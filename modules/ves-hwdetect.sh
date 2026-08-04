#!/usr/bin/env bash
# ves-hwdetect.sh -- GPU/hardware-encoder capability detection (NVENC, QSV,
# AMD VCE/VAAPI, VideoToolbox), ffmpeg filter/encoder probing, and the
# svtav1/x265 version-fingerprint machinery used to invalidate stale
# tool-version tags. Pure move from the former monolithic script -- no
# logic changes.

_handbrake_reports_nvenc() {
  local candidate="$1"
  [ -n "$candidate" ] || return 1
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$PLATFORM" = wsl ] && [[ "$candidate" == *.exe ]]; then
    sudo_drop_user "$SUDO_USER" "$candidate" --help 2>&1 | search_cie 'nvenc: version [0-9]|nvenc_av1_10bit|nvenc_h265'
  else
    "$candidate" --help 2>&1 | search_cie 'nvenc: version [0-9]|nvenc_av1_10bit|nvenc_h265'
  fi
}

_configure_qsv_runtime_env() {
  # Preserve prior LIBVA so AMD VAAPI can restore after a failed QSV probe.
  _CONVERT_SAVED_LIBVA_DRIVER_NAME="${LIBVA_DRIVER_NAME-__unset__}"
  export LIBVA_DRIVER_NAME=iHD
  export LIBVA_DRI3_DISABLE="${LIBVA_DRI3_DISABLE:-1}"
}

_restore_libva_after_qsv_probe() {
  if [ "${_CONVERT_SAVED_LIBVA_DRIVER_NAME-__unset__}" = "__unset__" ]; then
    unset LIBVA_DRIVER_NAME 2>/dev/null || true
  else
    export LIBVA_DRIVER_NAME="$_CONVERT_SAVED_LIBVA_DRIVER_NAME"
  fi
  unset _CONVERT_SAVED_LIBVA_DRIVER_NAME 2>/dev/null || true
}

_configure_amd_vaapi_runtime_env() {
  # Dual-GPU laptops often force LIBVA_DRIVER_NAME=iHD system-wide; AMD needs radeonsi.
  export LIBVA_DRIVER_NAME=radeonsi
  export LIBVA_DRI3_DISABLE="${LIBVA_DRI3_DISABLE:-1}"
}

# Short hevc_vaapi probe on a render node (mesa-va-drivers-freeworld / radeonsi).
_probe_amd_vaapi_on_device() {
  local device="$1"
  local tmp probe_out rc ok=1 probe_err
  [ -n "$device" ] && [ -e "$device" ] || return 1
  tmp="$(mktemp -d)"
  probe_out="$tmp/out.mkv"
  _configure_amd_vaapi_runtime_env
  set +e
  # Some mesa/radeonsi driver builds SIGABRT (core dump) instead of a clean
  # nonzero exit when hevc_vaapi encode genuinely isn't supported on this
  # device/kernel combo -- rare, but real (observed on a real fleet machine,
  # 2026-07-29). A bare foreground command that dies by signal makes bash
  # itself print an alarming, unsuppressable-by-redirect "PID Aborted (core
  # dumped) <command>" line straight to the script's own stderr -- `2>&1`/
  # `>/dev/null` on the command do NOT catch it, since it's bash's own job-
  # control report on the child, not something the child itself wrote.
  # Routing the same call through a command substitution avoids this: bash
  # does not emit that report for a process that dies inside `$(...)`, the
  # exit status (134 for SIGABRT) is still captured normally via `$?`, and
  # this probe already treats any nonzero rc as "not available" -- so a
  # crash is handled exactly the same as an ordinary clean failure, just
  # without the misleading crash-looking log line. Verified directly: this
  # exact restructuring (foreground command -> command substitution) is
  # what suppresses the message, confirmed via isolated reproduction before
  # applying here.
  probe_err="$(env LIBVA_DRIVER_NAME=radeonsi LIBVA_DRI3_DISABLE="${LIBVA_DRI3_DISABLE:-1}" \
    "${FFMPEG_CMD[@]}" -y -nostdin -hide_banner -loglevel error \
    -init_hw_device "vaapi=amd:${device}" -filter_hw_device amd \
    -f lavfi -i "color=c=black:s=320x240:d=0.4" \
    -vf 'format=nv12,hwupload' -c:v hevc_vaapi -qp 28 -f matroska "$probe_out" 2>&1 >/dev/null)"
  rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$probe_out" ]; then
    ok=0
  fi
  set -e
  rm -rf "$tmp"
  return "$ok"
}

