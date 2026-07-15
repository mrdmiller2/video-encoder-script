#!/usr/bin/env bash
# convert-v4.0.46.sh — Organize movie folders, transcode TV/movies to AV1/x265 MKV.
# Version: 4.0.46
# Naming: SCRIPT_NAME must match VERSION (convert-v{VERSION}.sh).
#   On each bump: copy the prior script to a NEW filename; keep all older versions in the repo.
#
# Portable: Linux/WSL/Cygwin (bash 4+), macOS (auto re-exec under Homebrew bash 4+).
# Tool paths: CONVERT_* env vars or --ffmpeg/--handbrake/etc. CLI overrides.
#   Auto mode: batch largest-first when <500 files; pipeline at ≥500 (inspect waves of 5,
#   encode one-at-a-time largest-first per wave while inspection continues).
#   Optional per-shard logs during sharded scans; merged into master and removed at session end.
#   AV1 paths (svt + nvenc_av1_10bit): Opus 112 kbps, all audio tracks kept, dialog DRC boost.
#   x265 paths (x265 + nvenc_h265): AAC 128 kbps only. All subtitles/audio kept + labeled.
#   AV1 kept when output is not more than 20% larger than the original; else x265 fallback.
#   AV1 sources (without --skip-av1): 60s mid-file sample; extrapolate AV1 vs x265 sizes;
#     skip when both predict >= original, else encode with the smaller predicted format.
#   Existing HEVC MKV is remux-copied to Title.x265.mkv (no re-encode).
# Movies: every loose video goes into Title/Title.ext (years parenthesized, e.g. Sakura 1992
#   -> Sakura (1992)/Sakura (1992).mkv). English libraries also use A–Z + 0 buckets.
# TV shows: S01E01 / EP01 / -01 patterns, or folders under Television/Anime — episodes stay put.
# Encoders: NVENC when NVIDIA GPUs are present (nvidia-smi or HandBrake NVENC probe);
#   Intel Quick Sync (qsv_h265) when HandBrake reports QSV and NVIDIA is not selected;
#   AMD VCE/VCN via HandBrake (vce_h265/vcn_*) or Linux VAAPI (hevc_vaapi on amdgpu) when
#   HandBrake lacks AMF/VCN (common on Fedora with mesa-va-drivers-freeworld).
#   otherwise svt_av1_10bit + x265 (software).
#   Linux/WSL/Windows priority: NVIDIA > Intel QSV > AMD VCE/VCN > software.
#   Override NVIDIA: CONVERT_PREFER_INTEL_QSV=1 or CONVERT_PREFER_AMD_VCE=1.
#   macOS: VideoToolbox (vt_h265) only — no NVIDIA/QSV/AMD path.
#   WSL2 hybrid: auto-picks Windows HandBrakeCLI.exe (NVENC or QSV) + Linux ffmpeg/mkvtoolnix.
#   WSL QSV: Linux /dev/dri is usually absent — use Windows HandBrake .exe (Intel Windows drivers).
#     Script probes qsv_h265 via that .exe; NVIDIA still wins unless --prefer-intel-qsv.
#   Sources: common + legacy containers HandBrake/ffmpeg can read (avi/ts/m2ts/mpg/wmv/…).
#   ./convert-v4.0.8.sh --path /mnt/BigMomma/Media/Movies/Chinese
#   ./convert-v4.0.8.sh -p /mnt/BigMomma/Media/Movies/English/D --dry-run
#   ./convert-v4.0.8.sh -p /path --organize-only
#   ./convert-v4.0.8.sh -p /path --convert-only
#   ./convert-v4.0.8.sh -p /mnt/Movies --shard-depth 1   # per top-level subdir find (default)
#   ./convert-v4.0.8.sh -p /mnt/Movies --no-shard          # monolithic find (large trees)
#   --dry-run inspects each file (name, codec, length, resolution) and logs to the master log
#   --skip-av1 / --skip-x265 skip sources already in those codecs (inspection still runs)
#   Resume: convert-v4.state / .queue / .shards in --path; use --no-resume for a fresh run
#   Restart: existing .AV1.mkv / .x265.mkv outputs are validated before skip (quick check
#     during scan; full first/last 30s decode at encode time). Incomplete outputs are removed.
#   Structure: Matroska EBML/segment bounds always; mkvalidator (when installed) for headers,
#     SeekHead/Cues/indices (encode-time by default; CONVERT_MKVALIDATOR_ON_QUICK=1 for scan).
#     Results cached by size+mtime. Failures appended to corrupt_files.txt.
#   Metadata: ffprobe must report duration + a video stream (catches empty/unplayable files).
#   Bad processed .AV1.mkv/.x265.mkv: deleted and flagged for reconversion (reconvert_files.txt).
#   Bad source media: logged to bad_sources.txt and skipped for human review (never deleted).
#   Startup: tool presence checklist + package-manager install commands (macOS / Linux / WSL).
#
# Disks: .iso files and Blu-ray folders (BDMV) are HandBrake "disc" sources.
#   Auto-converts the dominant title when it is >40% longer than every other title;
#   otherwise skips with a log entry for manual processing.
#
# GPUs: RTX 5080 (index 0) — AV1 + HEVC. RTX A4500 (index 1) — HEVC only.
#   Per-file semaphore: {Title}.convert-v4.IN_PROGRESS beside the source while a job runs;
#     removed when the job finishes (ok/fail/skip). Left behind on interrupt/crash so a
#     human can delete that title's partial .AV1.mkv / .x265.mkv before retrying.
# Original files are never deleted.

# macOS: re-exec under bash 4+ (Homebrew). System /bin/bash is 3.2 and lacks bash 4 features.
if [ -z "${CONVERT_V4_DARWIN_BASH:-}" ]; then
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] 2>/dev/null; then
        _darwin_bash=""
        for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
          if [ -x "$_candidate" ] && "$_candidate" -c '(( BASH_VERSINFO[0] >= 4 ))' 2>/dev/null; then
            _darwin_bash="$_candidate"
            break
          fi
        done
        if [ -n "$_darwin_bash" ]; then
          _convert_v4_exec_path="${BASH_SOURCE[0]:-$0}"
          CONVERT_V4_DARWIN_BASH=1 exec "$_darwin_bash" "$_convert_v4_exec_path" "$@"
        fi
        echo "[convert] macOS requires bash 4+ — install with: brew install bash" >&2
        exit 1
      fi
      ;;
  esac
fi

set -euo pipefail

_CONVERT_V4_SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"

VERSION="4.0.46"
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
LARGEST_FIRST=false
FORCE_PIPELINE=false
PIPELINE_FILE_THRESHOLD="${CONVERT_PIPELINE_THRESHOLD:-500}"
ENCODE_INSPECT_BATCH_SIZE="${CONVERT_ENCODE_BATCH_SIZE:-5}"
SKIP_BAKEOFF=false
NVENC_AV1_TUNE_OVERRIDE=""
ENFORCE_CIFS_0777=true
CONVERT_CIFS_MOUNT_SRC="${CONVERT_CIFS_MOUNT_SRC:-}"
CONVERT_CIFS_MOUNT_DST="${CONVERT_CIFS_MOUNT_DST:-}"
CONVERT_CIFS_CREDENTIALS="${CONVERT_CIFS_CREDENTIALS:-}"
CIFS_MOUNT_FILE_MODE="${CONVERT_CIFS_FILE_MODE:-0777}"
CIFS_MOUNT_DIR_MODE="${CONVERT_CIFS_DIR_MODE:-0777}"
DISK_TITLE_DOMINANCE_PCT=40
SAMPLE_SECONDS=60
MKV_VALIDATE_WINDOW_SECONDS=30
IN_PROGRESS_FLAG_SUFFIX="convert-v4.IN_PROGRESS"
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
# AMD: HandBrake vce/vcn when available; else Linux ffmpeg hevc_vaapi (mesa freeworld)
AMD_ENCODE_BACKEND=""
AMD_VAAPI_DEVICE=""
HB_SUPPORTS_KEEP_SUBNAME=false
TOOL_FFMPEG="${CONVERT_FFMPEG:-}"
TOOL_FFPROBE="${CONVERT_FFPROBE:-}"
TOOL_HANDBRAKE="${CONVERT_HANDBRAKE:-}"
TOOL_MKVPROPEDIT="${CONVERT_MKVPROPEDIT:-}"
TOOL_MKVMERGE="${CONVERT_MKVMERGE:-}"
TOOL_MKVALIDATOR="${CONVERT_MKVALIDATOR:-}"
HAS_MKVALIDATOR=false
# Full mkvalidator during quick scan when binary exists. Default 0: scan uses EBML
# bounds + queues uncached files so encode-time runs mkvalidator once (then caches).
# Set CONVERT_MKVALIDATOR_ON_QUICK=1 to run mkvalidator during library scan.
MKVALIDATOR_ON_QUICK="${CONVERT_MKVALIDATOR_ON_QUICK:-0}"
MKV_STRUCTURE_CACHE_FILE=""
CORRUPT_FILES_LOG=""
BAD_SOURCES_LOG=""
RECONVERT_FILES_LOG=""
# Set by validate_mkv_structure when quick scan defers full mkvalidator (do not delete yet).
MKV_VALIDATE_DEFERRED=false
PACKAGE_MANAGER=""
CHECK_TOOLS_ONLY=false
HAS_PYTHON3=false
HAS_GREP_OR_RG=false

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
CONVERT_SCAN_COUNT=0
CONVERT_READY_FILE=""
CONVERT_SCAN_DONE_FILE=""
CONVERT_SCAN_PID=0
CONVERT_READY_OFFSET=0
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

