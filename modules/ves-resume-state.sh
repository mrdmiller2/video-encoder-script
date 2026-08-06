#!/usr/bin/env bash
# ves-resume-state.sh -- queue/shard snapshot persistence and the resume-
# after-restart / resume-on-signal machinery. Pure move from the former
# monolithic script -- no logic changes.

# These sidecar state/log files live at fixed, predictable names -- by
# default directly inside JOB_ROOT (the media library root itself) unless
# it's read-only. A symlink planted at one of these exact names (by another
# fleet machine, another user on a shared NFS/CIFS mount, or by accident)
# would have every subsequent truncating write in this script go straight
# through to whatever it points at, e.g. a real source video. Since we own
# the full lifecycle of these specific files (always created fresh, never
# meant to pre-exist as anything but our own regular file from a prior run),
# removing a stray symlink at one of these names is always safe -- rm on a
# symlink only ever removes the link itself, never its target.
resume_init_paths() {
  [ -n "$JOB_SIDECAR_DIR" ] || JOB_SIDECAR_DIR="$JOB_ROOT"
  # This run's own progress-tracking files are per-HOST, not fleet-shared --
  # unlike the done-log/mkv-structure-cache below (which are deliberately a
  # single shared ledger), resuming a run should only ever resume THIS
  # machine's own prior progress. Team review (2026-07-24) found these were
  # previously one shared filename fleet-wide: two machines concurrently
  # working under the same JOB_ROOT would silently overwrite each other's
  # resume state with `mv -f`, each seeing only whichever wrote last. This
  # closes the cross-host case, which is the one that actually happens in
  # normal fleet operation. Deliberately NOT keyed by PID as well: a PID-
  # keyed filename would let a resumed run find its own prior state only if
  # it happened to get reassigned the exact same PID, breaking the resume-
  # across-restart feature this file exists for. Two concurrent invocations
  # on the SAME host against the SAME JOB_ROOT (a user/cron double-launch
  # mistake, not a fleet-standard pattern) would still race on this file --
  # accepted as a known residual gap rather than risk a run-lifetime lock
  # that would need to chain into the existing EXIT-trap set (ramdisk_job_
  # teardown already registers its own `trap ... EXIT`, which a naive second
  # `trap ... EXIT` would silently clobber, not compose with).
  local _resume_host
  _resume_host="$(hostname 2>/dev/null || echo unknown)"
  RESUME_STATE_FILE="$JOB_SIDECAR_DIR/convert-v4.${_resume_host}.state"
  RESUME_QUEUE_FILE="$JOB_SIDECAR_DIR/convert-v4.${_resume_host}.queue"
  RESUME_SHARDS_FILE="$JOB_SIDECAR_DIR/convert-v4.${_resume_host}.shards"
  MKV_STRUCTURE_CACHE_FILE="$JOB_SIDECAR_DIR/mkv_structure_ok.tsv"
  CORRUPT_FILES_LOG="$JOB_SIDECAR_DIR/corrupt_files.txt"
  BAD_SOURCES_LOG="$JOB_SIDECAR_DIR/bad_sources.txt"
  RECONVERT_FILES_LOG="$JOB_SIDECAR_DIR/reconvert_files.txt"
  STRIPPED_SUBTITLES_LOG="$JOB_SIDECAR_DIR/stripped_subtitles.txt"
  LOW_QUALITY_LOG="$JOB_SIDECAR_DIR/low_quality_review.txt"
  RESUME_DONE_LOG="$JOB_SIDECAR_DIR/convert-v5.done"
  local p
  for p in "$RESUME_STATE_FILE" "$RESUME_QUEUE_FILE" "$MKV_STRUCTURE_CACHE_FILE" \
           "$CORRUPT_FILES_LOG" "$BAD_SOURCES_LOG" "$RECONVERT_FILES_LOG" \
           "$STRIPPED_SUBTITLES_LOG" "$LOW_QUALITY_LOG" \
           "$RESUME_SHARDS_FILE" "$RESUME_DONE_LOG"; do
    _neutralize_symlink_sidecar_path "$p"
  done
  if { exec {DONE_LOG_FD}>>"$RESUME_DONE_LOG"; } 2>/dev/null; then
    chmod 0666 "$RESUME_DONE_LOG" 2>/dev/null || true
  else
    DONE_LOG_FD=""
  fi
  # Same fd-based hardening as MASTER_LOG_FD/DONE_LOG_FD: these three are
  # appended to many times per run via a predictable path. A symlink raced
  # into place there could redirect appended text into any file the process
  # can write, not just "our own logs" -- opening the fd once, right after
  # the neutralization above, closes that window for the rest of the run.
  if { exec {CORRUPT_FILES_LOG_FD}>>"$CORRUPT_FILES_LOG"; } 2>/dev/null; then
    chmod 0666 "$CORRUPT_FILES_LOG" 2>/dev/null || true
  else
    CORRUPT_FILES_LOG_FD=""
  fi
  if { exec {BAD_SOURCES_LOG_FD}>>"$BAD_SOURCES_LOG"; } 2>/dev/null; then
    chmod 0666 "$BAD_SOURCES_LOG" 2>/dev/null || true
  else
    BAD_SOURCES_LOG_FD=""
  fi
  if { exec {RECONVERT_FILES_LOG_FD}>>"$RECONVERT_FILES_LOG"; } 2>/dev/null; then
    chmod 0666 "$RECONVERT_FILES_LOG" 2>/dev/null || true
  else
    RECONVERT_FILES_LOG_FD=""
  fi
  if { exec {LOW_QUALITY_LOG_FD}>>"$LOW_QUALITY_LOG"; } 2>/dev/null; then
    chmod 0666 "$LOW_QUALITY_LOG" 2>/dev/null || true
  else
    LOW_QUALITY_LOG_FD=""
  fi
  if { exec {STRIPPED_SUBTITLES_LOG_FD}>>"$STRIPPED_SUBTITLES_LOG"; } 2>/dev/null; then
    chmod 0666 "$STRIPPED_SUBTITLES_LOG" 2>/dev/null || true
  else
    STRIPPED_SUBTITLES_LOG_FD=""
  fi
  filecache_init
}

