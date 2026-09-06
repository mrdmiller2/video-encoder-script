#!/usr/bin/env bash
# ves-sd-restore.sh -- "facelift" pre-processor for heavily degraded
# standard-definition / sub-HD source media (old broadcast TV, classic
# stand-up specials, VHS/DVD-lineage rips): MPEG-4/DivX macroblocking,
# ringing, bad prior deinterlace / telecine, chroma smear.
#
# Runs BEFORE the final SVT-AV1 encode, producing a video-only restored
# INTERMEDIATE file that the rest of the pipeline substitutes as
# `video_src` -- exactly the pattern ves-qtgmc.sh already established
# (audio/subs/chapters/metadata still come from the original $src). It is
# NOT a pipe; it is a file-path swap, so nothing downstream needs new
# plumbing.
#
# DESIGN NOTES (2026-09-06, from the AGY research doc + Codex/Cursor
# review -- orchestration/regional-survey/docs/sd_restoration_*_20260906.md):
#   * This is the SMALLEST CORRECT FIRST INCREMENT, deliberately narrower
#     than the full research chain. It proves the fleet-safety-critical
#     parts: classification, temporary restored-source substitution,
#     same-representation VMAF, cleanup, fallback.
#   * The single biggest failure mode is WRONG AUTOMATIC CLASSIFICATION --
#     one bad IVTC / QTGMC / deblock decision permanently damages motion,
#     faces or line detail across a whole title. So: conservative gate,
#     reuse the already-reviewed field-mode detector, and only two
#     structural modes (hard-telecine IVTC, genuine-interlace QTGMC).
#   * NO automatic denoise / chroma-warp / znedi3 / ML upscale here. Those
#     are later increments, added one filter-family at a time behind their
#     own flags after known-title A/B results exist. Upscaling stays the
#     job of the existing resolve_upscale_target() on the (restored)
#     video_src downstream.
#   * OFF BY DEFAULT. `RESTORE_SD_ENABLE=true` (or a per-title marker, see
#     sd_restore_marker_path) opts a run in. Analysis telemetry is logged
#     regardless so we can calibrate the gate against real titles before
#     trusting it.
#
# Toolchain: reuses the QTGMC toolchain from
# fleet-tools/install-qtgmc-{fedora,ubuntu,macos}.sh (ves-qtgmc.sh) for the
# interlace path; the telecine path is ffmpeg-native (fieldmatch,decimate)
# and always available. Degrades gracefully to a plain normal encode when
# anything is missing -- same contract as mkvalidator / ab-av1 / QTGMC.

# ---------------------------------------------------------------------------
# Config surface (real defaults live in ves-config.sh; these are the
# fallbacks so the module is safe to source standalone / in tests).
# ---------------------------------------------------------------------------
: "${RESTORE_SD_ENABLE:=false}"              # master switch (off = telemetry only)
: "${RESTORE_SD_EXPERIMENTAL:=false}"        # allow the progressive/ambiguous
                                            #   (non-structural) restore paths
: "${RESTORE_SD_DEBLOCK:=off}"               # off | light  -- pinned ffmpeg deblock
: "${RESTORE_SD_MAX_HEIGHT:=576}"            # only SD/sub-HD sources are candidates
: "${RESTORE_SD_BPPPF_MAX:=0.065}"           # low bits-per-pixel-per-frame => degraded
                                            #   (TELEMETRY LABEL until calibrated)
: "${RESTORE_SD_COMB_MIN:=0.05}"             # idet combed-frame ratio trigger
: "${RESTORE_SD_ANALYZE_WINDOWS:=3}"        # probe windows
: "${RESTORE_SD_ANALYZE_SECS:=12}"          # seconds per probe window
: "${RESTORE_SD_PROFILES:=vintage vtv standup concert canime wanime}"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

_sdr_log()  { log_err "sd-restore: $*"; }
_sdr_warn() { warn "sd-restore: $*"; }

# Where an orchestrator can drop a per-title marker to force the restore
# path on (or record the analyzer's verdict) without flipping the global
# RESTORE_SD_ENABLE. Marker content = the analyzer's one-line verdict.
sd_restore_marker_path() {  # src -> path
  local src="$1" dir
  dir="$(media_content_dir "$src" 2>/dev/null)" || dir="$(dirname -- "$src")"
  printf '%s/.ves-sd-restore' "$dir"
}

_sdr_profile_eligible() {  # profile -> 0 if in RESTORE_SD_PROFILES
  local p="$1" x
  for x in $RESTORE_SD_PROFILES; do [ "$x" = "$p" ] && return 0; done
  return 1
}

