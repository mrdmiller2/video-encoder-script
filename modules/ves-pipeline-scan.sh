#!/usr/bin/env bash
# ves-pipeline-scan.sh -- the pipeline-vs-batch dual-mode scan/encode
# driver: background scan producer, ready-queue bookkeeping, and both the
# pipeline and batch convert_library_* entry points. Pure move from the
# former monolithic script -- no logic changes. NOTE: convert_scan_producer
# (background-job + PID-file pattern) and ves-tracked-process.sh's
# run_tracked_encoder/kill_active_encoder are near-duplicate ad hoc
# implementations of the same "detached background job" concept -- flagged
# in the modularization plan as a DRY-up candidate (a new
# ves-detached-exec.sh), deliberately NOT done in this phase since it would
# require actual logic changes, not a pure move.

inspect_library() {
  local -a videos=() disks=() roots=()
  local f shard shard_idx=0 shard_total=0

  get_scan_roots roots
  shard_total="${#roots[@]}"

  if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
    log "Inspect: sharded scan (depth=$SHARD_DEPTH, $shard_total shard(s))"
  fi

  for shard in "${roots[@]}"; do
    shard_idx=$((shard_idx + 1))
    if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
      begin_shard_log "$shard"
      log "Inspect shard $shard_idx/$shard_total: $shard"
    fi
    while IFS= read -r f; do
      videos+=("$f")
    done < <(find_convert_videos_under "$shard")
    if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
      end_shard_log "$shard"
    fi
  done

  if roots_need_catchup_scan roots; then
    while IFS= read -r f; do
      videos+=("$f")
    done < <(find_videos_at_root "$SEARCH_PATH")
  fi

  discover_disk_sources disks

  log "Inspect: ${#videos[@]} video(s), ${#disks[@]} disc source(s)"
  stats_log_append "--- media inspection (dry-run) ---"
  for f in "${videos[@]}"; do
    is_derived_output "$f" && continue
    is_video_file "$f" || continue
    record_media_inspection "$f"
  done
  for f in "${disks[@]}"; do
    record_disk_inspection "$f"
  done
  stats_log_append "--- end inspection ---"
  stats_log_append ""
}

# Fast find-only count (no ffprobe). Stops early once threshold is reached.
convert_estimate_scan_total() {
  local -a roots=()
  local shard total=0

  get_scan_roots roots
  for shard in "${roots[@]}"; do
    # Fast count only, no ffprobe/mkvmerge -- this decides batch vs pipeline
    # mode before any real work has started, so it must not trigger
    # multipart merges (that's real I/O, potentially hours of it on a cold
    # first run across a whole TV region).
    while IFS= read -r _; do
      total=$((total + 1))
      if [ "$total" -ge "$PIPELINE_FILE_THRESHOLD" ]; then
        printf 'over'
        return 0
      fi
    done < <(find_convert_videos_under "$shard" true)
  done

  if roots_need_catchup_scan roots; then
    while IFS= read -r _; do
      total=$((total + 1))
      if [ "$total" -ge "$PIPELINE_FILE_THRESHOLD" ]; then
        printf 'over'
        return 0
      fi
    done < <(find_videos_at_root "$SEARCH_PATH" true)
  fi

  printf '%s' "$total"
}

# 0 = pipeline, 1 = batch (largest-first).
convert_library_use_pipeline() {
  local estimate

  if [ "$FORCE_PIPELINE" = true ]; then
    log "Convert mode: pipeline inspect→encode (forced --pipeline)"
    return 0
  fi
  if [ "$LARGEST_FIRST" = true ]; then
    log "Convert mode: batch largest-first (forced --largest-first)"
    return 1
  fi

  if _path_on_cifs "$SEARCH_PATH"; then
    log "Convert mode: pipeline (CIFS/SMB mount — inspect waves of $ENCODE_INSPECT_BATCH_SIZE)"
    return 0
  fi

  log "Estimating file count (find-only) to pick convert mode (threshold=$PIPELINE_FILE_THRESHOLD)..."
  estimate="$(convert_estimate_scan_total)"
  if [ "$estimate" = over ]; then
    log "Convert mode: pipeline (inspect waves of $ENCODE_INSPECT_BATCH_SIZE, encode one-at-a-time; library has ≥$PIPELINE_FILE_THRESHOLD files)"
    return 0
  fi
  log "Convert mode: batch largest-first ($estimate file(s) — under $PIPELINE_FILE_THRESHOLD)"
  return 1
}

