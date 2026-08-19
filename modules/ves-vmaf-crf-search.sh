#!/usr/bin/env bash
# ves-vmaf-crf-search.sh -- per-title VMAF-targeted CRF search (internal
# sample-based and ab-av1-backed), upscale-target decisions, size-keep
# policy, and encoder profile/param resolution (SVT-AV1/x265 strings,
# fixed-CRF fallbacks, AV1 encoder bake-off). Pure move from the former
# monolithic script -- no logic changes.

# Compares a same-timestamp window of src vs an already-encoded out (no
# re-encode -- out already exists) via libvmaf, for the VES-tag quality
# readout. Both inputs are seeked independently with their own -ss/-t (dual
# input-seek, no intermediate clip files) rather than extracting stream-copy
# clips first: -c copy seeking snaps to each file's *own* nearest keyframe,
# and src/out have different GOP structures post-encode, so two independently
# extracted "same timestamp" clips can actually start several seconds apart --
# silently comparing misaligned frames and corrupting the VMAF number. Seeking
# straight into the filter graph is frame-accurate for both inputs and avoids
# writing temp files at all. target_height set means out was upscaled: the
# source is scaled up to match before comparison, same filter chain as the
# CRF-search scorer.
#
# A VFR source (duplicate/dropped frames scattered through the file -- a
# common web-rip artifact) plays back at a genuinely different per-frame
# wall-clock timing than the CFR output the encoder produces. Two
# independent -ss seeks to "the same" timestamp then land on different
# underlying frames every few frames as the two timings drift apart, and
# libvmaf silently scores each of those misaligned pairs near 0 -- found via
# a real fleet-wide false-positive spike (dozens of episodes across
# Snowpiercer/Jessica Jones/Man in High Castle/Westworld flagged as "below
# VMAF floor" on multiple machines) that a still-frame comparison showed
# looked visually fine; the per-frame VMAF log for one flagged file showed a
# literal ~3-frame-period pattern of 90-100 alternating with 0.0.
#
# Normalizing both streams to a common frame rate (fps=) before comparison
# fixes that -- but is NOT safe to apply unconditionally (2026-08-12
# correction to the 2026-08-11 fix above): Battlestar Galactica (1978)
# episodes have real, if subtle, frame-timing irregularities (confirmed via
# ffmpeg's own "non monotonically increasing dts" warnings) while sitting at
# an unusual native rate (500/21) where avg_frame_rate and r_frame_rate are
# EXACTLY equal despite that -- forcing fps=500/21 on an already-matching
# stream introduced its own resampling artifacts and made one file's score
# WORSE (81.7->69.3), while the unfiltered comparison actually scored it
# fine (89.9 on the same window). Since real misalignment can only ever drag
# a score spuriously LOW (never inflate it), and unnecessary resampling can
# also only ever drag a score LOW, never invent quality that isn't there --
# taking whichever of the two measurements is HIGHER is safe in both
# directions: a genuinely bad encode still scores low both ways, while
# either failure mode (misalignment without the filter, or resampling
# artifacts from the filter) is masked by the other measurement not being
# subject to that specific failure. Costs one extra ffmpeg pass per sample
# window -- acceptable for this occasional tagging/diagnostic path.
# Task #172: ffmpeg's MKV muxer relabels output PTS with a small offset vs
# the source (observed 20-40ms). Both inputs below are seeked independently
# at the SAME nominal "$start" and then have their own PTS zeroed
# (setpts=PTS-STARTPTS), so this offset can silently land the two -ss seeks
# on different real-content frames -- invisible on static content, but on
# fast motion a 1-frame misalignment can swing the score by tens of points.
#
# First attempt (2026-08-17) measured the src/out first-frame PTS delta once
# per file and unconditionally compensated the OUT-side seek by it, trusting
# it as a fixed correction. Real-world test on PRINCE disproved that:
# compensating by the measured offset (-ss 413.979 vs uncompensated 414, a
# 21ms difference) scored 26.9, while the SAME window uncompensated scored
# 72.6 -- worse, not better. A follow-up controlled sweep (13-point, one
# frame-duration step each, same file/window) showed WHY: the true best
# alignment is a sharp single peak sitting at offset=0 for that window, with
# score collapsing by ~50 points within a single frame either side -- not a
# smooth function a single measured delta can reliably predict, because the
# real misalignment isn't a fixed property of the FILE, it can vary window
# to window (frame jitter, B-frame reordering, landing near a scene cut).
#
# Correct fix: don't guess the offset from metadata at all -- SEARCH for it.
# For each sample window, try every whole-frame offset from
# -VMAF_ALIGN_SEARCH_FRAMES to +VMAF_ALIGN_SEARCH_FRAMES (crossed with the
# existing plain/fps-filter axis below, which guards a different, still-real
# VFR-drift failure mode) and keep whichever scores highest. Misalignment
# can only ever drag a score spuriously LOW, never inflate it, so taking the
# max across every candidate is safe in every direction -- same reasoning as
# the fps_filter dual-measurement this extends. Costs
# (2*VMAF_ALIGN_SEARCH_FRAMES+1) x up-to-2 ffmpeg passes per sample window;
# acceptable for this once-per-file tagging/diagnostic path given the
# alternative is a measurement that can't be trusted.
_vmaf_compare_window_once() {  # src out start secs model target_height fps_filter offset
  local src="$1" out="$2" start="$3" secs="$4" model="$5" target_height="${6:-0}" fps_filter="${7:-}" offset="${8:-0}"
  local scale_filter="" vlog v out_start
  case "$target_height" in
    720) scale_filter='scale=1280:720:flags=lanczos:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,' ;;
    1080) scale_filter='scale=1920:1080:flags=lanczos:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,' ;;
  esac
  # Compensate the OUT-side seek by the measured src/out PTS offset so both
  # seeks land on the same real content frame -- clamped to 0 (never seek
  # negative) since a large negative offset near the start of a file would
  # otherwise produce an invalid -ss.
  out_start="$(awk -v s="$start" -v d="$offset" 'BEGIN{v=s+d; printf "%.6f", (v<0?0:v)}')"
  # Every mktemp in this file now prefers RAMDISK_JOB_DIR (the actual
  # runtime-resolved per-job ramdisk, empty if this run couldn't get one)
  # over bare TMPDIR/tmp -- these CRF-search sample clips already land on
  # RAM-backed storage via plain /tmp on Linux (tmpfs), but consolidating
  # them onto the same ramdisk the main encode already staged closes the
  # one platform (macOS, where /tmp is real disk) where they didn't. Part
  # of the 2026-08-19 NAS-load/RAM-disk-utilization audit.
  vlog="$(mktemp "${RAMDISK_JOB_DIR:-${TMPDIR:-/tmp}}/ves-vmaf-XXXXXX.json")" || return 1
  # run_ffmpeg_validation (timeout-wrapped) -- same short-bounded-window
  # hang risk as the CRF-search VMAF scorer (fixed 2026-07-29).
  run_ffmpeg_validation -y -v error -ss "$out_start" -t "$secs" -i "$out" -ss "$start" -t "$secs" -i "$src" -lavfi \
    "[0:v]${fps_filter}setpts=PTS-STARTPTS,format=yuv420p10le[d];[1:v]${fps_filter}${scale_filter}setpts=PTS-STARTPTS,format=yuv420p10le[r];[d][r]libvmaf=model=$model:n_threads=$(nproc 2>/dev/null || sysctl -n hw.ncpu):log_fmt=json:log_path=$vlog" \
    -f null - 2>/dev/null || { rm -f "$vlog"; return 1; }
  v="$(python3 -c "import json;print(round(json.load(open('$vlog'))['pooled_metrics']['vmaf']['mean'],2))" 2>/dev/null)" || { rm -f "$vlog"; return 1; }
  rm -f "$vlog"
  printf '%s' "$v"
}

_vmaf_compare_window() {  # src out start secs model target_height
  local src="$1" out="$2" start="$3" secs="$4" model="$5" target_height="${6:-0}"
  local fps_rate fps_filter="" best="" v frame_dur=""
  fps_rate="$(run_ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
    -of default=nw=1:nk=1 "$src" 2>/dev/null)" || fps_rate=""
  if [[ "$fps_rate" =~ ^[0-9]+/[0-9]+$ ]] && [ "${fps_rate#*/}" -gt 0 ] && [ "${fps_rate%/*}" -gt 0 ]; then
    fps_filter="fps=${fps_rate},"
    frame_dur="$(awk -v n="${fps_rate%/*}" -v d="${fps_rate#*/}" 'BEGIN{printf "%.6f", d/n}')"
  fi
  # Search -N..+N frame-durations around the nominal seek, crossed with
  # {no fps filter, fps filter}, and keep the max -- see the comment above
  # this function for why a single guessed offset isn't safe to trust.
  local -a offsets=("0")
  if [ -n "$frame_dur" ]; then
    local k
    for ((k = -VMAF_ALIGN_SEARCH_FRAMES; k <= VMAF_ALIGN_SEARCH_FRAMES; k++)); do
      [ "$k" -eq 0 ] && continue
      offsets+=("$(awk -v k="$k" -v d="$frame_dur" 'BEGIN{printf "%.6f", k*d}')")
    done
  fi
  local -a ff_variants=("")
  [ -n "$fps_filter" ] && ff_variants+=("$fps_filter")
  local o ff
  for o in "${offsets[@]}"; do
    for ff in "${ff_variants[@]}"; do
      v="$(_vmaf_compare_window_once "$src" "$out" "$start" "$secs" "$model" "$target_height" "$ff" "$o")" || continue
      if [ -z "$best" ] || awk -v a="$v" -v b="$best" 'BEGIN{exit !(a>b)}'; then
        best="$v"
      fi
    done
  done
  [ -n "$best" ] && printf '%s' "$best"
  [ -n "$best" ]
}

# Sampled full-output VMAF for the VES tag -- distinct from vmaf_crf_search's
# candidate-CRF prediction: this scores the actual chosen output against the
# actual source, so it's meaningful whether the CRF came from a search, a
# fixed-CRF fallback, or a profile that never runs VMAF search at all.
measure_final_vmaf() {  # src out target_height -> prints VMAF or fails
  local src="$1" out="$2" target_height="${3:-0}"
  local model dur nsamples i start vsum=0 v n=0
  [ -f "$src" ] && [ -f "$out" ] || return 1
  model="$(vmaf_model_for_source "$src")"
  dur="$(video_duration "$src")"; dur="${dur%.*}"
  [ -n "$dur" ] && [ "$dur" -gt 0 ] || return 1
  nsamples="$VMAF_SAMPLES"
  while [ "$nsamples" -gt 1 ] && [ "$dur" -lt $(( VMAF_SAMPLE_SECS * nsamples * 2 )) ]; do
    nsamples=$(( nsamples - 1 ))
  done
  for ((i = 1; i <= nsamples; i++)); do
    start=$(( dur * (i * 2 - 1) / (nsamples * 2) ))
    v="$(_vmaf_compare_window "$src" "$out" "$start" "$VMAF_SAMPLE_SECS" "$model" "$target_height")" || continue
    vsum="$(awk -v a="$vsum" -v x="$v" 'BEGIN{print a+x}')"
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || return 1
  awk -v s="$vsum" -v n="$n" 'BEGIN{printf "%.1f", s/n}'
}