_detect_amd_vaapi_encode() {
  local device preferred="${CONVERT_AMD_VAAPI_DEVICE:-}"
  AMD_VAAPI_DEVICE=""
  [ "$PLATFORM" = linux ] || [ "$PLATFORM" = wsl ] || return 1

  if [ -n "$preferred" ]; then
    if _probe_amd_vaapi_on_device "$preferred"; then
      AMD_VAAPI_DEVICE="$preferred"
      return 0
    fi
    warn "CONVERT_AMD_VAAPI_DEVICE=$preferred failed hevc_vaapi probe"
  fi

  for device in /dev/dri/renderD*; do
    [ -e "$device" ] || continue
    if _probe_amd_vaapi_on_device "$device"; then
      AMD_VAAPI_DEVICE="$device"
      return 0
    fi
  done
  return 1
}

# Short encode probe — HandBrake may list QSV while runtime init fails (or /dev/dri missing on Linux).
# Check output size BEFORE deleting the temp dir (probe_out lives under tmp).
_probe_qsv_encode_available() {
  local tmp probe_out rc ok=1 probe_err
  tmp="$(mktemp -d)"
  probe_out="$tmp/out.mkv"
  # Routed through command substitution, not run bare in the foreground: see
  # the matching comment in _probe_amd_vaapi_on_device for why -- a driver
  # crash here would otherwise make bash print an alarming, unsuppressable
  # "Aborted (core dumped)" line even though this probe already handles any
  # nonzero exit as "not available."
  if ! probe_err="$(run_ffmpeg -y -nostdin -f lavfi -i testsrc=duration=1:size=640x360:rate=24 \
    -pix_fmt yuv420p "$tmp/in.mp4" 2>&1 >/dev/null)"; then
    rm -rf "$tmp"
    return 1
  fi
  _configure_qsv_runtime_env
  set +e
  probe_err="$(run_handbrake -i "$tmp/in.mp4" -o "$probe_out" -f mkv -e qsv_h265 -q 28 \
    --encoder-preset balanced --encopts lowpower=0 --audio none 2>&1 >/dev/null)"
  rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$probe_out" ]; then
    ok=0
  fi
  set -e
  _restore_libva_after_qsv_probe
  rm -rf "$tmp"
  return "$ok"
}

_handbrake_reports_qsv() {
  local candidate="$1"
  local hb_help
  [ -n "$candidate" ] || return 1
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$PLATFORM" = wsl ] && [[ "$candidate" == *.exe ]]; then
    hb_help="$(sudo_drop_user "$SUDO_USER" "$candidate" --help 2>&1)" || return 1
  else
    hb_help="$("$candidate" --help 2>&1)" || return 1
  fi
  _handbrake_help_lists_qsv "$hb_help"
}

_handbrake_reports_amd_vce() {
  local candidate="$1"
  [ -n "$candidate" ] || return 1
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$PLATFORM" = wsl ] && [[ "$candidate" == *.exe ]]; then
    sudo_drop_user "$SUDO_USER" "$candidate" --help 2>&1 | search_cie 'vce_h265|vce_h264|vcn_h265|vcn_h264'
  else
    "$candidate" --help 2>&1 | search_cie 'vce_h265|vce_h264|vcn_h265|vcn_h264'
  fi
}

detect_hw_environment() {
  HAS_NVIDIA=false
  HAS_INTEL_QSV=false
  HAS_AMD_VCE=false
  USE_NVIDIA_ENCODE=false
  USE_QSV_ENCODE=false
  USE_AMD_VCE_ENCODE=false
  USE_VT_ENCODE=false
  NVIDIA_GPU_COUNT=0
  NVDEC_AVAILABLE=false
  QSV_DECODE_AVAILABLE=false
  HAS_HW_DECODE=false
  HW_DECODE_NAME=""
  ACTIVE_ENCODE_MODE=software
  AMD_ENCODE_BACKEND=""
  AMD_VAAPI_DEVICE=""

  case "$PLATFORM" in
    macos)
      if _detect_videotoolbox_via_handbrake; then
        USE_VT_ENCODE=true
        ACTIVE_ENCODE_MODE=videotoolbox
        HAS_HW_DECODE=true
        HW_DECODE_NAME=videotoolbox
        log "Active encoder: VideoToolbox (vt_h265 for HEVC; AV1 via svt_av1_10bit)"
      else
        warn "VideoToolbox not available — software encoders (svt_av1_10bit, x265)"
      fi
      ;;
    linux|wsl|windows)
      if [ "${CONVERT_FORCE_NVIDIA:-}" = 1 ] || [ "${CONVERT_FORCE_NVIDIA:-}" = true ]; then
        HAS_NVIDIA=true
        NVIDIA_GPU_COUNT=1
        NVDEC_AVAILABLE=true
        log "NVIDIA encode capability forced (CONVERT_FORCE_NVIDIA)"
      else
        _detect_nvidia_via_smi || _detect_nvidia_via_handbrake || true
      fi

      if [ "${CONVERT_FORCE_INTEL_QSV:-}" = 1 ] || [ "${CONVERT_FORCE_INTEL_QSV:-}" = true ]; then
        HAS_INTEL_QSV=true
        QSV_DECODE_AVAILABLE=true
        log "Intel Quick Sync capability forced (CONVERT_FORCE_INTEL_QSV)"
      else
        _detect_intel_qsv_via_handbrake || true
      fi

      if [ "${CONVERT_FORCE_AMD_VCE:-}" = 1 ] || [ "${CONVERT_FORCE_AMD_VCE:-}" = true ]; then
        HAS_AMD_VCE=true
        if ! _detect_amd_vce_via_handbrake; then
          AMD_ENCODE_BACKEND=handbrake
          log "AMD VCE/VCN capability forced (CONVERT_FORCE_AMD_VCE); HandBrake/VAAPI probe inconclusive"
        fi
      else
        _detect_amd_vce_via_handbrake || true
      fi

      _resolve_hw_encode_priority

      if [ "$USE_NVIDIA_ENCODE" = false ] && [ "$USE_QSV_ENCODE" = false ] \
        && [ "$USE_AMD_VCE_ENCODE" = false ]; then
        warn "No hardware encoder selected — using software (svt_av1_10bit, x265)"
        if [ "$HAS_NVIDIA" = false ] && [ "$HAS_INTEL_QSV" = false ] && [ "$HAS_AMD_VCE" = false ]; then
          warn "If HandBrake shows NVENC, QSV, or VCE, set CONVERT_FORCE_NVIDIA=1, CONVERT_FORCE_INTEL_QSV=1, or CONVERT_FORCE_AMD_VCE=1"
        fi
      fi
      ;;
    *)
      warn "Unknown platform — software encoders only"
      ;;
  esac
}

