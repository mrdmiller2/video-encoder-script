#!/usr/bin/env bash
# convert-v4.0.26.sh — Organize movie folders, transcode TV/movies to AV1/x265 MKV.
# Version: 4.0.26
# Naming: SCRIPT_NAME must match VERSION (convert-v{VERSION}.sh).
#   On each bump: copy the prior script to a NEW filename; keep all older versions in the repo.
#
# Portable: Linux/WSL/Cygwin (bash 4+), macOS (auto re-exec under zsh — default Terminal shell).
# Tool paths: CONVERT_* env vars or --ffmpeg/--handbrake/etc. CLI overrides.
#   Processes largest files first. Master log: {--path}/convert-v4.log (never movie subfolders).
#   Optional per-shard logs during sharded scans; merged into master and removed at session end.
#   AV1 paths (svt + nvenc_av1_10bit): Opus 112 kbps, all audio tracks kept, dialog DRC boost.
#   x265 paths (x265 + nvenc_h265): AAC 128 kbps only. All subtitles/audio kept + labeled.
#   AV1 kept when output is not more than 20% larger than the original; else x265 fallback.
#   Existing .AV1.mkv over 20% vs source: sample-test x265; re-encode when sample is smaller.
#   Existing HEVC MKV is remux-copied to Title.x265.mkv (no re-encode).
# Movies: every loose video goes into Title/Title.ext (years parenthesized, e.g. Sakura 1992
#   -> Sakura (1992)/Sakura (1992).mkv). English libraries also use A–Z + 0 buckets.
# TV shows: S01E01 / EP01 / -01 patterns, or folders under Television/Anime — episodes stay put.
# Encoders: NVENC when NVIDIA GPUs are present (nvidia-smi or HandBrake NVENC probe);
#   Intel Quick Sync (qsv_h265) when HandBrake reports QSV and NVIDIA is not selected;
#   otherwise svt_av1_10bit + x265 (software).
#   Linux/WSL/Windows priority: NVIDIA > Intel QSV > AMD VCE/VCN > software.
#   Override NVIDIA: CONVERT_PREFER_INTEL_QSV=1 or CONVERT_PREFER_AMD_VCE=1.
#   macOS: VideoToolbox (vt_h265) only — no NVIDIA/QSV/AMD path.
#   WSL2 hybrid: auto-picks Windows HandBrakeCLI.exe (NVENC or QSV) + Linux ffmpeg/mkvtoolnix.
#   ./convert-v4.0.8.sh --path /mnt/BigMomma/Media/Movies/Chinese
#   ./convert-v4.0.8.sh -p /mnt/BigMomma/Media/Movies/English/D --dry-run
#   ./convert-v4.0.8.sh -p /path --organize-only
#   ./convert-v4.0.8.sh -p /path --convert-only
#   ./convert-v4.0.8.sh -p /mnt/Movies --shard-depth 1   # per top-level subdir find (default)
#   ./convert-v4.0.8.sh -p /mnt/Movies --no-shard          # monolithic find (large trees)
#   --dry-run inspects each file (name, codec, length, resolution) and logs to the master log
#   --skip-av1 / --skip-x265 skip sources already in those codecs (inspection still runs)
#   Resume: convert-v4.state / .queue / .shards in --path; use --no-resume for a fresh run
#   Restart: existing .AV1.mkv / .x265.mkv outputs are validated (mkvmerge + duration +
#     first/last 30s decode) before skip; incomplete/broken outputs are removed and re-encoded.
#
# Disks: .iso files and Blu-ray folders (BDMV) are HandBrake "disc" sources.
#   Auto-converts the dominant title when it is >40% longer than every other title;
#   otherwise skips with a log entry for manual processing.
#
# GPUs: RTX 5080 (index 0) — AV1 + HEVC. RTX A4500 (index 1) — HEVC only.
# Original files are never deleted.

# macOS: re-exec under zsh (Terminal default). System bash is 3.2 and lacks bash 4 features.
if [ -z "${CONVERT_V4_ZSH:-}" ]; then
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      if command -v zsh >/dev/null 2>&1; then
        CONVERT_V4_ZSH=1 exec zsh "$0" "$@"
      fi
      ;;
  esac
fi

set -euo pipefail

VERSION="4.0.26"
SCRIPT_NAME="convert-v${VERSION}.sh"
SEARCH_PATH="."
DRY_RUN=false
DO_ORGANIZE=true
DO_CONVERT=true
SKIP_AV1=false
SKIP_X265=false
SHARD_DEPTH=1
NO_SHARD=false
NO_RESUME=false
DISK_TITLE_DOMINANCE_PCT=40
SAMPLE_SECONDS=60
MKV_VALIDATE_WINDOW_SECONDS=30
SIZE_OVERSHOOT_PCT=5
AV1_MAX_OVERSHOOT_PCT=20
GPU_AV1=0
GPU_HEVC_PRIMARY=0
GPU_HEVC_FALLBACK=1
HAS_NVIDIA=false
HAS_INTEL_QSV=false
HAS_AMD_VCE=false
USE_NVIDIA_ENCODE=false
USE_QSV_ENCODE=false
USE_AMD_VCE_ENCODE=false
USE_VT_ENCODE=false
HAS_VIDEOTOOLBOX=false
NVDEC_AVAILABLE=false
QSV_DECODE_AVAILABLE=false
ACTIVE_ENCODE_MODE=software
NVIDIA_GPU_COUNT=0
PLATFORM=unknown
HAS_HW_DECODE=false
HW_DECODE_NAME=""
TOOL_FFMPEG="${CONVERT_FFMPEG:-}"
TOOL_FFPROBE="${CONVERT_FFPROBE:-}"
TOOL_HANDBRAKE="${CONVERT_HANDBRAKE:-}"
TOOL_MKVPROPEDIT="${CONVERT_MKVPROPEDIT:-}"
TOOL_MKVMERGE="${CONVERT_MKVMERGE:-}"

AV1_ENCODER=""
declare -A BAKEOFF_ENCODER_CHOICE=()
OPUS_BITRATE=112
AAC_BITRATE=128
# CQ scales differ between SVT-AV1 and NVEnc AV1 — use encoder-specific values.
SVT_AV1_CQ_MOVIE=26
NVENC_AV1_CQ_MOVIE=24
SVT_AV1_CQ_ANIME=35
NVENC_AV1_CQ_ANIME=30
NVENC_AV1_TUNE=hq
AUDIO_DRC=2.0
AUDIO_GAIN=1.0
JOB_ROOT=""
JOB_ROOT_WRITABLE=false
JOB_SIDECAR_DIR=""
MASTER_LOG_FILE=""
SHARD_LOG_FILE=""
SHARD_LOG_ROOT=""
SHARD_LOG_ACTIVE=false
STATS_LOG_FILE=""
STATS_OUTPUT_BYTES=0
STATS_SAVED_BYTES=0
STATS_PROCESSED=0
STATS_SKIPPED=0
STATS_INSPECTED=0
CONVERT_JOB_INDEX=0
CONVERT_JOB_TOTAL=0
CONVERT_JOB_OK=true
RESUME_ACTIVE=false
RESUME_LAST_SOURCE=""
RESUME_LAST_INDEX=0
RESUME_LAST_STATUS=""
RESUME_LAST_SHARD=""
RESUME_STATE_FILE=""
RESUME_QUEUE_FILE=""
RESUME_SHARDS_FILE=""

# Resolved tool commands (arrays — HandBrake may be a flatpak invocation)
FFMPEG_CMD=()
FFPROBE_CMD=()
HANDBRAKE_CMD=()
MKVPROPEDIT_CMD=()
MKVMERGE_CMD=()
HANDBRAKE_DISPLAY="HandBrakeCLI"
HANDBRAKE_USE_WIN_PATHS=false
HANDBRAKE_DROP_TO_USER=""
MEDIA_OWNER_USER=""
HAND_BRAKE_FLATPAK_IDS=(fr.handbrake.ghb com.handbrake.ghb)

TEXT_SEARCH_BACKEND=grep
TEXT_SEARCH_DISPLAY=grep

VIDEO_EXTS=(avi mp4 mkv ts)
SUB_EXTS=(srt sub idx ass ssa vtt sup)

Color_Off='\033[0m'
Green='\033[0;32m'
Yellow='\033[1;33m'
Red='\033[0;31m'
Bold='\033[1m'

usage() {
  cat <<EOF
Usage: $0 --path DIR [options]

Options:
  -p, --path DIR          Root directory to scan (required for non-interactive use)
  --dry-run               Show actions without moving/encoding/deleting outputs
  --skip-av1              Skip sources whose video codec is AV1 (inspection still runs)
  --skip-x265             Skip sources whose video codec is HEVC/x265 (inspection still runs)
  --organize-only         Only fix per-movie folder layout + subtitle names
  --convert-only          Skip organization; only transcode/remux
  --sample-seconds N      Encoder bake-off sample length (default: 60, from middle of file)
  --shard-depth N         Find media per subdirectory at depth N (default: 1; avoids huge finds)
  --no-shard              Single find across entire --path (old behavior)
  --no-resume             Ignore saved resume state and start the convert queue from scratch
  --prefer-intel-qsv      Prefer Intel Quick Sync over NVIDIA when both are available
  --prefer-amd-vce        Prefer AMD VCE/VCN over NVIDIA when both are available

Tool paths (when not in PATH):
  --ffmpeg PATH           ffmpeg binary (or set CONVERT_FFMPEG)
  --ffprobe PATH          ffprobe binary (or set CONVERT_FFPROBE)
  --handbrake PATH        HandBrakeCLI binary (or set CONVERT_HANDBRAKE)
  --mkvpropedit PATH      mkvpropedit binary (or set CONVERT_MKVPROPEDIT)
  --mkvmerge PATH         mkvmerge binary (or set CONVERT_MKVMERGE)

Portable: Linux/WSL/Cygwin (bash 4+), macOS (zsh — re-exec'd automatically). macOS hw-decode: videotoolbox.

Target format:
  MKV container with AV1 video (kept when ≤20% larger than source) or x265 fallback.
  AV1 outputs more than 20% larger than the source trigger x265 fallback (sample-tested on existing .AV1.mkv).
  Outputs: {Title}.AV1.mkv or {Title}.x265.mkv alongside originals (originals never deleted).
  Disks (.iso / BDMV): dominant title auto-selected; ambiguous discs are skipped and logged.
  -h, --help              Show this help

Encoder priority (Linux/WSL/Windows):
  1 AMD+NVIDIA GPU:  NVIDIA default; --prefer-amd-vce tries AMD VCE, else software
  2 AMD, no NVIDIA:  AMD VCE if available, else software
  3 Intel+NVIDIA:    NVIDIA default; --prefer-intel-qsv tries Quick Sync, else software
  4 Intel, no NVIDIA: Quick Sync if available, else software
  Chain: NVIDIA > Intel QSV > AMD VCE > software (when no override)
  CONVERT_FORCE_NVIDIA=1 | CONVERT_FORCE_INTEL_QSV=1 | CONVERT_FORCE_AMD_VCE=1

macOS (combination 5):
  VideoToolbox (vt_h265) when HandBrake reports it, else software

Examples:
  $0 --path /mnt/BigMomma/Media/Movies/Chinese
  $0 -p /mnt/BigMomma/Media/Movies/English/D --dry-run
EOF
}

strip_ansi() {
  printf '%s' "$1" | sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g'
}

init_text_search() {
  if command -v rg >/dev/null 2>&1; then
    TEXT_SEARCH_BACKEND=rg
    TEXT_SEARCH_DISPLAY=rg
  elif command -v grep >/dev/null 2>&1; then
    TEXT_SEARCH_BACKEND=grep
    TEXT_SEARCH_DISPLAY=grep
  else
    err "Missing: grep (or install ripgrep: rg)"
    return 1
  fi
}

# Case-insensitive quiet match; reads stdin or optional file path.
search_ci() {
  local pattern="$1"
  local file="${2:-}"
  if [ "$TEXT_SEARCH_BACKEND" = rg ]; then
    if [ -n "$file" ]; then
      rg -qi -e "$pattern" "$file"
    else
      rg -qi -e "$pattern"
    fi
  else
    if [ -n "$file" ]; then
      grep -qi "$pattern" "$file"
    else
      grep -qi "$pattern"
    fi
  fi
}

# Extended-regex case-insensitive quiet match; reads stdin or optional file path.
search_cie() {
  local pattern="$1"
  local file="${2:-}"
  if [ "$TEXT_SEARCH_BACKEND" = rg ]; then
    if [ -n "$file" ]; then
      rg -qi -e "$pattern" "$file"
    else
      rg -qi -e "$pattern"
    fi
  else
    if [ -n "$file" ]; then
      grep -qiE "$pattern" "$file"
    else
      grep -qiE "$pattern"
    fi
  fi
}

search_count_e() {
  local pattern="$1"
  local data="$2"
  local count=0
  if [ "$TEXT_SEARCH_BACKEND" = rg ]; then
    count="$(printf '%s' "$data" | rg -c -e "$pattern" 2>/dev/null)" || count=0
  else
    count="$(printf '%s' "$data" | grep -cE "$pattern" 2>/dev/null)" || count=0
  fi
  printf '%s' "${count:-0}"
}

master_log_write() {
  [ -n "$MASTER_LOG_FILE" ] || return 0
  printf '%s\n' "$@" >>"$MASTER_LOG_FILE" 2>/dev/null || true
}

shard_log_write() {
  [ "$SHARD_LOG_ACTIVE" = true ] && [ -n "$SHARD_LOG_FILE" ] || return 0
  printf '%s\n' "$@" >>"$SHARD_LOG_FILE" 2>/dev/null || true
}

log_to_master() {
  local ts msg
  ts="$(date -u '+%H:%M:%S')"
  msg="$(strip_ansi "$*")"
  master_log_write "[$ts] $msg"
  shard_log_write "[$ts] $msg"
}

log() { echo -e "${Green}[convert]${Color_Off} $*"; log_to_master "[convert] $*"; }
warn() { echo -e "${Yellow}[warn]${Color_Off} $*" >&2; log_to_master "[warn] $*"; }
err() { echo -e "${Red}[error]${Color_Off} $*" >&2; }

init_shell_compat() {
  if [ -n "${ZSH_VERSION:-}" ]; then
    emulate -L bash 2>/dev/null || true
    setopt PIPE_FAIL 2>/dev/null || true
    setopt KSH_ARRAYS 2>/dev/null || true
    return 0
  fi
  if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    err "bash 4+ required on Linux/WSL/Cygwin (macOS should auto-switch to zsh)"
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

platform_extra_paths() {
  local tool="$1"
  case "$PLATFORM" in
    macos)
      printf '%s\n' \
        "/opt/homebrew/bin/$tool" \
        "/usr/local/bin/$tool" \
        "/Applications/HandBrake.app/Contents/MacOS/$tool"
      ;;
    windows)
      printf '%s\n' \
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
      printf '%s\n' "/usr/bin/$tool" "/usr/local/bin/$tool"
      ;;
  esac
}

print_tool_install_help() {
  err "One or more required tools were not found."
  cat >&2 <<EOF

Install the tools or point to them explicitly:

  Environment variables:
    CONVERT_FFMPEG      path to ffmpeg
    CONVERT_FFPROBE     path to ffprobe
    CONVERT_HANDBRAKE   path to HandBrakeCLI (WSL: .exe OK; CONVERT_HANDBRAKE_WIN for Windows-only)
    CONVERT_MKVPROPEDIT path to mkvpropedit
    CONVERT_MKVMERGE    path to mkvmerge

  Command-line overrides:
    --ffmpeg PATH  --ffprobe PATH  --handbrake PATH
    --mkvpropedit PATH  --mkvmerge PATH

  Platform: $PLATFORM
    Linux/WSL:  sudo apt install ffmpeg mkvtoolnix handbrake-cli python3 grep
                or: sudo dnf install ffmpeg mkvtoolnix HandBrake-cli python3 grep
    macOS:      uses zsh automatically (default Terminal shell)
                brew install ffmpeg mkvtoolnix handbrake python3
    Cygwin:     install ffmpeg, mkvtoolnix, HandBrakeCLI, python3 via Cygwin/Windows installers

  HandBrake Flatpak (Linux): fr.handbrake.ghb
EOF
}

configure_sudo_wsl_handbrake() {
  HANDBRAKE_DROP_TO_USER=""
  MEDIA_OWNER_USER=""
  if [ "$(id -u)" -ne 0 ]; then
    return 0
  fi
  if [ -n "${SUDO_USER:-}" ]; then
    MEDIA_OWNER_USER="$SUDO_USER"
  fi
  if [ "$PLATFORM" = wsl ] && [ "$HANDBRAKE_USE_WIN_PATHS" = true ]; then
    if [ -n "${SUDO_USER:-}" ]; then
      HANDBRAKE_DROP_TO_USER="$SUDO_USER"
      log "sudo + writable mount: HandBrake runs as $SUDO_USER; ffmpeg/mkv/file writes stay root"
    else
      warn "root without SUDO_USER — Windows HandBrake .exe may fail; invoke via: sudo $0 ... (not sudo bash)"
    fi
  fi
}

maybe_chown_for_media_user() {
  local f
  [ -n "$MEDIA_OWNER_USER" ] || return 0
  for f in "$@"; do
    [ -n "$f" ] && [ -e "$f" ] && chown "$MEDIA_OWNER_USER:$MEDIA_OWNER_USER" "$f" 2>/dev/null || true
  done
}

_job_path_slug() {
  local slug
  slug="$(printf '%s' "$JOB_ROOT" | sed 's|^/||; s|/|_|g' | tr -cd '[:alnum:]_.-')"
  [ -n "$slug" ] || slug="job"
  printf '%s' "$slug"
}

_job_root_is_writable() {
  local probe="$JOB_ROOT/.convert-v4-write-test-$$"
  if [ ! -d "$JOB_ROOT" ]; then
    return 1
  fi
  if [ -f "$JOB_ROOT/convert-v4.log" ] && [ ! -w "$JOB_ROOT/convert-v4.log" ]; then
    return 1
  fi
  if touch "$probe" 2>/dev/null; then
    rm -f -- "$probe"
    return 0
  fi
  return 1
}

resolve_job_sidecar_paths() {
  local slug cache_base

  if _job_root_is_writable; then
    JOB_ROOT_WRITABLE=true
    JOB_SIDECAR_DIR="$JOB_ROOT"
  else
    JOB_ROOT_WRITABLE=false
    slug="$(_job_path_slug)"
    cache_base="${CONVERT_LOG_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/convert-v4}"
    JOB_SIDECAR_DIR="$cache_base/jobs/$slug"
    if ! mkdir -p "$JOB_SIDECAR_DIR" 2>/dev/null; then
      JOB_SIDECAR_DIR="/tmp/convert-v4-$(id -un 2>/dev/null || echo user)-${slug}"
      mkdir -p "$JOB_SIDECAR_DIR" 2>/dev/null || JOB_SIDECAR_DIR="/tmp"
    fi
    warn "Job root not writable — log/resume files: $JOB_SIDECAR_DIR"
    warn "Use sudo for organize/convert when the NFS mount requires root (e.g. root_squash)"
  fi

  MASTER_LOG_FILE="$JOB_SIDECAR_DIR/convert-v4.log"
  STATS_LOG_FILE="$MASTER_LOG_FILE"
}

