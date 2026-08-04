#!/usr/bin/env bash
# ves-staging.sh -- per-file local/ramdisk staging path resolution and the
# finalize-staged-output move-into-place step. Pure move from the former
# monolithic script -- no logic changes.

# Decides where ffmpeg should actually write during this one file's encode:
# a staged path on the job's already-resolved ramdisk (see ramdisk_job_start,
# called once per run, not per file) if the per-file pre-flight size
# estimate fits in whatever's currently free there, else the real
# destination unchanged (today's direct-write behavior). Prints the path
# ffmpeg should use; the caller compares it against $2 to know whether a
# finalize/move step is needed afterward.
# Creates a private, unpredictable, mode-0700 mktemp -d sibling of $dst's
# directory. Used as the fallback staging location whenever ramdisk staging
# isn't available/enabled/big-enough -- an external review round found that
# every encoder invocation writing straight to the final (predictable)
# output path was still symlink-raceable in that case: the earlier
# `[ -L "$out" ]` check a caller does is a one-time snapshot, and bake-off/
# VMAF-search/encode time between that check and the encoder actually
# opening the path is a real window (easily minutes) for another writer
# with access to the destination directory to swap it for a symlink.
# Prints the directory path, or nothing if it couldn't be created (e.g. the
# destination directory itself isn't writable) -- callers fall back to the
# raw destination path in that case, matching the previous behavior.
_local_stage_dir_for() {
  local dst="$1" dir
  dir="$(mktemp -d "$(dirname "$dst")/.convert-stage-XXXXXX" 2>/dev/null)" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  _orphan_write_stage_host_marker "$dir"
  ACTIVE_LOCAL_STAGE_DIR="$dir"
  printf '%s' "$dir"
}

resolve_encode_stage_path() {
  local src="$1" dst="$2"
  local need_bytes free

  if [ -n "$RAMDISK_JOB_STAGE_DIR" ]; then
    need_bytes="$(file_size_bytes "$src")"
    if [ "$need_bytes" -gt 0 ]; then
      need_bytes=$(( need_bytes + need_bytes * RAMDISK_SIZE_ESTIMATE_MARGIN_PCT / 100 ))
      # Free space is checked against the outer mount (RAMDISK_JOB_DIR), same
      # filesystem the private RAMDISK_JOB_STAGE_DIR lives on -- df on either
      # path reports the same number.
      free="$(_dir_free_bytes "$RAMDISK_JOB_DIR")" || free=""
      if [ -n "$free" ] && [ "$free" -ge "$need_bytes" ]; then
        printf '%s/%s.%s' "$RAMDISK_JOB_STAGE_DIR" "$$" "$(basename "$dst")"
        return 0
      fi
      log_err "Ramdisk staging: not enough free space in $RAMDISK_JOB_DIR for this file (need ~$(( need_bytes / 1024 / 1024 ))MB) — falling back to local private staging"
    fi
  fi

  local local_dir
  local_dir="$(_local_stage_dir_for "$dst")" || {
    # Fail CLOSED, not open: falling back to the final (predictable) path
    # directly would reintroduce the exact symlink-race window this whole
    # staging mechanism exists to close, on precisely the error path where
    # something is already going wrong. An external reviewer flagged the
    # previous fail-open behavior here as inconsistent with the hard
    # invariant ("never", not "never unless staging setup itself fails").
    # Callers treat an empty result as "cannot safely encode this title
    # right now" and skip it rather than proceed.
    warn "Could not create a private staging directory next to $dst — refusing to encode directly to the final path (would reopen the symlink-race window)"
    return 1
  }
  printf '%s/%s.%s' "$local_dir" "$$" "$(basename "$dst")"
}