# True when this source should enter the convert queue (quick output check during scan).
convert_file_should_queue() {
  local f="$1"
  local skip_reason

  # v5.0.1 fast path: durably finished + source unchanged -> no ffprobe, no
  # output validation, no queue slot. Skipped when the user has explicitly
  # approved re-processing this exact tagged single-file target (see the
  # startup confirmation prompt / --force-reprocess) -- otherwise the done-log
  # would silently re-defeat an approval the user just gave, since a
  # previously-converted file normally carries both a tag and a done-log
  # entry. FORCE_REPROCESS_TAGGED is guaranteed single-file-scoped by this
  # point (batch/folder scans force it back to false at startup), so this
  # can never suppress the done-log for anything other than that one target.
  if [ "$FORCE_REPROCESS_TAGGED" != true ] && done_log_should_skip "$f"; then
    DONE_FAST_SKIPS=$((DONE_FAST_SKIPS + 1))
    return 1
  fi

  # Embedded-tag check: catches files the done-log/naming-convention checks above
  # miss (folder done-marker lost, or output relocated/renamed outside the script).
  # Always enforced during a batch/folder scan; bypassed only when the user
  # explicitly approved re-processing this exact single-file target (see the
  # SINGLE_FILE_MODE confirmation prompt near startup, or --force-reprocess).
  if [ "$FORCE_REPROCESS_TAGGED" != true ] && ! is_derived_output "$f" && mkv_ves_tag_present "$f"; then
    if mkv_ves_tag_tools_drifted "$f"; then
      log "Encode tools have moved on meaningfully since this was tagged — re-checking rather than skipping (still subject to VMAF/size guardrails): $f"
    else
      log "Skip — already tagged (VES ${VES_MAJOR}.x processed): $f"
      record_skip "$f" "already VES-tagged processed"
      DONE_FAST_SKIPS=$((DONE_FAST_SKIPS + 1))
      return 1
    fi
  fi

  if is_derived_output "$f"; then
    [ "$SKIP_AV1" = true ] && return 1
    needs_oversized_av1_recheck "$f"
    return $?
  fi

  is_video_file "$f" || return 1

  if ! source_looks_processable_quick "$f"; then
    return 1
  fi

  # Deletes bad processed outputs; skips queue when a valid complete output
  # exists. Bypassed on an approved single-file force-reprocess target for
  # the same reason as the two checks above -- otherwise a still-valid prior
  # output would silently defeat the user's explicit re-process approval.
  if [ "$FORCE_REPROCESS_TAGGED" != true ] && ! inspect_existing_outputs_for_queue "$f"; then
    return 1
  fi

  if should_skip_source_format "$f"; then
    skip_reason="$(skip_reason_for_format "$f")"
    log "Skip — $skip_reason: $f"
    record_skip "$f" "$skip_reason"
    return 1
  fi
  return 0
}

convert_log_inspect_progress() {
  local f="$1"
  local shard="${2:-}"
  local name

  CONVERT_SCAN_COUNT=$((CONVERT_SCAN_COUNT + 1))
  name="$(basename "$f")"
  if [ -n "$shard" ]; then
    log "Inspect $CONVERT_SCAN_COUNT: $name (shard: $(basename "$shard"))"
  else
    log "Inspect $CONVERT_SCAN_COUNT: $name"
  fi
}

