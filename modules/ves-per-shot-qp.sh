#!/usr/bin/env bash
# ves-per-shot-qp.sh -- Phase 6 of the chunk-parallel + per-shot dynamic
# optimization initiative: real per-shot VMAF-target QP search, reusing
# ves-vmaf-crf-search.sh's proven bounded-bisection pattern
# (vmaf_crf_search_internal/_vmaf_score_one) at shot granularity instead
# of a handful of samples spread across a whole file.
#
# Depends on Phase 5 (ves-scene-detect.sh, scene_detect_boundaries()) for
# real shot boundaries, and on the standalone SvtAv1EncApp CLI's
# --qpfile/--use-q-file mechanism (confirmed live 2026-08-24 to work
# correctly -- a real ~3.3x bitrate difference between QP 10 and QP 50 on
# the same clip -- unlike ffmpeg's -svtav1-params passthrough, which
# silently ignores it; see docs/DESIGN-6x-chunk-redesign.md) for how the
# resolved per-shot QPs actually get applied: ONE continuous encode per
# work-unit, with a per-frame QP file built from these results, not a
# separate encoded file per shot. That was tested and compared directly
# against the alternative (independent per-shot files spliced via the
# Layer-1 seam mechanism) on a real 199-shot/809s episode: the seam
# approach broke catastrophically at this granularity (VMAF 2.26, vs
# 85.32 for the qpfile approach using the same per-shot QP values) --
# see the same design doc section for the full comparison.

# run_ffmpeg_validation's timeout curve (_validation_timeout_for_args) scales
# off the INPUT FILE'S SIZE, calibrated for fast structural validation and
# stream-copy work -- it has nothing to do with how long a real CPU-bound
# encode takes. A short shot clip is tiny on disk (a few MB) but a genuinely
# complex shot at preset 8 with film-grain synthesis enabled can still take
# several minutes to encode (SVT-AV1 itself warns film-grain>0 above preset 6
# has "significant compute overhead"), so the size-scaled timeout comes out
# far too short for the actual encode/VMAF-measurement steps below. Found
# live 2026-08-24: shot 22 of the Yama no Susume S02E12 test episode (5.88s,
# 1080p, heavy motion) took ~5 minutes to encode a single QP candidate on
# JJACKSON -- well past the ~121s the size-based curve computed for its
# ~6MB extracted clip -- so the encode got killed mid-run and the shot
# silently fell back to the static fixed-QP default, defeating the entire
# point of per-shot search for exactly the shots most likely to need it.
# Scales off the shot's own duration instead: real encode/VMAF cost tracks
# how much video there is, not how many bytes the (post-copy, pre-encode)
# clip happens to occupy.
_shot_ffmpeg_timeout() {
  local duration="$1" base=300 per_sec=120 cap=3600
  local d_int extra scaled
  d_int="$(printf '%.0f' "$duration" 2>/dev/null)"
  case "$d_int" in ''|*[!0-9]*) d_int=0 ;; esac
  extra=$(( d_int * per_sec ))
  scaled=$(( base + extra ))
  [ "$scaled" -gt "$cap" ] && scaled="$cap"
  printf '%s' "$scaled"
}

# Resolves the standalone SvtAv1EncApp binary. Kept separate from
# discover_tools()'s shared startup checklist/banner (ves-tool-discovery.sh)
# since it's only ever needed for Phase 6 (per-shot search + the final
# qpfile-driven encode), not the general whole-file pipeline every run goes
# through -- a machine that's never touched Phase 6 shouldn't fail its
# checklist over a tool it doesn't need yet. Fleet-wide install location is
# fixed (/usr/bin/SvtAv1EncApp, built from source at a pinned commit -- see
# the fleet parity note below), so a plain PATH lookup is enough.
SVTAV1ENCAPP_CMD=()
discover_svtav1encapp() {
  [ "${#SVTAV1ENCAPP_CMD[@]}" -gt 0 ] && return 0
  local tool
  tool="$(command -v SvtAv1EncApp 2>/dev/null)" || return 1
  SVTAV1ENCAPP_CMD=("$tool")
  return 0
}

# Scores one shot at one candidate QP: encodes the shot's own real frame
# range (stream-copy extracted, not re-decoded first) at a HARD uniform
# QP via the exact same mechanism the final application uses (SvtAv1EncApp
# --qpfile, all frames set to the same value), not ffmpeg's -qp flag.
#
# 2026-08-25: this used to use `ffmpeg -c:v libsvtav1 -qp X` -- reasonable
# on its face (both are "the same SVT-AV1 library, just a different QP
# value"), but a real controlled experiment (same isolated clip, same exact
# QP, both encode paths) found ffmpeg's -qp wrapper and the standalone
# --qpfile mechanism do NOT deliver equivalent quality for the same nominal
# QP -- a real, substantial, consistent gap (mean ~8 VMAF points across a
# 6-shot sample, larger than the whole-file target-vs-actual gap this was
# found while investigating). A separate context-padding fix was tried
# first and made things worse, not better, before this was found -- the
# real bug was never "context," it was that the search was calibrating
# against a DIFFERENT encode code path than the one the final continuous
# encode actually uses. Now both use identical SvtAv1EncApp --qpfile
# invocations (a uniform one-QP-per-frame file here; a real varying one in
# the final assembled encode), so whatever quirk distinguishes the two
# paths no longer matters -- the search is calibrated against reality by
# construction, not by guessing at the cause.
#
# Requires SvtAv1EncApp to be fleet-wide version-pinned the same way
# ffmpeg's libsvtav1 already is (see feedback_svtav1_version_constant) --
# confirmed 2026-08-25 the distro-packaged binary on at least one fleet
# machine was a mismatched, much older build entirely missing features the
# real encode depends on (variance-boost, sharpness). Every machine running
# this function must have the fleet-pinned SvtAv1EncApp built from source
# and installed to /usr/bin, not whatever a package manager happens to
# provide.
# Prints "vmaf bytes" or fails.
_vmaf_score_shot() {
  local src="$1" start="$2" end="$3" qp="$4" codec="$5" model="$6" profile="$7"
  local work clip y4m out out_mkv vlog v b enc_timeout nframes qpfile
  local -a grain_decode_flag=()
  discover_svtav1encapp || return 1
  work="$(mktemp -d "${RAMDISK_JOB_DIR:-${TMPDIR:-/tmp}}/ves-shotqp-XXXXXX")" || return 1
  clip="$work/shot.mkv"
  # Extraction of a boundary-precise LOSSLESS clip. Two real constraints,
  # each learned the hard way:
  #
  #  1) (2026-08-25, Star Trek Discovery per-shot search) pre-input
  #     -ss/-to + `-c copy` cannot cut mid-GOP -- it snaps the END up to
  #     the next keyframe, overshooting a short shot by 1.5-3x (28->74,
  #     212->296 frames on two real shots), feeding junk trailing content
  #     into every VMAF probe and inflating every recorded byte cost (the
  #     equal-slope allocator's own lambda-bisection input). The cut must
  #     be a real decode into an ffv1 re-encode, never a stream copy.
  #
  #  2) (2026-08-28, Raised by Wolves regional-survey search) a bare
  #     post-input `-ss "$start"` with no pre-input seek makes ffmpeg
  #     demux from frame 0 to $start every call -- for a shot ~20 min into
  #     a ~40 min episode that is ~1200 s of throwaway lossless decode per
  #     probe, several probes per shot. Seen live at 5+ min per 2 s shot,
  #     fleet load average ~3x core count.
  #
  # Fix for (2), keeping (1): two-stage seek. Fast pre-input -ss to a
  # keyframe a safe margin (30 s, comfortably longer than any real GOP)
  # BEFORE the target, then an accurate post-input -ss for exactly that
  # margin, then -t for the exact duration. ffmpeg's post-input -ss is
  # frame-accurate regardless of where the preceding fast seek landed, as
  # long as it landed at/before the target frame -- which a
  # nearest-preceding-keyframe seek guarantees -- so the output is
  # frame-identical to the single-stage accurate seek from (1)
  # (re-verified frame-exact 2026-08-28). Use -t (duration), not -to
  # (absolute ts): -to's meaning after a post-input -ss varies by ffmpeg
  # version.
  local _seek_margin=30 _fast_ss _acc_ss _clip_dur
  _fast_ss="$(awk -v s="$start" -v m="$_seek_margin" 'BEGIN{ f=s-m; if(f<0)f=0; printf "%.6f", f }')"
  _acc_ss="$(awk -v s="$start" -v f="$_fast_ss" 'BEGIN{ printf "%.6f", s-f }')"
  _clip_dur="$(awk -v s="$start" -v e="$end" 'BEGIN{ d=e-s; if(d<0)d=0; printf "%.6f", d }')"
  run_ffmpeg_validation -y -v error -ss "$_fast_ss" -i "$src" -ss "$_acc_ss" -t "$_clip_dur" \
    -map 0:v:0 -c:v ffv1 -level 3 "$clip" 2>/dev/null || { rm -rf "$work"; return 1; }
  [ -s "$clip" ] || { rm -rf "$work"; return 1; }
  enc_timeout="$(_shot_ffmpeg_timeout "$(awk -v s="$start" -v e="$end" 'BEGIN{d=e-s; if(d<0)d=0; print d}')")"
  case "$codec" in
    av1)
      local svtp; svtp="$(profile_svt_params "$profile")" || { rm -rf "$work"; return 1; }
      y4m="$work/shot.y4m"
      run_ffmpeg_validation -y -v error -i "$clip" -map 0:v:0 -pix_fmt yuv420p10le -strict -1 "$y4m" 2>/dev/null \
        || { rm -rf "$work"; return 1; }
      nframes="$("${FFPROBE_CMD[@]}" -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$clip" 2>/dev/null)"
      [[ "$nframes" =~ ^[0-9]+$ ]] && [ "$nframes" -gt 0 ] || { rm -rf "$work"; return 1; }
      qpfile="$work/uniform-$qp.qp"
      yes "$qp" 2>/dev/null | head -n "$nframes" > "$qpfile"
      out="$work/shot-enc-$qp.ivf"
      _run_timeout_retry "$enc_timeout" "${SVTAV1ENCAPP_CMD[@]}" -i "$y4m" --use-q-file 1 --qpfile "$qpfile" \
        --svtav1-params "${svtp}:rc=0" -b "$out" 2>/dev/null || { rm -rf "$work"; return 1; }
      [ -s "$out" ] || { rm -rf "$work"; return 1; }
      out_mkv="$work/shot-enc-$qp.mkv"
      run_ffmpeg_validation -y -v error -i "$out" -c copy "$out_mkv" 2>/dev/null || { rm -rf "$work"; return 1; }
      svtav1_profile_uses_grain_synthesis "$profile" && grain_decode_flag=(-export_side_data film_grain)
      ;;
    *) rm -rf "$work"; return 1 ;;
  esac
  vlog="${out}.vmaf.json"
  _run_timeout_retry "$enc_timeout" "${FFMPEG_CMD[@]}" -y -v error "${grain_decode_flag[@]}" -i "$out_mkv" -i "$clip" -lavfi \
    "[0:v]setpts=PTS-STARTPTS,format=yuv420p10le[d];[1:v]setpts=PTS-STARTPTS,format=yuv420p10le[r];[d][r]libvmaf=model=$model:n_threads=$(nproc 2>/dev/null || sysctl -n hw.ncpu):log_fmt=json:log_path=$vlog" \
    -f null - 2>/dev/null || { rm -rf "$work"; return 1; }
  v="$(python3 -c "import json;print(round(json.load(open('$vlog'))['pooled_metrics']['vmaf']['mean'],2))" 2>/dev/null)" || { rm -rf "$work"; return 1; }
  b="$(file_size_bytes "$out")"
  rm -rf "$work"
  printf '%s %s' "$v" "$b"
}

