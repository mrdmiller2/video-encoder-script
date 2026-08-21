#!/usr/bin/env bash
# ves-ramdisk.sh -- RAM disk (tmpfs) staging discovery/creation and the
# per-job start/teardown lifecycle wired into main()'s EXIT trap. Pure
# move from the former monolithic script -- no logic changes. Note:
# ramdisk_job_start installs `trap ramdisk_job_teardown EXIT`, COMPOSED
# with (not replacing) the ERR/INT/TERM traps main() sets up itself --
# a second raw `trap ... EXIT` anywhere else would silently clobber this.

_dir_free_bytes() {
  local d="$1"
  case "$PLATFORM" in
    macos) df -k "$d" 2>/dev/null | awk 'NR==2{print $4*1024}' ;;
    *)     df -k "$d" 2>/dev/null | awk 'NR==2{print $4*1024}' ;;
  esac
}

_is_tmpfs_dir() {
  local d="$1"
  [ -d "$d" ] || return 1
  case "$PLATFORM" in
    macos)
      # macOS has no tmpfs; a RAM disk is an hdiutil-attached ram:// image.
      # Checking only "is this a Disk Image" (APFS container/physical-store
      # BusProtocol) isn't enough -- a file-backed .dmg mounted from real
      # SSD storage reports the same way and would be misclassified as RAM
      # (caught in team review). Instead, scan `hdiutil info`'s own attached-
      # image list for the block whose system-entities mount our target dir,
      # and only trust it if that same block's image-path is genuinely
      # ram://, not a file path.
      local canon
      canon="$(cd "$d" 2>/dev/null && pwd -P)" || canon="$d"
      hdiutil info 2>/dev/null | awk -v target="$canon" '
        /^===/ { ramimg=0; next }
        /^image-path[ \t]*:/ { ramimg=($0 ~ /ram:\/\//) ? 1 : 0; next }
        /^\/dev\/disk/ {
          n=split($0, f, "\t")
          mp=f[n]
          gsub(/^[ \t]+|[ \t]+$/, "", mp)
          if (mp == target && ramimg) { found=1 }
        }
        END { exit !found }
      '
      ;;
    *)
      command -v findmnt >/dev/null 2>&1 || return 1
      [ "$(findmnt -no FSTYPE --target "$d" 2>/dev/null)" = "tmpfs" ]
      ;;
  esac
}

# Only paths worth probing -- not a filesystem-wide search.
_ramdisk_candidate_dirs() {
  case "$PLATFORM" in
    macos) printf '%s\n' "/Volumes/ConvertRAMDisk" ;;
    *)     printf '%s\n' "/tmp" "/dev/shm" "/mnt/ramdisk" ;;
  esac
}

_mem_available_bytes() {
  case "$PLATFORM" in
    macos)
      # macOS deliberately keeps "Pages free" near zero -- it favors using
      # spare RAM as reclaimable cache over leaving it truly idle, unlike
      # Linux which exposes a proper MemAvailable estimate. Using only
      # "free" here starved the ramdisk down to ~1.5GB on a 64GB machine
      # (Crystalight/MARLONJ, confirmed in production, 2026-08-06) --
      # CONVERT_RAMDISK_PCT was being applied to a number that basically
      # never reflects real headroom on this platform. "Inactive" and
      # "speculative" pages are both reclaimable on demand (the same
      # pages Activity Monitor folds into its own "Available" figure) --
      # counting them gives a realistic available-memory estimate instead
      # of one that's structurally wrong for this OS. Deliberately still
      # excludes "active" pages (genuinely in use).
      local pagesize free_pages inactive_pages speculative_pages
      pagesize="$(sysctl -n hw.pagesize 2>/dev/null)"; pagesize="${pagesize:-4096}"
      free_pages="$(vm_stat 2>/dev/null | awk '/Pages free/{gsub("\\.","",$3); print $3}')" || free_pages=""
      inactive_pages="$(vm_stat 2>/dev/null | awk '/Pages inactive/{gsub("\\.","",$3); print $3}')" || inactive_pages=""
      speculative_pages="$(vm_stat 2>/dev/null | awk '/Pages speculative/{gsub("\\.","",$3); print $3}')" || speculative_pages=""
      printf '%s' "$(( (${free_pages:-0} + ${inactive_pages:-0} + ${speculative_pages:-0}) * pagesize ))"
      ;;
    *)
      awk '/MemAvailable/{print $2*1024}' /proc/meminfo 2>/dev/null
      ;;
  esac
}