_apply_active_hw_decode() {
  HAS_HW_DECODE=false
  HW_DECODE_NAME=""
  if [ "$USE_NVIDIA_ENCODE" = true ] && [ "$NVDEC_AVAILABLE" = true ]; then
    HAS_HW_DECODE=true
    HW_DECODE_NAME=nvdec
  elif [ "$USE_QSV_ENCODE" = true ] && [ "$QSV_DECODE_AVAILABLE" = true ]; then
    HAS_HW_DECODE=true
    HW_DECODE_NAME=qsv
  fi
}

_resolve_hw_encode_priority() {
  USE_NVIDIA_ENCODE=false
  USE_QSV_ENCODE=false
  USE_AMD_VCE_ENCODE=false
  ACTIVE_ENCODE_MODE=software

  if [ "${CONVERT_FORCE_NVIDIA:-}" = 1 ] || [ "${CONVERT_FORCE_NVIDIA:-}" = true ]; then
    USE_NVIDIA_ENCODE=true
    ACTIVE_ENCODE_MODE=nvenc
    _apply_active_hw_decode
    log "Active encoder: NVIDIA NVENC (forced)"
    return 0
  fi

  if [ "${CONVERT_FORCE_INTEL_QSV:-}" = 1 ] || [ "${CONVERT_FORCE_INTEL_QSV:-}" = true ]; then
    if [ "$HAS_INTEL_QSV" = true ]; then
      USE_QSV_ENCODE=true
      ACTIVE_ENCODE_MODE=qsv
      _apply_active_hw_decode
      log "Active encoder: Intel Quick Sync (forced)"
    else
      warn "CONVERT_FORCE_INTEL_QSV set but Quick Sync not available — software encoders"
    fi
    return 0
  fi

  if [ "${CONVERT_FORCE_AMD_VCE:-}" = 1 ] || [ "${CONVERT_FORCE_AMD_VCE:-}" = true ]; then
    if [ "$HAS_AMD_VCE" = true ]; then
      USE_AMD_VCE_ENCODE=true
      ACTIVE_ENCODE_MODE=amd_vce
      _apply_active_hw_decode
      log "Active encoder: AMD VCE/VCN (forced)"
    else
      warn "CONVERT_FORCE_AMD_VCE set but AMD VCE/VCN not available — software encoders"
    fi
    return 0
  fi

  if [ "${CONVERT_PREFER_INTEL_QSV:-}" = 1 ] || [ "${CONVERT_PREFER_INTEL_QSV:-}" = true ]; then
    if [ "$HAS_INTEL_QSV" = true ]; then
      USE_QSV_ENCODE=true
      ACTIVE_ENCODE_MODE=qsv
      _apply_active_hw_decode
      if [ "$HAS_NVIDIA" = true ]; then
        log "Active encoder: Intel Quick Sync (CONVERT_PREFER_INTEL_QSV; NVIDIA skipped)"
      else
        log "Active encoder: Intel Quick Sync"
      fi
    else
      warn "CONVERT_PREFER_INTEL_QSV set but Quick Sync not available — software encoders (NVIDIA skipped)"
    fi
    return 0
  fi

  if [ "${CONVERT_PREFER_AMD_VCE:-}" = 1 ] || [ "${CONVERT_PREFER_AMD_VCE:-}" = true ]; then
    if [ "$HAS_AMD_VCE" = true ]; then
      USE_AMD_VCE_ENCODE=true
      ACTIVE_ENCODE_MODE=amd_vce
      _apply_active_hw_decode
      if [ "$HAS_NVIDIA" = true ]; then
        log "Active encoder: AMD VCE/VCN (CONVERT_PREFER_AMD_VCE; NVIDIA skipped)"
      else
        log "Active encoder: AMD VCE/VCN"
      fi
    else
      warn "CONVERT_PREFER_AMD_VCE set but AMD VCE/VCN not available — software encoders (NVIDIA skipped)"
    fi
    return 0
  fi

  if [ "$HAS_NVIDIA" = true ]; then
    USE_NVIDIA_ENCODE=true
    ACTIVE_ENCODE_MODE=nvenc
    _apply_active_hw_decode
    _log_alternate_hw_encoders "NVIDIA NVENC"
    return 0
  fi

  if [ "$HAS_INTEL_QSV" = true ]; then
    USE_QSV_ENCODE=true
    ACTIVE_ENCODE_MODE=qsv
    _apply_active_hw_decode
    log "Active encoder: Intel Quick Sync"
    return 0
  fi

  if [ "$HAS_AMD_VCE" = true ]; then
    USE_AMD_VCE_ENCODE=true
    ACTIVE_ENCODE_MODE=amd_vce
    _apply_active_hw_decode
    if [ "${AMD_ENCODE_BACKEND:-}" = vaapi ]; then
      log "Active encoder: AMD VCN via VAAPI (hevc_vaapi on ${AMD_VAAPI_DEVICE})"
    else
      log "Active encoder: AMD VCE/VCN"
    fi
    return 0
  fi

  log "Active encoder: software (svt_av1_10bit, x265)"
}