# Linear interpolation between two real, bracketing (QP,VMAF) samples to
# predict which QP's VMAF should land closest to target -- ported from
# Av1an's real target-quality search (av1an-core/src/target_quality.rs
# predict_quantizer(), the n==2-history case), used here once >=2 real
# samples bracket the target instead of blindly bisecting the QP range.
# Clamped strictly inside (above_qp, below_qp) so it can never repeat an
# already-probed point or extrapolate past the known-bracketing pair.
_interp_qp() {
  local above_qp="$1" above_score="$2" below_qp="$3" below_score="$4" target="$5"
  awk -v aq="$above_qp" -v as="$above_score" -v bq="$below_qp" -v bs="$below_score" -v t="$target" '
    BEGIN {
      # No integer strictly between aq and bq -- callers guard against this
      # (the gap<=1 check breaks the search loop before ever calling this
      # function), but degenerate input would otherwise double-clamp and
      # bounce back to aq below; return aq directly instead.
      if (bq - aq <= 1) { print aq; exit; }
      if (bs == as) { q = int((aq + bq) / 2 + 0.5); }
      else { q = aq + (t - as) * (bq - aq) / (bs - as); q = int(q + 0.5); }
      if (q <= aq) q = aq + 1;
      if (q >= bq) q = bq - 1;
      print q;
    }'
}

# Bounded search for one shot -- anchors match vmaf_crf_search_internal()'s
# shape (QP instead of CRF), refinement steps use curve interpolation
# instead of blind bisection to reach the same guaranteed-optimal (gap<=1)
# answer faster (see _interp_qp() above and the comment inline below).
# Scored via _vmaf_score_shot() instead of sampling several clips. Prints
# "qp achieved_vmaf samples" (3 whitespace-separated fields -- parse with
# `read -r qp vmaf samples <<<"$result"`, NOT the old first/last-field
# shortcut) or fails (caller should fall back to a fixed default QP for
# this shot, same "search failed, don't block the pipeline" philosophy
# resolve_crf_for_encode() already uses for whole-file search). `samples`
# is every (qp,vmaf,bytes) this call actually probed, comma-joined
# "qp:vmaf:bytes" entries -- feeds the Phase 6.1 equal-slope allocator's
# per-shot rate-distortion data (the search already produces these as a
# side effect of finding its own winner; this just stops discarding them).
#
# LAST_SHOT_SEARCH_SAMPLES below is populated during the search purely as
# this function's own internal accumulator for building that 3rd field --
# NOT a usable side-channel for callers. Every real caller invokes this
# function via $(...) command substitution, which forks a subshell; a
# global written inside that subshell never reaches the caller. Found
# live 2026-08-25: an earlier version of this comment described the
# global itself as the intended hand-off mechanism, and it was silently
# always empty in every caller as a result.
LAST_SHOT_SEARCH_SAMPLES=()