video_display_metrics() {  # prints: display_width display_height fps bitrate bpppf
  local src="$1" w h sar dar fps br fmt_br sn sd dn dd fn fd dw dh bpp
  w="$(video_width "$src")"; h="$(video_height "$src")"
  sar="$(run_ffprobe -v error -select_streams v:0 -show_entries stream=sample_aspect_ratio -of default=nw=1:nk=1 "$src" 2>/dev/null || true)"
  dar="$(run_ffprobe -v error -select_streams v:0 -show_entries stream=display_aspect_ratio -of default=nw=1:nk=1 "$src" 2>/dev/null || true)"
  fps="$(run_ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=nw=1:nk=1 "$src" 2>/dev/null || true)"
  br="$(run_ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of default=nw=1:nk=1 "$src" 2>/dev/null || true)"
  if ! [[ "$br" =~ ^[0-9]+$ ]] || [ "$br" -le 0 ]; then
    fmt_br="$(run_ffprobe -v error -show_entries format=bit_rate -of default=nw=1:nk=1 "$src" 2>/dev/null || true)"
    [[ "$fmt_br" =~ ^[0-9]+$ ]] && br="$fmt_br" || br=0
  fi
  sn="${sar%%:*}"; sd="${sar##*:}"; dn="${dar%%:*}"; dd="${dar##*:}"
  fn="${fps%%/*}"; fd="${fps##*/}"
  dw="$w"; dh="$h"
  if [[ "$sn" =~ ^[0-9]+$ && "$sd" =~ ^[0-9]+$ ]] && [ "$sd" -gt 0 ]; then
    dw="$(awk -v w="$w" -v n="$sn" -v d="$sd" 'BEGIN{printf "%.2f",w*n/d}')"
  elif [[ "$dn" =~ ^[0-9]+$ && "$dd" =~ ^[0-9]+$ ]] && [ "$dd" -gt 0 ]; then
    dw="$(awk -v h="$h" -v n="$dn" -v d="$dd" 'BEGIN{printf "%.2f",h*n/d}')"
  fi
  if [[ "$fn" =~ ^[0-9]+$ && "$fd" =~ ^[0-9]+$ ]] && [ "$fd" -gt 0 ]; then
    fps="$(awk -v n="$fn" -v d="$fd" 'BEGIN{printf "%.6f",n/d}')"
  else
    fps=0
  fi
  bpp="$(awk -v b="${br:-0}" -v w="${dw:-0}" -v h="${dh:-0}" -v f="${fps:-0}" \
    'BEGIN{if(w>0&&h>0&&f>0&&b>0)printf "%.8f",b/(w*h*f);else printf "0"}')"
  printf '%s %s %s %s %s' "$dw" "$dh" "$fps" "${br:-0}" "$bpp"
}

upscale_sample_decision() {  # src display_height -> 720|1080
  local src="$1" display_h="$2" profile params crf dur start tmp clip out720 out1080
  local log720 log1080 v720 v1080 s720 s1080 gain ratio grain_flag=()
  profile="$(profile_for_source "$src")" || return 1
  params="$(profile_svt_params "$profile")"; crf="$(profile_fixed_crf av1 "$profile")"
  [ "$FF_HAS_LIBSVTAV1" = true ] && [ "$FF_HAS_LIBVMAF" = true ] || return 1
  dur="$(video_duration "$src")"
  start="$(awk -v d="$dur" -v n="$UPSCALE_SAMPLE_SECS" 'BEGIN{if(d>n*2)printf "%.3f",(d-n)/2;else print 0}')"
  # || return 1 (E2E review, 2026-07-30): every failure path below this
  # point cleans up "$tmp" and returns 1 -- but a failing mktemp itself here
  # was bare, which would abort the whole script under `set -e` instead of
  # letting this function's own graceful-failure convention run.
  tmp="$(mktemp -d "${RAMDISK_JOB_DIR:-${TMPDIR:-/tmp}}/ves-crf-XXXXXX")" || return 1
  clip="$tmp/clip.mkv"; out720="$tmp/720.mkv"; out1080="$tmp/1080.mkv"
  log720="$tmp/720.json"; log1080="$tmp/1080.json"
  # run_ffmpeg_validation (timeout-wrapped), not bare run_ffmpeg -- same
  # unbounded-short-sample-clip hang risk as vmaf_crf_search_internal /
  # _vmaf_score_one (fixed 2026-07-29 after a crashed SVT-AV1 worker thread
  # deadlocked a bare run_ffmpeg call and hung an entire fleet machine's
  # batch indefinitely); found here too during team review of that fix.
  # -fflags +genpts -avoid_negative_ts make_zero -- legacy AVI sources can
  # have irregular/missing timestamps at an arbitrary mid-file seek point,
  # which otherwise fails stream-copy clip extraction with "Can't write
  # packet with unknown timestamp" and silently falls back to the
  # conservative default instead of a real tested upscale decision (found
  # and verified via direct reproduction against "Divorce American Style
  # (1967)", 2026-07-30).
  run_ffmpeg_validation -y -v error -fflags +genpts -avoid_negative_ts make_zero -ss "$start" -t "$UPSCALE_SAMPLE_SECS" -i "$src" -map 0:v:0 -c copy "$clip" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  [ -s "$clip" ] || { rm -rf "$tmp"; return 1; }
  run_ffmpeg_validation -y -v error -i "$clip" -vf "scale=1280:720:flags=lanczos:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2" \
    -c:v libsvtav1 -preset "$SVT_PRESET_SEARCH" -crf "$crf" -pix_fmt yuv420p10le -svtav1-params "$params" -an "$out720" 2>/dev/null \
    || { rm -rf "$tmp"; return 1; }
  run_ffmpeg_validation -y -v error -i "$clip" -vf "scale=1920:1080:flags=lanczos:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2" \
    -c:v libsvtav1 -preset "$SVT_PRESET_SEARCH" -crf "$crf" -pix_fmt yuv420p10le -svtav1-params "$params" -an "$out1080" 2>/dev/null \
    || { rm -rf "$tmp"; return 1; }
  profile_uses_grain_synthesis "$profile" && grain_flag=(-export_side_data film_grain)
  run_ffmpeg_validation -y -v error "${grain_flag[@]}" -i "$out720" -i "$clip" -lavfi \
    "[0:v]scale=1920:1080:flags=lanczos,setpts=PTS-STARTPTS[d];[1:v]scale=1920:1080:flags=lanczos:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setpts=PTS-STARTPTS[r];[d][r]libvmaf=model=version=vmaf_v0.6.1neg:log_fmt=json:log_path=$log720" \
    -f null - 2>/dev/null || { rm -rf "$tmp"; return 1; }
  run_ffmpeg_validation -y -v error "${grain_flag[@]}" -i "$out1080" -i "$clip" -lavfi \
    "[0:v]setpts=PTS-STARTPTS[d];[1:v]scale=1920:1080:flags=lanczos:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setpts=PTS-STARTPTS[r];[d][r]libvmaf=model=version=vmaf_v0.6.1neg:log_fmt=json:log_path=$log1080" \
    -f null - 2>/dev/null || { rm -rf "$tmp"; return 1; }
  v720="$(python3 -c "import json;print(json.load(open('$log720'))['pooled_metrics']['vmaf']['mean'])" 2>/dev/null)" || { rm -rf "$tmp"; return 1; }
  v1080="$(python3 -c "import json;print(json.load(open('$log1080'))['pooled_metrics']['vmaf']['mean'])" 2>/dev/null)" || { rm -rf "$tmp"; return 1; }
  s720="$(file_size_bytes "$out720")"; s1080="$(file_size_bytes "$out1080")"
  gain="$(awk -v a="$v720" -v b="$v1080" 'BEGIN{printf "%.3f",b-a}')"
  ratio="$(awk -v a="$s720" -v b="$s1080" 'BEGIN{if(a>0)printf "%.3f",b/a;else print 99}')"
  log_err "Upscale sample: 720p VMAF=$v720 size=$(human_size_bytes "$s720"); 1080p VMAF=$v1080 size=$(human_size_bytes "$s1080"); gain=$gain size-ratio=$ratio"
  rm -rf -- "$tmp" 2>/dev/null || true
  if awk -v g="$gain" 'BEGIN{exit !(g>=0.5)}'; then printf 1080
  elif awk -v g="$gain" 'BEGIN{exit !(g<0.4)}'; then printf 720
  elif awk -v r="$ratio" 'BEGIN{exit !(r>1.18)}'; then printf 720
  elif awk -v h="$display_h" 'BEGIN{exit !(h>=540)}'; then printf 1080
  else printf 720
  fi
}

resolve_upscale_target() {
  local src="$1" metrics dw dh fps br bpp decision
  if [ -n "${UPSCALE_TARGET_CACHE[$src]+set}" ]; then
    UPSCALE_TARGET_HEIGHT="${UPSCALE_TARGET_CACHE[$src]}"; return 0
  fi
  UPSCALE_TARGET_HEIGHT=0
  if is_disk_source "$src"; then UPSCALE_TARGET_CACHE[$src]=0; return 0; fi
  metrics="$(video_display_metrics "$src")"; read -r dw dh fps br bpp <<<"$metrics"
  if [ -z "$dh" ] || ! [[ "$dh" =~ ^[0-9]+(\.[0-9]+)?$ ]] || awk -v h="$dh" 'BEGIN{exit !(h<=0)}'; then
    # Metrics retrieval itself failed or timed out (e.g. a stalled network
    # mount) — do not fall through to upscale_sample_decision(), which runs
    # several un-timeout-guarded run_ffmpeg calls against the same source
    # and could hang indefinitely on the same stall. Conservative height-only
    # fallback instead, same bias as the existing sample-test-failed path.
    if awk -v h="${dh:-0}" 'BEGIN{exit !(h>=540)}'; then decision=1080; else decision=720; fi
    warn "Upscale metrics retrieval failed/timed out — conservative ${decision}p fallback: $src"
  elif awk -v h="$dh" -v t="$UPSCALE_HEIGHT_THRESHOLD" 'BEGIN{exit !(h>=t)}'; then
    decision=0
  elif awk -v h="$dh" 'BEGIN{exit !(h>0&&h<=360)}'; then
    decision=720
  elif awk -v b="$bpp" -v t="$UPSCALE_LOW_BPPPF" 'BEGIN{exit !(b>0&&b<t)}'; then
    decision=720
  else
    decision="$(upscale_sample_decision "$src" "$dh")" || {
      # Fail conservatively: favor 1080 near the grace band, 720 for SD.
      if awk -v h="$dh" 'BEGIN{exit !(h>=540)}'; then decision=1080; else decision=720; fi
      warn "Upscale sample test unavailable/failed — conservative ${decision}p fallback: $src"
    }
  fi
  UPSCALE_TARGET_CACHE[$src]="$decision"; UPSCALE_TARGET_HEIGHT="$decision"
  case "$decision" in
    0) log "Upscale decision: native (display ${dw}x${dh}, near-720p grace band)" ;;
    720) log "Upscale decision: 1280x720 (display ${dw}x${dh}, bpppf=$bpp)" ;;
    1080) log "Upscale decision: 1920x1080 (display ${dw}x${dh}, sample test)" ;;
  esac
}