# Containers HandBrake/ffmpeg commonly ingest (legacy + modern). Keep find helpers in sync.
VIDEO_EXTS=(
  avi mp4 mkv ts m2ts mts mpg mpeg mpe m4v mov wmv flv webm vob divx asf ogv 3gp rmvb rm
)
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
  --largest-first         Force batch: inspect all, sort largest-first, then encode
  --pipeline              Force pipeline: inspect waves, encode one-at-a-time per wave
  --encode-batch N        Pipeline: queue N inspected items per encode wave (default: 5)
  --skip-bakeoff          Skip AV1 encoder bake-off (start encoding immediately)
  --nvenc-av1-tune TUNE   Force NVENC AV1 tune: hq or uhq (default: auto-probe)
  --prefer-intel-qsv      Prefer Intel Quick Sync over NVIDIA when both are available
  --prefer-amd-vce        Prefer AMD VCE/VCN over NVIDIA when both are available
  --no-enforce-mount      Skip CIFS mount check/remount (file_mode/dir_mode 0777)
  --mount-share SRC:DST   Mount CIFS share before run (e.g. //10.0.1.103/BabyBear:/mnt/BabyBear)
  --mount-credentials F   SMB credentials file (username=/password= lines)
  --check-tools           Verify required tools, print install commands for this OS, then exit

CIFS/SMB (WSL/NFS-style shares — logs and MKV outputs need writable mount):
  Default: ensure parent CIFS mount uses file_mode=0777,dir_mode=0777,noperm
  CONVERT_CIFS_MOUNT_SRC   e.g. //10.0.1.103/BabyBear (mount when DST is empty)
  CONVERT_CIFS_MOUNT_DST   e.g. /mnt/BabyBear (default: inferred from --path)
  CONVERT_CIFS_CREDENTIALS path to credentials file
  CONVERT_SMB_USER / CONVERT_SMB_PASSWORD  alternative to credentials file

Tool paths (when not in PATH):
  --ffmpeg PATH           ffmpeg binary (or set CONVERT_FFMPEG)
  --ffprobe PATH          ffprobe binary (or set CONVERT_FFPROBE)
  --handbrake PATH        HandBrakeCLI binary (or set CONVERT_HANDBRAKE)
  --mkvpropedit PATH      mkvpropedit binary (or set CONVERT_MKVPROPEDIT)
  --mkvmerge PATH         mkvmerge binary (or set CONVERT_MKVMERGE)
  --mkvalidator PATH      mkvalidator binary (or set CONVERT_MKVALIDATOR; optional)

Portable: Linux/WSL/Cygwin (bash 4+), macOS (Homebrew bash 4+ — re-exec'd automatically). macOS hw-decode: videotoolbox.

Target format:
  MKV container with AV1 video (kept when ≤20% larger than source) or x265 fallback.
  AV1 sources (without --skip-av1): sample-test AV1 vs x265; skip when neither beats original.
  Software-only encode skips AV1 encoder bake-off (svt_av1_10bit used directly).
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
  CONVERT_NVENC_AV1_TUNE=hq|uhq  Force NVENC AV1 tune (skip probe); default auto-probes uhq
  CONVERT_SKIP_NVENC_PROBE=1     Skip uhq probe and use tune=hq

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
# Same as log(), but always stderr — safe inside $(...) capture helpers.
log_err() { echo -e "${Green}[convert]${Color_Off} $*" >&2; log_to_master "[convert] $*"; }
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

# Print copy-pasteable install commands for this host (pre-compiled packages preferred).
print_platform_install_commands() {
  cat >&2 <<EOF

Package manager detected: ${PACKAGE_MANAGER:-none}
Platform: $PLATFORM

Prefer pre-built packages from your OS package manager (or Homebrew bottles).

EOF
  case "$PLATFORM" in
    macos)
      cat >&2 <<'EOF'
macOS (Homebrew — recommended):
  brew install bash ffmpeg mkvtoolnix handbrake python3 mkvalidator grep ripgrep

  Notes:
    - Script auto re-execs under Homebrew bash 4+ when /bin/bash is 3.2.
    - HandBrakeCLI comes from the handbrake formula.
EOF
      ;;
    linux|wsl)
      cat >&2 <<'EOF'
Linux / WSL — pick the block that matches your distro:

  Debian / Ubuntu / WSL (apt):
    sudo apt update
    sudo apt install -y ffmpeg mkvtoolnix handbrake-cli python3 grep ripgrep
    # mkvalidator is NOT in apt/dnf — optional. Drop a Linux x86_64 binary at:
    #   ~/.local/bin/mkvalidator
    # Or install Homebrew on Linux and: brew install mkvalidator
    # Without it, EBML segment-bounds checks still run.

  Fedora / RHEL (dnf):
    sudo dnf install -y ffmpeg mkvtoolnix HandBrake-cli python3 grep ripgrep
    # mkvalidator: brew install mkvalidator  (Homebrew on Linux) or build from Matroska source

  Arch:
    sudo pacman -S --needed ffmpeg mkvtoolnix handbrake python grep ripgrep
    # mkvalidator: yay -S mkvalidator   (AUR)  or: brew install mkvalidator

  openSUSE:
    sudo zypper install ffmpeg mkvtoolnix HandBrake-cli python3 grep ripgrep

  Alpine:
    sudo apk add ffmpeg mkvtoolnix handbrake python3 grep ripgrep

  HandBrake Flatpak (any Linux/WSL with Flatpak):
    flatpak install flathub fr.handbrake.ghb
    # Script auto-detects: flatpak run --command=HandBrakeCLI fr.handbrake.ghb

  WSL tip: Linux ffmpeg/mkvtoolnix + Windows HandBrakeCLI.exe (NVENC) is supported.
    Place HandBrakeCLI on PATH or set CONVERT_HANDBRAKE=/mnt/c/Program Files/HandBrake/HandBrakeCLI.exe
EOF
      if [ "$PACKAGE_MANAGER" = brew ]; then
        cat >&2 <<'EOF'

  This host has Homebrew — fastest path for missing tools (incl. mkvalidator bottle):
    brew install ffmpeg mkvtoolnix handbrake python3 mkvalidator grep ripgrep
EOF
      elif [ "$PACKAGE_MANAGER" = apt ]; then
        cat >&2 <<'EOF'

  Suggested for this host:
    sudo apt update && sudo apt install -y ffmpeg mkvtoolnix handbrake-cli python3 grep ripgrep
    # mkvalidator (optional): place binary at ~/.local/bin/mkvalidator — not available via apt
EOF
      elif [ "$PACKAGE_MANAGER" = dnf ] || [ "$PACKAGE_MANAGER" = yum ]; then
        cat >&2 <<'EOF'

  Suggested for this host:
    sudo dnf install -y ffmpeg mkvtoolnix HandBrake-cli python3 grep ripgrep
    # mkvalidator (optional): ~/.local/bin/mkvalidator or: brew install mkvalidator
EOF
      elif [ "$PACKAGE_MANAGER" = pacman ]; then
        cat >&2 <<'EOF'

  Suggested for this host:
    sudo pacman -S --needed ffmpeg mkvtoolnix handbrake python grep ripgrep
    # mkvalidator (optional): yay -S mkvalidator  or  ~/.local/bin/mkvalidator
EOF
      fi
      ;;
    windows)
      cat >&2 <<'EOF'
Windows / Cygwin / WSL:
  Prefer WSL2 + Linux tools (ffmpeg, mkvtoolnix) and Windows HandBrakeCLI.exe for NVENC.
  mkvalidator is optional and not in winget/choco apt — use WSL ~/.local/bin/mkvalidator
  (Linux x86_64 binary) or skip it (EBML bounds still validate structure).
EOF
      ;;
    *)
      cat >&2 <<'EOF'
Unknown platform — install ffmpeg, ffprobe, HandBrakeCLI, mkvmerge, mkvpropedit, python3,
and optionally mkvalidator; then pass paths via CONVERT_* / --ffmpeg etc.
EOF
      ;;
  esac
  cat >&2 <<'EOF'

Optional overrides (when binaries are not on PATH):
  CONVERT_FFMPEG CONVERT_FFPROBE CONVERT_HANDBRAKE CONVERT_MKVPROPEDIT
  CONVERT_MKVMERGE CONVERT_MKVALIDATOR
  --ffmpeg --ffprobe --handbrake --mkvpropedit --mkvmerge --mkvalidator
EOF
}

print_tool_install_help() {
  err "One or more required tools were not found."
  print_platform_install_commands
}

