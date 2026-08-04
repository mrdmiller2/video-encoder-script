#!/usr/bin/env bash
# ves-junk-cleanup.sh -- zero-byte-output/stale-flag junk scanning and the
# per-folder done/in-progress flag primitives. Pure move from the former
# monolithic script -- no logic changes.

folder_done_flag_path() { printf '%s/%s' "$1" "$FOLDER_DONE_FLAG_NAME"; }

folder_inprogress_flag_path() { printf '%s/%s' "$1" "$FOLDER_INPROGRESS_FLAG_NAME"; }

# Same atomic mktemp+mv pattern as _safe_touch_empty_flag, but with the
# current tools fingerprint as content instead of an empty file -- lets
# folder_marked_done() invalidate a whole folder's fast-skip once the
# fleet's encode tools have moved on to a meaningfully newer major.minor
# (see tools_fingerprint_is_stale, added v5.0.32F).
#
# Known follow-up (team review, 2026-07-20, not yet fixed): once a stale
# folder-done flag is invalidated, the common per-file heal path is
# inspect_existing_outputs_for_queue -> done_log_append (which DOES refresh
# that file's own fingerprint) -- but nothing re-runs
# mark_folder_done_if_complete afterward, so the folder-done flag itself
# can stay stale indefinitely on an already-fully-encoded folder where no
# file ever takes the record_skip/record_conversion_result path again. Not
# a correctness bug (every file still gets its individual drift check via
# the done-log/tag paths either way) -- just means that folder loses its
# whole-folder fast-skip performance benefit until something re-marks it.
_write_folder_done_flag() {
  local flag="$1" tmp rc=0
  tmp="$(mktemp "$(dirname "$flag")/.convert-flag-XXXXXX" 2>/dev/null)" || return 1
  printf '%s\n' "$(current_tools_fingerprint)" >"$tmp" 2>/dev/null
  mv -f -- "$tmp" "$flag" 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then
    _restore_default_file_mode "$flag"
  else
    rm -f -- "$tmp" 2>/dev/null
  fi
  return "$rc"
}

folder_marked_done() {  # dir -> 0 if a valid (non-stale) done-flag exists
  local dir="$1" flag flag_mtime dir_mtime flag_fp
  [ "$IGNORE_DONE_FOLDERS" = true ] && return 1
  flag="$(folder_done_flag_path "$dir")"
  [ -f "$flag" ] || return 1
  flag_mtime="$(mkv_structure_stat_key "$flag" 2>/dev/null)" || true; flag_mtime="${flag_mtime##*|}"
  # Same subtree-aware mtime as the file-list cache -- a done-flag on Show/
  # must be invalidated by a new episode added under Show/Season 2/, not
  # just by a change directly inside Show/ itself.
  dir_mtime="$(dir_subtree_max_mtime "$dir")" || true
  [ -n "$flag_mtime" ] && [ -n "$dir_mtime" ] || return 1
  [ "$dir_mtime" -le "$flag_mtime" ] || return 1
  # Empty content (flags written before v5.0.32F, or _write_folder_done_flag
  # failing to record a fingerprint for some reason) is not treated as
  # stale -- see tools_fingerprint_is_stale's design note.
  flag_fp="$(cat "$flag" 2>/dev/null)"
  ! tools_fingerprint_is_stale "$flag_fp"
}

mark_folder_inprogress() {
  local dir="$1" flag
  [ "$DRY_RUN" = true ] && return 0
  flag="$(folder_inprogress_flag_path "$dir")"
  _safe_touch_empty_flag "$flag" || true
}

