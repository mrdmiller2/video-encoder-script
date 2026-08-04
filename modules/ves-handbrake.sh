#!/usr/bin/env bash
# ves-handbrake.sh -- HandBrakeCLI discovery, capability probing, argv
# translation (incl. WSL Windows-path handling), and the run_handbrake/
# run_handbrake_with_progress execution wrappers. Pure move from the
# former monolithic script -- no logic changes.

configure_sudo_wsl_handbrake() {
  HANDBRAKE_DROP_TO_USER=""
  MEDIA_OWNER_USER=""
  if [ "$(id -u)" -ne 0 ]; then
    return 0
  fi
  if [ -n "${SUDO_USER:-}" ]; then
    MEDIA_OWNER_USER="$SUDO_USER"
  fi
  if [ "$PLATFORM" = wsl ] && [ "$HANDBRAKE_USE_WIN_PATHS" = true ]; then
    if [ -n "${SUDO_USER:-}" ]; then
      HANDBRAKE_DROP_TO_USER="$SUDO_USER"
      log "sudo + writable mount: HandBrake runs as $SUDO_USER; ffmpeg/mkv/file writes stay root"
    else
      warn "root without SUDO_USER — Windows HandBrake .exe may fail; invoke via: sudo $0 ... (not sudo bash)"
    fi
  fi
}

maybe_chown_for_media_user() {
  local f
  [ -n "$MEDIA_OWNER_USER" ] || return 0
  for f in "$@"; do
    # Plain chown follows a symlink and re-owns whatever it points to. This
    # only ever runs on our own outputs/sidecar files, which should never
    # legitimately be symlinks -- skip rather than risk handing ownership of
    # an unrelated real file (root running under sudo) to SUDO_USER.
    [ -n "$f" ] && [ -e "$f" ] && [ ! -L "$f" ] && chown "$MEDIA_OWNER_USER:$MEDIA_OWNER_USER" "$f" 2>/dev/null || true
  done
}

# sudo clears almost the entire environment by default, including
# WSL_INTEROP -- the socket path WSL2's Linux userspace needs to invoke a
# Windows .exe host binary at all. Running as root/sudo and dropping to a
# real user (sudo -u "$SUDO_USER") to call Windows HandBrakeCLI.exe/
# nvidia-smi.exe therefore fails with "cannot execute binary file" purely
# because of the stripped env var, not a real capability gap -- silently
# forcing software-only fallback. Forward it through explicitly.
sudo_drop_user() {
  local user="$1"
  shift
  if [ "$PLATFORM" = wsl ] && [ -n "${WSL_INTEROP:-}" ]; then
    sudo WSL_INTEROP="$WSL_INTEROP" -u "$user" -H -- "$@"
  else
    sudo -u "$user" -H -- "$@"
  fi
}

_handbrake_help_lists_qsv() {
  local hb_help="$1"
  search_cie 'qsv_h265|qsv_h264|qsv_av1' <<<"$hb_help" && return 0
  search_cie 'qsv: is available' <<<"$hb_help"
}

_wsl_windows_handbrake_candidates() {
  local candidate
  for candidate in \
    "${CONVERT_HANDBRAKE_WIN:-}" \
    "/mnt/c/Program Files/HandBrake/HandBrakeCLI.exe" \
    "/mnt/c/Program Files (x86)/HandBrake/HandBrakeCLI.exe"; do
    [ -n "$candidate" ] && [ -f "$candidate" ] && printf '%s\n' "$candidate"
  done
}

_set_handbrake_cmd() {
  local candidate="$1"
  HANDBRAKE_CMD=("$candidate")
  HANDBRAKE_DISPLAY="$candidate"
  HANDBRAKE_USE_WIN_PATHS=false
  if [ "$PLATFORM" = wsl ] && [[ "$candidate" == *.exe ]]; then
    HANDBRAKE_USE_WIN_PATHS=true
  fi
}

handbrake_path_for_exe() {
  local p="$1"
  if [ "$HANDBRAKE_USE_WIN_PATHS" = true ] && command -v wslpath >/dev/null 2>&1; then
    wslpath -w "$p" 2>/dev/null || printf '%s' "$p"
  else
    printf '%s' "$p"
  fi
}