resolve_configured_tool() {
  local configured="$1"
  local name="$2"
  local candidate

  if [ -z "$configured" ]; then
    return 1
  fi
  if [ -x "$configured" ]; then
    printf '%s' "$configured"
    return 0
  fi
  if [ "$PLATFORM" = wsl ] && [[ "$configured" == *.exe ]] && [ -f "$configured" ]; then
    printf '%s' "$configured"
    return 0
  fi
  err "Configured $name path is not executable: $configured"
  return 1
}

discover_binary() {
  local name="$1"
  local candidate

  if candidate="$(command -v "$name" 2>/dev/null)"; then
    printf '%s' "$candidate"
    return 0
  fi

  while IFS= read -r candidate; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && printf '%s' "$candidate" && return 0
  done < <(platform_extra_paths "$name")

  return 1
}

_handbrake_reports_nvenc() {
  local candidate="$1"
  [ -n "$candidate" ] || return 1
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$PLATFORM" = wsl ] && [[ "$candidate" == *.exe ]]; then
    sudo -u "$SUDO_USER" -H -- "$candidate" --help 2>&1 | search_cie 'nvenc: version [0-9]|nvenc_av1_10bit|nvenc_h265'
  else
    "$candidate" --help 2>&1 | search_cie 'nvenc: version [0-9]|nvenc_av1_10bit|nvenc_h265'
  fi
}

_handbrake_reports_qsv() {
  local candidate="$1"
  [ -n "$candidate" ] || return 1
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$PLATFORM" = wsl ] && [[ "$candidate" == *.exe ]]; then
    sudo -u "$SUDO_USER" -H -- "$candidate" --help 2>&1 | search_cie 'qsv_h265|qsv_h264|qsv_av1'
  else
    "$candidate" --help 2>&1 | search_cie 'qsv_h265|qsv_h264|qsv_av1'
  fi
}

_handbrake_reports_amd_vce() {
  local candidate="$1"
  [ -n "$candidate" ] || return 1
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$PLATFORM" = wsl ] && [[ "$candidate" == *.exe ]]; then
    sudo -u "$SUDO_USER" -H -- "$candidate" --help 2>&1 | search_cie 'vce_h265|vce_h264|vcn_h265|vcn_h264'
  else
    "$candidate" --help 2>&1 | search_cie 'vce_h265|vce_h264|vcn_h265|vcn_h264'
  fi
}

_wsl_windows_handbrake_candidates() {
  local candidate
  for candidate in \
    "${CONVERT_HANDBRAKE_WIN:-}" \
    "/mnt/c/Program Files/HandBrake/HandBrakeCLI.exe" \
    "/mnt/c/Program Files (x86)/HandBrake/HandBrakeCLI.exe"; do
    [ -n "$candidate" ] && [ -f "$candidate" ] && printf '%s\n' "$candidate"
  done
}

_set_handbrake_cmd() {
  local candidate="$1"
  HANDBRAKE_CMD=("$candidate")
  HANDBRAKE_DISPLAY="$candidate"
  HANDBRAKE_USE_WIN_PATHS=false
  if [ "$PLATFORM" = wsl ] && [[ "$candidate" == *.exe ]]; then
    HANDBRAKE_USE_WIN_PATHS=true
  fi
}

handbrake_path_for_exe() {
  local p="$1"
  if [ "$HANDBRAKE_USE_WIN_PATHS" = true ] && command -v wslpath >/dev/null 2>&1; then
    wslpath -w "$p" 2>/dev/null || printf '%s' "$p"
  else
    printf '%s' "$p"
  fi
}

_handbrake_translate_argv() {
  local -n _args="$1"
  local -a out=() arg mode="" part translated
  for arg in "${_args[@]}"; do
    case "$arg" in
      -i|-o)
        out+=("$arg")
        mode=path
        ;;
      --srt-file)
        out+=("$arg")
        mode=srt
        ;;
      *)
        if [ "$mode" = path ]; then
          out+=("$(handbrake_path_for_exe "$arg")")
          mode=""
        elif [ "$mode" = srt ]; then
          translated=""
          IFS=',' read -ra parts <<<"$arg"
          for part in "${parts[@]}"; do
            [ -n "$translated" ] && translated+=","
            translated+="$(handbrake_path_for_exe "$part")"
          done
          out+=("$translated")
          mode=""
        else
          out+=("$arg")
        fi
        ;;
    esac
  done
  _args=("${out[@]}")
}

discover_handbrake_cli() {
  local candidate id linux_hb="" win_hb="" win_nvenc="" win_qsv="" win_amd=""

  if candidate="$(resolve_configured_tool "$TOOL_HANDBRAKE" HandBrakeCLI)"; then
    _set_handbrake_cmd "$candidate"
    return 0
  fi

  if [ "$PLATFORM" = wsl ]; then
    if candidate="$(discover_binary HandBrakeCLI)"; then
      linux_hb="$candidate"
    fi
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      if _handbrake_reports_nvenc "$candidate"; then
        win_nvenc="$candidate"
        break
      fi
      if [ -z "$win_qsv" ] && _handbrake_reports_qsv "$candidate"; then
        win_qsv="$candidate"
      fi
      if [ -z "$win_amd" ] && _handbrake_reports_amd_vce "$candidate"; then
        win_amd="$candidate"
      fi
      [ -z "$win_hb" ] && win_hb="$candidate"
    done < <(_wsl_windows_handbrake_candidates)

    if [ -n "$win_nvenc" ]; then
      _set_handbrake_cmd "$win_nvenc"
      log "WSL hybrid: Windows HandBrake (NVENC); ffmpeg/mkv tools stay on Linux PATH"
      return 0
    fi
    if [ -n "$win_qsv" ]; then
      _set_handbrake_cmd "$win_qsv"
      log "WSL hybrid: Windows HandBrake (Intel Quick Sync); ffmpeg/mkv tools stay on Linux PATH"
      return 0
    fi
    if [ -n "$win_amd" ]; then
      _set_handbrake_cmd "$win_amd"
      log "WSL hybrid: Windows HandBrake (AMD VCE/VCN); ffmpeg/mkv tools stay on Linux PATH"
      return 0
    fi
    if [ -n "$linux_hb" ] && _handbrake_reports_nvenc "$linux_hb"; then
      _set_handbrake_cmd "$linux_hb"
      return 0
    fi
    if [ -n "$linux_hb" ] && _handbrake_reports_qsv "$linux_hb"; then
      _set_handbrake_cmd "$linux_hb"
      log "Linux HandBrake reports Intel Quick Sync"
      return 0
    fi
    if [ -n "$linux_hb" ] && _handbrake_reports_amd_vce "$linux_hb"; then
      _set_handbrake_cmd "$linux_hb"
      log "Linux HandBrake reports AMD VCE/VCN"
      return 0
    fi
    if [ -n "$linux_hb" ]; then
      _set_handbrake_cmd "$linux_hb"
      if [ -n "$win_hb" ]; then
        warn "Linux HandBrake has no NVENC/QSV/AMD VCE; install Windows HandBrake or set CONVERT_HANDBRAKE to the .exe path"
      fi
      return 0
    fi
    if [ -n "$win_hb" ]; then
      _set_handbrake_cmd "$win_hb"
      warn "Using Windows HandBrake without hardware probe — set CONVERT_FORCE_NVIDIA=1, CONVERT_FORCE_INTEL_QSV=1, or CONVERT_FORCE_AMD_VCE=1 if needed"
      return 0
    fi
  else
    if candidate="$(discover_binary HandBrakeCLI)"; then
      _set_handbrake_cmd "$candidate"
      return 0
    fi
  fi

  if [ "$PLATFORM" = linux ] || [ "$PLATFORM" = wsl ]; then
    if command -v flatpak >/dev/null 2>&1; then
      for id in "${HAND_BRAKE_FLATPAK_IDS[@]}"; do
        if flatpak info "$id" >/dev/null 2>&1; then
          HANDBRAKE_CMD=(flatpak run --command=HandBrakeCLI "$id")
          HANDBRAKE_DISPLAY="flatpak run --command=HandBrakeCLI $id"
          HANDBRAKE_USE_WIN_PATHS=false
          return 0
        fi
      done
    fi
  fi

  return 1
}

discover_tools() {
  local tool extra=()

  if tool="$(resolve_configured_tool "$TOOL_FFMPEG" ffmpeg)" || tool="$(discover_binary ffmpeg)"; then
    FFMPEG_CMD=("$tool")
  else
    print_tool_install_help
    err "Missing: ffmpeg"
    return 1
  fi

  if tool="$(resolve_configured_tool "$TOOL_FFPROBE" ffprobe)" || tool="$(discover_binary ffprobe)"; then
    FFPROBE_CMD=("$tool")
  else
    print_tool_install_help
    err "Missing: ffprobe"
    return 1
  fi

  if ! discover_handbrake_cli; then
    print_tool_install_help
    err "Missing: HandBrakeCLI"
    return 1
  fi

  if tool="$(resolve_configured_tool "$TOOL_MKVPROPEDIT" mkvpropedit)" || tool="$(discover_binary mkvpropedit)"; then
    MKVPROPEDIT_CMD=("$tool")
  else
    print_tool_install_help
    err "Missing: mkvpropedit"
    return 1
  fi

  if tool="$(resolve_configured_tool "$TOOL_MKVMERGE" mkvmerge)" || tool="$(discover_binary mkvmerge)"; then
    MKVMERGE_CMD=("$tool")
  else
    print_tool_install_help
    err "Missing: mkvmerge"
    return 1
  fi

  log "Platform: $PLATFORM | shell: $(shell_name) | ffmpeg=${FFMPEG_CMD[*]} | HandBrake=${HANDBRAKE_DISPLAY} | search=${TEXT_SEARCH_DISPLAY}"
  configure_sudo_wsl_handbrake
}

_handbrake_exec() {
  if [ -n "$HANDBRAKE_DROP_TO_USER" ]; then
    sudo -u "$HANDBRAKE_DROP_TO_USER" -H -- "$@"
  else
    "$@"
  fi
}

run_ffmpeg() { "${FFMPEG_CMD[@]}" "$@"; }
run_ffprobe() { "${FFPROBE_CMD[@]}" "$@"; }

run_handbrake() {
  local -a hb_args=("$@")
  if [ "$HANDBRAKE_USE_WIN_PATHS" = true ]; then
    _handbrake_translate_argv hb_args
  fi
  _handbrake_exec "${HANDBRAKE_CMD[@]}" "${hb_args[@]}"
}

# Run HandBrake with --json and stream encode progress to the terminal (one job at a time).
run_handbrake_with_progress() {
  local label="$1"
  shift
  local -a hb_cmd=("${HANDBRAKE_CMD[@]}" "$@")
  local rc=0

  if [ "$HANDBRAKE_USE_WIN_PATHS" = true ]; then
    _handbrake_translate_argv hb_cmd
    hb_cmd+=(--json)
  else
    hb_cmd+=(--json)
  fi

  _handbrake_exec "${hb_cmd[@]}" 2>&1 | awk -v label="$label" '
    /^Progress: / {
      buf = substr($0, index($0, "{"))
      while (buf !~ /\}/ && (getline line) > 0) {
        buf = buf line
      }
      if (buf ~ /"State": "WORKING"/) {
        pct = 0
        eta = ""
        if (match(buf, /"Progress": ?([0-9.]+)/, m)) {
          pct = m[1] * 100
        }
        if (match(buf, /"ETASeconds": ?([0-9]+)/, e) && e[1] > 0) {
          eta = sprintf(" ETA %dm %ds", int(e[1] / 60), int(e[1] % 60))
        }
        printf "\033[0;32m[convert]\033[0m %s: %.1f%%%s\r", label, pct, eta > "/dev/stderr"
        fflush("/dev/stderr")
      }
      if (buf ~ /"State": "WORKDONE"/) {
        err = 0
        if (match(buf, /"Error": ?([0-9]+)/, er)) {
          err = er[1] + 0
        }
        if (err != 0) {
          printf "\033[0;32m[convert]\033[0m %s: failed (error %d)\n", label, err > "/dev/stderr"
        } else {
          printf "\033[0;32m[convert]\033[0m %s: complete\n", label > "/dev/stderr"
        }
        fflush("/dev/stderr")
      }
      next
    }
    /Encode done!/ { next }
    /^\{[[:space:]]*$/ { skip = 1; next }
    skip && /^}/ { skip = 0; next }
    skip { next }
  '

  rc="${PIPESTATUS[0]}"
  return "$rc"
}

run_mkvpropedit() { "${MKVPROPEDIT_CMD[@]}" "$@"; }
run_mkvmerge() { "${MKVMERGE_CMD[@]}" "$@"; }

begin_convert_job() {
  local src="$1"
  local idx="$2"
  local total="$3"
  local name size shard
  name="$(basename "$src")"
  if is_disk_source "$src"; then
    size="$(human_size_bytes "$(disc_source_size_bytes "$src")")"
  else
    size="$(human_size_bytes "$(file_size_bytes "$src")")"
  fi
  shard="$(shard_for_path "$src")"
  RESUME_LAST_SOURCE="$src"
  RESUME_LAST_INDEX="$idx"
  RESUME_LAST_SHARD="$shard"
  CONVERT_JOB_TOTAL="$total"
  resume_persist_state "started"
  echo ""
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Job $idx of $total: $name ($size)"
  log "Shard: $shard"
  log "Source: $src"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

end_convert_job() {
  local src="$1"
  local idx="$2"
  local total="$3"
  local ok="${4:-true}"
  local status=completed
  [ "$ok" = false ] && status=failed
  RESUME_LAST_SOURCE="$src"
  RESUME_LAST_INDEX="$idx"
  resume_persist_state "$status"
  if [ "$ok" = true ]; then
    log "Job $idx of $total complete: $(basename "$src")"
  else
    warn "Job $idx of $total failed: $(basename "$src")"
  fi
  echo ""
}

detect_hw_environment() {
  HAS_NVIDIA=false
  HAS_INTEL_QSV=false
  HAS_AMD_VCE=false
  USE_NVIDIA_ENCODE=false
  USE_QSV_ENCODE=false
  USE_AMD_VCE_ENCODE=false
  USE_VT_ENCODE=false
  NVIDIA_GPU_COUNT=0
  NVDEC_AVAILABLE=false
  QSV_DECODE_AVAILABLE=false
  HAS_HW_DECODE=false
  HW_DECODE_NAME=""
  ACTIVE_ENCODE_MODE=software

  case "$PLATFORM" in
    macos)
      if _detect_videotoolbox_via_handbrake; then
        USE_VT_ENCODE=true
        ACTIVE_ENCODE_MODE=videotoolbox
        HAS_HW_DECODE=true
        HW_DECODE_NAME=videotoolbox
        log "Active encoder: VideoToolbox (vt_h265 for HEVC; AV1 via svt_av1_10bit)"
      else
        warn "VideoToolbox not available — software encoders (svt_av1_10bit, x265)"
      fi
      ;;
    linux|wsl|windows)
      if [ "${CONVERT_FORCE_NVIDIA:-}" = 1 ] || [ "${CONVERT_FORCE_NVIDIA:-}" = true ]; then
        HAS_NVIDIA=true
        NVIDIA_GPU_COUNT=1
        NVDEC_AVAILABLE=true
        log "NVIDIA encode capability forced (CONVERT_FORCE_NVIDIA)"
      else
        _detect_nvidia_via_smi || _detect_nvidia_via_handbrake || true
      fi

      if [ "${CONVERT_FORCE_INTEL_QSV:-}" = 1 ] || [ "${CONVERT_FORCE_INTEL_QSV:-}" = true ]; then
        HAS_INTEL_QSV=true
        QSV_DECODE_AVAILABLE=true
        log "Intel Quick Sync capability forced (CONVERT_FORCE_INTEL_QSV)"
      else
        _detect_intel_qsv_via_handbrake || true
      fi

      if [ "${CONVERT_FORCE_AMD_VCE:-}" = 1 ] || [ "${CONVERT_FORCE_AMD_VCE:-}" = true ]; then
        HAS_AMD_VCE=true
        log "AMD VCE/VCN capability forced (CONVERT_FORCE_AMD_VCE)"
      else
        _detect_amd_vce_via_handbrake || true
      fi

      _resolve_hw_encode_priority

      if [ "$USE_NVIDIA_ENCODE" = false ] && [ "$USE_QSV_ENCODE" = false ] \
        && [ "$USE_AMD_VCE_ENCODE" = false ]; then
        warn "No hardware encoder selected — using software (svt_av1_10bit, x265)"
        if [ "$HAS_NVIDIA" = false ] && [ "$HAS_INTEL_QSV" = false ] && [ "$HAS_AMD_VCE" = false ]; then
          warn "If HandBrake shows NVENC, QSV, or VCE, set CONVERT_FORCE_NVIDIA=1, CONVERT_FORCE_INTEL_QSV=1, or CONVERT_FORCE_AMD_VCE=1"
        fi
      fi
      ;;
    *)
      warn "Unknown platform — software encoders only"
      ;;
  esac
}

_apply_active_hw_decode() {
  HAS_HW_DECODE=false
  HW_DECODE_NAME=""
  if [ "$USE_NVIDIA_ENCODE" = true ] && [ "$NVDEC_AVAILABLE" = true ]; then
    HAS_HW_DECODE=true
    HW_DECODE_NAME=nvdec
  elif [ "$USE_QSV_ENCODE" = true ] && [ "$QSV_DECODE_AVAILABLE" = true ]; then
    HAS_HW_DECODE=true
    HW_DECODE_NAME=qsv
  fi
}