resolve_per_shot_qp() {
  local src="$1" start="$2" end="$3" codec="$4" target="$5" model="$6" profile="$7"
  local -A score=() bytes=()
  local qp above below gap
  LAST_SHOT_SEARCH_SAMPLES=()

  _probe_qp() {
    local q="$1" r
    [ -n "${score[$q]:-}" ] && return 0
    r="$(_vmaf_score_shot "$src" "$start" "$end" "$q" "$codec" "$model" "$profile")" || return 1
    score[$q]="${r%% *}"; bytes[$q]="${r##* }"
    LAST_SHOT_SEARCH_SAMPLES+=("${q}:${score[$q]}:${bytes[$q]}")
    log_err "  per-shot qp-search [$codec] shot=${start}-${end} qp=$q vmaf=${score[$q]}"
  }

  # QP shares CRF's exact 0-63 scale and direction in this SVT-AV1 build
  # (lower value = more bits = higher quality) -- same anchor/bisect shape
  # as vmaf_crf_search_internal(), "above"/"below" naming kept identical
  # to that function on purpose so the two stay easy to compare.
  #
  # 2026-08-25: refinement probe PLACEMENT switched from blind bisection to
  # linear interpolation on the real (QP,VMAF) curve once two bracketing
  # samples exist -- ported from Av1an's real target-quality search
  # (av1an-core/src/target_quality.rs predict_quantizer(), confirmed via
  # its actual GitHub source). Pure speed win, no downside: it still
  # searches for the same true answer (gap<=1, i.e. the highest/most
  # bit-efficient QP that still meets target), just reaches it in fewer
  # probes than blindly halving the remaining range, since it uses where
  # the curve actually crosses the target instead of the range's midpoint.
  #
  # An earlier version of this fix also added a tolerance-band EARLY EXIT
  # (stop the instant any probe lands within [target,target+0.5], not only
  # once gap<=1) -- ported from the same Av1an source, but REVERTED same
  # day after review: it stops before confirming no more-efficient
  # (higher, fewer-bits) QP exists just beyond the accepted one, trading
  # guaranteed bit-optimality for speed. That's the wrong tradeoff given
  # this project's own priority order (quality > size > *speed* last) --
  # confirmed on a real shot where the old bisection search's extra probes
  # (which the tolerance exit would have skipped) were doing exactly this
  # check: shot 52.594-52.803 of the 2026-08-24 test episode landed on the
  # identical qp=30/vmaf=94.17 either way, but bisection spent 4 extra
  # probes (all landing below target) specifically confirming nothing
  # between 30 and 46 could beat 30 -- real, deliberate thoroughness, not
  # wasted work. Keep interpolation (faster path to the same guaranteed-
  # optimal answer); don't accept "good enough" in its place.
  local anchors="$VMAF_SEARCH_MIN_CRF 30 $VMAF_SEARCH_MAX_CRF"
  for qp in $anchors; do _probe_qp "$qp" || return 1; done
  for i in 1 2 3; do
    above=""; below=""
    for qp in $(printf '%s\n' "${!score[@]}" | sort -n); do
      if awk -v s="${score[$qp]}" -v t="$target" 'BEGIN{exit !(s>=t)}'; then above="$qp"; else below="$qp"; break; fi
    done
    if [ -z "$above" ]; then _probe_qp "$VMAF_SEARCH_MIN_CRF" || break; continue; fi
    if [ -z "$below" ]; then _probe_qp "$VMAF_SEARCH_MAX_CRF" || break; continue; fi
    gap=$(( below - above )); [ "$gap" -le 1 ] && break
    local next_qp
    next_qp="$(_interp_qp "$above" "${score[$above]}" "$below" "${score[$below]}" "$target")"
    _probe_qp "$next_qp" || break
  done

  local best="" bv="" closest="" cv=""
  for qp in $(printf '%s\n' "${!score[@]}" | sort -n); do
    if awk -v s="${score[$qp]}" -v t="$target" 'BEGIN{exit !(s>=t)}'; then
      # Highest QP (fewest bits) that still meets target -- keep overwriting
      # as qp increases since we sort ascending.
      best="$qp"; bv="${score[$qp]}"
    fi
    if [ -z "$cv" ] || awk -v s="${score[$qp]}" -v c="$cv" 'BEGIN{exit !(s>c)}'; then
      closest="$qp"; cv="${score[$qp]}"
    fi
  done
  if [ -z "$best" ]; then
    # No sampled QP reached target -- same "return the best real
    # measurement, don't discard it for a disconnected static fallback"
    # reasoning as vmaf_crf_search_internal's own 2026-08-16 fix.
    best="$closest"; bv="$cv"
  fi
  [ -n "$best" ] || return 1
  # 3rd field: every (qp,vmaf,bytes) sample this search actually probed,
  # comma-joined -- feeds the Phase 6.1 equal-slope allocator. Printed
  # here (not via a global) because every real caller invokes this
  # function through $(...) command substitution, which forks a subshell;
  # a global set inside that subshell never reaches the caller (found
  # live 2026-08-25: LAST_SHOT_SEARCH_SAMPLES was silently always empty in
  # every caller despite being populated correctly inside this function).
  # Callers must parse 3 whitespace-separated fields (e.g. `read -r qp
  # vmaf samples <<<"$result"`), not the old first/last-field shortcut.
  local IFS=,
  printf '%s %s %s' "$best" "$bv" "${LAST_SHOT_SEARCH_SAMPLES[*]}"
}

