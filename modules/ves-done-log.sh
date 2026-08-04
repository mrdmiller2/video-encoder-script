#!/usr/bin/env bash
# ves-done-log.sh -- the durable per-file done-log (load/append/skip-check).
# Pure move from the former monolithic script -- no logic changes.

done_log_load() {
  local st sz mt p fp n=0
  DONE_SET=()
  DONE_SET_LOADED=true
  [ -n "$RESUME_DONE_LOG" ] && [ -f "$RESUME_DONE_LOG" ] || return 0
  # 5th column (tools fingerprint) is new as of v5.0.32F -- `read` leaves fp
  # empty on older 4-column lines, which tools_fingerprint_is_stale() treats
  # as "not stale" (see done_log_should_skip), so pre-existing done-logs keep
  # fast-skipping exactly as before rather than forcing a one-time full-
  # library recheck the moment this ships.
  while IFS=$'\t' read -r st sz mt p fp; do
    [ -n "$p" ] || continue
    case "$st" in done|skip) DONE_SET["$p"]="$sz|$mt#$fp"; n=$((n+1)) ;; esac
  done <"$RESUME_DONE_LOG"
  # This function is called as a bare statement all the way up through
  # resume_prepare_convert to main() -- none of those call sites are
  # if/while/&&/||-exempt from set -e, so this being the LAST statement in
  # the function means its own exit status becomes done_log_load's return
  # value. `[ "$n" -gt 0 ] && log ...` was that last statement, so whenever
  # the done-log file exists but happens to have zero matching done/skip
  # entries, the implicit "false" return would abort the entire script at
  # startup, before any conversion work happens. Explicit if + a real
  # `return 0` avoids the whole class of "last statement's truthiness
  # becomes an unintended function return" bug.
  if [ "$n" -gt 0 ]; then
    log "Done-log: $n finished source(s) on record — unchanged files fast-skip (bypass with --no-resume)"
  fi
  return 0
}

done_log_append() {  # status src
  local st="$1" src="$2" key fp
  [ "$DRY_RUN" = true ] && return 0
  [ -n "${RESUME_DONE_LOG:-}" ] || return 0
  is_disk_source "$src" && return 0
  key="$(mkv_structure_stat_key "$src")" || return 0
  fp="$(current_tools_fingerprint)"
  if [ -n "$DONE_LOG_FD" ]; then
    local _mtok
    _mtok="$(_shared_mutex_acquire "${RESUME_DONE_LOG}.appendlock")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$st" "${key%%|*}" "${key##*|}" "$src" "$fp" >&"$DONE_LOG_FD" 2>/dev/null || true
    _shared_mutex_release "${RESUME_DONE_LOG}.appendlock" "$_mtok"
  fi
  DONE_SET["$src"]="$key#$fp"
}

done_log_should_skip() {  # src -> 0 when durably done, unchanged, and tools haven't drifted
  local src="$1" key stored stored_key stored_fp
  [ "$NO_RESUME" = true ] && return 1
  [ "$DONE_SET_LOADED" = true ] || return 1
  stored="${DONE_SET[$src]:-}"
  [ -n "$stored" ] || return 1
  key="$(mkv_structure_stat_key "$src")" || return 1
  stored_key="${stored%%#*}"
  stored_fp="${stored#*#}"
  # No '#' present at all means stored_key already equals the whole string
  # (bash leaves an unmatched `#pattern` expansion untouched) -- that's a
  # pre-fingerprint entry, not one with an empty fingerprint; treat the same
  # (not stale) either way, but only take the substring when a real
  # fingerprint was actually recorded.
  [ "$stored" = "$stored_key" ] && stored_fp=""
  [ "$key" = "$stored_key" ] || return 1
  ! tools_fingerprint_is_stale "$stored_fp"
}