_handbrake_translate_argv() {
  local -n _args="$1"
  local -a out=() arg mode=""
  for arg in "${_args[@]}"; do
    case "$arg" in
      -i|-o)
        out+=("$arg")
        mode=path
        ;;
      *)
        # --srt-file's comma-joined value is pre-translated at the point it's
        # built (handbrake_append_external_srts) -- re-splitting a joined
        # string on ',' here is unsafe for any subtitle path that itself
        # contains a literal comma.
        if [ "$mode" = path ]; then
          out+=("$(handbrake_path_for_exe "$arg")")
          mode=""
        else
          out+=("$arg")
        fi
        ;;
    esac
  done
  _args=("${out[@]}")
}

discover_handbrake_cli() {
  local candidate id linux_hb="" win_hb="" win_nvenc="" win_qsv="" win_amd=""

  if candidate="$(resolve_configured_tool "$TOOL_HANDBRAKE" HandBrakeCLI)"; then
    _set_handbrake_cmd "$candidate"
    return 0
  fi

  if [ "$PLATFORM" = wsl ]; then
    if candidate="$(discover_binary HandBrakeCLI)"; then
      linux_hb="$candidate"
    fi
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      if _handbrake_reports_nvenc "$candidate"; then
        win_nvenc="$candidate"
        break
      fi
      if [ -z "$win_qsv" ] && _handbrake_reports_qsv "$candidate"; then
        win_qsv="$candidate"
      fi
      if [ -z "$win_amd" ] && _handbrake_reports_amd_vce "$candidate"; then
        win_amd="$candidate"
      fi
      [ -z "$win_hb" ] && win_hb="$candidate"
    done < <(_wsl_windows_handbrake_candidates)

    if [ -n "$win_nvenc" ]; then
      _set_handbrake_cmd "$win_nvenc"
      log "WSL hybrid: Windows HandBrake (NVENC); ffmpeg/mkv tools stay on Linux PATH"
      return 0
    fi
    if [ -n "$win_qsv" ]; then
      _set_handbrake_cmd "$win_qsv"
      log "WSL hybrid: Windows HandBrake (Intel Quick Sync); ffmpeg/mkv tools stay on Linux PATH"
      return 0
    fi
    if [ -n "$win_amd" ]; then
      _set_handbrake_cmd "$win_amd"
      log "WSL hybrid: Windows HandBrake (AMD VCE/VCN); ffmpeg/mkv tools stay on Linux PATH"
      return 0
    fi
    if [ -n "$linux_hb" ] && _handbrake_reports_nvenc "$linux_hb"; then
      _set_handbrake_cmd "$linux_hb"
      return 0
    fi
    if [ -n "$linux_hb" ] && _handbrake_reports_qsv "$linux_hb"; then
      _set_handbrake_cmd "$linux_hb"
      log "Linux HandBrake reports Intel Quick Sync"
      return 0
    fi
    if [ -n "$linux_hb" ] && _handbrake_reports_amd_vce "$linux_hb"; then
      _set_handbrake_cmd "$linux_hb"
      log "Linux HandBrake reports AMD VCE/VCN"
      return 0
    fi
    if [ -n "$linux_hb" ]; then
      _set_handbrake_cmd "$linux_hb"
      if [ -n "$win_hb" ]; then
        warn "Linux HandBrake has no NVENC/QSV/AMD VCE; install Windows HandBrake or set CONVERT_HANDBRAKE to the .exe path"
      fi
      return 0
    fi
    if [ -n "$win_hb" ]; then
      _set_handbrake_cmd "$win_hb"
      warn "Using Windows HandBrake without hardware probe — set CONVERT_FORCE_NVIDIA=1, CONVERT_FORCE_INTEL_QSV=1, or CONVERT_FORCE_AMD_VCE=1 if needed"
      return 0
    fi
  else
    if candidate="$(discover_binary HandBrakeCLI)"; then
      _set_handbrake_cmd "$candidate"
      return 0
    fi
  fi

  if [ "$PLATFORM" = linux ] || [ "$PLATFORM" = wsl ]; then
    if command -v flatpak >/dev/null 2>&1; then
      for id in "${HAND_BRAKE_FLATPAK_IDS[@]}"; do
        if flatpak info "$id" >/dev/null 2>&1; then
          HANDBRAKE_CMD=(flatpak run --command=HandBrakeCLI "$id")
          HANDBRAKE_DISPLAY="flatpak run --command=HandBrakeCLI $id"
          HANDBRAKE_USE_WIN_PATHS=false
          return 0
        fi
      done
    fi
  fi

  return 1
}