_resolve_hw_encode_priority() {
  USE_NVIDIA_ENCODE=false
  USE_QSV_ENCODE=false
  USE_AMD_VCE_ENCODE=false
  ACTIVE_ENCODE_MODE=software

  if [ "${CONVERT_FORCE_NVIDIA:-}" = 1 ] || [ "${CONVERT_FORCE_NVIDIA:-}" = true ]; then
    USE_NVIDIA_ENCODE=true
    ACTIVE_ENCODE_MODE=nvenc
    _apply_active_hw_decode
    log "Active encoder: NVIDIA NVENC (forced)"
    return 0
  fi

  if [ "${CONVERT_FORCE_INTEL_QSV:-}" = 1 ] || [ "${CONVERT_FORCE_INTEL_QSV:-}" = true ]; then
    if [ "$HAS_INTEL_QSV" = true ]; then
      USE_QSV_ENCODE=true
      ACTIVE_ENCODE_MODE=qsv
      _apply_active_hw_decode
      log "Active encoder: Intel Quick Sync (forced)"
    else
      warn "CONVERT_FORCE_INTEL_QSV set but Quick Sync not available — software encoders"
    fi
    return 0
  fi

  if [ "${CONVERT_FORCE_AMD_VCE:-}" = 1 ] || [ "${CONVERT_FORCE_AMD_VCE:-}" = true ]; then
    if [ "$HAS_AMD_VCE" = true ]; then
      USE_AMD_VCE_ENCODE=true
      ACTIVE_ENCODE_MODE=amd_vce
      _apply_active_hw_decode
      log "Active encoder: AMD VCE/VCN (forced)"
    else
      warn "CONVERT_FORCE_AMD_VCE set but AMD VCE/VCN not available — software encoders"
    fi
    return 0
  fi

  if [ "${CONVERT_PREFER_INTEL_QSV:-}" = 1 ] || [ "${CONVERT_PREFER_INTEL_QSV:-}" = true ]; then
    if [ "$HAS_INTEL_QSV" = true ]; then
      USE_QSV_ENCODE=true
      ACTIVE_ENCODE_MODE=qsv
      _apply_active_hw_decode
      if [ "$HAS_NVIDIA" = true ]; then
        log "Active encoder: Intel Quick Sync (CONVERT_PREFER_INTEL_QSV; NVIDIA skipped)"
      else
        log "Active encoder: Intel Quick Sync"
      fi
    else
      warn "CONVERT_PREFER_INTEL_QSV set but Quick Sync not available — software encoders (NVIDIA skipped)"
    fi
    return 0
  fi

  if [ "${CONVERT_PREFER_AMD_VCE:-}" = 1 ] || [ "${CONVERT_PREFER_AMD_VCE:-}" = true ]; then
    if [ "$HAS_AMD_VCE" = true ]; then
      USE_AMD_VCE_ENCODE=true
      ACTIVE_ENCODE_MODE=amd_vce
      _apply_active_hw_decode
      if [ "$HAS_NVIDIA" = true ]; then
        log "Active encoder: AMD VCE/VCN (CONVERT_PREFER_AMD_VCE; NVIDIA skipped)"
      else
        log "Active encoder: AMD VCE/VCN"
      fi
    else
      warn "CONVERT_PREFER_AMD_VCE set but AMD VCE/VCN not available — software encoders (NVIDIA skipped)"
    fi
    return 0
  fi

  if [ "$HAS_NVIDIA" = true ]; then
    USE_NVIDIA_ENCODE=true
    ACTIVE_ENCODE_MODE=nvenc
    _apply_active_hw_decode
    _log_alternate_hw_encoders "NVIDIA NVENC"
    return 0
  fi

  if [ "$HAS_INTEL_QSV" = true ]; then
    USE_QSV_ENCODE=true
    ACTIVE_ENCODE_MODE=qsv
    _apply_active_hw_decode
    log "Active encoder: Intel Quick Sync"
    return 0
  fi

  if [ "$HAS_AMD_VCE" = true ]; then
    USE_AMD_VCE_ENCODE=true
    ACTIVE_ENCODE_MODE=amd_vce
    _apply_active_hw_decode
    log "Active encoder: AMD VCE/VCN"
    return 0
  fi

  log "Active encoder: software (svt_av1_10bit, x265)"
}

_log_alternate_hw_encoders() {
  local primary="$1"
  local -a alt=()

  [ "$HAS_INTEL_QSV" = true ] && alt+=("Intel Quick Sync")
  [ "$HAS_AMD_VCE" = true ] && alt+=("AMD VCE/VCN")
  if [ "${#alt[@]}" -eq 0 ]; then
    log "Active encoder: $primary"
    return 0
  fi
  log "Active encoder: $primary (${alt[*]} also detected; use --prefer-intel-qsv or --prefer-amd-vce to override)"
}

# Resolve nvidia-smi on WSL/Cygwin where it may not be on PATH (Windows .exe still works).
_resolve_nvidia_smi() {
  local candidate

  if candidate="$(command -v nvidia-smi 2>/dev/null)"; then
    printf '%s' "$candidate"
    return 0
  fi

  for candidate in \
    /usr/lib/wsl/lib/nvidia-smi \
    /mnt/c/Windows/System32/nvidia-smi.exe \
    /cygdrive/c/Windows/System32/nvidia-smi.exe; do
    if [ -e "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

_detect_nvidia_via_smi() {
  local smi list

  if ! smi="$(_resolve_nvidia_smi)"; then
    return 1
  fi

  list="$("$smi" -L 2>/dev/null)" || list=""
  NVIDIA_GPU_COUNT="$(search_count_e '^GPU [0-9]+:' "$list")"
  if [ "${NVIDIA_GPU_COUNT:-0}" -gt 0 ]; then
    HAS_NVIDIA=true
    NVDEC_AVAILABLE=true
    log "Detected $NVIDIA_GPU_COUNT NVIDIA GPU(s) via $smi — NVENC available"
    return 0
  fi
  return 1
}

# WSL2 laptops often run Windows HandBrake with NVENC while Linux nvidia-smi is missing.
_detect_nvidia_via_handbrake() {
  local hb_help

  hb_help="$(run_handbrake --help 2>&1)" || return 1
  if ! search_cie 'nvenc: version [0-9]|nvenc_av1_10bit|nvenc_h265' <<<"$hb_help"; then
    return 1
  fi

  HAS_NVIDIA=true
  NVIDIA_GPU_COUNT=1
  if search_cie 'nvdec: is available|Use .nvdec. to enable' <<<"$hb_help"; then
    NVDEC_AVAILABLE=true
    log "HandBrake reports NVENC/NVDEC (no nvidia-smi)"
  else
    log "HandBrake reports NVENC (no nvidia-smi); hardware decode not confirmed"
  fi
  return 0
}

_detect_intel_qsv_via_handbrake() {
  local hb_help

  hb_help="$(run_handbrake --help 2>&1)" || return 1
  if ! search_cie 'qsv_h265|qsv_h264|qsv_av1' <<<"$hb_help"; then
    return 1
  fi

  HAS_INTEL_QSV=true
  if search_cie 'qsv: is available|Use .qsv. to enable' <<<"$hb_help"; then
    QSV_DECODE_AVAILABLE=true
    log "HandBrake reports Intel Quick Sync (encode + decode)"
  else
    log "HandBrake reports Intel Quick Sync encoders; hardware decode not confirmed"
  fi
  return 0
}

_detect_amd_vce_via_handbrake() {
  local hb_help

  hb_help="$(run_handbrake --help 2>&1)" || return 1
  if ! search_cie 'vce_h265|vce_h264|vcn_h265|vcn_h264' <<<"$hb_help"; then
    return 1
  fi

  HAS_AMD_VCE=true
  log "HandBrake reports AMD VCE/VCN (vce_h265); no hardware decode in HandBrake"
  return 0
}

_detect_videotoolbox_via_handbrake() {
  local hb_help

  hb_help="$(run_handbrake --help 2>&1)" || return 1
  if ! search_cie 'vt_h265|vt_h264' <<<"$hb_help"; then
    return 1
  fi

  HAS_VIDEOTOOLBOX=true
  if search_ci videotoolbox <<<"$hb_help"; then
    log "HandBrake reports VideoToolbox (vt_h265 encode + videotoolbox decode)"
  else
    log "HandBrake reports VideoToolbox encoders (vt_h265)"
  fi
  return 0
}

# NVENC AV1 tune=uhq needs NVENC 13+ and a new enough FFmpeg inside HandBrake.
nvenc_av1_encopts() {
  printf 'spatial-aq=1:temporal-aq=1:rc-lookahead=32:tune=%s' "$NVENC_AV1_TUNE"
}

detect_nvenc_av1_tune() {
  local tmp probe_out probe_log saved_cuda rc
  local -a hb_args=()

  NVENC_AV1_TUNE=hq
  if [ "$USE_NVIDIA_ENCODE" = false ]; then
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    log "NVENC AV1 tune probe skipped (--dry-run) — using tune=hq"
    return 0
  fi

  if [ "$PLATFORM" = wsl ] && [ "$HANDBRAKE_USE_WIN_PATHS" = true ]; then
    log "NVENC AV1 tune probe skipped (WSL Windows HandBrake) — using tune=hq"
    return 0
  fi

  if [ "${CONVERT_SKIP_NVENC_PROBE:-}" = 1 ] || [ "${CONVERT_SKIP_NVENC_PROBE:-}" = true ]; then
    log "NVENC AV1 tune probe skipped (CONVERT_SKIP_NVENC_PROBE) — using tune=hq"
    return 0
  fi

  log "NVENC AV1 tune probe: short test encode (${HANDBRAKE_DISPLAY})"

  tmp="$(mktemp -d)"
  probe_out="$tmp/probe.mkv"
  probe_log="$tmp/probe.log"

  if ! run_ffmpeg -y -nostdin -f lavfi -i testsrc=duration=1:size=640x360:rate=24 \
    -pix_fmt yuv420p "$tmp/in.mp4" >/dev/null 2>&1; then
    rm -rf "$tmp"
    warn "NVENC AV1 tune probe skipped (test clip failed) — using tune=hq"
    return 0
  fi

  saved_cuda="${CUDA_VISIBLE_DEVICES:-}"
  export CUDA_VISIBLE_DEVICES="${GPU_AV1:-0}"

  hb_args=(
    -i "$tmp/in.mp4" -o "$probe_out" -f mkv
    -e nvenc_av1_10bit -q 28 --encoder-preset slowest
    --encopts 'spatial-aq=1:temporal-aq=1:rc-lookahead=32:tune=uhq'
    --audio none
  )
  if [ "$HANDBRAKE_USE_WIN_PATHS" = true ]; then
    _handbrake_translate_argv hb_args
  fi

  set +e
  if command -v timeout >/dev/null 2>&1; then
    if [ -n "$HANDBRAKE_DROP_TO_USER" ]; then
      timeout 120 sudo -u "$HANDBRAKE_DROP_TO_USER" -H -- "${HANDBRAKE_CMD[@]}" "${hb_args[@]}" >"$probe_log" 2>&1
    else
      timeout 120 "${HANDBRAKE_CMD[@]}" "${hb_args[@]}" >"$probe_log" 2>&1
    fi
  elif [ -n "$HANDBRAKE_DROP_TO_USER" ]; then
    sudo -u "$HANDBRAKE_DROP_TO_USER" -H -- "${HANDBRAKE_CMD[@]}" "${hb_args[@]}" >"$probe_log" 2>&1
  else
    _handbrake_exec "${HANDBRAKE_CMD[@]}" "${hb_args[@]}" >"$probe_log" 2>&1
  fi
  rc=$?
  set -e

  if [ -n "$saved_cuda" ]; then
    export CUDA_VISIBLE_DEVICES="$saved_cuda"
  else
    unset CUDA_VISIBLE_DEVICES 2>/dev/null || CUDA_VISIBLE_DEVICES=
  fi

  if [ "$rc" -eq 124 ]; then
    warn "NVENC AV1 tune probe timed out — using tune=hq"
  elif [ "$rc" -eq 0 ] && [ -s "$probe_out" ] && \
    ! search_cie 'Unable to parse option value "uhq"|Error setting option tune|encavcodecInit: avcodec_open failed' "$probe_log"; then
    NVENC_AV1_TUNE=uhq
    log "NVENC AV1 tune probe: tune=uhq supported — using uhq"
  else
    if [ "$rc" -ne 0 ]; then
      warn "NVENC AV1 tune probe encode failed (rc=$rc) — using tune=hq"
      [ -s "$probe_log" ] && tail -3 "$probe_log" >&2 || true
    else
      log "NVENC AV1 tune probe: tune=uhq unavailable — using tune=hq"
    fi
  fi

  rm -rf "$tmp"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -p|--path) SEARCH_PATH="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --skip-av1) SKIP_AV1=true; shift ;;
    --skip-x265) SKIP_X265=true; shift ;;
    --organize-only) DO_ORGANIZE=true; DO_CONVERT=false; shift ;;
    --convert-only) DO_ORGANIZE=false; DO_CONVERT=true; shift ;;
    --sample-seconds) SAMPLE_SECONDS="$2"; shift 2 ;;
    --shard-depth) SHARD_DEPTH="$2"; shift 2 ;;
    --no-shard) NO_SHARD=true; shift ;;
    --no-resume) NO_RESUME=true; shift ;;
    --prefer-intel-qsv) CONVERT_PREFER_INTEL_QSV=1; shift ;;
    --prefer-amd-vce) CONVERT_PREFER_AMD_VCE=1; shift ;;
    --ffmpeg) TOOL_FFMPEG="$2"; shift 2 ;;
    --ffprobe) TOOL_FFPROBE="$2"; shift 2 ;;
    --handbrake) TOOL_HANDBRAKE="$2"; shift 2 ;;
    --mkvpropedit) TOOL_MKVPROPEDIT="$2"; shift 2 ;;
    --mkvmerge) TOOL_MKVMERGE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

detect_platform
init_shell_compat

SEARCH_PATH="$(canonical_path "$SEARCH_PATH")"
JOB_ROOT="$SEARCH_PATH"
if [ ! -d "$SEARCH_PATH" ]; then
  err "Path not found: $SEARCH_PATH"
  exit 1
fi

discover_tools || exit 1
init_text_search || exit 1

resolve_job_sidecar_paths

assert_script_name_matches_version() {
  local base
  base="$(basename "$0")"
  if [ "$base" != "$SCRIPT_NAME" ]; then
    err "Version $VERSION requires script filename $SCRIPT_NAME (found: $base)"
    err "Create $SCRIPT_NAME as a new file when bumping VERSION; do not overwrite prior versions."
    exit 1
  fi
}

is_video_file() {
  local f="$1" ext
  ext="$(to_lower "${f##*.}")"
  local e
  for e in "${VIDEO_EXTS[@]}"; do
    [ "$ext" = "$e" ] && return 0
  done
  return 1
}

is_subtitle_file() {
  local f="$1" ext
  ext="$(to_lower "${f##*.}")"
  local e
  for e in "${SUB_EXTS[@]}"; do
    [ "$ext" = "$e" ] && return 0
  done
  return 1
}

is_derived_output() {
  local base="${1##*/}"
  [[ "$base" =~ \.(AV1|av1|x265|X265)\.mkv$ ]] && return 0
  [[ "$base" =~ -av1\.mkv$ ]] && return 0
  return 1
}

is_iso_file() {
  [ "$(to_lower "${1##*.}")" = "iso" ]
}

is_bluray_root() {
  [ -d "$1/BDMV" ]
}

is_disk_source() {
  is_iso_file "$1" || is_bluray_root "$1"
}

# Directory holding sidecar subtitles and output MKVs for a source.
media_content_dir() {
  local src="$1"
  if is_bluray_root "$src"; then
    printf '%s' "$src"
  else
    dirname "$src"
  fi
}

# English-scale libraries bucket movies under single-letter dirs (A–Z) and 0 (digit-led).
uses_letter_bucket_library() {
  local p="$1"
  case "$p" in
    */English|*/English/*|*/english|*/english/*)
      return 0
      ;;
  esac
  return 1
}

is_numeric_shelf_dir() {
  [ "$(basename "$1")" = "0" ]
}

is_letter_shelf_dir() {
  local name
  name="$(basename "$1")"
  [[ "$name" =~ ^[A-Za-z]$ ]]
}

is_shelf_dir() {
  is_numeric_shelf_dir "$1" || is_letter_shelf_dir "$1"
}

# Shelf 0: titles whose first significant character is a digit (007, 9 Heads…, $50K…).
title_for_numeric_shelf() {
  local title="$1"
  title="${title#"${title%%[![:space:]]*}"}"
  [[ "$title" =~ ^[0-9] ]] && return 0
  [[ "$title" =~ ^[^[:alnum:]]*[0-9] ]] && return 0
  return 1
}

# First letter for A–Z shelf placement; leading articles "The" and "A" are ignored.
# (Organize still folders any loose file already sitting in a shelf, regardless of letter.)
title_first_letter() {
  local title="$1" c
  title="${title#"${title%%[![:space:]]*}"}"
  title="$(printf '%s' "$title" | sed -E \
    's/^[Tt][Hh][Ee][[:space:]]+//; s/^[Aa][[:space:]]+//')"
  c="$(printf '%s' "$title" | sed 's/^[^[:alpha:]]*//' | cut -c1)"
  [ -n "$c" ] || return 0
  printf '%s' "$c" | tr '[:lower:]' '[:upper:]'
}

title_belongs_in_shelf() {
  local title="$1"
  local shelf="$2"
  shelf="$(printf '%s' "$shelf" | tr '[:lower:]' '[:upper:]')"
  if [ "$shelf" = "0" ]; then
    title_for_numeric_shelf "$title"
    return $?
  fi
  if [[ "$shelf" =~ ^[A-Z]$ ]]; then
    [ "$(title_first_letter "$title")" = "$shelf" ]
    return $?
  fi
  return 1
}

movie_title_from_file() {
  local f="$1"
  local cooked="${f##*/}"
  printf '%s' "${cooked%.*}"
}

# Organize layout: parenthesize trailing release year (Sakura 1992 -> Sakura (1992)).
canonical_organize_title() {
  local title="$1"
  printf '%s' "$title" | sed -E \
    's/^[[:space:]]+//; s/[[:space:]]+$//;
     s/^(.+)[[:space:]]+\(([0-9]{4})\)$/\1 (\2)/;
     t same;
     s/^(.+)[[:space:]]+([0-9]{4})$/\1 (\2)/;
     :same'
}

is_movie_language_dir() {
  local dir="$1" name
  name="$(basename "$dir")"
  is_shelf_dir "$dir" && return 1
  case "$name" in
    Japanese|Chinese|English|Korean|French|German|Spanish|Italian|Cantonese|Mandarin|Hindi|Thai|Vietnamese|Russian|Portuguese|Polish|Dutch|Swedish|Norwegian|Danish|Finnish|Greek|Turkish|Arabic|Hebrew|Indonesian|Malay|Filipino|Tagalog|Other|Misc)
      return 0
      ;;
  esac
  return 1
}

# Parent directory where a loose movie file should be foldered.
is_movie_organize_parent() {
  local parent="$1"
  if is_shelf_dir "$parent"; then
    uses_letter_bucket_library "$parent" && return 0
    return 1
  fi
  is_movie_language_dir "$parent" && return 0
  [ "$parent" = "$SEARCH_PATH" ] && return 0
  return 1
}

subtitle_matches_organize_title() {
  local sub="$1"
  local raw_title="$2"
  local canon_title="$3"
  local stem
  stem="$(movie_title_from_file "$sub")"
  [[ "$stem" == "$raw_title"* ]] || [[ "$raw_title" == *"$stem"* ]] && return 0
  [[ "$stem" == "$canon_title"* ]] || [[ "$canon_title" == *"$stem"* ]] && return 0
  return 1
}

# Strip .AV1 / .x265 suffixes so replacements get clean output names.
canonical_title_from_file() {
  local title
  title="$(movie_title_from_file "$1")"
  title="${title%.AV1}"
  title="${title%.av1}"
  title="${title%.x265}"
  title="${title%.X265}"
  printf '%s' "$title"
}

canonical_title_from_source() {
  local src="$1"
  if is_bluray_root "$src"; then
    basename "$src"
  else
    canonical_title_from_file "$src"
  fi
}

x265_output_path() {
  local src="$1"
  local dir title
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src")"
  printf '%s/%s.x265.mkv' "$dir" "$title"
}

av1_output_path() {
  local src="$1"
  local dir title
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src")"
  printf '%s/%s.AV1.mkv' "$dir" "$title"
}

is_oversized_av1() {
  local src="$1"
  local orig orig_sz av1_sz
  orig="$(find_original_source_for_av1 "$src")"
  [ -n "$orig" ] || return 1
  orig_sz="$(file_size_bytes "$orig")"
  av1_sz="$(file_size_bytes "$src")"
  awk -v o="$orig_sz" -v a="$av1_sz" -v lim="$AV1_MAX_OVERSHOOT_PCT" \
    'BEGIN { if (o <= 0) exit 1; exit !(((a - o) / o) * 100 > lim) }'
}

# Non-derived sibling used as size reference for an AV1 output or AV1 library file.
find_original_source_for_av1() {
  local src="$1"
  local dir title ext f
  dir="$(dirname "$src")"
  title="$(canonical_title_from_file "$src")"
  for ext in mkv mp4 avi ts; do
    f="$dir/$title.$ext"
    [ -f "$f" ] || continue
    [ "$f" = "$src" ] && continue
    is_derived_output "$f" && continue
    printf '%s' "$f"
    return 0
  done
  return 1
}

av1_overshoot_pct_vs_original() {
  local src="$1"
  local orig orig_sz av1_sz
  orig="$(find_original_source_for_av1 "$src")"
  [ -n "$orig" ] || return 0
  orig_sz="$(file_size_bytes "$orig")"
  av1_sz="$(file_size_bytes "$src")"
  awk -v o="$orig_sz" -v a="$av1_sz" 'BEGIN {
    if (o <= 0) { print 0; exit }
    printf "%.1f", ((a - o) / o) * 100
  }'
}

needs_oversized_av1_recheck() {
  local f="$1"
  is_derived_output "$f" || return 1
  is_oversized_av1 "$f" || return 1
  [ ! -f "$(x265_output_path "$f")" ]
}

# Path hints: /Television/, /Anime/, etc. (see BabyBear/BigPoppa layouts)
is_tv_library_path() {
  local p="$1"
  case "$p" in
    */Television/*|*/Television|*/Anime/*|*/Anime|*/TV\ Shows/*|*/TV\ Shows|*/Series/*|*/Series)
      return 0
      ;;
  esac
  return 1
}

is_anime_content() {
  local p="$1"
  case "$p" in
    */Anime/*|*/Anime|*/anime/*|*/anime)
      return 0
      ;;
  esac
  return 1
}

