#!/usr/bin/env bash
# ves-cifs-mount.sh -- CIFS/SMB mount detection, credentials, and the
# ensure-mounted-with-0777-modes path, plus the job-root writability and
# sidecar-log-path resolution that runs very early in main() before any
# encode work starts. Pure move from the former monolithic script -- no
# logic changes.

# mktemp always creates its file at 0600, ignoring umask -- intentional on
# mktemp's part (closes a symlink-race window, same rationale used for the
# CIFS credentials file above), but every atomic `mktemp` + `mv -f over-the-
# final-path` pattern in this script inherits that 0600 via mv, silently
# leaving the real output (an .mkv, a cache file) far more restrictive than
# a normal `>`-created file would have been. This library is shared across
# a multi-machine, multi-user-account fleet over NFS/CIFS -- a umask-derived
# mode (typically 644) still locks a file to one UID on shares without a
# common identity mapping. Force the most permissive mode meaningful for a
# regular (non-executable) file, matching this project's own CIFS mount
# policy of file_mode=0777,dir_mode=0777 elsewhere.
# 2026-09-06 (user directive): 0777, not the previous 0666 -- the execute bit
# is a no-op on a data file, but on some NFS/SMB identity-map configs an
# owner-mismatched 0666 file still can't be rewritten or re-permissioned by
# the next fleet host, and the goal is ZERO permission-related hangs. STING's
# ves_perm_sweep.sh is the periodic backstop.
_restore_default_file_mode() {
  local f="$1"
  chmod 0777 "$f" 2>/dev/null || true
}

_job_path_slug() {
  local slug
  slug="$(printf '%s' "$JOB_ROOT" | sed 's|^/||; s|/|_|g' | tr -cd '[:alnum:]_.-')"
  [ -n "$slug" ] || slug="job"
  printf '%s' "$slug"
}

_path_on_cifs() {
  local p="$1"
  [ "$(findmnt -T "$p" -n -o FSTYPE 2>/dev/null || true)" = cifs ]
}

_cifs_mount_for_path() {
  findmnt -T "$1" -n -o TARGET 2>/dev/null || true
}

_mount_owner_uid() {
  if [ -n "${SUDO_USER:-}" ]; then
    id -u "$SUDO_USER" 2>/dev/null || id -u
  else
    id -u
  fi
}

_mount_owner_gid() {
  if [ -n "${SUDO_USER:-}" ]; then
    id -g "$SUDO_USER" 2>/dev/null || id -g
  else
    id -g
  fi
}

_sudo_mount() {
  if [ "$(id -u)" -eq 0 ]; then
    mount "$@"
  else
    sudo mount "$@"
  fi
}

_cifs_opts_have_0777() {
  local opts="$1"
  case "$opts" in
    *file_mode=${CIFS_MOUNT_FILE_MODE}*) ;;
    *) return 1 ;;
  esac
  case "$opts" in
    *dir_mode=${CIFS_MOUNT_DIR_MODE}*) ;;
    *) return 1 ;;
  esac
  return 0
}

_cifs_mount_writable() {
  local mp="$1"
  local probe="$mp/.convert-v4-mount-test-$$"
  touch "$probe" 2>/dev/null || return 1
  rm -f -- "$probe"
  return 0
}

_cifs_mount_point_empty() {
  local mp="$1"
  [ -d "$mp" ] || return 1
  [ -z "$(find "$mp" -mindepth 1 -maxdepth 1 2>/dev/null | head -1)" ]
}