# Finds an already-mounted, RAM-backed directory with at least $1 bytes free.
# Returns its path on stdout, or nothing if none qualifies.
ramdisk_discover() {
  local need_bytes="$1" d free
  # CONVERT_RAMDISK_DIR is still required to actually BE RAM-backed (verified
  # via _is_tmpfs_dir, same as every other candidate) -- an override that
  # merely exists with free space would let a misconfiguration silently
  # redirect staging onto a normal disk (or worse, an NFS/CIFS path), which
  # a reviewer flagged as widening the symlink attack surface described
  # below. If it fails the check, fall through to normal discovery instead
  # of using it, rather than trusting it blindly.
  if [ -n "$CONVERT_RAMDISK_DIR" ] && [ -d "$CONVERT_RAMDISK_DIR" ] && _is_tmpfs_dir "$CONVERT_RAMDISK_DIR"; then
    free="$(_dir_free_bytes "$CONVERT_RAMDISK_DIR")" || free=""
    if [ "${free:-0}" -ge "$need_bytes" ]; then
      printf '%s' "$CONVERT_RAMDISK_DIR"
      return 0
    fi
    return 1
  fi
  while IFS= read -r d; do
    if [ ! -d "$d" ]; then
      continue
    fi
    if ! _is_tmpfs_dir "$d"; then
      continue
    fi
    free="$(_dir_free_bytes "$d")" || free=""
    if [ -n "$free" ] && [ "$free" -ge "$need_bytes" ]; then
      printf '%s' "$d"
      return 0
    fi
  done < <(_ramdisk_candidate_dirs)
  return 1
}

# Creates a new ramdisk, two-tier sized off currently-available memory (not
# total installed RAM -- leaves headroom for the encoder process's own
# footprint, which a real production crash proved can be several GB on its
# own for a demanding 4K/10-bit source -- see ves-config.sh's
# CONVERT_RAMDISK_TIER_THRESHOLD_GB comment for the full incident writeup).
# Only called when discovery finds nothing suitable already mounted.
ramdisk_create() {
  local need_bytes="$1" avail size_bytes size_mb path
  avail="$(_mem_available_bytes)" || avail=""
  if [ -z "$avail" ] || [ "$avail" -le 0 ]; then
    return 1
  fi
  local threshold_bytes=$(( CONVERT_RAMDISK_TIER_THRESHOLD_GB * 1024 * 1024 * 1024 ))
  local cap_small_bytes=$(( CONVERT_RAMDISK_CAP_SMALL_GB * 1024 * 1024 * 1024 ))
  if [ "$avail" -ge "$threshold_bytes" ]; then
    size_bytes=$(( avail * CONVERT_RAMDISK_PCT_LARGE / 100 ))
  else
    size_bytes="$cap_small_bytes"
    # Never claim more than is actually free, even under the flat cap --
    # a machine with less than CONVERT_RAMDISK_CAP_SMALL_GB free entirely
    # would otherwise get a ramdisk request guaranteed to fail below.
    [ "$size_bytes" -le "$avail" ] || size_bytes="$avail"
  fi
  if [ "$size_bytes" -lt "$need_bytes" ]; then
    return 1
  fi
  size_mb=$(( size_bytes / 1024 / 1024 ))

  case "$PLATFORM" in
    macos)
      path="/Volumes/ConvertRAMDisk"
      if [ -d "$path" ]; then
        return 1
      fi
      local sectors dev
      sectors=$(( size_mb * 2048 ))
      dev="$(hdiutil attach -nomount "ram://${sectors}" 2>/dev/null)" || return 1
      dev="$(printf '%s' "$dev" | awk '{print $1}')"
      if ! diskutil erasevolume APFS "ConvertRAMDisk" "$dev" >/dev/null 2>&1; then
        hdiutil detach "$dev" -force >/dev/null 2>&1 || true
        return 1
      fi
      printf '%s' "$path"
      ;;
    *)
      # Every Linux/WSL fleet machine already has a suitable tmpfs at /tmp
      # (verified 2026-07) so this path is a rarely-exercised fallback; it
      # requires root, and fails closed (falls back to direct-write) if not.
      path="/run/convert-ramdisk"
      if [ "$(id -u)" -ne 0 ]; then
        return 1
      fi
      mkdir -p "$path" 2>/dev/null || return 1
      mount -t tmpfs -o "size=${size_mb}m" tmpfs "$path" 2>/dev/null || return 1
      printf '%s' "$path"
      ;;
  esac
}

