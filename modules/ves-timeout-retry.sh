#!/usr/bin/env bash
# ves-timeout-retry.sh -- bounded external-process execution: the timeout
# command resolution/degradation logic, the core run_with_timeout wrapper,
# and the thin per-tool wrappers (run_ffprobe/run_mkvmerge/run_mkvalidator/
# run_ffmpeg_validation/run_ffmpeg_remux/run_ffmpeg/run_mkvpropedit) built
# on top of it. Pure move from the former monolithic script -- no logic
# changes. Depends on ves-config.sh (FFMPEG_CMD/FFPROBE_CMD/etc arrays,
# VALIDATION_TIMEOUT_SECS and friends) already being sourced.

run_ffmpeg() { "${FFMPEG_CMD[@]}" "$@"; }

# Portable timeout helper (Phase B; Phase D reuses for all validation wrappers).
# Prints the timeout binary path and returns 0, or returns 1 if none available.
_timeout_cmd() {
  if [ -n "${_TIMEOUT_CMD_RESOLVED:-}" ]; then
    if [ "$_TIMEOUT_CMD_RESOLVED" = "none" ]; then
      return 1
    fi
    printf '%s' "$_TIMEOUT_CMD_RESOLVED"
    return 0
  fi
  if command -v timeout >/dev/null 2>&1; then
    _TIMEOUT_CMD_RESOLVED="$(command -v timeout)"
    printf '%s' "$_TIMEOUT_CMD_RESOLVED"
    return 0
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    _TIMEOUT_CMD_RESOLVED="$(command -v gtimeout)"
    printf '%s' "$_TIMEOUT_CMD_RESOLVED"
    return 0
  fi
  _TIMEOUT_CMD_RESOLVED=none
  if [ "${_TIMEOUT_DEGRADE_WARNED:-false}" != true ]; then
    warn "No timeout/gtimeout on PATH — using background+poll+TERM/KILL fallback (never unwrapped)"
    _TIMEOUT_DEGRADE_WARNED=true
  fi
  return 1
}

# Run a command under timeout. Prefer GNU timeout/gtimeout; otherwise a
# fail-closed background+poll fallback (TERM then KILL). Never runs probes
# completely unwrapped. Returns 124 on timeout (GNU timeout convention).
# Uses --foreground when available so a timeout signal cannot kill an
# enclosing bash function whose stdout/stderr are redirected (GNU timeout's
# default separate process group does that in practice).
# Non-tty stdin is preserved for the fallback path (bash would otherwise
# redirect background-job stdin from /dev/null, breaking heredoc callers
# such as validate_mkv_ebml_bounds).
run_with_timeout() {
  local secs="$1"
  shift
  local tc bg waited=0 rc stdin_file=""
  # Call _timeout_cmd in this shell (not via command substitution) so its
  # cache / warn-once side effects (_TIMEOUT_CMD_RESOLVED, _TIMEOUT_DEGRADE_WARNED)
  # persist across invocations.
  if _timeout_cmd >/dev/null; then
    tc="$_TIMEOUT_CMD_RESOLVED"
    if [ -z "${_TIMEOUT_HAS_FOREGROUND:-}" ]; then
      if "$tc" --help 2>&1 | grep -q -- '--foreground'; then
        _TIMEOUT_HAS_FOREGROUND=1
      else
        _TIMEOUT_HAS_FOREGROUND=0
      fi
    fi
    if [ "$_TIMEOUT_HAS_FOREGROUND" = 1 ]; then
      # --kill-after: if COMMAND ignores SIGTERM (e.g. a shell waiting on a
      # child), escalate so we never hang the validation path indefinitely.
      "$tc" --foreground --kill-after=5 "$secs" "$@"
    else
      "$tc" "$secs" "$@"
    fi
    return $?
  fi
  # Preserve non-tty stdin for heredoc callers (EBML python). Use absolute
  # cat paths so restricted-PATH fallback tests (no timeout on PATH) still work.
  if [ ! -t 0 ]; then
    stdin_file="${TMPDIR:-/tmp}/.convert-rwt-stdin.$$.$RANDOM"
    if command -v cat >/dev/null 2>&1; then
      cat >"$stdin_file" || { rm -f "$stdin_file"; return 1; }
    elif [ -x /bin/cat ]; then
      /bin/cat >"$stdin_file" || { rm -f "$stdin_file"; return 1; }
    elif [ -x /usr/bin/cat ]; then
      /usr/bin/cat >"$stdin_file" || { rm -f "$stdin_file"; return 1; }
    else
      # No cat available — cannot safely preserve stdin; reject rather than hang unwrapped.
      return 1
    fi
  fi
  if [ -n "$stdin_file" ]; then
    "$@" <"$stdin_file" &
  else
    "$@" </dev/null &
  fi
  bg=$!
  while [ "$waited" -lt "$secs" ]; do
    if ! kill -0 "$bg" 2>/dev/null; then
      set +e
      wait "$bg"
      rc=$?
      set -e
      rm -f "$stdin_file"
      return "$rc"
    fi
    sleep 1
    waited=$((waited + 1))
  done
  kill -TERM "$bg" 2>/dev/null || true
  waited=0
  while [ "$waited" -lt 5 ]; do
    if ! kill -0 "$bg" 2>/dev/null; then
      wait "$bg" 2>/dev/null || true
      rm -f "$stdin_file"
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  kill -KILL "$bg" 2>/dev/null || true
  wait "$bg" 2>/dev/null || true
  rm -f "$stdin_file"
  return 124
}

