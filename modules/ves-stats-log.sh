#!/usr/bin/env bash
# ves-stats-log.sh -- per-run/per-shard stats log accounting (bytes saved,
# processed/skipped/inspected counts) and the master/shard log lifecycle.
# Pure move from the former monolithic script -- no logic changes.

init_stats_log() {
  local ts
  _neutralize_symlink_sidecar_path "$MASTER_LOG_FILE"
  ts="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  if [ -n "$MASTER_LOG_FD" ]; then
    {
      echo ""
      echo "=== $SCRIPT_NAME v$VERSION — $ts ==="
      echo "job_root: $JOB_ROOT"
      echo "path: $SEARCH_PATH"
      echo "log_dir: $JOB_SIDECAR_DIR"
      echo "job_root_writable: $JOB_ROOT_WRITABLE"
      echo "dry_run: $DRY_RUN | organize: $DO_ORGANIZE | convert: $DO_CONVERT | skip_av1: $SKIP_AV1 | skip_x265: $SKIP_X265 | nvidia: $HAS_NVIDIA | intel_qsv: $HAS_INTEL_QSV | amd_vce: $HAS_AMD_VCE | amd_backend: ${AMD_ENCODE_BACKEND:-none} | videotoolbox: $HAS_VIDEOTOOLBOX | active_encode: $ACTIVE_ENCODE_MODE | hw_decode: ${HW_DECODE_NAME:-none}"
      echo "order: largest to smallest"
      if [ "$DRY_RUN" = true ]; then
        echo "inspect: name | video format | length | resolution (no conversion)"
      fi
      if [ -n "$RESUME_STATE_FILE" ] && [ -f "$RESUME_STATE_FILE" ] && [ "$NO_RESUME" = false ]; then
        echo "resume: $(basename -- "$RESUME_STATE_FILE") present (auto-resume on convert)"
      fi
    } >&"$MASTER_LOG_FD" 2>/dev/null || true
  else
    warn "Master log disabled — could not write $MASTER_LOG_FILE"
    warn "Try: export CONVERT_LOG_DIR=\"\$HOME/convert-v4-logs\""
  fi
  if [ "$JOB_ROOT_WRITABLE" = true ]; then
    set +e
    merge_orphan_subdir_logs
    set -e
  fi
}

begin_shard_log() {
  local shard="$1"
  SHARD_LOG_ROOT="$shard"
  if [ "$JOB_ROOT_WRITABLE" = true ] && [ -w "$shard" ] 2>/dev/null; then
    SHARD_LOG_FILE="$shard/convert-v4.shard.log"
  else
    SHARD_LOG_FILE="$JOB_SIDECAR_DIR/shard-$(basename "$shard").log"
  fi
  SHARD_LOG_ACTIVE=true
  _neutralize_symlink_sidecar_path "$SHARD_LOG_FILE"
  if { exec {SHARD_LOG_FD}>>"$SHARD_LOG_FILE"; } 2>/dev/null; then
    chmod 0666 "$SHARD_LOG_FILE" 2>/dev/null
  else
    SHARD_LOG_FD=""
    SHARD_LOG_ACTIVE=false
    return 0
  fi
  {
    echo ""
    echo "=== shard log — $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
    echo "shard: $shard"
    echo "job_root: $JOB_ROOT"
    echo ""
  } >&"$SHARD_LOG_FD" 2>/dev/null || SHARD_LOG_ACTIVE=false
}

end_shard_log() {
  local shard="$1"
  if [ -z "$SHARD_LOG_FILE" ] || [ ! -f "$SHARD_LOG_FILE" ]; then
    SHARD_LOG_ACTIVE=false
    SHARD_LOG_FILE=""
    if [ -n "$SHARD_LOG_FD" ]; then
      { exec {SHARD_LOG_FD}>&-; } 2>/dev/null || true
      SHARD_LOG_FD=""
    fi
    return 0
  fi
  # Close the shard fd before reading the file back for merging into the
  # master log -- makes sure everything written through it has actually
  # landed, and the fd itself only ever pointed at this shard's own file.
  if [ -n "$SHARD_LOG_FD" ]; then
    { exec {SHARD_LOG_FD}>&-; } 2>/dev/null || true
    SHARD_LOG_FD=""
  fi
  master_log_write ""
  master_log_write "--- merged shard log: $shard ---"
  if [ -n "$MASTER_LOG_FD" ]; then
    cat "$SHARD_LOG_FILE" >&"$MASTER_LOG_FD" 2>/dev/null || true
  fi
  master_log_write "--- end shard log: $shard ---"
  master_log_write ""
  rm -f -- "$SHARD_LOG_FILE"
  SHARD_LOG_ACTIVE=false
  SHARD_LOG_FILE=""
  SHARD_LOG_ROOT=""
}