uses_anime_profile() {
  local src="${1:-}"
  is_anime_content "$src" && return 0
  is_anime_content "$SEARCH_PATH" && return 0
  return 1
}

# TV episode markers: S01E01, EP1, Episode 1, 1x01, trailing -01, leading 01-
is_tv_episode() {
  local f="$1"
  local stem
  stem="$(movie_title_from_file "$f")"

  [[ "$stem" =~ [Ss][0-9]{1,2}[Ee][0-9]{1,3} ]] && return 0
  [[ "$stem" =~ [Ss][0-9]{1,2}[[:space:]_\.-]+[Ee][0-9]{1,3} ]] && return 0
  [[ "$stem" =~ [Ee][Pp][[:space:]]*[0-9]{1,3} ]] && return 0
  [[ "$stem" =~ [Ee]pisode[[:space:]]*[0-9]{1,3} ]] && return 0
  [[ "$stem" =~ [0-9]{1,2}[xX][0-9]{1,2} ]] && return 0
  [[ "$stem" =~ -[[:space:]]*[0-9]{1,2}$ ]] && return 0
  [[ "$stem" =~ [[:space:]][0-9]{1,2}$ ]] && return 0
  [[ "$stem" =~ ^[0-9]{2}- ]] && return 0
  return 1
}

# Parent folder holds TV episodes — keep the folder intact.
is_tv_show_directory() {
  local dir="$1"
  local f count=0 videos=0
  shell_nullglob_on
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    is_video_file "$f" || continue
    is_derived_output "$f" && continue
    videos=$((videos + 1))
    is_tv_episode "$f" && count=$((count + 1))
  done
  shell_nullglob_off
  [ "$count" -ge 1 ] && return 0
  if is_tv_library_path "$dir" && [ "$videos" -ge 2 ]; then
    return 0
  fi
  return 1
}

sample_start_middle() {
  local dur="$1"
  awk -v d="$dur" -v s="$SAMPLE_SECONDS" 'BEGIN {
    if (d <= 0) { print 0; exit }
    if (d <= s) { print 0; exit }
    start = (d / 2) - (s / 2)
    if (start < 0) start = 0
    if (start + s > d) start = d - s
    if (start < 0) start = 0
    printf "%.3f", start
  }'
}

file_size_bytes() {
  case "$PLATFORM" in
    macos) stat -f%z "$1" 2>/dev/null || echo 0 ;;
    *) stat -c%s "$1" 2>/dev/null || echo 0 ;;
  esac
}

disc_source_size_bytes() {
  local src="$1"
  if is_iso_file "$src"; then
    file_size_bytes "$src"
  elif is_bluray_root "$src"; then
    du -sb "$src" 2>/dev/null | awk '{print $1+0}' || echo 0
  else
    echo 0
  fi
}

human_size_bytes() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1073741824) printf "%.2f GB", b/1073741824
    else if (b >= 1048576) printf "%.2f MB", b/1048576
    else if (b > 0) printf "%.0f KB", b/1024
    else print "0 B"
  }'
}

sort_paths_by_size_desc() {
  local -n _paths="$1"
  local -a sized=() entry sz path
  local -a sorted_paths=()

  for path in "${_paths[@]}"; do
    if is_disk_source "$path"; then
      sz="$(disc_source_size_bytes "$path")"
    else
      sz="$(file_size_bytes "$path")"
    fi
    sized+=("${sz}"$'\t'"${path}")
  done

  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    path="${entry#*$'\t'}"
    sorted_paths+=("$path")
  done < <(printf '%s\n' "${sized[@]}" | sort -t $'\t' -k1 -nr)

  _paths=("${sorted_paths[@]}")
}

get_scan_roots() {
  local -n _roots="$1"
  local shard

  _roots=()
  if [ "$NO_SHARD" = true ]; then
    _roots=("$SEARCH_PATH")
    return 0
  fi

  while IFS= read -r shard; do
    [ -n "$shard" ] || continue
    _roots+=("$shard")
  done < <(find "$SEARCH_PATH" -mindepth "$SHARD_DEPTH" -maxdepth "$SHARD_DEPTH" -type d 2>/dev/null | LC_ALL=C sort)

  if [ "${#_roots[@]}" -eq 0 ]; then
    _roots=("$SEARCH_PATH")
  fi
}

resume_init_paths() {
  [ -n "$JOB_SIDECAR_DIR" ] || JOB_SIDECAR_DIR="$JOB_ROOT"
  RESUME_STATE_FILE="$JOB_SIDECAR_DIR/convert-v4.state"
  RESUME_QUEUE_FILE="$JOB_SIDECAR_DIR/convert-v4.queue"
  RESUME_SHARDS_FILE="$JOB_SIDECAR_DIR/convert-v4.shards"
}