# Short human-readable upscale status for the per-title "Encoder profile" log
# line. Call after resolve_upscale_target() has set UPSCALE_TARGET_HEIGHT.
upscale_status_desc() {
  case "$UPSCALE_TARGET_HEIGHT" in
    720) printf 'upscaling to 720p' ;;
    1080) printf 'upscaling to 1080p' ;;
    *) printf 'no upscale' ;;
  esac
}

source_triggers_1080p_upscale() {
  resolve_upscale_target "$1"
  [ "$UPSCALE_TARGET_HEIGHT" = 1080 ]
}

source_is_upscaled() {
  resolve_upscale_target "$1"
  [ "$UPSCALE_TARGET_HEIGHT" = 720 ] || [ "$UPSCALE_TARGET_HEIGHT" = 1080 ]
}

# Size-tiered upscale-overshoot cap (see UPSCALE_OVERSHOOT_* above).
effective_upscale_overshoot_pct() {
  local orig_sz="$1"
  local mb=$((orig_sz / 1048576))
  if [ "$mb" -le "$UPSCALE_OVERSHOOT_SMALL_MAX_MB" ]; then
    echo "$UPSCALE_OVERSHOOT_SMALL_PCT"
  elif [ "$mb" -le "$UPSCALE_OVERSHOOT_MED_MAX_MB" ]; then
    echo "$UPSCALE_OVERSHOOT_MED_PCT"
  else
    echo "$UPSCALE_MAX_OVERSHOOT_PCT"
  fi
}

size_keep_policy_av1() {
  local orig_sz="$1"
  local new_sz="$2"
  local upscaled="${3:-false}"
  local pct lim="$AV1_MAX_OVERSHOOT_PCT"
  if [ "$new_sz" -le "$orig_sz" ]; then
    echo keep
    return 0
  fi
  # Upscale adds pixels — allow more growth than normal, but still cap (size-tiered).
  if [ "$upscaled" = true ]; then
    lim="$(effective_upscale_overshoot_pct "$orig_sz")"
  fi
  pct="$(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { if (o<=0) print 100; else print ((n-o)/o)*100 }')"
  if awk -v p="$pct" -v lim="$lim" 'BEGIN { exit !(p>lim) }'; then
    echo reject
  else
    echo keep
  fi
}

size_keep_policy() {
  local orig_sz="$1"
  local new_sz="$2"
  local upscaled="${3:-false}"
  local pct lim="$SIZE_OVERSHOOT_PCT"
  if [ "$new_sz" -le "$orig_sz" ]; then
    echo keep
    return 0
  fi
  if [ "$upscaled" = true ]; then
    lim="$(effective_upscale_overshoot_pct "$orig_sz")"
  fi
  pct="$(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { if (o<=0) print 100; else print ((n-o)/o)*100 }')"
  if awk -v p="$pct" -v lim="$lim" 'BEGIN { exit !(p>lim) }'; then
    echo reject
  else
    echo keep
  fi
}

encoder_ssim_score() {
  local reference="$1"
  local encoded="$2"
  local out score
  if [ ! -s "$encoded" ]; then
    echo 0
    return 0
  fi
  # run_ffmpeg_validation (timeout-wrapped) -- reference/encoded here are
  # both short bake-off sample clips (SAMPLE_SECONDS), same hang risk as
  # the CRF-search VMAF scorer (fixed 2026-07-29).
  out="$(run_ffmpeg_validation -nostdin -i "$reference" -i "$encoded" -lavfi ssim -f null - 2>&1 || true)"
  score="$(awk '/SSIM Y:/{ print $3; exit }' <<<"$out" | tr -d '()')"
  if [ -z "$score" ] || [ "$score" = "N/A" ]; then
    score="$(awk '/All:/{ print $2; exit }' <<<"$out" | tr -d '()')"
  fi
  # Keep only a numeric SSIM value (ffmpeg stderr must not leak into comparisons).
  score="$(awk -v s="${score:-0}" 'BEGIN {
    if (s ~ /^[0-9]+(\.[0-9]+)?$/) print s; else print 0
  }')"
  printf '%s' "$score"
}

bakeoff_default_av1_encoder() {
  if [ "$USE_NVIDIA_ENCODE" = true ]; then
    AV1_ENCODER="svt_av1_10bit"
    warn "Bake-off incomplete — defaulting to $AV1_ENCODER (nvenc_av1_10bit sample failed)"
  else
    AV1_ENCODER="svt_av1_10bit"
    warn "Bake-off incomplete — defaulting to $AV1_ENCODER"
  fi
}

# Bake-off runs once per profile class (not once per file).
bakeoff_profile_key() {
  local src="$1"
  local base
  base="$(profile_for_source "$src")" || return $?
  if source_has_dolby_vision "$src" || source_is_hdr10_wcg "$src"; then
    printf '%s_hdr' "$base"
  else
    printf '%s_sdr' "$base"
  fi
}

bakeoff_encoder_for_src() {
  local src="$1"
  local hb_title="${2:-}"
  local hb_dur="${3:-}"
  local key="${4:-$(bakeoff_profile_key "$src")}"

  if [ -n "${BAKEOFF_ENCODER_CHOICE[$key]+set}" ]; then
    AV1_ENCODER="${BAKEOFF_ENCODER_CHOICE[$key]}"
    return 0
  fi

  if [ "$SKIP_BAKEOFF" = true ]; then
    bakeoff_default_av1_encoder
    BAKEOFF_ENCODER_CHOICE[$key]="$AV1_ENCODER"
    log "Bake-off skipped (--skip-bakeoff) — profile '$key' locked: $AV1_ENCODER"
    return 0
  fi

  if [ "$ACTIVE_ENCODE_MODE" = software ]; then
    bakeoff_default_av1_encoder
    BAKEOFF_ENCODER_CHOICE[$key]="$AV1_ENCODER"
    log "Bake-off skipped (software encode) — profile '$key' locked: $AV1_ENCODER"
    if _path_on_cifs "$src"; then
      warn "Software encode over SMB is very slow — use hardware encoders when available"
    fi
    return 0
  fi

  if [ "$USE_NVIDIA_ENCODE" = true ]; then
    AV1_ENCODER="nvenc_av1_10bit"
    BAKEOFF_ENCODER_CHOICE[$key]="$AV1_ENCODER"
    log "Bake-off skipped (NVENC) — profile '$key' locked: $AV1_ENCODER"
    return 0
  fi

  log "Bake-off profile '$key' (sample from: $(basename "$src"))"
  pick_av1_encoder "$src" "$hb_title" "$hb_dur" || bakeoff_default_av1_encoder
  BAKEOFF_ENCODER_CHOICE[$key]="$AV1_ENCODER"
  log "Profile '$key' encoder locked: $AV1_ENCODER (applies to all $key sources in this run)"
}

profile_svt_params() {
  local params
  case "$1" in
    wanime) params="$SVT_PARAMS_WANIME" ;;
    anime) params="$SVT_PARAMS_ANIME" ;;
    canime) params="$SVT_PARAMS_CANIME" ;;
    movies) params="$SVT_PARAMS_MOVIES" ;;
    classic) params="$SVT_PARAMS_CLASSIC" ;;
    vintage) params="$SVT_PARAMS_VINTAGE" ;;
    mtv) params="$SVT_PARAMS_MTV" ;;
    vtv) params="$SVT_PARAMS_VTV" ;;
    *) return 1 ;;
  esac
  if ! svtav1_supports_sharpness; then
    params="$(printf '%s' "$params" | sed -E 's/:sharpness=[0-9]+//')"
  fi
  printf '%s' "$params"
}

profile_x265_params() {
  case "$1" in
    wanime) printf '%s' "$X265_PARAMS_WANIME" ;;
    anime) printf '%s' "$X265_PARAMS_ANIME" ;;
    canime) printf '%s' "$X265_PARAMS_CANIME" ;;
    movies) printf '%s' "$X265_PARAMS_MOVIES" ;;
    classic) printf '%s' "$X265_PARAMS_CLASSIC" ;;
    vintage) printf '%s' "$X265_PARAMS_VINTAGE" ;;
    mtv) printf '%s' "$X265_PARAMS_MTV" ;;
    vtv) printf '%s' "$X265_PARAMS_VTV" ;;
    *) return 1 ;;
  esac
}

# x265's own "tune" concept (animation/grain/etc) is a whole-preset
# convenience applied by x265_param_default_preset(), a DIFFERENT function
# than x265_param_parse() (what ffmpeg's -x265-params, HandBrake's
# --encopts, and ab-av1's --enc x265-params= all call) -- so it can never be
# set as a key inside those params strings (see the X265_PARAMS_* comment).
# Callers must pass this through their interface's own dedicated tune flag
# instead (ffmpeg: -tune; HandBrake: --encoder-tune; ab-av1: --enc tune=...).
# Empty return means "no tune" -- callers must skip the flag entirely rather
# than pass an empty string (x265/ffmpeg reject an empty -tune value).
profile_x265_tune() {
  case "$1" in
    wanime|anime|canime) printf 'animation' ;;
    vintage) printf 'grain' ;;
    *) return 1 ;;
  esac
}

profile_fixed_crf() {
  local codec="$1" profile="$2" hdr="${3:-false}"
  if [ "$hdr" = true ]; then
    [ "$codec" = av1 ] && printf '%s' "$FIXED_CRF_SVT_HDR" || printf '%s' "$FIXED_CRF_X265_HDR"
    return
  fi
  case "$codec:$profile" in
    av1:wanime) printf 26 ;; av1:anime) printf 26 ;; av1:canime) printf "$FIXED_CRF_SVT_CANIME" ;; av1:movies) printf 26 ;;
    av1:classic) printf 25 ;; av1:vintage) printf 24 ;; av1:mtv) printf 26 ;; av1:vtv) printf 25 ;;
    hevc:wanime) printf 20 ;; hevc:anime) printf 22 ;; hevc:canime) printf "$FIXED_CRF_X265_CANIME" ;; hevc:movies) printf 20 ;;
    hevc:classic) printf 20 ;; hevc:vintage) printf 20 ;; hevc:mtv) printf 20 ;; hevc:vtv) printf 21 ;;
    *) return 1 ;;
  esac
}

