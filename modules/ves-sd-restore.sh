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
  is_must_eliminate_format "$src" && mustelim=1
  # codec-level "must eliminate" (container may be .mkv but stream is DivX/MS-MPEG4)
  local vcodec; vcodec="$(video_codec "$src" 2>/dev/null | to_lower)"
  case "$vcodec" in mpeg4|msmpeg4v1|msmpeg4v2|msmpeg4v3|rv10|rv20|rv30|rv40|wmv1|wmv2|wmv3|vc1) mustelim=1 ;; esac

  # field-mode classification -- reuse the already-reviewed detector.
  local class="ambiguous"
  if declare -F detect_source_traits >/dev/null 2>&1; then
    detect_source_traits "$src" >/dev/null 2>&1 || true
    class="$(source_traits_field_mode "$src" 2>/dev/null)"
    [ -n "$class" ] && [ "$class" != unknown ] || class="ambiguous"
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
  awk -v c="$comb" -v t="$RESTORE_SD_COMB_MIN" 'BEGIN{exit !(c>=t)}' && metric_trigger=1
  [ "$class" = telecine ] || [ "$class" = interlaced ] && metric_trigger=1

  local verdict reason
  if [ -f "$(sd_restore_marker_path "$src")" ] && \
     grep -q '^force' "$(sd_restore_marker_path "$src")" 2>/dev/null; then
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

# idet combed-frame ratio: mean of "interlaced" over N short windows / total.
_sdr_comb_ratio() {  # src -> float 0..1
  local src="$1" dur start i n="${RESTORE_SD_ANALYZE_WINDOWS:-3}" secs="${RESTORE_SD_ANALYZE_SECS:-12}"
  dur="$(video_duration "$src" 2>/dev/null)"; dur="${dur%.*}"
  [[ "$dur" =~ ^[0-9]+$ ]] && [ "$dur" -gt 0 ] || { printf '0'; return; }
  local total_tff=0 total_bff=0 total_prog=0 total_undet=0
  for ((i=1; i<=n; i++)); do
    start=$(( dur * i / (n + 1) ))
    local out
    out="$(run_ffmpeg -hide_banner -nostats -ss "$start" -t "$secs" -i "$src" \
            -vf idet -an -f null - 2>&1 | grep -E 'Multi frame detection' | tail -1)"
    local tff bff prog undet
    tff="$(sed -n 's/.*TFF: *\([0-9]\+\).*/\1/p' <<<"$out")"
    bff="$(sed -n 's/.*BFF: *\([0-9]\+\).*/\1/p' <<<"$out")"
    prog="$(sed -n 's/.*Progressive: *\([0-9]\+\).*/\1/p' <<<"$out")"
    undet="$(sed -n 's/.*Undetermined: *\([0-9]\+\).*/\1/p' <<<"$out")"
    total_tff=$(( total_tff + ${tff:-0} ))
    total_bff=$(( total_bff + ${bff:-0} ))
    total_prog=$(( total_prog + ${prog:-0} ))
    total_undet=$(( total_undet + ${undet:-0} ))
  done
  awk -v i=$(( total_tff + total_bff )) -v tot=$(( total_tff + total_bff + total_prog + total_undet )) \
    'BEGIN{ if(tot>0) printf "%.3f", i/tot; else printf "0" }'
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

  local verdict
  verdict="$(sd_restore_analyze "$src" "$profile" | sed -n 's/^verdict=\([a-z]*\).*/\1/p')"
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
  local class; class="$(source_traits_field_mode "$src" 2>/dev/null)"
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
  local inter="$1"
  [ "$RESTORE_SD_DEBLOCK" = light ] || { printf '%s\n' "$inter"; return 0; }
  local d; d="$(dirname -- "$inter")"
  local tmp="$d/sdrestore-deblocked.mkv"
  if run_ffmpeg -hide_banner -nostdin -y -i "$inter" \
       -map 0:v:0 -vf "$(_sdr_pinned_deblock_vf)" \
       -c:v ffv1 -level 3 -pix_fmt yuv420p10le -an -sn \
       "$tmp" >/dev/null 2>&1 && [ -s "$tmp" ]; then
    mv -f -- "$tmp" "$inter"
    _sdr_log "applied light deblock to intermediate"
  else
    rm -f -- "$tmp" 2>/dev/null || true
    _sdr_warn "light deblock failed -- keeping un-deblocked intermediate"
  fi
  printf '%s\n' "$inter"
}

_sdr_ivtc_intermediate() {  # src profile -> prints path
  local src="$1" profile="${2:-}"
  local d; d="$(_sdr_stage_dir)" || { _sdr_warn "no stage dir -- normal encode"; return 1; }
  local out="$d/sdrestore-ivtc.mkv"
  local field_order; field_order="$(source_traits_field_order "$src" 2>/dev/null)"
  local order_arg="tff"; [ "$field_order" = bff ] && order_arg="bff"
  local vf="fieldmatch=order=${order_arg}:combmatch=full,decimate"
  [ "$RESTORE_SD_DEBLOCK" = light ] && vf="${vf},$(_sdr_pinned_deblock_vf)"
  # preserve anamorphic SAR onto the fresh render (same lesson as ves-qtgmc.sh)
  local sar; sar="$(run_ffprobe -v error -select_streams v:0 -show_entries stream=sample_aspect_ratio -of csv=p=0 "$src" 2>/dev/null | head -1)"
  [[ "$sar" == *:* ]] && [ "$sar" != 0:1 ] && [ "$sar" != 1:1 ] && vf="${vf},setsar=${sar/:/\/}"
  if run_ffmpeg -hide_banner -nostdin -y -i "$src" \
       -map 0:v:0 -vf "$vf" -c:v ffv1 -level 3 -pix_fmt yuv420p10le -an -sn \
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
  local sar; sar="$(run_ffprobe -v error -select_streams v:0 -show_entries stream=sample_aspect_ratio -of csv=p=0 "$src" 2>/dev/null | head -1)"
  local vf; vf="$(_sdr_pinned_deblock_vf)"
  [[ "$sar" == *:* ]] && [ "$sar" != 0:1 ] && [ "$sar" != 1:1 ] && vf="${vf},setsar=${sar/:/\/}"
  if run_ffmpeg -hide_banner -nostdin -y -i "$src" \
       -map 0:v:0 -vf "$vf" -c:v ffv1 -level 3 -pix_fmt yuv420p10le -an -sn \
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
  local class="${1:-}"
  command -v ffmpeg >/dev/null 2>&1 || { _sdr_warn "no ffmpeg"; return 1; }
  # 'pp' filter present? (needed only when deblock=light)
  if [ "$RESTORE_SD_DEBLOCK" = light ]; then
    run_ffmpeg -hide_banner -filters 2>/dev/null | grep -qw pp || {
      _sdr_warn "ffmpeg built without 'pp' -- disabling deblock for this host"
      RESTORE_SD_DEBLOCK=off
    }
  fi
  case "$class" in
    interlaced) qtgmc_available || { _sdr_warn "QTGMC unavailable on this host"; return 1; } ;;
  esac
  return 0
}
