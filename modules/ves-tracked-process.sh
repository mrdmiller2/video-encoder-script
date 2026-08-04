#!/usr/bin/env bash
# ves-tracked-process.sh -- the orphan-hardening background-encoder
# primitive: run_tracked_encoder launches the real encode/remux subprocess
# in a way INT/TERM/ERR can terminate cleanly instead of orphaning it, plus
# the in-progress-flag field updates and kill_active_encoder cleanup.
# Originally a pure move from the former monolithic script; the heartbeat
# subshell's PID handling got a real bug fix on 2026-08-04 (team-reviewed)
# -- see run_tracked_encoder's own comment.

# Kills a run_tracked_encoder heartbeat subshell AND its currently-running
# `sleep 300` child. Two things make this harder than a single `kill`:
# (1) a background job in a non-interactive script (no `set -m`) shares the
# script's own process group rather than getting its own, so the subshell
# terminating does not take its foreground `sleep` child down with it --
# that sleep is simply orphaned (reparented) and keeps running for up to
# its own remaining 300s regardless; (2) the child PID must be captured
# BEFORE killing the parent, not after -- the kernel reparents an orphaned
# child to init/systemd essentially immediately once its parent exits, so
# a `pkill -P $hb_pid` issued after the parent is already dead finds
# nothing (confirmed via direct empirical testing, not assumption -- two
# earlier drafts of this fix each failed for one of these two reasons in a
# real interrupt test before this one was verified to actually work).
#
# Every command below is deliberately `|| true`-guarded even where a
# failure looks "impossible": this function runs from inside the
# SIGINT/SIGTERM trap handler (resume_on_signal -> kill_active_encoder),
# under this script's global `set -euo pipefail` -- a bare
# `x="$(pgrep ...)"` assignment propagates pgrep's exit status (nonzero
# when it simply finds no children, the common case), which would abort
# the ENTIRE trap handler right here under set -e, skipping every cleanup
# step after this call. Confirmed via direct empirical repro, not
# assumption (team review caught this in the first draft of this exact
# fix -- a genuinely worse failure mode than the leak being fixed). Also
# tolerates `pgrep` being entirely absent (not currently in this project's
# tool checklist) by falling back to the pre-fix bounded-leak behavior
# (kill the subshell only; its orphaned sleep self-terminates on its own
# next wake, same as before this fix existed) rather than crashing.
_kill_encoder_heartbeat() {
  local hb_pid="${1:-0}" hb_children=""
  [ "$hb_pid" -gt 0 ] 2>/dev/null || return 0
  if command -v pgrep >/dev/null 2>&1; then
    hb_children="$(pgrep -P "$hb_pid" 2>/dev/null)" || true
  fi
  kill "$hb_pid" 2>/dev/null || true
  if [ -n "$hb_children" ]; then
    # shellcheck disable=SC2086  # word-split intentional: pgrep -P can list multiple children
    kill $hb_children 2>/dev/null || true
  fi
  return 0
}

_tracked_command_fingerprint() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      env) continue ;;
      *=*) continue ;;
    esac
    basename "$arg"
    return 0
  done
  printf 'unknown'
}

update_in_progress_encoder_fields() {
  local src="${RESUME_LAST_SOURCE:-}"
  local flag flag_tmp
  [ "$DRY_RUN" = true ] && return 0
  [ -n "$src" ] || return 0
  [ "${ACTIVE_ENCODER_PID:-0}" -gt 0 ] 2>/dev/null || return 0
  flag="$(in_progress_flag_path "$src")"
  [ -f "$flag" ] || return 0
  [ ! -L "$flag" ] || {
    warn "Refusing to update encoder PID fields — in-progress flag is a symlink: $flag"
    return 1
  }
  flag_tmp="$(mktemp "${flag}.XXXXXX" 2>/dev/null)" || {
    warn "Could not create a temp file for encoder PID fields: $flag"
    return 1
  }
  awk '
    !/^encoder_pid=/ && !/^encoder_started_utc=/ && !/^encoder_fingerprint=/
  ' "$flag" >"$flag_tmp"
  {
    printf 'encoder_pid=%s\n' "$ACTIVE_ENCODER_PID"
    printf 'encoder_started_utc=%s\n' "$ACTIVE_ENCODER_STARTED_UTC"
    printf 'encoder_fingerprint=%s\n' "$ACTIVE_ENCODER_FINGERPRINT"
  } >>"$flag_tmp"
  mv -f -- "$flag_tmp" "$flag"
  _restore_default_file_mode "$flag"
}

# Runs a command while duplicating its stderr into a durable file, without
# disturbing its own inherited stderr passthrough (progress/-stats display,
# whatever the caller's own logging redirection already does). Added
# 2026-07-20 after the Angel Cop audio-truncation incident, where the only
# ffmpeg invocation that could have explained a silently-abandoned audio
# stream had its stderr go solely to the shared per-run MASTER_LOG_FILE,
# which a later re-scan run then overwrote before anyone looked -- this is
# the fix for that: give ffmpeg's own encode attempts a per-title,
# per-attempt log file that nothing else ever writes to or truncates.
_run_capturing_stderr() {
  local errfile="$1"
  shift
  # exec (not a plain call) is load-bearing: run_tracked_encoder captures
  # $! right after backgrounding this function, expecting that PID to be
  # the actual encoder process for later SIGTERM/SIGKILL (kill_active_encoder)
  # and orphan-reaper fingerprint matching. Without exec, $! would be this
  # wrapper's own bash process, not ffmpeg -- an interrupt would kill the
  # wrapper and leave ffmpeg running as an untracked orphan. exec replaces
  # this process image in place (same PID) once the process-substitution
  # redirect is wired up, so the tracked PID becomes ffmpeg itself. Found
  # in team review, 2026-07-20.
  exec "$@" 2> >(tee -a "$errfile" >&2)
}