convert_init_pipeline_files() {
  CONVERT_READY_FILE="$JOB_SIDECAR_DIR/convert-ready.queue"
  CONVERT_SCAN_DONE_FILE="$JOB_SIDECAR_DIR/convert-scan.done"
  CONVERT_SCAN_TOTAL_FILE="$JOB_SIDECAR_DIR/convert-scan.total"
  rm -f -- "$CONVERT_SCAN_DONE_FILE" "$CONVERT_SCAN_TOTAL_FILE"
  # `rm -f` (removing whatever's there, symlink or not) followed by a plain
  # `: >path` to recreate it leaves a window where a symlink replanted at
  # that exact name between the two steps would get followed and truncated
  # -- fixed the same way as every other predictable-path reset: create via
  # mktemp, then mv into place (mv replaces the destination, including a
  # symlink, directly and atomically without following it).
  _safe_touch_empty_flag "$CONVERT_READY_FILE" || : >"$CONVERT_READY_FILE"
  _safe_touch_empty_flag "$RESUME_QUEUE_FILE" || : >"$RESUME_QUEUE_FILE"
  CONVERT_READY_OFFSET=0
  CONVERT_SCAN_COUNT=0
  # Persistent read fd: sequential `read -u` advances a stream position in
  # O(1) per call, unlike `sed -n Np` which rescans from the start of the
  # (ever-growing) file every time -- O(n^2) total across a large queue.
  exec {CONVERT_READY_FD}<"$CONVERT_READY_FILE" || CONVERT_READY_FD=""
  # Persistent write fds, opened here (before convert_scan_producer forks)
  # rather than reopening these files by path on every discovered item --
  # the forked producer inherits these, and O_APPEND writes through an
  # already-open fd are immune to the path later being swapped for a
  # symlink, unlike reopening by name on each append.
  exec {CONVERT_READY_WRITE_FD}>>"$CONVERT_READY_FILE" || CONVERT_READY_WRITE_FD=""
  exec {RESUME_QUEUE_WRITE_FD}>>"$RESUME_QUEUE_FILE" || RESUME_QUEUE_WRITE_FD=""
}