# Log a one-line status for each tool; returns 1 if any required tool is missing.
report_tool_checklist() {
  local missing=0
  local status path

  log "Tool checklist (platform=$PLATFORM package_manager=${PACKAGE_MANAGER:-none}):"

  _tool_row() {
    local name="$1" required="$2" present="$3" detail="${4:-}"
    if [ "$present" = true ]; then
      log "  [OK]  $name${detail:+ — $detail}"
    elif [ "$required" = true ]; then
      log "  [MISSING] $name (required)${detail:+ — $detail}"
      missing=1
    else
      log "  [OPTIONAL MISSING] $name${detail:+ — $detail}"
    fi
  }

  if [ "${#FFMPEG_CMD[@]}" -gt 0 ]; then
    _tool_row "ffmpeg" true true "${FFMPEG_CMD[*]}"
  else
    _tool_row "ffmpeg" true false "install via package manager"
  fi
  if [ "${#FFPROBE_CMD[@]}" -gt 0 ]; then
    _tool_row "ffprobe" true true "${FFPROBE_CMD[*]}"
  else
    _tool_row "ffprobe" true false "usually bundled with ffmpeg"
  fi
  if [ -n "${HANDBRAKE_DISPLAY:-}" ]; then
    _tool_row "HandBrakeCLI" true true "$HANDBRAKE_DISPLAY"
  else
    _tool_row "HandBrakeCLI" true false "handbrake-cli / HandBrake-cli / brew handbrake / Flatpak"
  fi
  if [ "${#MKVMERGE_CMD[@]}" -gt 0 ]; then
    _tool_row "mkvmerge" true true "${MKVMERGE_CMD[*]}"
  else
    _tool_row "mkvmerge" true false "mkvtoolnix package"
  fi
  if [ "${#MKVPROPEDIT_CMD[@]}" -gt 0 ]; then
    _tool_row "mkvpropedit" true true "${MKVPROPEDIT_CMD[*]}"
  else
    _tool_row "mkvpropedit" true false "mkvtoolnix package"
  fi
  if [ "$HAS_MKVALIDATOR" = true ]; then
    _tool_row "mkvalidator" false true "${MKVALIDATOR_CMD[*]}"
  else
    _tool_row "mkvalidator" false false "optional — place at ~/.local/bin/mkvalidator (not in apt/winget)"
  fi
  if command -v python3 >/dev/null 2>&1; then
    HAS_PYTHON3=true
    _tool_row "python3" true true "$(command -v python3)"
  else
    HAS_PYTHON3=false
    _tool_row "python3" true false "needed for EBML structure + remux helpers"
  fi
  if [ "${TEXT_SEARCH_BACKEND:-}" = rg ] || [ "${TEXT_SEARCH_BACKEND:-}" = grep ] || command -v grep >/dev/null 2>&1 || command -v rg >/dev/null 2>&1; then
    HAS_GREP_OR_RG=true
    _tool_row "grep/rg" true true "${TEXT_SEARCH_DISPLAY:-grep}"
  else
    HAS_GREP_OR_RG=false
    _tool_row "grep/rg" true false
  fi

  if [ "$missing" -ne 0 ]; then
    print_platform_install_commands
    return 1
  fi
  return 0
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
    credf="$(mktemp)"
    chmod 600 "$credf"
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
      src="$(awk -v mnt="$mp" '$2==mnt && $3=="cifs" { print $1; exit }' /etc/fstab)"
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
    home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
    [ -n "$home" ] || home="$(eval echo "~$SUDO_USER")"
  fi
  [ -n "$home" ] || home="$HOME"
  printf '%s' "$home"
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
  echo "[convert] Log file: $MASTER_LOG_FILE (job_root_writable=$JOB_ROOT_WRITABLE)" >&2
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

_handbrake_help_lists_qsv() {
  local hb_help="$1"
  search_cie 'qsv_h265|qsv_h264|qsv_av1' <<<"$hb_help" && return 0
  search_cie 'qsv: is available' <<<"$hb_help"
}

_configure_qsv_runtime_env() {
  # Preserve prior LIBVA so AMD VAAPI can restore after a failed QSV probe.
  _CONVERT_SAVED_LIBVA_DRIVER_NAME="${LIBVA_DRIVER_NAME-__unset__}"
  export LIBVA_DRIVER_NAME=iHD
  export LIBVA_DRI3_DISABLE="${LIBVA_DRI3_DISABLE:-1}"
}

_restore_libva_after_qsv_probe() {
  if [ "${_CONVERT_SAVED_LIBVA_DRIVER_NAME-__unset__}" = "__unset__" ]; then
    unset LIBVA_DRIVER_NAME 2>/dev/null || true
  else
    export LIBVA_DRIVER_NAME="$_CONVERT_SAVED_LIBVA_DRIVER_NAME"
  fi
  unset _CONVERT_SAVED_LIBVA_DRIVER_NAME 2>/dev/null || true
}

_configure_amd_vaapi_runtime_env() {
  # Dual-GPU laptops often force LIBVA_DRIVER_NAME=iHD system-wide; AMD needs radeonsi.
  export LIBVA_DRIVER_NAME=radeonsi
  export LIBVA_DRI3_DISABLE="${LIBVA_DRI3_DISABLE:-1}"
}

# Short hevc_vaapi probe on a render node (mesa-va-drivers-freeworld / radeonsi).
_probe_amd_vaapi_on_device() {
  local device="$1"
  local tmp probe_out rc ok=1
  [ -n "$device" ] && [ -e "$device" ] || return 1
  tmp="$(mktemp -d)"
  probe_out="$tmp/out.mkv"
  _configure_amd_vaapi_runtime_env
  set +e
  env LIBVA_DRIVER_NAME=radeonsi LIBVA_DRI3_DISABLE="${LIBVA_DRI3_DISABLE:-1}" \
    "${FFMPEG_CMD[@]}" -y -nostdin -hide_banner -loglevel error \
    -init_hw_device "vaapi=amd:${device}" -filter_hw_device amd \
    -f lavfi -i "color=c=black:s=320x240:d=0.4" \
    -vf 'format=nv12,hwupload' -c:v hevc_vaapi -qp 28 -f matroska "$probe_out" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$probe_out" ]; then
    ok=0
  fi
  set -e
  rm -rf "$tmp"
  return "$ok"
}

_detect_amd_vaapi_encode() {
  local device preferred="${CONVERT_AMD_VAAPI_DEVICE:-}"
  AMD_VAAPI_DEVICE=""
  [ "$PLATFORM" = linux ] || [ "$PLATFORM" = wsl ] || return 1

  if [ -n "$preferred" ]; then
    if _probe_amd_vaapi_on_device "$preferred"; then
      AMD_VAAPI_DEVICE="$preferred"
      return 0
    fi
    warn "CONVERT_AMD_VAAPI_DEVICE=$preferred failed hevc_vaapi probe"
  fi

  for device in /dev/dri/renderD*; do
    [ -e "$device" ] || continue
    if _probe_amd_vaapi_on_device "$device"; then
      AMD_VAAPI_DEVICE="$device"
      return 0
    fi
  done
  return 1
}

# Short encode probe — HandBrake may list QSV while runtime init fails (or /dev/dri missing on Linux).
# Check output size BEFORE deleting the temp dir (probe_out lives under tmp).
_probe_qsv_encode_available() {
  local tmp probe_out rc ok=1
  tmp="$(mktemp -d)"
  probe_out="$tmp/out.mkv"
  if ! run_ffmpeg -y -nostdin -f lavfi -i testsrc=duration=1:size=640x360:rate=24 \
    -pix_fmt yuv420p "$tmp/in.mp4" >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi
  _configure_qsv_runtime_env
  set +e
  run_handbrake -i "$tmp/in.mp4" -o "$probe_out" -f mkv -e qsv_h265 -q 28 \
    --encoder-preset balanced --encopts lowpower=0 --audio none >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$probe_out" ]; then
    ok=0
  fi
  set -e
  _restore_libva_after_qsv_probe
  rm -rf "$tmp"
  return "$ok"
}

_handbrake_reports_qsv() {
  local candidate="$1"
  local hb_help
  [ -n "$candidate" ] || return 1
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$PLATFORM" = wsl ] && [[ "$candidate" == *.exe ]]; then
    hb_help="$(sudo -u "$SUDO_USER" -H -- "$candidate" --help 2>&1)" || return 1
  else
    hb_help="$("$candidate" --help 2>&1)" || return 1
  fi
  _handbrake_help_lists_qsv "$hb_help"
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
  local tool
  local failed=0

  detect_package_manager

  FFMPEG_CMD=()
  FFPROBE_CMD=()
  MKVMERGE_CMD=()
  MKVPROPEDIT_CMD=()
  MKVALIDATOR_CMD=()
  HAS_MKVALIDATOR=false
  HANDBRAKE_DISPLAY=""

  if tool="$(resolve_configured_tool "$TOOL_FFMPEG" ffmpeg)" || tool="$(discover_binary ffmpeg)"; then
    FFMPEG_CMD=("$tool")
  else
    failed=1
  fi

  if tool="$(resolve_configured_tool "$TOOL_FFPROBE" ffprobe)" || tool="$(discover_binary ffprobe)"; then
    FFPROBE_CMD=("$tool")
  else
    failed=1
  fi

  if discover_handbrake_cli; then
    :
  else
    HANDBRAKE_DISPLAY=""
    failed=1
  fi

  if tool="$(resolve_configured_tool "$TOOL_MKVPROPEDIT" mkvpropedit)" || tool="$(discover_binary mkvpropedit)"; then
    MKVPROPEDIT_CMD=("$tool")
  else
    failed=1
  fi

  if tool="$(resolve_configured_tool "$TOOL_MKVMERGE" mkvmerge)" || tool="$(discover_binary mkvmerge)"; then
    MKVMERGE_CMD=("$tool")
  else
    failed=1
  fi

  if tool="$(resolve_configured_tool "$TOOL_MKVALIDATOR" mkvalidator)" || tool="$(discover_binary mkvalidator)"; then
    MKVALIDATOR_CMD=("$tool")
    HAS_MKVALIDATOR=true
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    failed=1
  fi

  if ! report_tool_checklist; then
    failed=1
  fi

  if [ "$failed" -ne 0 ]; then
    err "Install the missing required tools above, then re-run (or use --check-tools)."
    return 1
  fi

  if [ "$HAS_MKVALIDATOR" = true ]; then
    log "mkvalidator: ${MKVALIDATOR_CMD[*]} (Matroska structure checks enabled)"
  else
    warn "mkvalidator not found — EBML bounds still run; optional: copy Linux x86_64 binary to ~/.local/bin/mkvalidator"
  fi

  log "Platform: $PLATFORM | shell: $(shell_name) | ffmpeg=${FFMPEG_CMD[*]} | HandBrake=${HANDBRAKE_DISPLAY} | search=${TEXT_SEARCH_DISPLAY:-?} | pkg=${PACKAGE_MANAGER:-none}"
  configure_sudo_wsl_handbrake
  detect_handbrake_cli_capabilities
}

detect_handbrake_cli_capabilities() {
  local hb_help=""
  HB_SUPPORTS_KEEP_SUBNAME=false
  hb_help="$(run_handbrake --help 2>&1)" || true
  if search_ci 'keep-subname' <<<"$hb_help"; then
    HB_SUPPORTS_KEEP_SUBNAME=true
  else
    log "HandBrakeCLI has no --keep-subname (older build) — omitting that flag"
  fi
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

  # Portable awk (macOS BSD awk has no GNU match(..., array) capture groups).
  # GNU-only match() was aborting this pipe on macOS and, with pipefail, failing every encode.
  _handbrake_exec "${hb_cmd[@]}" 2>&1 | awk -v label="$label" '
    /^Progress: / {
      buf = substr($0, index($0, "{"))
      while (buf !~ /\}/ && (getline line) > 0) {
        buf = buf line
      }
      if (buf ~ /"State": "WORKING"/) {
        pct = 0
        eta = ""
        if (match(buf, /"Progress": ?[0-9.]+/)) {
          n = substr(buf, RSTART, RLENGTH)
          sub(/"Progress": ?/, "", n)
          pct = n * 100
        }
        if (match(buf, /"ETASeconds": ?[0-9]+/)) {
          n = substr(buf, RSTART, RLENGTH)
          sub(/"ETASeconds": ?/, "", n)
          if (n + 0 > 0) {
            eta = sprintf(" ETA %dm %ds", int(n / 60), int(n % 60))
          }
        }
        printf "\033[0;32m[convert]\033[0m %s: %.1f%%%s\r", label, pct, eta > "/dev/stderr"
        fflush()
      }
      if (buf ~ /"State": "WORKDONE"/) {
        err = 0
        if (match(buf, /"Error": ?[0-9]+/)) {
          n = substr(buf, RSTART, RLENGTH)
          sub(/"Error": ?/, "", n)
          err = n + 0
        }
        if (err != 0) {
          printf "\033[0;32m[convert]\033[0m %s: failed (error %d)\n", label, err > "/dev/stderr"
        } else {
          printf "\033[0;32m[convert]\033[0m %s: complete\n", label > "/dev/stderr"
        }
        fflush()
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
run_mkvalidator() { "${MKVALIDATOR_CMD[@]}" "$@"; }

in_progress_flag_path() {
  local src="$1"
  local dir title
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src")"
  printf '%s/%s.%s' "$dir" "$title" "$IN_PROGRESS_FLAG_SUFFIX"
}

# Place a visible per-file semaphore beside the source while encode/remux is underway.
# Left behind on interrupt/crash so humans know that title's .AV1.mkv / .x265.mkv may be partial.
place_in_progress_flag() {
  local src="$1"
  local idx="${2:-}"
  local flag dir title
  [ "$DRY_RUN" = true ] && return 0
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src")"
  flag="$(in_progress_flag_path "$src")"
  mkdir -p -- "$dir" 2>/dev/null || true
  if [ -f "$flag" ]; then
    warn "Found leftover ${title}.${IN_PROGRESS_FLAG_SUFFIX} — prior run may have left partial .AV1.mkv/.x265.mkv for this title"
  fi
  cat >"$flag" <<EOF
convert-v4 IN PROGRESS
version=$VERSION
pid=$$
host=$(hostname 2>/dev/null || echo unknown)
started_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
job_index=${idx:-}
title=$title
source=$src

If you see this file, the convert job for this title was interrupted or is still running.
Delete ${title}.AV1.mkv and/or ${title}.x265.mkv here (not the original) before trusting
or re-running convert for this title.
EOF
}

clear_in_progress_flag() {
  local src="$1"
  local flag
  [ "$DRY_RUN" = true ] && return 0
  flag="$(in_progress_flag_path "$src")"
  [ -f "$flag" ] || return 0
  rm -f -- "$flag"
}

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
  # Keep CONVERT_JOB_TOTAL numeric only (pipeline may pass "?" as display total).
  if [[ "$total" =~ ^[0-9]+$ ]]; then
    CONVERT_JOB_TOTAL="$total"
  fi
  place_in_progress_flag "$src" "$idx"
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
  clear_in_progress_flag "$src"
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
  AMD_ENCODE_BACKEND=""
  AMD_VAAPI_DEVICE=""

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
        if ! _detect_amd_vce_via_handbrake; then
          AMD_ENCODE_BACKEND=handbrake
          log "AMD VCE/VCN capability forced (CONVERT_FORCE_AMD_VCE); HandBrake/VAAPI probe inconclusive"
        fi
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
    if [ "${AMD_ENCODE_BACKEND:-}" = vaapi ]; then
      log "Active encoder: AMD VCN via VAAPI (hevc_vaapi on ${AMD_VAAPI_DEVICE})"
    else
      log "Active encoder: AMD VCE/VCN"
    fi
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
  if ! _handbrake_help_lists_qsv "$hb_help"; then
    return 1
  fi

  if ! _probe_qsv_encode_available; then
    warn "HandBrake reports QSV but a short qsv_h265 probe failed — using software encoders"
    warn "Dual-GPU Intel Macs under Linux often need native macOS (VideoToolbox) for hardware encode"
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

  AMD_ENCODE_BACKEND=""
  AMD_VAAPI_DEVICE=""

  hb_help="$(run_handbrake --help 2>&1)" || true
  if search_cie 'vce_h265|vce_h264|vcn_h265|vcn_h264' <<<"$hb_help"; then
    HAS_AMD_VCE=true
    AMD_ENCODE_BACKEND=handbrake
    log "HandBrake reports AMD VCE/VCN (vce_h265); no hardware decode in HandBrake"
    return 0
  fi

  # Fedora/mesa: HandBrake often lacks VCN (needs proprietary AMF). Use VAAPI on amdgpu.
  if _detect_amd_vaapi_encode; then
    HAS_AMD_VCE=true
    AMD_ENCODE_BACKEND=vaapi
    log "AMD VCN via VAAPI (ffmpeg hevc_vaapi on $AMD_VAAPI_DEVICE; HandBrake has no vce/vcn)"
    return 0
  fi

  return 1
}

_detect_videotoolbox_via_handbrake() {
  local hb_help

  hb_help="$(run_handbrake --help 2>&1)" || return 1
  if ! search_cie 'vt_h265' <<<"$hb_help"; then
    if search_cie 'vt_h264' <<<"$hb_help"; then
      log "HandBrake has vt_h264 only (no vt_h265) — HEVC will use software x265"
    fi
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

_apply_nvenc_av1_tune_override() {
  local tune="${1:-}"
  tune="$(to_lower "$tune")"
  case "$tune" in
    hq|uhq)
      NVENC_AV1_TUNE="$tune"
      log "NVENC AV1 tune: $NVENC_AV1_TUNE (forced)"
      return 0
      ;;
    "")
      return 1
      ;;
    *)
      warn "Invalid NVENC AV1 tune '$tune' — expected hq or uhq; will auto-probe"
      return 1
      ;;
  esac
}