_log_alternate_hw_encoders() {
  local primary="$1"
  local -a alt=()

  [ "$HAS_INTEL_QSV" = true ] && alt+=("Intel Quick Sync")
  [ "$HAS_AMD_VCE" = true ] && alt+=("AMD VCE/VCN")
  if [ "${#alt[@]}" -eq 0 ]; then
    log "Active encoder: $primary"
    return 0
  fi
  log "Active encoder: $primary (${alt[*]} also detected; use --prefer-intel-qsv or --prefer-amd-vce to override)"
}

# Resolve nvidia-smi on WSL/Cygwin where it may not be on PATH (Windows .exe still works).
_resolve_nvidia_smi() {
  local candidate

  if candidate="$(command -v nvidia-smi 2>/dev/null)"; then
    printf '%s' "$candidate"
    return 0
  fi

  for candidate in \
    /usr/lib/wsl/lib/nvidia-smi \
    /mnt/c/Windows/System32/nvidia-smi.exe \
    /cygdrive/c/Windows/System32/nvidia-smi.exe; do
    if [ -e "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

_detect_nvidia_via_smi() {
  local smi list

  if ! smi="$(_resolve_nvidia_smi)"; then
    return 1
  fi

  list="$("$smi" -L 2>/dev/null)" || list=""
  NVIDIA_GPU_COUNT="$(search_count_e '^GPU [0-9]+:' "$list")"
  if [ "${NVIDIA_GPU_COUNT:-0}" -gt 0 ]; then
    HAS_NVIDIA=true
    NVDEC_AVAILABLE=true
    log "Detected $NVIDIA_GPU_COUNT NVIDIA GPU(s) via $smi — NVENC available"
    return 0
  fi
  return 1
}

# WSL2 laptops often run Windows HandBrake with NVENC while Linux nvidia-smi is missing.
_detect_nvidia_via_handbrake() {
  local hb_help

  hb_help="$(run_handbrake --help 2>&1)" || return 1
  if ! search_cie 'nvenc: version [0-9]|nvenc_av1_10bit|nvenc_h265' <<<"$hb_help"; then
    return 1
  fi

  HAS_NVIDIA=true
  NVIDIA_GPU_COUNT=1
  if search_cie 'nvdec: is available|Use .nvdec. to enable' <<<"$hb_help"; then
    NVDEC_AVAILABLE=true
    log "HandBrake reports NVENC/NVDEC (no nvidia-smi)"
  else
    log "HandBrake reports NVENC (no nvidia-smi); hardware decode not confirmed"
  fi
  return 0
}

_detect_intel_qsv_via_handbrake() {
  local hb_help

  hb_help="$(run_handbrake --help 2>&1)" || return 1
  if ! _handbrake_help_lists_qsv "$hb_help"; then
    return 1
  fi

  if ! _probe_qsv_encode_available; then
    warn "HandBrake reports QSV but a short qsv_h265 probe failed — using software encoders"
    warn "Dual-GPU Intel Macs under Linux often need native macOS (VideoToolbox) for hardware encode"
    return 1
  fi

  HAS_INTEL_QSV=true
  if search_cie 'qsv: is available|Use .qsv. to enable' <<<"$hb_help"; then
    QSV_DECODE_AVAILABLE=true
    log "HandBrake reports Intel Quick Sync (encode + decode)"
  else
    log "HandBrake reports Intel Quick Sync encoders; hardware decode not confirmed"
  fi
  return 0
}

_detect_amd_vce_via_handbrake() {
  local hb_help

  AMD_ENCODE_BACKEND=""
  AMD_VAAPI_DEVICE=""

  hb_help="$(run_handbrake --help 2>&1)" || true
  if search_cie 'vce_h265|vce_h264|vcn_h265|vcn_h264' <<<"$hb_help"; then
    HAS_AMD_VCE=true
    AMD_ENCODE_BACKEND=handbrake
    log "HandBrake reports AMD VCE/VCN (vce_h265); no hardware decode in HandBrake"
    return 0
  fi

  # Fedora/mesa: HandBrake often lacks VCN (needs proprietary AMF). Use VAAPI on amdgpu.
  if _detect_amd_vaapi_encode; then
    HAS_AMD_VCE=true
    AMD_ENCODE_BACKEND=vaapi
    log "AMD VCN via VAAPI (ffmpeg hevc_vaapi on $AMD_VAAPI_DEVICE; HandBrake has no vce/vcn)"
    return 0
  fi

  return 1
}

_detect_videotoolbox_via_handbrake() {
  local hb_help

  hb_help="$(run_handbrake --help 2>&1)" || return 1
  if ! search_cie 'vt_h265' <<<"$hb_help"; then
    if search_cie 'vt_h264' <<<"$hb_help"; then
      log "HandBrake has vt_h264 only (no vt_h265) — HEVC will use software x265"
    fi
    return 1
  fi

  HAS_VIDEOTOOLBOX=true
  if search_ci videotoolbox <<<"$hb_help"; then
    log "HandBrake reports VideoToolbox (vt_h265 encode + videotoolbox decode)"
  else
    log "HandBrake reports VideoToolbox encoders (vt_h265)"
  fi
  return 0
}

# NVENC AV1 tune=uhq needs NVENC 13+ and a new enough FFmpeg inside HandBrake.
nvenc_av1_encopts() {
  printf 'spatial-aq=1:temporal-aq=1:rc-lookahead=32:tune=%s' "$NVENC_AV1_TUNE"
}

_apply_nvenc_av1_tune_override() {
  local tune="${1:-}"
  tune="$(to_lower "$tune")"
  case "$tune" in
    hq|uhq)
      NVENC_AV1_TUNE="$tune"
      log "NVENC AV1 tune: $NVENC_AV1_TUNE (forced)"
      return 0
      ;;
    "")
      return 1
      ;;
    *)
      warn "Invalid NVENC AV1 tune '$tune' — expected hq or uhq; will auto-probe"
      return 1
      ;;
  esac
}