profile_uses_grain_synthesis() {
  case "$1" in anime|classic|vintage|vtv) return 0 ;; *) return 1 ;; esac
}

# Supersedes the legacy five-profile definition above. Hardware-only encoders
# retain their established quality scales; software SVT/x265 consume the exact
# Phase F constants.
load_encoder_profile() {
  local encoder="$1" src="${2:-$SEARCH_PATH}" profile
  profile="$(profile_for_source "$src")" || return $?
  EP_PRESET=""; EP_QUALITY=""; EP_ENCOPTS=""; EP_ENCODER_TUNE=""; EP_AUDIO_CODEC=""
  EP_AUDIO_BITRATE=""; EP_HW_DECODE=false; EP_VIDEO_FILTERS=()
  EP_PROFILE_NAME="$profile"
  case "$profile" in
    anime) EP_VIDEO_FILTERS=(--lapsharp=light) ;;
    # Classic anime wants more edge retention than modern anime -- the
    # line-art-preservation goal this profile exists for -- so it gets the
    # stronger lapsharp tier instead of the modern profile's light tier.
    canime) EP_VIDEO_FILTERS=(--lapsharp=medium) ;;
  esac
  case "$encoder" in
    svt_av1_10bit)
      EP_PRESET="$SVT_PRESET_FINAL"; EP_QUALITY="$(profile_fixed_crf av1 "$profile")"
      EP_ENCOPTS="$(profile_svt_params "$profile")"
      EP_AUDIO_CODEC=opus; EP_AUDIO_BITRATE=$OPUS_BITRATE; EP_HW_DECODE=auto ;;
    nvenc_av1_10bit)
      EP_PRESET=slowest
      case "$profile" in anime|canime) EP_QUALITY=30 ;; *) EP_QUALITY=24 ;; esac
      EP_ENCOPTS="$(nvenc_av1_encopts)"
      EP_AUDIO_CODEC=opus; EP_AUDIO_BITRATE=$OPUS_BITRATE; EP_HW_DECODE=true ;;
    x265)
      EP_PRESET=medium; EP_QUALITY="$(profile_fixed_crf hevc "$profile")"
      EP_ENCOPTS="$(profile_x265_params "$profile")"
      EP_ENCODER_TUNE="$(profile_x265_tune "$profile")" || EP_ENCODER_TUNE=""
      EP_AUDIO_CODEC=aac; EP_AUDIO_BITRATE=$AAC_BITRATE; EP_HW_DECODE=false ;;
    nvenc_h265)
      EP_PRESET=medium; EP_QUALITY=24
      case "$profile" in anime|canime) EP_QUALITY=26 ;; esac
      EP_ENCOPTS='spatial-aq=1:temporal-aq=1:rc-lookahead=32:multipass=fullres'
      EP_AUDIO_CODEC=aac; EP_AUDIO_BITRATE=$AAC_BITRATE; EP_HW_DECODE=true ;;
    qsv_h265)
      EP_PRESET=medium; EP_QUALITY=22; EP_ENCOPTS='lowpower=0'
      case "$profile" in anime|canime) EP_QUALITY=24 ;; esac
      EP_AUDIO_CODEC=aac; EP_AUDIO_BITRATE=$AAC_BITRATE; EP_HW_DECODE=true ;;
    vt_h265)
      EP_QUALITY=58; EP_ENCOPTS='bframes=1'
      case "$profile" in anime|canime) EP_QUALITY=60 ;; esac
      EP_AUDIO_CODEC=aac; EP_AUDIO_BITRATE=$AAC_BITRATE; EP_HW_DECODE=true ;;
    vce_h265)
      EP_QUALITY=22; EP_ENCOPTS='preanalysis=1'
      EP_AUDIO_CODEC=aac; EP_AUDIO_BITRATE=$AAC_BITRATE; EP_HW_DECODE=false ;;
    *) err "Unknown encoder profile: $encoder"; return 1 ;;
  esac
}

pick_av1_encoder() {
  local sample_src="$1"
  local hb_title="${2:-}"
  local hb_dur="${3:-}"
  local tmp clip nvenc_out svt_out ss_nv ss_svt start dur end hdr_note
  # || return 1 (E2E review, 2026-07-30): bare mktemp here would abort the
  # whole script under `set -e` instead of this function's own return-1
  # convention used by every failure path below.
  tmp="$(mktemp -d "${RAMDISK_JOB_DIR:-${TMPDIR:-/tmp}}/ves-crf-XXXXXX")" || return 1
  clip="$tmp/clip.mkv"
  nvenc_out="$tmp/nvenc.mkv"
  svt_out="$tmp/svt.mkv"

  if [ "$DRY_RUN" = true ]; then
    if [ "$USE_NVIDIA_ENCODE" = true ]; then
      AV1_ENCODER="nvenc_av1_10bit"
      log "[dry-run] Would run encoder bake-off; defaulting to $AV1_ENCODER"
    else
      AV1_ENCODER="svt_av1_10bit"
      log "[dry-run] Would run encoder bake-off; defaulting to $AV1_ENCODER"
    fi
    rm -rf "$tmp"
    return 0
  fi

  log "Encoder bake-off (${SAMPLE_SECONDS}s sample) — comparing AV1 encoders for this profile"
  local -a hb_color_extra=()
  local svt_cq nv_cq
  load_encoder_profile svt_av1_10bit "$sample_src"
  svt_cq="$EP_QUALITY"
  if [ "$USE_NVIDIA_ENCODE" = true ]; then
    load_encoder_profile nvenc_av1_10bit "$sample_src"
    nv_cq="$EP_QUALITY"
    log "Bake-off CQ (scales differ): svt_av1_10bit=$svt_cq vs nvenc_av1_10bit=$nv_cq"
  else
    log "Bake-off CQ: svt_av1_10bit=$svt_cq"
  fi
  hdr_note="$(hdr_color_note "$sample_src")"
  [ -n "$hdr_note" ] && log "Bake-off source color: $hdr_note"
  handbrake_append_color_metadata "$sample_src" hb_color_extra

  if [ -n "$hb_title" ]; then
    dur="$hb_dur"
    start="$(sample_start_middle "$dur")"
    end="$(awk -v s="$start" -v n="$SAMPLE_SECONDS" 'BEGIN { printf "%.0f", s + n }')"
    log "Bake-off (disc title $hb_title): ${SAMPLE_SECONDS}s sample from middle (start=${start}s of ${dur}s)"
    load_encoder_profile svt_av1_10bit "$sample_src"
    run_handbrake_with_progress "Bake-off: svt_av1_10bit" -i "$sample_src" -t "$hb_title" -o "$svt_out" -f mkv \
      --start-at "duration:$start" --stop-at "duration:$end" \
      -e svt_av1_10bit -q "$EP_QUALITY" --encoder-preset "$EP_PRESET" \
      --encopts "$EP_ENCOPTS" --all-audio --aencoder "$EP_AUDIO_CODEC" -B "$EP_AUDIO_BITRATE" \
      -D "$AUDIO_DRC" --gain "$AUDIO_GAIN" \
      "${EP_VIDEO_FILTERS[@]}" "${hb_color_extra[@]}" || warn "Bake-off: svt_av1_10bit sample encode failed"
  else
    dur="$(video_duration "$sample_src")"
    start="$(sample_start_middle "$dur")"
    log "Bake-off: ${SAMPLE_SECONDS}s sample from middle (start=${start}s of ${dur}s)"
    # run_ffmpeg_validation (timeout-wrapped) -- short sample-clip
    # extraction, same hang risk class fixed 2026-07-29 elsewhere.
    if ! run_ffmpeg_validation -y -nostdin -ss "$start" -t "$SAMPLE_SECONDS" -i "$sample_src" -map 0 -c copy "$clip" >/dev/null 2>&1; then
      warn "Bake-off: ffmpeg could not extract sample clip"
      rm -rf "$tmp"
      bakeoff_default_av1_encoder
      return 0
    fi
    if [ ! -s "$clip" ]; then
      warn "Bake-off: sample clip is empty"
      rm -rf "$tmp"
      bakeoff_default_av1_encoder
      return 0
    fi
    load_encoder_profile svt_av1_10bit "$sample_src"
    run_handbrake_with_progress "Bake-off: svt_av1_10bit" -i "$clip" -o "$svt_out" -f mkv \
      -e svt_av1_10bit -q "$EP_QUALITY" --encoder-preset "$EP_PRESET" \
      --encopts "$EP_ENCOPTS" --all-audio --aencoder "$EP_AUDIO_CODEC" -B "$EP_AUDIO_BITRATE" \
      -D "$AUDIO_DRC" --gain "$AUDIO_GAIN" \
      "${EP_VIDEO_FILTERS[@]}" "${hb_color_extra[@]}" || warn "Bake-off: svt_av1_10bit sample encode failed"
  fi

  if [ "$USE_NVIDIA_ENCODE" = true ]; then
    load_encoder_profile nvenc_av1_10bit "$sample_src"
    if [ -n "$hb_title" ]; then
      CUDA_VISIBLE_DEVICES="$GPU_AV1" run_handbrake_with_progress "Bake-off: nvenc_av1_10bit" -i "$sample_src" -t "$hb_title" -o "$nvenc_out" -f mkv \
        --start-at "duration:$start" --stop-at "duration:$end" \
        -e nvenc_av1_10bit -q "$EP_QUALITY" --encoder-preset "$EP_PRESET" \
        --encopts "$EP_ENCOPTS" --enable-hw-decoding "${HW_DECODE_NAME:-nvdec}" \
        --all-audio --aencoder "$EP_AUDIO_CODEC" -B "$EP_AUDIO_BITRATE" \
        -D "$AUDIO_DRC" --gain "$AUDIO_GAIN" \
        "${EP_VIDEO_FILTERS[@]}" "${hb_color_extra[@]}" || warn "Bake-off: nvenc_av1_10bit sample encode failed"
    else
      CUDA_VISIBLE_DEVICES="$GPU_AV1" run_handbrake_with_progress "Bake-off: nvenc_av1_10bit" -i "$clip" -o "$nvenc_out" -f mkv \
        -e nvenc_av1_10bit -q "$EP_QUALITY" --encoder-preset "$EP_PRESET" \
        --encopts "$EP_ENCOPTS" --enable-hw-decoding "${HW_DECODE_NAME:-nvdec}" \
        --all-audio --aencoder "$EP_AUDIO_CODEC" -B "$EP_AUDIO_BITRATE" \
        -D "$AUDIO_DRC" --gain "$AUDIO_GAIN" \
        "${EP_VIDEO_FILTERS[@]}" "${hb_color_extra[@]}" || warn "Bake-off: nvenc_av1_10bit sample encode failed"
    fi

    ss_nv=0; ss_svt=0
    if [ -s "$nvenc_out" ]; then
      ss_nv="$(encoder_ssim_score "$clip" "$nvenc_out")"
    fi
    if [ -s "$svt_out" ]; then
      ss_svt="$(encoder_ssim_score "$clip" "$svt_out")"
    fi

    log "Bake-off SSIM — nvenc_av1_10bit (CQ $nv_cq): ${ss_nv:-0} | svt_av1_10bit (CQ $svt_cq): ${ss_svt:-0}"

    if [ -s "$svt_out" ] && [ -s "$nvenc_out" ]; then
      if awk -v a="${ss_svt:-0}" -v b="${ss_nv:-0}" 'BEGIN { exit !(a>=b) }'; then
        AV1_ENCODER="svt_av1_10bit"
      else
        AV1_ENCODER="nvenc_av1_10bit"
      fi
    elif [ -s "$svt_out" ]; then
      AV1_ENCODER="svt_av1_10bit"
    elif [ -s "$nvenc_out" ]; then
      AV1_ENCODER="nvenc_av1_10bit"
    else
      rm -rf "$tmp"
      bakeoff_default_av1_encoder
      return 0
    fi
    log "Selected AV1 encoder: $AV1_ENCODER (GPU $GPU_AV1 for nvenc)"
  else
    if [ -s "$svt_out" ]; then
      AV1_ENCODER="svt_av1_10bit"
      log "Selected AV1 encoder: $AV1_ENCODER (software — no NVIDIA GPU)"
    else
      rm -rf "$tmp"
      bakeoff_default_av1_encoder
      return 0
    fi
  fi

  rm -rf "$tmp"
  log "Bake-off complete — proceeding with full encode queue"
  return 0
}