# Which scan-root shard contains this source path.
shard_for_path() {
  local src="$1"
  local -a roots=()
  local root best=""
  get_scan_roots roots
  for root in "${roots[@]}"; do
    case "$src" in
      "$root"|"$root"/*) best="$root" ;;
    esac
  done
  [ -n "$best" ] && printf '%s' "$best" || printf '%s' "$SEARCH_PATH"
}

count_videos_under_shard() {
  local shard="$1"
  local f count=0 bytes=0 sz
  while IFS= read -r f; do
    is_derived_output "$f" && continue
    is_video_file "$f" || continue
    count=$((count + 1))
    sz="$(file_size_bytes "$f")"
    bytes=$((bytes + sz))
  done < <(find_convert_videos_under "$shard")
  printf '%s %s' "$count" "$bytes"
}

count_disks_under_shard() {
  local shard="$1"
  local -a disks=()
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && disks+=("$line")
  done < <(find_isos_under "$shard")
  while IFS= read -r line; do
    [ -n "$line" ] && disks+=("$line")
  done < <(find_bluray_roots_under "$shard")
  printf '%s' "${#disks[@]}"
}

build_shard_snapshot() {
  local out_file="$1"
  local -a roots=()
  local shard vinfo vcount vbytes dcount
  get_scan_roots roots
  : >"$out_file"
  for shard in "${roots[@]}"; do
    vinfo="$(count_videos_under_shard "$shard")"
    vcount="${vinfo%% *}"
    vbytes="${vinfo##* }"
    dcount="$(count_disks_under_shard "$shard")"
    printf '%s\t%s\t%s\t%s\n' "$shard" "$vcount" "$vbytes" "$dcount" >>"$out_file"
  done
  if [ "$NO_SHARD" = false ] && [ "${#roots[@]}" -gt 1 ]; then
    vcount=0
    vbytes=0
    local f sz
    while IFS= read -r f; do
      is_derived_output "$f" && continue
      is_video_file "$f" || continue
      vcount=$((vcount + 1))
      sz="$(file_size_bytes "$f")"
      vbytes=$((vbytes + sz))
    done < <(find_videos_at_root "$SEARCH_PATH")
    dcount=0
    local line
    while IFS= read -r line; do
      [ -n "$line" ] && dcount=$((dcount + 1))
    done < <(find_isos_at_root "$SEARCH_PATH")
    while IFS= read -r line; do
      [ -n "$line" ] && dcount=$((dcount + 1))
    done < <(find_bluray_roots_at_root "$SEARCH_PATH")
    printf '%s\t%s\t%s\t%s\n' "$SEARCH_PATH" "$vcount" "$vbytes" "$dcount" >>"$out_file"
  fi
  LC_ALL=C sort -o "$out_file" "$out_file"
}

compare_shard_snapshots() {
  local old_file="$1"
  local new_file="$2"
  [ -f "$old_file" ] || return 0
  awk -F '\t' -v oldf="$old_file" -v newf="$new_file" '
    FNR == NR {
      old[$1] = $2 "\t" $3 "\t" $4
      next
    }
    {
      new[$1] = $2 "\t" $3 "\t" $4
    }
    END {
      for (s in old) {
        if (!(s in new)) print "removed\t" s "\t" old[s]
      }
      for (s in new) {
        if (!(s in old)) print "added\t" s "\t" new[s]
        else if (old[s] != new[s]) print "changed\t" s "\t" old[s] "\t->\t" new[s]
      }
    }
  ' "$old_file" "$new_file"
}

write_queue_snapshot() {
  local -n _q="$1"
  local f
  : >"$RESUME_QUEUE_FILE"
  for f in "${_q[@]}"; do
    printf '%s\n' "$f" >>"$RESUME_QUEUE_FILE"
  done
}

load_queue_snapshot() {
  local -n _out="$1"
  local line
  _out=()
  [ -f "$RESUME_QUEUE_FILE" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] && _out+=("$line")
  done <"$RESUME_QUEUE_FILE"
}

resume_persist_state() {
  local status="${1:-}"
  [ "$DRY_RUN" = true ] && return 0
  [ -z "$RESUME_STATE_FILE" ] && return 0
  {
    printf 'version=%s\n' "$VERSION"
    printf 'path=%s\n' "$SEARCH_PATH"
    printf 'shard_depth=%s\n' "$SHARD_DEPTH"
    printf 'no_shard=%s\n' "$NO_SHARD"
    printf 'skip_av1=%s\n' "$SKIP_AV1"
    printf 'skip_x265=%s\n' "$SKIP_X265"
    printf 'last_source=%s\n' "${RESUME_LAST_SOURCE:-}"
    printf 'last_index=%s\n' "${RESUME_LAST_INDEX:-0}"
    printf 'last_status=%s\n' "${status:-$RESUME_LAST_STATUS}"
    printf 'last_shard=%s\n' "${RESUME_LAST_SHARD:-}"
    local key val
    for key in "${!BAKEOFF_ENCODER_CHOICE[@]}"; do
      val="${BAKEOFF_ENCODER_CHOICE[$key]}"
      printf 'bakeoff_encoder_%s=%s\n' "$key" "$val"
    done
    printf 'queue_total=%s\n' "${CONVERT_JOB_TOTAL:-0}"
    printf 'updated=%s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  } >"$RESUME_STATE_FILE"
}

resume_state_matches_current() {
  local key val
  [ -f "$RESUME_STATE_FILE" ] || return 1
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    case "$key" in
      path) val="$SEARCH_PATH" ;;
      shard_depth) val="$SHARD_DEPTH" ;;
      no_shard) val="$NO_SHARD" ;;
      skip_av1) val="$SKIP_AV1" ;;
      skip_x265) val="$SKIP_X265" ;;
      *) continue ;;
    esac
    if ! grep -qxF "${key}=${val}" "$RESUME_STATE_FILE" 2>/dev/null; then
      return 1
    fi
  done <<'EOF'
path
shard_depth
no_shard
skip_av1
skip_x265
EOF
  return 0
}

resume_load_state() {
  local line key val
  RESUME_LAST_SOURCE=""
  RESUME_LAST_INDEX=0
  RESUME_LAST_STATUS=""
  RESUME_LAST_SHARD=""
  BAKEOFF_ENCODER_CHOICE=()
  [ -f "$RESUME_STATE_FILE" ] || return 1
  while IFS= read -r line; do
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      last_source) RESUME_LAST_SOURCE="$val" ;;
      last_index) RESUME_LAST_INDEX="$val" ;;
      last_status) RESUME_LAST_STATUS="$val" ;;
      last_shard) RESUME_LAST_SHARD="$val" ;;
      bakeoff_encoder_*)
        key="${key#bakeoff_encoder_}"
        BAKEOFF_ENCODER_CHOICE[$key]="$val"
        ;;
      bakeoff_done)
        # Legacy v4.0.13: treat as movie_sdr locked to svt unless per-profile keys exist.
        if [ "$val" = true ] && [ "${#BAKEOFF_ENCODER_CHOICE[@]}" -eq 0 ]; then
          BAKEOFF_ENCODER_CHOICE[movie_sdr]="svt_av1_10bit"
        fi
        ;;
    esac
  done <"$RESUME_STATE_FILE"
  return 0
}

resume_clear_state() {
  rm -f -- "$RESUME_STATE_FILE" "$RESUME_QUEUE_FILE" "$RESUME_SHARDS_FILE"
  RESUME_ACTIVE=false
  RESUME_LAST_SOURCE=""
  RESUME_LAST_INDEX=0
  RESUME_LAST_STATUS=""
  RESUME_LAST_SHARD=""
  BAKEOFF_ENCODER_CHOICE=()
}

# Trim the queue to resume after an interrupted session. New files are always included.
apply_resume_to_queue() {
  local -n _q="$1"
  local -a old_queue=() result=()
  local item want_path resume_idx=-1 i=0
  local -A in_old=()

  [ "$RESUME_ACTIVE" = true ] || return 0
  [ -n "$RESUME_LAST_SOURCE" ] || return 0
  load_queue_snapshot old_queue || return 0

  for item in "${old_queue[@]}"; do
    in_old["$item"]=1
  done

  case "$RESUME_LAST_STATUS" in
    completed|skipped)
      want_path=""
      for i in "${!_q[@]}"; do
        if [ "${_q[$i]}" = "$RESUME_LAST_SOURCE" ]; then
          if [ $((i + 1)) -lt "${#_q[@]}" ]; then
            want_path="${_q[$((i + 1))]}"
          fi
          break
        fi
      done
      ;;
    *)
      want_path="$RESUME_LAST_SOURCE"
      ;;
  esac

  if [ -n "$want_path" ]; then
    for i in "${!_q[@]}"; do
      if [ "${_q[$i]}" = "$want_path" ]; then
        resume_idx="$i"
        break
      fi
    done
  fi

  if [ "$resume_idx" -lt 0 ]; then
    warn "Resume anchor not found in current queue"
    if [ "$RESUME_LAST_INDEX" -gt 0 ] && [ "$RESUME_LAST_INDEX" -le "${#_q[@]}" ]; then
      resume_idx=$((RESUME_LAST_INDEX - 1))
      if [ "$RESUME_LAST_STATUS" = completed ] || [ "$RESUME_LAST_STATUS" = skipped ]; then
        [ "$resume_idx" -lt "${#_q[@]}" ] && resume_idx=$((resume_idx + 1)) || resume_idx=-1
      fi
      warn "Using saved job index $RESUME_LAST_INDEX as resume hint"
    else
      return 0
    fi
  fi

  for i in "${!_q[@]}"; do
    item="${_q[$i]}"
    if [[ -z "${in_old[$item]+x}" ]]; then
      result+=("$item")
    elif [ "$resume_idx" -ge 0 ] && [ "$i" -ge "$resume_idx" ]; then
      result+=("$item")
    fi
  done

  log "Resume: last job was $RESUME_LAST_STATUS on $(basename "$RESUME_LAST_SOURCE") (shard: ${RESUME_LAST_SHARD:-unknown})"
  log "Resume: continuing with ${#result[@]} of ${#_q[@]} queued item(s)"
  _q=("${result[@]}")
}

resume_check_shard_changes() {
  local prev_shards="$RESUME_SHARDS_FILE.prev"
  local changes
  [ -f "$RESUME_SHARDS_FILE" ] || return 0
  cp -f "$RESUME_SHARDS_FILE" "$prev_shards"
  build_shard_snapshot "$RESUME_SHARDS_FILE"
  changes="$(compare_shard_snapshots "$prev_shards" "$RESUME_SHARDS_FILE")"
  rm -f -- "$prev_shards"
  if [ -n "$changes" ]; then
    log "Shard snapshot changes since last run:"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      log "  $line"
    done <<<"$changes"
    stats_log_append "--- shard changes since last run ---"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      stats_log_append "  $line"
    done <<<"$changes"
    stats_log_append ""
  else
    log "Shard snapshot unchanged since last run"
  fi
}

resume_prepare_convert() {
  resume_init_paths
  if [ "$NO_RESUME" = true ]; then
    log "Resume disabled (--no-resume) — starting fresh"
    resume_clear_state
    return 0
  fi
  if ! resume_state_matches_current; then
    if [ -f "$RESUME_STATE_FILE" ]; then
      warn "Saved resume state does not match current path/options — starting fresh"
      resume_clear_state
    fi
    return 0
  fi
  if resume_load_state; then
    RESUME_ACTIVE=true
    log "Resume state found — will continue from last interrupted job"
    resume_check_shard_changes
  fi
}

resume_on_signal() {
  warn "Interrupted — resume state saved at job ${RESUME_LAST_INDEX:-0}: ${RESUME_LAST_SOURCE:-unknown}"
  resume_persist_state "interrupted"
  exit 130
}

find_videos_under() {
  local root="$1"
  find "$root" -type f \( \
    -iname '*.avi' -o -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.ts' \) \
    ! -iname '*.AV1.mkv' ! -iname '*.x265.mkv' 2>/dev/null
}

find_convert_videos_under() {
  local root="$1"
  find "$root" -type f \( \
    -iname '*.avi' -o -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.ts' \) 2>/dev/null
}

find_videos_at_root() {
  local root="$1"
  find "$root" -maxdepth 1 -type f \( \
    -iname '*.avi' -o -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.ts' \) \
    ! -iname '*.AV1.mkv' ! -iname '*.x265.mkv' 2>/dev/null
}

find_isos_under() {
  local root="$1"
  find "$root" -type f -iname '*.iso' 2>/dev/null
}

find_isos_at_root() {
  local root="$1"
  find "$root" -maxdepth 1 -type f -iname '*.iso' 2>/dev/null
}

find_bluray_roots_under() {
  local root="$1"
  find "$root" -type d -name BDMV 2>/dev/null | while IFS= read -r bdmv; do
    [ -n "$bdmv" ] || continue
    dirname "$bdmv"
  done | LC_ALL=C sort -u
}

find_bluray_roots_at_root() {
  local root="$1"
  find "$root" -mindepth 1 -maxdepth 2 -type d -name BDMV 2>/dev/null | while IFS= read -r bdmv; do
    [ -n "$bdmv" ] || continue
    dirname "$bdmv"
  done | LC_ALL=C sort -u
}

discover_disk_sources() {
  local -n _out="$1"
  local -a roots=() raw=()
  local shard line

  _out=()
  get_scan_roots roots

  for shard in "${roots[@]}"; do
    while IFS= read -r line; do
      [ -n "$line" ] && raw+=("$line")
    done < <(find_isos_under "$shard")
    while IFS= read -r line; do
      [ -n "$line" ] && raw+=("$line")
    done < <(find_bluray_roots_under "$shard")
  done

  if [ "$NO_SHARD" = false ] && [ "${#roots[@]}" -gt 1 ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && raw+=("$line")
    done < <(find_isos_at_root "$SEARCH_PATH")
    while IFS= read -r line; do
      [ -n "$line" ] && raw+=("$line")
    done < <(find_bluray_roots_at_root "$SEARCH_PATH")
  fi

  if [ "${#raw[@]}" -eq 0 ]; then
    return 0
  fi

  while IFS= read -r line; do
    [ -n "$line" ] && _out+=("$line")
  done < <(printf '%s\n' "${raw[@]}" | LC_ALL=C sort -u)
}

handbrake_scan_title_durations() {
  local src="$1"
  local scan_txt

  scan_txt="$(run_handbrake -t 0 --scan -i "$src" 2>&1 || true)"
  awk '
    BEGIN { idx = 0; dur = 0 }
    /^\+ title [0-9]+:/ {
      if (idx > 0 && dur > 0) print idx ":" dur
      if (match($0, /title ([0-9]+)/, m)) idx = m[1] + 0; else idx = 0
      dur = 0
    }
    /^  \+ duration: / {
      n = split($3, t, ":")
      if (n >= 3) dur = t[1] * 3600 + t[2] * 60 + int(t[3]) + 0
    }
    END { if (idx > 0 && dur > 0) print idx ":" dur }
  ' <<< "$scan_txt"
}

# Prints SELECT:<title>:<seconds> or SKIP:<reason>
select_dominant_disk_title() {
  local src="$1"
  local -a lines=()
  local line result

  while IFS= read -r line; do
    [ -n "$line" ] && lines+=("$line")
  done < <(handbrake_scan_title_durations "$src")

  if [ "${#lines[@]}" -eq 0 ]; then
    printf 'SKIP:%s' "no titles found on disc"
    return 0
  fi

  if [ "${#lines[@]}" -eq 1 ]; then
    printf 'SELECT:%s' "${lines[0]}"
    return 0
  fi

  result="$(printf '%s\n' "${lines[@]}" | awk -v pct="$DISK_TITLE_DOMINANCE_PCT" '
    BEGIN { cnt = 0; thresh = 1 + pct / 100 }
    {
      split($0, a, ":")
      idx[cnt] = a[1]
      dur[cnt] = a[2] + 0
      cnt++
    }
    END {
      if (cnt < 1) {
        print "SKIP"
        exit
      }
      if (cnt == 1) {
        print "SELECT:" idx[0] ":" dur[0]
        exit
      }
      max_i = 0
      for (i = 1; i < cnt; i++) {
        if (dur[i] > dur[max_i]) max_i = i
      }
      max_d = dur[max_i]
      for (i = 0; i < cnt; i++) {
        if (i == max_i) continue
        if (max_d <= dur[i] * thresh) {
          print "SKIP"
          exit
        }
      }
      print "SELECT:" idx[max_i] ":" max_d
    }
  ')"

  if [ "$result" = SKIP ]; then
    printf 'SKIP:%s' "Unable to Determine which title you wish to convert, process this manually"
  else
    printf '%s' "$result"
  fi
}

init_stats_log() {
  local ts
  ts="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  {
    echo ""
    echo "=== $SCRIPT_NAME v$VERSION — $ts ==="
    echo "job_root: $JOB_ROOT"
    echo "path: $SEARCH_PATH"
    echo "log_dir: $JOB_SIDECAR_DIR"
    echo "job_root_writable: $JOB_ROOT_WRITABLE"
    echo "dry_run: $DRY_RUN | organize: $DO_ORGANIZE | convert: $DO_CONVERT | skip_av1: $SKIP_AV1 | skip_x265: $SKIP_X265 | nvidia: $HAS_NVIDIA | intel_qsv: $HAS_INTEL_QSV | amd_vce: $HAS_AMD_VCE | active_encode: $ACTIVE_ENCODE_MODE"
    echo "order: largest to smallest"
    if [ "$DRY_RUN" = true ]; then
      echo "inspect: name | video format | length | resolution (no conversion)"
    fi
    if [ -f "$JOB_SIDECAR_DIR/convert-v4.state" ] && [ "$NO_RESUME" = false ]; then
      echo "resume: convert-v4.state present (auto-resume on convert)"
    fi
  } >>"$MASTER_LOG_FILE" 2>/dev/null || warn "Master log disabled — could not write $MASTER_LOG_FILE"
  if [ "$JOB_ROOT_WRITABLE" = true ]; then
    set +e
    merge_orphan_subdir_logs
    set -e
  fi
}

begin_shard_log() {
  local shard="$1"
  SHARD_LOG_ROOT="$shard"
  if [ "$JOB_ROOT_WRITABLE" = true ] && [ -w "$shard" ] 2>/dev/null; then
    SHARD_LOG_FILE="$shard/convert-v4.shard.log"
  else
    SHARD_LOG_FILE="$JOB_SIDECAR_DIR/shard-$(basename "$shard").log"
  fi
  SHARD_LOG_ACTIVE=true
  {
    echo ""
    echo "=== shard log — $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
    echo "shard: $shard"
    echo "job_root: $JOB_ROOT"
    echo ""
  } >>"$SHARD_LOG_FILE" 2>/dev/null || SHARD_LOG_ACTIVE=false
}

end_shard_log() {
  local shard="$1"
  if [ -z "$SHARD_LOG_FILE" ] || [ ! -f "$SHARD_LOG_FILE" ]; then
    SHARD_LOG_ACTIVE=false
    SHARD_LOG_FILE=""
    return 0
  fi
  master_log_write ""
  master_log_write "--- merged shard log: $shard ---"
  cat "$SHARD_LOG_FILE" >>"$MASTER_LOG_FILE" 2>/dev/null || true
  master_log_write "--- end shard log: $shard ---"
  master_log_write ""
  rm -f -- "$SHARD_LOG_FILE"
  SHARD_LOG_ACTIVE=false
  SHARD_LOG_FILE=""
  SHARD_LOG_ROOT=""
}

merge_orphan_subdir_logs() {
  local f rel
  [ -n "$MASTER_LOG_FILE" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$f" = "$MASTER_LOG_FILE" ] && continue
    rel="${f#"$JOB_ROOT"/}"
    master_log_write ""
    master_log_write "--- merged orphan log: $rel ---"
    cat "$f" >>"$MASTER_LOG_FILE" 2>/dev/null || true
    master_log_write "--- end orphan log: $rel ---"
    master_log_write ""
    rm -f -- "$f"
  done < <(find "$JOB_ROOT" -mindepth 2 -type f \( -name 'convert-v4.log' -o -name 'convert-v4.shard.log' \) 2>/dev/null | LC_ALL=C sort)
}

stats_log_append() {
  [ -n "$MASTER_LOG_FILE" ] || return 0
  printf '%s\n' "$*" >>"$MASTER_LOG_FILE" 2>/dev/null || true
  shard_log_write "$@"
}

stats_log_running_totals() {
  stats_log_append "--- running totals ---"
  stats_log_append "files processed: $STATS_PROCESSED"
  stats_log_append "files skipped: $STATS_SKIPPED"
  if [ "$STATS_INSPECTED" -gt 0 ]; then
    stats_log_append "files inspected: $STATS_INSPECTED"
  fi
  stats_log_append "output space used: $(human_size_bytes "$STATS_OUTPUT_BYTES") ($STATS_OUTPUT_BYTES bytes)"
  stats_log_append "space saved vs sources: $(human_size_bytes "$STATS_SAVED_BYTES") ($STATS_SAVED_BYTES bytes)"
  stats_log_append ""
}

record_conversion_result() {
  local src="$1"
  local out="${2:-}"
  local orig_sz out_sz saved
  if is_disk_source "$src"; then
    orig_sz="$(disc_source_size_bytes "$src")"
  else
    orig_sz="$(file_size_bytes "$src")"
  fi

  if [ -n "$out" ] && [ -f "$out" ] && [ "$DRY_RUN" = false ]; then
    out_sz="$(file_size_bytes "$out")"
    STATS_OUTPUT_BYTES=$((STATS_OUTPUT_BYTES + out_sz))
    if [ "$out_sz" -lt "$orig_sz" ]; then
      saved=$((orig_sz - out_sz))
      STATS_SAVED_BYTES=$((STATS_SAVED_BYTES + saved))
      stats_log_append "[$(date -u '+%H:%M:%S')] KEPT: $(basename "$src")"
      stats_log_append "  source: $(human_size_bytes "$orig_sz") — $(basename "$src")"
      stats_log_append "  output: $(human_size_bytes "$out_sz") — $(basename "$out")"
      stats_log_append "  space used (output): +$(human_size_bytes "$out_sz")"
      stats_log_append "  space saved vs source: $(human_size_bytes "$saved")"
    else
      stats_log_append "[$(date -u '+%H:%M:%S')] KEPT (larger): $(basename "$src")"
      stats_log_append "  source: $(human_size_bytes "$orig_sz")"
      stats_log_append "  output: $(human_size_bytes "$out_sz") (+$(human_size_bytes "$((out_sz - orig_sz))") vs source)"
    fi
  elif [ "$DRY_RUN" = true ] && [ -n "$out" ]; then
    stats_log_append "[$(date -u '+%H:%M:%S')] [dry-run] would create: $(basename "$out")"
    stats_log_append "  source: $(human_size_bytes "$orig_sz") — $(basename "$src")"
  elif [ -z "$out" ]; then
    stats_log_append "[$(date -u '+%H:%M:%S')] METADATA: $(basename "$src") ($(human_size_bytes "$orig_sz"))"
  fi

  STATS_PROCESSED=$((STATS_PROCESSED + 1))
  stats_log_running_totals
}

record_skip() {
  local src="$1"
  local reason="${2:-already exists}"
  STATS_SKIPPED=$((STATS_SKIPPED + 1))
  stats_log_append "[$(date -u '+%H:%M:%S')] SKIP: $(basename "$src") — $reason"
  stats_log_running_totals
}

finalize_stats_log() {
  [ -n "$MASTER_LOG_FILE" ] || return 0
  if [ "$SHARD_LOG_ACTIVE" = true ] && [ -n "$SHARD_LOG_ROOT" ]; then
    end_shard_log "$SHARD_LOG_ROOT"
  fi
  merge_orphan_subdir_logs
  stats_log_append "=== session complete — $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
  stats_log_append "files processed: $STATS_PROCESSED"
  stats_log_append "files skipped: $STATS_SKIPPED"
  if [ "$STATS_INSPECTED" -gt 0 ]; then
    stats_log_append "files inspected: $STATS_INSPECTED"
  fi
  stats_log_append "total output space used: $(human_size_bytes "$STATS_OUTPUT_BYTES") ($STATS_OUTPUT_BYTES bytes)"
  stats_log_append "total space saved vs sources: $(human_size_bytes "$STATS_SAVED_BYTES") ($STATS_SAVED_BYTES bytes)"
  stats_log_append "note: originals are never deleted; output space is additive"
  stats_log_append ""
  maybe_chown_for_media_user "$MASTER_LOG_FILE" "$RESUME_STATE_FILE" "$RESUME_QUEUE_FILE" "$RESUME_SHARDS_FILE"
}

video_codec() {
  run_ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null || echo unknown
}

video_height() {
  run_ffprobe -v error -select_streams v:0 -show_entries stream=height \
    -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null || echo 0
}

video_duration() {
  run_ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null || echo 0
}

video_width() {
  run_ffprobe -v error -select_streams v:0 -show_entries stream=width \
    -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null || echo 0
}

format_duration_hms() {
  awk -v s="$1" 'BEGIN {
    if (s <= 0) { print "unknown"; exit }
    h = int(s / 3600)
    m = int((s % 3600) / 60)
    sec = int(s % 60)
    printf "%d:%02d:%02d", h, m, sec
  }'
}

video_resolution() {
  local src="$1"
  local w h
  w="$(video_width "$src")"
  h="$(video_height "$src")"
  if [ "$w" -gt 0 ] && [ "$h" -gt 0 ]; then
    printf '%sx%s' "$w" "$h"
  else
    printf 'unknown'
  fi
}

video_color_primaries() {
  run_ffprobe -v error -select_streams v:0 -show_entries stream=color_primaries \
    -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null || echo unknown
}

video_color_transfer() {
  run_ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer \
    -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null || echo unknown
}

source_has_dolby_vision() {
  local src="$1"
  run_ffprobe -v error -select_streams v:0 -show_entries stream_side_data=side_data_type \
    -of csv=p=0 "$src" 2>/dev/null | search_ci 'DOVI configuration record'
}

source_is_hdr10_wcg() {
  local src="$1"
  local prim transfer
  prim="$(video_color_primaries "$src")"
  transfer="$(video_color_transfer "$src")"
  [ "$prim" = bt2020 ] && { [ "$transfer" = smpte2084 ] || [ "$transfer" = arib-std-b67 ]; }
}

hdr_color_note() {
  local src="$1"
  if source_has_dolby_vision "$src"; then
    printf 'Dolby Vision'
  elif source_is_hdr10_wcg "$src"; then
    printf 'HDR10/WCG'
  else
    printf ''
  fi
}

# HandBrake on this build uses --colorspace (not separate --colorprim flags).
handbrake_append_color_metadata() {
  local src="$1"
  local -n _args="$2"
  if source_has_dolby_vision "$src"; then
    log "Dolby Vision — BT.2020/PQ color metadata (--colorspace primaries=bt2020:transfer=smpte2084:matrix=bt2020nc)"
    _args+=(--colorspace 'primaries=bt2020:transfer=smpte2084:matrix=bt2020nc')
    return 0
  fi
  if source_is_hdr10_wcg "$src"; then
    log "HDR10/WCG — BT.2020 color metadata (--colorspace)"
    _args+=(--colorspace 'primaries=bt2020:transfer=smpte2084:matrix=bt2020nc')
  fi
}

handbrake_title_resolution() {
  local src="$1"
  local title_idx="$2"
  local scan_txt res
  scan_txt="$(run_handbrake -t 0 --scan -i "$src" 2>&1 || true)"
  res="$(awk -v want="$title_idx" '
    BEGIN { idx = 0; res = "" }
    /^\+ title [0-9]+:/ {
      if (match($0, /title ([0-9]+)/, m)) idx = m[1] + 0; else idx = 0
    }
    /^  \+ size: / {
      if (idx == want) res = $3
    }
    END { print res }
  ' <<< "$scan_txt")"
  [ -n "$res" ] && printf '%s' "$res" || printf 'unknown'
}

record_media_inspection() {
  local src="$1"
  local note="${2:-}"
  local name codec dur dur_h res
  [ "$DRY_RUN" = true ] || return 0
  name="$(basename "$src")"
  codec="$(video_codec "$src")"
  dur="$(video_duration "$src")"
  dur_h="$(format_duration_hms "$dur")"
  res="$(video_resolution "$src")"
  local hdr_note
  hdr_note="$(hdr_color_note "$src")"
  stats_log_append "[$(date -u '+%H:%M:%S')] INSPECT: $name"
  stats_log_append "  format: $codec | length: $dur_h (${dur}s) | resolution: $res"
  [ -n "$hdr_note" ] && stats_log_append "  hdr: $hdr_note"
  [ -n "$note" ] && stats_log_append "  note: $note"
  STATS_INSPECTED=$((STATS_INSPECTED + 1))
}

record_disk_inspection() {
  local src="$1"
  local note="${2:-}"
  local sel title_idx title_dur res kind dur_h name
  [ "$DRY_RUN" = true ] || return 0
  name="$(basename "$src")"
  if is_iso_file "$src"; then
    kind="ISO"
  else
    kind="Blu-ray"
  fi
  sel="$(select_dominant_disk_title "$src")"
  case "$sel" in
    SKIP:*)
      stats_log_append "[$(date -u '+%H:%M:%S')] INSPECT: $name"
      stats_log_append "  format: disc ($kind) | length: n/a | resolution: n/a"
      if [ -n "$note" ]; then
        stats_log_append "  note: $note — ${sel#SKIP:}"
      else
        stats_log_append "  note: ${sel#SKIP:}"
      fi
      ;;
    SELECT:*)
      title_idx="${sel#SELECT:}"
      title_idx="${title_idx%%:*}"
      title_dur="${sel##*:}"
      dur_h="$(format_duration_hms "$title_dur")"
      res="$(handbrake_title_resolution "$src" "$title_idx")"
      stats_log_append "[$(date -u '+%H:%M:%S')] INSPECT: $name"
      stats_log_append "  format: disc ($kind) title $title_idx | length: $dur_h (${title_dur}s) | resolution: $res"
      [ -n "$note" ] && stats_log_append "  note: $note"
      ;;
    *)
      stats_log_append "[$(date -u '+%H:%M:%S')] INSPECT: $name"
      stats_log_append "  format: disc ($kind) | length: unknown | resolution: unknown"
      stats_log_append "  note: title scan failed"
      ;;
  esac
  STATS_INSPECTED=$((STATS_INSPECTED + 1))
}

is_hevc_codec() {
  case "$1" in
    hevc|h265|x265) return 0 ;;
  esac
  return 1
}

# True when --skip-av1 / --skip-x265 excludes this source from conversion.
should_skip_source_format() {
  local src="$1"
  local codec
  is_disk_source "$src" && return 1
  codec="$(video_codec "$src")"
  if [ "$SKIP_AV1" = true ] && [ "$codec" = "av1" ]; then
    return 0
  fi
  if [ "$SKIP_X265" = true ] && is_hevc_codec "$codec"; then
    return 0
  fi
  return 1
}

skip_reason_for_format() {
  local src="$1"
  local codec
  codec="$(video_codec "$src")"
  if [ "$SKIP_AV1" = true ] && [ "$codec" = "av1" ]; then
    printf 'AV1 source (--skip-av1)'
    return 0
  fi
  if [ "$SKIP_X265" = true ] && is_hevc_codec "$codec"; then
    printf 'HEVC/x265 source (--skip-x265)'
    return 0
  fi
  return 1
}

# Returns 0 and prints the path when a canonical output exists and passes validate_mkv_output.
find_complete_canonical_output() {
  local src="$1"
  local hb_dur="${2:-}"
  local av1_out x265_out

  av1_out="$(av1_output_path "$src")"
  if [ -f "$av1_out" ] && validate_mkv_output "$src" "$av1_out" "$hb_dur"; then
    printf '%s' "$av1_out"
    return 0
  fi

  x265_out="$(x265_output_path "$src")"
  if [ -f "$x265_out" ] && validate_mkv_output "$src" "$x265_out" "$hb_dur"; then
    printf '%s' "$x265_out"
    return 0
  fi
  return 1
}

has_complete_canonical_output() {
  local src="$1"
  local hb_dur="${2:-}"
  find_complete_canonical_output "$src" "$hb_dur" >/dev/null
}

clear_incomplete_canonical_outputs() {
  local src="$1"
  local hb_dur="${2:-}"
  local av1_out x265_out

  av1_out="$(av1_output_path "$src")"
  if [ -f "$av1_out" ] && ! validate_mkv_output "$src" "$av1_out" "$hb_dur"; then
    warn "Incomplete/broken AV1 output — will re-encode: $av1_out"
    remove_output_only "$av1_out"
  fi

  x265_out="$(x265_output_path "$src")"
  if [ -f "$x265_out" ] && ! validate_mkv_output "$src" "$x265_out" "$hb_dur"; then
    warn "Incomplete/broken x265 output — will re-encode: $x265_out"
    remove_output_only "$x265_out"
  fi
}

skip_if_complete_canonical_output() {
  local src="$1"
  local hb_dur="${2:-}"
  local complete_out

  if complete_out="$(find_complete_canonical_output "$src" "$hb_dur")"; then
    log "Skip — complete output exists: $complete_out"
    record_skip "$src" "complete output exists"
    return 0
  fi
  clear_incomplete_canonical_outputs "$src" "$hb_dur"
  return 1
}

guess_lang_from_path() {
  local p="$1"
  case "$p" in
    *Chinese*|*Cantonese*|*Mandarin*) echo zh ;;
    *Japanese*) echo ja ;;
    *Korean*) echo ko ;;
    *French*) echo fr ;;
    *German*) echo de ;;
    *Spanish*) echo es ;;
    *English*) echo en ;;
    *) echo en ;;
  esac
}

detect_subtitle_lang() {
  local sub="$1"
  local context_path="$2"
  local base="${sub##*/}"
  local stem="${base%.*}"
  local   ext="$(to_lower "${base##*.}")"

  if [[ "$base" =~ \.(en|eng)\. ]]; then echo eng; return; fi
  if [[ "$base" =~ \.(zh|zho|chi|chs|cht)\. ]]; then echo chi; return; fi
  if [[ "$base" =~ \.(ja|jpn)\. ]]; then echo jpn; return; fi
  if [[ "$base" =~ \.(ko|kor)\. ]]; then echo kor; return; fi
  if [[ "$base" =~ \.(fr|fre)\. ]]; then echo fre; return; fi
  if [[ "$base" =~ \.(de|ger)\. ]]; then echo ger; return; fi
  if [[ "$base" =~ \.(es|spa)\. ]]; then echo spa; return; fi
  if [[ "$base" =~ \.(it|ita)\. ]]; then echo ita; return; fi
  if [[ "$base" =~ \.(pt|por)\. ]]; then echo por; return; fi
  if [[ "$base" =~ \.(ru|rus)\. ]]; then echo rus; return; fi

  if [[ "$stem" =~ \.(en|eng)$ ]]; then echo eng; return; fi
  if [[ "$stem" =~ \.(zh|chi|zho)$ ]]; then echo chi; return; fi
  if [[ "$stem" =~ \.(ja|jpn)$ ]]; then echo jpn; return; fi
  if [[ "$stem" =~ \.(ko|kor)$ ]]; then echo kor; return; fi

  case "$stem" in
    *english*|*English*) echo eng ;;
    *chinese*|*Chinese*|*mandarin*) echo chi ;;
    *japanese*|*Japanese*) echo jpn ;;
    *korean*|*Korean*) echo kor ;;
    *) lang_iso3_from_guess "$(guess_lang_from_path "$context_path")" ;;
  esac
}