# One dedicated resource path per platform for the "we created this
# ourselves" case -- distinct from a discovered shared system tmpfs like
# /tmp, which is never ours to tear down.
_ramdisk_owned_path() {
  case "$PLATFORM" in
    macos) printf '/Volumes/ConvertRAMDisk' ;;
    *)     printf '/run/convert-ramdisk' ;;
  esac
}

# Deliberately stricter than _is_tmpfs_dir (used for general discovery of
# /tmp, /dev/shm, etc.): this specifically decides whether OUR dedicated
# path is genuinely mounted as its own resource before we unmount/eject it
# or treat a leftover as safe to bulk-clear. Two reviewers independently
# flagged the previous version: on Linux, `findmnt --target` reports the
# filesystem *containing* the path (e.g. /run is already tmpfs on Fedora),
# not whether the path itself is a separate mountpoint, so a plain leftover
# subdirectory could be misclassified as "mounted". On macOS, the old loose
# `mount | grep` fallback matched *any* volume mounted at that exact path
# name, which could eject something unrelated a user happened to mount
# there. Fixed: Linux now requires the path to be its own exact mountpoint;
# macOS relies solely on _is_tmpfs_dir's positive Virtual-Interface check,
# no permissive fallback.
_ramdisk_owned_mounted() {
  local path
  path="$(_ramdisk_owned_path)"
  if [ ! -d "$path" ]; then
    return 1
  fi
  case "$PLATFORM" in
    macos)
      _is_tmpfs_dir "$path" 2>/dev/null
      ;;
    *)
      if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q "$path" 2>/dev/null || return 1
      elif command -v findmnt >/dev/null 2>&1; then
        [ -n "$(findmnt -no FSTYPE --mountpoint "$path" 2>/dev/null)" ] || return 1
      else
        return 1
      fi
      _is_tmpfs_dir "$path" 2>/dev/null
      ;;
  esac
}