# Called after any per-file result is recorded (success, skip, or reject).
# Deliberately cheap: stat()-only signals (fast done-log + bare output
# existence), never ffprobe/mkvalidator -- this runs once per completed file
# and re-checks every sibling in the same folder, so an expensive per-file
# check here would turn into O(n^2) validation calls across a large folder.
# Existing outputs are trusted without re-validation because anything on
# disk as {title}.AV1.mkv/.x265.mkv already passed validate_mkv_output at
# the time it was created (this run or a prior one).
_dir_subtree_all_video_files_done() {  # dir -> 0 if every video file anywhere under it is finished
  local dir="$1" f
  while IFS= read -r f; do
    is_video_file "$f" || continue
    is_derived_output "$f" && continue
    is_multipart_merged_file "$f" && continue
    done_log_should_skip "$f" && continue
    # -s (non-empty), not bare -f: this whole-folder check is deliberately
    # cheap/stat-only (see comment above the caller), but a zero-byte or
    # truncated leftover next to the source -- e.g. a crash before staging
    # ever moved a real output into place -- would otherwise satisfy a
    # bare existence check and mark the entire folder done, permanently
    # skipping re-processing of that one broken file (team E2E review,
    # 2026-07-20). Still just a stat(), not a real validation.
    [ -s "$(av1_output_path "$f")" ] && continue
    [ -s "$(x265_output_path "$f")" ] && continue
    if is_must_eliminate_format "$f" && [ -s "$(must_eliminate_remux_path "$f")" ]; then
      continue
    fi
    return 1
  done < <(find "$dir" -type f 2>/dev/null)
  return 0
}