# Size-scaled validation timeout (2026-07-26/27): VALIDATION_TIMEOUT_SECS=120
# was tuned for anime's typical 300-700MB episodes. Real movie/TV content
# can be multi-GB, and a genuinely healthy (not stalled) mkvalidator/ffprobe
# structural scan of a 2-5GB file was directly measured taking 10+ minutes
# over NFS -- a flat 120s ceiling was misclassifying good files as "possibly
# stalled" and retrying them forever. Finds the file(s) being validated from
# the wrapper's own arguments: an `-i FILE` pair if present (run_ffmpeg_
# validation's convention -- always exactly one input), else sums the sizes
# of every plain (non-flag) argument that currently exists as a file. That
# fallback deliberately sums rather than picking one: ffprobe/mkvmerge/
# mkvalidator's single-file calls naturally end up scaling on just the real
# source (a `-o `$tmp`` output target doesn't exist yet at call time, so it
# contributes nothing), while a multi-part `mkvmerge -o out --quiet part1 +
# part2 + part3` merge correctly scales on the combined size of every part
# instead of (as an earlier version of this fix did, a 3-way review caught
# it) only the last one -- reviewers found a large-part-then-small-part
# merge would otherwise get a near-base timeout despite reading/writing the
# full combined size. Falls back to the flat base timeout if no file
# argument is found or none exist yet (e.g. `--version` probes). Never
# shrinks below the base; capped so a genuinely stuck process still fails
# within a bounded time rather than hanging forever.
#
# Rate/cap raised again 2026-07-27 alongside the MKVALIDATOR_MAX_SIZE_BYTES
# increase to 10GiB: the 300s/GiB rate (chosen against a 2.59GiB data
# point at ~260s/GiB actual) turned out too optimistic once a real 20.15GiB
# file was directly measured at ~340s/GiB -- the per-GiB cost isn't flat,
# it worsens at larger sizes. 350s/GiB + a cap of 3620s (~60 min, exactly
# what a file at the new 10GiB mkvalidator ceiling needs at this rate)
# keeps real margin at every size up to that ceiling; files above it skip
# full mkvalidator entirely (see MKVALIDATOR_MAX_SIZE_BYTES) so never hit
# this cap in practice for that specific tool, though the same scaling
# still applies to ffprobe/mkvmerge/ffmpeg-validation calls on any file
# size.
_validation_timeout_for_args() {
  local base="${VALIDATION_TIMEOUT_SECS}" cap=3620 extra_per_gib=350
  local f="" prev="" a sz total=0 extra scaled
  for a in "$@"; do
    [ "$prev" = "-i" ] && f="$a"
    prev="$a"
  done
  if [ -n "$f" ]; then
    sz="$(stat -c%s -- "$f" 2>/dev/null || stat -f%z -- "$f" 2>/dev/null)" && [ -n "$sz" ] && total="$sz"
  else
    for a in "$@"; do
      case "$a" in
        -*) ;;
        *)
          [ -f "$a" ] || continue
          sz="$(stat -c%s -- "$a" 2>/dev/null || stat -f%z -- "$a" 2>/dev/null)" || continue
          [ -n "$sz" ] && total=$((total + sz))
          ;;
      esac
    done
  fi
  [ "$total" -gt 0 ] || { printf '%s' "$base"; return; }
  extra=$(( (total * extra_per_gib) / 1073741824 ))
  scaled=$(( base + extra ))
  [ "$scaled" -gt "$cap" ] && scaled="$cap"
  printf '%s' "$scaled"
}