# Shared ffmpeg sample-encoder for av1_source_reencode_sample_decision.
# Reuses determine_hdr_mode() + build_ffmpeg_video_args() -- the exact same
# HDR/color-metadata machinery the real encode uses -- so the sample can
# never diverge from the real encode's color handling and reintroduce the
# tint/color-shift bug determine_hdr_mode's own comments describe. Replaces
# the HandBrake-based sample encoders (2026-07-22): HandBrakeCLI build
# version drift across the fleet (1.9.0/1.11.0 vs a newer nightly build)
# caused HandBrake to silently fail to open ffmpeg -c copy-extracted sample
# clips at all ("unrecognized file type") on some machines, corrupting the
# AV1-vs-x265 shrink prediction into a false "sample test failed" skip with
# no diagnostic detail -- see feedback_verbose_encoder_diagnostics memory.
# This also fixes a pre-existing accuracy gap: the old HandBrake sample used
# NVENC hardware quality whenever available, while the real encode almost
# always goes through ffmpeg's software libsvtav1/libx265 instead (see
# try_av1_convert's ENCODE_ENGINE=ffmpeg branch) -- the two were frequently
# already calibrated against different encoders entirely.
ffmpeg_sample_encode() {
  local codec="$1" clip="$2" dst="$3" orig_src="$4" profile="$5"
  local hdr=false hdr_mode crf resolved_crf rc acodec abr errfile vf_joined
  local -a args

  hdr_mode="$(determine_hdr_mode "$orig_src")"
  case "$hdr_mode" in
    pq|pq_reconstruct|hlg) hdr=true ;;
    unknown)
      # Fail closed, same as the real encode (ffmpeg_encode): an
      # unclassifiable Dolby Vision source risks the exact wrong-color bug
      # determine_hdr_mode exists to catch. Guessing SDR here would let a
      # sample-test decision go through even though the real encode of this
      # same file will refuse and flag it for human review anyway. Also
      # flag it (matching ffmpeg_encode) rather than just returning 1 --
      # otherwise this parks in neither bad_sources.txt nor the done-log and
      # silently retries forever instead of surfacing for a person to look
      # at. Found in team review, 2026-07-22.
      flag_bad_source_for_human "$orig_src" "Dolby Vision detected but its profile/base-layer transfer couldn't be confidently classified — sample test cannot proceed"
      return 1
      ;;
    *) hdr=false ;;
  esac

  # Use the exact same CRF the real encode would use, not a generic fixed
  # default: for SDR sources resolve_crf_for_encode runs the same
  # VMAF-targeted search ffmpeg_encode uses, which routinely lands several
  # CRF points higher (a meaningfully smaller file) than profile_fixed_crf.
  # Using the fixed default here systematically under-predicted how much a
  # real SDR encode would shrink some sources, permanently skipping (and
  # VES-tagging) files that genuinely would have benefited -- exactly the
  # false-negative risk the sample test exists to avoid. HDR sources are
  # unaffected (resolve_crf_for_encode already falls back to the same fixed
  # CRF as before for hdr=true). The VMAF search result is cached
  # (VMAF_CRF_CACHE, keyed on src/codec/profile/target-height) and reused
  # verbatim if the real encode of this same file follows, so this doesn't
  # pay the search cost twice. Found in team review, 2026-07-22.
  # Output-variable name must NOT be "crf" -- resolve_crf_for_encode has its
  # own local variable of that exact name, and bash's printf -v (like a
  # nameref) resolves to the INNERMOST scope with that name, so passing
  # "crf" here silently writes to resolve_crf_for_encode's own local instead
  # of this function's, leaving THIS function's $crf permanently unbound.
  # Under this script's `set -u`, the very next reference to $crf (the
  # build_ffmpeg_video_args call below) then kills the current subshell
  # outright -- no graceful nonzero return, no diagnostic, nothing -- which
  # is exactly what made this bug so hard to pin down live: it looks like a
  # silent abort with no failing command in sight. ffmpeg_encode() avoids
  # this correctly by using a differently-named "resolved_crf" local; mirror
  # that here. Found by team investigation, 2026-07-22.
  resolve_crf_for_encode "$orig_src" "$codec" "$profile" "$hdr" resolved_crf || return 1
  crf="$resolved_crf"
  rc=0
  build_ffmpeg_video_args "$codec" "$crf" "$orig_src" "$profile" "$hdr" "$hdr_mode" || rc=$?
  if [ "$rc" -eq 2 ]; then
    # Same rc=2 contract as ffmpeg_encode: Dolby Vision profile 5 with no
    # libplacebo support. The real encode of this file would hit the exact
    # same wall and flag it for human review -- do that here too instead of
    # returning a generic "sample test failed" that gives no indication this
    # needs a person, not a retry.
    flag_bad_source_for_human "$orig_src" "Dolby Vision profile 5 requires libplacebo (not in this ffmpeg build) — sample test cannot proceed"
    return 1
  fi
  [ "$rc" -eq 0 ] || return 1

  case "$codec" in
    av1)  if [ "$FF_HAS_LIBOPUS" = true ]; then acodec=libopus; abr="$OPUS_BITRATE_V5"; else acodec=aac; abr="$AAC_BITRATE_V5"; fi ;;
    hevc) acodec=aac; abr="$AAC_BITRATE_V5" ;;
  esac

  errfile="$(mktemp "${RAMDISK_JOB_DIR:-${TMPDIR:-/tmp}}/.sample-encode-stderr.XXXXXX" 2>/dev/null)" || errfile=/dev/null

  # Map subtitles too (dropped attachments match the clip extraction, which
  # no longer pulls -map 0's global attachments either) so the sample's
  # track composition mirrors both the clip and what the real encode
  # (ffmpeg_encode) actually mixes into its output -- otherwise the
  # encoded/clip size ratio doesn't reflect what a real encode would
  # produce. Found in team review, 2026-07-22.
  args=(-y -nostdin -v warning -i "$clip" -map 0:v:0 -map "0:a?" -map "0:s?" "${FF_VIDEO_ARGS[@]}")
  if [ "${#FF_VF[@]}" -gt 0 ]; then
    vf_joined="$(IFS=,; printf '%s' "${FF_VF[*]}")"
    args+=(-vf "$vf_joined")
  fi
  args+=(-c:a "$acodec" -b:a "$abr" -af "$(ffmpeg_audio_filter_chain "$acodec")")
  if [ "$acodec" = libopus ]; then args+=(-mapping_family 1); fi
  args+=(-c:s copy -f matroska "$dst")

  rc=0
  run_tracked_encoder "ffmpeg sample: $codec" _run_capturing_stderr "$errfile" "${FFMPEG_CMD[@]}" "${args[@]}" || rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "ffmpeg sample encode ($codec) failed (rc=$rc): $(tail -c 2000 "$errfile" 2>/dev/null | tr '\n' ' ')"
  fi
  [ "$errfile" = /dev/null ] || rm -f "$errfile" 2>/dev/null
  return "$rc"
}

encode_sample_av1() {
  local clip="$1"
  local dst="$2"
  local orig_src="$3"
  ffmpeg_sample_encode av1 "$clip" "$dst" "$orig_src" "$PROFILE_CONTEXT"
}

encode_sample_x265() {
  local clip="$1"
  local dst="$2"
  local orig_src="$3"
  ffmpeg_sample_encode hevc "$clip" "$dst" "$orig_src" "$PROFILE_CONTEXT"
}

# Extrapolate full-file size from a mid-file sample encode ratio.
extrapolate_size_from_sample() {
  local orig_full_sz="$1"
  local clip_sz="$2"
  local encoded_sample_sz="$3"
  awk -v o="$orig_full_sz" -v c="$clip_sz" -v e="$encoded_sample_sz" \
    'BEGIN { if (c <= 0) { print 0; exit }; printf "%.0f", o * (e / c) }'
}