lang_iso3_from_guess() {
  case "$1" in
    en) echo eng ;;
    zh) echo chi ;;
    ja) echo jpn ;;
    ko) echo kor ;;
    fr) echo fre ;;
    de) echo ger ;;
    es) echo spa ;;
    *) echo eng ;;
  esac
}

lang_iso3_normalize() {
  local code
  code="$(to_lower "$1")"
  case "$code" in
    en|eng|english) echo eng ;;
    zh|zho|chi|chs|cht|chinese|mandarin|cantonese) echo chi ;;
    ja|jpn|japanese) echo jpn ;;
    ko|kor|korean) echo kor ;;
    fr|fre|french) echo fre ;;
    de|ger|german) echo ger ;;
    es|spa|spanish) echo spa ;;
    it|ita|italian) echo ita ;;
    pt|por|portuguese) echo por ;;
    ru|rus|russian) echo rus ;;
    und|"") echo "" ;;
    *) echo "$code" ;;
  esac
}

lang_display_name() {
  local code
  code="$(lang_iso3_normalize "$1")"
  case "$code" in
    eng) echo English ;;
    chi) echo Chinese ;;
    jpn) echo Japanese ;;
    kor) echo Korean ;;
    fre) echo French ;;
    ger) echo German ;;
    spa) echo Spanish ;;
    ita) echo Italian ;;
    por) echo Portuguese ;;
    rus) echo Russian ;;
    *) [ -n "$code" ] && echo "$code" || echo Unknown ;;
  esac
}

subtitle_matches_video() {
  local sub="$1"
  local video="$2"
  local title stem
  title="$(canonical_title_from_source "$video")"
  stem="$(movie_title_from_file "$sub")"
  stem="${stem%.*}"
  [[ "$stem" == "$title"* ]] || [[ "$title" == *"$stem"* ]] || [[ "$stem" == "$(canonical_title_from_source "$video")"* ]]
}