# convert_scan_producer runs as a background process (&) -- variable writes
# there (including CONVERT_JOB_TOTAL) live only in that child and never
# propagate back to this shell. The queued count must cross via a file.
convert_pipeline_scan_total() {
  local n
  [ -n "$CONVERT_SCAN_TOTAL_FILE" ] && [ -f "$CONVERT_SCAN_TOTAL_FILE" ] || { printf '0'; return; }
  n="$(cat "$CONVERT_SCAN_TOTAL_FILE" 2>/dev/null)"
  [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$n" || printf '0'
}

convert_append_ready_item() {
  local f="$1"
  if [ -n "${CONVERT_READY_WRITE_FD:-}" ]; then
    printf '%s\n' "$f" >&"$CONVERT_READY_WRITE_FD"
  else
    printf '%s\n' "$f" >>"$CONVERT_READY_FILE"
  fi
  if [ -n "${RESUME_QUEUE_WRITE_FD:-}" ]; then
    printf '%s\n' "$f" >&"$RESUME_QUEUE_WRITE_FD"
  else
    printf '%s\n' "$f" >>"$RESUME_QUEUE_FILE"
  fi
}

# Scan library in background; append eligible paths to CONVERT_READY_FILE as found.
convert_scan_producer() {
  local -a roots=() disks=()
  local f shard shard_idx=0 shard_total=0 queued=0

  trap '_safe_touch_empty_flag "$CONVERT_SCAN_DONE_FILE" 2>/dev/null || touch "$CONVERT_SCAN_DONE_FILE" 2>/dev/null || true' EXIT

  get_scan_roots roots
  shard_total="${#roots[@]}"

  if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
    log "Convert scan: sharded (depth=$SHARD_DEPTH, $shard_total shard(s))"
  else
    log "Convert scan: pipeline inspect→encode (inspect runs ahead while jobs encode)"
  fi

  for shard in "${roots[@]}"; do
    shard_idx=$((shard_idx + 1))
    if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
      begin_shard_log "$shard"
      log "Convert scan shard $shard_idx/$shard_total: $shard"
    fi
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      convert_log_inspect_progress "$f" "$shard"
      if convert_file_should_queue "$f"; then
        queued=$((queued + 1))
        convert_append_ready_item "$f"
        log "Queued ($queued): $(basename "$f")"
      fi
    done < <(find_convert_videos_under "$shard")
    if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
      end_shard_log "$shard"
    fi
  done

  if roots_need_catchup_scan roots; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      convert_log_inspect_progress "$f" "$SEARCH_PATH"
      if convert_file_should_queue "$f"; then
        queued=$((queued + 1))
        convert_append_ready_item "$f"
        log "Queued ($queued): $(basename "$f")"
      fi
    done < <(find_videos_at_root "$SEARCH_PATH")
  fi

  discover_disk_sources disks
  for f in "${disks[@]}"; do
    convert_log_inspect_progress "$f"
    if ! inspect_existing_outputs_for_queue "$f"; then
      continue
    fi
    queued=$((queued + 1))
    convert_append_ready_item "$f"
    log "Queued disc ($queued): $(basename "$f")"
  done

  CONVERT_JOB_TOTAL="$queued"
  # This runs in the background scan process -- the CONVERT_JOB_TOTAL
  # assignment above never reaches the parent shell, only this file does.
  # Written via a private tempfile + mv (not a direct truncating `>`) so a
  # symlink raced into place at this predictable path since init's `rm -f`
  # gets replaced atomically rather than followed and overwritten.
  local scan_total_tmp
  scan_total_tmp="$(mktemp "${CONVERT_SCAN_TOTAL_FILE}.XXXXXX" 2>/dev/null)" && {
    printf '%s' "$queued" >"$scan_total_tmp"
    if mv -f "$scan_total_tmp" "$CONVERT_SCAN_TOTAL_FILE" 2>/dev/null; then
      _restore_default_file_mode "$CONVERT_SCAN_TOTAL_FILE"
    else
      rm -f "$scan_total_tmp"
    fi
  }
  log "Convert scan complete: $CONVERT_SCAN_COUNT inspected, $queued queued"
  _safe_touch_empty_flag "$CONVERT_SCAN_DONE_FILE" || touch "$CONVERT_SCAN_DONE_FILE" 2>/dev/null
}

convert_pipeline_resume_offset() {
  local -a queue=()
  local item want_path resume_idx=-1 i=0
  local -A in_old=()

  [ "$RESUME_ACTIVE" = true ] || { printf '0'; return 0; }
  [ -n "$RESUME_LAST_SOURCE" ] || { printf '0'; return 0; }
  load_queue_snapshot queue || { printf '0'; return 0; }

  for item in "${queue[@]}"; do
    in_old["$item"]=1
  done

  case "$RESUME_LAST_STATUS" in
    completed|skipped)
      want_path=""
      for i in "${!queue[@]}"; do
        if [ "${queue[$i]}" = "$RESUME_LAST_SOURCE" ]; then
          if [ $((i + 1)) -lt "${#queue[@]}" ]; then
            want_path="${queue[$((i + 1))]}"
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
    for i in "${!queue[@]}"; do
      if [ "${queue[$i]}" = "$want_path" ]; then
        resume_idx="$i"
        break
      fi
    done
  fi

  if [ "$resume_idx" -lt 0 ]; then
    if [ "$RESUME_LAST_INDEX" -gt 0 ] && [ "$RESUME_LAST_INDEX" -le "${#queue[@]}" ]; then
      resume_idx=$((RESUME_LAST_INDEX - 1))
      if [ "$RESUME_LAST_STATUS" = completed ] || [ "$RESUME_LAST_STATUS" = skipped ]; then
        [ "$resume_idx" -lt "${#queue[@]}" ] && resume_idx=$((resume_idx + 1)) || resume_idx=-1
      fi
    fi
  fi

  if [ "$resume_idx" -lt 0 ]; then
    warn "Resume anchor not found in current queue — starting from first queued item"
    printf '0'
    return 0
  fi

  # log_err: this function's stdout is captured as the numeric resume offset.
  log_err "Resume: last job was $RESUME_LAST_STATUS on $(basename "$RESUME_LAST_SOURCE") (shard: ${RESUME_LAST_SHARD:-unknown})"
  log_err "Resume: skipping first $resume_idx queued item(s)"
  printf '%s' "$resume_idx"
}

convert_pipeline_ready_pending() {
  local ready_lines=0
  [ -f "$CONVERT_READY_FILE" ] && { ready_lines="$(wc -l <"$CONVERT_READY_FILE" | tr -d ' ')" || ready_lines=0; }
  echo $((ready_lines - CONVERT_READY_OFFSET))
}

# Start an encode wave when N items are queued, or when scan ends with a partial wave.
convert_pipeline_should_start_batch() {
  local pending="$1"
  [ "$pending" -ge "$ENCODE_INSPECT_BATCH_SIZE" ] && return 0
  [ -f "$CONVERT_SCAN_DONE_FILE" ] && [ "$pending" -gt 0 ] && return 0
  return 1
}