detect_nvenc_av1_tune() {
  local tmp probe_out probe_log saved_cuda rc
  local -a hb_args=()
  local forced_tune="${NVENC_AV1_TUNE_OVERRIDE:-${CONVERT_NVENC_AV1_TUNE:-}}"

  NVENC_AV1_TUNE=hq
  if [ "$USE_NVIDIA_ENCODE" = false ]; then
    return 0
  fi

  if _apply_nvenc_av1_tune_override "$forced_tune"; then
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    log "NVENC AV1 tune probe skipped (--dry-run) — using tune=hq"
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
    --largest-first) LARGEST_FIRST=true; shift ;;
    --pipeline) FORCE_PIPELINE=true; shift ;;
    --encode-batch) ENCODE_INSPECT_BATCH_SIZE="$2"; shift 2 ;;
    --skip-bakeoff) SKIP_BAKEOFF=true; shift ;;
    --nvenc-av1-tune) NVENC_AV1_TUNE_OVERRIDE="$2"; shift 2 ;;
    --prefer-intel-qsv) CONVERT_PREFER_INTEL_QSV=1; shift ;;
    --prefer-amd-vce) CONVERT_PREFER_AMD_VCE=1; shift ;;
    --no-enforce-mount) ENFORCE_CIFS_0777=false; shift ;;
    --mount-share)
      CONVERT_CIFS_MOUNT_SRC="${2%%:*}"
      CONVERT_CIFS_MOUNT_DST="${2#*:}"
      ENFORCE_CIFS_0777=true
      shift 2
      ;;
    --mount-credentials) CONVERT_CIFS_CREDENTIALS="$2"; shift 2 ;;
    --ffmpeg) TOOL_FFMPEG="$2"; shift 2 ;;
    --ffprobe) TOOL_FFPROBE="$2"; shift 2 ;;
    --handbrake) TOOL_HANDBRAKE="$2"; shift 2 ;;
    --mkvpropedit) TOOL_MKVPROPEDIT="$2"; shift 2 ;;
    --mkvmerge) TOOL_MKVMERGE="$2"; shift 2 ;;
    --mkvalidator) TOOL_MKVALIDATOR="$2"; shift 2 ;;
    --check-tools) CHECK_TOOLS_ONLY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

detect_platform
init_shell_compat

if [ "$CHECK_TOOLS_ONLY" = true ]; then
  init_text_search || exit 1
  discover_tools || exit 1
  log "Tool check complete — all required tools present."
  exit 0
fi

SEARCH_PATH="$(canonical_path "$SEARCH_PATH")"
JOB_ROOT="$SEARCH_PATH"

if [ -n "${CONVERT_CIFS_MOUNT_SRC:-}" ] && [ -n "${CONVERT_CIFS_MOUNT_DST:-}" ]; then
  ensure_cifs_mount_for_path "$CONVERT_CIFS_MOUNT_DST" || exit 1
fi

if [ ! -d "$SEARCH_PATH" ]; then
  ensure_cifs_mount_for_path "$SEARCH_PATH" || true
fi
if [ ! -d "$SEARCH_PATH" ]; then
  err "Path not found: $SEARCH_PATH"
  exit 1
fi

ensure_cifs_mount_for_path "$SEARCH_PATH" || exit 1

init_text_search || exit 1
discover_tools || exit 1

resolve_job_sidecar_paths

assert_script_name_matches_version() {
  local base
  base="$(basename "$_CONVERT_V4_SCRIPT_PATH")"
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

# Populate nameref array with find predicates for VIDEO_EXTS: ( -iname '*.avi' -o ... )
build_find_video_pred() {
  local -n _pred="$1"
  local e first=1
  _pred=( '(' )
  for e in "${VIDEO_EXTS[@]}"; do
    if [ "$first" -eq 1 ]; then
      first=0
    else
      _pred+=( -o )
    fi
    _pred+=( -iname "*.${e}" )
  done
  _pred+=( ')' )
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
  MKV_STRUCTURE_CACHE_FILE="$JOB_SIDECAR_DIR/mkv_structure_ok.tsv"
  CORRUPT_FILES_LOG="$JOB_SIDECAR_DIR/corrupt_files.txt"
  BAD_SOURCES_LOG="$JOB_SIDECAR_DIR/bad_sources.txt"
  RECONVERT_FILES_LOG="$JOB_SIDECAR_DIR/reconvert_files.txt"
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
  if [ "${CONVERT_SCAN_PID:-0}" -gt 0 ] 2>/dev/null; then
    kill "$CONVERT_SCAN_PID" 2>/dev/null || true
    wait "$CONVERT_SCAN_PID" 2>/dev/null || true
    CONVERT_SCAN_PID=0
  fi
  warn "Interrupted — resume state saved at job ${RESUME_LAST_INDEX:-0}: ${RESUME_LAST_SOURCE:-unknown}"
  if [ -n "${RESUME_LAST_SOURCE:-}" ]; then
    warn "Left $(canonical_title_from_source "$RESUME_LAST_SOURCE").${IN_PROGRESS_FLAG_SUFFIX} — delete that title's partial .AV1.mkv/.x265.mkv before trusting them"
  fi
  resume_persist_state "interrupted"
  exit 130
}

find_videos_under() {
  local root="$1"
  local -a pred=()
  build_find_video_pred pred
  find "$root" -type f "${pred[@]}" \
    ! -iname '*.AV1.mkv' ! -iname '*.x265.mkv' 2>/dev/null
}

find_convert_videos_under() {
  local root="$1"
  local -a pred=()
  build_find_video_pred pred
  find "$root" -type f "${pred[@]}" 2>/dev/null
}

find_videos_at_root() {
  local root="$1"
  local -a pred=()
  build_find_video_pred pred
  find "$root" -maxdepth 1 -type f "${pred[@]}" \
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
    echo "dry_run: $DRY_RUN | organize: $DO_ORGANIZE | convert: $DO_CONVERT | skip_av1: $SKIP_AV1 | skip_x265: $SKIP_X265 | nvidia: $HAS_NVIDIA | intel_qsv: $HAS_INTEL_QSV | amd_vce: $HAS_AMD_VCE | amd_backend: ${AMD_ENCODE_BACKEND:-none} | videotoolbox: $HAS_VIDEOTOOLBOX | active_encode: $ACTIVE_ENCODE_MODE | hw_decode: ${HW_DECODE_NAME:-none}"
    echo "order: largest to smallest"
    if [ "$DRY_RUN" = true ]; then
      echo "inspect: name | video format | length | resolution (no conversion)"
    fi
    if [ -f "$JOB_SIDECAR_DIR/convert-v4.state" ] && [ "$NO_RESUME" = false ]; then
      echo "resume: convert-v4.state present (auto-resume on convert)"
    fi
  } >>"$MASTER_LOG_FILE" 2>/dev/null || {
    warn "Master log disabled — could not write $MASTER_LOG_FILE"
    warn "Try: export CONVERT_LOG_DIR=\"\$HOME/convert-v4-logs\""
  }
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
  local src="$1"
  local dur
  dur="$(run_ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$src" 2>/dev/null || true)"
  if [ -n "$dur" ] && awk -v d="$dur" 'BEGIN { exit !(d+0 > 0) }'; then
    printf '%s' "$dur"
    return 0
  fi
  # Legacy/transport streams sometimes omit format duration; use primary video stream.
  dur="$(run_ffprobe -v error -select_streams v:0 -show_entries stream=duration \
    -of default=noprint_wrappers=1:nokey=1 "$src" 2>/dev/null || true)"
  if [ -n "$dur" ] && awk -v d="$dur" 'BEGIN { exit !(d+0 > 0) }'; then
    printf '%s' "$dur"
    return 0
  fi
  printf '0'
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
  local quick="${3:-false}"
  local av1_out x265_out

  av1_out="$(av1_output_path "$src")"
  x265_out="$(x265_output_path "$src")"
  if [ ! -f "$av1_out" ] && [ ! -f "$x265_out" ]; then
    return 1
  fi

  if [ -f "$av1_out" ] && validate_mkv_output "$src" "$av1_out" "$hb_dur" "$quick"; then
    printf '%s' "$av1_out"
    return 0
  fi

  if [ -f "$x265_out" ] && validate_mkv_output "$src" "$x265_out" "$hb_dur" "$quick"; then
    printf '%s' "$x265_out"
    return 0
  fi
  return 1
}

has_complete_canonical_output() {
  local src="$1"
  local hb_dur="${2:-}"
  local quick="${3:-false}"
  find_complete_canonical_output "$src" "$hb_dur" "$quick" >/dev/null
}

clear_incomplete_canonical_outputs() {
  local src="$1"
  local hb_dur="${2:-}"
  local av1_out x265_out

  av1_out="$(av1_output_path "$src")"
  if [ -f "$av1_out" ]; then
    MKV_VALIDATE_DEFERRED=false
    if ! validate_mkv_output "$src" "$av1_out" "$hb_dur"; then
      if [ "$MKV_VALIDATE_DEFERRED" = true ]; then
        warn "Deferred mkvalidator for $av1_out — leaving file for full structure check"
      else
        flag_bad_processed_output "$src" "$av1_out" "invalid/incomplete AV1 output"
      fi
    fi
  fi

  x265_out="$(x265_output_path "$src")"
  if [ -f "$x265_out" ]; then
    MKV_VALIDATE_DEFERRED=false
    if ! validate_mkv_output "$src" "$x265_out" "$hb_dur"; then
      if [ "$MKV_VALIDATE_DEFERRED" = true ]; then
        warn "Deferred mkvalidator for $x265_out — leaving file for full structure check"
      else
        flag_bad_processed_output "$src" "$x265_out" "invalid/incomplete x265 output"
      fi
    fi
  fi
}

# During scan: accept good outputs; delete truly bad processed MKVs; queue deferred/missing.
# Returns 0 if source should be queued for convert/reconvert; 1 if skip (complete or bad source).
inspect_existing_outputs_for_queue() {
  local src="$1"
  local av1_out x265_out

  av1_out="$(av1_output_path "$src")"
  x265_out="$(x265_output_path "$src")"

  if [ -f "$av1_out" ]; then
    MKV_VALIDATE_DEFERRED=false
    if validate_mkv_output "$src" "$av1_out" "" true; then
      return 1
    fi
    if [ "$MKV_VALIDATE_DEFERRED" = true ]; then
      return 0
    fi
    flag_bad_processed_output "$src" "$av1_out" "invalid processed AV1 (scan)"
  fi

  if [ -f "$x265_out" ]; then
    MKV_VALIDATE_DEFERRED=false
    if validate_mkv_output "$src" "$x265_out" "" true; then
      return 1
    fi
    if [ "$MKV_VALIDATE_DEFERRED" = true ]; then
      return 0
    fi
    flag_bad_processed_output "$src" "$x265_out" "invalid processed x265 (scan)"
  fi

  return 0
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
  local filtered
  # Drop benign null-muxer DTS warnings (common on VFR/anime). The word "invalid"
  # in those lines used to false-fail validation even when ffmpeg exited 0 and
  # the same warnings appear on the original source.
  filtered="$(mktemp)"
  grep -Eiv 'non monotonically increasing dts|Application provided invalid, non monotonically increasing dts' "$errf" >"$filtered" 2>/dev/null || true
  if search_cie 'corrupt|error while decoding|invalid data found|error opening|error initializing' "$filtered"; then
    warn "Validation failed: ffmpeg reported issues in ${label}"
    cat "$filtered" >&2
    rm -f "$filtered"
    return 1
  fi
  rm -f "$filtered"
  return 0
}

mkv_structure_cache_invalidate() {
  local dst="$1"
  local cache="${MKV_STRUCTURE_CACHE_FILE:-}"
  [ -n "$cache" ] && [ -f "$cache" ] || return 0
  awk -F '\t' -v p="$dst" '$2!=p { print }' "$cache" >"${cache}.tmp" 2>/dev/null || true
  mv -f "${cache}.tmp" "$cache" 2>/dev/null || true
}