# ---------------------------------------------------------------------------
# Pass 1: cheap analysis / telemetry.
# Prints ONE line:  verdict=<restore|skip|forced> class=<telecine|interlaced|
#   progressive|ambiguous> w=<W> h=<H> bpppf=<f> comb=<r> mustelim=<0|1>
#   reason="<...>"
# Always safe to call (read-only ffprobe/idet). Also emitted to the log.
# ---------------------------------------------------------------------------
sd_restore_analyze() {  # src [profile]
  local src="$1" profile="${2:-}"
  local metrics dw dh fps br bpppf
  metrics="$(video_display_metrics "$src" 2>/dev/null)" || metrics="0 0 0 0 0"
  read -r dw dh fps br bpppf <<<"$metrics"
  local h_int="${dh%.*}"; [[ "$h_int" =~ ^[0-9]+$ ]] || h_int=0

  local mustelim=0
  if is_must_eliminate_format "$src" 2>/dev/null; then mustelim=1; fi
  # codec-level "must eliminate" (container may be .mkv but stream is DivX/MS-MPEG4)
  local vcodec=""; vcodec="$(video_codec "$src" 2>/dev/null | to_lower 2>/dev/null || true)"
  case "$vcodec" in mpeg4|msmpeg4v1|msmpeg4v2|msmpeg4v3|rv10|rv20|rv30|rv40|wmv1|wmv2|wmv3|vc1) mustelim=1 ;; esac

  # field-mode classification -- reuse the already-reviewed detector.
  local class="ambiguous"
  if declare -F detect_source_traits >/dev/null 2>&1; then
    detect_source_traits "$src" >/dev/null 2>&1 || true
    class="$(source_traits_field_mode "$src" 2>/dev/null || true)"
    { [ -n "$class" ] && [ "$class" != unknown ]; } || class="ambiguous"
  fi

  # combed-frame ratio over a few short windows (idet). Cheap; ~<5s CPU.
  local comb="0"
  comb="$(_sdr_comb_ratio "$src")"

  # --- candidacy + verdict -------------------------------------------------
  local sd_candidate=0
  if [ "$mustelim" = 1 ]; then sd_candidate=1
  elif [ "$h_int" -gt 0 ] && [ "$h_int" -le "$RESTORE_SD_MAX_HEIGHT" ] && \
       awk -v b="$bpppf" -v t="$RESTORE_SD_BPPPF_MAX" 'BEGIN{exit !(b>0 && b<t)}'; then
    sd_candidate=1
  fi

  local metric_trigger=0
  if awk -v c="$comb" -v t="$RESTORE_SD_COMB_MIN" 'BEGIN{exit !(c>=t)}'; then metric_trigger=1; fi
  case "$class" in telecine|interlaced) metric_trigger=1 ;; esac

  local verdict reason mk; mk="$(sd_restore_marker_path "$src")"
  if [ -f "$mk" ] && grep -q '^force' "$mk" 2>/dev/null; then
    verdict="forced"; reason="per-title marker"
  elif [ "$sd_candidate" = 1 ] && [ "$metric_trigger" = 1 ]; then
    verdict="restore"; reason="sd_candidate + metric_trigger (class=$class comb=$comb bpppf=$bpppf)"
  elif [ "$sd_candidate" = 1 ]; then
    verdict="skip"; reason="SD/legacy but no metric trigger (looks clean)"
  else
    verdict="skip"; reason="not an SD/legacy candidate (h=$h_int bpppf=$bpppf)"
  fi

  local line
  line="verdict=$verdict class=$class w=${dw%.*} h=$h_int bpppf=$bpppf comb=$comb mustelim=$mustelim reason=\"$reason\""
  _sdr_log "analyze $(basename -- "$src") -> $line"
  printf '%s\n' "$line"
}