# Cheap (no-decode) complexity scan via packet sizes to pick 3 representative
# sample points -- low/median/high local bitrate, used as a free proxy for
# scene complexity/motion (encoders already spend more bits on harder
# content) -- rather than one arbitrary mid-file cut, which could land on a
# uniquely quiet or uniquely busy scene and skew the shrink prediction either
# way. Excludes the first/last excl_secs (default 180s) as opening/closing
# credits rarely represent the body of the content. Prints three start times
# in seconds "low median high" (space-separated), or empty on failure/too
# little usable duration -- caller falls back to a single mid-file sample.
#
# Uses ffprobe -read_intervals to probe ~15 short (10s) sparse windows
# spread across the usable duration, NOT a single continuous packet scan of
# the whole file: a full-file `-show_entries packet=...` scan was measured
# at 3+ minutes and still incomplete on a 7GB 4K title over this fleet's
# NFS -- container demuxing still means reading the whole file's data even
# without decoding frames, so "no decode" alone doesn't make it cheap on a
# large file over a network mount. -read_intervals seeks directly to each
# window via the container's index instead of reading everything in
# between, so cost is bounded by the number of probe windows, not file
# size (measured: ~8s for 32 windows across a 2h42m movie, vs 3+ minutes
# unfinished for the naive full scan). Found in team review, 2026-07-22.
find_complexity_sample_points() {
  local src="$1" dur="$2" excl_secs="${3:-180}"
  local usable_end usable_dur probe_width=10 num_probes=15 max_probes spacing pos i s spec="" starts_str
  local -a probe_starts=()

  usable_end="$(awk -v d="$dur" -v e="$excl_secs" 'BEGIN{r=d-e; if(r<0)r=0; printf "%.0f", r}')"
  usable_dur="$(awk -v s="$excl_secs" -v e="$usable_end" 'BEGIN{r=e-s; if(r<0)r=0; printf "%.0f", r}')"
  [ "$usable_dur" -gt 0 ] 2>/dev/null || return 1

  # Never request more (or narrower-spaced) probes than fit non-overlapping
  # in the usable window -- matters most for short TV episodes.
  max_probes="$(awk -v d="$usable_dur" -v w="$probe_width" 'BEGIN{ n=int(d/w); if(n<1)n=1; print n }')"
  [ "$num_probes" -le "$max_probes" ] || num_probes="$max_probes"
  spacing="$(awk -v d="$usable_dur" -v n="$num_probes" 'BEGIN{ s=d/n; if(s<1)s=1; printf "%.3f", s }')"

  pos="$excl_secs"
  for ((i = 0; i < num_probes; i++)); do
    s="$(awk -v p="$pos" 'BEGIN{printf "%.3f", p}')"
    probe_starts+=("$s")
    spec+="${s}%+${probe_width},"
    pos="$(awk -v p="$pos" -v sp="$spacing" 'BEGIN{printf "%.3f", p+sp}')"
  done
  spec="${spec%,}"
  [ -n "$spec" ] || return 1
  starts_str="${probe_starts[*]}"

  run_ffprobe -v error -select_streams v:0 -read_intervals "$spec" -show_entries packet=pts_time,size -of csv=p=0 "$src" 2>/dev/null | \
    awk -F, -v starts="$starts_str" -v width="$probe_width" '
      BEGIN {
        m = split(starts, arr, " ")
        for (k = 1; k <= m; k++) probe[k-1] = arr[k] + 0
      }
      $1 != "" && $2 != "" {
        t = $1 + 0; sz = $2 + 0
        for (k = 0; k < m; k++) {
          if (t >= probe[k] && t < probe[k] + width) { sum[k] += sz; seen[k] = 1; break }
        }
      }
      END {
        n = 0
        for (k = 0; k < m; k++) { if (seen[k]) order[n++] = k }
        if (n == 0) exit 1
        for (i = 0; i < n; i++) vals[i] = sum[order[i]]
        for (i = 1; i < n; i++) {
          v = vals[i]; j = i - 1
          while (j >= 0 && vals[j] > v) { vals[j+1] = vals[j]; j-- }
          vals[j+1] = v
        }
        med_val = vals[int(n/2)]
        low_k = order[0]; low_v = sum[low_k]
        high_k = order[0]; high_v = sum[high_k]
        best_med_k = order[0]
        best_med_diff = sum[order[0]] - med_val; if (best_med_diff < 0) best_med_diff = -best_med_diff
        for (i = 0; i < n; i++) {
          k = order[i]; v = sum[k]
          if (v < low_v) { low_v = v; low_k = k }
          if (v > high_v) { high_v = v; high_k = k }
          d = v - med_val; if (d < 0) d = -d
          if (d < best_med_diff) { best_med_diff = d; best_med_k = k }
        }
        printf "%.3f %.3f %.3f\n", probe[low_k], probe[best_med_k], probe[high_k]
      }'
}

# Sample AV1 vs x265 at 3 complexity-representative points (low/median/high,
# via find_complexity_sample_points); average their extrapolated full-size
# predictions rather than trusting a single arbitrary mid-file cut. A movie
# that mostly skews toward its low-complexity sample should predict a much
# better reduction than one whose median/high samples dominate -- exactly
# the intuition a single fixed-point sample couldn't capture. Falls back to
# one mid-file sample (the original v5.0.32 behavior) if the complexity scan
# fails or the source is too short to usefully split into 3 windows. Prints
# ONLY: skip | av1 | x265 (stdout is captured by callers). Use log_err for
# messages. Returns 1 only when every sample point failed.
av1_source_reencode_sample_decision() {
  local sample_src="$1"
  local orig_sz="$2"
  local tmp dur sample_len points pick
  local sample_profile saved_profile_context
  local -a starts=() uniq_starts=() pred_av1_pts=() pred_x265_pts=()

  if [ "$DRY_RUN" = true ]; then
    log_err "[dry-run] Would sample 3 complexity points (low/median/high); compare predicted AV1 vs x265 vs original ($(human_size_bytes "$orig_sz"))"
    printf 'skip'
    return 0
  fi

  dur="$(video_duration "$sample_src")"
  sample_len="$SAMPLE_SECONDS"
  is_tv_episode "$sample_src" && sample_len=$((SAMPLE_SECONDS / 2))

  points="$(find_complexity_sample_points "$sample_src" "$dur")" || points=""
  if [ -n "$points" ]; then
    read -r -a starts <<<"$points"
  fi
  if [ "${#starts[@]}" -eq 0 ]; then
    starts=("$(sample_start_middle "$dur")")
  fi

  # Dedup while preserving order -- short/uniform-complexity sources can
  # legitimately collapse low/median/high onto the same window.
  local start seen_key
  local -A seen_starts=()
  for start in "${starts[@]}"; do
    [ -n "$start" ] || continue
    seen_key="${start%.*}"
    [ -n "${seen_starts[$seen_key]:-}" ] && continue
    seen_starts[$seen_key]=1
    uniq_starts+=("$start")
  done

  # || return 1 (E2E review, 2026-07-30): same reasoning as elsewhere -- a
  # bare mktemp failure here would abort under `set -e` before this
  # function's own graceful cleanup/return-1 path ever runs.
  tmp="$(mktemp -d "${RAMDISK_JOB_DIR:-${TMPDIR:-/tmp}}/ves-crf-XXXXXX")" || return 1
  sample_profile="$(profile_for_source "$sample_src")" || { rm -rf "$tmp"; return 1; }
  saved_profile_context="$PROFILE_CONTEXT"
  PROFILE_CONTEXT="$sample_profile"

  local point_idx=0 valid_points=0 clip av1_out x265_out clip_sz av1_sz x265_sz point_rc
  for start in "${uniq_starts[@]}"; do
    point_idx=$((point_idx + 1))
    clip="$tmp/clip_$point_idx.mkv"
    av1_out="$tmp/av1_$point_idx.mkv"
    x265_out="$tmp/x265_$point_idx.mkv"

    log_err "AV1 source sample point $point_idx/${#uniq_starts[@]}: ${sample_len}s at ${start}s of ${dur}s"

    # Only video/audio/subs -- NOT -map 0, which also pulls global
    # attachments (cover art, embedded fonts) into the clip. Those are
    # fixed-size regardless of clip length, so on a title with a large
    # font/attachment set they inflate clip_sz without a matching inflation
    # in the encoded sample (ffmpeg_sample_encode doesn't map attachments
    # either), skewing the encoded/clip ratio and corrupting the
    # extrapolated full-file size prediction. Found in team review, 2026-07-22.
    # run_ffmpeg_validation (timeout-wrapped) -- short sample-clip
    # extraction, same hang risk class fixed 2026-07-29 elsewhere.
    # mp4/m4v/mov -> srt exception, same as try_av1_convert's sub_args --
    # Matroska (this clip's container) cannot hold mov_text, and a blanket
    # "-c copy" would fail the WHOLE clip extraction on any MP4 source
    # with subtitles, not just drop the subtitle track (found in team
    # review, 2026-08-02).
    local clip_sub_codec="copy"
    case "$(to_lower "${sample_src##*.}")" in
      mp4|m4v|mov) clip_sub_codec="srt" ;;
    esac
    if ! run_ffmpeg_validation -y -nostdin -ss "$start" -t "$sample_len" -i "$sample_src" -map 0:v:0 -map "0:a?" -map "0:s?" -c:v copy -c:a copy -c:s "$clip_sub_codec" "$clip" >/dev/null 2>&1; then
      warn "AV1 source sample: ffmpeg could not extract clip at point $point_idx"
      continue
    fi
    if [ ! -s "$clip" ]; then
      warn "AV1 source sample: clip is empty at point $point_idx"
      continue
    fi

    clip_sz="$(file_size_bytes "$clip")"
    [ "$clip_sz" -gt 0 ] || continue

    point_rc=0
    encode_sample_av1 "$clip" "$av1_out" "$sample_src" >/dev/null || point_rc=1
    # A plain `[ cond ] && { ... }` one-liner is NOT safe under this script's
    # `set -e`: when point_rc is already 1, the left-hand test itself fails
    # (its own exit status is 1), and with no trailing `||` on this bare
    # statement, THAT failure alone aborts the entire script immediately --
    # skipping right past the "continue to the next point"/diagnostic-warn
    # logic below. An `if` block is exempt from errexit for its condition
    # regardless of true/false, so it doesn't have this trap. Found live
    # (reproducibly, not a transient NFS issue) testing against Blade Runner
    # 2049, 2026-07-22 -- see feedback_verbose_encoder_diagnostics memory.
    if [ "$point_rc" -eq 0 ]; then
      encode_sample_x265 "$clip" "$x265_out" "$sample_src" >/dev/null || point_rc=1
    fi
    if [ "$point_rc" -ne 0 ] || [ ! -s "$av1_out" ] || [ ! -s "$x265_out" ]; then
      warn "AV1 source sample: encode failed at point $point_idx"
      continue
    fi

    av1_sz="$(file_size_bytes "$av1_out")"
    x265_sz="$(file_size_bytes "$x265_out")"
    pred_av1_pts+=("$(extrapolate_size_from_sample "$orig_sz" "$clip_sz" "$av1_sz")")
    pred_x265_pts+=("$(extrapolate_size_from_sample "$orig_sz" "$clip_sz" "$x265_sz")")
    valid_points=$((valid_points + 1))
    log_err "Point $point_idx sizes: clip=$(human_size_bytes "$clip_sz") av1=$(human_size_bytes "$av1_sz") x265=$(human_size_bytes "$x265_sz")"
  done

  PROFILE_CONTEXT="$saved_profile_context"
  rm -rf "$tmp"

  if [ "$valid_points" -eq 0 ]; then
    return 1
  fi

  local pred_av1 pred_x265
  pred_av1="$(printf '%s\n' "${pred_av1_pts[@]}" | awk '{s+=$1; n++} END{ printf "%.0f", s/n }')"
  pred_x265="$(printf '%s\n' "${pred_x265_pts[@]}" | awk '{s+=$1; n++} END{ printf "%.0f", s/n }')"

  log_err "Averaged $valid_points/${#uniq_starts[@]} sample point(s) — predicted full size: AV1=$(human_size_bytes "$pred_av1") x265=$(human_size_bytes "$pred_x265") original=$(human_size_bytes "$orig_sz")"

  if awk -v a="$pred_av1" -v x="$pred_x265" -v o="$orig_sz" 'BEGIN { exit !((a >= o) && (x >= o)) }'; then
    printf 'skip'
    return 0
  fi

  pick=skip
  if awk -v p="$pred_av1" -v o="$orig_sz" 'BEGIN { exit !(p < o) }'; then
    pick=av1
  fi
  if awk -v p="$pred_x265" -v o="$orig_sz" 'BEGIN { exit !(p < o) }'; then
    if [ "$pick" = skip ]; then
      pick=x265
    elif awk -v a="$pred_av1" -v x="$pred_x265" 'BEGIN { exit !(x < a) }'; then
      pick=x265
    fi
  fi

  printf '%s' "$pick"
  return 0
}