# Orchestrates the full per-shot search for one title and writes a
# per-frame qpfile (one QP integer per line, one line per frame, matching
# SvtAv1EncApp's --qpfile format) ready for a single continuous encode.
# Real cost: one bounded QP search per shot (up to ~6 short sample
# encodes each) -- meaningfully more total work than the single whole-
# file search, by design (this is the "order of magnitude more encode
# passes" the original plan explicitly anticipated), which is why this is
# meant to run distributed across fleet verifier-tier idle time, not
# stacked onto one machine's encoder-tier work.
build_per_shot_qpfile() {
  local src="$1" codec="$2" profile="$3" qpfile_out="$4"
  local dur fps_rate fps_num fps_den fps target model
  local -a bounds=()
  local ts qp_result qp shot_start shot_end total_frames frame

  dur="$(video_duration "$src")" || return 1
  fps_rate="$("${FFPROBE_CMD[@]}" -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 -- "$src" 2>/dev/null)"
  fps_num="${fps_rate%/*}"; fps_den="${fps_rate#*/}"
  fps="$(awk -v n="$fps_num" -v d="$fps_den" 'BEGIN{printf "%.6f", n/d}')"
  target="$(vmaf_target_for_source "$src")" || return 1
  model="$(vmaf_model_for_source "$src")"

  bounds=("0.0")
  while IFS= read -r ts; do
    [ -n "$ts" ] && bounds+=("$ts")
  done < <(scene_detect_boundaries "$src")
  bounds+=("$dur")

  local -a shot_qps=()
  local i n=$(( ${#bounds[@]} - 1 ))
  for ((i = 0; i < n; i++)); do
    shot_start="${bounds[$i]}"
    shot_end="${bounds[$((i+1))]}"
    qp_result="$(resolve_per_shot_qp "$src" "$shot_start" "$shot_end" "$codec" "$target" "$model" "$profile")"
    if [ -n "$qp_result" ]; then
      qp="${qp_result%% *}"
    else
      qp="$(fixed_crf_for "$codec" "$profile" false)"
      warn "Per-shot QP search failed for shot $i ($shot_start-$shot_end) -- falling back to fixed $qp"
    fi
    shot_qps+=("$shot_start:$shot_end:$qp")
  done

  total_frames="$(awk -v d="$dur" -v f="$fps" 'BEGIN{printf "%d", d*f + 1}')"
  _write_shot_qps_to_qpfile shot_qps "$total_frames" "$fps" "$qpfile_out"
  log "Per-shot QP search: ${#shot_qps[@]} shots, qpfile written to $qpfile_out ($total_frames frames)"
}

# Expands a "start:end:qp" array (one entry per shot, in order) into a
# per-frame qpfile -- shared by both the single-machine path above
# (build_per_shot_qpfile) and the distributed manifest path below
# (assemble_qpfile_from_shot_manifest), so the two never drift apart on
# how frame timestamps map to shots.
_write_shot_qps_to_qpfile() {
  local -n _shots_ref="$1"
  local total_frames="$2" fps="$3" qpfile_out="$4"
  local si=0 t qp frame shot_end_check
  : >"$qpfile_out"
  for ((frame = 0; frame < total_frames; frame++)); do
    t="$(awk -v fr="$frame" -v f="$fps" 'BEGIN{printf "%.6f", fr/f}')"
    while [ "$si" -lt $(( ${#_shots_ref[@]} - 1 )) ]; do
      shot_end_check="${_shots_ref[$si]#*:}"; shot_end_check="${shot_end_check%%:*}"
      awk -v t="$t" -v e="$shot_end_check" 'BEGIN{exit !(t>=e)}' && si=$((si+1)) || break
    done
    qp="${_shots_ref[$si]##*:}"
    printf '%s\n' "$qp" >>"$qpfile_out"
  done
}

# ---------------------------------------------------------------------
# Distributed shot-search coordination -- reuses ves-chunk-coordinator.sh's
# exact proven atomic-claim primitives (mkdir-lock, mv-based stale
# reclaim) at shot granularity, so any idle fleet machine can claim and
# search individual shots for a title in parallel, independent of which
# machine will eventually own that title's final continuous encode. This
# is the fleet-distribution half of Phase 6: the expensive part (up to
# ~6 short sample-encode+VMAF passes per shot, confirmed live 2026-08-24
# to take several minutes per shot even on simple content) is what needs
# spreading across the fleet's idle capacity, not the final encode itself
# (which stays a single continuous pass per work-unit, same as Layer 1).
# ---------------------------------------------------------------------

# Directory holding one title's shot-search manifest + per-shot status
# files. Sibling to chunk_manifest_dir()'s own <title>.chunks convention.
shot_manifest_dir() {
  local src="$1"
  local dir title
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src")"
  printf '%s/%s.shots' "$dir" "$title"
}

shot_lock_path() {
  local src="$1" idx="$2"
  local dir title
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src")"
  printf '%s/%s.shot%s' "$dir" "$title" "$idx"
}

# Runs scene_detect_boundaries() ONCE (the expensive full-decode pass) and
# writes one shot-NNN.meta file per shot (start_ts/end_ts) plus
# manifest.meta (codec/profile/target/model, resolved once so every
# machine searching a shot for this title uses identical search
# parameters). Idempotent via the same .complete-written-last convention
# chunk_split_create_manifest() uses -- a second machine racing to split
# the same title just walks away once it sees mkdir fail.
shot_split_create_manifest() {
  local src="$1" codec="$2" profile="$3"
  local mdir tmpdir dur target model n=0 prev="0.0" ts
  mdir="$(shot_manifest_dir "$src")"
  [ -f "$mdir/.complete" ] && return 0
  if ! mkdir -- "$mdir" 2>/dev/null; then
    # Stale-build reclaim: mkdir is the atomic claim, but a builder that
    # crashes or is killed mid-scan (this is a full-file scene-detect
    # decode pass, can run well past 10min on a long episode) never
    # writes .complete, leaving an empty mdir that silently blocks every
    # future attempt forever. Found live 2026-08-27: a killed foreground
    # run left exactly this state and permanently return-1'd this
    # function for that title. Same 1800s ceiling as shot_claim_next()'s
    # own staleness reclaim -- a manifest build still incomplete past
    # that is almost certainly a dead builder, not slow-but-alive work.
    local mdir_age
    mdir_age=$(( $(date +%s) - $(stat -c%Y -- "$mdir" 2>/dev/null || stat -f%m -- "$mdir" 2>/dev/null || echo 0) ))
    if [ -d "$mdir" ] && [ ! -f "$mdir/.complete" ] && [ "$mdir_age" -gt 1800 ]; then
      rm -rf -- "$mdir" 2>/dev/null
      mkdir -- "$mdir" 2>/dev/null || return 1
    else
      return 1
    fi
  fi
  chmod 0777 -- "$mdir" 2>/dev/null || true
  tmpdir="$(mktemp -d "${mdir}.build.XXXXXX")" || { rmdir -- "$mdir" 2>/dev/null; return 1; }

  dur="$(video_duration "$src")" || { rm -rf -- "$tmpdir"; rmdir -- "$mdir" 2>/dev/null; return 1; }
  target="$(vmaf_target_for_source "$src")" || { rm -rf -- "$tmpdir"; rmdir -- "$mdir" 2>/dev/null; return 1; }
  model="$(vmaf_model_for_source "$src")"

  while IFS= read -r ts; do
    [ -n "$ts" ] || continue
    cat >"${tmpdir}/shot-$(printf '%03d' "$n").meta" <<EOF
index=$n
start_ts=$prev
end_ts=$ts
EOF
    n=$((n + 1))
    prev="$ts"
  done < <(scene_detect_boundaries "$src")
  # Final shot runs from the last detected cut to the real end of the file.
  cat >"${tmpdir}/shot-$(printf '%03d' "$n").meta" <<EOF
index=$n
start_ts=$prev
end_ts=$dur
EOF
  n=$((n + 1))

  cat >"${tmpdir}/manifest.meta" <<EOF
source=$src
shot_count=$n
codec=$codec
profile=$profile
target=$target
model=$model
created_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
created_host=$(hostname 2>/dev/null || echo unknown)
EOF

  local f
  for f in "$tmpdir"/*; do
    mv -f -- "$f" "$mdir/$(basename -- "$f")"
  done
  rmdir -- "$tmpdir" 2>/dev/null
  : >"$mdir/.complete"
  log "Shot split: $n shot(s) created for $(basename -- "$src")"
  return 0
}

# Claims one not-yet-searched shot for $src. Prints the claimed shot index
# on stdout and returns 0, or returns 1 if none are available (caller
# should move on, same contract as chunk_claim_next()). Identical
# mkdir-lock + mv-based-stale-reclaim shape -- see chunk_claim_next()'s
# own comments for why. Staleness ceiling is deliberately much shorter
# than chunk-encode's 7200s: a shot's bounded QP search (a handful of
# short sample encodes) should finish in minutes, confirmed live
# 2026-08-24 (~3-9 min for a single shot including VMAF measurement), not
# hours -- a search still "claimed" past 1800s is almost certainly a dead
# worker, not slow-but-alive work.
shot_claim_next() {
  local src="$1" this_host
  local mdir f idx lockdir status_file reclaim_name
  mdir="$(shot_manifest_dir "$src")"
  [ -f "$mdir/.complete" ] || return 1
  this_host="$(hostname 2>/dev/null || echo unknown)"

  for f in "$mdir"/shot-*.meta; do
    [ -e "$f" ] || continue
    idx="$(awk -F= '/^index=/{print $2; exit}' "$f")"
    status_file="$mdir/shot-$(printf '%03d' "$idx").status"
    if [ -f "$status_file" ]; then
      local st
      st="$(awk -F= '/^status=/{print $2; exit}' "$status_file" 2>/dev/null)"
      [ "$st" = "resolved" ] && continue
    fi
    lockdir="$(shot_lock_path "$src" "$idx").lock"
    if mkdir -- "$lockdir" 2>/dev/null; then
      cat >"${lockdir}/owner.meta" <<EOF
host=$this_host
pid=$$
claimed_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
      printf '%s' "$idx"
      return 0
    fi
    local owner_meta age mtime now
    owner_meta="${lockdir}/owner.meta"
    mtime="$(mkv_structure_stat_key "$owner_meta" 2>/dev/null)" || true
    mtime="${mtime##*|}"
    now="$(date +%s)"
    age=$(( now - ${mtime:-$now} ))
    if [ "$age" -gt "${SHOT_SEARCH_STALE_SECS:-1800}" ]; then
      reclaim_name="${lockdir}.reclaim.${this_host}.$$.$RANDOM"
      if mv -- "$lockdir" "$reclaim_name" 2>/dev/null; then
        rm -rf -- "$reclaim_name" 2>/dev/null
        if mkdir -- "$lockdir" 2>/dev/null; then
          cat >"${lockdir}/owner.meta" <<EOF
host=$this_host
pid=$$
claimed_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
          printf '%s' "$idx"
          return 0
        fi
      fi
    fi
  done
  return 1
}

shot_release_claim() {
  local src="$1" idx="$2"
  rm -rf -- "$(shot_lock_path "$src" "$idx").lock" 2>/dev/null || true
}

# Runs resolve_per_shot_qp() for one already-claimed shot and records the
# result. Callers (any idle fleet machine) loop: shot_claim_next -> this
# -> shot_release_claim, same shape as the chunk encoder loop.
shot_search_claimed() {
  local src="$1" idx="$2"
  local mdir shot_meta start_ts end_ts codec profile target model result qp vmaf status_file tmp
  mdir="$(shot_manifest_dir "$src")"
  shot_meta="$mdir/shot-$(printf '%03d' "$idx").meta"
  [ -f "$shot_meta" ] || { shot_release_claim "$src" "$idx"; return 1; }

  # Re-check status now that we actually hold the lock. shot_claim_next()'s
  # own pre-claim check can be fooled by NFS attribute-cache staleness (this
  # fleet's shared media mount uses actimeo=1800 -- up to 30 minutes before a
  # client re-validates cached directory/file state against the server), so
  # two machines can both see an already-resolved shot as unresolved and both
  # attempt to claim it. The mkdir a moment ago in shot_claim_next() was
  # itself a write requiring a fresh server round-trip, which makes a
  # same-process read immediately after it far more likely to be fresh than
  # the read that drove the original claim decision. This doesn't make the
  # check airtight (still a cache, still possibly stale), but it's a cheap
  # real reduction in wasted duplicate search work. Found live 2026-08-24:
  # Sting redundantly re-searched 3 shots MJACKSON had already resolved.
  status_file="$mdir/shot-$(printf '%03d' "$idx").status"
  if [ -f "$status_file" ]; then
    local already_st
    already_st="$(awk -F= '/^status=/{print $2; exit}' "$status_file" 2>/dev/null)"
    if [ "$already_st" = "resolved" ]; then
      shot_release_claim "$src" "$idx"
      return 0
    fi
  fi
  start_ts="$(awk -F= '/^start_ts=/{print $2; exit}' "$shot_meta")"
  end_ts="$(awk -F= '/^end_ts=/{print $2; exit}' "$shot_meta")"
  codec="$(awk -F= '/^codec=/{print $2; exit}' "$mdir/manifest.meta")"
  profile="$(awk -F= '/^profile=/{print $2; exit}' "$mdir/manifest.meta")"
  target="$(awk -F= '/^target=/{print $2; exit}' "$mdir/manifest.meta")"
  # substr(...,index(...)+1), not $2 -- model's own value contains a
  # literal "=" (e.g. "version=vmaf_v0.6.1neg"), and -F= splits on every
  # "=" in the line, so a plain $2 silently truncates it to "version".
  # Found live 2026-08-24: this exact truncation broke every shot search
  # on MJACKSON (invalid libvmaf model= argument -> every ffmpeg call
  # failed -> every shot fell back to the static fixed-QP default).
  model="$(awk -F= '/^model=/{print substr($0,index($0,"=")+1); exit}' "$mdir/manifest.meta")"

  result="$(resolve_per_shot_qp "$src" "$start_ts" "$end_ts" "$codec" "$target" "$model" "$profile")"
  local samples="" search_failed=0
  if [ -n "$result" ]; then
    # 3 whitespace-separated fields (qp, vmaf, samples) -- read, not the
    # old first/last-field shortcut, since the samples field itself would
    # otherwise be mistaken for the last field (see resolve_per_shot_qp()'s
    # own header comment for why this isn't a side-channel global instead).
    read -r qp vmaf samples <<<"$result"
  else
    qp="$(fixed_crf_for "$codec" "$profile" false)"
    vmaf=""
    search_failed=1
    warn "Shot search failed for shot $idx ($start_ts-$end_ts) on $(hostname 2>/dev/null) -- falling back to fixed qp=$qp"
  fi

  status_file="$mdir/shot-$(printf '%03d' "$idx").status"
  tmp="$(mktemp "${status_file}.XXXXXX" 2>/dev/null)" || { shot_release_claim "$src" "$idx"; return 1; }
  {
    printf 'status=resolved\n'
    printf 'qp=%s\n' "$qp"
    printf 'vmaf=%s\n' "$vmaf"
    printf 'samples=%s\n' "$samples"
    # 1 when resolve_per_shot_qp() returned nothing and we blind-fell-back
    # to a fixed QP -- the shot has no real rate/VMAF data. Kept as a
    # resolved status (don't block the pipeline) but marked so the
    # allocator and credits detection can tell it apart from a real result.
    printf 'search_failed=%s\n' "$search_failed"
    printf 'searched_host=%s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf 'searched_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } >"$tmp"
  mv -f -- "$tmp" "$status_file"
  _restore_default_file_mode "$status_file"
  shot_release_claim "$src" "$idx"
  return 0
}

# True if every shot in the manifest has a resolved status -- the signal
# that a title is ready for assemble_qpfile_from_shot_manifest().
shot_manifest_all_resolved() {
  local src="$1" mdir f idx status_file st
  mdir="$(shot_manifest_dir "$src")"
  [ -f "$mdir/.complete" ] || return 1
  for f in "$mdir"/shot-*.meta; do
    [ -e "$f" ] || continue
    idx="$(awk -F= '/^index=/{print $2; exit}' "$f")"
    status_file="$mdir/shot-$(printf '%03d' "$idx").status"
    [ -f "$status_file" ] || return 1
    st="$(awk -F= '/^status=/{print $2; exit}' "$status_file" 2>/dev/null)"
    [ "$st" = "resolved" ] || return 1
  done
  return 0
}

# Reads every shot's resolved QP from the manifest (all shot_manifest_
# all_resolved() must already be true) and writes the final per-frame
# qpfile -- the step whichever machine owns the final continuous encode
# for this title runs once, after the distributed search across the
# fleet has finished. Mirrors build_per_shot_qpfile()'s own frame-
# expansion exactly via the shared _write_shot_qps_to_qpfile() helper.
assemble_qpfile_from_shot_manifest() {
  local src="$1" qpfile_out="$2"
  local mdir f idx start_ts end_ts qp dur fps_rate fps_num fps_den fps total_frames
  local -a shot_qps=()
  mdir="$(shot_manifest_dir "$src")"
  shot_manifest_all_resolved "$src" || return 1

  for f in "$mdir"/shot-*.meta; do
    [ -e "$f" ] || continue
    idx="$(awk -F= '/^index=/{print $2; exit}' "$f")"
    start_ts="$(awk -F= '/^start_ts=/{print $2; exit}' "$f")"
    end_ts="$(awk -F= '/^end_ts=/{print $2; exit}' "$f")"
    qp="$(awk -F= '/^qp=/{print $2; exit}' "$mdir/shot-$(printf '%03d' "$idx").status")"
    shot_qps[$idx]="$start_ts:$end_ts:$qp"
  done

  dur="$(video_duration "$src")" || return 1
  fps_rate="$("${FFPROBE_CMD[@]}" -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 -- "$src" 2>/dev/null)"
  fps_num="${fps_rate%/*}"; fps_den="${fps_rate#*/}"
  fps="$(awk -v n="$fps_num" -v d="$fps_den" 'BEGIN{printf "%.6f", n/d}')"
  total_frames="$(awk -v d="$dur" -v f="$fps" 'BEGIN{printf "%d", d*f + 1}')"

  _write_shot_qps_to_qpfile shot_qps "$total_frames" "$fps" "$qpfile_out"
  log "Assembled qpfile from shot manifest: ${#shot_qps[@]} shots, $qpfile_out ($total_frames frames)"
}

# Phase 6.1 (docs/DESIGN-6x-chunk-redesign.md): equal-slope global bit
# allocation, an alternative to assemble_qpfile_from_shot_manifest()'s
# "every shot independently picks the QP that meets the same fixed target"
# policy. Instead: given a global shadow price (lambda) for one more byte,
# every shot independently picks whichever of ITS OWN already-probed
# samples maximizes (vmaf - lambda*bytes) -- the standard Lagrangian
# relaxation of "maximize quality subject to a bit budget", here solved in
# the dual direction (find the lambda whose resulting duration-weighted
# mean VMAF lands at the target) via bisection on log(lambda), mirroring
# vmaf_crf_search_internal()'s own bisection shape.
#
# No new encodes: reuses the (qp,vmaf,bytes) samples resolve_per_shot_qp()
# already produced and shot_search_claimed() now persists in each shot's
# status file (`samples=`). At any fixed lambda, the per-shot optimum is
# provably just argmax over that shot's own samples -- no explicit convex-
# hull construction needed, since a dominated (non-hull) sample can never
# win that argmax for any lambda, so hull-filtering happens for free.
#
# REAL POLICY CHANGE from assemble_qpfile_from_shot_manifest(): individual
# shots are no longer guaranteed to hit the target -- only the duration-
# weighted whole-title average is. "No quality regression" today is
# enforced per-shot; this relaxes it to per-title-average, trading some
# hard-shot quality for cheap-shot bit savings. Not shipped as the default
# path -- call explicitly, compare against assemble_qpfile_from_shot_
# manifest()'s output, and get real user sign-off before switching.
assemble_qpfile_via_equal_slope() {
  local src="$1" qpfile_out="$2" target="$3"
  local mdir f idx start_ts end_ts dur fps_rate fps_num fps_den fps total_frames
  local -a shot_qps=()
  mdir="$(shot_manifest_dir "$src")"
  shot_manifest_all_resolved "$src" || return 1

  local samples_flat durations_flat
  samples_flat="$(mktemp)" || return 1
  durations_flat="$(mktemp)" || { rm -f "$samples_flat"; return 1; }
  local -A shot_start=() shot_end=()
  # Shots whose search produced no real samples at all (a total search
  # failure that fell back to a fixed QP -- see shot_search_claimed()) --
  # there is no rate-distortion curve to optimize over, so these are kept
  # OUT of the lambda bisection entirely (excluded from both the weighted-
  # mean numerator and its duration denominator) and merged back in
  # afterward using their own already-recorded fallback QP. Found live
  # 2026-08-25: leaving such a shot out of durations_flat but still in
  # dur[] via awk's "for (idx in dur)" silently treated its VMAF as 0 in
  # the weighted mean (awk's uninitialized-array-read default), badly
  # understating the true achievable mean and making the bisection
  # converge somewhere meaningless.
  local -a no_sample_idx=()

  for f in "$mdir"/shot-*.meta; do
    [ -e "$f" ] || continue
    idx="$(awk -F= '/^index=/{print $2; exit}' "$f")"
    start_ts="$(awk -F= '/^start_ts=/{print $2; exit}' "$f")"
    end_ts="$(awk -F= '/^end_ts=/{print $2; exit}' "$f")"
    shot_start[$idx]="$start_ts"; shot_end[$idx]="$end_ts"
    local status_file samples_line
    status_file="$mdir/shot-$(printf '%03d' "$idx").status"
    samples_line="$(awk -F= '/^samples=/{print substr($0,index($0,"=")+1); exit}' "$status_file")"
    if [ -z "$samples_line" ]; then
      no_sample_idx+=("$idx")
      continue
    fi
    printf '%s %s %s\n' "$idx" "$start_ts" "$end_ts" >>"$durations_flat"
    local IFS=,; local -a parts=($samples_line); unset IFS
    local p
    for p in "${parts[@]}"; do
      [ -n "$p" ] || continue
      local IFS=:; local -a triple=($p); unset IFS
      [ "${#triple[@]}" -eq 3 ] || continue
      printf '%s %s %s %s\n' "$idx" "${triple[0]}" "${triple[1]}" "${triple[2]}" >>"$samples_flat"
    done
  done

  local qp_lines
  qp_lines="$(awk -v target="$target" -v durations_file="$durations_flat" '
    BEGIN {
      while ((getline line < durations_file) > 0) {
        split(line, a, " ")
        d = a[3] - a[2]; if (d < 0) d = 0
        dur[a[1]] = d
        total_dur += d
      }
      close(durations_file)
    }
    { n++; sidx[n]=$1; sqp[n]=$2; svmaf[n]=$3; sbytes[n]=$4 }
    END {
      if (total_dur <= 0 || n == 0) { exit 1 }
      lo = 1e-10; hi = 1e-1
      for (iter = 0; iter < 50; iter++) {
        lambda = exp((log(lo) + log(hi)) / 2)
        for (idx in dur) has_best[idx] = 0
        for (i = 1; i <= n; i++) {
          idx = sidx[i]
          obj = svmaf[i] - lambda * sbytes[i]
          if (!has_best[idx] || obj > best_obj[idx]) {
            has_best[idx] = 1; best_obj[idx] = obj
            best_qp[idx] = sqp[i]; best_vmaf[idx] = svmaf[i]
          }
        }
        wsum = 0
        for (idx in dur) wsum += best_vmaf[idx] * dur[idx]
        mean_vmaf = wsum / total_dur
        if (mean_vmaf > target) { lo = lambda } else { hi = lambda }
      }
      printf "LAMBDA=%.10g FINAL_MEAN_VMAF=%.4f\n", lambda, mean_vmaf > "/dev/stderr"
      for (idx in best_qp) printf "%s %s %s\n", idx, best_qp[idx], best_vmaf[idx]
    }
  ' "$samples_flat")" || { rm -f "$samples_flat" "$durations_flat"; return 1; }
  rm -f "$samples_flat" "$durations_flat"

  local line
  while IFS=' ' read -r idx qp vmaf; do
    [ -n "$idx" ] || continue
    shot_qps[$idx]="${shot_start[$idx]}:${shot_end[$idx]}:$qp"
  done <<<"$qp_lines"

  # Merge back in the shots excluded from the lambda bisection above --
  # their own already-recorded fallback QP, unchanged (nothing to optimize
  # without real samples).
  local ni
  for ni in "${no_sample_idx[@]}"; do
    local fallback_qp
    fallback_qp="$(awk -F= '/^qp=/{print substr($0,index($0,"=")+1); exit}' "$mdir/shot-$(printf '%03d' "$ni").status")"
    shot_qps[$ni]="${shot_start[$ni]}:${shot_end[$ni]}:$fallback_qp"
  done

  dur="$(video_duration "$src")" || return 1
  fps_rate="$("${FFPROBE_CMD[@]}" -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 -- "$src" 2>/dev/null)"
  fps_num="${fps_rate%/*}"; fps_den="${fps_rate#*/}"
  fps="$(awk -v n="$fps_num" -v d="$fps_den" 'BEGIN{printf "%.6f", n/d}')"
  total_frames="$(awk -v d="$dur" -v f="$fps" 'BEGIN{printf "%d", d*f + 1}')"

  _write_shot_qps_to_qpfile shot_qps "$total_frames" "$fps" "$qpfile_out"
  log "Assembled qpfile via equal-slope allocation: ${#shot_qps[@]} shots, $qpfile_out ($total_frames frames)"
}

# Same equal-slope mechanism as assemble_qpfile_via_equal_slope() above,
# but bisecting lambda against a TOTAL BYTE BUDGET instead of a target mean
# VMAF. Found live 2026-08-25 (real user pushback, both anime and Reacher
# test episodes): a mean-VMAF target that isn't reachable by any shot
# combination in the isolated search data forces the bisection to its
# floor -- lambda->0, i.e. "spend maximum on every shot" -- which never
# exercises the actual redistribution the allocator exists for (taking
# bits from shots that don't need them, giving them to shots that do). A
# byte budget doesn't have that failure mode: it's always achievable (the
# search range's own min/max bytes bound it), so the bisection is
# guaranteed to find a real, non-degenerate lambda that genuinely
# discriminates between easy and hard shots. This is also the more
# faithful match to Netflix's own actual formulation (a fixed bit budget,
# not a target quality average -- see Phase 6.1 in docs/DESIGN-6x-chunk-
# redesign.md) and directly answers the real question this allocator is
# for: given about the same bits standard already spends, can they be
# redistributed for a better result (higher floor on hard shots) instead
# of a higher average?

# Phase 6.2 (2026-08-26), first increment: detect a plausible end-credits
# segment via the file's own last chapter marker. Checked against real
# files in this library first (Discovery/Reacher/one anime title): none
# carry semantic chapter names ("Chapter 01", not "Credits"), but the
# boundaries themselves are real structural cuts -- Reacher's last
# chapter starts at 50:59 in a ~55min episode, a plausible credits-length
# remainder. Gate on a plausible duration (30s-5min) so a short final
# SCENE (not credits) doesn't get misclassified and starved. Prints
# "start end" (seconds) on stdout if a plausible range is found; prints
# nothing and returns 1 otherwise -- callers must treat "not detected" as
# "don't deprioritize anything", never guess.
#
# Deliberately NOT attempting opening-titles detection here -- explicit
# user direction 2026-08-26 (Star Trek Lower Decks example: real story,
# then intro, then back to story, cold-open length varies per episode)
# ruled out any fixed-position/duration heuristic for that case. The
# right tool is cross-episode audio fingerprinting (the same mechanism
# Jellyfin's Intro Skipper / Plex's own intro detection use, both built
# on Chromaprint -- confirmed already present on this machine as
# /usr/bin/fpcalc + a python chromaprint binding). That's real, separate
# work (needs a handful of episodes of the same show to compare against,
# not a single-file heuristic) -- queued as the next Phase 6.2 increment,
# not built yet.
detect_credits_range() {
  local src="$1"
  local dur last_start last_dur
  dur="$(video_duration "$src")" || return 1
  local chap_starts
  chap_starts="$(run_ffprobe -v error -show_chapters -show_entries chapter=start_time -of csv=p=0 -- "$src" 2>/dev/null)"
  if [ -n "$chap_starts" ]; then
    last_start="$(printf '%s\n' "$chap_starts" | tail -1 | cut -d, -f1)"
    if [[ "$last_start" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      last_dur="$(awk -v d="$dur" -v s="$last_start" 'BEGIN{print d-s}')"
      if awk -v d="$last_dur" 'BEGIN{exit !(d>=30 && d<=300)}'; then
        printf '%s %s\n' "$last_start" "$dur"
        return 0
      fi
    fi
  fi
  detect_credits_range_by_complexity "$src" "$dur"
}

# Fallback for files with no chapters at all (real gap found 2026-08-26:
# Star Trek Discovery has none) -- reuses the per-shot search's OWN
# already-computed byte-cost data instead of a new video-analysis pass.
# Credits (scrolling text over a plain/dark background) compress far more
# cheaply than real content; a CONTIGUOUS run of low bytes-per-second
# shots ending near the file's end is a strong signal. Validated against
# real Discovery data: shot 450 (2355.5-2421.2s, 65.7s) came back at 8%
# of the file's median bytes/sec. The reported range is extended to true
# EOF (mirroring the chapter path) even when a short bumper/logo follows
# the crawl -- that tail is low-viewer-value too, so including it in the
# deprioritized range is safe. Requires the shot manifest to already be
# fully resolved (same precondition as the allocator itself).
#
# 2026-08-28 rework (v6.0.0R): the earlier version matched only the single
# lowest-ratio shot in the last quarter and returned just that shot's own
# span. That under-detected multi-shot credits sequences (WandaVision
# S01E05) and missed shows whose tail never cleared a strict 0.25x bar
# (Wild Cards S01E10) entirely. Now: baseline median is taken over the
# file body only (pre-last-quarter), and detection walks a contiguous
# trailing run of cheap shots, trying a strict then a looser ratio.
detect_credits_range_by_complexity() {
  local src="$1" dur="${2:-}"
  local mdir f idx start_ts end_ts status_file qp samples bytes_at_qp
  [ -n "$dur" ] || dur="$(video_duration "$src")" || return 1
  mdir="$(shot_manifest_dir "$src")"
  shot_manifest_all_resolved "$src" || return 1

  local flat; flat="$(mktemp)" || return 1
  for f in "$mdir"/shot-*.meta; do
    [ -e "$f" ] || continue
    idx="$(awk -F= '/^index=/{print $2; exit}' "$f")"
    start_ts="$(awk -F= '/^start_ts=/{print $2; exit}' "$f")"
    end_ts="$(awk -F= '/^end_ts=/{print $2; exit}' "$f")"
    status_file="$mdir/shot-$(printf '%03d' "$idx").status"
    qp="$(awk -F= '/^qp=/{print substr($0,index($0,"=")+1); exit}' "$status_file")"
    samples="$(awk -F= '/^samples=/{print substr($0,index($0,"=")+1); exit}' "$status_file")"
    bytes_at_qp=""
    if [ -n "$qp" ] && [ -n "$samples" ]; then
      local IFS=,; local -a parts=($samples); unset IFS
      local p
      for p in "${parts[@]}"; do
        local IFS=:; local -a triple=($p); unset IFS
        [ "${#triple[@]}" -eq 3 ] || continue
        [ "${triple[0]}" = "$qp" ] && { bytes_at_qp="${triple[2]}"; break; }
      done
    fi
    # A shot with no usable byte sample -- the per-shot search failed on it
    # and shot_search_claimed() fell back to a fixed QP (status=resolved but
    # samples= empty; real case 2026-08-28: RbW S01E01 shot 454, a 90s
    # credits block whose search OOM'd a weak fleet host's RAMDISK). Emit it
    # with an "NA" byte marker rather than dropping it: a gap in the shot
    # sequence used to break the trailing-run walk right where the credits
    # live. Downstream (awk) treats a long NA shot near EOF as almost
    # certainly the credits crawl (no scene cut for 45s+), a short one as a
    # bridgeable unknown.
    printf '%s %s %s %s\n' "$idx" "$start_ts" "$end_ts" "${bytes_at_qp:-NA}" >>"$flat"
  done

  # Baseline bytes/sec from the file's BODY only -- shots that start
  # before the last quarter. A long credits sequence in the tail would
  # otherwise drag the median down and mask itself (real: Wild Cards
  # S01E10, whose tail never cleared the old strict 0.25x-of-all-shots
  # bar and was missed entirely). The 0.75 split is positional, not
  # value-based, so this is not circular. Falls back to an all-shots
  # median for files too short to have a distinct body.
  #
  # Median via external `sort -n` rather than awk's asort() -- confirmed
  # 2026-08-26 this module is deployed to macOS fleet machines (MARLONJ)
  # running BSD/one-true-awk, which has no asort() extension; this file
  # must stay portable to every awk in the fleet, not just GNU awk.
  local window_start
  window_start="$(awk -v d="$dur" 'BEGIN{ printf "%.3f", d * 0.75 }')"
  local bps_sorted median
  bps_sorted="$(awk -v ws="$window_start" '$4 != "NA" { d = $3 - $2; if (d > 0 && $2 < ws) print $4 / d }' "$flat" | sort -n)"
  if [ -z "$bps_sorted" ]; then
    bps_sorted="$(awk '$4 != "NA" { d = $3 - $2; if (d > 0) print $4 / d }' "$flat" | sort -n)"
  fi
  if [ -z "$bps_sorted" ]; then rm -f "$flat"; return 1; fi
  median="$(awk '{a[NR]=$1} END{ if (NR==0) exit 1; if (NR%2==1) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2 }' <<<"$bps_sorted")"

  # Anchor on a CONTIGUOUS trailing run of cheap-to-compress shots, not a
  # single outlier. The old code matched only the one lowest-ratio shot
  # and returned just its own span, which (a) under-detected badly when
  # the real credits span several shots of differing byte profiles
  # (WandaVision S01E05: ~93s of trailing credits missed), and (b) missed
  # entirely when no single shot cleared the strict bar. Walking a
  # contiguous run that ends near EOF is a far stronger signal, so we can
  # both extend the reported end to true EOF (mirroring the chapter path)
  # and safely try a looser ratio on a second pass. A short trailing
  # bumper/preview after the credits is skipped (up to ~90s from EOF).
  local result
  result="$(awk -v total_dur="$dur" -v median="$median" -v window_start="$window_start" '
    { n++; s[n]=$2; e[n]=$3
      d = e[n] - s[n]
      if ($4 == "NA") { bps[n] = -2 }          # search failed for this shot
      else            { bps[n] = (d > 0) ? $4/d : -1 } }
    END {
      if (n == 0 || median <= 0) exit 1
      # order shot indices chronologically (glob is already sorted, but
      # be defensive) -- n ~= a few hundred, O(n^2) is trivial here
      for (i = 1; i <= n; i++) ord[i] = i
      for (i = 1; i <= n; i++)
        for (j = i + 1; j <= n; j++)
          if (s[ord[j]] < s[ord[i]]) { t = ord[i]; ord[i] = ord[j]; ord[j] = t }

      split("0.25 0.40", thr, " ")
      for (ti = 1; ti <= 2; ti++) {
        ratio_max = thr[ti] + 0
        # try each trailing shot as the run end-anchor, closest-to-EOF
        # first; stop looking once we are more than 90s short of EOF
        for (a = n; a >= 1; a--) {
          ka = ord[a]
          if (total_dur - e[ka] > 90) break
          if (bps[ka] < 0 || bps[ka] / median >= ratio_max) continue
          run_start = a
          gap_dur = 0; gap_cnt = 0
          for (p = a - 1; p >= 1; p--) {
            k = ord[p]
            if ((e[k] - s[k]) <= 0) break
            if (s[k] < window_start) break
            if (bps[k] == -2) {
              # search failed for this shot -- no byte data. A long one
              # (>=45s, i.e. no scene cut for 45s+) is almost certainly the
              # credits crawl itself: fold it into the run. A short one is a
              # bridgeable unknown, same budget as an expensive blip.
              if ((e[k] - s[k]) >= 45) { gap_dur = 0; gap_cnt = 0; run_start = p; continue }
              gap_dur += (e[k] - s[k]); gap_cnt++
              if (gap_dur > 10 || gap_cnt > 2) break
              continue
            }
            if (bps[k] < 0) break
            if (bps[k] / median >= ratio_max) {
              # tolerate a brief expensive blip inside the crawl (a logo
              # card / mid-credits sting) -- real: WandaVision S01E05
              # shot 334 at 0.45x sits between two long ~0.2x runs
              gap_dur += (e[k] - s[k]); gap_cnt++
              if (gap_dur > 10 || gap_cnt > 2) break
              continue
            }
            gap_dur = 0; gap_cnt = 0
            run_start = p
          }
          rs = s[ord[run_start]]
          run_dur = e[ord[a]] - rs
          if (run_dur < 30) continue
          if (run_dur > total_dur * 0.35) continue
          printf "%s %s\n", rs, total_dur
          exit 0
        }
      }
      exit 1
    }
  ' "$flat")"
  local rc=$?
  rm -f "$flat"
  [ $rc -eq 0 ] && [ -n "$result" ] || return 1
  printf '%s\n' "$result"
}

assemble_qpfile_via_equal_slope_budget() {
  local src="$1" qpfile_out="$2" byte_budget="$3"
  local deprio_start="${4:-}" deprio_end="${5:-}" deprio_weight="${6:-1.0}"
  local mdir f idx start_ts end_ts dur fps_rate fps_num fps_den fps total_frames
  local -a shot_qps=()
  mdir="$(shot_manifest_dir "$src")"
  shot_manifest_all_resolved "$src" || return 1

  local samples_flat durations_flat
  samples_flat="$(mktemp)" || return 1
  durations_flat="$(mktemp)" || { rm -f "$samples_flat"; return 1; }
  local -A shot_start=() shot_end=()
  local -a no_sample_idx=()

  for f in "$mdir"/shot-*.meta; do
    [ -e "$f" ] || continue
    idx="$(awk -F= '/^index=/{print $2; exit}' "$f")"
    start_ts="$(awk -F= '/^start_ts=/{print $2; exit}' "$f")"
    end_ts="$(awk -F= '/^end_ts=/{print $2; exit}' "$f")"
    shot_start[$idx]="$start_ts"; shot_end[$idx]="$end_ts"
    local status_file samples_line
    status_file="$mdir/shot-$(printf '%03d' "$idx").status"
    samples_line="$(awk -F= '/^samples=/{print substr($0,index($0,"=")+1); exit}' "$status_file")"
    if [ -z "$samples_line" ]; then
      no_sample_idx+=("$idx")
      continue
    fi
    printf '%s %s %s\n' "$idx" "$start_ts" "$end_ts" >>"$durations_flat"
    local IFS=,; local -a parts=($samples_line); unset IFS
    local p
    for p in "${parts[@]}"; do
      [ -n "$p" ] || continue
      local IFS=:; local -a triple=($p); unset IFS
      [ "${#triple[@]}" -eq 3 ] || continue
      printf '%s %s %s %s\n' "$idx" "${triple[0]}" "${triple[1]}" "${triple[2]}" >>"$samples_flat"
    done
  done

  local qp_lines
  qp_lines="$(awk -v budget="$byte_budget" -v durations_file="$durations_flat" \
    -v deprio_start="$deprio_start" -v deprio_end="$deprio_end" -v deprio_weight="$deprio_weight" '
    BEGIN {
      have_deprio = (deprio_start != "" && deprio_end != "")
      while ((getline line < durations_file) > 0) {
        split(line, a, " ")
        dur[a[1]] = 1
        shot_s[a[1]] = a[2]; shot_e[a[1]] = a[3]
        # Phase 6.2: a shot whose midpoint falls inside the detected
        # low-viewer-value range (credits/intro) gets its VMAF term
        # discounted in the objective below, biasing the allocator to
        # accept lower quality there for the same marginal bytes --
        # freeing budget for weight[idx]==1.0 main content within the
        # SAME total spend, without touching the bisection core.
        mid = (a[2] + a[3]) / 2
        if (have_deprio && mid >= deprio_start && mid <= deprio_end) {
          weight[a[1]] = deprio_weight
        } else {
          weight[a[1]] = 1.0
        }
      }
      close(durations_file)
    }
    { n++; sidx[n]=$1; sqp[n]=$2; svmaf[n]=$3; sbytes[n]=$4 }
    END {
      if (n == 0) { exit 1 }
      # lambda range must bracket the true crossover: lo picks max-quality
      # (most bytes) everywhere, hi picks min-quality (fewest bytes)
      # everywhere -- unlike the VMAF-target version, a byte budget is
      # always achievable somewhere in [lo,hi] since actual spend is
      # monotonically decreasing in lambda.
      lo = 1e-12; hi = 1.0
      for (iter = 0; iter < 60; iter++) {
        lambda = exp((log(lo) + log(hi)) / 2)
        for (idx in dur) has_best[idx] = 0
        for (i = 1; i <= n; i++) {
          idx = sidx[i]
          obj = weight[idx] * svmaf[i] - lambda * sbytes[i]
          if (!has_best[idx] || obj > best_obj[idx]) {
            has_best[idx] = 1; best_obj[idx] = obj
            best_qp[idx] = sqp[i]; best_vmaf[idx] = svmaf[i]; best_bytes[idx] = sbytes[i]
          }
        }
        total_bytes = 0; wsum = 0; wdur = 0
        for (idx in dur) { total_bytes += best_bytes[idx] }
        if (total_bytes > budget) { lo = lambda } else { hi = lambda }
      }
      # Final pass at the converged lambda for reporting.
      lambda = exp((log(lo) + log(hi)) / 2)
      for (idx in dur) has_best[idx] = 0
      for (i = 1; i <= n; i++) {
        idx = sidx[i]
        obj = weight[idx] * svmaf[i] - lambda * sbytes[i]
        if (!has_best[idx] || obj > best_obj[idx]) {
          has_best[idx] = 1; best_obj[idx] = obj
          best_qp[idx] = sqp[i]; best_vmaf[idx] = svmaf[i]; best_bytes[idx] = sbytes[i]
        }
      }
      total_bytes = 0; min_vmaf = 999; min_idx = ""; deprio_n = 0
      for (idx in best_vmaf) {
        total_bytes += best_bytes[idx]
        if (best_vmaf[idx] < min_vmaf) { min_vmaf = best_vmaf[idx]; min_idx = idx }
        if (weight[idx] < 1.0) deprio_n++
      }
      printf "LAMBDA=%.10g TOTAL_BYTES=%d BUDGET=%d MIN_SHOT_VMAF=%.2f (shot %s) DEPRIORITIZED_SHOTS=%d\n", lambda, total_bytes, budget, min_vmaf, min_idx, deprio_n > "/dev/stderr"
      for (idx in best_qp) printf "%s %s %s\n", idx, best_qp[idx], best_vmaf[idx]
    }
  ' "$samples_flat")" || { rm -f "$samples_flat" "$durations_flat"; return 1; }
  rm -f "$samples_flat" "$durations_flat"

  local line
  while IFS=' ' read -r idx qp vmaf; do
    [ -n "$idx" ] || continue
    shot_qps[$idx]="${shot_start[$idx]}:${shot_end[$idx]}:$qp"
  done <<<"$qp_lines"

  local ni
  for ni in "${no_sample_idx[@]}"; do
    local fallback_qp
    fallback_qp="$(awk -F= '/^qp=/{print substr($0,index($0,"=")+1); exit}' "$mdir/shot-$(printf '%03d' "$ni").status")"
    shot_qps[$ni]="${shot_start[$ni]}:${shot_end[$ni]}:$fallback_qp"
  done

  dur="$(video_duration "$src")" || return 1
  fps_rate="$("${FFPROBE_CMD[@]}" -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 -- "$src" 2>/dev/null)"
  fps_num="${fps_rate%/*}"; fps_den="${fps_rate#*/}"
  fps="$(awk -v n="$fps_num" -v d="$fps_den" 'BEGIN{printf "%.6f", n/d}')"
  total_frames="$(awk -v d="$dur" -v f="$fps" 'BEGIN{printf "%d", d*f + 1}')"

  _write_shot_qps_to_qpfile shot_qps "$total_frames" "$fps" "$qpfile_out"
  log "Assembled qpfile via equal-slope budget allocation: ${#shot_qps[@]} shots, $qpfile_out ($total_frames frames)"
}