record_corrupt_mkv() {
  local dst="$1"
  local reason="${2:-structure error}"
  local logf="${CORRUPT_FILES_LOG:-}"
  [ -n "$logf" ] || logf="${JOB_SIDECAR_DIR:-.}/corrupt_files.txt"
  {
    printf '%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$dst" "$reason"
  } >>"$logf" 2>/dev/null || true
  maybe_chown_for_media_user "$logf"
}

# Delete a bad processed .AV1.mkv / .x265.mkv and flag the source for reconversion.
flag_bad_processed_output() {
  local src="$1"
  local out="$2"
  local reason="${3:-invalid processed output}"
  local logf="${RECONVERT_FILES_LOG:-}"

  [ -n "$logf" ] || logf="${JOB_SIDECAR_DIR:-.}/reconvert_files.txt"
  warn "Bad processed output — deleting and flagging for reconversion: $out ($reason)"
  {
    printf '%s\t%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$src" "$out" "$reason"
  } >>"$logf" 2>/dev/null || true
  maybe_chown_for_media_user "$logf"
  record_corrupt_mkv "$out" "$reason"
  mkv_structure_cache_invalidate "$out"
  if [ "$DRY_RUN" = true ]; then
    return 0
  fi
  rm -f -- "$out"
}

# Bad source media: never delete; log for human review and skip conversion.
flag_bad_source_for_human() {
  local src="$1"
  local reason="${2:-unplayable or corrupt source}"
  local logf="${BAD_SOURCES_LOG:-}"

  [ -n "$logf" ] || logf="${JOB_SIDECAR_DIR:-.}/bad_sources.txt"
  warn "Bad source — skipping for human processing (original kept): $src ($reason)"
  {
    printf '%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$src" "$reason"
  } >>"$logf" 2>/dev/null || true
  maybe_chown_for_media_user "$logf"
  record_skip "$src" "bad source — human review: $reason"
}

# Validate a source before convert. Disks (ISO/BDMV) are left to HandBrake title scan.
# Returns 0 if OK to process; 1 if bad (already logged/skipped).
validate_source_media() {
  local src="$1"
  local ext codec

  if is_disk_source "$src"; then
    return 0
  fi
  if is_derived_output "$src"; then
    return 0
  fi

  if [ ! -s "$src" ]; then
    flag_bad_source_for_human "$src" "empty or missing file"
    return 1
  fi

  if ! ffprobe_metadata_ok "$src" true; then
    flag_bad_source_for_human "$src" "missing duration or video stream (ffprobe)"
    return 1
  fi

  ext="$(to_lower "${src##*.}")"
  if [ "$ext" = "mkv" ] || [ "$ext" = "webm" ]; then
    if ! validate_mkv_ebml_bounds "$src"; then
      flag_bad_source_for_human "$src" "Matroska EBML/segment bounds invalid"
      return 1
    fi
    # Full mkvalidator on sources at encode time only (when available).
    if [ "$HAS_MKVALIDATOR" = true ]; then
      if ! validate_mkv_mkvalidator "$src"; then
        flag_bad_source_for_human "$src" "mkvalidator structure errors"
        return 1
      fi
    fi
  fi

  codec="$(video_codec "$src")"
  if [ -z "$codec" ] || [ "$codec" = "unknown" ]; then
    flag_bad_source_for_human "$src" "unknown/unreadable video codec"
    return 1
  fi
  return 0
}

# Quick source gate during scan (metadata + EBML only — no full mkvalidator).
source_looks_processable_quick() {
  local src="$1"
  local ext

  if is_disk_source "$src"; then
    return 0
  fi
  if is_derived_output "$src"; then
    return 0
  fi
  if [ ! -s "$src" ]; then
    flag_bad_source_for_human "$src" "empty or missing file"
    return 1
  fi
  if ! ffprobe_metadata_ok "$src" true; then
    flag_bad_source_for_human "$src" "missing duration or video stream (ffprobe)"
    return 1
  fi
  ext="$(to_lower "${src##*.}")"
  if [ "$ext" = "mkv" ] || [ "$ext" = "webm" ]; then
    if ! validate_mkv_ebml_bounds "$src"; then
      flag_bad_source_for_human "$src" "Matroska EBML/segment bounds invalid"
      return 1
    fi
  fi
  return 0
}

mkv_structure_stat_key() {
  local dst="$1"
  # size|mtime — portable via python (stat -c differs on macOS)
  python3 - "$dst" <<'PY' 2>/dev/null || return 1
import os, sys
p = sys.argv[1]
st = os.stat(p)
print(f"{st.st_size}|{int(st.st_mtime)}")
PY
}

mkv_structure_cache_hit() {
  local dst="$1"
  local key cache="${MKV_STRUCTURE_CACHE_FILE:-}"
  [ -n "$cache" ] && [ -f "$cache" ] || return 1
  key="$(mkv_structure_stat_key "$dst")" || return 1
  # key is size|mtime; line is size|mtime<TAB>path
  awk -F '\t' -v k="$key" -v p="$dst" '$1==k && $2==p { found=1; exit } END { exit !found }' "$cache" 2>/dev/null
}

mkv_structure_cache_store() {
  local dst="$1"
  local key cache="${MKV_STRUCTURE_CACHE_FILE:-}"
  [ -n "$cache" ] || return 0
  key="$(mkv_structure_stat_key "$dst")" || return 0
  mkdir -p "$(dirname "$cache")" 2>/dev/null || true
  if [ -f "$cache" ]; then
    awk -F '\t' -v p="$dst" '$2!=p { print }' "$cache" >"${cache}.tmp" 2>/dev/null || true
    mv -f "${cache}.tmp" "$cache" 2>/dev/null || true
  fi
  printf '%s\t%s\n' "$key" "$dst" >>"$cache"
  maybe_chown_for_media_user "$cache"
}

# Fast Matroska header/structure check: EBML Segment size must match EOF, and any
# SeekHead→Cues offset must lie within the file. Catches truncated remuxes that
# still pass mkvmerge --identify and ffprobe duration (duration lives in Info).
validate_mkv_ebml_bounds() {
  local dst="$1"
  local out rc
  set +e
  out="$(python3 - "$dst" <<'PY'
import os, sys

path = sys.argv[1]
size = os.path.getsize(path)

def read_vint(f):
    b = f.read(1)
    if not b:
        return None, 0
    first = b[0]
    mask = 0x80
    length = 1
    while length <= 8 and not (first & mask):
        mask >>= 1
        length += 1
    if length > 8:
        return None, 0
    val = first & (mask - 1)
    if length > 1:
        rest = f.read(length - 1)
        if len(rest) != length - 1:
            return None, 0
        for r in rest:
            val = (val << 8) | r
    return val, length

def read_id(f):
    b = f.read(1)
    if not b:
        return None, 0
    first = b[0]
    mask = 0x80
    length = 1
    while length <= 4 and not (first & mask):
        mask >>= 1
        length += 1
    if length > 4:
        return None, 0
    data = b + f.read(length - 1)
    if len(data) != length:
        return None, 0
    val = 0
    for x in data:
        val = (val << 8) | x
    return val, length

with open(path, "rb") as f:
    eid, _ = read_id(f)
    if eid != 0x1A45DFA3:
        print("missing EBML head")
        sys.exit(2)
    esize, _ = read_vint(f)
    if esize is None:
        print("bad EBML size")
        sys.exit(2)
    f.seek(esize, os.SEEK_CUR)

    sid, _ = read_id(f)
    if sid != 0x18538067:
        print("missing Segment")
        sys.exit(2)
    ssize, slen = read_vint(f)
    if ssize is None:
        print("bad Segment size")
        sys.exit(2)
    seg_data = f.tell()
    unknown = (1 << (7 * slen)) - 1
    if ssize != unknown:
        expected_end = seg_data + ssize
        if expected_end != size:
            print(f"Segment size {ssize} expects EOF {expected_end}, file is {size}")
            sys.exit(2)

    end = size if ssize == unknown else min(size, seg_data + ssize)
    while f.tell() < end:
        pos = f.tell()
        cid, _ = read_id(f)
        if cid is None:
            break
        csize, clen = read_vint(f)
        if csize is None:
            print(f"bad element size at {pos}")
            sys.exit(2)
        cstart = f.tell()
        c_unknown = (1 << (7 * clen)) - 1
        if csize != c_unknown and cstart + csize > end:
            print(f"element at {pos} extends past Segment end")
            sys.exit(2)
        if cid == 0x1F43B675:  # Cluster — stop header walk
            break
        if cid == 0x114D9B74:  # SeekHead
            seek_end = cstart + csize if csize != c_unknown else end
            while f.tell() < seek_end:
                eid2, _ = read_id(f)
                if eid2 is None:
                    break
                esz2, _ = read_vint(f)
                if esz2 is None:
                    break
                estart = f.tell()
                if eid2 == 0x4DBB:  # Seek
                    sid_v = None
                    spos = None
                    send = estart + esz2
                    while f.tell() < send:
                        kid, _ = read_id(f)
                        if kid is None:
                            break
                        ksz, _ = read_vint(f)
                        if ksz is None:
                            break
                        data = f.read(ksz)
                        if kid == 0x53AB and data:  # SeekID
                            sid_v = int.from_bytes(data, "big")
                        elif kid == 0x53AC and data:  # SeekPosition
                            spos = int.from_bytes(data, "big")
                    if sid_v == 0x1C53BB6B and spos is not None:  # Cues
                        abs_pos = seg_data + spos
                        if abs_pos < 0 or abs_pos >= size:
                            print(f"Cues SeekPosition {spos} -> {abs_pos} outside file ({size})")
                            sys.exit(2)
                f.seek(estart + esz2)
            f.seek(seek_end)
            continue
        if csize == c_unknown:
            break
        f.seek(cstart + csize)

print("ok")
sys.exit(0)
PY
)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    warn "Validation failed: Matroska structure (EBML/segment bounds): ${out:-$dst}"
    return 1
  fi
  return 0
}

validate_mkv_mkvalidator() {
  local dst="$1"
  local errf out rc
  if [ "$HAS_MKVALIDATOR" != true ]; then
    return 0
  fi
  errf="$(mktemp)"
  # --quiet --no-warn: structure/errors only (ERR* lines). Exit != 0 => corrupt.
  set +e
  run_mkvalidator --quiet --no-warn "$dst" >/dev/null 2>"$errf"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] || grep -qE '^[\r]?ERR[0-9A-Fa-f]{3}:' "$errf" 2>/dev/null; then
    warn "Validation failed: mkvalidator reported structure errors in $dst"
    # Show a few ERR lines (strip CR from mkvalidator output)
    tr -d '\r' <"$errf" | grep -E '^ERR[0-9A-Fa-f]{3}:' | head -20 >&2 || cat "$errf" >&2
    rm -f "$errf"
    return 1
  fi
  rm -f "$errf"
  return 0
}