detect_handbrake_cli_capabilities() {
  local hb_help=""
  HB_SUPPORTS_KEEP_SUBNAME=false
  hb_help="$(run_handbrake --help 2>&1)" || true
  if search_ci 'keep-subname' <<<"$hb_help"; then
    HB_SUPPORTS_KEEP_SUBNAME=true
  else
    log "HandBrakeCLI has no --keep-subname (older build) — omitting that flag"
  fi
}

_handbrake_exec() {
  if [ -n "$HANDBRAKE_DROP_TO_USER" ]; then
    sudo_drop_user "$HANDBRAKE_DROP_TO_USER" "$@"
  else
    "$@"
  fi
}

run_handbrake() {
  local -a hb_args=("$@")
  if [ "$HANDBRAKE_USE_WIN_PATHS" = true ]; then
    _handbrake_translate_argv hb_args
  fi
  _handbrake_exec "${HANDBRAKE_CMD[@]}" "${hb_args[@]}"
}

# Run HandBrake with --json and stream encode progress to the terminal (one job at a time).
run_handbrake_with_progress() {
  local label="$1"
  shift
  local -a hb_cmd=("${HANDBRAKE_CMD[@]}" "$@")
  local rc=0 hb_prog_dir="" hb_prog_fifo="" hb_reader_pid=0 hb_wait_pid=0 child_pid=""

  if [ "$HANDBRAKE_USE_WIN_PATHS" = true ]; then
    _handbrake_translate_argv hb_cmd
    hb_cmd+=(--json)
  else
    hb_cmd+=(--json)
  fi

  hb_prog_dir="$(mktemp -d "${TMPDIR:-/tmp}/.convert-hbprog-XXXXXX")" || return 1
  chmod 700 "$hb_prog_dir" || {
    rm -rf -- "$hb_prog_dir" 2>/dev/null || true
    return 1
  }
  hb_prog_fifo="$hb_prog_dir/progress.fifo"
  mkfifo "$hb_prog_fifo" || {
    rm -rf -- "$hb_prog_dir" 2>/dev/null || true
    return 1
  }

  ACTIVE_ENCODER_LABEL="$label"
  ACTIVE_ENCODER_FINGERPRINT="$(_tracked_command_fingerprint "${hb_cmd[@]}")"
  ACTIVE_ENCODER_STARTED_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  ACTIVE_ENCODER_FIFO_DIR="$hb_prog_dir"
  if [ -n "$HANDBRAKE_DROP_TO_USER" ]; then
    if [ "$PLATFORM" = wsl ] && [ -n "${WSL_INTEROP:-}" ]; then
      sudo WSL_INTEROP="$WSL_INTEROP" -u "$HANDBRAKE_DROP_TO_USER" -H -- "${hb_cmd[@]}" >"$hb_prog_fifo" 2>&1 &
    else
      sudo -u "$HANDBRAKE_DROP_TO_USER" -H -- "${hb_cmd[@]}" >"$hb_prog_fifo" 2>&1 &
    fi
    hb_wait_pid=$!
    ACTIVE_ENCODER_PID=$hb_wait_pid
  else
    "${hb_cmd[@]}" >"$hb_prog_fifo" 2>&1 &
    ACTIVE_ENCODER_PID=$!
    hb_wait_pid=$ACTIVE_ENCODER_PID
  fi

  # Portable awk (macOS BSD awk has no GNU match(..., array) capture groups).
  # GNU-only match() was aborting this pipe on macOS and, with pipefail, failing every encode.
  awk -v label="$label" '
    /^Progress: / {
      buf = substr($0, index($0, "{"))
      while (buf !~ /\}/ && (getline line) > 0) {
        buf = buf line
      }
      if (buf ~ /"State": "WORKING"/) {
        pct = 0
        eta = ""
        if (match(buf, /"Progress": ?[0-9.]+/)) {
          n = substr(buf, RSTART, RLENGTH)
          sub(/"Progress": ?/, "", n)
          pct = n * 100
        }
        if (match(buf, /"ETASeconds": ?[0-9]+/)) {
          n = substr(buf, RSTART, RLENGTH)
          sub(/"ETASeconds": ?/, "", n)
          if (n + 0 > 0) {
            eta = sprintf(" ETA %dm %ds", int(n / 60), int(n % 60))
          }
        }
        printf "\033[0;32m[convert]\033[0m %s: %.1f%%%s\r", label, pct, eta > "/dev/stderr"
        fflush()
      }
      if (buf ~ /"State": "WORKDONE"/) {
        err = 0
        if (match(buf, /"Error": ?[0-9]+/)) {
          n = substr(buf, RSTART, RLENGTH)
          sub(/"Error": ?/, "", n)
          err = n + 0
        }
        if (err != 0) {
          printf "\033[0;32m[convert]\033[0m %s: failed (error %d)\n", label, err > "/dev/stderr"
        } else {
          printf "\033[0;32m[convert]\033[0m %s: complete\n", label > "/dev/stderr"
        }
        fflush()
      }
      next
    }
    /Encode done!/ { next }
    /^\{[[:space:]]*$/ { skip = 1; next }
    skip && /^}/ { skip = 0; next }
    skip { next }
  ' <"$hb_prog_fifo" &
  hb_reader_pid=$!
  if [ -n "$HANDBRAKE_DROP_TO_USER" ]; then
    for _ in $(seq 1 50); do
      child_pid="$(ps -eo pid=,ppid=,args= 2>/dev/null | awk -v p="$hb_wait_pid" '
        $2 == p && ($0 ~ /HandBrakeCLI/ || $0 ~ /HandBrakeCLI.exe/) { print $1; exit }
      ')"
      [ -n "$child_pid" ] && break
      sleep 0.1
    done
    if [[ "$child_pid" =~ ^[0-9]+$ ]]; then
      ACTIVE_ENCODER_PID="$child_pid"
    else
      warn "Could not resolve dropped-user HandBrake child PID; tracking sudo supervisor pid=$hb_wait_pid"
    fi
  fi
  update_in_progress_encoder_fields || true

  wait "$hb_wait_pid" || rc=$?
  wait "$hb_reader_pid" 2>/dev/null || true
  ACTIVE_ENCODER_PID=0
  ACTIVE_ENCODER_LABEL=""
  ACTIVE_ENCODER_FINGERPRINT=""
  ACTIVE_ENCODER_STARTED_UTC=""
  rm -rf -- "$hb_prog_dir" 2>/dev/null || true
  ACTIVE_ENCODER_FIFO_DIR=""
  return "$rc"
}

