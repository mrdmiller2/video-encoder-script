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

# Appends one line to sample-prediction-log.tsv comparing a sample-based
# size prediction (SAMPLE_PRED_*, set by _set_sample_pred_from_output right
# after av1_source_reencode_sample_decision returns "av1" or "x265") against
# the real encode's actual output size, then clears SAMPLE_PRED_ACTIVE --
# called once from record_conversion_result, right before it would
# otherwise leave stale prediction state for a later unrelated title. Same
# ${JOB_SIDECAR_DIR:-.} location convention as bad_sources.txt/
# corrupt_files.txt (ves-validation.sh) -- per-scan-root, not a new sidecar
# path. 2026-08-24: added per explicit user direction to start collecting
# real predicted-vs-actual data, since no such tracking existed before and
# "is VMAF_SAMPLES=3 enough" had no empirical answer.
log_sample_prediction_outcome() {
  local actual_out_bytes="$1" actual_codec="$2"
  [ "$SAMPLE_PRED_ACTIVE" = true ] || return 0
  local logf="${JOB_SIDECAR_DIR:-.}/sample-prediction-log.tsv"
  local pred_bytes correct="unknown"
  case "$SAMPLE_PRED_DECISION" in
    av1) pred_bytes="$SAMPLE_PRED_AV1_BYTES" ;;
    x265) pred_bytes="$SAMPLE_PRED_X265_BYTES" ;;
  esac
  if [[ "$pred_bytes" =~ ^[0-9]+$ ]] && [[ "$actual_out_bytes" =~ ^[0-9]+$ ]] \
     && [[ "$SAMPLE_PRED_ORIG_BYTES" =~ ^[0-9]+$ ]]; then
    # "correct" = the sample predicted the right DIRECTION (shrink vs grow
    # vs original), not an exact size match -- that's the question that
    # actually matters for wasted-cycle avoidance: did trusting the sample
    # and running the real encode pay off, or was the real result on the
    # wrong side of "original" from what the sample predicted.
    correct="$(awk -v p="$pred_bytes" -v a="$actual_out_bytes" -v o="$SAMPLE_PRED_ORIG_BYTES" \
      'BEGIN { pd = (p < o); ad = (a < o); print (pd == ad) ? "yes" : "no" }')"
  fi
  if [ ! -f "$logf" ]; then
    printf 'timestamp\tkind\tdecision\tpoints_used\tpoints_requested\torig_bytes\tpred_av1_bytes\tpred_x265_bytes\tactual_codec\tactual_bytes\tpred_correct_direction\n' >>"$logf" 2>/dev/null
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$SAMPLE_PRED_KIND" "$SAMPLE_PRED_DECISION" \
    "$SAMPLE_PRED_POINTS_USED" "$SAMPLE_PRED_POINTS_REQUESTED" "$SAMPLE_PRED_ORIG_BYTES" \
    "$SAMPLE_PRED_AV1_BYTES" "$SAMPLE_PRED_X265_BYTES" "$actual_codec" "$actual_out_bytes" "$correct" \
    >>"$logf" 2>/dev/null
  SAMPLE_PRED_ACTIVE=false
  SAMPLE_PRED_KIND=""
  SAMPLE_PRED_DECISION=""
  SAMPLE_PRED_AV1_BYTES=""
  SAMPLE_PRED_X265_BYTES=""
  SAMPLE_PRED_ORIG_BYTES=""
  SAMPLE_PRED_POINTS_USED=""
  SAMPLE_PRED_POINTS_REQUESTED=""
}

# Appends one line to content-variance-log.tsv recording the raw low/
# median/high packet-size sample values (source_content_variance_probe(),
# ves-source-traits.sh) for every file that finishes processing, alongside
# the real outcome (codec chosen, actual output size vs. original) --
# pure observability, no gate depends on this. 2026-08-24, per explicit
# user direction: this originated as a chunk-parallel-eligibility gate
# (high/median ratio) on the 6.x-chunk-redesign branch that a real
# 17-title validation against known reference titles found had no
# coherent genre/pacing correlation (see docs/DESIGN-6x-chunk-redesign.md
# on that branch) -- reverted as a gate there, but 17 titles isn't a
# statistically meaningful sample for something this potentially subtle,
# so rather than abandon the signal, this keeps recording the RAW low/
# median/high values (not just one collapsed ratio, so future analysis
# isn't locked into today's statistic choice) for every file processed on
# BOTH this line and the 6.x branch, accumulating from real day-to-day
# fleet volume instead of only deliberate test runs. Same
# ${JOB_SIDECAR_DIR:-.} location convention as sample-prediction-log.tsv/
# bad_sources.txt. Best-effort: a probe failure (e.g. an unusual source
# ffprobe can't read packet sizes for) just skips this file's row rather
# than blocking anything.
log_source_content_variance() {
  local src="$1" actual_codec="$2" actual_out_bytes="$3" orig_bytes="$4"
  local probe low med high ratio="" logf dur
  probe="$(source_content_variance_probe "$src" 2>/dev/null)" || return 0
  read -r low med high <<<"$probe"
  [[ "$low" =~ ^[0-9]+$ ]] && [[ "$med" =~ ^[0-9]+$ ]] && [[ "$high" =~ ^[0-9]+$ ]] || return 0
  [ "$med" -gt 0 ] && ratio="$(awk -v h="$high" -v m="$med" 'BEGIN{printf "%.2f", h/m}')"
  dur="$(video_duration "$src" 2>/dev/null)"
  logf="${JOB_SIDECAR_DIR:-.}/content-variance-log.tsv"
  if [ ! -f "$logf" ]; then
    printf 'timestamp\tsource\tduration_secs\tlow_bytes\tmedian_bytes\thigh_bytes\thigh_median_ratio\tactual_codec\tactual_out_bytes\torig_bytes\n' >>"$logf" 2>/dev/null
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(basename -- "$src")" "${dur:-}" "$low" "$med" "$high" \
    "${ratio:-}" "${actual_codec:-}" "${actual_out_bytes:-}" "${orig_bytes:-}" \
    >>"$logf" 2>/dev/null
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
  if [ "$SAMPLE_PRED_ACTIVE" = true ] && [ -n "$out" ] && [ -f "$out" ] && [ "$DRY_RUN" = false ]; then
    log_sample_prediction_outcome "$(file_size_bytes "$out")" "$SAMPLE_PRED_DECISION"
  elif [ "$SAMPLE_PRED_ACTIVE" = true ]; then
    # No real output (encode failed/skipped downstream of the decision) --
    # nothing to compare, but still clear the sticky state so it can't leak
    # into a later, unrelated title's own record_conversion_result call.
    SAMPLE_PRED_ACTIVE=false
  fi
  if [ "$DRY_RUN" = false ]; then
    if [ -n "$out" ] && [ -f "$out" ]; then
      log_source_content_variance "$src" "$(video_codec "$out" 2>/dev/null)" "$(file_size_bytes "$out")" "$orig_sz"
    else
      log_source_content_variance "$src" "" "" "$orig_sz"
    fi
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
