#!/usr/bin/env bash
# ves-tracked-process.sh -- the orphan-hardening background-encoder
# primitive: run_tracked_encoder launches the real encode/remux subprocess
# in a way INT/TERM/ERR can terminate cleanly instead of orphaning it, plus
# the in-progress-flag field updates and kill_active_encoder cleanup. Pure
# move from the former monolithic script -- no logic changes.

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
  local heartbeat_flag="" heartbeat_pid=0
  [ -n "${RESUME_LAST_SOURCE:-}" ] && heartbeat_flag="$(in_progress_flag_path "$RESUME_LAST_SOURCE" 2>/dev/null)"
  if [ -n "$heartbeat_flag" ]; then
    ( while kill -0 "$ACTIVE_ENCODER_PID" 2>/dev/null; do
        sleep 300 2>/dev/null
        touch -- "$heartbeat_flag" 2>/dev/null || true
      done ) &
    heartbeat_pid=$!
    disown "$heartbeat_pid" 2>/dev/null || true
  fi

  wait "$ACTIVE_ENCODER_PID" || rc=$?
  [ "$heartbeat_pid" -gt 0 ] 2>/dev/null && kill "$heartbeat_pid" 2>/dev/null
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