# HandBrake on this build uses --colorspace (not separate --colorprim flags).
handbrake_append_color_metadata() {
  local src="$1"
  local -n _args="$2"
  if source_has_dolby_vision "$src"; then
    log "Dolby Vision — BT.2020/PQ color metadata (--colorspace primaries=bt2020:transfer=smpte2084:matrix=bt2020nc)"
    _args+=(--colorspace 'primaries=bt2020:transfer=smpte2084:matrix=bt2020nc')
    return 0
  fi
  if source_is_hdr10_wcg "$src"; then
    log "HDR10/WCG — BT.2020 color metadata (--colorspace)"
    _args+=(--colorspace 'primaries=bt2020:transfer=smpte2084:matrix=bt2020nc')
  fi
}

handbrake_title_resolution() {
  local src="$1"
  local title_idx="$2"
  local scan_txt res
  scan_txt="$(run_handbrake -t 0 --scan -i "$src" 2>&1 || true)"
  res="$(awk -v want="$title_idx" '
    BEGIN { idx = 0; res = "" }
    /^\+ title [0-9]+:/ {
      if (match($0, /title [0-9]+/)) {
        idx = substr($0, RSTART, RLENGTH); sub(/title /, "", idx); idx = idx + 0
      } else idx = 0
    }
    /^  \+ size: / {
      if (idx == want) res = $3
    }
    END { print res }
  ' <<< "$scan_txt")"
  [ -n "$res" ] && printf '%s' "$res" || printf 'unknown'
}