collect_external_subtitles() {
  local src="$1"
  local dir item
  dir="$(media_content_dir "$src")"
  shell_nullglob_on
  for item in "$dir"/*; do
    [ -f "$item" ] || continue
    is_subtitle_file "$item" || continue
    subtitle_matches_video "$item" "$src" && printf '%s\n' "$item"
  done
  shell_nullglob_off
}

handbrake_append_external_srts() {
  local -n _args="$1"
  local src="$2"
  local -a subs=() langs=() codesets=()
  local sub lang

  while IFS= read -r sub; do
    [ -n "$sub" ] || continue
    case "${sub##*.}" in
      srt|SRT) ;;
      *) continue ;;
    esac
    subs+=("$sub")
    lang="$(detect_subtitle_lang "$sub" "$src")"
    langs+=("$lang")
    codesets+=(UTF-8)
  done < <(collect_external_subtitles "$src")

  [ "${#subs[@]}" -eq 0 ] && return 0

  local joined_subs joined_langs joined_codesets
  joined_subs="$(IFS=,; printf '%s' "${subs[*]}")"
  joined_langs="$(IFS=,; printf '%s' "${langs[*]}")"
  joined_codesets="$(IFS=,; printf '%s' "${codesets[*]}")"
  _args+=(--srt-file "$joined_subs" --srt-lang "$joined_langs" --srt-codeset "$joined_codesets")
  log "External subtitles: ${subs[*]}"
}

label_mkv_tracks() {
  local mkv="$1"
  local src="$2"
  local title="${3:-$(canonical_title_from_file "$src")}"

  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] label audio/subtitle tracks + title on $mkv"
    return 0
  fi
  [ -f "$mkv" ] || return 0

  CONVERT_MKVMERGE="${MKVMERGE_CMD[*]}"
  CONVERT_MKVPROPEDIT="${MKVPROPEDIT_CMD[*]}"
  export CONVERT_MKVMERGE CONVERT_MKVPROPEDIT

  python3 - "$mkv" "$src" "$title" <<'PY'
import json, os, subprocess, sys

mkv, src, title = sys.argv[1:4]
mkvmerge = os.environ.get("CONVERT_MKVMERGE", "mkvmerge").split()
mkvpropedit = os.environ.get("CONVERT_MKVPROPEDIT", "mkvpropedit").split()

LANG_NAMES = {
    "eng": "English", "chi": "Chinese", "jpn": "Japanese", "kor": "Korean",
    "fre": "French", "ger": "German", "spa": "Spanish", "ita": "Italian",
    "por": "Portuguese", "rus": "Russian",
}

def norm(code):
    if not code:
        return ""
    c = code.lower().strip()
    aliases = {
        "en": "eng", "zh": "chi", "zho": "chi", "chi": "chi", "chs": "chi", "cht": "chi",
        "ja": "jpn", "jpn": "jpn", "ko": "kor", "kor": "kor", "fr": "fre", "fre": "fre",
        "de": "ger", "ger": "ger", "es": "spa", "spa": "spa", "it": "ita", "ita": "ita",
        "pt": "por", "por": "por", "ru": "rus", "rus": "rus",
    }
    return aliases.get(c, c if len(c) == 3 else "")

def guess_from_path(path):
    p = path.lower()
    for key, code in (
        ("chinese", "chi"), ("cantonese", "chi"), ("mandarin", "chi"),
        ("japanese", "jpn"), ("korean", "kor"), ("french", "fre"),
        ("german", "ger"), ("spanish", "spa"), ("english", "eng"),
    ):
        if key in p:
            return code
    return "eng"

def detect_from_filename(path):
    name = path.rsplit("/", 1)[-1].lower()
    markers = (
        (".en.", "eng"), (".eng.", "eng"), (".zh.", "chi"), (".chi.", "chi"),
        (".ja.", "jpn"), (".jpn.", "jpn"), (".ko.", "kor"), (".kor.", "kor"),
        (".fr.", "fre"), (".de.", "ger"), (".es.", "spa"),
    )
    for m, code in markers:
        if m in name:
            return code
    return ""

try:
    data = json.loads(subprocess.check_output([*mkvmerge, "-J", mkv], text=True))
except Exception:
    sys.exit(0)

fallback = guess_from_path(src)
args = [*mkvpropedit, mkv, "-e", "info", "--set", f"title={title}"]

for track in data.get("tracks", []):
    if track.get("type") not in ("audio", "subtitles"):
        continue
    tid = track["id"]
    props = track.get("properties", {})
    lang = norm(props.get("language_ietf") or props.get("language") or "")
    if not lang:
        lang = detect_from_filename(src) or fallback
    name = props.get("track_name") or ""
    if not name or name.lower() in {"und", "unknown", "track"}:
        name = LANG_NAMES.get(lang, lang.upper() if lang else "Unknown")
    args.extend(["--edit", f"track:{tid}", "--set", f"name={name}"])
    if lang:
        args.extend(["--set", f"language={lang}"])

subprocess.run(args, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PY
}

finalize_mkv_output() {
  local mkv="$1"
  local src="$2"
  local title="${3:-$(canonical_title_from_file "$src")}"
  label_mkv_tracks "$mkv" "$src" "$title"
  maybe_chown_for_media_user "$mkv"
}

subtitle_target_name() {
  local sub="$1"
  local movie_file="$2"
  local lang ext
  lang="$(detect_subtitle_lang "$sub" "$movie_file")"
  ext="$(to_lower "${sub##*.}")"
  printf '%s.%s' "$lang" "$ext"
}
# Loose movie not yet in Title/Title.ext under a movie library parent.
# TV episodes and TV show folders are never reorganized into per-episode folders.
needs_flat_organize() {
  local video="$1"
  local parent dirbase raw_title canon_title

  parent="$(dirname "$video")"
  raw_title="$(movie_title_from_file "$video")"
  canon_title="$(canonical_organize_title "$raw_title")"
  dirbase="$(basename "$parent")"

  if is_tv_episode "$video"; then
    return 1
  fi
  if is_tv_show_directory "$parent"; then
    return 1
  fi

  # Right folder, filename needs year parenthesized (or other canon fix).
  if [ "$dirbase" = "$canon_title" ] && [ "$raw_title" != "$canon_title" ]; then
    return 0
  fi

  # Already correct: .../Title (YYYY)/Title (YYYY).ext
  if [ "$dirbase" = "$canon_title" ] && [ "$raw_title" = "$canon_title" ]; then
    return 1
  fi

  is_movie_organize_parent "$parent" || return 1

  # Loose file in library/shelf parent — needs subfolder.
  return 0
}

organize_movie_entry() {
  local video="$1"
  local parent raw_title canon_title ext dest_dir dest_video dirbase

  parent="$(dirname "$video")"
  raw_title="$(movie_title_from_file "$video")"
  canon_title="$(canonical_organize_title "$raw_title")"
  ext="${video##*.}"
  dirbase="$(basename "$parent")"

  if [ "$dirbase" = "$canon_title" ]; then
    dest_dir="$parent"
    dest_video="$dest_dir/$canon_title.$ext"
  else
    dest_dir="$parent/$canon_title"
    dest_video="$dest_dir/$canon_title.$ext"
  fi

  log "Organize: $video -> $dest_video"
  if [ "$DRY_RUN" = true ]; then
    return 0
  fi

  mkdir -p "$dest_dir"
  if [ "$video" != "$dest_video" ]; then
    mv -n -- "$video" "$dest_video"
    video="$dest_video"
  fi

  local item target
  for item in "$parent"/*; do
    [ -e "$item" ] || continue
    [ "$item" = "$dest_dir" ] && continue
    if is_subtitle_file "$item"; then
      if subtitle_matches_organize_title "$item" "$raw_title" "$canon_title"; then
        target="$dest_dir/$(subtitle_target_name "$item" "$video")"
        log "  subtitle: $item -> $target"
        mv -n -- "$item" "$target"
      fi
    fi
  done
}

organize_library() {
  local -a loose=() roots=() shard shard_idx=0 shard_total=0 f

  get_scan_roots roots
  shard_total="${#roots[@]}"

  if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
    log "Organize: sharded scan (depth=$SHARD_DEPTH, $shard_total shard(s))"
  fi

  for shard in "${roots[@]}"; do
    shard_idx=$((shard_idx + 1))
    if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
      begin_shard_log "$shard"
      log "Organize shard $shard_idx/$shard_total: $shard"
    fi
    while IFS= read -r f; do
      loose+=("$f")
    done < <(find_videos_under "$shard")
    if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
      end_shard_log "$shard"
    fi
  done

  if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
    while IFS= read -r f; do
      loose+=("$f")
    done < <(find_videos_at_root "$SEARCH_PATH")
  fi

  sort_paths_by_size_desc loose
  log "Organize queue: ${#loose[@]} files (largest first)"

  local f
  for f in "${loose[@]}"; do
    is_derived_output "$f" && continue
    if needs_flat_organize "$f"; then
      organize_movie_entry "$f"
    fi
  done
}

set_mkv_title() {
  local mkv="$1"
  local title="$2"
  finalize_mkv_output "$mkv" "$mkv" "$title"
}

validate_mkv_ffmpeg_stderr() {
  local errf="$1"
  local label="$2"
  if search_cie 'corrupt|invalid|error' "$errf"; then
    warn "Validation failed: ffmpeg reported issues in ${label}"
    cat "$errf" >&2
    return 1
  fi
  return 0
}

validate_mkv_decode_windows() {
  local dst="$1"
  local window="${2:-$MKV_VALIDATE_WINDOW_SECONDS}"
  local errf dur

  errf="$(mktemp)"

  if ! run_ffmpeg -v error -t "$window" -i "$dst" -map 0:v:0 -f null - 2>"$errf"; then
    warn "Validation failed: decode error in first ${window}s of $dst"
    cat "$errf" >&2
    rm -f "$errf"
    return 1
  fi
  validate_mkv_ffmpeg_stderr "$errf" "first ${window}s of $dst" || { rm -f "$errf"; return 1; }

  dur="$(video_duration "$dst")"
  if awk -v d="$dur" -v w="$window" 'BEGIN { exit !(d>w) }'; then
    : > "$errf"
    if ! run_ffmpeg -v error -sseof -"${window}" -i "$dst" -map 0:v:0 -f null - 2>"$errf"; then
      warn "Validation failed: decode error in last ${window}s of $dst"
      cat "$errf" >&2
      rm -f "$errf"
      return 1
    fi
    validate_mkv_ffmpeg_stderr "$errf" "last ${window}s of $dst" || { rm -f "$errf"; return 1; }
  fi

  rm -f "$errf"
  return 0
}

validate_mkv_output() {
  local src="$1"
  local dst="$2"
  local src_dur_override="${3:-}"
  local dur_src dur_dst diff pct

  if [ ! -s "$dst" ]; then
    warn "Validation failed: empty output $dst"
    return 1
  fi

  if ! run_mkvmerge --identify "$dst" >/dev/null 2>&1; then
    warn "Validation failed: mkvmerge cannot identify $dst"
    return 1
  fi

  if [ -n "$src_dur_override" ]; then
    dur_src="$src_dur_override"
  else
    dur_src="$(video_duration "$src")"
  fi
  dur_dst="$(video_duration "$dst")"
  if awk -v a="$dur_src" -v b="$dur_dst" 'BEGIN { exit !(a>0 && b>0) }'; then
    diff="$(awk -v a="$dur_src" -v b="$dur_dst" 'BEGIN { printf "%.6f", (a>b)?a-b:b-a }')"
    pct="$(awk -v d="$diff" -v a="$dur_src" 'BEGIN { if (a<=0) print 100; else print (d/a)*100 }')"
    if awk -v p="$pct" 'BEGIN { exit !(p>3.0) }'; then
      warn "Validation failed: duration drift ${pct}% (src=${dur_src}s dst=${dur_dst}s)"
      return 1
    fi
  fi

  validate_mkv_decode_windows "$dst" || return 1
  return 0
}

size_keep_policy_av1() {
  local orig_sz="$1"
  local new_sz="$2"
  local pct
  if [ "$new_sz" -le "$orig_sz" ]; then
    echo keep
    return 0
  fi
  pct="$(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { if (o<=0) print 100; else print ((n-o)/o)*100 }')"
  if awk -v p="$pct" -v lim="$AV1_MAX_OVERSHOOT_PCT" 'BEGIN { exit !(p>lim) }'; then
    echo reject
  else
    echo keep
  fi
}

size_keep_policy() {
  local orig_sz="$1"
  local new_sz="$2"
  if [ "$new_sz" -le "$orig_sz" ]; then
    echo keep
    return 0
  fi
  local pct
  pct="$(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { if (o<=0) print 100; else print ((n-o)/o)*100 }')"
  if awk -v p="$pct" -v lim="$SIZE_OVERSHOOT_PCT" 'BEGIN { exit !(p>lim) }'; then
    echo reject
  else
    echo keep
  fi
}

encoder_ssim_score() {
  local reference="$1"
  local encoded="$2"
  local out score
  if [ ! -s "$encoded" ]; then
    echo 0
    return 0
  fi
  out="$(run_ffmpeg -nostdin -i "$reference" -i "$encoded" -lavfi ssim -f null - 2>&1 || true)"
  score="$(awk '/SSIM Y:/{ print $3; exit }' <<<"$out" | tr -d '()')"
  if [ -z "$score" ] || [ "$score" = "N/A" ]; then
    score="$(awk '/All:/{ print $2; exit }' <<<"$out" | tr -d '()')"
  fi
  # Keep only a numeric SSIM value (ffmpeg stderr must not leak into comparisons).
  score="$(awk -v s="${score:-0}" 'BEGIN {
    if (s ~ /^[0-9]+(\.[0-9]+)?$/) print s; else print 0
  }')"
  printf '%s' "$score"
}

bakeoff_default_av1_encoder() {
  if [ "$USE_NVIDIA_ENCODE" = true ]; then
    AV1_ENCODER="svt_av1_10bit"
    warn "Bake-off incomplete — defaulting to $AV1_ENCODER (nvenc_av1_10bit sample failed)"
  else
    AV1_ENCODER="svt_av1_10bit"
    warn "Bake-off incomplete — defaulting to $AV1_ENCODER"
  fi
}

# Bake-off runs once per profile class (not once per file, not one global pick for all).
# Classes: movie_sdr | movie_hdr | anime_sdr | anime_hdr
bakeoff_profile_key() {
  local src="$1"
  local base=movie
  uses_anime_profile "$src" && base=anime
  if source_has_dolby_vision "$src" || source_is_hdr10_wcg "$src"; then
    printf '%s_hdr' "$base"
  else
    printf '%s_sdr' "$base"
  fi
}

bakeoff_encoder_for_src() {
  local src="$1"
  local hb_title="${2:-}"
  local hb_dur="${3:-}"
  local key="${4:-$(bakeoff_profile_key "$src")}"

  if [ -n "${BAKEOFF_ENCODER_CHOICE[$key]+set}" ]; then
    AV1_ENCODER="${BAKEOFF_ENCODER_CHOICE[$key]}"
    return 0
  fi

  log "Bake-off profile '$key' (sample from: $(basename "$src"))"
  pick_av1_encoder "$src" "$hb_title" "$hb_dur" || bakeoff_default_av1_encoder
  BAKEOFF_ENCODER_CHOICE[$key]="$AV1_ENCODER"
  log "Profile '$key' encoder locked: $AV1_ENCODER (applies to all $key sources in this run)"
}

# Per-encoder video/audio tuning. Sets EP_* globals via load_encoder_profile.
# Pass optional src path to select anime vs movie profiles.
load_encoder_profile() {
  local encoder="$1"
  local src="${2:-}"
  local anime=false
  EP_PRESET=""
  EP_QUALITY=""
  EP_ENCOPTS=""
  EP_AUDIO_CODEC=""
  EP_AUDIO_BITRATE=""
  EP_HW_DECODE=false
  EP_VIDEO_FILTERS=()
  EP_PROFILE_NAME=movie

  if [ -n "$src" ] && uses_anime_profile "$src"; then
    anime=true
    EP_PROFILE_NAME=anime
  fi

  if [ "$anime" = true ]; then
    case "$encoder" in
      svt_av1_10bit)
        EP_PRESET=5
        EP_QUALITY=$SVT_AV1_CQ_ANIME
        EP_ENCOPTS='enable-qm=1:film-grain-denoise=1:film-grain=12:qm-min=0:scd=1:enable-tf=0:keyint=15s:aq-mode=2:enable-variance-boost=1:variance-boost-strength=3:variance-octile=4:enable-overlays=1'
        EP_VIDEO_FILTERS=(--lapsharp=light)
        EP_AUDIO_CODEC=opus
        EP_AUDIO_BITRATE=$OPUS_BITRATE
        EP_HW_DECODE=auto
        ;;
      nvenc_av1_10bit)
        EP_PRESET=slowest
        EP_QUALITY=$NVENC_AV1_CQ_ANIME
        EP_ENCOPTS="$(nvenc_av1_encopts)"
        EP_VIDEO_FILTERS=(--lapsharp=light)
        EP_AUDIO_CODEC=opus
        EP_AUDIO_BITRATE=$OPUS_BITRATE
        EP_HW_DECODE=true
        ;;
      x265)
        EP_PRESET=medium
        EP_QUALITY=26
        EP_ENCOPTS='tune=animation:keyint=240:min-keyint=24:bframes=8:ref=4:rc-lookahead=30:aq-mode=2:psy-rd=1.5:psy-rdoq=0.8'
        EP_VIDEO_FILTERS=(--lapsharp=light)
        EP_AUDIO_CODEC=aac
        EP_AUDIO_BITRATE=$AAC_BITRATE
        EP_HW_DECODE=false
        ;;
      nvenc_h265)
        EP_PRESET=medium
        EP_QUALITY=26
        EP_ENCOPTS='spatial-aq=1:temporal-aq=1:rc-lookahead=32:multipass=fullres'
        EP_VIDEO_FILTERS=(--lapsharp=light)
        EP_AUDIO_CODEC=aac
        EP_AUDIO_BITRATE=$AAC_BITRATE
        EP_HW_DECODE=true
        ;;
      qsv_h265)
        EP_PRESET=medium
        EP_QUALITY=24
        EP_ENCOPTS='lowpower=0'
        EP_VIDEO_FILTERS=(--lapsharp=light)
        EP_AUDIO_CODEC=aac
        EP_AUDIO_BITRATE=$AAC_BITRATE
        EP_HW_DECODE=true
        ;;
      vt_h265)
        EP_PRESET=
        EP_QUALITY=60
        EP_ENCOPTS='bframes=1'
        EP_VIDEO_FILTERS=(--lapsharp=light)
        EP_AUDIO_CODEC=aac
        EP_AUDIO_BITRATE=$AAC_BITRATE
        EP_HW_DECODE=true
        ;;
      vce_h265)
        EP_PRESET=
        EP_QUALITY=22
        EP_ENCOPTS='preanalysis=1'
        EP_VIDEO_FILTERS=(--lapsharp=light)
        EP_AUDIO_CODEC=aac
        EP_AUDIO_BITRATE=$AAC_BITRATE
        EP_HW_DECODE=false
        ;;
      *)
        err "Unknown encoder profile: $encoder"
        return 1
        ;;
    esac
    return 0
  fi

  case "$encoder" in
    svt_av1_10bit)
      EP_PRESET=8
      EP_QUALITY=$SVT_AV1_CQ_MOVIE
      EP_ENCOPTS='enable-qm=1:qm-min=0:keyint=15s:scd=1:aq-mode=2'
      EP_AUDIO_CODEC=opus
      EP_AUDIO_BITRATE=$OPUS_BITRATE
      EP_HW_DECODE=auto
      ;;
    nvenc_av1_10bit)
      EP_PRESET=slowest
      EP_QUALITY=$NVENC_AV1_CQ_MOVIE
      EP_ENCOPTS="$(nvenc_av1_encopts)"
      EP_AUDIO_CODEC=opus
      EP_AUDIO_BITRATE=$OPUS_BITRATE
      EP_HW_DECODE=true
      ;;
    x265)
      EP_PRESET=medium
      EP_QUALITY=22
      EP_ENCOPTS='keyint=240:min-keyint=24:bframes=8:ref=5:rc-lookahead=40:aq-mode=3:psy-rd=2.0:psy-rdoq=1.0:deblock=-1,-1'
      EP_AUDIO_CODEC=aac
      EP_AUDIO_BITRATE=$AAC_BITRATE
      EP_HW_DECODE=false
      ;;
    nvenc_h265)
      EP_PRESET=medium
      EP_QUALITY=24
      EP_ENCOPTS='spatial-aq=1:temporal-aq=1:rc-lookahead=32:multipass=fullres'
      EP_AUDIO_CODEC=aac
      EP_AUDIO_BITRATE=$AAC_BITRATE
      EP_HW_DECODE=true
      ;;
    qsv_h265)
      EP_PRESET=medium
      EP_QUALITY=22
      EP_ENCOPTS='lowpower=0'
      EP_AUDIO_CODEC=aac
      EP_AUDIO_BITRATE=$AAC_BITRATE
      EP_HW_DECODE=true
      ;;
    vt_h265)
      EP_PRESET=
      EP_QUALITY=58
      EP_ENCOPTS='bframes=1'
      EP_AUDIO_CODEC=aac
      EP_AUDIO_BITRATE=$AAC_BITRATE
      EP_HW_DECODE=true
      ;;
    vce_h265)
      EP_PRESET=
      EP_QUALITY=22
      EP_ENCOPTS='preanalysis=1'
      EP_AUDIO_CODEC=aac
      EP_AUDIO_BITRATE=$AAC_BITRATE
      EP_HW_DECODE=false
      ;;
    *)
      err "Unknown encoder profile: $encoder"
      return 1
      ;;
  esac
}

handbrake_append_audio_args() {
  local -n _args="$1"
  local codec="$2"
  local bitrate="$3"
  _args+=(--all-audio --aencoder "$codec" -B "$bitrate" -D "$AUDIO_DRC" --gain "$AUDIO_GAIN")
}

handbrake_append_hw_decode() {
  local -n _args="$1"
  local encoder="$2"
  local mode="$3"
  case "$mode" in
    false|'') return 0 ;;
  esac
  [ "$HAS_HW_DECODE" = true ] || return 0
  [ -n "$HW_DECODE_NAME" ] || return 0
  case "$mode" in
    true)
      _args+=(--enable-hw-decoding "$HW_DECODE_NAME")
      ;;
    auto)
      if [ "$encoder" = "svt_av1_10bit" ] || [ "$PLATFORM" = macos ]; then
        _args+=(--enable-hw-decoding "$HW_DECODE_NAME")
      fi
      ;;
  esac
}

build_handbrake_args() {
  local src="$1"
  local dst="$2"
  local encoder="$3"
  local -n _out="$4"
  local hb_title="${5:-}"
  local h

  load_encoder_profile "$encoder" "$src" || return 1
  if is_disk_source "$src"; then
    h=0
  else
    h="$(video_height "$src")"
  fi

  if [ "$EP_PROFILE_NAME" = anime ]; then
    log "Encoder profile: anime ($encoder)"
  fi

  _out=(
    -i "$src" -o "$dst" -f mkv -m -O
    -e "$encoder" -q "$EP_QUALITY"
    --all-subtitles --keep-subname
    --subtitle-burned=none --subtitle-default=none
  )
  if [ -n "$EP_PRESET" ]; then
    _out+=(--encoder-preset "$EP_PRESET")
  fi

  if [ -n "$hb_title" ]; then
    _out+=(-t "$hb_title")
  fi

  if [ "${#EP_VIDEO_FILTERS[@]}" -gt 0 ]; then
    _out+=("${EP_VIDEO_FILTERS[@]}")
  fi

  handbrake_append_audio_args _out "$EP_AUDIO_CODEC" "$EP_AUDIO_BITRATE"
  handbrake_append_external_srts _out "$src"

  if [ -n "$EP_ENCOPTS" ]; then
    _out+=(--encopts "$EP_ENCOPTS")
  fi

  if [ "$h" -gt 0 ] && [ "$h" -lt 720 ]; then
    _out+=(-w 1920 -l 1080 --custom-anamorphic none)
    log "Upscale target 1920x1080 (source height ${h}px)"
  fi

  handbrake_append_hw_decode _out "$encoder" "$EP_HW_DECODE"
  handbrake_append_color_metadata "$src" _out
}

pick_av1_encoder() {
  local sample_src="$1"
  local hb_title="${2:-}"
  local hb_dur="${3:-}"
  local tmp clip nvenc_out svt_out ss_nv ss_svt start dur end
  tmp="$(mktemp -d)"
  clip="$tmp/clip.mkv"
  nvenc_out="$tmp/nvenc.mkv"
  svt_out="$tmp/svt.mkv"

  if [ "$DRY_RUN" = true ]; then
    if [ "$USE_NVIDIA_ENCODE" = true ]; then
      AV1_ENCODER="nvenc_av1_10bit"
      log "[dry-run] Would run encoder bake-off; defaulting to $AV1_ENCODER"
    else
      AV1_ENCODER="svt_av1_10bit"
      log "[dry-run] Would run encoder bake-off; defaulting to $AV1_ENCODER"
    fi
    rm -rf "$tmp"
    return 0
  fi

  log "Encoder bake-off (${SAMPLE_SECONDS}s sample) — comparing AV1 encoders for this profile"
  local -a hb_color_extra=()
  local svt_cq nv_cq
  load_encoder_profile svt_av1_10bit "$sample_src"
  svt_cq="$EP_QUALITY"
  if [ "$USE_NVIDIA_ENCODE" = true ]; then
    load_encoder_profile nvenc_av1_10bit "$sample_src"
    nv_cq="$EP_QUALITY"
    log "Bake-off CQ (scales differ): svt_av1_10bit=$svt_cq vs nvenc_av1_10bit=$nv_cq"
  else
    log "Bake-off CQ: svt_av1_10bit=$svt_cq"
  fi
  hdr_note="$(hdr_color_note "$sample_src")"
  [ -n "$hdr_note" ] && log "Bake-off source color: $hdr_note"
  handbrake_append_color_metadata "$sample_src" hb_color_extra

  if [ -n "$hb_title" ]; then
    dur="$hb_dur"
    start="$(sample_start_middle "$dur")"
    end="$(awk -v s="$start" -v n="$SAMPLE_SECONDS" 'BEGIN { printf "%.0f", s + n }')"
    log "Bake-off (disc title $hb_title): ${SAMPLE_SECONDS}s sample from middle (start=${start}s of ${dur}s)"
    load_encoder_profile svt_av1_10bit "$sample_src"
    run_handbrake_with_progress "Bake-off: svt_av1_10bit" -i "$sample_src" -t "$hb_title" -o "$svt_out" -f mkv \
      --start-at "duration:$start" --stop-at "duration:$end" \
      -e svt_av1_10bit -q "$EP_QUALITY" --encoder-preset "$EP_PRESET" \
      --encopts "$EP_ENCOPTS" --all-audio --aencoder "$EP_AUDIO_CODEC" -B "$EP_AUDIO_BITRATE" \
      -D "$AUDIO_DRC" --gain "$AUDIO_GAIN" \
      "${EP_VIDEO_FILTERS[@]}" "${hb_color_extra[@]}" || warn "Bake-off: svt_av1_10bit sample encode failed"
  else
    dur="$(video_duration "$sample_src")"
    start="$(sample_start_middle "$dur")"
    log "Bake-off: ${SAMPLE_SECONDS}s sample from middle (start=${start}s of ${dur}s)"
    if ! run_ffmpeg -y -nostdin -ss "$start" -t "$SAMPLE_SECONDS" -i "$sample_src" -map 0 -c copy "$clip" >/dev/null 2>&1; then
      warn "Bake-off: ffmpeg could not extract sample clip"
      rm -rf "$tmp"
      bakeoff_default_av1_encoder
      return 0
    fi
    if [ ! -s "$clip" ]; then
      warn "Bake-off: sample clip is empty"
      rm -rf "$tmp"
      bakeoff_default_av1_encoder
      return 0
    fi
    load_encoder_profile svt_av1_10bit "$sample_src"
    run_handbrake_with_progress "Bake-off: svt_av1_10bit" -i "$clip" -o "$svt_out" -f mkv \
      -e svt_av1_10bit -q "$EP_QUALITY" --encoder-preset "$EP_PRESET" \
      --encopts "$EP_ENCOPTS" --all-audio --aencoder "$EP_AUDIO_CODEC" -B "$EP_AUDIO_BITRATE" \
      -D "$AUDIO_DRC" --gain "$AUDIO_GAIN" \
      "${EP_VIDEO_FILTERS[@]}" "${hb_color_extra[@]}" || warn "Bake-off: svt_av1_10bit sample encode failed"
  fi

  if [ "$USE_NVIDIA_ENCODE" = true ]; then
    load_encoder_profile nvenc_av1_10bit "$sample_src"
    if [ -n "$hb_title" ]; then
      CUDA_VISIBLE_DEVICES="$GPU_AV1" run_handbrake_with_progress "Bake-off: nvenc_av1_10bit" -i "$sample_src" -t "$hb_title" -o "$nvenc_out" -f mkv \
        --start-at "duration:$start" --stop-at "duration:$end" \
        -e nvenc_av1_10bit -q "$EP_QUALITY" --encoder-preset "$EP_PRESET" \
        --encopts "$EP_ENCOPTS" --enable-hw-decoding "${HW_DECODE_NAME:-nvdec}" \
        --all-audio --aencoder "$EP_AUDIO_CODEC" -B "$EP_AUDIO_BITRATE" \
        -D "$AUDIO_DRC" --gain "$AUDIO_GAIN" \
        "${EP_VIDEO_FILTERS[@]}" "${hb_color_extra[@]}" || warn "Bake-off: nvenc_av1_10bit sample encode failed"
    else
      CUDA_VISIBLE_DEVICES="$GPU_AV1" run_handbrake_with_progress "Bake-off: nvenc_av1_10bit" -i "$clip" -o "$nvenc_out" -f mkv \
        -e nvenc_av1_10bit -q "$EP_QUALITY" --encoder-preset "$EP_PRESET" \
        --encopts "$EP_ENCOPTS" --enable-hw-decoding "${HW_DECODE_NAME:-nvdec}" \
        --all-audio --aencoder "$EP_AUDIO_CODEC" -B "$EP_AUDIO_BITRATE" \
        -D "$AUDIO_DRC" --gain "$AUDIO_GAIN" \
        "${EP_VIDEO_FILTERS[@]}" "${hb_color_extra[@]}" || warn "Bake-off: nvenc_av1_10bit sample encode failed"
    fi

    ss_nv=0; ss_svt=0
    if [ -s "$nvenc_out" ]; then
      ss_nv="$(encoder_ssim_score "$clip" "$nvenc_out")"
    fi
    if [ -s "$svt_out" ]; then
      ss_svt="$(encoder_ssim_score "$clip" "$svt_out")"
    fi

    log "Bake-off SSIM — nvenc_av1_10bit (CQ $nv_cq): ${ss_nv:-0} | svt_av1_10bit (CQ $svt_cq): ${ss_svt:-0}"

    if [ -s "$svt_out" ] && [ -s "$nvenc_out" ]; then
      if awk -v a="${ss_svt:-0}" -v b="${ss_nv:-0}" 'BEGIN { exit !(a>=b) }'; then
        AV1_ENCODER="svt_av1_10bit"
      else
        AV1_ENCODER="nvenc_av1_10bit"
      fi
    elif [ -s "$svt_out" ]; then
      AV1_ENCODER="svt_av1_10bit"
    elif [ -s "$nvenc_out" ]; then
      AV1_ENCODER="nvenc_av1_10bit"
    else
      rm -rf "$tmp"
      bakeoff_default_av1_encoder
      return 0
    fi
    log "Selected AV1 encoder: $AV1_ENCODER (GPU $GPU_AV1 for nvenc)"
  else
    if [ -s "$svt_out" ]; then
      AV1_ENCODER="svt_av1_10bit"
      log "Selected AV1 encoder: $AV1_ENCODER (software — no NVIDIA GPU)"
    else
      rm -rf "$tmp"
      bakeoff_default_av1_encoder
      return 0
    fi
  fi

  rm -rf "$tmp"
  log "Bake-off complete — proceeding with full encode queue"
  return 0
}

encode_sample_x265() {
  local src="$1"
  local dst="$2"
  local hb_title="${3:-}"
  local encoder gpu
  local -a hb_args=()

  if [ "$USE_NVIDIA_ENCODE" = true ]; then
    encoder="nvenc_h265"
    gpu="$GPU_HEVC_PRIMARY"
  elif [ "$USE_QSV_ENCODE" = true ]; then
    encoder="qsv_h265"
    gpu=""
  elif [ "$USE_VT_ENCODE" = true ]; then
    encoder="vt_h265"
    gpu=""
  elif [ "$USE_AMD_VCE_ENCODE" = true ]; then
    encoder="vce_h265"
    gpu=""
  else
    encoder="x265"
    gpu=""
  fi

  build_handbrake_args "$src" "$dst" "$encoder" hb_args "$hb_title" || return 1

  if [ -n "$gpu" ]; then
    CUDA_VISIBLE_DEVICES="$gpu" run_handbrake_with_progress "Sample: x265" "${hb_args[@]}"
  else
    run_handbrake_with_progress "Sample: x265" "${hb_args[@]}"
  fi
}

# Compare middle sample sizes: true when x265 sample is smaller than AV1 sample.
x265_sample_smaller_than_av1() {
  local src="$1"
  local tmp clip x265_out av1_sz x265_sz start dur gb
  tmp="$(mktemp -d)"
  clip="$tmp/clip.mkv"
  x265_out="$tmp/x265.mkv"

  if [ "$DRY_RUN" = true ]; then
    gb="$(awk -v s="$(file_size_bytes "$src")" 'BEGIN { printf "%.2f", s/1024/1024/1024 }')"
    log "[dry-run] Would sample ${SAMPLE_SECONDS}s at mid-file to compare AV1 (${gb} GB) vs x265 compression"
    rm -rf "$tmp"
    return 1
  fi

  dur="$(video_duration "$src")"
  start="$(sample_start_middle "$dur")"

  run_ffmpeg -y -nostdin -ss "$start" -t "$SAMPLE_SECONDS" -i "$src" -map 0 -c copy "$clip" >/dev/null 2>&1
  [ -s "$clip" ] || { rm -rf "$tmp"; return 1; }

  av1_sz="$(file_size_bytes "$clip")"
  encode_sample_x265 "$clip" "$x265_out"
  [ -s "$x265_out" ] || { rm -rf "$tmp"; return 1; }

  x265_sz="$(file_size_bytes "$x265_out")"
  log "Oversized AV1 sample (${SAMPLE_SECONDS}s @ ${start}s): AV1=${av1_sz} bytes, x265=${x265_sz} bytes"

  rm -rf "$tmp"
  [ "$x265_sz" -lt "$av1_sz" ]
}

handbrake_encode() {
  local src="$1"
  local dst="$2"
  local encoder="$3"
  local gpu="${4:-}"
  local hb_title="${5:-}"
  local -a hb_args=()

  load_encoder_profile "$encoder" "$src" || return 1

  if [ "$DRY_RUN" = true ]; then
    local title_arg=""
    [ -n "$hb_title" ] && title_arg="-t $hb_title "
    log "[dry-run] $HANDBRAKE_DISPLAY -e $encoder profile=$EP_PROFILE_NAME -q $EP_QUALITY --encoder-preset $EP_PRESET --encopts '$EP_ENCOPTS' --aencoder $EP_AUDIO_CODEC -B $EP_AUDIO_BITRATE -D $AUDIO_DRC --gain $AUDIO_GAIN ${title_arg}-i '$src' -o '$dst'"
    return 0
  fi

  build_handbrake_args "$src" "$dst" "$encoder" hb_args "$hb_title" || return 1

  local progress_label="Encoding ($encoder)"
  local saved_cuda="${CUDA_VISIBLE_DEVICES:-}"
  if [ -n "$gpu" ] && [ "$USE_NVIDIA_ENCODE" = true ]; then
    export CUDA_VISIBLE_DEVICES="$gpu"
  else
    unset CUDA_VISIBLE_DEVICES 2>/dev/null || CUDA_VISIBLE_DEVICES=
  fi

  run_handbrake_with_progress "$progress_label" "${hb_args[@]}"
  local rc=$?

  if [ -n "$saved_cuda" ]; then
    export CUDA_VISIBLE_DEVICES="$saved_cuda"
  else
    unset CUDA_VISIBLE_DEVICES 2>/dev/null || CUDA_VISIBLE_DEVICES=
  fi
  return "$rc"
}

remux_copy_to_mkv() {
  local src="$1"
  local dst="$2"
  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] remux $src -> $dst"
    return 0
  fi
  log "Remuxing (stream copy)..."
  run_ffmpeg -y -nostdin -stats -loglevel warning -i "$src" -map 0 -c copy "$dst"
  finalize_mkv_output "$dst" "$src"
}

remove_output_only() {
  local f="$1"
  [ -e "$f" ] || return 0
  warn "Removing rejected output (original kept): $f"
  if [ "$DRY_RUN" = true ]; then
    return 0
  fi
  rm -f -- "$f"
}

process_existing_av1() {
  local src="$1"
  local dir title ext out x265_out sz gb
  dir="$(dirname "$src")"
  title="$(movie_title_from_file "$src")"
  ext="$(to_lower "${src##*.}")"
  x265_out="$(x265_output_path "$src")"

  if [ "$ext" != "mkv" ]; then
    out="$(av1_output_path "$src")"
    log "AV1 remux to MKV: $src -> $out"
    remux_copy_to_mkv "$src" "$out"
    validate_mkv_output "$src" "$out" || { remove_output_only "$out"; return 1; }
    finalize_mkv_output "$out" "$src" "$title"
    record_conversion_result "$src" "$out"
    return 0
  fi

  if is_oversized_av1 "$src"; then
    sz="$(file_size_bytes "$src")"
    pct="$(av1_overshoot_pct_vs_original "$src")"
    if [ -f "$x265_out" ]; then
      log "AV1 output ${pct}% vs original — x265 replacement already exists: $x265_out"
      finalize_mkv_output "$src" "$src" "$title"
      record_skip "$src" "x265 replacement exists"
      return 0
    fi
    log "AV1 output ${pct}% larger than original ($(human_size_bytes "$sz")) — testing whether x265 compresses better: $src"
    if x265_sample_smaller_than_av1 "$src"; then
      warn "x265 sample was smaller — re-encoding bloated AV1 to x265"
      try_x265_convert "$src"
      return $?
    fi
    log "x265 sample was not smaller — keeping AV1 (${pct}% vs original)"
    finalize_mkv_output "$src" "$src" "$title"
    record_conversion_result "$src" ""
    return 0
  fi

  log "AV1 in MKV — metadata only: $src"
  finalize_mkv_output "$src" "$src" "$title"
  record_conversion_result "$src" ""
}

try_av1_convert() {
  local src="$1"
  local hb_title="${2:-}"
  local hb_dur="${3:-}"
  local dir title out gpu policy
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src")"
  out="$(av1_output_path "$src")"

  skip_if_complete_canonical_output "$src" "$hb_dur" && return 0

  bakeoff_encoder_for_src "$src" "$hb_title" "$hb_dur"
  [ -n "$AV1_ENCODER" ] || AV1_ENCODER="svt_av1_10bit"

  gpu="$GPU_AV1"
  if [ "$AV1_ENCODER" = "svt_av1_10bit" ] || [ "$USE_NVIDIA_ENCODE" = false ]; then
    gpu=""
  fi

  log "AV1 transcode ($AV1_ENCODER): $src"
  handbrake_encode "$src" "$out" "$AV1_ENCODER" "$gpu" "$hb_title" || {
    remove_output_only "$out"
    warn "AV1 encode failed — trying x265 fallback"
    try_x265_convert "$src" "$hb_title" "$hb_dur"
    return $?
  }

  if [ "$DRY_RUN" = true ]; then
    return 0
  fi

  validate_mkv_output "$src" "$out" "$hb_dur" || {
    remove_output_only "$out"
    warn "AV1 validation failed — trying x265 fallback"
    try_x265_convert "$src" "$hb_title" "$hb_dur"
    return $?
  }

  local orig_sz new_sz
  if is_disk_source "$src"; then
    orig_sz="$(disc_source_size_bytes "$src")"
  else
    orig_sz="$(file_size_bytes "$src")"
  fi
  new_sz="$(file_size_bytes "$out")"
  policy="$(size_keep_policy_av1 "$orig_sz" "$new_sz")"

  if [ "$policy" = keep ]; then
    finalize_mkv_output "$out" "$src" "$title"
    log "Kept AV1 ($(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { printf "%.1f%% of original", (n/o)*100 }')): $out"
    record_conversion_result "$src" "$out"
    return 0
  fi

  warn "AV1 output >${AV1_MAX_OVERSHOOT_PCT}% larger than original ($(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { printf "%.1f%%", (n/o)*100 }')) — trying x265 fallback"
  remove_output_only "$out"
  try_x265_convert "$src" "$hb_title" "$hb_dur"
}

try_x265_convert() {
  local src="$1"
  local hb_title="${2:-}"
  local hb_dur="${3:-}"
  local dir title out gpu encoder codec ext src_codec policy
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src")"
  out="$(x265_output_path "$src")"
  codec="$(video_codec "$src")"
  src_codec="$codec"
  ext="$(to_lower "${src##*.}")"

  skip_if_complete_canonical_output "$src" "$hb_dur" && return 0

  if [ "$ext" = "mkv" ] && is_hevc_codec "$codec" && [ -z "$hb_title" ]; then
    log "x265 remux (HEVC stream copy to MKV): $src -> $out"
    remux_copy_to_mkv "$src" "$out"
    if [ "$DRY_RUN" = true ]; then
      return 0
    fi
    validate_mkv_output "$src" "$out" "$hb_dur" || { remove_output_only "$out"; return 1; }
    finalize_mkv_output "$out" "$src" "$title"
    log "Kept x265 remux ($(awk -v o="$(file_size_bytes "$src")" -v n="$(file_size_bytes "$out")" 'BEGIN { printf "%.1f%% of original", (n/o)*100 }')): $out"
    record_conversion_result "$src" "$out"
    return 0
  fi

  if [ "$USE_NVIDIA_ENCODE" = true ]; then
    encoder="nvenc_h265"
    gpu="$GPU_HEVC_PRIMARY"
    log "x265 transcode (nvenc_h265, GPU $gpu): $src"
    handbrake_encode "$src" "$out" "$encoder" "$gpu" "$hb_title" || {
      if [ "$NVIDIA_GPU_COUNT" -gt 1 ]; then
        warn "Primary GPU HEVC failed; trying GPU $GPU_HEVC_FALLBACK"
        handbrake_encode "$src" "$out" "$encoder" "$GPU_HEVC_FALLBACK" "$hb_title" || { remove_output_only "$out"; return 1; }
      else
        remove_output_only "$out"
        return 1
      fi
    }
  elif [ "$USE_QSV_ENCODE" = true ]; then
    encoder="qsv_h265"
    log "x265 transcode (qsv_h265, Intel Quick Sync): $src"
    handbrake_encode "$src" "$out" "$encoder" "" "$hb_title" || { remove_output_only "$out"; return 1; }
  elif [ "$USE_VT_ENCODE" = true ]; then
    encoder="vt_h265"
    log "x265 transcode (vt_h265, VideoToolbox): $src"
    handbrake_encode "$src" "$out" "$encoder" "" "$hb_title" || { remove_output_only "$out"; return 1; }
  elif [ "$USE_AMD_VCE_ENCODE" = true ]; then
    encoder="vce_h265"
    log "x265 transcode (vce_h265, AMD VCE/VCN): $src"
    handbrake_encode "$src" "$out" "$encoder" "" "$hb_title" || { remove_output_only "$out"; return 1; }
  else
    encoder="x265"
    log "x265 transcode (software x265): $src"
    handbrake_encode "$src" "$out" "$encoder" "" "$hb_title" || { remove_output_only "$out"; return 1; }
  fi

  if [ "$DRY_RUN" = true ]; then
    return 0
  fi

  validate_mkv_output "$src" "$out" "$hb_dur" || { remove_output_only "$out"; return 1; }

  local orig_sz new_sz
  if is_disk_source "$src"; then
    orig_sz="$(disc_source_size_bytes "$src")"
  else
    orig_sz="$(file_size_bytes "$src")"
  fi
  new_sz="$(file_size_bytes "$out")"
  if [ "$src_codec" = "av1" ]; then
    policy="$(size_keep_policy_av1 "$orig_sz" "$new_sz")"
  else
    policy="$(size_keep_policy "$orig_sz" "$new_sz")"
  fi

  if [ "$policy" = keep ]; then
    finalize_mkv_output "$out" "$src" "$title"
    log "Kept x265 ($(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { printf "%.1f%% of original", (n/o)*100 }')): $out"
    record_conversion_result "$src" "$out"
    return 0
  fi

  if [ "$src_codec" = "av1" ]; then
    warn "x265 output not smaller than oversized AV1 — rejected"
  else
    warn "x265 output >${SIZE_OVERSHOOT_PCT}% larger — rejected"
  fi
  remove_output_only "$out"
  return 1
}

process_disk() {
  local src="$1"
  local sel title_idx title_dur kind

  if is_iso_file "$src"; then
    kind="ISO disc"
  else
    kind="Blu-ray disc"
  fi

  log "Scanning titles ($kind): $src"
  sel="$(select_dominant_disk_title "$src")"
  case "$sel" in
    SKIP:*)
      warn "Skipping $kind: ${sel#SKIP:}"
      record_skip "$src" "${sel#SKIP:}"
      return 0
      ;;
    SELECT:*)
      title_idx="${sel#SELECT:}"
      title_idx="${title_idx%%:*}"
      title_dur="${sel##*:}"
      ;;
    *)
      warn "Skipping $kind: title scan failed"
      record_skip "$src" "title scan failed"
      return 0
      ;;
  esac

  log "Processing ($kind title $title_idx, ${title_dur}s): $src"
  try_av1_convert "$src" "$title_idx" "$title_dur"
}

process_video() {
  local src="$1"
  local codec kind ext
  codec="$(video_codec "$src")"
  ext="$(to_lower "${src##*.}")"
  if is_tv_episode "$src"; then
    kind="TV episode"
  else
    kind="movie"
  fi

  if uses_anime_profile "$src"; then
    kind="anime ${kind}"
  fi

  log "Processing ($kind): $src (codec=$codec container=$ext)"
  if [ "$codec" = "av1" ]; then
    process_existing_av1 "$src"
    return 0
  fi
  try_av1_convert "$src"
}

inspect_library() {
  local -a videos=() disks=() roots=()
  local f shard shard_idx=0 shard_total=0

  get_scan_roots roots
  shard_total="${#roots[@]}"

  if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
    log "Inspect: sharded scan (depth=$SHARD_DEPTH, $shard_total shard(s))"
  fi

  for shard in "${roots[@]}"; do
    shard_idx=$((shard_idx + 1))
    if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
      begin_shard_log "$shard"
      log "Inspect shard $shard_idx/$shard_total: $shard"
    fi
    while IFS= read -r f; do
      videos+=("$f")
    done < <(find_convert_videos_under "$shard")
    if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
      end_shard_log "$shard"
    fi
  done

  if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
    while IFS= read -r f; do
      videos+=("$f")
    done < <(find "$SEARCH_PATH" -maxdepth 1 -type f \( \
      -iname '*.avi' -o -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.ts' \) 2>/dev/null)
  fi

  discover_disk_sources disks

  log "Inspect: ${#videos[@]} video(s), ${#disks[@]} disc source(s)"
  stats_log_append "--- media inspection (dry-run) ---"
  for f in "${videos[@]}"; do
    is_derived_output "$f" && continue
    is_video_file "$f" || continue
    record_media_inspection "$f"
  done
  for f in "${disks[@]}"; do
    record_disk_inspection "$f"
  done
  stats_log_append "--- end inspection ---"
  stats_log_append ""
}

convert_library() {
  local -a videos=() disks=() queue=() roots=()
  local f shard shard_idx=0 shard_total=0

  resume_init_paths

  get_scan_roots roots
  shard_total="${#roots[@]}"

  if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
    log "Convert: sharded scan (depth=$SHARD_DEPTH, $shard_total shard(s))"
  fi

  for shard in "${roots[@]}"; do
    shard_idx=$((shard_idx + 1))
    if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
      begin_shard_log "$shard"
      log "Convert shard $shard_idx/$shard_total: $shard"
    fi
    while IFS= read -r f; do
      videos+=("$f")
    done < <(find_convert_videos_under "$shard")
    if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
      end_shard_log "$shard"
    fi
  done

  if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
    while IFS= read -r f; do
      videos+=("$f")
    done < <(find "$SEARCH_PATH" -maxdepth 1 -type f \( \
      -iname '*.avi' -o -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.ts' \) 2>/dev/null)
  fi

  discover_disk_sources disks

  for f in "${videos[@]}"; do
    if is_derived_output "$f"; then
      [ "$SKIP_AV1" = true ] && continue
      needs_oversized_av1_recheck "$f" || continue
    else
      is_video_file "$f" || continue
      has_complete_canonical_output "$f" && continue
      if should_skip_source_format "$f"; then
        local skip_reason
        skip_reason="$(skip_reason_for_format "$f")"
        log "Skip — $skip_reason: $f"
        record_skip "$f" "$skip_reason"
        continue
      fi
    fi
    queue+=("$f")
  done

  for f in "${disks[@]}"; do
    has_complete_canonical_output "$f" && continue
    queue+=("$f")
  done

  sort_paths_by_size_desc queue

  if [ "$RESUME_ACTIVE" = true ]; then
    apply_resume_to_queue queue
  else
    build_shard_snapshot "$RESUME_SHARDS_FILE"
  fi

  write_queue_snapshot queue
  CONVERT_JOB_TOTAL=${#queue[@]}
  log "Convert queue: $CONVERT_JOB_TOTAL items (largest first; one at a time; includes ${#disks[@]} disc source(s))"

  CONVERT_JOB_INDEX=0
  for f in "${queue[@]}"; do
    CONVERT_JOB_INDEX=$((CONVERT_JOB_INDEX + 1))
    CONVERT_JOB_OK=false
    begin_convert_job "$f" "$CONVERT_JOB_INDEX" "$CONVERT_JOB_TOTAL"
    if is_disk_source "$f"; then
      process_disk "$f" && CONVERT_JOB_OK=true || warn "Job failed — continuing queue: $f"
    else
      process_video "$f" && CONVERT_JOB_OK=true || warn "Job failed — continuing queue: $f"
    fi
    end_convert_job "$f" "$CONVERT_JOB_INDEX" "$CONVERT_JOB_TOTAL" "$CONVERT_JOB_OK"
  done

  if [ "$DRY_RUN" = false ]; then
    resume_clear_state
    log "Convert queue finished — resume state cleared"
  fi
}

_convert_on_err() {
  local exit_code=$?
  err "Script aborted (exit $exit_code near line ${BASH_LINENO[0]:-?})"
  exit "$exit_code"
}

main() {
  trap '_convert_on_err' ERR
  assert_script_name_matches_version
  init_stats_log
  detect_hw_environment
  detect_nvenc_av1_tune
  trap resume_on_signal INT TERM
  log "$SCRIPT_NAME v$VERSION"
  log "Path: $SEARCH_PATH (platform=$PLATFORM shell=$(shell_name) dry_run=$DRY_RUN organize=$DO_ORGANIZE convert=$DO_CONVERT skip_av1=$SKIP_AV1 skip_x265=$SKIP_X265 shard_depth=$SHARD_DEPTH no_shard=$NO_SHARD nvidia=$HAS_NVIDIA intel_qsv=$HAS_INTEL_QSV amd_vce=$HAS_AMD_VCE videotoolbox=$HAS_VIDEOTOOLBOX active_encode=$ACTIVE_ENCODE_MODE hw_decode=${HW_DECODE_NAME:-none})"
  log "Master log: $MASTER_LOG_FILE (job_root_writable=$JOB_ROOT_WRITABLE)"

  if [ "$DRY_RUN" = true ]; then
    log "Phase 0: media inspection (name, format, length, resolution — no conversion)"
    inspect_library
  fi

  if [ "$DO_ORGANIZE" = true ]; then
    log "Phase 1: organize per-movie folders (all languages; years parenthesized)"
    organize_library
  fi

  if [ "$DO_CONVERT" = true ]; then
    resume_prepare_convert
    log "Phase 2: transcode / remux to MKV (one file at a time; AV1 preferred when smaller, else x265)"
    convert_library
  fi

  finalize_stats_log
  trap - INT TERM
  log "Done. Original files were not deleted."
}

main "$@"