write_queue_snapshot() {
  local -n _q="$1"
  local f tmp
  # Build in a private mktemp'd file, then mv into place -- mv replaces
  # whatever sits at RESUME_QUEUE_FILE (including a symlink) directly and
  # atomically without following it, unlike the previous truncate-then-
  # append-by-path approach.
  tmp="$(mktemp "${RESUME_QUEUE_FILE}.XXXXXX" 2>/dev/null)" || return 0
  for f in "${_q[@]}"; do
    printf '%s\n' "$f" >>"$tmp"
  done
  mv -f -- "$tmp" "$RESUME_QUEUE_FILE"
  _restore_default_file_mode "$RESUME_QUEUE_FILE"
}

load_queue_snapshot() {
  local -n _out="$1"
  local line
  _out=()
  [ -f "$RESUME_QUEUE_FILE" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] && _out+=("$line")
  done <"$RESUME_QUEUE_FILE"
}

resume_persist_state() {
  local status="${1:-}"
  [ "$DRY_RUN" = true ] && return 0
  [ -z "$RESUME_STATE_FILE" ] && return 0
  local tmp
  tmp="$(mktemp "${RESUME_STATE_FILE}.XXXXXX" 2>/dev/null)" || return 0
  {
    printf 'version=%s\n' "$VERSION"
    printf 'path=%s\n' "$SEARCH_PATH"
    printf 'shard_depth=%s\n' "$SHARD_DEPTH"
    printf 'no_shard=%s\n' "$NO_SHARD"
    printf 'name_glob=%s\n' "${NAME_GLOB:-}"
    printf 'name_glob_ci=%s\n' "$NAME_GLOB_CI"
    printf 'skip_av1=%s\n' "$SKIP_AV1"
    printf 'skip_x265=%s\n' "$SKIP_X265"
    printf 'last_source=%s\n' "${RESUME_LAST_SOURCE:-}"
    printf 'last_index=%s\n' "${RESUME_LAST_INDEX:-0}"
    printf 'last_status=%s\n' "${status:-$RESUME_LAST_STATUS}"
    printf 'last_shard=%s\n' "${RESUME_LAST_SHARD:-}"
    local key val
    for key in "${!BAKEOFF_ENCODER_CHOICE[@]}"; do
      val="${BAKEOFF_ENCODER_CHOICE[$key]}"
      printf 'bakeoff_encoder_%s=%s\n' "$key" "$val"
    done
    printf 'queue_total=%s\n' "${CONVERT_JOB_TOTAL:-0}"
    printf 'updated=%s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  } >"$tmp"
  mv -f -- "$tmp" "$RESUME_STATE_FILE"
  _restore_default_file_mode "$RESUME_STATE_FILE"
}

resume_state_matches_current() {
  local key val
  [ -f "$RESUME_STATE_FILE" ] || return 1
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    case "$key" in
      path) val="$SEARCH_PATH" ;;
      shard_depth) val="$SHARD_DEPTH" ;;
      no_shard) val="$NO_SHARD" ;;
      name_glob) val="${NAME_GLOB:-}" ;;
      name_glob_ci) val="$NAME_GLOB_CI" ;;
      skip_av1) val="$SKIP_AV1" ;;
      skip_x265) val="$SKIP_X265" ;;
      *) continue ;;
    esac
    if ! grep -qxF "${key}=${val}" "$RESUME_STATE_FILE" 2>/dev/null; then
      return 1
    fi
  done <<'EOF'