handbrake_append_external_srts() {
  local -n _args="$1"
  local src="$2"
  local -a subs=() langs=() codesets=()
  local sub lang

  while IFS= read -r sub; do
    [ -n "$sub" ] || continue
    case "${sub##*.}" in
      srt|SRT) ;;
      *) continue ;;
    esac
    subs+=("$sub")
    lang="$(detect_subtitle_lang "$sub" "$src")"
    langs+=("$lang")
    codesets+=(UTF-8)
  done < <(collect_external_subtitles "$src")

  [ "${#subs[@]}" -eq 0 ] && return 0

  # Translate each path individually BEFORE comma-joining. A path containing
  # a literal comma (e.g. "Movie, The (2020).en.srt") would otherwise get
  # blindly re-split on ',' later (in _handbrake_translate_argv, which only
  # sees the joined string) into two bogus fragments, each wrongly
  # translated. handbrake_path_for_exe() is a no-op outside WSL win-path
  # mode, so this is safe to always apply here.
  local -a subs_out=()
  local sub_i
  for sub_i in "${subs[@]}"; do
    subs_out+=("$(handbrake_path_for_exe "$sub_i")")
  done

  local joined_subs joined_langs joined_codesets
  joined_subs="$(IFS=,; printf '%s' "${subs_out[*]}")"
  joined_langs="$(IFS=,; printf '%s' "${langs[*]}")"
  joined_codesets="$(IFS=,; printf '%s' "${codesets[*]}")"
  _args+=(--srt-file "$joined_subs" --srt-lang "$joined_langs" --srt-codeset "$joined_codesets")
  log "External subtitles: ${subs[*]}"
}

handbrake_append_audio_args() {
  local -n _args="$1"
  local codec="$2"
  local bitrate="$3"
  _args+=(--all-audio --aencoder "$codec" -B "$bitrate" -D "$AUDIO_DRC" --gain "$AUDIO_GAIN")
}

handbrake_append_hw_decode() {
  local -n _args="$1"
  local encoder="$2"
  local mode="$3"
  case "$mode" in
    false|'') return 0 ;;
  esac
  [ "$HAS_HW_DECODE" = true ] || return 0
  [ -n "$HW_DECODE_NAME" ] || return 0
  case "$mode" in
    true)
      _args+=(--enable-hw-decoding "$HW_DECODE_NAME")
      ;;
    auto)
      if [ "$encoder" = "svt_av1_10bit" ] || [ "$PLATFORM" = macos ]; then
        _args+=(--enable-hw-decoding "$HW_DECODE_NAME")
      fi
      ;;
  esac
}

build_handbrake_args() {
  local src="$1"
  local dst="$2"
  local encoder="$3"
  local -n _out="$4"
  local hb_title="${5:-}"
  # Sample-encode callers pass true here: a short mid-file clip extracted via
  # -ss + -c copy can carry irregular DTS/PTS (a B-frame-reordering artifact
  # at the cut boundary) that a hardware decoder can choke on -- confirmed via
  # HandBrake exit 4 / "av_interleaved_write_frame failed" on such a clip,
  # software decode handles the same clip fine, and decode speed doesn't
  # matter for a SAMPLE_SECONDS-length clip anyway. Real full-length encodes
  # (unaffected, no -ss cut) keep hardware decode as normal.
  local no_hw_decode="${6:-false}"
  local h

  load_encoder_profile "$encoder" "$src" || return 1
  if is_disk_source "$src"; then
    h=0
  else
    h="$(video_height "$src")"
  fi

  _out=(
    -i "$src" -o "$dst" -f mkv -m -O
    -e "$encoder" -q "$EP_QUALITY"
    --all-subtitles
    --subtitle-burned=none --subtitle-default=none
  )
  if [ "$HB_SUPPORTS_KEEP_SUBNAME" = true ]; then
    _out+=(--keep-subname)
  fi
  if [ -n "$EP_PRESET" ]; then
    _out+=(--encoder-preset "$EP_PRESET")
  fi

  if [ -n "$hb_title" ]; then
    _out+=(-t "$hb_title")
  fi

  if [ "${#EP_VIDEO_FILTERS[@]}" -gt 0 ]; then
    _out+=("${EP_VIDEO_FILTERS[@]}")
  fi

  handbrake_append_audio_args _out "$EP_AUDIO_CODEC" "$EP_AUDIO_BITRATE"
  handbrake_append_external_srts _out "$src"

  if [ -n "$EP_ENCOPTS" ]; then
    _out+=(--encopts "$EP_ENCOPTS")
  fi
  if [ -n "$EP_ENCODER_TUNE" ]; then
    _out+=(--encoder-tune "$EP_ENCODER_TUNE")
  fi

  resolve_upscale_target "$src"
  log "Encoder profile: $EP_PROFILE_NAME ($encoder) — $(upscale_status_desc)"
  case "$UPSCALE_TARGET_HEIGHT" in
    720) _out+=(-w 1280 -l 720 --custom-anamorphic none) ;;
    1080) _out+=(-w 1920 -l 1080 --custom-anamorphic none) ;;
  esac

  [ "$no_hw_decode" = true ] || handbrake_append_hw_decode _out "$encoder" "$EP_HW_DECODE"
  handbrake_append_color_metadata "$src" _out
}