# Header/structure validation for existing (and new) MKV outputs.
# Always: EBML segment/SeekHead bounds (fast; catches truncation mkvmerge misses).
# mkvalidator (when installed): full ERR* structure check; results cached by size+mtime.
# Quick scan without cache: if CONVERT_MKVALIDATOR_ON_QUICK=0 (default), return failure so
# the file is queued and encode-time full validation runs mkvalidator once, then caches.
validate_mkv_structure() {
  local dst="$1"
  local quick="${2:-false}"

  MKV_VALIDATE_DEFERRED=false

  if mkv_structure_cache_hit "$dst"; then
    return 0
  fi

  if ! validate_mkv_ebml_bounds "$dst"; then
    record_corrupt_mkv "$dst" "ebml_bounds"
    return 1
  fi

  if [ "$HAS_MKVALIDATOR" != true ]; then
    # No mkvalidator — EBML bounds are the structure gate; cache that.
    mkv_structure_cache_store "$dst"
    return 0
  fi

  if [ "$quick" = true ] && [ "${MKVALIDATOR_ON_QUICK}" = "0" ]; then
    # Defer full mkvalidator to encode-time skip/validate (do not delete yet).
    MKV_VALIDATE_DEFERRED=true
    return 1
  fi

  if ! validate_mkv_mkvalidator "$dst"; then
    record_corrupt_mkv "$dst" "mkvalidator"
    return 1
  fi

  mkv_structure_cache_store "$dst"
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

# Missing-metadata gate: empty/unplayable files often have no duration or no video stream.
# quiet=true: return status only (no warn / corrupt log) — used for source triage.
ffprobe_metadata_ok() {
  local dst="$1"
  local quiet="${2:-false}"
  local errf dur codec rc

  errf="$(mktemp)"
  set +e
  dur="$(run_ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$dst" 2>"$errf")"
  rc=$?
  set -e

  if [ "$rc" -ne 0 ] || search_cie 'error' "$errf"; then
    if [ "$quiet" != true ]; then
      warn "Validation failed: ffprobe error reading metadata from $dst"
      cat "$errf" >&2
    fi
    rm -f "$errf"
    return 1
  fi
  rm -f "$errf"

  if [ -z "$dur" ] || ! awk -v d="$dur" 'BEGIN { exit !(d+0 > 0) }'; then
    # Some .ts/.m2ts/.avi lack format duration but still have a playable video stream.
    dur="$(run_ffprobe -v error -select_streams v:0 -show_entries stream=duration \
      -of default=noprint_wrappers=1:nokey=1 "$dst" 2>/dev/null || true)"
  fi
  if [ -z "$dur" ] || ! awk -v d="$dur" 'BEGIN { exit !(d+0 > 0) }'; then
    if [ "$quiet" != true ]; then
      warn "Validation failed: missing/zero duration in $dst"
    fi
    return 1
  fi

  codec="$(run_ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 "$dst" 2>/dev/null || true)"
  if [ -z "$codec" ] || [ "$codec" = "unknown" ]; then
    if [ "$quiet" != true ]; then
      warn "Validation failed: no video stream mapping in $dst"
    fi
    return 1
  fi
  return 0
}

validate_mkv_metadata() {
  local dst="$1"
  if ! ffprobe_metadata_ok "$dst" false; then
    # Classify for corrupt log (best-effort).
    local dur
    dur="$(video_duration "$dst")"
    if [ -z "$dur" ] || ! awk -v d="$dur" 'BEGIN { exit !(d+0 > 0) }'; then
      record_corrupt_mkv "$dst" "missing_duration"
    else
      record_corrupt_mkv "$dst" "ffprobe_metadata"
    fi
    return 1
  fi
  return 0
}

validate_mkv_output() {
  local src="$1"
  local dst="$2"
  local src_dur_override="${3:-}"
  local quick="${4:-false}"
  local dur_src dur_dst diff pct

  if [ ! -s "$dst" ]; then
    warn "Validation failed: empty output $dst"
    record_corrupt_mkv "$dst" "empty"
    return 1
  fi

  # Metadata first: empty/unplayable files fail here without structure/decode work.
  if ! validate_mkv_metadata "$dst"; then
    return 1
  fi

  if ! run_mkvmerge --identify "$dst" >/dev/null 2>&1; then
    warn "Validation failed: mkvmerge cannot identify $dst"
    record_corrupt_mkv "$dst" "mkvmerge_identify"
    return 1
  fi

  # Structure before duration-drift/decode: truncated MKVs often still identify.
  if ! validate_mkv_structure "$dst" "$quick"; then
    return 1
  fi

  if [ -n "$src_dur_override" ]; then
    dur_src="$src_dur_override"
  else
    dur_src="$(video_duration "$src")"
  fi
  dur_dst="$(video_duration "$dst")"
  # Destination duration is already required by validate_mkv_metadata.
  if awk -v a="$dur_src" -v b="$dur_dst" 'BEGIN { exit !(a>0 && b>0) }'; then
    diff="$(awk -v a="$dur_src" -v b="$dur_dst" 'BEGIN { printf "%.6f", (a>b)?a-b:b-a }')"
    pct="$(awk -v d="$diff" -v a="$dur_src" 'BEGIN { if (a<=0) print 100; else print (d/a)*100 }')"
    if awk -v p="$pct" 'BEGIN { exit !(p>3.0) }'; then
      warn "Validation failed: duration drift ${pct}% (src=${dur_src}s dst=${dur_dst}s)"
      return 1
    fi
  fi

  if [ "$quick" != true ]; then
    validate_mkv_decode_windows "$dst" || return 1
  fi
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

  if [ "$SKIP_BAKEOFF" = true ]; then
    bakeoff_default_av1_encoder
    BAKEOFF_ENCODER_CHOICE[$key]="$AV1_ENCODER"
    log "Bake-off skipped (--skip-bakeoff) — profile '$key' locked: $AV1_ENCODER"
    return 0
  fi

  if [ "$ACTIVE_ENCODE_MODE" = software ]; then
    bakeoff_default_av1_encoder
    BAKEOFF_ENCODER_CHOICE[$key]="$AV1_ENCODER"
    log "Bake-off skipped (software encode) — profile '$key' locked: $AV1_ENCODER"
    if _path_on_cifs "$src"; then
      warn "Software encode over SMB is very slow — use hardware encoders when available"
    fi
    return 0
  fi

  if [ "$USE_NVIDIA_ENCODE" = true ]; then
    AV1_ENCODER="nvenc_av1_10bit"
    BAKEOFF_ENCODER_CHOICE[$key]="$AV1_ENCODER"
    log "Bake-off skipped (NVENC) — profile '$key' locked: $AV1_ENCODER"
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
    --all-subtitles
    --subtitle-burned=none --subtitle-default=none
  )
  if [ "$HB_SUPPORTS_KEEP_SUBNAME" = true ]; then
    _out+=(--keep-subname)
  fi
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

encode_sample_av1() {
  local src="$1"
  local dst="$2"
  local hb_title="${3:-}"
  local encoder gpu
  local -a hb_args=()

  if [ "$USE_NVIDIA_ENCODE" = true ]; then
    encoder="nvenc_av1_10bit"
    gpu="$GPU_AV1"
  else
    encoder="svt_av1_10bit"
    gpu=""
  fi

  build_handbrake_args "$src" "$dst" "$encoder" hb_args "$hb_title" || return 1

  if [ -n "$gpu" ]; then
    CUDA_VISIBLE_DEVICES="$gpu" run_handbrake_with_progress "Sample: AV1" "${hb_args[@]}"
  else
    run_handbrake_with_progress "Sample: AV1" "${hb_args[@]}"
  fi
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
    if [ "${AMD_ENCODE_BACKEND:-}" = vaapi ]; then
      vaapi_hevc_encode "$src" "$dst" "$hb_title"
      return $?
    fi
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

# Extrapolate full-file size from a mid-file sample encode ratio.
extrapolate_size_from_sample() {
  local orig_full_sz="$1"
  local clip_sz="$2"
  local encoded_sample_sz="$3"
  awk -v o="$orig_full_sz" -v c="$clip_sz" -v e="$encoded_sample_sz" \
    'BEGIN { if (c <= 0) { print 0; exit }; printf "%.0f", o * (e / c) }'
}

# Sample AV1 vs x265 on a mid-file clip; predict full sizes vs orig_sz.
# Prints: skip | av1 | x265. Returns 1 when sampling/encode fails.
av1_source_reencode_sample_decision() {
  local sample_src="$1"
  local orig_sz="$2"
  local tmp clip av1_out x265_out clip_sz av1_sz x265_sz pred_av1 pred_x265 start dur pick

  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] Would sample ${SAMPLE_SECONDS}s mid-file; compare predicted AV1 vs x265 vs original ($(human_size_bytes "$orig_sz"))"
    printf 'skip'
    return 0
  fi

  tmp="$(mktemp -d)"
  clip="$tmp/clip.mkv"
  av1_out="$tmp/av1.mkv"
  x265_out="$tmp/x265.mkv"

  dur="$(video_duration "$sample_src")"
  start="$(sample_start_middle "$dur")"
  log "AV1 source sample: ${SAMPLE_SECONDS}s from middle (start=${start}s of ${dur}s)"

  if ! run_ffmpeg -y -nostdin -ss "$start" -t "$SAMPLE_SECONDS" -i "$sample_src" -map 0 -c copy "$clip" >/dev/null 2>&1; then
    warn "AV1 source sample: ffmpeg could not extract clip"
    rm -rf "$tmp"
    return 1
  fi
  if [ ! -s "$clip" ]; then
    warn "AV1 source sample: clip is empty"
    rm -rf "$tmp"
    return 1
  fi

  clip_sz="$(file_size_bytes "$clip")"
  encode_sample_av1 "$clip" "$av1_out" || { rm -rf "$tmp"; return 1; }
  encode_sample_x265 "$clip" "$x265_out" || { rm -rf "$tmp"; return 1; }
  [ -s "$av1_out" ] && [ -s "$x265_out" ] || { rm -rf "$tmp"; return 1; }

  av1_sz="$(file_size_bytes "$av1_out")"
  x265_sz="$(file_size_bytes "$x265_out")"
  pred_av1="$(extrapolate_size_from_sample "$orig_sz" "$clip_sz" "$av1_sz")"
  pred_x265="$(extrapolate_size_from_sample "$orig_sz" "$clip_sz" "$x265_sz")"

  log "AV1 source sample sizes: clip=$(human_size_bytes "$clip_sz") av1=$(human_size_bytes "$av1_sz") x265=$(human_size_bytes "$x265_sz")"
  log "Predicted full size: AV1=$(human_size_bytes "$pred_av1") x265=$(human_size_bytes "$pred_x265") original=$(human_size_bytes "$orig_sz")"

  rm -rf "$tmp"

  if awk -v a="$pred_av1" -v x="$pred_x265" -v o="$orig_sz" 'BEGIN { exit !((a >= o) && (x >= o)) }'; then
    printf 'skip'
    return 0
  fi

  pick=skip
  if awk -v p="$pred_av1" -v o="$orig_sz" 'BEGIN { exit !(p < o) }'; then
    pick=av1
  fi
  if awk -v p="$pred_x265" -v o="$orig_sz" 'BEGIN { exit !(p < o) }'; then
    if [ "$pick" = skip ]; then
      pick=x265
    elif awk -v a="$pred_av1" -v x="$pred_x265" 'BEGIN { exit !(x < a) }'; then
      pick=x265
    fi
  fi

  printf '%s' "$pick"
  return 0
}

handbrake_encode() {
  local src="$1"
  local dst="$2"
  local encoder="$3"
  local gpu="${4:-}"
  local hb_title="${5:-}"
  local -a hb_args=()

  # Linux VAAPI path when HandBrake has no vce/vcn (Fedora + mesa freeworld).
  if [ "$encoder" = "vce_h265" ] && [ "${AMD_ENCODE_BACKEND:-}" = vaapi ]; then
    vaapi_hevc_encode "$src" "$dst" "$hb_title"
    return $?
  fi

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
  case "$encoder" in
    qsv_h265|qsv_h264|qsv_av1) _configure_qsv_runtime_env ;;
  esac

  run_handbrake_with_progress "$progress_label" "${hb_args[@]}"
  local rc=$?

  if [ -n "$saved_cuda" ]; then
    export CUDA_VISIBLE_DEVICES="$saved_cuda"
  else
    unset CUDA_VISIBLE_DEVICES 2>/dev/null || CUDA_VISIBLE_DEVICES=
  fi

  # Some HandBrake builds exit 0 after rejecting unknown CLI flags and leave an empty -o file.
  if [ "$rc" -eq 0 ] && [ ! -s "$dst" ]; then
    warn "HandBrake reported success but output is missing/empty: $dst"
    rc=1
  fi
  return "$rc"
}