detect_nvenc_av1_tune() {
  local tmp probe_out probe_log saved_cuda rc
  local -a hb_args=()
  local forced_tune="${NVENC_AV1_TUNE_OVERRIDE:-${CONVERT_NVENC_AV1_TUNE:-}}"

  NVENC_AV1_TUNE=hq
  if [ "$USE_NVIDIA_ENCODE" = false ]; then
    return 0
  fi

  if _apply_nvenc_av1_tune_override "$forced_tune"; then
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    log "NVENC AV1 tune probe skipped (--dry-run) — using tune=hq"
    return 0
  fi

  if [ "${CONVERT_SKIP_NVENC_PROBE:-}" = 1 ] || [ "${CONVERT_SKIP_NVENC_PROBE:-}" = true ]; then
    log "NVENC AV1 tune probe skipped (CONVERT_SKIP_NVENC_PROBE) — using tune=hq"
    return 0
  fi

  log "NVENC AV1 tune probe: short test encode (${HANDBRAKE_DISPLAY})"

  tmp="$(mktemp -d)" || { warn "NVENC AV1 tune probe: mktemp failed — using tune=hq"; return 0; }
  probe_out="$tmp/probe.mkv"
  probe_log="$tmp/probe.log"

  if ! run_ffmpeg -y -nostdin -f lavfi -i testsrc=duration=1:size=640x360:rate=24 \
    -pix_fmt yuv420p "$tmp/in.mp4" >/dev/null 2>&1; then
    rm -rf "$tmp"
    warn "NVENC AV1 tune probe skipped (test clip failed) — using tune=hq"
    return 0
  fi

  saved_cuda="${CUDA_VISIBLE_DEVICES:-}"
  export CUDA_VISIBLE_DEVICES="${GPU_AV1:-0}"

  hb_args=(
    -i "$tmp/in.mp4" -o "$probe_out" -f mkv
    -e nvenc_av1_10bit -q 28 --encoder-preset slowest
    --encopts 'spatial-aq=1:temporal-aq=1:rc-lookahead=32:tune=uhq'
    --audio none
  )
  if [ "$HANDBRAKE_USE_WIN_PATHS" = true ]; then
    _handbrake_translate_argv hb_args
  fi

  # timeout execs an external command directly -- it can't wrap a shell
  # function (sudo_drop_user), so the WSL_INTEROP forwarding is inlined here
  # as a plain sudo argument instead (sudo VAR=val -u user is a supported
  # invocation form independent of env_reset).
  local -a sudo_env=()
  if [ "$PLATFORM" = wsl ] && [ -n "${WSL_INTEROP:-}" ]; then
    sudo_env=(WSL_INTEROP="$WSL_INTEROP")
  fi

  set +e
  if command -v timeout >/dev/null 2>&1; then
    if [ -n "$HANDBRAKE_DROP_TO_USER" ]; then
      timeout 120 sudo "${sudo_env[@]}" -u "$HANDBRAKE_DROP_TO_USER" -H -- "${HANDBRAKE_CMD[@]}" "${hb_args[@]}" >"$probe_log" 2>&1
    else
      timeout 120 "${HANDBRAKE_CMD[@]}" "${hb_args[@]}" >"$probe_log" 2>&1
    fi
  elif [ -n "$HANDBRAKE_DROP_TO_USER" ]; then
    sudo "${sudo_env[@]}" -u "$HANDBRAKE_DROP_TO_USER" -H -- "${HANDBRAKE_CMD[@]}" "${hb_args[@]}" >"$probe_log" 2>&1
  else
    _handbrake_exec "${HANDBRAKE_CMD[@]}" "${hb_args[@]}" >"$probe_log" 2>&1
  fi
  rc=$?
  set -e

  if [ -n "$saved_cuda" ]; then
    export CUDA_VISIBLE_DEVICES="$saved_cuda"
  else
    unset CUDA_VISIBLE_DEVICES 2>/dev/null || CUDA_VISIBLE_DEVICES=
  fi

  if [ "$rc" -eq 124 ]; then
    warn "NVENC AV1 tune probe timed out — using tune=hq"
  elif [ "$rc" -eq 0 ] && [ -s "$probe_out" ] && \
    ! search_cie 'Unable to parse option value "uhq"|Error setting option tune|encavcodecInit: avcodec_open failed' "$probe_log"; then
    NVENC_AV1_TUNE=uhq
    log "NVENC AV1 tune probe: tune=uhq supported — using uhq"
  else
    if [ "$rc" -ne 0 ]; then
      warn "NVENC AV1 tune probe encode failed (rc=$rc) — using tune=hq"
      [ -s "$probe_log" ] && tail -3 "$probe_log" >&2 || true
    else
      log "NVENC AV1 tune probe: tune=uhq unavailable — using tune=hq"
    fi
  fi

  rm -rf "$tmp"
}