_guess_mount_point_for_path() {
  local p="$1"
  if [ -n "${CONVERT_CIFS_MOUNT_DST:-}" ]; then
    printf '%s' "$CONVERT_CIFS_MOUNT_DST"
    return 0
  fi
  case "$p" in
    /mnt/*/*)
      printf '/mnt/%s' "$(echo "${p#/mnt/}" | cut -d/ -f1)"
      ;;
    /mnt/*)
      printf '%s' "$p"
      ;;
    *)
      printf ''
      ;;
  esac
}

_cifs_credentials_file() {
  local credf
  if [ -n "${CONVERT_CIFS_CREDENTIALS:-}" ] && [ -f "$CONVERT_CIFS_CREDENTIALS" ]; then
    printf '%s' "$CONVERT_CIFS_CREDENTIALS"
    return 0
  fi
  if [ -n "${CONVERT_SMB_USER:-}" ] && [ -n "${CONVERT_SMB_PASSWORD:-}" ]; then
    # mktemp respects the process umask -- a permissive umask (022/002)
    # briefly leaves the file world/group-readable before the later chmod
    # runs, during which another local process could read the plaintext
    # password. Force a restrictive umask so it's created 0600 atomically,
    # with no window at all.
    local old_umask
    old_umask="$(umask)"
    umask 077
    credf="$(mktemp)"
    umask "$old_umask"
    printf 'username=%s\npassword=%s\n' "$CONVERT_SMB_USER" "$CONVERT_SMB_PASSWORD" >"$credf"
    printf '%s' "$credf"
    return 0
  fi
  return 1
}

_cifs_base_mount_opts() {
  local uid gid
  uid="$(_mount_owner_uid)"
  gid="$(_mount_owner_gid)"
  printf 'rw,uid=%s,gid=%s,forceuid,forcegid,iocharset=utf8,file_mode=%s,dir_mode=%s,noperm,vers=3.0' \
    "$uid" "$gid" "$CIFS_MOUNT_FILE_MODE" "$CIFS_MOUNT_DIR_MODE"
}

_cifs_mount_fresh() {
  local src="$1"
  local dst="$2"
  local credf opts rc temp_cred=false

  [ -n "$src" ] || { err "CIFS mount source not set (CONVERT_CIFS_MOUNT_SRC)"; return 1; }
  [ -n "$dst" ] || { err "CIFS mount destination not set"; return 1; }

  if ! credf="$(_cifs_credentials_file)"; then
    err "SMB credentials required — set CONVERT_CIFS_CREDENTIALS or CONVERT_SMB_USER/CONVERT_SMB_PASSWORD"
    return 1
  fi
  [ "${CONVERT_CIFS_CREDENTIALS:-}" != "$credf" ] && temp_cred=true
  # `mount` can hang indefinitely against an offline/firewalled SMB host; if
  # the user interrupts (Ctrl-C) while it's hung, nothing after that point
  # normally runs, orphaning the plaintext credentials file in /tmp. These
  # traps cover that window specifically -- but `trap ... SIG` is process-
  # wide, not function-scoped, so setting it here would otherwise clobber
  # whatever handler main() (or a caller) already had registered for the
  # rest of the script's life. Save the prior handlers and restore them via
  # a RETURN trap, which fires on every return path out of this function
  # (including the early ones above) without needing to duplicate the
  # restore call at each one.
  local _saved_exit_trap _saved_int_trap _saved_term_trap
  _saved_exit_trap="$(trap -p EXIT)"
  _saved_int_trap="$(trap -p INT)"
  _saved_term_trap="$(trap -p TERM)"
  trap '
    trap - RETURN
    [ -n "$_saved_exit_trap" ] && eval "$_saved_exit_trap" || trap - EXIT
    [ -n "$_saved_int_trap" ] && eval "$_saved_int_trap" || trap - INT
    [ -n "$_saved_term_trap" ] && eval "$_saved_term_trap" || trap - TERM
  ' RETURN
  # Guard re-checks temp_cred at fire time (not registration time) -- must
  # never delete the user's own CONVERT_CIFS_CREDENTIALS file if that's what
  # $credf ended up pointing at instead of a generated temp file. INT/TERM
  # re-exit afterward to preserve the normal "Ctrl-C actually stops the
  # script" behavior (a custom trap otherwise suppresses that default).
  trap '[ "$temp_cred" = true ] && rm -f -- "$credf" 2>/dev/null' EXIT
  trap '[ "$temp_cred" = true ] && rm -f -- "$credf" 2>/dev/null; exit 130' INT TERM

  if [ "$(id -u)" -ne 0 ]; then
    sudo mkdir -p "$dst" 2>/dev/null || mkdir -p "$dst" 2>/dev/null || true
  else
    mkdir -p "$dst"
  fi

  opts="$(_cifs_base_mount_opts),credentials=$credf"
  log "Mounting CIFS $src -> $dst (file_mode=$CIFS_MOUNT_FILE_MODE dir_mode=$CIFS_MOUNT_DIR_MODE)"
  set +e
  _sudo_mount -t cifs "$src" "$dst" -o "$opts"
  rc=$?
  set -e
  [ "$temp_cred" = true ] && rm -f -- "$credf"
  if [ "$rc" -ne 0 ]; then
    warn "CIFS mount failed (rc=$rc) — trying vers=3.1.1"
    credf="$(_cifs_credentials_file)" || return 1
    temp_cred=false
    [ "${CONVERT_CIFS_CREDENTIALS:-}" != "$credf" ] && temp_cred=true
    opts="$(_cifs_base_mount_opts | sed 's/vers=3.0/vers=3.1.1/'),credentials=$credf"
    set +e
    _sudo_mount -t cifs "$src" "$dst" -o "$opts"
    rc=$?
    set -e
    [ "$temp_cred" = true ] && rm -f -- "$credf"
    if [ "$rc" -ne 0 ]; then
      err "CIFS mount failed — run with sudo or mount manually:"
      err "  sudo $0 --mount-share //SERVER/SHARE:/mnt/point -p /mnt/point/..."
      err "  Set CONVERT_CIFS_CREDENTIALS or CONVERT_SMB_USER/CONVERT_SMB_PASSWORD"
      return 1
    fi
  fi
  _cifs_mount_writable "$dst"
}

_cifs_remount_0777() {
  local mp="$1"
  local opts="${2:-}"
  local extra remount_opts rc

  extra="file_mode=${CIFS_MOUNT_FILE_MODE},dir_mode=${CIFS_MOUNT_DIR_MODE},noperm"
  case "$opts" in
    *forceuid*) ;;
    *) extra="${extra},uid=$(_mount_owner_uid),gid=$(_mount_owner_gid),forceuid,forcegid" ;;
  esac

  log "Remounting $mp with $extra"
  set +e
  _sudo_mount -o "remount,${extra}" "$mp"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    warn "CIFS remount failed (rc=$rc) — unmount and fresh mount may be required"
    return 1
  fi
  _cifs_mount_writable "$mp"
}

ensure_cifs_mount_for_path() {
  local path="$1"
  local mp src fstype opts cred_mp

  [ "$ENFORCE_CIFS_0777" = true ] || return 0
  [ "$PLATFORM" = macos ] && return 0

  if ! command -v mount.cifs >/dev/null 2>&1; then
    warn "cifs-utils not installed — skipping CIFS mount enforcement (dnf/apt install cifs-utils)"
    return 0
  fi

  mp="$(findmnt -T "$path" -n -o TARGET 2>/dev/null || true)"
  fstype="$(findmnt -T "$path" -n -o FSTYPE 2>/dev/null || true)"

  if [ "$fstype" = cifs ] && [ -n "$mp" ]; then
    opts="$(findmnt -T "$path" -n -o OPTIONS 2>/dev/null || true)"
    if _cifs_opts_have_0777 "$opts" && _cifs_mount_writable "$mp"; then
      log "CIFS mount OK: $mp (file_mode=$CIFS_MOUNT_FILE_MODE dir_mode=$CIFS_MOUNT_DIR_MODE)"
      return 0
    fi
    _cifs_remount_0777 "$mp" "$opts" || return 1
    log "CIFS mount remounted: $mp"
    return 0
  fi

  mp="$(_guess_mount_point_for_path "$path")"
  [ -n "$mp" ] || return 0

  if findmnt "$mp" -n -o FSTYPE 2>/dev/null | grep -qxF cifs; then
    opts="$(findmnt "$mp" -n -o OPTIONS 2>/dev/null || true)"
    if _cifs_opts_have_0777 "$opts" && _cifs_mount_writable "$mp"; then
      return 0
    fi
    _cifs_remount_0777 "$mp" "$opts" || return 1
    return 0
  fi

  if _cifs_mount_point_empty "$mp" || ! findmnt "$mp" >/dev/null 2>&1; then
    src="${CONVERT_CIFS_MOUNT_SRC:-}"
    if [ -z "$src" ] && [ -f /etc/fstab ]; then
      src="$(awk -v mnt="$mp" '$2==mnt && $3=="cifs" { print $1; exit }' /etc/fstab)" || src=""
    fi
    if [ -z "$src" ]; then
      warn "Share at $mp is not mounted — set CONVERT_CIFS_MOUNT_SRC or use --mount-share"
      return 0
    fi
    CONVERT_CIFS_MOUNT_DST="$mp"
    _cifs_mount_fresh "$src" "$mp" || return 1
    log "CIFS mounted: $src -> $mp (file_mode=$CIFS_MOUNT_FILE_MODE dir_mode=$CIFS_MOUNT_DIR_MODE)"
  fi
  return 0
}

_job_root_is_writable() {
  local probe="$JOB_ROOT/.convert-v4-write-test-$$"
  if [ ! -d "$JOB_ROOT" ]; then
    return 1
  fi
  if [ -f "$JOB_ROOT/convert-v4.log" ] && [ ! -w "$JOB_ROOT/convert-v4.log" ]; then
    return 1
  fi
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    if sudo -u "$SUDO_USER" touch "$probe" 2>/dev/null; then
      sudo -u "$SUDO_USER" rm -f -- "$probe"
      return 0
    fi
    return 1
  fi
  if touch "$probe" 2>/dev/null; then
    rm -f -- "$probe"
    return 0
  fi
  return 1
}

_runtime_home() {
  local home="$HOME"
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    # getent is glibc/Linux-only -- not present on macOS/BSD by default.
    if command -v getent >/dev/null 2>&1; then
      home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)" || home=""
    fi
    # eval on a variable derived from the environment is a code-injection
    # vector (SUDO_USER='x$(payload)' would execute the payload under eval).
    # Bash tilde expansion (quoted OR unquoted) does NOT substitute a
    # variable's value into the tilde-prefix position at all -- ~$VAR and
    # ~"$VAR" both stay a literal, unexpanded "~value" string for ANY
    # username, resolvable or not. That earlier "fix" was safe but silently
    # never worked. dscl (macOS) or python3's pwd module do the same
    # getpwnam-style lookup getent does, without eval and without relying on
    # tilde expansion doing something it was never going to do.
    if [ -z "$home" ] && [ "$PLATFORM" = macos ] && command -v dscl >/dev/null 2>&1; then
      home="$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')" || home=""
    fi
    if [ -z "$home" ] && command -v python3 >/dev/null 2>&1; then
      home="$(python3 -c 'import pwd,sys
try:
    print(pwd.getpwnam(sys.argv[1]).pw_dir)
except KeyError:
    pass' "$SUDO_USER" 2>/dev/null)" || home=""
    fi
    if [ -z "$home" ]; then
      if [ -d "/home/$SUDO_USER" ]; then
        home="/home/$SUDO_USER"
      elif [ -d "/Users/$SUDO_USER" ]; then
        home="/Users/$SUDO_USER"
      fi
    fi
  fi
  [ -n "$home" ] || home="$HOME"
  printf '%s' "$home"
}

_neutralize_symlink_sidecar_path() {
  local p="$1"
  if [ -L "$p" ]; then
    warn "Sidecar path is a symlink, not our own regular file — removing the link only (target untouched) before use: $p"
    rm -f -- "$p"
  fi
}

# Creates (or refreshes the mtime of) a zero-byte marker file at a
# predictable path, without ever opening that predictable path directly.
# `_neutralize_symlink_sidecar_path` followed later by `: >"$flag"` is a
# check-then-truncate race -- and unlike an append, `>` unconditionally
# truncates whatever it's pointed at first, so a symlink replanted in that
# (admittedly tight) window would zero out its target instantly, worse than
# the append case. mv/rename() replaces the destination directly, including
# a symlink, without ever following it.
_safe_touch_empty_flag() {
  local flag="$1" tmp rc=0
  tmp="$(mktemp "$(dirname "$flag")/.convert-flag-XXXXXX" 2>/dev/null)" || return 1
  mv -f -- "$tmp" "$flag" 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] && _restore_default_file_mode "$flag"
  return "$rc"
}

resolve_job_sidecar_paths() {
  local slug cache_base home

  if _job_root_is_writable; then
    JOB_ROOT_WRITABLE=true
    JOB_SIDECAR_DIR="$JOB_ROOT"
  else
    JOB_ROOT_WRITABLE=false
    slug="$(_job_path_slug)"
    home="$(_runtime_home)"
    cache_base="${CONVERT_LOG_DIR:-${XDG_CACHE_HOME:-$home/.cache}/convert-v4}"
    JOB_SIDECAR_DIR="$cache_base/jobs/$slug"
    if ! mkdir -p "$JOB_SIDECAR_DIR" 2>/dev/null; then
      JOB_SIDECAR_DIR="/tmp/convert-v4-$(id -un 2>/dev/null || echo user)-${slug}"
      mkdir -p "$JOB_SIDECAR_DIR" 2>/dev/null || JOB_SIDECAR_DIR="/tmp"
    fi
    warn "Job root not writable — log/resume files: $JOB_SIDECAR_DIR"
    warn "CIFS/SMB: mount with file_mode=0777,dir_mode=0777,noperm (see --mount-share / CONVERT_CIFS_MOUNT_SRC)"
    warn "NFS: use sudo when root_squash requires root for writes"
  fi

  MASTER_LOG_FILE="$JOB_SIDECAR_DIR/convert-v4.log"
  STATS_LOG_FILE="$MASTER_LOG_FILE"
  _neutralize_symlink_sidecar_path "$MASTER_LOG_FILE"
  if { exec {MASTER_LOG_FD}>>"$MASTER_LOG_FILE"; } 2>/dev/null; then
    chmod 0666 "$MASTER_LOG_FILE" 2>/dev/null || true
  else
    MASTER_LOG_FD=""
  fi
  echo "[convert] Log file: $MASTER_LOG_FILE (job_root_writable=$JOB_ROOT_WRITABLE)" >&2
}

mount_audit_for_path() {
  local p="$1" src fstype opts rec=()
  case "$PLATFORM" in
    macos)
      local line mnt=""
      # `awk '{print $NF}'` on df's output breaks the moment the mount point
      # itself contains a space (e.g. "/Volumes/Media Mount") -- $NF grabs
      # only the last word. The Capacity column ("NN%") never legitimately
      # appears inside a real path, so stripping through it with sed is a
      # robust way to keep the full mount point (spaces included) intact.
      mnt="$(df -P "$p" 2>/dev/null | tail -1 | sed -E 's/^.*[0-9]+% *//')" || mnt=""
      [ -n "$mnt" ] || mnt="$(df "$p" 2>/dev/null | tail -1 | awk '{print $NF}')" || mnt=""
      line="$(/sbin/mount | grep -F " on $mnt (" | head -1)" || line=""
      case "$line" in
        *"(nfs"*) [ "${line#*read-only}" != "$line" ] && warn "mount audit: $p is mounted READ-ONLY" ;;
        *"(smbfs"*) warn "mount audit: $p is SMB on macOS — NFS usually performs better for encode I/O" ;;
      esac
      return 0
      ;;
  esac
  command -v findmnt >/dev/null 2>&1 || return 0
  src="$(findmnt -no SOURCE --target "$p" 2>/dev/null)" || return 0
  fstype="$(findmnt -no FSTYPE --target "$p" 2>/dev/null)" || fstype=""
  opts="$(findmnt -no OPTIONS --target "$p" 2>/dev/null)" || opts=""
  case "$fstype" in
    nfs|nfs4)
      case ",$opts," in *,soft,*) rec+=("'soft' risks silent I/O errors on long encodes — use 'hard'");; esac
      case ",$opts," in *,nconnect=*,*) : ;; *) [ "$PLATFORM" != macos ] && rec+=("add 'nconnect=8' for parallel RPC streams");; esac
      case "$opts" in *rsize=1048576*) : ;; *) rec+=("raise 'rsize/wsize' to 1048576");; esac
      case ",$opts," in *,noatime,*) : ;; *) rec+=("add 'noatime'");; esac
      ;;
    cifs|smb3)
      case ",$opts," in *,soft,*) rec+=("'soft' CIFS risks silent write corruption on network hiccups — use 'hard' (or switch to NFS)");; esac
      case "$opts" in *vers=1*|*vers=2.0*) rec+=("SMB protocol too old — use vers=3.1.1");; esac
      case "$opts" in *rsize=4194304*|*rsize=1048576*) : ;; *) rec+=("raise 'rsize/wsize' (>=1MiB)");; esac
      ;;
    9p|drvfs) rec+=("path is on a WSL drvfs/9p mount — very slow for media trees; mount the share inside WSL (NFS/CIFS) instead");;
    *) return 0 ;;
  esac
  if [ "${#rec[@]}" -gt 0 ]; then
    warn "mount audit: $src ($fstype) on the library path could be tuned:"
    local r; for r in "${rec[@]}"; do warn "  - $r"; done
    warn "  (advisory only — remount with suggested options when convenient)"
  fi
}