run_tracked_encoder() {
  local label="$1"
  shift
  local rc=0
  ACTIVE_ENCODER_LABEL="$label"
  ACTIVE_ENCODER_FINGERPRINT="$(_tracked_command_fingerprint "$@")"
  ACTIVE_ENCODER_STARTED_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  "$@" &
  ACTIVE_ENCODER_PID=$!
  update_in_progress_encoder_fields || true

  # Heartbeat: junk_flag_is_stale() treats an in-progress flag as abandoned
  # once its mtime is >2h old for a DIFFERENT host's staleness check --
  # but update_in_progress_encoder_fields above only touches that mtime
  # ONCE, at encoder start. Real encodes on this fleet's slower machines
  # routinely run 3-7+ hours (seen directly this session), so without a
  # periodic touch, any other host scanning the same shared library after
  # the 2h mark would conclude this job was abandoned, reclaim the lock,
  # and start a second, dual-writing encode of the same title -- found in
  # team E2E review, 2026-07-20. Runs as a fully independent background
  # subshell (not folded into the wait below) so it can never change this
  # function's signal-handling/interrupt-responsiveness behavior.
  # Its PID is kept in the global ACTIVE_ENCODER_HEARTBEAT_PID (not just a
  # local) so kill_active_encoder -- called from the SIGINT/SIGTERM trap
  # handler, unwinding this function early -- can also kill it immediately;
  # without that, an interrupt mid-encode used to leave this subshell alive
  # for up to 300s after the parent script had already exited (found via
  # real-content regression testing, 2026-08-04).
  local heartbeat_flag=""
  ACTIVE_ENCODER_HEARTBEAT_PID=0
  [ -n "${RESUME_LAST_SOURCE:-}" ] && heartbeat_flag="$(in_progress_flag_path "$RESUME_LAST_SOURCE" 2>/dev/null)"
  if [ -n "$heartbeat_flag" ]; then
    ( while kill -0 "$ACTIVE_ENCODER_PID" 2>/dev/null; do
        sleep 300 2>/dev/null
        touch -- "$heartbeat_flag" 2>/dev/null || true
      done ) &
    ACTIVE_ENCODER_HEARTBEAT_PID=$!
    disown "$ACTIVE_ENCODER_HEARTBEAT_PID" 2>/dev/null || true
  fi

  wait "$ACTIVE_ENCODER_PID" || rc=$?
  _kill_encoder_heartbeat "$ACTIVE_ENCODER_HEARTBEAT_PID"
  ACTIVE_ENCODER_HEARTBEAT_PID=0
  ACTIVE_ENCODER_PID=0
  ACTIVE_ENCODER_LABEL=""
  ACTIVE_ENCODER_FINGERPRINT=""
  ACTIVE_ENCODER_STARTED_UTC=""
  return "$rc"
}

kill_active_encoder() {
  local pid="${ACTIVE_ENCODER_PID:-0}"
  local label="${ACTIVE_ENCODER_LABEL:-encoder}"
  local fifo_dir="${ACTIVE_ENCODER_FIFO_DIR:-}"
  local waited=0
  # Kill the heartbeat subshell (if any) up front, regardless of which exit
  # path below is taken -- it does not depend on the main encoder pid still
  # being alive, and every caller of kill_active_encoder wants it gone.
  _kill_encoder_heartbeat "${ACTIVE_ENCODER_HEARTBEAT_PID:-0}"
  ACTIVE_ENCODER_HEARTBEAT_PID=0
  [ "$pid" -gt 0 ] 2>/dev/null || {
    if [ -n "$fifo_dir" ]; then
      rm -rf -- "$fifo_dir" 2>/dev/null || true
      ACTIVE_ENCODER_FIFO_DIR=""
    fi
    return 0
  }
  kill -0 "$pid" 2>/dev/null || {
    ACTIVE_ENCODER_PID=0
    if [ -n "$fifo_dir" ]; then
      rm -rf -- "$fifo_dir" 2>/dev/null || true
      ACTIVE_ENCODER_FIFO_DIR=""
    fi
    return 0
  }
  warn "Stopping active $label process (pid=$pid)"
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$waited" -lt 50 ]; do
    kill -0 "$pid" 2>/dev/null || {
      wait "$pid" 2>/dev/null || true
      ACTIVE_ENCODER_PID=0
      if [ -n "$fifo_dir" ]; then
        rm -rf -- "$fifo_dir" 2>/dev/null || true
        ACTIVE_ENCODER_FIFO_DIR=""
      fi
      return 0
    }
    if process_is_zombie "$pid"; then
      wait "$pid" 2>/dev/null || true
      ACTIVE_ENCODER_PID=0
      if [ -n "$fifo_dir" ]; then
        rm -rf -- "$fifo_dir" 2>/dev/null || true
        ACTIVE_ENCODER_FIFO_DIR=""
      fi
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null && is_encoder_process "$pid"; then
    warn "Active $label process did not exit after TERM; sending KILL (pid=$pid)"
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  else
    warn "Active $label pid changed identity before KILL check; leaving pid=$pid untouched"
  fi
  ACTIVE_ENCODER_PID=0
  if [ -n "$fifo_dir" ]; then
    rm -rf -- "$fifo_dir" 2>/dev/null || true
    ACTIVE_ENCODER_FIFO_DIR=""
  fi
}
