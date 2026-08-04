#!/usr/bin/env bash
# ves-title-lock.sh -- per-file in-progress flag lifecycle (place/clear)
# and the begin/end-convert-job wrapper around a single title's encode.
# Pure move from the former monolithic script -- no logic changes.

is_encoder_process() {
  local pid="$1"
  local comm args
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  comm="$(ps -p "$pid" -o comm= 2>/dev/null | awk 'NR==1{print $1}')"
  args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
  case "$(basename "${comm:-}")" in
    ffmpeg|HandBrakeCLI|HandBrakeCLI.exe|mkvmerge) return 0 ;;
  esac
  case "$args" in
    *ffmpeg*|*HandBrakeCLI*|*HandBrakeCLI.exe*|*mkvmerge*) return 0 ;;
  esac
  return 1
}

process_is_zombie() {
  local pid="$1"
  local stat
  stat="$(ps -p "$pid" -o stat= 2>/dev/null | awk 'NR==1{print $1}')"
  case "$stat" in
    Z*) return 0 ;;
  esac
  return 1
}

in_progress_flag_path() {
  local src="$1"
  local dir title
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src")"
  printf '%s/%s.%s' "$dir" "$title" "$IN_PROGRESS_FLAG_SUFFIX"
}

# Place a visible per-file semaphore beside the source while encode/remux is underway.
# Left behind on interrupt/crash so humans know that title's .AV1.mkv / .x265.mkv may be partial.
#
# Also claims a same-named ".lock" sibling directory via mkdir, which is
# atomic even on NFS/CIFS -- unlike the informational flag file above (a
# plain `cat >` write), two fleet machines scanning the same shared library
# can otherwise both decide a title needs encoding and race to write the
# same output path. The lock dir is a pure implementation detail (never
# inspected by clean_junk_scan/junk_flag_is_stale) so the human-visible
# .IN_PROGRESS file's format and behavior are unchanged. Returns 1 if
# another live process (this host or another fleet machine) already holds
# the claim -- callers must skip the job in that case.
place_in_progress_flag() {
  local src="$1"
  local idx="${2:-}"
  local flag lockdir dir title this_host
  [ "$DRY_RUN" = true ] && return 0
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src")"
  flag="$(in_progress_flag_path "$src")"
  lockdir="${flag}.lock"
  this_host="$(hostname 2>/dev/null || echo unknown)"
  mkdir -p -- "$dir" 2>/dev/null || true

  if ! mkdir -- "$lockdir" 2>/dev/null; then
    if junk_flag_is_stale "$flag" 2>/dev/null; then
      # rmdir-then-mkdir is two separate syscalls -- two hosts can both pass
      # the staleness check and both attempt reclaim; whichever one's rmdir
      # runs after the other's mkdir would silently delete the winner's
      # brand-new lock. Reclaim via `mv` instead: rename() on a directory is
      # a single atomic syscall, so exactly one racing process can win the
      # rename of this exact source path -- the loser's mv simply fails and
      # it backs off instead of destroying the winner's lock. No `-T`: that
      # flag is a GNU extension and would break on macOS (Crystalight).
      local reclaim_name="${lockdir}.reclaim.$(hostname 2>/dev/null || echo unknown).$$.$RANDOM"
      if mv -- "$lockdir" "$reclaim_name" 2>/dev/null; then
        rm -rf -- "$reclaim_name" 2>/dev/null
        if ! mkdir -- "$lockdir" 2>/dev/null; then
          warn "Title claimed by another process just now — skipping: $title"
          return 1
        fi
      else
        warn "Title claimed by another process just now — skipping: $title"
        return 1
      fi
    else
      local holder
      holder="$(awk -F= '/^host=/{h=$2} /^pid=/{p=$2} END{print h" pid "p}' "$flag" 2>/dev/null)"
      warn "Title already being encoded elsewhere (${holder:-unknown host/pid}) — skipping: $title"
      return 1
    fi
  fi

  # cat >"$flag" follows a symlink at that path and truncates+writes INTO
  # whatever it points to. $flag is a predictable name sitting right beside
  # the source on a shared NFS/CIFS library, so refuse rather than write
  # through it if it's ever a symlink (planted or accidental) instead of a
  # plain file.
  if [ -L "$flag" ]; then
    warn "Refusing to write in-progress flag — path is a symlink, not a plain file: $flag"
    rmdir -- "$lockdir" 2>/dev/null
    return 1
  fi

  if [ -f "$flag" ]; then
    warn "Found leftover ${title}.${IN_PROGRESS_FLAG_SUFFIX} — prior run may have left partial .AV1.mkv/.x265.mkv for this title"
  fi
  # The [ -L "$flag" ] check above is a one-time snapshot; `cat >"$flag"`
  # itself still opens that predictable path by name and would follow a
  # symlink planted in the (small but real) window between the check and
  # this write. Write to a private temp file in the same directory first,
  # then mv it into place: mv/rename() replaces whatever is at the
  # destination -- including a symlink -- directly and atomically, without
  # ever dereferencing/following it.
  local flag_tmp
  flag_tmp="$(mktemp "${flag}.XXXXXX" 2>/dev/null)" || {
    warn "Could not create a temp file for the in-progress flag — refusing to write: $flag"
    rmdir -- "$lockdir" 2>/dev/null
    return 1
  }
  cat >"$flag_tmp" <<EOF
convert-v4 IN PROGRESS
version=$VERSION
pid=$$
host=$this_host
started_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
job_index=${idx:-}
title=$title
source=$src

If you see this file, the convert job for this title was interrupted or is still running.
Delete ${title}.AV1.mkv and/or ${title}.x265.mkv here (not the original) before trusting
or re-running convert for this title.
EOF
  mv -f -- "$flag_tmp" "$flag"
  _restore_default_file_mode "$flag"
  return 0
}