path
shard_depth
no_shard
name_glob
name_glob_ci
skip_av1
skip_x265
EOF
  return 0
}

resume_load_state() {
  local line key val
  RESUME_LAST_SOURCE=""
  RESUME_LAST_INDEX=0
  RESUME_LAST_STATUS=""
  RESUME_LAST_SHARD=""
  BAKEOFF_ENCODER_CHOICE=()
  [ -f "$RESUME_STATE_FILE" ] || return 1
  while IFS= read -r line; do
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      last_source) RESUME_LAST_SOURCE="$val" ;;
      last_index) RESUME_LAST_INDEX="$val" ;;
      last_status) RESUME_LAST_STATUS="$val" ;;
      last_shard) RESUME_LAST_SHARD="$val" ;;
      bakeoff_encoder_*)
        key="${key#bakeoff_encoder_}"
        BAKEOFF_ENCODER_CHOICE[$key]="$val"
        ;;
      bakeoff_done)
        # Legacy v4.0.13: treat as movie_sdr locked to svt unless per-profile keys exist.
        if [ "$val" = true ] && [ "${#BAKEOFF_ENCODER_CHOICE[@]}" -eq 0 ]; then
          BAKEOFF_ENCODER_CHOICE[movie_sdr]="svt_av1_10bit"
        fi
        ;;
    esac
  done <"$RESUME_STATE_FILE"
  return 0
}

resume_clear_state() {
  rm -f -- "$RESUME_STATE_FILE" "$RESUME_QUEUE_FILE" "$RESUME_SHARDS_FILE"
  RESUME_ACTIVE=false
  RESUME_LAST_SOURCE=""
  RESUME_LAST_INDEX=0
  RESUME_LAST_STATUS=""
  RESUME_LAST_SHARD=""
  BAKEOFF_ENCODER_CHOICE=()
}

# Trim the queue to resume after an interrupted session. New files are always included.
apply_resume_to_queue() {
  local -n _q="$1"
  local -a old_queue=() result=()
  local item want_path resume_idx=-1 i=0
  local -A in_old=()

  [ "$RESUME_ACTIVE" = true ] || return 0
  [ -n "$RESUME_LAST_SOURCE" ] || return 0
  load_queue_snapshot old_queue || return 0

  for item in "${old_queue[@]}"; do
    in_old["$item"]=1
  done

  case "$RESUME_LAST_STATUS" in
    completed|skipped)
      want_path=""
      for i in "${!_q[@]}"; do
        if [ "${_q[$i]}" = "$RESUME_LAST_SOURCE" ]; then
          if [ $((i + 1)) -lt "${#_q[@]}" ]; then
            want_path="${_q[$((i + 1))]}"
          fi
          break
        fi
      done
      ;;
    *)
      want_path="$RESUME_LAST_SOURCE"
      ;;
  esac

  if [ -n "$want_path" ]; then
    for i in "${!_q[@]}"; do
      if [ "${_q[$i]}" = "$want_path" ]; then
        resume_idx="$i"
        break
      fi
    done
  fi

  if [ "$resume_idx" -lt 0 ]; then
    warn "Resume anchor not found in current queue"
    if [ "$RESUME_LAST_INDEX" -gt 0 ] && [ "$RESUME_LAST_INDEX" -le "${#_q[@]}" ]; then
      resume_idx=$((RESUME_LAST_INDEX - 1))
      if [ "$RESUME_LAST_STATUS" = completed ] || [ "$RESUME_LAST_STATUS" = skipped ]; then
        [ "$resume_idx" -lt "${#_q[@]}" ] && resume_idx=$((resume_idx + 1)) || resume_idx=-1
      fi
      warn "Using saved job index $RESUME_LAST_INDEX as resume hint"
    else
      return 0
    fi
  fi

  for i in "${!_q[@]}"; do
    item="${_q[$i]}"
    if [[ -z "${in_old[$item]+x}" ]]; then
      result+=("$item")
    elif [ "$resume_idx" -ge 0 ] && [ "$i" -ge "$resume_idx" ]; then
      result+=("$item")
    fi
  done

  log "Resume: last job was $RESUME_LAST_STATUS on $(basename "$RESUME_LAST_SOURCE") (shard: ${RESUME_LAST_SHARD:-unknown})"
  log "Resume: continuing with ${#result[@]} of ${#_q[@]} queued item(s)"
  _q=("${result[@]}")
}