mark_folder_done_if_complete() {
  local dir="$1" f still_pending=false cached
  [ "$DRY_RUN" = true ] && return 0
  folder_marked_done "$dir" && return 0
  local -a files=()
  if cached="$(filecache_get "$dir")"; then
    [ -n "$cached" ] && while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done <<<"$cached"
  else
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done       < <(find "$dir" -maxdepth 1 -type f 2>/dev/null)
  fi
  [ "${#files[@]}" -gt 0 ] || return 0

  for f in "${files[@]}"; do
    is_video_file "$f" || continue
    is_derived_output "$f" && continue
    is_multipart_merged_file "$f" && continue
    done_log_should_skip "$f" && continue
    # -s not -f: see the matching fix/comment in _dir_subtree_all_video_files_done.
    [ -s "$(av1_output_path "$f")" ] && continue
    [ -s "$(x265_output_path "$f")" ] && continue
    if is_must_eliminate_format "$f" && [ -s "$(must_eliminate_remux_path "$f")" ]; then
      continue
    fi
    still_pending=true
    break
  done
  if [ "$still_pending" = false ]; then
    local done_flag="$(folder_done_flag_path "$dir")"
    _write_folder_done_flag "$done_flag" || true
    rm -f "$(folder_inprogress_flag_path "$dir")" 2>/dev/null
    log "Folder complete — marked done, will be skipped on future runs: $dir"
  fi

  # This function is called with dirname($src) -- for a nested TV layout
  # that's the Season folder, but find_convert_videos_under_cached only ever
  # checks folder_marked_done() at the Show folder (immediate child of the
  # scanned root). A done-flag written only at Season level is never found
  # by that check, so completed shows never actually got skipped. Also try
  # the parent: if the whole show's subtree is finished, mark it done too.
  #
  # Only worth attempting when $dir itself just came up clean: the parent
  # subtree check below necessarily re-examines every file under $dir too,
  # so if still_pending=true it's mathematically guaranteed to also report
  # the parent as not-done -- a full recursive re-scan of the whole show's
  # subtree (every season, every episode) wasted on every single per-file
  # completion event in an unfinished folder, on shared NFS. Gate on
  # still_pending to skip that O(n^2) cost.
  if [ "$still_pending" = false ]; then
    local parent
    parent="$(dirname "$dir")"
    # Never ascend above the scanned root -- there is nothing above it whose
    # done-flag would ever be consulted, and it may not even be ours to write to.
    case "$parent" in
      "$JOB_ROOT"|"$JOB_ROOT"/*) ;;
      *) parent="$dir" ;;
    esac
    if [ "$parent" != "$dir" ] && [ -d "$parent" ] && ! folder_marked_done "$parent"; then
      if _dir_subtree_all_video_files_done "$parent"; then
        local parent_done_flag="$(folder_done_flag_path "$parent")"
        _write_folder_done_flag "$parent_done_flag" || true
        rm -f "$(folder_inprogress_flag_path "$parent")" 2>/dev/null
        log "Folder complete — marked done, will be skipped on future runs: $parent"
      fi
    fi
  fi
}

junk_flag_is_stale() {  # flag path -> 0 if safe to remove
  local flag="$1" pid host
  # A lockdir exists (that's the only way this function gets called from
  # place_in_progress_flag) but its flag file is missing entirely -- the
  # normal sequence always writes the flag immediately after creating the
  # lockdir, so a missing flag means a crash/kill happened in that exact
  # window. Age-based staleness below computes age against $now when mtime
  # is unavailable, i.e. 0 -- "brand new", the opposite of what's true here.
  # That previously left an orphaned lockdir with no flag permanently
  # un-reclaimable (found in team E2E review, 2026-07-20): treat a missing
  # flag as unconditionally stale instead.
  [ -f "$flag" ] || return 0
  pid="$(awk -F= '/^pid=/{print $2; exit}' "$flag" 2>/dev/null)"
  host="$(awk -F= '/^host=/{print $2; exit}' "$flag" 2>/dev/null)"
  if [ -n "$pid" ] && [ "$host" = "$(hostname 2>/dev/null)" ]; then
    kill -0 "$pid" 2>/dev/null && return 1   # still running here — not stale
    return 0   # same host, pid confirmed dead — definitely stale, no need to wait
  fi
  # Different host, or no pid/host recorded at all: stale if older than 2
  # hours (avoid racing a run that just started and hasn't written progress
  # yet, and give a remote machine's own liveness signal time to show up).
  local mtime now age
  mtime="$(mkv_structure_stat_key "$flag" 2>/dev/null)" || true; mtime="${mtime##*|}"
  now="$(date +%s)"
  age=$(( now - ${mtime:-$now} ))
  [ "$age" -gt 7200 ]
}

# A zero-byte file matching our own output naming convention (Title.AV1.mkv
# etc.) is only safe to auto-delete if it's actually OUR derived output from
# a real source that still exists beside it -- an external review pointed
# out that a genuine original file could coincidentally be named that way
# (unusual, but the hard invariant doesn't get to assume "unusual never
# happens"), and deleting it based on name/size alone would violate "never
# delete an original, even a bad one." Requires a sibling file with the same
# title and a common video extension that ISN'T itself one of our derived
# suffixes.
_zero_byte_output_has_real_source() {
  local f="$1" dir base title escaped_title sib
  dir="$(dirname "$f")"
  base="$(basename "$f")"
  case "$base" in
    *.[Aa][Vv]1.[Mm][Kk][Vv])    title="${base%.*.*}" ;;
    *.[Xx]265.[Mm][Kk][Vv])      title="${base%.*.*}" ;;
    *.[Mm][Ee][Rr][Gg][Ee][Dd].[Mm][Kk][Vv]) title="${base%.*.*}" ;;
    *) return 1 ;;
  esac
  # $title comes from a real filename and can itself contain find -iname
  # glob metacharacters (*, ?, [) -- unescaped, a title like "Who?" would
  # match unrelated siblings ("WhoA...") and could misclassify a genuinely
  # sourceless zero-byte output as having a real source.
  escaped_title="${title//\\/\\\\}"
  escaped_title="${escaped_title//\*/\\*}"
  escaped_title="${escaped_title//\?/\\?}"
  escaped_title="${escaped_title//\[/\\[}"
  while IFS= read -r sib; do
    [ -n "$sib" ] || continue
    case "$(basename "$sib")" in
      *.[Aa][Vv]1.[Mm][Kk][Vv]|*.[Xx]265.[Mm][Kk][Vv]|*.[Mm][Ee][Rr][Gg][Ee][Dd].[Mm][Kk][Vv]) continue ;;
    esac
    return 0
  done < <(find "$dir" -maxdepth 1 -type f -iname "${escaped_title}.*" 2>/dev/null)
  return 1
}