convert_run_encode_job() {
  local f="$1"
  local idx="$2"
  local total_label="$3"

  CONVERT_JOB_OK=false
  if ! begin_convert_job "$f" "$idx" "$total_label"; then
    return 0
  fi
  if is_disk_source "$f"; then
    process_disk "$f" && CONVERT_JOB_OK=true || warn "Job failed — continuing queue: $f"
  else
    process_video "$f" && CONVERT_JOB_OK=true || warn "Job failed — continuing queue: $f"
  fi
  end_convert_job "$f" "$idx" "$total_label" "$CONVERT_JOB_OK"
}

convert_run_pipeline_jobs() {
  local resume_skip="${1:-0}"
  local -a batch=()
  local f total_label pending batch_num=0 bf ready_lines=0

  CONVERT_JOB_INDEX=0
  if [ "$RESUME_ACTIVE" = true ] && [ "${RESUME_LAST_INDEX:-0}" -gt 0 ]; then
    case "$RESUME_LAST_STATUS" in
      completed|skipped) CONVERT_JOB_INDEX="$RESUME_LAST_INDEX" ;;
      *) CONVERT_JOB_INDEX=$((RESUME_LAST_INDEX - 1)) ;;
    esac
  fi

  while true; do
    pending="$(convert_pipeline_ready_pending)"

    if ! convert_pipeline_should_start_batch "$pending"; then
      ready_lines=0
      [ -f "$CONVERT_READY_FILE" ] && { ready_lines="$(wc -l <"$CONVERT_READY_FILE" | tr -d ' ')" || ready_lines=0; }
      if [ -f "$CONVERT_SCAN_DONE_FILE" ] && [ "$CONVERT_READY_OFFSET" -ge "$ready_lines" ]; then
        break
      fi
      if ! kill -0 "$CONVERT_SCAN_PID" 2>/dev/null && [ ! -f "$CONVERT_SCAN_DONE_FILE" ]; then
        warn "Convert scan process exited unexpectedly"
        break
      fi
      sleep 2
      continue
    fi

    batch=()
    while [ "${#batch[@]}" -lt "$ENCODE_INSPECT_BATCH_SIZE" ]; do
      pending="$(convert_pipeline_ready_pending)"
      [ "$pending" -eq 0 ] && break
      IFS= read -r -u "$CONVERT_READY_FD" f || break
      [ -n "$f" ] || break
      CONVERT_READY_OFFSET=$((CONVERT_READY_OFFSET + 1))
      # resume_skip must be numeric (convert_pipeline_resume_offset prints only digits).
      if [[ "$resume_skip" =~ ^[0-9]+$ ]] && [ "$CONVERT_READY_OFFSET" -le "$resume_skip" ]; then
        pending="$(convert_pipeline_ready_pending)"
        [ "$pending" -eq 0 ] && [ -f "$CONVERT_SCAN_DONE_FILE" ] && break
        continue
      fi
      batch+=("$f")
      pending="$(convert_pipeline_ready_pending)"
      if [ -f "$CONVERT_SCAN_DONE_FILE" ] && [ "$pending" -eq 0 ]; then
        break
      fi
    done

    [ "${#batch[@]}" -eq 0 ] && continue

    batch_num=$((batch_num + 1))
    sort_paths_by_size_desc batch
    log "Encode wave $batch_num: ${#batch[@]} item(s) (largest first; one encode at a time — inspection continues in background)"

    for bf in "${batch[@]}"; do
      CONVERT_JOB_INDEX=$((CONVERT_JOB_INDEX + 1))
      if [ -f "$CONVERT_SCAN_DONE_FILE" ]; then
        total_label="$(convert_pipeline_scan_total)"
        [[ "$total_label" =~ ^[1-9][0-9]*$ ]] || total_label='?'
      else
        total_label='?'
      fi
      convert_run_encode_job "$bf" "$CONVERT_JOB_INDEX" "$total_label"
    done
  done

  wait "$CONVERT_SCAN_PID" 2>/dev/null || true
  CONVERT_SCAN_PID=0
}