# idet combed-frame ratio over N short windows. Reuses the already-reviewed,
# timeout-wrapped, errexit-safe _idet_probe_window() from ves-source-traits.sh
# (prints "prog interlaced rn rt rb tff bff", non-zero on failure). Fails
# CLOSED to 0 -- a probe miss must never abort a job or spuriously trigger
# restoration.
_sdr_comb_ratio() {  # src -> float 0..1
  local src="$1" dur start i probe prog inter _rn _rt _rb _tff _bff
  local n="${RESTORE_SD_ANALYZE_WINDOWS:-3}" secs="${RESTORE_SD_ANALYZE_SECS:-12}"
  local w; w="$(video_width "$src" 2>/dev/null)"; [[ "$w" =~ ^[0-9]+$ ]] || w=640
  dur="$(video_duration "$src" 2>/dev/null || true)"; dur="${dur%.*}"
  [[ "$dur" =~ ^[0-9]+$ ]] && [ "$dur" -gt 0 ] || { printf '0'; return 0; }
  local tot_i=0 tot_all=0
  for ((i=1; i<=n; i++)); do
    start=$(( dur * i / (n + 1) ))
    if declare -F _idet_probe_window >/dev/null 2>&1; then
      probe="$(_idet_probe_window "$src" "$start" "$secs" 2>/dev/null || true)"
      [ -n "$probe" ] || continue
      read -r prog inter _rn _rt _rb _tff _bff <<<"$probe"
      [[ "$prog" =~ ^[0-9]+$ ]] && [[ "$inter" =~ ^[0-9]+$ ]] || continue
      tot_i=$(( tot_i + inter )); tot_all=$(( tot_all + prog + inter ))
    fi
  done
  awk -v i="$tot_i" -v tot="$tot_all" 'BEGIN{ if(tot>0) printf "%.3f", i/tot; else printf "0" }'
}

# Preflight: is there enough scratch for a lossless SD intermediate? Rough
# upper bound = duration_s * width * height * 3 bytes/px/frame_at_the_fps
# ... simplified to a generous per-minute SD estimate + headroom. Fails
# CLOSED (returns 1 = "no") on any uncertainty so restoration never starts
# a render it can't finish.
_sdr_space_ok() {  # src
  local src="$1" dur mins need_bytes free_bytes dir
  dir="${RAMDISK_JOB_DIR:-${TMPDIR:-/tmp}}"
  dur="$(video_duration "$src" 2>/dev/null || true)"; dur="${dur%.*}"
  [[ "$dur" =~ ^[0-9]+$ ]] && [ "$dur" -gt 0 ] || return 1
  mins=$(( (dur + 59) / 60 ))
  # ~120 MB / minute is a safe ceiling for FFV1 SD 8-bit (real SD FFV1 runs
  # 50-100 MB/min); x1.5 for a deblock-rewrite temp briefly coexisting with
  # its input, + 512 MB slack.
  need_bytes=$(( (mins * 120 * 3 / 2 + 512) * 1024 * 1024 ))
  if declare -F _dir_free_bytes >/dev/null 2>&1; then
    free_bytes="$(_dir_free_bytes "$dir" 2>/dev/null || true)"
  else
    free_bytes="$(df -k "$dir" 2>/dev/null | awk 'NR==2{print $4*1024}')"
  fi
  [[ "$free_bytes" =~ ^[0-9]+$ ]] || return 1
  if [ "$free_bytes" -lt "$need_bytes" ]; then
    _sdr_warn "insufficient scratch in $dir: need ~$(( need_bytes / 1024 / 1024 ))MB, have $(( free_bytes / 1024 / 1024 ))MB -- normal encode"
    return 1
  fi
  return 0
}

# Pixel format for the intermediate: keep the source's own bit depth. 10-bit
# FFV1 from an 8-bit SD source preserves nothing extra and just inflates the
# scratch footprint (Codex review). Only promote to 10-bit for genuinely
# >8-bit sources.
_sdr_inter_pixfmt() {  # src
  local src="$1" depth
  depth="$(run_ffprobe -v error -select_streams v:0 -show_entries stream=bits_per_raw_sample -of csv=p=0 "$src" 2>/dev/null | head -1 || true)"
  [[ "$depth" =~ ^[0-9]+$ ]] && [ "$depth" -gt 8 ] && { printf 'yuv420p10le'; return; }
  printf 'yuv420p'
}

# ---------------------------------------------------------------------------
# The gate the encode path calls.  0 => run sd_restore_to_intermediate.
# ---------------------------------------------------------------------------
sd_restore_should_restore() {  # src profile
  local src="$1" profile="${2:-}"
  # global switch OR a per-title force marker
  local marker; marker="$(sd_restore_marker_path "$src")"
  if [ "$RESTORE_SD_ENABLE" != true ]; then
    [ -f "$marker" ] && grep -q '^force' "$marker" 2>/dev/null || return 1
  fi
  _sdr_profile_eligible "$profile" || { _sdr_log "profile '$profile' not restore-eligible"; return 1; }

  local verdict=""
  verdict="$(sd_restore_analyze "$src" "$profile" 2>/dev/null | sed -n 's/^verdict=\([a-z]*\).*/\1/p' || true)"
  case "$verdict" in
    restore|forced) return 0 ;;
    *)              return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Produce the restored video-only intermediate.  Prints its path on success