# Called once per script run (not per file) before the convert phase starts.
# Sets the job-wide RAMDISK_JOB_DIR (empty if ramdisk staging isn't usable
# this run) and RAMDISK_JOB_OWNED (whether this run created/owns the
# resource and must tear it down, vs. merely using a pre-existing shared
# system tmpfs it must leave alone). A leftover owned resource from a prior
# crash is treated as stale and cleared/recreated rather than reused as-is,
# since it could hold a partial file from whatever died mid-write.
#
# Every conditional below is written as an explicit if/then rather than a
# bare `[ cond ] && action` or unguarded `var="$(cmd)"` -- this script runs
# under `set -euo pipefail` (line 183), and a bare `[ cond ] && action` at
# the top level of a function "fails" (triggers errexit) whenever cond is
# false, since the whole line's exit status is then cond's non-zero status.
# Caught this exact bug via a real end-to-end test on the macOS machine
# before shipping -- the function exited silently with no error message the
# moment CONVERT_NO_RAMDISK was false, which is the common case.
ramdisk_job_start() {
  RAMDISK_JOB_DIR=""
  RAMDISK_JOB_OWNED=false
  RAMDISK_JOB_STAGE_DIR=""
  # Registered unconditionally (not just on the ramdisk-found success path
  # further down) -- ramdisk_job_teardown now also owns disc-extraction
  # scratch-file/symlink cleanup (see process_disk, 2026-07-31), which must
  # run on crash/interrupt regardless of whether THIS run has a ramdisk at
  # all. Harmless no-op for the ramdisk-specific half when RAMDISK_JOB_DIR
  # stays empty.
  trap ramdisk_job_teardown EXIT
  if [ "$CONVERT_NO_RAMDISK" = true ] || [ "$DRY_RUN" = true ]; then
    return 0
  fi

  local owned_path probe_need
  owned_path="$(_ramdisk_owned_path)"
  probe_need=$(( 64 * 1024 * 1024 ))  # just enough to confirm it's alive/usable

  if _ramdisk_owned_mounted; then
    log_err "Ramdisk staging: found an existing owned ramdisk at $owned_path (likely left over from an interrupted prior run) — clearing it"
    case "$PLATFORM" in
      macos)
        local dev
        dev="$(df "$owned_path" 2>/dev/null | awk 'NR==2{print $1}')" || dev=""
        if [ -n "$dev" ]; then
          diskutil eject "$dev" >/dev/null 2>&1 || true
        fi
        ;;
      *)
        if [ -n "$(ls -A "$owned_path" 2>/dev/null)" ]; then
          rm -rf "${owned_path:?}"/* 2>/dev/null || true
        fi
        ;;
    esac
  fi

  local dir owned=false
  dir="$(ramdisk_discover "$probe_need")" || dir=""
  if [ -z "$dir" ]; then
    dir="$(ramdisk_create "$probe_need")" || dir=""
    if [ -n "$dir" ]; then
      owned=true
    fi
  fi

  if [ -z "$dir" ]; then
    log_err "Ramdisk staging: no suitable RAM-backed target this run — every file will write directly to its destination"
    return 0
  fi

  # A predictable path directly in $dir (which, in the discovered case, is a
  # shared system location like /tmp) lets any other local user pre-place a
  # symlink at the exact name we're about to write to -- a reviewer flagged
  # this as a real symlink-attack vector against the hard source-safety
  # invariant. mktemp -d gives an unpredictable, exclusively-created name;
  # chmod 700 means even another legitimate user on the same shared /tmp
  # can't read or write into it even if they somehow guessed it. Every
  # per-file staged path is then constructed inside THIS private directory,
  # not directly in $dir.
  local stage_dir
  stage_dir="$(mktemp -d "${dir}/.convert-stage-XXXXXX" 2>/dev/null)" || stage_dir=""
  if [ -z "$stage_dir" ]; then
    log_err "Ramdisk staging: could not create a private staging directory under $dir — every file will write directly to its destination"
    return 0
  fi
  chmod 700 "$stage_dir" 2>/dev/null || true
  # Not actually reachable by reap_orphaned_encoders today (it only ever
  # scans under $SEARCH_PATH, never a ramdisk mount), but marked anyway for
  # defense-in-depth/consistency with every other staging-dir creation site.
  _orphan_write_stage_host_marker "$stage_dir"

  RAMDISK_JOB_DIR="$dir"
  RAMDISK_JOB_STAGE_DIR="$stage_dir"
  RAMDISK_JOB_OWNED="$owned"
  if [ "$owned" = true ]; then
    log_err "Ramdisk staging: created $dir for this run (owned — will be torn down when the run ends), staging in $stage_dir"
  else
    log_err "Ramdisk staging: using discovered $dir for this run, staging in private $stage_dir"
  fi
  return 0
}

# Trapped on EXIT (normal completion, _convert_on_err's exit, and
# resume_on_signal's exit 130 all funnel through the same EXIT trap) — only
# tears down a resource this run actually owns; a discovered shared system
# tmpfs (e.g. /tmp) is left mounted and untouched either way.
ramdisk_job_teardown() {
  # Composed into this same EXIT trap rather than a second `trap ... EXIT`
  # (which would silently clobber this one -- see resume_init_paths's
  # comment on this exact gotcha). Covers the crash/interrupt case; the
  # normal-path cleanup in process_disk runs this same cleanup itself right
  # after each disc job, so these are almost always already empty by the
  # time this runs.
  if [ -n "$DISC_EXTRACT_SYMLINK_PATH" ] && [ -L "$DISC_EXTRACT_SYMLINK_PATH" ]; then
    rm -f -- "$DISC_EXTRACT_SYMLINK_PATH" 2>/dev/null || true
  fi
  if [ -n "$DISC_EXTRACT_SCRATCH_FILE" ]; then
    rm -rf -- "$(dirname -- "$DISC_EXTRACT_SCRATCH_FILE")" 2>/dev/null || true
  fi
  if [ -n "${ACTIVE_FFMPEG_STAGE1_FILE:-}" ]; then
    rm -f -- "$ACTIVE_FFMPEG_STAGE1_FILE" 2>/dev/null || true
    ACTIVE_FFMPEG_STAGE1_FILE=""
  fi
  if [ -n "$RAMDISK_JOB_STAGE_DIR" ]; then
    rm -rf -- "$RAMDISK_JOB_STAGE_DIR" 2>/dev/null || true
  fi
  if [ -z "$RAMDISK_JOB_DIR" ]; then
    return 0
  fi
  if [ "$RAMDISK_JOB_OWNED" != true ]; then
    return 0
  fi
  case "$PLATFORM" in
    macos)
      local dev
      dev="$(df "$RAMDISK_JOB_DIR" 2>/dev/null | awk 'NR==2{print $1}')" || dev=""
      if [ -n "$dev" ]; then
        diskutil eject "$dev" >/dev/null 2>&1 || true
      fi
      ;;
    *)
      # Mirrors _sudo_mount: ramdisk_create mounts via `sudo mount` for
      # non-root users (every fleet worker account), so teardown needs the
      # same fallback or the owned tmpfs is silently never unmounted here.
      # -n (non-interactive) so this EXIT-trap cleanup can never block on a
      # password prompt with no TTY attached.
      if [ "$(id -u)" -eq 0 ]; then
        umount "$RAMDISK_JOB_DIR" 2>/dev/null || true
      else
        sudo -n umount "$RAMDISK_JOB_DIR" 2>/dev/null || true
      fi
      ;;
  esac
  return 0
}

# Defensive guarantee for a codec-fallback transition (AV1 attempt fails or
# is discarded, caller is about to try x265 in the same job) -- the RAM
# disk is reserved for the ACTIVE encoding attempt only, never a holding
# area for a discarded/superseded one. $RAMDISK_JOB_STAGE_DIR is a single
# directory shared across the whole job's lifetime (only torn down at job
# end via ramdisk_job_teardown, see above), so anything a prior codec
# attempt left behind there -- most plausibly a crashed encode's partial
# stage1 file that its own cleanup path didn't reach (an actual PRINCE
# production crash, 2026-08-20, root-caused a RAM-disk-exhaustion failure
# this way) -- would otherwise still be sitting there competing with the
# new attempt for the same limited space. Moves anything found to a local
# (non-ramdisk) holding directory rather than deleting it outright, in
# case it's ever worth a human glance for debugging a repeat crash --
# explicit user direction, 2026-08-20. Safe to call even when nothing
# needs moving (the common case, when the prior attempt's own cleanup
# already worked correctly).
ramdisk_sweep_stale_attempt_files() {
  [ -n "$RAMDISK_JOB_STAGE_DIR" ] && [ -d "$RAMDISK_JOB_STAGE_DIR" ] || return 0
  local f holding_dir moved=0
  holding_dir="${_CONVERT_V4_SCRIPT_DIR:-/tmp}/logs/ramdisk-holding"
  while IFS= read -r -d '' f; do
    mkdir -p "$holding_dir" 2>/dev/null
    if mv -f -- "$f" "$holding_dir/" 2>/dev/null; then
      moved=$((moved + 1))
    elif sleep 0.5 && mv -f -- "$f" "$holding_dir/" 2>/dev/null; then
      # Retry once after a brief pause -- covers a transient lock right
      # after a crash (the file a crashed process just wrote can still
      # be briefly held by the OS/an AV scanner touching it).
      moved=$((moved + 1))
    elif cp -f -- "$f" "$holding_dir/" 2>/dev/null; then
      # Never silently delete a file we couldn't preserve first (found
      # 2026-08-20: this exact rm-on-mv-failure path was destroying
      # crash stderr logs a live PRINCE root-cause investigation needed,
      # with zero warning). A plain copy survives even when an atomic
      # rename doesn't.
      moved=$((moved + 1))
      rm -f -- "$f" 2>/dev/null || true
    else
      warn "RAM disk: could not preserve leftover file from a prior codec attempt (move and copy both failed) -- it will be lost when the RAM disk is torn down: $f"
    fi
  done < <(find "$RAMDISK_JOB_STAGE_DIR" -mindepth 1 -type f -print0 2>/dev/null)
  if [ "$moved" -gt 0 ]; then
    warn "RAM disk: moved $moved leftover file(s) from a prior codec attempt to local disk ($holding_dir) before starting the next attempt — see that file's own diagnostic logs if this recurs"
  fi
}
