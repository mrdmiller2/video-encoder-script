#!/usr/bin/env bash
# ves-shared-mutex.sh -- mkdir-based cross-process mutex (used to serialize
# access to shared state like the done-log). Pure move from the former
# monolithic script -- no logic changes.

# Short-hold, mkdir-based mutex for a shared NFS file's critical section --
# mkdir is atomic even across NFS clients with different OS/lock-manager
# implementations (this fleet spans Linux, WSL2, and macOS), so it protects
# genuinely fleet-shared files (the done-log, the mkv-structure cache) more
# reliably than flock across such a mixed fleet. Distinct from the per-title
# in-progress lockdir (place_in_progress_flag), which is held for an entire
# encode job.
# Team review (2026-07-24) found these shared files had no cross-host
# locking at all: NFS does not guarantee atomic appends across separate
# client machines the way a single local process's O_APPEND writes are,
# and a read-modify-write rewrite (mktemp + mv into place) is a classic
# lost-update race when two hosts do it concurrently.
#
# Reclaim policy (team review, 2026-07-25): the original version reclaimed
# after ~100 spins of `sleep 0.1` (~10s of *intended* spin time) unconditionally
# -- three independent reviewers flagged this as too
# short and too naive: `sleep 0.1` isn't guaranteed to actually take only
# 0.1s under system load, so the real elapsed time before reclaim could be
# far more or less than 10s, and a real NFS stall inside the critical section
# (a slow `printf` to the done-log, a slow `mv` of the structure cache) is
# entirely plausible on this fleet and well within that window -- reclaiming
# out from under a live holder reintroduces exactly the lost-update race this
# mutex exists to prevent. Fixed by checking the lockdir's actual wall-clock
# mtime (not a spin counter) before ever reclaiming, and only after a much
# longer, genuinely-implausible-for-a-live-holder threshold.
_shared_mutex_dir_age_secs() {
  local dir="$1" now mtime
  now="$(date +%s 2>/dev/null)" || return 1
  case "$PLATFORM" in
    macos) mtime="$(stat -f%m "$dir" 2>/dev/null)" ;;
    linux|wsl) mtime="$(stat -c%Y "$dir" 2>/dev/null)" ;;
    *)
      mtime="$(stat -c%Y "$dir" 2>/dev/null)" \
        || mtime="$(python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$dir" 2>/dev/null)"
      ;;
  esac
  [ -n "$mtime" ] && [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
  echo $(( now - mtime ))
}

_shared_mutex_acquire() {
  local lockdir="$1"
  local waited=0
  local stale_secs="${SHARED_MUTEX_STALE_SECS:-90}"
  while ! mkdir -- "$lockdir" 2>/dev/null; do
    waited=$((waited + 1))
    # Re-check real elapsed time (via mtime, not the spin counter) every ~2s
    # rather than on every 0.1s spin -- stat-ing a shared NFS directory on
    # every single poll would itself add needless NFS traffic.
    if [ "$((waited % 20))" -eq 0 ]; then
      local age
      age="$(_shared_mutex_dir_age_secs "$lockdir")" || age=0
      if [ "$age" -ge "$stale_secs" ]; then
        # Genuinely stale by wall-clock age, not just "we've been spinning
        # a while" -- reclaim rather than block a fleet run indefinitely on
        # a dead lock from a machine that's no longer running.
        #
        # rmdir-then-mkdir would be two separate syscalls -- two hosts can
        # both pass the staleness check and both attempt reclaim, and
        # whichever one's rmdir runs after the other's mkdir would silently
        # delete the winner's brand-new lock (the exact race
        # place_in_progress_flag's own reclaim comment already documents).
        # Reclaim via `mv` instead: rename() on a directory is a single
        # atomic syscall, so exactly one racing waiter can win the rename of
        # this exact lockdir -- the loser's mv simply fails and it loops
        # back to spinning instead of destroying the winner's lock. No `-T`:
        # that flag is a GNU extension and would break on macOS (Crystalight).
        local reclaim_name="${lockdir}.reclaim.$(hostname 2>/dev/null || echo unknown).$$.$RANDOM"
        if mv -- "$lockdir" "$reclaim_name" 2>/dev/null; then
          rm -rf -- "$reclaim_name" 2>/dev/null
        fi
      fi
    fi
    sleep 0.1
  done
  # Ownership token (team review, 2026-07-25): the reclaim logic above closes
  # the two-waiters-both-reclaim race, but a THIRD scenario remained open --
  # the ORIGINAL holder, still slowly finishing its critical section after
  # being timed out and reclaimed, would eventually call _shared_mutex_release
  # and blindly `rmdir` whatever lockdir is there BY THEN, which could now
  # belong to whichever waiter legitimately won the reclaim. Writing a unique
  # token at acquire time and having release refuse to remove a lockdir whose
  # token doesn't match closes this: a stale ex-holder's release becomes a
  # no-op instead of destroying the current legitimate holder's lock. Not a
  # perfect compare-and-delete (a narrow TOCTOU window remains between the
  # check and the rmdir), but a real ownership check is far stronger than
  # none at all for a lock with no such verification previously.
  local my_token="$(hostname 2>/dev/null || echo unknown).$$.$RANDOM.$(date +%s 2>/dev/null || echo 0)"
  printf '%s' "$my_token" > "${lockdir}/.owner" 2>/dev/null || true
  printf '%s' "$my_token"
  return 0
}

_shared_mutex_release() {
  local lockdir="$1"
  local my_token="${2:-}"
  if [ -n "$my_token" ]; then
    local current
    current="$(cat "${lockdir}/.owner" 2>/dev/null)" || current=""
    if [ "$current" != "$my_token" ]; then
      # This lock was reclaimed as stale while we were still working (we
      # took longer than stale_secs) -- someone else now legitimately owns
      # it. Walking away instead of rmdir-ing it is the entire point of the
      # token check above.
      return 0
    fi
  fi
  # rmdir only removes an EMPTY directory -- the .owner file written at
  # acquire time means a bare rmdir here would always fail silently (caught
  # by review before shipping), leaking every single successful release and
  # forcing every subsequent acquire to wait out the full stale-reclaim
  # window instead of getting a clean, immediate handoff. Remove the token
  # file first so the directory is actually empty when we rmdir it.
  rm -f -- "${lockdir}/.owner" 2>/dev/null || true
  rmdir -- "$lockdir" 2>/dev/null || true
}