# (caller swaps it in as video_src and owns cleanup of $(dirname) via a
# RETURN trap, exactly like the QTGMC caller). Non-zero => caller keeps the
# original source (normal encode).
# ---------------------------------------------------------------------------
sd_restore_to_intermediate() {  # src profile -> prints intermediate path | fail
  local src="$1" profile="${2:-}"
  _sdr_space_ok "$src" || return 1
  local class; class="$(source_traits_field_mode "$src" 2>/dev/null || true)"
  [ -n "$class" ] && [ "$class" != unknown ] || class="ambiguous"

  # Structural mode selection -- ONLY the two safe modes unless the operator
  # explicitly opted into the experimental (progressive/ambiguous) path.
  case "$class" in
    interlaced)
      # reuse the reviewed QTGMC path verbatim
      if declare -F qtgmc_deinterlace_to_intermediate >/dev/null 2>&1 && qtgmc_available; then
        _sdr_log "structural mode: QTGMC (genuine interlace) for $(basename -- "$src")"
        local q; q="$(qtgmc_deinterlace_to_intermediate "$src")" && [ -s "$q" ] || {
          _sdr_warn "QTGMC failed -- normal encode"; return 1; }
        _sdr_maybe_deblock "$q" "$src" "$profile"
        return 0
      fi
      _sdr_warn "QTGMC toolchain unavailable -- normal encode"; return 1 ;;
    telecine)
      _sdr_log "structural mode: IVTC fieldmatch,decimate for $(basename -- "$src")"
      _sdr_ivtc_intermediate "$src" "$profile" || return 1
      return 0 ;;
    progressive|ambiguous)
      if [ "$RESTORE_SD_EXPERIMENTAL" != true ]; then
        _sdr_log "class=$class and RESTORE_SD_EXPERIMENTAL!=true -- no structural restore; normal encode"
        return 1
      fi
      # experimental: no cadence work, just the optional pinned deblock
      if [ "$RESTORE_SD_DEBLOCK" = light ]; then
        _sdr_log "experimental: light deblock only (class=$class) for $(basename -- "$src")"
        _sdr_deblock_only_intermediate "$src" "$profile" || return 1
        return 0
      fi
      _sdr_log "experimental path but nothing to do (RESTORE_SD_DEBLOCK=off) -- normal encode"
      return 1 ;;
    *) _sdr_warn "unhandled class '$class' -- normal encode"; return 1 ;;
  esac
}

_sdr_stage_dir() {  # -> mktemp -d in the job ramdisk/scratch
  mktemp -d "${RAMDISK_JOB_DIR:-${TMPDIR:-/tmp}}/.convert-stage-sdrestore-XXXXXX" 2>/dev/null
}

# pinned light deblock, appended in place: rewrites $1 through ffmpeg with a
# conservative postproc chain. Keeps 10-bit, no scaling, video-only.
_sdr_pinned_deblock_vf() {
  # ffmpeg 'pp' filter -- hb|ha (h deblock) + vb|va (v deblock) + dr (deringing),
  # all at the gentle 'a' (autoq) thresholds. Deliberately NOT spp/pp7 as a
  # first-class choice (Codex: treat those as fallbacks) -- 'pp' is the most
  # widely-built, most conservative option and ships with every fleet ffmpeg.
  printf 'pp=ha/va/dr'
}

_sdr_maybe_deblock() {  # intermediate_path original_src profile -- edits $1 in place if RESTORE_SD_DEBLOCK=light
  local inter="$1" osrc="${2:-}"
  [ "$RESTORE_SD_DEBLOCK" = light ] || { printf '%s\n' "$inter"; return 0; }
  local d; d="$(dirname -- "$inter")"
  local tmp="$d/sdrestore-deblocked.mkv"
  local pf="yuv420p"; [ -n "$osrc" ] && pf="$(_sdr_inter_pixfmt "$osrc")"
  if run_ffmpeg -hide_banner -nostdin -y -i "$inter" \
       -map 0:v:0 -vf "$(_sdr_pinned_deblock_vf)" \
       -c:v ffv1 -level 3 -pix_fmt "$pf" -an -sn \
       "$tmp" >/dev/null 2>&1 && [ -s "$tmp" ]; then
    mv -f -- "$tmp" "$inter"
    _sdr_log "applied light deblock to intermediate"
  else
    rm -f -- "$tmp" 2>/dev/null || true
    _sdr_warn "light deblock failed -- keeping un-deblocked intermediate"
  fi
  printf '%s\n' "$inter"
}