convert_library_pipeline() {
  resume_init_paths
  local resume_skip
  resume_skip="$(convert_pipeline_resume_offset)"
  convert_init_pipeline_files

  if [ "$RESUME_ACTIVE" != true ]; then
    build_shard_snapshot "$RESUME_SHARDS_FILE" || true
  fi

  convert_scan_producer &
  CONVERT_SCAN_PID=$!
  log "Convert pipeline started (scan pid=$CONVERT_SCAN_PID; first encode after $ENCODE_INSPECT_BATCH_SIZE inspected item(s) queued, one encode at a time)"

  convert_run_pipeline_jobs "$resume_skip"

  # CONVERT_JOB_TOTAL itself was only ever set inside the background scan
  # process (convert_scan_producer &) and never propagates here -- read the
  # real count back from the file it wrote instead, or this always reads 0.
  local final_total
  final_total="$(convert_pipeline_scan_total)"
  if [ "$final_total" -gt 0 ] 2>/dev/null; then
    log "Convert queue finished: $final_total item(s)"
  else
    log "Convert queue finished: no items needed encoding"
  fi
  log_batch_encode_total

  { exec {CONVERT_READY_FD}<&-; } 2>/dev/null || true

  if [ "$DRY_RUN" = false ]; then
    resume_clear_state
    log "Convert queue finished — resume state cleared"
  fi

  rm -f -- "$CONVERT_READY_FILE" "$CONVERT_SCAN_DONE_FILE" "$CONVERT_SCAN_TOTAL_FILE"
}

convert_library_batch() {
  local -a videos=() disks=() queue=() roots=()
  local f shard shard_idx=0 shard_total=0

  resume_init_paths

  get_scan_roots roots
  shard_total="${#roots[@]}"

  if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
    log "Convert: sharded scan (depth=$SHARD_DEPTH, $shard_total shard(s))"
  else
    log "Convert: batch mode (--largest-first) — full inspect before first encode"
  fi

  for shard in "${roots[@]}"; do
    shard_idx=$((shard_idx + 1))
    if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
      begin_shard_log "$shard"
      log "Convert shard $shard_idx/$shard_total: $shard"
    fi
    while IFS= read -r f; do
      videos+=("$f")
    done < <(find_convert_videos_under "$shard")
    if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
      end_shard_log "$shard"
    fi
  done

  if roots_need_catchup_scan roots; then
    while IFS= read -r f; do
      videos+=("$f")
    done < <(find_videos_at_root "$SEARCH_PATH")
  fi

  discover_disk_sources disks

  log "Convert inspect: ${#videos[@]} video(s), ${#disks[@]} disc source(s)"
  for f in "${videos[@]}"; do
    convert_log_inspect_progress "$f"
    if convert_file_should_queue "$f"; then
      queue+=("$f")
    fi
  done

  for f in "${disks[@]}"; do
    convert_log_inspect_progress "$f"
    if ! inspect_existing_outputs_for_queue "$f"; then
      continue
    fi
    queue+=("$f")
  done

  sort_paths_by_size_desc queue

  if [ "$RESUME_ACTIVE" = true ]; then
    apply_resume_to_queue queue
  else
    build_shard_snapshot "$RESUME_SHARDS_FILE" || true
  fi

  write_queue_snapshot queue
  CONVERT_JOB_TOTAL=${#queue[@]}
  log "Convert queue: $CONVERT_JOB_TOTAL items (largest first; one at a time; includes ${#disks[@]} disc source(s))"

  CONVERT_JOB_INDEX=0
  for f in "${queue[@]}"; do
    CONVERT_JOB_INDEX=$((CONVERT_JOB_INDEX + 1))
    CONVERT_JOB_OK=false
    if ! begin_convert_job "$f" "$CONVERT_JOB_INDEX" "$CONVERT_JOB_TOTAL"; then
      continue
    fi
    if is_disk_source "$f"; then
      process_disk "$f" && CONVERT_JOB_OK=true || warn "Job failed — continuing queue: $f"
    else
      process_video "$f" && CONVERT_JOB_OK=true || warn "Job failed — continuing queue: $f"
    fi
    end_convert_job "$f" "$CONVERT_JOB_INDEX" "$CONVERT_JOB_TOTAL" "$CONVERT_JOB_OK"
  done

  if [ "$DRY_RUN" = false ]; then
    resume_clear_state
    log "Convert queue finished — resume state cleared"
  fi
  log_batch_encode_total
}

convert_library() {
  if convert_library_use_pipeline; then
    convert_library_pipeline
  else
    convert_library_batch
  fi
  season_retry_pass
}