clean_junk_scan() {
  local root="$1"
  local -a zero_byte=() zero_byte_no_source=() stale_flags=()
  local f

  log "Junk scan: $root"

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ ! -s "$f" ]; then
      if _zero_byte_output_has_real_source "$f"; then
        zero_byte+=("$f")
      else
        zero_byte_no_source+=("$f")
      fi
    fi
  done < <(find "$root" -type f \( -iname '*.AV1.mkv' -o -iname '*.x265.mkv' -o -iname '*.merged.mkv' \) 2>/dev/null)

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    junk_flag_is_stale "$f" && stale_flags+=("$f")
  done < <(find "$root" -type f -name "*.${IN_PROGRESS_FLAG_SUFFIX}" 2>/dev/null)

  # NOTE: a .merged.mkv whose raw Part1/Part2 sources are gone is NOT junk --
  # deleting the raw parts after verifying the merge is the normal, expected
  # cleanup workflow, and at that point the merged file is the ONLY copy.
  # An earlier version of this scan treated "source parts gone" as orphaned
  # and deleted the merge under --clean-junk-apply, which could destroy the
  # only remaining copy of the title. There's no reliable signal to tell
  # "user cleaned up verified parts" apart from "an aborted merge lost its
  # inputs" from file state alone, so this class is never auto-deleted.

  local total=$(( ${#zero_byte[@]} + ${#zero_byte_no_source[@]} + ${#stale_flags[@]} ))
  if [ "$total" -eq 0 ]; then
    log "Junk scan: nothing to clean"
    return 0
  fi

  log "Junk scan found $total item(s):"
  [ "${#zero_byte[@]}" -gt 0 ] && { log "  Zero-byte/empty outputs with a real source alongside them (${#zero_byte[@]}):"; printf '    %s\n' "${zero_byte[@]}"; }
  if [ "${#zero_byte_no_source[@]}" -gt 0 ]; then
    log "  Zero-byte files matching our output naming, but with NO corresponding source found (${#zero_byte_no_source[@]}) — never auto-deleted, could be a real (if corrupt) original:"
    printf '    %s\n' "${zero_byte_no_source[@]}"
  fi
  [ "${#stale_flags[@]}" -gt 0 ] && { log "  Stale IN_PROGRESS flags, no live process (${#stale_flags[@]}):"; printf '    %s\n' "${stale_flags[@]}"; }

  if [ "$CLEAN_JUNK_APPLY" != true ]; then
    log "Report only — rerun with --clean-junk-apply to delete the zero-byte-with-source and stale-flag items above."
    return 0
  fi

  local apply_total=$(( ${#zero_byte[@]} + ${#stale_flags[@]} ))
  for f in "${zero_byte[@]}"; do
    rm -f -- "$f" && log "  removed: $f"
  done
  for f in "${stale_flags[@]}"; do
    rm -f -- "$f" && log "  removed: $f"
    # The flag's own reclaim path (place_in_progress_flag) can't tell a
    # missing flag apart from "not stale" once this deletes it out from
    # under a live lockdir -- remove the sibling .lock too or the title is
    # permanently skipped as "claimed elsewhere" on every future run.
    if rmdir -- "${f}.lock" 2>/dev/null; then
      log "  removed: ${f}.lock"
    fi
  done
  log "Junk scan: removed $apply_total item(s)"
  if [ "${#zero_byte_no_source[@]}" -gt 0 ]; then
    log "  ${#zero_byte_no_source[@]} item(s) left untouched (no corresponding source found) — delete manually if you've confirmed they're safe to remove"
  fi
}

remove_output_only() {
  local f="$1"
  [ -e "$f" ] || return 0
  warn "Removing rejected output (original kept): $f"
  mkv_structure_cache_invalidate "$f"
  if [ "$DRY_RUN" = true ]; then
    return 0
  fi
  rm -f -- "$f"
}