# ffmpeg hevc_vaapi encode (AMD VCN via mesa). Used when HandBrake lacks vce/vcn.
vaapi_hevc_encode() {
  local src="$1"
  local dst="$2"
  local hb_title="${3:-}"
  local qp bitrate af_args
  local -a ff_args=()

  if [ -n "$hb_title" ]; then
    warn "AMD VAAPI path cannot select HandBrake disc titles — falling back to software x265"
    handbrake_encode "$src" "$dst" "x265" "" "$hb_title"
    return $?
  fi

  load_encoder_profile "vce_h265" "$src" || return 1
  qp="${EP_QUALITY:-22}"
  bitrate="${EP_AUDIO_BITRATE:-$AAC_BITRATE}"

  if [ -z "${AMD_VAAPI_DEVICE:-}" ]; then
    err "AMD VAAPI device not set"
    return 1
  fi

  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] ffmpeg hevc_vaapi device=$AMD_VAAPI_DEVICE qp=$qp aac=${bitrate}k profile=$EP_PROFILE_NAME -i '$src' -o '$dst'"
    return 0
  fi

  _configure_amd_vaapi_runtime_env
  af_args="volume=${AUDIO_GAIN}"
  # Approximate HandBrake DRC with a light compressor when DRC > 1.
  if awk -v d="$AUDIO_DRC" 'BEGIN { exit !(d > 1.01) }'; then
    af_args="acompressor=threshold=-18dB:ratio=3:attack=20:release=250,volume=${AUDIO_GAIN}"
  fi

  log "Encoding (hevc_vaapi / AMD VCN on $AMD_VAAPI_DEVICE)..."
  ff_args=(
    -y -nostdin -stats -loglevel warning
    -init_hw_device "vaapi=amd:${AMD_VAAPI_DEVICE}"
    -filter_hw_device amd
    -i "$src"
    -map 0:v:0 -map 0:a? -map 0:s?
    -vf "format=nv12,hwupload"
    -c:v hevc_vaapi -rc_mode CQP -qp "$qp"
    -c:a aac -b:a "${bitrate}k" -af "$af_args"
    -c:s copy
    -f matroska
    "$dst"
  )
  # Force radeonsi on the ffmpeg process — do not rely on ambient LIBVA (QSV may set iHD).
  env LIBVA_DRIVER_NAME=radeonsi LIBVA_DRI3_DISABLE="${LIBVA_DRI3_DISABLE:-1}" \
    "${FFMPEG_CMD[@]}" "${ff_args[@]}"
  local rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$dst" ]; then
    warn "ffmpeg hevc_vaapi reported success but output is missing/empty: $dst"
    rc=1
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
  mkv_structure_cache_invalidate "$f"
  if [ "$DRY_RUN" = true ]; then
    return 0
  fi
  rm -f -- "$f"
}

process_existing_av1() {
  local src="$1"
  local dir title ext out x265_out decision encode_src ref_sz pct orig_sibling

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

  encode_src="$src"
  ref_sz="$(file_size_bytes "$src")"

  if is_derived_output "$src"; then
    orig_sibling="$(find_original_source_for_av1 "$src")"
    if [ -z "$orig_sibling" ]; then
      log "AV1 in MKV — metadata only (no original sibling): $src"
      finalize_mkv_output "$src" "$src" "$title"
      record_conversion_result "$src" ""
      return 0
    fi
    ref_sz="$(file_size_bytes "$orig_sibling")"
    encode_src="$orig_sibling"
    if ! is_oversized_av1 "$src"; then
      log "AV1 in MKV — metadata only: $src"
      finalize_mkv_output "$src" "$src" "$title"
      record_conversion_result "$src" ""
      return 0
    fi
    if [ -f "$x265_out" ]; then
      pct="$(av1_overshoot_pct_vs_original "$src")"
      log "AV1 output ${pct}% vs original — x265 replacement already exists: $x265_out"
      finalize_mkv_output "$src" "$src" "$title"
      record_skip "$src" "x265 replacement exists"
      return 0
    fi
    pct="$(av1_overshoot_pct_vs_original "$src")"
    log "AV1 output ${pct}% larger than original — sample-testing AV1 vs x265 re-encode: $src"
  else
    log "AV1 source — sample-testing whether re-encode would shrink: $src"
  fi

  if ! decision="$(av1_source_reencode_sample_decision "$encode_src" "$ref_sz")"; then
    warn "AV1 sample test failed — metadata only: $src"
    finalize_mkv_output "$src" "$src" "$title"
    record_skip "$src" "AV1 sample test failed"
    return 0
  fi

  case "$decision" in
    skip)
      if is_derived_output "$src"; then
        pct="$(av1_overshoot_pct_vs_original "$src")"
        log "Sample predicts no smaller output — keeping AV1 (${pct}% vs original)"
        finalize_mkv_output "$src" "$src" "$title"
        record_conversion_result "$src" ""
      else
        log "Skip — sample predicts re-encode would not shrink: $src"
        finalize_mkv_output "$src" "$src" "$title"
        record_skip "$src" "AV1 re-encode sample predicts no size win"
      fi
      return 0
      ;;
    av1)
      log "Sample predicts AV1 re-encode would shrink — proceeding with AV1"
      try_av1_convert "$encode_src"
      return $?
      ;;
    x265)
      log "Sample predicts x265 re-encode would shrink — proceeding with x265"
      try_x265_convert "$encode_src"
      return $?
      ;;
    *)
      warn "AV1 sample returned unknown decision '$decision' — metadata only: $src"
      finalize_mkv_output "$src" "$src" "$title"
      record_skip "$src" "AV1 sample test failed"
      return 0
      ;;
  esac
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
    if ! handbrake_encode "$src" "$out" "$encoder" "" "$hb_title"; then
      remove_output_only "$out"
      warn "qsv_h265 failed — falling back to software x265: $src"
      encoder="x265"
      handbrake_encode "$src" "$out" "$encoder" "" "$hb_title" || { remove_output_only "$out"; return 1; }
    fi
  elif [ "$USE_VT_ENCODE" = true ]; then
    encoder="vt_h265"
    log "x265 transcode (vt_h265, VideoToolbox): $src"
    handbrake_encode "$src" "$out" "$encoder" "" "$hb_title" || { remove_output_only "$out"; return 1; }
  elif [ "$USE_AMD_VCE_ENCODE" = true ]; then
    if [ "${AMD_ENCODE_BACKEND:-}" = vaapi ]; then
      log "x265 transcode (hevc_vaapi, AMD VCN on $AMD_VAAPI_DEVICE): $src"
    else
      log "x265 transcode (vce_h265, AMD VCE/VCN): $src"
    fi
    encoder="vce_h265"
    if ! handbrake_encode "$src" "$out" "$encoder" "" "$hb_title"; then
      remove_output_only "$out"
      warn "AMD HEVC encode failed — falling back to software x265: $src"
      encoder="x265"
      handbrake_encode "$src" "$out" "$encoder" "" "$hb_title" || { remove_output_only "$out"; return 1; }
    fi
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

  if ! validate_source_media "$src"; then
    return 0
  fi

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
    done < <(find_videos_at_root "$SEARCH_PATH")
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

# Fast find-only count (no ffprobe). Stops early once threshold is reached.
convert_estimate_scan_total() {
  local -a roots=()
  local shard total=0

  get_scan_roots roots
  for shard in "${roots[@]}"; do
    while IFS= read -r _; do
      total=$((total + 1))
      if [ "$total" -ge "$PIPELINE_FILE_THRESHOLD" ]; then
        printf 'over'
        return 0
      fi
    done < <(find_convert_videos_under "$shard")
  done

  if [ "$NO_SHARD" = false ] && [ "${#roots[@]}" -gt 1 ]; then
    while IFS= read -r _; do
      total=$((total + 1))
      if [ "$total" -ge "$PIPELINE_FILE_THRESHOLD" ]; then
        printf 'over'
        return 0
      fi
    done < <(find_videos_at_root "$SEARCH_PATH")
  fi

  printf '%s' "$total"
}

# 0 = pipeline, 1 = batch (largest-first).
convert_library_use_pipeline() {
  local estimate

  if [ "$FORCE_PIPELINE" = true ]; then
    log "Convert mode: pipeline inspect→encode (forced --pipeline)"
    return 0
  fi
  if [ "$LARGEST_FIRST" = true ]; then
    log "Convert mode: batch largest-first (forced --largest-first)"
    return 1
  fi

  if _path_on_cifs "$SEARCH_PATH"; then
    log "Convert mode: pipeline (CIFS/SMB mount — inspect waves of $ENCODE_INSPECT_BATCH_SIZE)"
    return 0
  fi

  log "Estimating file count (find-only) to pick convert mode (threshold=$PIPELINE_FILE_THRESHOLD)..."
  estimate="$(convert_estimate_scan_total)"
  if [ "$estimate" = over ]; then
    log "Convert mode: pipeline (inspect waves of $ENCODE_INSPECT_BATCH_SIZE, encode one-at-a-time; library has ≥$PIPELINE_FILE_THRESHOLD files)"
    return 0
  fi
  log "Convert mode: batch largest-first ($estimate file(s) — under $PIPELINE_FILE_THRESHOLD)"
  return 1
}

# True when this source should enter the convert queue (quick output check during scan).
convert_file_should_queue() {
  local f="$1"
  local skip_reason

  if is_derived_output "$f"; then
    [ "$SKIP_AV1" = true ] && return 1
    needs_oversized_av1_recheck "$f"
    return $?
  fi

  is_video_file "$f" || return 1

  if ! source_looks_processable_quick "$f"; then
    return 1
  fi

  # Deletes bad processed outputs; skips queue when a valid complete output exists.
  if ! inspect_existing_outputs_for_queue "$f"; then
    return 1
  fi

  if should_skip_source_format "$f"; then
    skip_reason="$(skip_reason_for_format "$f")"
    log "Skip — $skip_reason: $f"
    record_skip "$f" "$skip_reason"
    return 1
  fi
  return 0
}

convert_log_inspect_progress() {
  local f="$1"
  local shard="${2:-}"
  local name

  CONVERT_SCAN_COUNT=$((CONVERT_SCAN_COUNT + 1))
  name="$(basename "$f")"
  if [ -n "$shard" ]; then
    log "Inspect $CONVERT_SCAN_COUNT: $name (shard: $(basename "$shard"))"
  else
    log "Inspect $CONVERT_SCAN_COUNT: $name"
  fi
}

convert_init_pipeline_files() {
  CONVERT_READY_FILE="$JOB_SIDECAR_DIR/convert-ready.queue"
  CONVERT_SCAN_DONE_FILE="$JOB_SIDECAR_DIR/convert-scan.done"
  rm -f -- "$CONVERT_READY_FILE" "$CONVERT_SCAN_DONE_FILE"
  : >"$CONVERT_READY_FILE"
  CONVERT_READY_OFFSET=0
  CONVERT_SCAN_COUNT=0
}

convert_append_ready_item() {
  local f="$1"
  printf '%s\n' "$f" >>"$CONVERT_READY_FILE"
  printf '%s\n' "$f" >>"$RESUME_QUEUE_FILE"
}

# Scan library in background; append eligible paths to CONVERT_READY_FILE as found.
convert_scan_producer() {
  local -a roots=() disks=()
  local f shard shard_idx=0 shard_total=0 queued=0

  trap 'touch "$CONVERT_SCAN_DONE_FILE" 2>/dev/null || true' EXIT

  get_scan_roots roots
  shard_total="${#roots[@]}"

  if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
    log "Convert scan: sharded (depth=$SHARD_DEPTH, $shard_total shard(s))"
  else
    log "Convert scan: pipeline inspect→encode (inspect runs ahead while jobs encode)"
  fi

  for shard in "${roots[@]}"; do
    shard_idx=$((shard_idx + 1))
    if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
      begin_shard_log "$shard"
      log "Convert scan shard $shard_idx/$shard_total: $shard"
    fi
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      convert_log_inspect_progress "$f" "$shard"
      if convert_file_should_queue "$f"; then
        queued=$((queued + 1))
        convert_append_ready_item "$f"
        log "Queued ($queued): $(basename "$f")"
      fi
    done < <(find_convert_videos_under "$shard")
    if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
      end_shard_log "$shard"
    fi
  done

  if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      convert_log_inspect_progress "$f" "$SEARCH_PATH"
      if convert_file_should_queue "$f"; then
        queued=$((queued + 1))
        convert_append_ready_item "$f"
        log "Queued ($queued): $(basename "$f")"
      fi
    done < <(find_videos_at_root "$SEARCH_PATH")
  fi

  discover_disk_sources disks
  for f in "${disks[@]}"; do
    convert_log_inspect_progress "$f"
    if ! inspect_existing_outputs_for_queue "$f"; then
      continue
    fi
    queued=$((queued + 1))
    convert_append_ready_item "$f"
    log "Queued disc ($queued): $(basename "$f")"
  done

  CONVERT_JOB_TOTAL="$queued"
  log "Convert scan complete: $CONVERT_SCAN_COUNT inspected, $queued queued"
  touch "$CONVERT_SCAN_DONE_FILE"
}