merge_orphan_subdir_logs() {
  local f rel
  [ -n "$MASTER_LOG_FD" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$f" = "$MASTER_LOG_FILE" ] && continue
    rel="${f#"$JOB_ROOT"/}"
    master_log_write ""
    master_log_write "--- merged orphan log: $rel ---"
    cat "$f" >&"$MASTER_LOG_FD" 2>/dev/null || true
    master_log_write "--- end orphan log: $rel ---"
    master_log_write ""
    rm -f -- "$f"
  done < <(find "$JOB_ROOT" -mindepth 2 -type f \( -name 'convert-v4.log' -o -name 'convert-v4.shard.log' \) 2>/dev/null | LC_ALL=C sort)
}

stats_log_append() {
  if [ -n "$MASTER_LOG_FD" ]; then
    printf '%s\n' "$*" >&"$MASTER_LOG_FD" 2>/dev/null || true
  fi
  shard_log_write "$@"
}

stats_log_running_totals() {
  stats_log_append "--- running totals ---"
  stats_log_append "files processed: $STATS_PROCESSED"
  stats_log_append "files skipped: $STATS_SKIPPED"
  if [ "$STATS_INSPECTED" -gt 0 ]; then
    stats_log_append "files inspected: $STATS_INSPECTED"
  fi
  stats_log_append "output space used: $(human_size_bytes "$STATS_OUTPUT_BYTES") ($STATS_OUTPUT_BYTES bytes)"
  stats_log_append "space saved vs sources: $(human_size_bytes "$STATS_SAVED_BYTES") ($STATS_SAVED_BYTES bytes)"
  stats_log_append ""
}

record_conversion_result() {
  local src="$1"
  local out="${2:-}"
  # JOB_LOGICAL_SOURCE (set by try_av1_convert/try_x265_convert's own
  # logical_source param) is the TRUE original for a disc-extraction job,
  # where $src is actually a symlink to a temporary lossless intermediate.
  # Defaults to $src itself for every ordinary call site.
  local logical_source="${JOB_LOGICAL_SOURCE:-$src}"
  local orig_sz out_sz saved
  if is_disk_source "$logical_source"; then
    orig_sz="$(disc_source_size_bytes "$logical_source")"
  else
    orig_sz="$(file_size_bytes "$src")"
  fi

  if [ -n "$out" ] && [ -f "$out" ] && [ "$DRY_RUN" = false ]; then
    out_sz="$(file_size_bytes "$out")"
    STATS_OUTPUT_BYTES=$((STATS_OUTPUT_BYTES + out_sz))
    if [ "$out_sz" -lt "$orig_sz" ]; then
      saved=$((orig_sz - out_sz))
      STATS_SAVED_BYTES=$((STATS_SAVED_BYTES + saved))
      stats_log_append "[$(date -u '+%H:%M:%S')] KEPT: $(basename "$src")"
      stats_log_append "  source: $(human_size_bytes "$orig_sz") — $(basename "$src")"
      stats_log_append "  output: $(human_size_bytes "$out_sz") — $(basename "$out")"
      stats_log_append "  space used (output): +$(human_size_bytes "$out_sz")"
      stats_log_append "  space saved vs source: $(human_size_bytes "$saved")"
      # Season-level shrink heuristic bookkeeping -- a genuine size reduction
      # from a real encode attempt counts as both tested and shrunk for this
      # episode's season (see SEASON_RETRY_THRESHOLD_PCT).
      if [ "$SEASON_RETRY_IN_PROGRESS" = false ] && [ "$SEASON_SAMPLE_DECISION_CONTEXT" = true ] \
         && is_tv_episode "$src"; then
        local __season
        __season="$(season_retry_key "$src")"
        SEASON_SAMPLE_TESTED_COUNT[$__season]=$(( ${SEASON_SAMPLE_TESTED_COUNT[$__season]:-0} + 1 ))
        SEASON_SHRINK_COUNT[$__season]=$(( ${SEASON_SHRINK_COUNT[$__season]:-0} + 1 ))
      fi
    else
      stats_log_append "[$(date -u '+%H:%M:%S')] KEPT (larger): $(basename "$src")"
      stats_log_append "  source: $(human_size_bytes "$orig_sz")"
      stats_log_append "  output: $(human_size_bytes "$out_sz") (+$(human_size_bytes "$((out_sz - orig_sz))") vs source)"
      # Counts toward this season's tested total (a real encode was attempted
      # and judged) but not the shrink count -- it grew, even if kept within
      # the guardrail's overshoot tolerance.
      if [ "$SEASON_RETRY_IN_PROGRESS" = false ] && [ "$SEASON_SAMPLE_DECISION_CONTEXT" = true ] \
         && is_tv_episode "$src"; then
        local __season
        __season="$(season_retry_key "$src")"
        SEASON_SAMPLE_TESTED_COUNT[$__season]=$(( ${SEASON_SAMPLE_TESTED_COUNT[$__season]:-0} + 1 ))
      fi
    fi
  elif [ "$DRY_RUN" = true ] && [ -n "$out" ]; then
    stats_log_append "[$(date -u '+%H:%M:%S')] [dry-run] would create: $(basename "$out")"
    stats_log_append "  source: $(human_size_bytes "$orig_sz") — $(basename "$src")"
  elif [ -z "$out" ]; then
    stats_log_append "[$(date -u '+%H:%M:%S')] METADATA: $(basename "$src") ($(human_size_bytes "$orig_sz"))"
  fi

  STATS_PROCESSED=$((STATS_PROCESSED + 1))
  stats_log_running_totals
  # done_log_append already no-ops for a real is_disk_source path -- use
  # logical_source here too so a disc job's temporary symlink (which IS an
  # ordinary .mkv, not a disk source by itself) doesn't slip through and
  # get a done-log entry for a path that's deleted moments after this
  # returns (see process_disk).
  done_log_append done "$logical_source"
  mark_folder_done_if_complete "$(dirname "$src")"
}

record_skip() {
  local src="$1"
  local reason="${2:-already exists}"
  STATS_SKIPPED=$((STATS_SKIPPED + 1))
  stats_log_append "[$(date -u '+%H:%M:%S')] SKIP: $(basename "$src") — $reason"
  stats_log_running_totals
  # Durable skips go on the done-log; transient failures must retry next run.
  # Timeouts / stalled-mount skips are this-run-only (same as fail/error/unable).
  case "$(to_lower "$reason")" in
    *fail*|*error*|*unable*|*timeout*|*stalled*|*'timed out'*) : ;;
    *) done_log_append skip "$src" ;;
  esac
  mark_folder_done_if_complete "$(dirname "$src")"
  # Season-level shrink heuristic bookkeeping -- only this specific skip
  # reason represents a real "would this shrink?" prediction to second-guess
  # later; every other skip reason (corrupt source, already-tagged, sample
  # test itself failing/timing out) is unrelated to this heuristic.
  case "$reason" in
    *"re-encode sample predicts no size win"*)
      if [ "$SEASON_RETRY_IN_PROGRESS" = false ] && is_tv_episode "$src"; then
        local __season
        __season="$(season_retry_key "$src")"
        SEASON_SAMPLE_TESTED_COUNT[$__season]=$(( ${SEASON_SAMPLE_TESTED_COUNT[$__season]:-0} + 1 ))
        SEASON_NO_SHRINK_FILES[$__season]+="$src"$'\n'
      fi
      ;;
  esac
}

finalize_stats_log() {
  [ -n "$MASTER_LOG_FILE" ] || return 0
  if [ "$SHARD_LOG_ACTIVE" = true ] && [ -n "$SHARD_LOG_ROOT" ]; then
    end_shard_log "$SHARD_LOG_ROOT"
  fi
  merge_orphan_subdir_logs
  stats_log_append "=== session complete — $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
  stats_log_append "files processed: $STATS_PROCESSED"
  stats_log_append "files skipped: $STATS_SKIPPED"
  if [ "$STATS_INSPECTED" -gt 0 ]; then
    stats_log_append "files inspected: $STATS_INSPECTED"
  fi
  stats_log_append "total output space used: $(human_size_bytes "$STATS_OUTPUT_BYTES") ($STATS_OUTPUT_BYTES bytes)"
  stats_log_append "total space saved vs sources: $(human_size_bytes "$STATS_SAVED_BYTES") ($STATS_SAVED_BYTES bytes)"
  stats_log_append "note: originals are never deleted; output space is additive"
  stats_log_append ""
  maybe_chown_for_media_user "$MASTER_LOG_FILE" "$RESUME_STATE_FILE" "$RESUME_QUEUE_FILE" "$RESUME_SHARDS_FILE"
}