vmaf_model_for_source() {
  local h
  h="$(video_height "$1")"
  if [ "${h:-0}" -gt 1600 ]; then
    printf 'version=vmaf_4k_v0.6.1'
  else
    printf 'version=vmaf_v0.6.1neg'
  fi
}

vmaf_target_for_source() {
  local src="$1"
  local h profile
  h="$(video_height "$src")"
  if [ "${h:-0}" -gt 1600 ]; then printf '%s' "$VMAF_TARGET_4K"; return; fi
  profile="$(profile_for_source "$src")" || return $?
  case "$profile" in
    wanime) printf '%s' "$VMAF_TARGET_WANIME" ;; anime) printf '%s' "$VMAF_TARGET_ANIME" ;;
    canime) printf '%s' "$VMAF_TARGET_CANIME" ;;
    movies) printf '%s' "$VMAF_TARGET_MOVIE" ;; classic) printf '%s' "$VMAF_TARGET_CLASSIC" ;;
    vintage) printf '%s' "$VMAF_TARGET_VINTAGE" ;; mtv) printf '%s' "$VMAF_TARGET_MTV" ;;
    vtv) printf '%s' "$VMAF_TARGET_VTV" ;;
  esac
}

fixed_crf_for() {
  profile_fixed_crf "$1" "$2" "$3"
}

# One sample-encode + VMAF score. Prints "vmaf bytes". Messages go to stderr.
# v5.0.29: encodes the probe with the SAME profile-specific svtav1-params /
# x265-params the final encode will use (via svtav1_profile_extras), not just
# base params -- otherwise the CRF chosen here doesn't reflect what film-grain
# synthesis/variance-boost/etc actually cost in the real encode. For profiles
# with real AV1 film-grain synthesis, also decodes the probe with
# -export_side_data film_grain so libvmaf scores the true encoded quality
# rather than being corrupted by pseudo-random, source-misaligned synthesized
# grain (see svtav1_profile_uses_grain_synthesis).
_vmaf_score_one() {  # clip crf codec model profile target_height
  local clip="$1" crf="$2" codec="$3" model="$4"
  local profile="$5" target_height="${6:-0}"
  local out vlog v svtp x265p x265_tune scale_filter="" ref_filter=""
  local -a grain_decode_flag=()
  local -a encode_filter=()
  out="${clip%.mkv}-enc-$codec-$crf.mkv"
  vlog="${out%.mkv}.vmaf.json"
  case "$target_height" in
    720) scale_filter='scale=1280:720:flags=lanczos:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2' ;;
    1080) scale_filter='scale=1920:1080:flags=lanczos:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2' ;;
  esac
  [ -n "$scale_filter" ] && encode_filter=(-vf "$scale_filter")
  ref_filter="${scale_filter:+$scale_filter,}setpts=PTS-STARTPTS,format=yuv420p10le"
  # run_ffmpeg_validation (timeout-wrapped), not bare run_ffmpeg, for both the
  # sample-clip encode and the VMAF scoring pass below -- these operate on a
  # single short clip (VMAF_SAMPLE_SECS), never a real multi-hour encode, so
  # a generous bounded timeout is safe here (unlike the actual full-file
  # encode elsewhere, which is deliberately left unbound). Found 2026-07-29:
  # a crashed SVT-AV1 encoder worker thread (SIGSEGV, confirmed via kernel
  # log on GruntBox2's non-AVX2 hardware) left ffmpeg's main thread
  # deadlocked waiting on it instead of exiting; with no timeout, the whole
  # batch script blocked on this one call indefinitely with no recovery.
  case "$codec" in
    av1)
      svtp="$(profile_svt_params "$profile")"
      run_ffmpeg_validation -y -v error -i "$clip" "${encode_filter[@]}" -c:v libsvtav1 -preset "$SVT_PRESET_SEARCH" -crf "$crf" \
        -pix_fmt yuv420p10le -svtav1-params "$svtp" -an "$out" 2>/dev/null || return 1
      if svtav1_profile_uses_grain_synthesis "$profile"; then
        grain_decode_flag=(-export_side_data film_grain)
      fi
      ;;
    hevc)
      x265p="$(profile_x265_params "$profile")"
      # tune is NOT an x265-params key -- see profile_x265_tune.
      x265_tune="$(profile_x265_tune "$profile")" || x265_tune=""
      run_ffmpeg_validation -y -v error -i "$clip" "${encode_filter[@]}" -c:v libx265 -preset medium -crf "$crf" \
        -pix_fmt yuv420p10le -x265-params "$x265p" ${x265_tune:+-tune "$x265_tune"} -an "$out" 2>/dev/null || return 1 ;;
  esac
  run_ffmpeg_validation -y -v error "${grain_decode_flag[@]}" -i "$out" -i "$clip" -lavfi \
    "[0:v]setpts=PTS-STARTPTS,format=yuv420p10le[d];[1:v]$ref_filter[r];[d][r]libvmaf=model=$model:n_threads=$(nproc 2>/dev/null || sysctl -n hw.ncpu):log_fmt=json:log_path=$vlog" \
    -f null - 2>/dev/null || return 1
  v="$(python3 -c "import json;print(round(json.load(open('$vlog'))['pooled_metrics']['vmaf']['mean'],2))" 2>/dev/null)" || return 1
  printf '%s %s' "$v" "$(file_size_bytes "$out")"
}