# errexit-safe SAR read (Codex FIX): a failed ffprobe|head must not abort.
_sdr_sar_suffix() {  # src -> ",setsar=N/D"  (empty when square / unknown)
  local src="$1" sar
  sar="$(run_ffprobe -v error -select_streams v:0 -show_entries stream=sample_aspect_ratio -of csv=p=0 "$src" 2>/dev/null | head -1 || true)"
  [[ "$sar" == *:* ]] && [ "$sar" != 0:1 ] && [ "$sar" != 1:1 ] || { printf ''; return 0; }
  printf ',setsar=%s' "${sar/:/\/}"
}

_sdr_ivtc_intermediate() {  # src profile -> prints path
  local src="$1" profile="${2:-}"
  local d; d="$(_sdr_stage_dir)" || { _sdr_warn "no stage dir -- normal encode"; return 1; }
  local out="$d/sdrestore-ivtc.mkv"
  local field_order; field_order="$(source_traits_field_order "$src" 2>/dev/null || true)"
  local order_arg="tff"; [ "$field_order" = bff ] && order_arg="bff"
  local vf="fieldmatch=order=${order_arg}:combmatch=full,decimate"
  [ "$RESTORE_SD_DEBLOCK" = light ] && vf="${vf},$(_sdr_pinned_deblock_vf)"
  vf="${vf}$(_sdr_sar_suffix "$src")"
  if run_ffmpeg -hide_banner -nostdin -y -i "$src" \
       -map 0:v:0 -vf "$vf" -c:v ffv1 -level 3 -pix_fmt "$(_sdr_inter_pixfmt "$src")" -an -sn \
       "$out" >/dev/null 2>&1 && [ -s "$out" ]; then
    printf '%s\n' "$out"; return 0
  fi
  _sdr_warn "IVTC ffmpeg failed -- normal encode"
  rm -rf -- "$d" 2>/dev/null || true
  return 1
}

_sdr_deblock_only_intermediate() {  # src profile -> prints path
  local src="$1"
  local d; d="$(_sdr_stage_dir)" || return 1
  local out="$d/sdrestore-deblock.mkv"
  local vf; vf="$(_sdr_pinned_deblock_vf)$(_sdr_sar_suffix "$src")"
  if run_ffmpeg -hide_banner -nostdin -y -i "$src" \
       -map 0:v:0 -vf "$vf" -c:v ffv1 -level 3 -pix_fmt "$(_sdr_inter_pixfmt "$src")" -an -sn \
       "$out" >/dev/null 2>&1 && [ -s "$out" ]; then
    printf '%s\n' "$out"; return 0
  fi
  rm -rf -- "$d" 2>/dev/null || true
  return 1
}

# ---------------------------------------------------------------------------
# Host capability check -- what the active mode needs on THIS machine.
# 0 = ok to attempt; 1 = fall back to normal encode.
# ---------------------------------------------------------------------------
sd_restore_verify() {  # [class]
  local class="${1:-}" filters
  command -v ffmpeg >/dev/null 2>&1 || { _sdr_warn "no ffmpeg"; return 1; }
  filters="$(run_ffmpeg -hide_banner -filters 2>/dev/null || true)"

  # 'pp' filter present? (needed only when deblock=light) -- degrade, don't fail.
  if [ "$RESTORE_SD_DEBLOCK" = light ] && ! grep -qw 'pp' <<<"$filters"; then
    _sdr_warn "ffmpeg built without 'pp' -- disabling deblock for this host"
    RESTORE_SD_DEBLOCK=off
  fi

  case "$class" in
    telecine)
      grep -qw 'fieldmatch' <<<"$filters" && grep -qw 'decimate' <<<"$filters" || {
        _sdr_warn "ffmpeg lacks fieldmatch/decimate -- normal encode"; return 1; }
      run_ffmpeg -hide_banner -encoders 2>/dev/null | grep -qw 'ffv1' || {
        _sdr_warn "ffmpeg lacks ffv1 encoder -- normal encode"; return 1; } ;;
    interlaced)
      qtgmc_available || { _sdr_warn "QTGMC unavailable on this host -- normal encode"; return 1; } ;;
  esac
  return 0
}