svtav1_supports_sharpness() {
  if [ -z "$FF_SVTAV1_SUPPORTS_SHARPNESS" ]; then
    local out
    out="$("${FFMPEG_CMD[@]}" -hide_banner -f lavfi -i "color=c=black:s=64x64:d=1" \
      -c:v libsvtav1 -svtav1-params "sharpness=0" -f null - 2>&1)" || true
    if printf '%s' "$out" | grep -qi "error parsing option sharpness"; then
      FF_SVTAV1_SUPPORTS_SHARPNESS=false
      warn "This machine's SVT-AV1 build doesn't support 'sharpness' — omitting it from encode profiles (upgrade libsvtav1 to restore it)"
    else
      FF_SVTAV1_SUPPORTS_SHARPNESS=true
    fi
  fi
  [ "$FF_SVTAV1_SUPPORTS_SHARPNESS" = true ]
}

current_svtav1_major_minor() {
  if [ -z "$CURRENT_SVTAV1_MAJOR_MINOR" ]; then
    local out ver
    out="$("${FFMPEG_CMD[@]}" -hide_banner -f lavfi -i "color=c=black:s=64x64:d=1" \
      -c:v libsvtav1 -f null - 2>&1)" || true
    # The version line is "SVT [version]:<tab>SVT-AV1 Encoder Lib v4.1.0-...",
    # not "SVT [version]: v4.1.0" -- grep the whole line, then pull the
    # version token out of it, rather than anchoring right after the label.
    # Trailing `|| true` (team review, 2026-07-22): a future SVT-AV1 build
    # changing its banner text would make BOTH greps miss, and under
    # `set -o pipefail` that non-zero status would abort the whole script
    # right here -- fleet-wide, on every machine, the moment they upgrade --
    # instead of gracefully falling back to "unknown" like the line below
    # already intends. Verified via direct bash testing.
    ver="$(printf '%s' "$out" | grep -i 'SVT \[version\]' | grep -oE 'v[0-9]+\.[0-9]+' | head -1)" || true
    ver="${ver#v}"
    CURRENT_SVTAV1_MAJOR_MINOR="${ver:-unknown}"
  fi
  printf '%s' "$CURRENT_SVTAV1_MAJOR_MINOR"
}

