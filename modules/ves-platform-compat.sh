#!/usr/bin/env bash
# ves-platform-compat.sh -- shell/OS portability shims: shell-option
# save/restore helpers, path canonicalization, glob matching, and
# platform/package-manager detection. Pure move from the former
# monolithic script -- no logic changes.

init_shell_compat() {
  if [ -n "${ZSH_VERSION:-}" ]; then
    emulate -L bash 2>/dev/null || true
    setopt PIPE_FAIL 2>/dev/null || true
    setopt KSH_ARRAYS 2>/dev/null || true
    return 0
  fi
  if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    err "bash 4+ required (macOS: brew install bash; Linux/WSL: apt/dnf install bash)"
    exit 1
  fi
}

shell_name() {
  if [ -n "${ZSH_VERSION:-}" ]; then
    printf 'zsh %s' "$ZSH_VERSION"
  elif [ -n "${BASH_VERSION:-}" ]; then
    printf 'bash %s' "$BASH_VERSION"
  else
    printf 'sh'
  fi
}

shell_nullglob_on() {
  if [ -n "${ZSH_VERSION:-}" ]; then
    setopt NULL_GLOB 2>/dev/null || true
  else
    shopt -s nullglob
  fi
}

shell_nullglob_off() {
  if [ -n "${ZSH_VERSION:-}" ]; then
    unsetopt NULL_GLOB 2>/dev/null || true
  else
    shopt -u nullglob 2>/dev/null || true
  fi
}

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

detect_platform() {
  local uname_s
  uname_s="$(uname -s 2>/dev/null || echo unknown)"
  case "$uname_s" in
    Linux)
      if [ -r /proc/version ] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
        PLATFORM=wsl
      else
        PLATFORM=linux
      fi
      ;;
    Darwin) PLATFORM=macos ;;
    CYGWIN*|MINGW*|MSYS*) PLATFORM=windows ;;
    *) PLATFORM=unknown ;;
  esac
}

canonical_path() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$p" 2>/dev/null && return 0
  fi
  if [ "$PLATFORM" = linux ] || [ "$PLATFORM" = wsl ]; then
    readlink -f "$p" 2>/dev/null && return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))' "$p" 2>/dev/null && return 0
  fi
  printf '%s' "$p"
}

# Bash-glob match for directory basenames (A*, Al*, [A-C]*).
name_glob_matches() {
  local name="$1"
  local pattern="$2"
  if [ "$NAME_GLOB_CI" = true ]; then
    local lower_name lower_pat
    lower_name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    lower_pat="$(printf '%s' "$pattern" | tr '[:upper:]' '[:lower:]')"
    case "$lower_name" in
      $lower_pat) return 0 ;;
      *) return 1 ;;
    esac
  fi
  case "$name" in
    $pattern) return 0 ;;
    *) return 1 ;;
  esac
}

# If --path ends with an unexpanded glob (* ? [), split into parent + name-glob.
# Quote the path so the shell does not expand it first.
split_path_trailing_glob() {
  local path="$1"
  local base parent
  # A literal existing file always wins over the glob-metacharacter
  # heuristic below (found via a real production run, 2026-08-06): the
  # case pattern *[\*\?\[]* can't distinguish an actual unexpanded glob
  # from a real filename that just happens to contain literal [, ], *, or
  # ? -- e.g. a common release-group tag like "[tvu.org.ru]". Without this
  # check, `-p ".../Title.[tvu.org.ru].avi"` silently got reinterpreted as
  # "directory .../ + name-glob '*.[tvu.org.ru].avi'" and either matched
  # nothing (hard failure) or matched the wrong thing entirely -- neither
  # of which the caller asked for or would expect from a plain file path.
  if [ -f "$path" ]; then
    SEARCH_PATH="$path"
    return 0
  fi
  case "$path" in
    *[\*\?\[]*)
      base="$(basename "$path")"
      parent="$(dirname "$path")"
      case "$base" in
        *[\*\?\[]*)
          SEARCH_PATH="$parent"
          if [ -n "$NAME_GLOB" ] && [ "$NAME_GLOB" != "$base" ]; then
            warn "Overriding --name-glob '$NAME_GLOB' with path trailing glob '$base'"
          fi
          NAME_GLOB="$base"
          return 0
          ;;
      esac
      ;;
  esac
  SEARCH_PATH="$path"
}

platform_extra_paths() {
  local tool="$1"
  case "$PLATFORM" in
    macos)
      printf '%s\n' \
        "$HOME/.local/bin/$tool" \
        "/opt/homebrew/bin/$tool" \
        "/usr/local/bin/$tool" \
        "/Applications/HandBrake.app/Contents/MacOS/$tool"
      ;;
    windows)
      printf '%s\n' \
        "$HOME/.local/bin/$tool" \
        "/cygdrive/c/Program Files/HandBrake/$tool.exe" \
        "/cygdrive/c/Program Files (x86)/HandBrake/$tool.exe" \
        "/cygdrive/c/Program Files/ffmpeg/bin/$tool.exe"
      ;;
    linux|wsl)
      printf '%s\n' \
        "/usr/bin/$tool" \
        "/usr/local/bin/$tool" \
        "$HOME/.local/bin/$tool"
      ;;
    *)
      printf '%s\n' "$HOME/.local/bin/$tool" "/usr/bin/$tool" "/usr/local/bin/$tool"
      ;;
  esac
}

detect_package_manager() {
  PACKAGE_MANAGER=""
  case "$PLATFORM" in
    macos)
      if command -v brew >/dev/null 2>&1; then
        PACKAGE_MANAGER=brew
      fi
      ;;
    linux|wsl)
      # Prefer Homebrew on Linux when present (pre-built bottles for mkvalidator).
      if command -v brew >/dev/null 2>&1; then
        PACKAGE_MANAGER=brew
      elif command -v apt-get >/dev/null 2>&1; then
        PACKAGE_MANAGER=apt
      elif command -v dnf >/dev/null 2>&1; then
        PACKAGE_MANAGER=dnf
      elif command -v yum >/dev/null 2>&1; then
        PACKAGE_MANAGER=yum
      elif command -v pacman >/dev/null 2>&1; then
        PACKAGE_MANAGER=pacman
      elif command -v zypper >/dev/null 2>&1; then
        PACKAGE_MANAGER=zypper
      elif command -v apk >/dev/null 2>&1; then
        PACKAGE_MANAGER=apk
      fi
      ;;
    windows)
      if command -v choco >/dev/null 2>&1; then
        PACKAGE_MANAGER=choco
      elif command -v winget >/dev/null 2>&1; then
        PACKAGE_MANAGER=winget
      elif command -v scoop >/dev/null 2>&1; then
        PACKAGE_MANAGER=scoop
      fi
      ;;
  esac
}