resume_check_shard_changes() {
  local prev_shards="$RESUME_SHARDS_FILE.prev"
  local changes
  [ -f "$RESUME_SHARDS_FILE" ] || return 0
  _neutralize_symlink_sidecar_path "$prev_shards"
  # Both guarded (E2E review, 2026-07-30): a transient NFS hiccup making
  # either the copy or the comparison fail would otherwise abort the whole
  # script right here under `set -e` -- this is just resume bookkeeping,
  # not something worth killing a fleet run over.
  cp -f "$RESUME_SHARDS_FILE" "$prev_shards" 2>/dev/null || true
  build_shard_snapshot "$RESUME_SHARDS_FILE" || true
  changes="$(compare_shard_snapshots "$prev_shards" "$RESUME_SHARDS_FILE" 2>/dev/null)" || changes=""
  rm -f -- "$prev_shards"
  if [ -n "$changes" ]; then
    log "Shard snapshot changes since last run:"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      log "  $line"
    done <<<"$changes"
    stats_log_append "--- shard changes since last run ---"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      stats_log_append "  $line"
    done <<<"$changes"
    stats_log_append ""
  else
    log "Shard snapshot unchanged since last run"
  fi
}

resume_prepare_convert() {
  # resume_init_paths sets RESUME_DONE_LOG to the real sidecar path -- it was
  # previously called AFTER done_log_load, so done_log_load always saw the
  # empty top-level default and silently never loaded convert-v5.done. That
  # disabled the entire done-log fast-skip resume path (every restart fully
  # re-validated every file via ffprobe/mkvalidator instead of fast-skipping
  # already-finished ones) without any visible error.
  resume_init_paths
  done_log_load
  if [ "$NO_RESUME" = true ]; then
    log "Resume disabled (--no-resume) — starting fresh"
    resume_clear_state
    return 0
  fi
  if ! resume_state_matches_current; then
    if [ -f "$RESUME_STATE_FILE" ]; then
      warn "Saved resume state does not match current path/options — starting fresh"
      resume_clear_state
    fi
    return 0
  fi
  if resume_load_state; then
    RESUME_ACTIVE=true
    log "Resume state found — will continue from last interrupted job"
    resume_check_shard_changes
  fi
}

resume_on_signal() {
  kill_active_encoder
  if [ "${CONVERT_SCAN_PID:-0}" -gt 0 ] 2>/dev/null; then
    kill "$CONVERT_SCAN_PID" 2>/dev/null || true
    wait "$CONVERT_SCAN_PID" 2>/dev/null || true
    CONVERT_SCAN_PID=0
  fi
  # Best-effort: an interrupt mid-encode leaves the private local staging dir
  # (non-ramdisk fallback) behind with nothing else to ever clean it up.
  if [ -n "${ACTIVE_LOCAL_STAGE_DIR:-}" ]; then
    rm -rf -- "$ACTIVE_LOCAL_STAGE_DIR" 2>/dev/null || true
    ACTIVE_LOCAL_STAGE_DIR=""
  fi
  if [ -n "${ACTIVE_FINALIZE_DIR:-}" ]; then
    rm -rf -- "$ACTIVE_FINALIZE_DIR" 2>/dev/null || true
    ACTIVE_FINALIZE_DIR=""
  fi
  if [ -n "${ACTIVE_STREAMOPT_DIR:-}" ]; then
    rm -rf -- "$ACTIVE_STREAMOPT_DIR" 2>/dev/null || true
    ACTIVE_STREAMOPT_DIR=""
  fi
  if [ -n "${ACTIVE_FFMPEG_STAGE1_FILE:-}" ]; then
    rm -f -- "$ACTIVE_FFMPEG_STAGE1_FILE" 2>/dev/null || true
    ACTIVE_FFMPEG_STAGE1_FILE=""
  fi
  warn "Interrupted — resume state saved at job ${RESUME_LAST_INDEX:-0}: ${RESUME_LAST_SOURCE:-unknown}"
  if [ -n "${RESUME_LAST_SOURCE:-}" ]; then
    # finalize_mkv_output and tag_preexisting_desired_format both clear this
    # title's in-progress flag themselves as soon as their output is durable
    # -- so if the flag is still on disk here, the interrupt genuinely landed
    # mid-encode and the advice below is accurate. If the flag is already
    # gone, the job actually finished; don't tell a human to delete good output.
    if [ -f "$(in_progress_flag_path "$RESUME_LAST_SOURCE" 2>/dev/null)" ]; then
      warn "Left $(canonical_title_from_source "$RESUME_LAST_SOURCE").${IN_PROGRESS_FLAG_SUFFIX} — delete that title's partial .AV1.mkv/.x265.mkv before trusting them"
    fi
  fi
  resume_persist_state "interrupted"
  exit 130
}