# Separate, much more generous timeout curve for full-file stream-copy
# remux repair (attempt_source_mkv_structure_remux's ffmpeg fallback) --
# NOT the same curve as _validation_timeout_for_args, which is sized for
# short, bounded validation probes. A full -c copy of a multi-GB file is
# legitimately slow on a busy/throttled NFS link without being hung;
# Two independent reviewers (2026-07-29) flagged that reusing
# the validation cap (3620s) here requires ~14 MiB/s sustained for a 50GiB
# file just to avoid a false timeout -- easily missed on a real fleet
# member under load, which would wrongly flag a perfectly healthy source as
# corrupt after 3 retries. This curve assumes a much lower ~1.5 MiB/s floor
# and a 10-hour cap instead.
_remux_timeout_for_args() {
  local base=300 cap=36000 extra_per_gib=700
  local f="" prev="" a sz total=0 extra scaled
  for a in "$@"; do
    [ "$prev" = "-i" ] && f="$a"
    prev="$a"
  done
  if [ -n "$f" ]; then
    sz="$(stat -c%s -- "$f" 2>/dev/null || stat -f%z -- "$f" 2>/dev/null)" && [ -n "$sz" ] && total="$sz"
  fi
  [ "$total" -gt 0 ] || { printf '%s' "$base"; return; }
  extra=$(( (total * extra_per_gib) / 1073741824 ))
  scaled=$(( base + extra ))
  [ "$scaled" -gt "$cap" ] && scaled="$cap"
  printf '%s' "$scaled"
}

run_ffmpeg_remux() { _run_timeout_retry "$(_remux_timeout_for_args "$@")" "${FFMPEG_CMD[@]}" "$@"; }

# 3-way review (2026-07-27) independently caught the same real bug in the
# first draft: callers like validate_mkv_mkvalidator redirect this whole
# call's stdout/stderr to a shared file once (`run_mkvalidator ... 2>"$errf"`).
# If attempt 1 times out after writing some diagnostic output, that content
# stayed in $errf; a clean attempt 2 then appended nothing new, and the
# caller's post-hoc `grep ERR "$errf"` could still find attempt 1's stale
# output and misreport a successful retry as a failure. Fixed by isolating
# each attempt's stdout/stderr into its own fresh temp file and only
# replaying the FINAL attempt's (the one whose rc is actually returned)
# output to the caller's real stdout/stderr -- works uniformly whether the
# caller redirected to a file or captured via `$(...)`, without needing to
# touch every call site individually.
_run_timeout_retry() {
  local timeout_s="$1" attempt=0 rc out_tmp err_tmp
  shift
  out_tmp="$(mktemp)" || { run_with_timeout "$timeout_s" "$@"; return $?; }
  err_tmp="$(mktemp)" || {
    # Couldn't get a second isolated capture file -- fall back to a single
    # unretried attempt rather than risk the stale-output problem this
    # exists to prevent (and clean up the first mktemp so it isn't leaked).
    rm -f -- "$out_tmp"
    run_with_timeout "$timeout_s" "$@"
    return $?
  }
  while :; do
    run_with_timeout "$timeout_s" "$@" >"$out_tmp" 2>"$err_tmp"
    rc=$?
    if [ "$rc" -ne 124 ]; then
      cat -- "$out_tmp"
      cat -- "$err_tmp" >&2
      rm -f -- "$out_tmp" "$err_tmp"
      return "$rc"
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -gt "$VALIDATION_TIMEOUT_RETRIES" ]; then
      cat -- "$out_tmp"
      cat -- "$err_tmp" >&2
      rm -f -- "$out_tmp" "$err_tmp"
      return "$rc"
    fi
    : >"$out_tmp"
    : >"$err_tmp"
  done
}

# Validation-path wrappers: single-point timeout covers all call sites.
# Streaming remux uses run_tracked_encoder + MKVMERGE_CMD directly (Phase A),
# not run_mkvmerge — intentionally unbound by VALIDATION_TIMEOUT_SECS.
run_ffprobe() { _run_timeout_retry "$(_validation_timeout_for_args "$@")" "${FFPROBE_CMD[@]}" "$@"; }

run_mkvmerge() { _run_timeout_retry "$(_validation_timeout_for_args "$@")" "${MKVMERGE_CMD[@]}" "$@"; }

# Team review (2026-07-22): plain run_ffmpeg (below, unbound) is correct for
# a real multi-hour encode, but validate_mkv_decode_windows's short bounded
# decode-window probes were using that same unbound call -- a `-t 30`
# argument only bounds decoded OUTPUT duration, not wall-clock time, so a
# stalled NFS read during a validation probe could hang the whole machine
# indefinitely even though every other validation helper (ffprobe/mkvmerge/
# mkvalidator) is timeout-wrapped. Use this for short/bounded validation
# ffmpeg probes only -- never for a real encode.
run_ffmpeg_validation() { _run_timeout_retry "$(_validation_timeout_for_args "$@")" "${FFMPEG_CMD[@]}" "$@"; }

run_mkvalidator() { _run_timeout_retry "$(_validation_timeout_for_args "$@")" "${MKVALIDATOR_CMD[@]}" "$@"; }

run_mkvpropedit() { "${MKVPROPEDIT_CMD[@]}" "$@"; }