convert_pipeline_resume_offset() {
  local -a queue=()
  local item want_path resume_idx=-1 i=0
  local -A in_old=()

  [ "$RESUME_ACTIVE" = true ] || { printf '0'; return 0; }
  [ -n "$RESUME_LAST_SOURCE" ] || { printf '0'; return 0; }
  load_queue_snapshot queue || { printf '0'; return 0; }

  for item in "${queue[@]}"; do
    in_old["$item"]=1
  done

  case "$RESUME_LAST_STATUS" in
    completed|skipped)
      want_path=""
      for i in "${!queue[@]}"; do
        if [ "${queue[$i]}" = "$RESUME_LAST_SOURCE" ]; then
          if [ $((i + 1)) -lt "${#queue[@]}" ]; then
            want_path="${queue[$((i + 1))]}"
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
    for i in "${!queue[@]}"; do
      if [ "${queue[$i]}" = "$want_path" ]; then
        resume_idx="$i"
        break
      fi
    done
  fi

  if [ "$resume_idx" -lt 0 ]; then
    if [ "$RESUME_LAST_INDEX" -gt 0 ] && [ "$RESUME_LAST_INDEX" -le "${#queue[@]}" ]; then
      resume_idx=$((RESUME_LAST_INDEX - 1))
      if [ "$RESUME_LAST_STATUS" = completed ] || [ "$RESUME_LAST_STATUS" = skipped ]; then
        [ "$resume_idx" -lt "${#queue[@]}" ] && resume_idx=$((resume_idx + 1)) || resume_idx=-1
      fi
    fi
  fi

  if [ "$resume_idx" -lt 0 ]; then
    warn "Resume anchor not found in current queue — starting from first queued item"
    printf '0'
    return 0
  fi

  # log_err: this function's stdout is captured as the numeric resume offset.
  log_err "Resume: last job was $RESUME_LAST_STATUS on $(basename "$RESUME_LAST_SOURCE") (shard: ${RESUME_LAST_SHARD:-unknown})"
  log_err "Resume: skipping first $resume_idx queued item(s)"
  printf '%s' "$resume_idx"
}

convert_pipeline_ready_pending() {
  local ready_lines=0
  [ -f "$CONVERT_READY_FILE" ] && ready_lines="$(wc -l <"$CONVERT_READY_FILE" | tr -d ' ')"
  echo $((ready_lines - CONVERT_READY_OFFSET))
}

# Start an encode wave when N items are queued, or when scan ends with a partial wave.
convert_pipeline_should_start_batch() {
  local pending="$1"
  [ "$pending" -ge "$ENCODE_INSPECT_BATCH_SIZE" ] && return 0
  [ -f "$CONVERT_SCAN_DONE_FILE" ] && [ "$pending" -gt 0 ] && return 0
  return 1
}

convert_run_encode_job() {
  local f="$1"
  local idx="$2"
  local total_label="$3"

  CONVERT_JOB_OK=false
  begin_convert_job "$f" "$idx" "$total_label"
  if is_disk_source "$f"; then
    process_disk "$f" && CONVERT_JOB_OK=true || warn "Job failed — continuing queue: $f"
  else
    process_video "$f" && CONVERT_JOB_OK=true || warn "Job failed — continuing queue: $f"
  fi
  end_convert_job "$f" "$idx" "$total_label" "$CONVERT_JOB_OK"
}

convert_run_pipeline_jobs() {
  local resume_skip="${1:-0}"
  local -a batch=()
  local f total_label pending batch_num=0 bf ready_lines=0

  CONVERT_JOB_INDEX=0
  if [ "$RESUME_ACTIVE" = true ] && [ "${RESUME_LAST_INDEX:-0}" -gt 0 ]; then
    case "$RESUME_LAST_STATUS" in
      completed|skipped) CONVERT_JOB_INDEX="$RESUME_LAST_INDEX" ;;
      *) CONVERT_JOB_INDEX=$((RESUME_LAST_INDEX - 1)) ;;
    esac
  fi

  while true; do
    pending="$(convert_pipeline_ready_pending)"

    if ! convert_pipeline_should_start_batch "$pending"; then
      ready_lines=0
      [ -f "$CONVERT_READY_FILE" ] && ready_lines="$(wc -l <"$CONVERT_READY_FILE" | tr -d ' ')"
      if [ -f "$CONVERT_SCAN_DONE_FILE" ] && [ "$CONVERT_READY_OFFSET" -ge "$ready_lines" ]; then
        break
      fi
      if ! kill -0 "$CONVERT_SCAN_PID" 2>/dev/null && [ ! -f "$CONVERT_SCAN_DONE_FILE" ]; then
        warn "Convert scan process exited unexpectedly"
        break
      fi
      sleep 2
      continue
    fi

    batch=()
    while [ "${#batch[@]}" -lt "$ENCODE_INSPECT_BATCH_SIZE" ]; do
      pending="$(convert_pipeline_ready_pending)"
      [ "$pending" -eq 0 ] && break
      f="$(sed -n "$((CONVERT_READY_OFFSET + 1))p" "$CONVERT_READY_FILE" 2>/dev/null)" || break
      [ -n "$f" ] || break
      CONVERT_READY_OFFSET=$((CONVERT_READY_OFFSET + 1))
      # resume_skip must be numeric (convert_pipeline_resume_offset prints only digits).
      if [[ "$resume_skip" =~ ^[0-9]+$ ]] && [ "$CONVERT_READY_OFFSET" -le "$resume_skip" ]; then
        pending="$(convert_pipeline_ready_pending)"
        [ "$pending" -eq 0 ] && [ -f "$CONVERT_SCAN_DONE_FILE" ] && break
        continue
      fi
      batch+=("$f")
      pending="$(convert_pipeline_ready_pending)"
      if [ -f "$CONVERT_SCAN_DONE_FILE" ] && [ "$pending" -eq 0 ]; then
        break
      fi
    done

    [ "${#batch[@]}" -eq 0 ] && continue

    batch_num=$((batch_num + 1))
    sort_paths_by_size_desc batch
    log "Encode wave $batch_num: ${#batch[@]} item(s) (largest first; one encode at a time — inspection continues in background)"

    for bf in "${batch[@]}"; do
      CONVERT_JOB_INDEX=$((CONVERT_JOB_INDEX + 1))
      if [ -f "$CONVERT_SCAN_DONE_FILE" ] && [[ "${CONVERT_JOB_TOTAL:-}" =~ ^[1-9][0-9]*$ ]]; then
        total_label="$CONVERT_JOB_TOTAL"
      else
        total_label='?'
      fi
      convert_run_encode_job "$bf" "$CONVERT_JOB_INDEX" "$total_label"
    done
  done

  wait "$CONVERT_SCAN_PID" 2>/dev/null || true
  CONVERT_SCAN_PID=0
}

convert_library_pipeline() {
  resume_init_paths
  local resume_skip
  resume_skip="$(convert_pipeline_resume_offset)"
  convert_init_pipeline_files
  : >"$RESUME_QUEUE_FILE"

  if [ "$RESUME_ACTIVE" != true ]; then
    build_shard_snapshot "$RESUME_SHARDS_FILE"
  fi

  convert_scan_producer &
  CONVERT_SCAN_PID=$!
  log "Convert pipeline started (scan pid=$CONVERT_SCAN_PID; first encode after $ENCODE_INSPECT_BATCH_SIZE inspected item(s) queued, one encode at a time)"

  convert_run_pipeline_jobs "$resume_skip"

  if [ "$CONVERT_JOB_TOTAL" -gt 0 ] 2>/dev/null; then
    log "Convert queue finished: $CONVERT_JOB_TOTAL item(s)"
  else
    log "Convert queue finished: no items needed encoding"
  fi

  if [ "$DRY_RUN" = false ]; then
    resume_clear_state
    log "Convert queue finished — resume state cleared"
  fi

  rm -f -- "$CONVERT_READY_FILE" "$CONVERT_SCAN_DONE_FILE"
}

convert_library_batch() {
  local -a videos=() disks=() queue=() roots=()
  local f shard shard_idx=0 shard_total=0

  resume_init_paths

  get_scan_roots roots
  shard_total="${#roots[@]}"

  if [ "$NO_SHARD" = false ] && [ "$shard_total" -gt 1 ]; then
    log "Convert: sharded scan (depth=$SHARD_DEPTH, $shard_total shard(s))"
  else
    log "Convert: batch mode (--largest-first) — full inspect before first encode"
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
    done < <(find_videos_at_root "$SEARCH_PATH")
  fi

  discover_disk_sources disks

  log "Convert inspect: ${#videos[@]} video(s), ${#disks[@]} disc source(s)"
  for f in "${videos[@]}"; do
    convert_log_inspect_progress "$f"
    if convert_file_should_queue "$f"; then
      queue+=("$f")
    fi
  done

  for f in "${disks[@]}"; do
    convert_log_inspect_progress "$f"
    if ! inspect_existing_outputs_for_queue "$f"; then
      continue
    fi
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

convert_library() {
  if convert_library_use_pipeline; then
    convert_library_pipeline
  else
    convert_library_batch
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
  detect_hw_environment
  detect_nvenc_av1_tune
  init_stats_log
  trap resume_on_signal INT TERM
  log "$SCRIPT_NAME v$VERSION"
  log "Path: $SEARCH_PATH (platform=$PLATFORM shell=$(shell_name) dry_run=$DRY_RUN organize=$DO_ORGANIZE convert=$DO_CONVERT skip_av1=$SKIP_AV1 skip_x265=$SKIP_X265 shard_depth=$SHARD_DEPTH no_shard=$NO_SHARD pipeline_threshold=$PIPELINE_FILE_THRESHOLD encode_batch=$ENCODE_INSPECT_BATCH_SIZE largest_first=$LARGEST_FIRST force_pipeline=$FORCE_PIPELINE nvidia=$HAS_NVIDIA intel_qsv=$HAS_INTEL_QSV amd_vce=$HAS_AMD_VCE amd_backend=${AMD_ENCODE_BACKEND:-none} videotoolbox=$HAS_VIDEOTOOLBOX active_encode=$ACTIVE_ENCODE_MODE hw_decode=${HW_DECODE_NAME:-none})"
  log "Master log: $MASTER_LOG_FILE (job_root_writable=$JOB_ROOT_WRITABLE)"

  if [ "$DO_ORGANIZE" = true ] && [ "$DO_CONVERT" = true ]; then
    warn "Both organize and convert enabled — for large TV libraries use --convert-only to skip organize"
  fi
  if [ "$PLATFORM" = wsl ] && [ "$ACTIVE_ENCODE_MODE" = software ]; then
    warn "WSL + software encode over SMB is extremely slow — install Windows HandBrake for NVENC/QSV"
    warn "  --handbrake '/mnt/c/Program Files/HandBrake/HandBrakeCLI.exe'"
  fi
  if [ "$DRY_RUN" = true ] && [ "$DO_CONVERT" = true ]; then
    warn "Dry-run: no files will be encoded (inspection/organize only)"
  fi

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
    log "Phase 2: transcode / remux to MKV (auto: batch <${PIPELINE_FILE_THRESHOLD} files; else pipeline waves of ${ENCODE_INSPECT_BATCH_SIZE})"
    convert_library
  fi

  finalize_stats_log
  trap - INT TERM
  log "Done. Original files were not deleted."
}

main "$@"