current_x265_major_minor() {
  if [ -z "$CURRENT_X265_MAJOR_MINOR" ]; then
    local out ver
    out="$("${FFMPEG_CMD[@]}" -hide_banner -f lavfi -i "color=c=black:s=64x64:d=1" \
      -c:v libx265 -f null - 2>&1)" || true
    # Trailing `|| true`: same reasoning as current_svtav1_major_minor above
    # -- a banner-text mismatch must fall back to "unknown", not crash the
    # whole script (team review, 2026-07-22).
    ver="$(printf '%s' "$out" | grep -oE 'HEVC encoder version [0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+' | head -1)" || true
    CURRENT_X265_MAJOR_MINOR="${ver:-unknown}"
  fi
  printf '%s' "$CURRENT_X265_MAJOR_MINOR"
}

current_tools_fingerprint() {
  if [ -z "$TOOLS_FINGERPRINT" ]; then
    TOOLS_FINGERPRINT="svtav1=$(current_svtav1_major_minor);x265=$(current_x265_major_minor)"
  fi
  printf '%s' "$TOOLS_FINGERPRINT"
}

_fp_field() {  # fingerprint_string key -> value
  local fp="$1" key="$2" pair
  local -a pairs=()
  IFS=';' read -ra pairs <<<"$fp"
  for pair in "${pairs[@]}"; do
    case "$pair" in
      "$key="*) printf '%s' "${pair#*=}"; return 0 ;;
    esac
  done
}

# 0 (true) only if cur is a strictly newer MAJOR.MINOR than recorded.
_version_major_minor_newer() {
  local cur="$1" recorded="$2"
  [ -n "$cur" ] && [ -n "$recorded" ] || return 1
  [ "$cur" != "unknown" ] && [ "$recorded" != "unknown" ] || return 1
  local cur_maj="${cur%%.*}" cur_min="${cur#*.}"
  local rec_maj="${recorded%%.*}" rec_min="${recorded#*.}"
  [[ "$cur_maj" =~ ^[0-9]+$ ]] && [[ "$cur_min" =~ ^[0-9]+$ ]] || return 1
  [[ "$rec_maj" =~ ^[0-9]+$ ]] && [[ "$rec_min" =~ ^[0-9]+$ ]] || return 1
  [ "$cur_maj" -gt "$rec_maj" ] && return 0
  [ "$cur_maj" -eq "$rec_maj" ] && [ "$cur_min" -gt "$rec_min" ] && return 0
  return 1
}

# True (0) only when a REAL recorded fingerprint exists AND this machine's
# svtav1 or x265 is a strictly newer major.minor than what's on record. An
# empty/missing fingerprint is never "stale" -- see the design note above.
tools_fingerprint_is_stale() {
  local recorded="$1"
  [ -n "$recorded" ] || return 1
  local cur_fp cur_svtv cur_x265v rec_svtv rec_x265v
  cur_fp="$(current_tools_fingerprint)"
  cur_svtv="$(_fp_field "$cur_fp" svtav1)"
  cur_x265v="$(_fp_field "$cur_fp" x265)"
  rec_svtv="$(_fp_field "$recorded" svtav1)"
  rec_x265v="$(_fp_field "$recorded" x265)"
  _version_major_minor_newer "$cur_svtv" "$rec_svtv" && return 0
  _version_major_minor_newer "$cur_x265v" "$rec_x265v" && return 0
  return 1
}

current_tool_versions_tag_suffix() {
  if [ -z "$TOOL_VERSIONS_TAG_SUFFIX" ]; then
    # Every piece computed separately with its own `|| ...` fallback, rather
    # than embedding bare command substitutions directly in the final
    # assignment -- under set -e, any one of them failing (ffmpeg/mkvmerge
    # missing or erroring) would otherwise abort the script mid-tag-write
    # instead of falling back to "unknown" the way the interpolation implies.
    # Team review (2026-07-24).
    local ffv mkvv svtv x265v
    ffv="$("${FFMPEG_CMD[@]}" -version 2>&1 | head -1 | awk '{print $3}')" || ffv=""
    mkvv="$(run_mkvmerge --version 2>&1 | awk '{print $2}' | tr -d 'v')" || mkvv=""
    svtv="$(current_svtav1_major_minor)" || svtv=""
    x265v="$(current_x265_major_minor)" || x265v=""
    TOOL_VERSIONS_TAG_SUFFIX=" [tools: ffmpeg=${ffv:-unknown};svtav1=${svtv:-unknown};x265=${x265v:-unknown};mkvmerge=${mkvv:-unknown}]"
  fi
  printf '%s' "$TOOL_VERSIONS_TAG_SUFFIX"
}