handbrake_encode() {
  local src="$1"
  local dst="$2"
  local encoder="$3"
  local gpu="${4:-}"
  local hb_title="${5:-}"
  local -a hb_args=()
  local real_dst="$dst"

  # Linux VAAPI path when HandBrake has no vce/vcn (Fedora + mesa freeworld).
  if [ "$encoder" = "vce_h265" ] && [ "${AMD_ENCODE_BACKEND:-}" = vaapi ]; then
    vaapi_hevc_encode "$src" "$dst" "$hb_title"
    return $?
  fi

  load_encoder_profile "$encoder" "$src" || return 1

  if [ "$DRY_RUN" = true ]; then
    local title_arg=""
    [ -n "$hb_title" ] && title_arg="-t $hb_title "
    log "[dry-run] $HANDBRAKE_DISPLAY -e $encoder profile=$EP_PROFILE_NAME -q $EP_QUALITY --encoder-preset $EP_PRESET --encopts '$EP_ENCOPTS'${EP_ENCODER_TUNE:+ --encoder-tune $EP_ENCODER_TUNE} --aencoder $EP_AUDIO_CODEC -B $EP_AUDIO_BITRATE -D $AUDIO_DRC --gain $AUDIO_GAIN ${title_arg}-i '$src' -o '$dst'"
    return 0
  fi

  # An external review found HandBrake's -o writes straight to the final
  # (predictable) path, same as ffmpeg's direct-write path -- resolve_encode_
  # stage_path routes this through the same private-directory staging used
  # everywhere else instead.
  dst="$(resolve_encode_stage_path "$src" "$real_dst")" || {
    warn "Cannot safely stage output for this title — skipping rather than risk the direct-write symlink race: $real_dst"
    return 1
  }
  build_handbrake_args "$src" "$dst" "$encoder" hb_args "$hb_title" || return 1

  local progress_label="Encoding ($encoder)"
  local saved_cuda="${CUDA_VISIBLE_DEVICES:-}"
  if [ -n "$gpu" ] && [ "$USE_NVIDIA_ENCODE" = true ]; then
    export CUDA_VISIBLE_DEVICES="$gpu"
  else
    unset CUDA_VISIBLE_DEVICES 2>/dev/null || CUDA_VISIBLE_DEVICES=
  fi
  case "$encoder" in
    qsv_h265|qsv_h264|qsv_av1) _configure_qsv_runtime_env ;;
  esac

  # rc=0; cmd || rc=$? -- see ffmpeg_encode_hw's comment: a bare failing
  # command here aborts the whole script under `set -e` before `rc=$?` on
  # the next line ever runs (verified via direct bash testing, 2026-07-22).
  local rc=0
  run_handbrake_with_progress "$progress_label" "${hb_args[@]}" || rc=$?

  if [ -n "$saved_cuda" ]; then
    export CUDA_VISIBLE_DEVICES="$saved_cuda"
  else
    unset CUDA_VISIBLE_DEVICES 2>/dev/null || CUDA_VISIBLE_DEVICES=
  fi

  # Some HandBrake builds exit 0 after rejecting unknown CLI flags and leave an empty -o file.
  if [ "$rc" -eq 0 ] && [ ! -s "$dst" ]; then
    warn "HandBrake reported success but output is missing/empty: $dst"
    rc=1
  fi
  if [ "$rc" -eq 0 ] && [ "$dst" != "$real_dst" ]; then
    if ! finalize_staged_encode_output "$dst" "$real_dst"; then
      warn "Output staging: failed to move staged HandBrake output to $real_dst"
      rc=1
    fi
  elif [ "$rc" -ne 0 ] && [ "$dst" != "$real_dst" ]; then
    rm -f "$dst" 2>/dev/null
    _cleanup_staged_file_dir "$dst"
  fi
  return "$rc"
}