# Moves a staged output into place on its real (possibly NFS) destination as
# one sequential transfer, restoring normal file permissions (mktemp-derived
# temp files -- and copies of them -- inherit 0600, same class of issue fixed
# in v5.0.17's optimize_mkv_for_streaming). No-op if nothing was staged.
#
# Two reviewers independently flagged the original version of this function:
# `mktemp "${final_dst}.stageXXXXXX"` creates a file, but then `cp` REOPENS
# that path by name to write into it -- a TOCTOU window where another local
# writer with access to the destination directory could swap that name for
# a symlink between the two steps, and `cp` would follow it. The fix mirrors
# the same private-directory approach used for staging: the copy happens
# inside a freshly mktemp -d'd, mode-700 sibling directory (unpredictable
# name, owner-only access), so there is nothing for another process to
# usefully race against. The final `mv -f` is a same-filesystem rename of a
# file that only ever lived inside that private directory.
# $staged's containing directory is either the job-scoped RAMDISK_JOB_STAGE_DIR
# (persists across every file in the run -- torn down once by
# ramdisk_job_teardown, must NOT be removed here) or a one-off per-file
# directory from _local_stage_dir_for (nothing else will ever clean it up,
# so this is the only chance). rmdir only succeeds on an empty directory,
# so this is a safe no-op in the job-scoped case even without the explicit
# check, but the check documents the real reason and avoids relying on that
# coincidence.
_cleanup_staged_file_dir() {
  local staged_dir
  staged_dir="$(dirname "$1")"
  if [ "$staged_dir" != "$RAMDISK_JOB_STAGE_DIR" ]; then
    rmdir "$staged_dir" 2>/dev/null || true
    # NOT `[ cond ] && action` -- as the function's own last statement, a
    # bare (unguarded) call site would inherit that test's false/1 exit
    # status as set -e sees the whole function fail, aborting the script.
    if [ "$staged_dir" = "${ACTIVE_LOCAL_STAGE_DIR:-}" ]; then
      ACTIVE_LOCAL_STAGE_DIR=""
    fi
  fi
}

finalize_staged_encode_output() {
  local staged="$1" final_dst="$2"
  if [ "$staged" = "$final_dst" ]; then
    return 0
  fi
  if [ ! -s "$staged" ]; then
    return 1
  fi

  local tmp_dir tmp_on_dst copy_ok=false
  tmp_dir="$(mktemp -d "$(dirname "$final_dst")/.convert-finalize-XXXXXX" 2>/dev/null)" || return 1
  chmod 700 "$tmp_dir" 2>/dev/null || true
  _orphan_write_stage_host_marker "$tmp_dir"
  tmp_on_dst="$tmp_dir/$(basename "$final_dst")"
  # Tracked globally so an INT/TERM or a set -e abort mid-copy still has
  # this private dir cleaned up (resume_on_signal / _convert_on_err), not
  # just the three explicit rm -rf's on this function's own return paths.
  ACTIVE_FINALIZE_DIR="$tmp_dir"

  if cp "$staged" "$tmp_on_dst" 2>/dev/null; then
    if [ "$(file_size_bytes "$tmp_on_dst")" -eq "$(file_size_bytes "$staged")" ]; then
      copy_ok=true
    fi
  fi

  if [ "$copy_ok" = true ]; then
    if mv -f -- "$tmp_on_dst" "$final_dst" 2>/dev/null; then
      _restore_default_file_mode "$final_dst"
      rm -f -- "$staged"
      _cleanup_staged_file_dir "$staged"
      rm -rf -- "$tmp_dir" 2>/dev/null
      ACTIVE_FINALIZE_DIR=""
      return 0
    fi
    warn "Ramdisk staging: mv into $final_dst failed — keeping staged copy at $staged for manual recovery"
    rm -rf -- "$tmp_dir" 2>/dev/null
    ACTIVE_FINALIZE_DIR=""
    return 1
  fi

  # Team review (2026-07-22): keep the staged file for manual recovery here,
  # the same as the mv-failure branch above -- this is reached whenever the
  # copy to the final NFS destination fails or comes out size-mismatched
  # (dest full, transient I/O error, permission glitch), which says nothing
  # about whether the STAGED file itself (a fully completed, already-
  # validated real encode, possibly hours of work) is good. Unconditionally
  # deleting it here was discarding good completed work on a transient
  # copy-side failure instead of the destination-side problem it actually
  # was.
  warn "Ramdisk staging: copy to $final_dst failed or size mismatch — keeping staged copy at $staged for manual recovery"
  rm -rf -- "$tmp_dir" 2>/dev/null
  ACTIVE_FINALIZE_DIR=""
  return 1
}