ffmpeg_lists_filter() {
  # no grep -q: with pipefail, early grep exit SIGPIPEs ffmpeg and fails the pipeline
  run_ffmpeg -hide_banner -filters 2>/dev/null | grep " $1 " >/dev/null 2>&1
}

ffmpeg_lists_encoder() {
  run_ffmpeg -hide_banner -encoders 2>/dev/null | grep -E "^ [A-Z.]{6} $1 " >/dev/null 2>&1
}

# Functional probe: a 1s synthetic encode. Compiled-in but broken encoders
# (wrong GPU generation, missing driver, no /dev/dri access) fail here.
probe_ffmpeg_encoder() {
  local enc="$1"
  local -a pre=()
  case "$enc" in
    *_vaapi)
      local dev
      for dev in /dev/dri/renderD*; do
        [ -e "$dev" ] || continue
        if run_ffmpeg -y -v error -vaapi_device "$dev" \
             -f lavfi -i "testsrc2=duration=1:size=640x360:rate=24" \
             -vf "format=nv12,hwupload" -c:v "$enc" -f null - >/dev/null 2>&1; then
          FF_VAAPI_DEVICE="$dev"
          return 0
        fi
      done
      return 1
      ;;
  esac
  run_ffmpeg -y -v error "${pre[@]}" \
    -f lavfi -i "testsrc2=duration=1:size=640x360:rate=24" \
    -c:v "$enc" -f null - >/dev/null 2>&1
}

detect_ffmpeg_capabilities() {
  ffmpeg_lists_filter  "libvmaf"    && FF_HAS_LIBVMAF=true
  ffmpeg_lists_filter  "libplacebo" && FF_HAS_LIBPLACEBO=true
  ffmpeg_lists_encoder "libsvtav1"  && FF_HAS_LIBSVTAV1=true
  ffmpeg_lists_encoder "libx265"    && FF_HAS_LIBX265=true
  ffmpeg_lists_encoder "libopus"    && FF_HAS_LIBOPUS=true
  AB_AV1_BIN="$(command -v ab-av1 2>/dev/null || true)"

  # Hardware encoders: probe in quality-per-bit order, keep the first that works.
  local enc
  for enc in av1_nvenc av1_qsv av1_vaapi; do
    ffmpeg_lists_encoder "$enc" && probe_ffmpeg_encoder "$enc" && { FF_AV1_HW="$enc"; break; }
  done
  for enc in hevc_nvenc hevc_qsv hevc_videotoolbox hevc_vaapi hevc_amf; do
    ffmpeg_lists_encoder "$enc" && probe_ffmpeg_encoder "$enc" && { FF_HEVC_HW="$enc"; break; }
  done

  log "ffmpeg caps: libvmaf=$FF_HAS_LIBVMAF svtav1=$FF_HAS_LIBSVTAV1 x265=$FF_HAS_LIBX265 libplacebo=$FF_HAS_LIBPLACEBO ab-av1=${AB_AV1_BIN:-no}"
  log "ffmpeg hw encoders (functional probe): av1=${FF_AV1_HW:-none} hevc=${FF_HEVC_HW:-none}"

  if [ "$ENCODE_ENGINE" = auto ]; then
    if [ "$FF_HAS_LIBSVTAV1" = true ] && [ "$FF_HAS_LIBX265" = true ]; then
      ENCODE_ENGINE=ffmpeg
    else
      warn "ffmpeg lacks libsvtav1/libx265 — falling back to HandBrake engine (install a full ffmpeg build for VMAF-targeted encoding)"
      ENCODE_ENGINE=handbrake
    fi
  fi
  if [ "$ENCODE_ENGINE" = ffmpeg ] && [ "$FF_HAS_LIBVMAF" != true ] && [ "$VMAF_DISABLED" != true ]; then
    warn "ffmpeg has no libvmaf — VMAF targeting disabled, using fixed CRFs (install a libvmaf-enabled ffmpeg, e.g. BtbN static build, for per-title quality targeting)"
    VMAF_DISABLED=true
  fi
  log "encode engine: $ENCODE_ENGINE (files)$( [ "$ENCODE_ENGINE" = ffmpeg ] && printf '; HandBrake retained for disc sources' )"
}