# Per-title CRF search. Prints "crf predicted_bytes achieved_vmaf" or fails.
# Internal engine — used when ab-av1 is absent, and always for grain-
# synthesizing AV1 profiles (see resolve_crf_for_encode).
vmaf_crf_search_internal() {  # src codec target model profile target_height
  local src="$1" codec="$2" target="$3" model="$4"
  local profile="$5" target_height="${6:-0}"
  local work dur clip_bytes=0 i start clip
  local -a clips=()
  local -A score=() bytes=()
  # || return 1 (E2E review, 2026-07-30): same reasoning as elsewhere in
  # this function's sibling sample-encode helpers.
  work="$(mktemp -d "${RAMDISK_JOB_DIR:-${TMPDIR:-/tmp}}/ves-crf-XXXXXX")" || return 1

  dur="$(video_duration "$src")"
  dur="${dur%.*}"
  [ -n "$dur" ] && [ "$dur" -ge $(( VMAF_SAMPLE_SECS * 3 )) ] || { rm -rf "$work"; return 1; }
  # short sources: fewer samples rather than no search
  local nsamples="$VMAF_SAMPLES"
  while [ "$nsamples" -gt 1 ] && [ "$dur" -lt $(( VMAF_SAMPLE_SECS * nsamples * 2 )) ]; do
    nsamples=$(( nsamples - 1 ))
  done

  for ((i = 1; i <= nsamples; i++)); do
    start=$(( dur * (i * 2 - 1) / (nsamples * 2) ))
    clip="$work/clip$i.mkv"
    # run_ffmpeg_validation (timeout-wrapped), not bare run_ffmpeg -- a short
    # stream-copy clip extraction should complete quickly regardless of
    # source size, but a stalled NFS read here can otherwise hang the whole
    # batch indefinitely, same class of gap as validate_mkv_decode_windows
    # (2026-07-22 team review). Found 2026-07-29: a crashed SVT-AV1 worker
    # thread deadlocking the sample-encode step below (never reaching this
    # call, but same unguarded-run_ffmpeg root cause) silently hung an
    # entire fleet machine's batch for hours with no recovery.
    run_ffmpeg_validation -y -v error -ss "$start" -t "$VMAF_SAMPLE_SECS" -i "$src" \
      -map 0:v:0 -c copy "$clip" 2>/dev/null || { rm -rf "$work"; return 1; }
    [ -s "$clip" ] || { rm -rf "$work"; return 1; }
    clips+=("$clip")
    clip_bytes=$(( clip_bytes + $(file_size_bytes "$clip") ))
  done

  _probe_crf() {  # crf -> populates score/bytes; totals across all samples
    local crf="$1" vsum=0 btot=0 c r v b
    [ -n "${score[$crf]:-}" ] && return 0
    for c in "${clips[@]}"; do
      r="$(_vmaf_score_one "$c" "$crf" "$codec" "$model" "$profile" "$target_height")" || return 1
      v="${r%% *}"; b="${r##* }"
      vsum="$(awk -v a="$vsum" -v x="$v" 'BEGIN{print a+x}')"
      btot=$(( btot + b ))
    done
    score[$crf]="$(awk -v s="$vsum" -v n="${#clips[@]}" 'BEGIN{printf "%.2f", s/n}')"
    bytes[$crf]=$btot
    log_err "  crf-search [$codec] crf=$crf vmaf=${score[$crf]}"
  }

  # Coarse anchors, then bisect the target crossing.
  local anchors="22 30 38" crf above below gap
  for crf in $anchors; do _probe_crf "$crf" || { rm -rf "$work"; return 1; }; done
  for i in 1 2 3; do
    above=""; below=""
    for crf in $(printf '%s\n' "${!score[@]}" | sort -n); do
      if awk -v s="${score[$crf]}" -v t="$target" 'BEGIN{exit !(s>=t)}'; then above="$crf"; else below="$crf"; break; fi
    done
    if [ -z "$above" ]; then _probe_crf "$VMAF_SEARCH_MIN_CRF" || break; continue; fi
    if [ -z "$below" ]; then _probe_crf "$VMAF_SEARCH_MAX_CRF" || break; continue; fi
    gap=$(( below - above )); [ "$gap" -le 1 ] && break
    _probe_crf $(( above + gap / 2 )) || break
  done

  local best="" bv="" bb=""
  local closest="" cv="" cb=""
  for crf in $(printf '%s\n' "${!score[@]}" | sort -n); do
    if awk -v s="${score[$crf]}" -v t="$target" 'BEGIN{exit !(s>=t)}'; then
      best="$crf"; bv="${score[$crf]}"; bb="${bytes[$crf]}"
    fi
    # Track the highest-VMAF sample seen regardless of target, so a
    # search that never reaches target still has a real fallback to
    # offer below (2026-08-16 fix — see comment below).
    if [ -z "$cv" ] || awk -v s="${score[$crf]}" -v c="$cv" 'BEGIN{exit !(s>c)}'; then
      closest="$crf"; cv="${score[$crf]}"; cb="${bytes[$crf]}"
    fi
  done
  rm -rf "$work"
  if [ -z "$best" ]; then
    # No sampled CRF reached target -- use the best (highest-VMAF)
    # sample actually measured instead of discarding it: the caller's
    # own fallback (fixed_crf_for, a static per-profile constant
    # disconnected from this content) can be, and in practice was,
    # WORSE than a CRF this search already tested and scored. Found
    # 2026-08-16 auditing a real production failure: Stargate Universe
    # S01E18 sampled crf=16->vmaf=87.23 (above the 85 below-floor
    # threshold, close to the 90 target) but this function returned 1
    # anyway, so the caller fell back to profile_fixed_crf's static
    # crf=26 for the real encode -- producing a final measured VMAF of
    # 33.7, far worse than what crf=16 had already demonstrated. Still
    # returns 1 (triggering the static fallback) only when literally no
    # sample ever succeeded, since there is nothing measured to fall
    # back to in that case.
    best="$closest"; bv="$cv"; bb="$cb"
  fi
  [ -n "$best" ] || return 1
  local orig pred
  orig="$(file_size_bytes "$src")"
  pred="$(awk -v o="$orig" -v c="$clip_bytes" -v e="$bb" 'BEGIN{ if (c<=0) {print 0; exit}; printf "%d", o*(e/c) }')"
  printf '%s %s %s' "$best" "$pred" "$bv"
}

# ab-av1 crf-search wrapper. Prints "crf predicted_size achieved_vmaf".
# Final stdout line: "crf 21.25 VMAF 94.19 predicted video stream size 22.47 MiB (17%) taking 60 seconds"
# Never called for AV1 + a grain-synthesizing profile (anime/vintage) -- see
# resolve_crf_for_encode. wanime's non-grain extras (sharpness) ARE passed
# through via --svt so the search still matches the final encode's params.
vmaf_crf_search_abav1() {  # src codec target model profile target_height
  local src="$1" codec="$2" target="$3" model="$4" profile="$5" target_height="${6:-0}"
  local enc preset out line crf vmaf pred params kv p vfilter="" x265_tune
  local -a profile_args=() vfilter_args=()
  case "$target_height" in
    720) vfilter='scale=1280:720:flags=lanczos:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2' ;;
    1080) vfilter='scale=1920:1080:flags=lanczos:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2' ;;
  esac
  [ -n "$vfilter" ] && vfilter_args=(--vfilter "$vfilter")
  case "$codec" in
    av1)
      enc="libsvtav1"; preset="$SVT_PRESET_SEARCH"
      params="$(profile_svt_params "$profile")"
      IFS=':' read -ra kv <<<"$params"
      for p in "${kv[@]}"; do profile_args+=(--svt "$p"); done
      ;;
    hevc)
      enc="libx265"; preset="medium"
      profile_args+=(--enc "x265-params=$(profile_x265_params "$profile")")
      # tune is NOT an x265-params key (see profile_x265_tune) -- ab-av1's
      # --enc passes key=value straight through as ffmpeg's own -key value
      # AVOption, so a separate --enc tune=... entry (not folded into the
      # x265-params= value above) is required for it to actually apply.
      x265_tune="$(profile_x265_tune "$profile")" || x265_tune=""
      [ -n "$x265_tune" ] && profile_args+=(--enc "tune=$x265_tune")
      ;;
  esac
  # Timeout-wrapped (2026-07-29), same reasoning as vmaf_crf_search_internal's
  # run_ffmpeg_validation calls -- ab-av1 shells out to ffmpeg internally for
  # each sample, and a crashed/deadlocked encoder worker thread there would
  # otherwise hang this call (and the whole batch) indefinitely with no
  # timeout to catch it. Size-scaled via _validation_timeout_for_args off
  # the full source ("-i $src" is present in the arg list below) since
  # ab-av1 seeks across the real source for each of its samples.
  out="$(_run_timeout_retry "$(_validation_timeout_for_args -i "$src")" \
          "$AB_AV1_BIN" crf-search -i "$src" -e "$enc" --preset "$preset" "${profile_args[@]}" "${vfilter_args[@]}" \
          --min-vmaf "$target" --min-crf "$VMAF_SEARCH_MIN_CRF" --max-crf "$VMAF_SEARCH_MAX_CRF" \
          --sample-duration "${VMAF_SAMPLE_SECS}s" --samples "$VMAF_SAMPLES" \
          --vmaf "model=$model" 2>/dev/null)" || return 1
  line="$(printf '%s\n' "$out" | grep -E '^crf [0-9.]+ VMAF' | tail -1)"
  # CRFs can be fractional (21.25) — round DOWN (lower CRF = safer/higher quality)
  crf="$(printf '%s' "$line" | sed -n 's/^crf \([0-9.]*\) .*/\1/p' | awk '{printf "%d", $1}')"
  vmaf="$(printf '%s' "$line" | sed -n 's/.*VMAF \([0-9.]*\).*/\1/p')"
  pred="$(printf '%s' "$line" | sed -n 's/.*predicted video stream size \([0-9.]*[[:space:]]*[KMGT]iB\).*/\1/p' | tr -d ' ')"
  [ -n "$crf" ] || return 1
  printf '%s %s %s' "$crf" "${pred:-0}" "${vmaf:-0}"
}

# Resolve the CRF for a source+codec. Resolution is part of the cache key:
# 720p and 1080p are different encode decisions for the same title/profile.
resolve_crf_for_encode() {  # src codec profile hdr [output-variable]
  local src="$1" codec="$2" profile="$3" hdr="$4"
  local outvar="${5:-}" target_height key target model res crf pred vmaf
  resolve_upscale_target "$src"
  target_height="$UPSCALE_TARGET_HEIGHT"
  key="${codec}:${profile}:${target_height}:${src}"

  if [ -n "${VMAF_CRF_CACHE[$key]:-}" ]; then
    if [ -n "$outvar" ]; then printf -v "$outvar" '%s' "${VMAF_CRF_CACHE[$key]}"; else printf '%s' "${VMAF_CRF_CACHE[$key]}"; fi
    return 0
  fi

  if [ "$hdr" = true ] || [ "$VMAF_DISABLED" = true ] || [ "$FF_HAS_LIBVMAF" != true ]; then
    crf="$(fixed_crf_for "$codec" "$profile" "$hdr")"
    [ "$hdr" = true ] && log_err "HDR source — fixed CRF $crf (VMAF unreliable on PQ/HLG)" \
                      || log_err "Fixed CRF $crf ($codec, $profile, output=${target_height:-0}p)"
    VMAF_CRF_CACHE[$key]="$crf"
    if [ -n "$outvar" ]; then printf -v "$outvar" '%s' "$crf"; else printf '%s' "$crf"; fi
    return 0
  fi

  target="$(vmaf_target_for_source "$src")" || target=""
  model="$(vmaf_model_for_source "$src")"
  if [ -z "$target" ]; then
    crf="$(fixed_crf_for "$codec" "$profile" "$hdr")"
    log_err "Cannot resolve VMAF target for $src (profile undetectable/ambiguous) — fixed CRF $crf"
    VMAF_CRF_CACHE[$key]="$crf"
    if [ -n "$outvar" ]; then printf -v "$outvar" '%s' "$crf"; else printf '%s' "$crf"; fi
    return 0
  fi
  if [ "$DRY_RUN" = true ]; then
    crf="$(fixed_crf_for "$codec" "$profile" "$hdr")"
    log_err "[dry-run] Would VMAF-search CRF (target=$target model=${model#version=}); reporting fixed CRF $crf"
    VMAF_CRF_CACHE[$key]="$crf"
    if [ -n "$outvar" ]; then printf -v "$outvar" '%s' "$crf"; else printf '%s' "$crf"; fi
    return 0
  fi
  log_err "VMAF CRF search: target=$target model=${model#version=} codec=$codec"
  # Grain-synthesizing AV1 profiles cannot use ab-av1: its
  # own internal VMAF scoring has no way to disable synthesized-grain decode
  # (confirmed against ab-av1 GitHub issue #139, open/unfixed as of 0.11.4),
  # so pseudo-random synthesized grain corrupts the score there just as it
  # would corrupt ours. Always use the internal search for those, which
  # strips grain via -export_side_data film_grain before scoring.
  if [ -n "$AB_AV1_BIN" ] && { [ "$codec" != av1 ] || ! svtav1_profile_uses_grain_synthesis "$profile"; }; then
    res="$(vmaf_crf_search_abav1 "$src" "$codec" "$target" "$model" "$profile" "$target_height")" || res=""
  fi
  if [ -z "${res:-}" ]; then
    res="$(vmaf_crf_search_internal "$src" "$codec" "$target" "$model" "$profile" "$target_height")" || res=""
  fi
  if [ -z "$res" ]; then
    crf="$(fixed_crf_for "$codec" "$profile" "$hdr")"
    warn "VMAF search failed or no CRF met target — fixed CRF $crf"
  else
    read -r crf pred vmaf <<<"$res"
    # >= target is the common case; the internal search's below-target
    # fallback (2026-08-16, see its own comment) can hand back a sample
    # that never reached target — log that distinctly rather than
    # falsely claiming it met target.
    local _met_target="< $target (search never converged — best sample used)"
    awk -v s="$vmaf" -v t="$target" 'BEGIN{exit !(s>=t)}' && _met_target=">= $target"
    case "$pred" in
      *iB) log_err "VMAF search chose CRF $crf (sample VMAF $vmaf $_met_target; predicted video ~$pred)" ;;
      *)   log_err "VMAF search chose CRF $crf (sample VMAF $vmaf $_met_target; predicted $(human_size_bytes "${pred:-0}"))" ;;
    esac
  fi
  VMAF_CRF_CACHE[$key]="$crf"
  if [ -n "$outvar" ]; then printf -v "$outvar" '%s' "$crf"; else printf '%s' "$crf"; fi
}