clear_in_progress_flag() {
  local src="$1"
  local flag
  [ "$DRY_RUN" = true ] && return 0
  flag="$(in_progress_flag_path "$src")"
  rmdir -- "${flag}.lock" 2>/dev/null || true
  [ -f "$flag" ] || return 0
  rm -f -- "$flag"
}

begin_convert_job() {
  local src="$1"
  local idx="$2"
  local total="$3"
  local name size shard
  name="$(basename "$src")"
  if is_disk_source "$src"; then
    size="$(human_size_bytes "$(disc_source_size_bytes "$src")")"
  else
    size="$(human_size_bytes "$(file_size_bytes "$src")")"
  fi
  shard="$(shard_for_path "$src")"
  RESUME_LAST_SOURCE="$src"
  RESUME_LAST_INDEX="$idx"
  RESUME_LAST_SHARD="$shard"
  # Keep CONVERT_JOB_TOTAL numeric only (pipeline may pass "?" as display total).
  if [[ "$total" =~ ^[0-9]+$ ]]; then
    CONVERT_JOB_TOTAL="$total"
  fi
  if ! place_in_progress_flag "$src" "$idx"; then
    return 1
  fi
  resume_persist_state "started"
  CONVERT_JOB_START_EPOCH="$(date +%s)"
  CONVERT_JOB_SRC_DURATION="0"
  if ! is_disk_source "$src"; then
    CONVERT_JOB_SRC_DURATION="$(video_duration "$src")"
  fi
  echo ""
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Job $idx of $total: $name ($size)"
  log "Shard: $shard"
  log "Source: $src"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

end_convert_job() {
  local src="$1"
  local idx="$2"
  local total="$3"
  local ok="${4:-true}"
  local status=completed
  [ "$ok" = false ] && status=failed
  RESUME_LAST_SOURCE="$src"
  RESUME_LAST_INDEX="$idx"
  clear_in_progress_flag "$src"
  resume_persist_state "$status"
  if [ "$ok" = true ]; then
    log "Job $idx of $total complete: $(basename "$src")"
    if [ "$DRY_RUN" = false ] && [ "${CONVERT_JOB_START_EPOCH:-0}" -gt 0 ]; then
      local elapsed
      elapsed=$(( $(date +%s) - CONVERT_JOB_START_EPOCH ))
      [ "$elapsed" -ge 0 ] || elapsed=0
      CONVERT_BATCH_ENCODE_SECONDS=$(( CONVERT_BATCH_ENCODE_SECONDS + elapsed ))
      if awk -v d="${CONVERT_JOB_SRC_DURATION:-0}" 'BEGIN { exit !(d+0 > 0) }' && [ "$elapsed" -gt 0 ]; then
        local speed
        speed="$(awk -v d="$CONVERT_JOB_SRC_DURATION" -v e="$elapsed" 'BEGIN { printf "%.2f", d / e }')"
        log "  Encode time: $(format_duration_hms "$elapsed") (source runtime $(format_duration_hms "$CONVERT_JOB_SRC_DURATION"), ${speed}x realtime)"
        notify_telegram "OK Job $idx/$total complete: $(basename "$src") -- $(format_duration_hms "$elapsed") (${speed}x realtime)"
      else
        log "  Encode time: $(format_duration_hms "$elapsed")"
        notify_telegram "OK Job $idx/$total complete: $(basename "$src") -- $(format_duration_hms "$elapsed")"
      fi
    fi
  else
    warn "Job $idx of $total failed: $(basename "$src")"
    [ "$DRY_RUN" = false ] && notify_telegram "FAILED Job $idx/$total: $(basename "$src")"
  fi
  echo ""
}

log_batch_encode_total() {
  [ "$CONVERT_BATCH_ENCODE_SECONDS" -gt 0 ] || return 0
  log "Total encode time this batch: $(format_duration_hms "$CONVERT_BATCH_ENCODE_SECONDS")"
}
