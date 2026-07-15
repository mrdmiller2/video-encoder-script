#!/usr/bin/env bash
# convert-v5.0.8.sh — Organize movie folders, transcode TV/movies to AV1/x265 MKV.
# Version: 5.0.8
#
# v5.0.8: fixed the 1080p-upscale trigger catching near-720p sources it
#   shouldn't. Many "720p" releases are letterboxed/cropped and report a
#   height a little under 720 (e.g. 1280x700, 1280x716) -- the old "< 720"
#   cutoff upscaled these along with genuine SD. New threshold is 700, so
#   only real SD (480p/540p/576p/320p, etc.) triggers the upscale; anything
#   from ~700p up (including near-720p variants) is left at native size.
#
# v5.0.7: three fixes from real-world large-library operation.
#   1. Streaming-optimized MKV output: every finalized file is remuxed
#      through mkvmerge (proper SeekHead/Cues) instead of trusting whatever
#      the live encoder muxer wrote -- faster seeking/scrubbing and instant
#      duration lookup for players.
#   2. --clean-junk / --clean-junk-apply: scans --path for zero-byte or
#      empty .AV1.mkv/.x265.mkv/.merged.mkv, and stale IN_PROGRESS flags with
#      no live process. Report-only by default; --clean-junk-apply deletes.
#   3. Per-directory file-list cache fixes the multi-hour restart-enumeration
#      cost on large TV regions (e.g. Television/American, ~1,000 show
#      folders / 40k+ episodes): each immediate subdirectory's file list is
#      cached against that subdirectory's own mtime, so unchanged folders
#      are never re-walked on restart -- independent of --shard-depth/
#      --no-shard/--name-glob, since those control job-queue grouping, not
#      how many directories get scanned.
#   4. Per-folder done/in-progress semaphores (.convert-v5-folder-done /
#      .convert-v5-folder-inprogress): once every video in a folder has a
#      confirmed output, the folder is marked done and skipped entirely on
#      future runs -- not even a cache lookup. A folder's mtime advancing
#      past the done-flag invalidates it automatically (new/changed file);
#      --ignore-done-folders forces a full recheck regardless. The
#      in-progress flag is advisory (not a lock) -- a hint when multiple
#      fleet machines share the same NFS library. The completeness check
#      after each file only uses cheap stat-based signals (done-log + bare
#      output existence), never ffprobe/mkvalidator, since it re-checks every
#      sibling in a folder after each completion -- an expensive per-file
#      check there would be O(n^2) validation calls across a large folder.
#
# v5.0.6: fixed a correctness bug where a Dolby Vision source falling back to
#   x265 could take the "already HEVC, just remux" stream-copy shortcut,
#   which copies the original DoVi/RPU tagging verbatim instead of stripping
#   it -- silently defeating the DoVi->HDR10 conversion for any DoVi title
#   that lands on the x265 path (e.g. after an AV1 attempt fails/rejects).
#   DoVi sources now always take the real re-encode path.
#
# v5.0.4: two fixes from real playback A/B testing against v4 outputs.
#   1. Removed an explicit SVT-AV1 tune=0 (perceptual/VQ tune) that v4 never
#      set — v4 relied on the encoder's sharper PSNR-oriented default. tune=0
#      was introduced in v5.0.0 and caused a visible softness vs. v4/source.
#   2. ffmpeg audio path now applies a dialogue-clarity filter (dynaudnorm +
#      static gain) matching v4's HandBrake -D/--gain dynamic-range-compression
#      behavior, which v5's ffmpeg engine had dropped entirely.
#   3. --prefer-hw NVENC AV1 now uses the probed NVENC_AV1_TUNE (uhq when the
#      driver/GPU supports it, matching v4) instead of a hardcoded tune=hq.
#
# v5.0.3: multi-part sources (Part1/Part2, CD1/CD2, Disc1/Disc2, ...) are
#   detected, validated for compatibility (ffprobe: codec/resolution/pix_fmt/
#   fps), and merged via mkvmerge append into '{Title}.merged.mkv' before
#   encoding — output plays as one continuous file, not two. Merges are
#   cached (size+mtime fingerprint) and skipped when parts are unchanged.
#   Incompatible or failed merges are flagged (multipart_mismatch.txt) and
#   left as separate sources rather than silently concatenated.
#
# v5.0.2: -p accepts a single file directly, in addition to a directory or a
#   directory + trailing glob (e.g. '.../American/A*'). Single-file mode skips
#   organize/sharding/name-glob and puts sidecars in the file's parent dir.
#
# v5.0.1: set-based resume. convert-v5.done records every durably finished
#   source (status+size+mtime); restarts skip unchanged finished files before
#   any ffprobe/validation instead of relying on the positional queue anchor.
#   Fixes silently-lost work when the size-sorted queue shifts between runs and
#   makes restarts on large libraries start encoding in seconds, not hours.
#   --no-resume bypasses the fast path (forces full re-inspection).
#
# v5: ffmpeg encode engine with per-title VMAF-targeted CRF search (libsvtav1 /
#   libx265). Quality floor instead of fixed quality: each title is sampled and
#   encoded at the highest CRF that still meets the VMAF target (NEG model,
#   default 94.0 ~ visually transparent vs. source; 4K uses the 4K model at 95).
#   Falls back: ab-av1 (if installed) > internal libvmaf search > fixed CRF.
#   HDR is never VMAF-searched (unreliable on PQ/HLG) — conservative fixed CRF.
#   Dolby Vision is stripped to plain HDR10 (Plex/VLC-safe): P7/P8 keep the
#   HDR10 base layer + static metadata; P5 is converted via libplacebo.
#   HandBrake remains the engine for disc sources (ISO/BDMV title selection)
#   and via --engine handbrake for everything.
#   Hardware detection is functional-probe based (1s test encode per encoder):
#   NVIDIA NVENC / Intel QSV / AMD VAAPI-AMF / Apple VideoToolbox, per-codec.
#   --prefer-hw uses hardware encoders (speed over size; fixed quality).
#   Startup audits the library path mount (NFS/CIFS options) and recommends
#   tuning when suboptimal (advisory only).
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
#   Sources shorter than 700p (SD: 480/540/576p, etc.) are upscaled to 1920x1080 — near-720p
#   sources (letterboxed/cropped ~700-719p) are left alone. Size growth is expected up to
#     UPSCALE_MAX_OVERSHOOT_PCT (default 50%); beyond that, reject and keep the original.
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
#   AV1 sample decision uses log_err (stdout is captured as skip|av1|x265 only).
#   ./convert-v4.0.8.sh --path /mnt/BigMomma/Media/Movies/Chinese
#   ./convert-v4.0.8.sh -p /mnt/BigMomma/Media/Movies/English/D --dry-run
#   ./convert-v4.0.8.sh -p /path --organize-only
#   ./convert-v4.0.8.sh -p /path --convert-only
#   ./convert-v4.0.8.sh -p /mnt/Movies --shard-depth 1   # per top-level subdir find (default)
#   ./convert-v4.0.8.sh -p /mnt/Movies --no-shard          # monolithic find (large trees)
#   Narrow a large shelf by prefix/glob (quote globs so the shell does not expand them):
#     ./convert-v4.0.52.sh -p '/mnt/BabyBear/Media/Television/American/A*' --convert-only
#     ./convert-v4.0.52.sh -p /mnt/.../American -g 'Al*' --convert-only
#   Single show folder (no movement for TV episodes):
#     ./convert-v4.0.52.sh -p '/mnt/BabyBear/Media/Television/American/Alf' --convert-only
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
#   Source MKV structure errors (mkvalidator / EBML): attempt ffmpeg/mkvmerge remux repair
#     in place before encode; on remux failure, flag like any other bad source (human review).
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

VERSION="5.0.14"
SCRIPT_NAME="convert-v${VERSION}.sh"
SEARCH_PATH="."
DRY_RUN=false
DO_ORGANIZE=true
DO_CONVERT=true
SKIP_AV1=false
SKIP_X265=false
SHARD_DEPTH=1
NO_SHARD=false
# Optional basename glob for shard dirs under --path (e.g. A*, Al*). Empty = all.
NAME_GLOB=""
NAME_GLOB_CI=false
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
# When source height < 720 (1080p upscale path), allow more growth vs source before reject.
UPSCALE_MAX_OVERSHOOT_PCT="${CONVERT_UPSCALE_MAX_OVERSHOOT_PCT:-50}"
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
CLEAN_JUNK=false
CLEAN_JUNK_APPLY=false
IGNORE_DONE_FOLDERS=false
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

# ============================================================================
# v5 core — ffmpeg encode engine with VMAF-targeted CRF search
# ============================================================================
# Files are encoded with ffmpeg (libsvtav1 / libx265) at a per-title CRF chosen
# by sampling short mid-file clips and scoring them with libvmaf (NEG model).
# Disc sources (ISO/BDMV) keep the HandBrake engine — title scan/selection.
# Quality gates (three-tier, per machine capability):
#   1. ab-av1 installed            -> ab-av1 crf-search (fastest, best)
#   2. ffmpeg has libvmaf          -> internal sample-based CRF search
#   3. no libvmaf                  -> fixed CRF (v4-equivalent behavior)
# HDR sources are NOT VMAF-searched (VMAF is unreliable on PQ/HLG) — they use
# a conservative fixed CRF and carry HDR10 static metadata into the output.
# Dolby Vision policy: strip DoVi in favor of plain HDR10 (Plex/VLC-safe).
#   P7/P8: HDR10 base layer survives re-encode; RPU/EL simply dropped.
#   P5:    no HDR10 base — convert via libplacebo (applies RPU -> PQ/BT.2020);
#          if libplacebo is unavailable the file is flagged for human review.

# --- v5 tunables (env-overridable) ---
ENCODE_ENGINE="${CONVERT_ENGINE:-auto}"           # auto|ffmpeg|handbrake
VMAF_TARGET_MOVIE="${CONVERT_VMAF_TARGET:-94.0}"  # 1080p SDR movies/TV (NEG model; ~= default-model 95.5)
VMAF_TARGET_ANIME="${CONVERT_VMAF_TARGET_ANIME:-94.0}"
VMAF_TARGET_4K="${CONVERT_VMAF_TARGET_4K:-95.0}"  # scored with the 4K model
VMAF_SAMPLES="${CONVERT_VMAF_SAMPLES:-3}"
VMAF_SAMPLE_SECS="${CONVERT_VMAF_SAMPLE_SECS:-20}"
VMAF_SEARCH_MIN_CRF=16
VMAF_SEARCH_MAX_CRF=46
VMAF_DISABLED=false                               # --no-vmaf
PREFER_HW_ENCODE=false                            # --prefer-hw (speed over size)
# Fixed CRFs used when VMAF search is unavailable/disabled, and always for HDR:
FIXED_CRF_SVT_MOVIE=26
FIXED_CRF_SVT_ANIME=32
FIXED_CRF_SVT_HDR=24
FIXED_CRF_X265_MOVIE=20
FIXED_CRF_X265_ANIME=22
FIXED_CRF_X265_HDR=18
SVT_PRESET_FINAL="${CONVERT_SVT_PRESET:-5}"       # full-file encode preset
SVT_PRESET_SEARCH=8                               # sample-search preset (faster; scores track final closely)
X265_PRESET_FINAL="${CONVERT_X265_PRESET:-slow}"
OPUS_BITRATE_V5="${CONVERT_OPUS_BITRATE:-112k}"
AAC_BITRATE_V5="${CONVERT_AAC_BITRATE:-128k}"

FF_HAS_LIBVMAF=false
FF_HAS_LIBSVTAV1=false
FF_HAS_LIBX265=false
FF_HAS_LIBPLACEBO=false
FF_HAS_LIBOPUS=false
AB_AV1_BIN=""
FF_AV1_HW=""            # best functional hw AV1 encoder (av1_nvenc|av1_qsv|av1_vaapi|"")
FF_HEVC_HW=""           # best functional hw HEVC encoder
declare -A VMAF_CRF_CACHE=()

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
CONVERT_SCAN_TOTAL_FILE=""
CONVERT_SCAN_PID=0
CONVERT_READY_OFFSET=0
CONVERT_READY_FD=""
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
  avi mp4 mkv ts m2ts mts mpg mpeg mpe m4v mov wmv flv webm vob divx asf ogv ogm 3gp rmvb rm
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
  -p, --path DIR          Root directory to scan (required for non-interactive use).
                          May end with a quoted glob on the last segment, e.g.
                          '/.../Television/American/A*' or '/.../American/Al*'
                          (parent becomes --path; basename becomes --name-glob).
                          A single existing show dir focuses only that folder.
  -g, --name-glob GLOB    Only include shard directories whose basename matches GLOB
                          (bash glob: A*, Al*, \[A-C\]*). Implies filtered shards
                          even when --no-shard is set (avoids scanning the whole shelf).
  --name-glob-ci          Case-insensitive --name-glob matching
  --dry-run               Show actions without moving/encoding/deleting outputs
  --skip-av1              Skip sources whose video codec is AV1 (inspection still runs)
  --skip-x265             Skip sources whose video codec is HEVC/x265 (inspection still runs)
  --organize-only         Only fix per-movie folder layout + subtitle names
  --convert-only          Skip organization; only transcode/remux
  --sample-seconds N      Encoder bake-off sample length (default: 60, from middle of file)
  --shard-depth N         Find media per subdirectory at depth N (default: 1; avoids huge finds)
  --no-shard              Single find across entire --path (old behavior; ignored when
                          --name-glob / path trailing-glob selects multiple matches)
  --no-resume             Ignore saved resume state and start the convert queue from scratch
  --largest-first         Force batch: inspect all, sort largest-first, then encode
  --pipeline              Force pipeline: inspect waves, encode one-at-a-time per wave
  --encode-batch N        Pipeline: queue N inspected items per encode wave (default: 5)
  v5 encode engine:
  --engine MODE           auto|ffmpeg|handbrake (default auto: ffmpeg for files, HandBrake for discs)
  --vmaf-target N         VMAF (NEG model) floor for SDR movies/TV + anime (default 94.0)
  --vmaf-target-4k N      VMAF floor for 4K sources, scored with the 4K model (default 95.0)
  --vmaf-samples N        Sample clips per title for the CRF search (default 3)
  --no-vmaf               Disable VMAF search — fixed CRFs (v4-equivalent behavior)
  --prefer-hw             Use hardware encoders at fixed quality (speed over size)
  --svt-preset N          SVT-AV1 preset for final encodes (default 5; lower = slower/better)

  --skip-bakeoff          Skip AV1 encoder bake-off (start encoding immediately)
  --nvenc-av1-tune TUNE   Force NVENC AV1 tune: hq or uhq (default: auto-probe)
  --prefer-intel-qsv      Prefer Intel Quick Sync over NVIDIA when both are available
  --prefer-amd-vce        Prefer AMD VCE/VCN over NVIDIA when both are available
  --no-enforce-mount      Skip CIFS mount check/remount (file_mode/dir_mode 0777)
  --mount-share SRC:DST   Mount CIFS share before run (e.g. //192.0.2.50/BabyBear:/mnt/BabyBear)
  --mount-credentials F   SMB credentials file (username=/password= lines)
  --check-tools           Verify required tools, print install commands for this OS, then exit
  --clean-junk            Scan --path for junk (zero-byte outputs, stale IN_PROGRESS flags)
                          and report findings only, then exit
  --clean-junk-apply      Same scan, but actually delete what it finds
  --ignore-done-folders   Force a full recheck of folders marked complete by a prior run
                          (use after adding/changing files in an already-finished folder)

CIFS/SMB (WSL/NFS-style shares — logs and MKV outputs need writable mount):
  Default: ensure parent CIFS mount uses file_mode=0777,dir_mode=0777,noperm
  CONVERT_CIFS_MOUNT_SRC   e.g. //192.0.2.50/BabyBear (mount when DST is empty)
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
  $0 -p '/mnt/BabyBear/Media/Television/American/A*' --convert-only --no-shard
  $0 -p /mnt/BabyBear/Media/Television/American -g 'Al*' --convert-only
  $0 -p '/mnt/BabyBear/Media/Television/American/Alf' --convert-only
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
    # Plain chown follows a symlink and re-owns whatever it points to. This
    # only ever runs on our own outputs/sidecar files, which should never
    # legitimately be symlinks -- skip rather than risk handing ownership of
    # an unrelated real file (root running under sudo) to SUDO_USER.
    [ -n "$f" ] && [ -e "$f" ] && [ ! -L "$f" ] && chown "$MEDIA_OWNER_USER:$MEDIA_OWNER_USER" "$f" 2>/dev/null || true
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
    # getent is glibc/Linux-only -- not present on macOS/BSD by default.
    if command -v getent >/dev/null 2>&1; then
      home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
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
      home="$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    fi
    if [ -z "$home" ] && command -v python3 >/dev/null 2>&1; then
      home="$(python3 -c 'import pwd,sys
try:
    print(pwd.getpwnam(sys.argv[1]).pw_dir)
except KeyError:
    pass' "$SUDO_USER" 2>/dev/null)"
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

  # A user-built binary in ~/.local/bin takes priority over the system PATH
  # copy — e.g. a libvmaf-enabled ffmpeg build vs. the distro package. This
  # also covers non-interactive SSH/cron invocations where ~/.local/bin was
  # never added to PATH (shell rc files like .bashrc short-circuit for
  # non-interactive shells, and .profile only loads for login shells).
  candidate="$HOME/.local/bin/$name"
  [ -x "$candidate" ] && printf '%s' "$candidate" && return 0

  if candidate="$(command -v "$name" 2>/dev/null)"; then
    printf '%s' "$candidate"
    return 0
  fi

  while IFS= read -r candidate; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && printf '%s' "$candidate" && return 0
  done < <(platform_extra_paths "$name")

  return 1
}

# sudo clears almost the entire environment by default, including
# WSL_INTEROP -- the socket path WSL2's Linux userspace needs to invoke a
# Windows .exe host binary at all. Running as root/sudo and dropping to a
# real user (sudo -u "$SUDO_USER") to call Windows HandBrakeCLI.exe/
# nvidia-smi.exe therefore fails with "cannot execute binary file" purely
# because of the stripped env var, not a real capability gap -- silently
# forcing software-only fallback. Forward it through explicitly.
sudo_drop_user() {
  local user="$1"
  shift
  if [ "$PLATFORM" = wsl ] && [ -n "${WSL_INTEROP:-}" ]; then
    sudo WSL_INTEROP="$WSL_INTEROP" -u "$user" -H -- "$@"
  else
    sudo -u "$user" -H -- "$@"
  fi
}

_handbrake_reports_nvenc() {
  local candidate="$1"
  [ -n "$candidate" ] || return 1
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$PLATFORM" = wsl ] && [[ "$candidate" == *.exe ]]; then
    sudo_drop_user "$SUDO_USER" "$candidate" --help 2>&1 | search_cie 'nvenc: version [0-9]|nvenc_av1_10bit|nvenc_h265'
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
    hb_help="$(sudo_drop_user "$SUDO_USER" "$candidate" --help 2>&1)" || return 1
  else
    hb_help="$("$candidate" --help 2>&1)" || return 1
  fi
  _handbrake_help_lists_qsv "$hb_help"
}

_handbrake_reports_amd_vce() {
  local candidate="$1"
  [ -n "$candidate" ] || return 1
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$PLATFORM" = wsl ] && [[ "$candidate" == *.exe ]]; then
    sudo_drop_user "$SUDO_USER" "$candidate" --help 2>&1 | search_cie 'vce_h265|vce_h264|vcn_h265|vcn_h264'
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
  local -a out=() arg mode=""
  for arg in "${_args[@]}"; do
    case "$arg" in
      -i|-o)
        out+=("$arg")
        mode=path
        ;;
      *)
        # --srt-file's comma-joined value is pre-translated at the point it's
        # built (handbrake_append_external_srts) -- re-splitting a joined
        # string on ',' here is unsafe for any subtitle path that itself
        # contains a literal comma.
        if [ "$mode" = path ]; then
          out+=("$(handbrake_path_for_exe "$arg")")
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
    sudo_drop_user "$HANDBRAKE_DROP_TO_USER" "$@"
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
#
# Also claims a same-named ".lock" sibling directory via mkdir, which is
# atomic even on NFS/CIFS -- unlike the informational flag file above (a
# plain `cat >` write), two fleet machines scanning the same shared library
# can otherwise both decide a title needs encoding and race to write the
# same output path. The lock dir is a pure implementation detail (never
# inspected by clean_junk_scan/junk_flag_is_stale) so the human-visible
# .IN_PROGRESS file's format and behavior are unchanged. Returns 1 if
# another live process (this host or another fleet machine) already holds
# the claim -- callers must skip the job in that case.
place_in_progress_flag() {
  local src="$1"
  local idx="${2:-}"
  local flag lockdir dir title this_host
  [ "$DRY_RUN" = true ] && return 0
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src")"
  flag="$(in_progress_flag_path "$src")"
  lockdir="${flag}.lock"
  this_host="$(hostname 2>/dev/null || echo unknown)"
  mkdir -p -- "$dir" 2>/dev/null || true

  if ! mkdir -- "$lockdir" 2>/dev/null; then
    if junk_flag_is_stale "$flag" 2>/dev/null; then
      rmdir -- "$lockdir" 2>/dev/null
      if ! mkdir -- "$lockdir" 2>/dev/null; then
        warn "Title claimed by another process just now — skipping: $title"
        return 1
      fi
    else
      local holder
      holder="$(awk -F= '/^host=/{h=$2} /^pid=/{p=$2} END{print h" pid "p}' "$flag" 2>/dev/null)"
      warn "Title already being encoded elsewhere (${holder:-unknown host/pid}) — skipping: $title"
      return 1
    fi
  fi

  # cat >"$flag" follows a symlink at that path and truncates+writes INTO
  # whatever it points to. $flag is a predictable name sitting right beside
  # the source on a shared NFS/CIFS library, so refuse rather than write
  # through it if it's ever a symlink (planted or accidental) instead of a
  # plain file.
  if [ -L "$flag" ]; then
    warn "Refusing to write in-progress flag — path is a symlink, not a plain file: $flag"
    rmdir -- "$lockdir" 2>/dev/null
    return 1
  fi

  if [ -f "$flag" ]; then
    warn "Found leftover ${title}.${IN_PROGRESS_FLAG_SUFFIX} — prior run may have left partial .AV1.mkv/.x265.mkv for this title"
  fi
  cat >"$flag" <<EOF
convert-v4 IN PROGRESS
version=$VERSION
pid=$$
host=$this_host
started_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
job_index=${idx:-}
title=$title
source=$src

If you see this file, the convert job for this title was interrupted or is still running.
Delete ${title}.AV1.mkv and/or ${title}.x265.mkv here (not the original) before trusting
or re-running convert for this title.
EOF
  return 0
}

clear_in_progress_flag() {
  local src="$1"
  local flag
  [ "$DRY_RUN" = true ] && return 0
  flag="$(in_progress_flag_path "$src")"
  rmdir -- "${flag}.lock" 2>/dev/null || true
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
  if ! place_in_progress_flag "$src" "$idx"; then
    return 1
  fi
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

  # timeout execs an external command directly -- it can't wrap a shell
  # function (sudo_drop_user), so the WSL_INTEROP forwarding is inlined here
  # as a plain sudo argument instead (sudo VAR=val -u user is a supported
  # invocation form independent of env_reset).
  local -a sudo_env=()
  if [ "$PLATFORM" = wsl ] && [ -n "${WSL_INTEROP:-}" ]; then
    sudo_env=(WSL_INTEROP="$WSL_INTEROP")
  fi

  set +e
  if command -v timeout >/dev/null 2>&1; then
    if [ -n "$HANDBRAKE_DROP_TO_USER" ]; then
      timeout 120 sudo "${sudo_env[@]}" -u "$HANDBRAKE_DROP_TO_USER" -H -- "${HANDBRAKE_CMD[@]}" "${hb_args[@]}" >"$probe_log" 2>&1
    else
      timeout 120 "${HANDBRAKE_CMD[@]}" "${hb_args[@]}" >"$probe_log" 2>&1
    fi
  elif [ -n "$HANDBRAKE_DROP_TO_USER" ]; then
    sudo "${sudo_env[@]}" -u "$HANDBRAKE_DROP_TO_USER" -H -- "${HANDBRAKE_CMD[@]}" "${hb_args[@]}" >"$probe_log" 2>&1
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
    -g|--name-glob) NAME_GLOB="$2"; shift 2 ;;
    --name-glob-ci) NAME_GLOB_CI=true; shift ;;
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
    --clean-junk) CLEAN_JUNK=true; shift ;;
    --clean-junk-apply) CLEAN_JUNK=true; CLEAN_JUNK_APPLY=true; shift ;;
    --ignore-done-folders) IGNORE_DONE_FOLDERS=true; shift ;;
    --check-tools) CHECK_TOOLS_ONLY=true; shift ;;
    --vmaf-target) VMAF_TARGET_MOVIE="$2"; VMAF_TARGET_ANIME="$2"; shift 2 ;;
    --vmaf-target-4k) VMAF_TARGET_4K="$2"; shift 2 ;;
    --vmaf-samples) VMAF_SAMPLES="$2"; shift 2 ;;
    --no-vmaf) VMAF_DISABLED=true; shift ;;
    --prefer-hw) PREFER_HW_ENCODE=true; shift ;;
    --engine) ENCODE_ENGINE="$2"; shift 2 ;;
    --svt-preset) SVT_PRESET_FINAL="$2"; shift 2 ;;
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

split_path_trailing_glob "$SEARCH_PATH"
# A path starting with '-' (e.g. `-p -Media`) gets misread as an option by
# realpath/find/etc regardless of quoting -- quoting only stops the shell
# from word-splitting it, not a program's own argv parsing from treating a
# leading dash as a flag. Neutralize it the same way ./ does for any
# relative path.
case "$SEARCH_PATH" in
  -*) SEARCH_PATH="./$SEARCH_PATH" ;;
esac
SEARCH_PATH="$(canonical_path "$SEARCH_PATH")"
JOB_ROOT="$SEARCH_PATH"

if [ -n "${CONVERT_CIFS_MOUNT_SRC:-}" ] && [ -n "${CONVERT_CIFS_MOUNT_DST:-}" ]; then
  ensure_cifs_mount_for_path "$CONVERT_CIFS_MOUNT_DST" || exit 1
fi

if [ ! -e "$SEARCH_PATH" ]; then
  ensure_cifs_mount_for_path "$SEARCH_PATH" || true
fi
if [ ! -e "$SEARCH_PATH" ]; then
  err "Path not found: $SEARCH_PATH"
  exit 1
fi

# v5.0.2: -p may target a single file directly (movie or episode), not just a
# directory or a directory+trailing-glob. Sidecars (log/state/resume) live in
# the file's parent directory; organize is skipped (nothing to reorganize for
# one file); sharding/name-glob do not apply.
SINGLE_FILE_MODE=false
if [ -f "$SEARCH_PATH" ]; then
  SINGLE_FILE_MODE=true
  JOB_ROOT="$(dirname "$SEARCH_PATH")"
  DO_ORGANIZE=false
  NO_SHARD=true
  if [ -n "$NAME_GLOB" ]; then
    warn "--name-glob ignored — $SEARCH_PATH is a single file target"
    NAME_GLOB=""
  fi
elif [ ! -d "$SEARCH_PATH" ]; then
  err "Path is neither a file nor a directory: $SEARCH_PATH"
  exit 1
fi

ensure_cifs_mount_for_path "$SEARCH_PATH" || exit 1

if [ -n "$NAME_GLOB" ] && [ "$NO_SHARD" = true ]; then
  warn "--name-glob '$NAME_GLOB' forces filtered per-directory shards (ignoring --no-shard for shelf-wide find)"
fi

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

# is_derived_output() is a cheap, name-only guess used throughout the broad
# scan/queueing path -- intentionally never ffprobes there. But before any
# DESTRUCTIVE action (deleting a file, or mutating one in place) based on
# "this looks like our own AV1/x265 output", actually confirm the file's
# real video codec matches what its name claims. A file named "*.AV1.mkv"
# whose stream isn't actually AV1 (wrong format entirely, or even just a
# differently-encoded file that happens to share the naming convention) is
# proof it's NOT something this script produced, regardless of filename.
derived_output_codec_claim_matches() {
  local out="$1"
  local base="${out##*/}"
  local codec
  case "$base" in
    *.[Aa][Vv]1.mkv) codec="$(video_codec "$out" 2>/dev/null)"; [ "$codec" = "av1" ] ;;
    *.[Xx]265.mkv)   codec="$(video_codec "$out" 2>/dev/null)"; [ "$codec" = "hevc" ] ;;
    *) return 0 ;;
  esac
}

is_multipart_merged_file() {
  local base="${1##*/}"
  [[ "$base" =~ \.(merged|MERGED)\.mkv$ ]]
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
  title="${title%.merged}"
  title="${title%.MERGED}"
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
# Plex requires season folders to be literally named "Season NN" (or
# "Specials" for season 0) -- see support.plex.tv's TV naming guide. That's a
# cheaper and more reliable TV signal than scanning file contents: a
# directory named this way IS a season folder, full stop, regardless of what
# the episode filenames inside it look like.
is_plex_season_dir_name() {
  local base="$1"
  [[ "$base" =~ ^[Ss]eason[[:space:]]+[0-9]+$ ]] && return 0
  [[ "$base" =~ ^[Ss]pecials$ ]] && return 0
  return 1
}

is_tv_show_directory() {
  local dir="$1"
  local f count=0 videos=0
  is_plex_season_dir_name "$(basename "$dir")" && return 0
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
    linux|wsl) stat -c%s "$1" 2>/dev/null || echo 0 ;;
    # Any other/unrecognized platform (a plain BSD box, not macOS): GNU
    # stat's -c flag isn't guaranteed there. python3's portable os.stat is
    # the same fallback mkv_structure_stat_key already relies on.
    *)
      stat -c%s "$1" 2>/dev/null && return 0
      python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_size)' "$1" 2>/dev/null || echo 0
      ;;
  esac
}

disc_source_size_bytes() {
  local src="$1"
  if is_iso_file "$src"; then
    file_size_bytes "$src"
  elif is_bluray_root "$src"; then
    # du -b is GNU-only (BSD/macOS du has no -b) -- sum real file sizes
    # instead, via the already-portable file_size_bytes helper.
    local total=0 f sz
    while IFS= read -r f; do
      sz="$(file_size_bytes "$f")"
      total=$((total + sz))
    done < <(find "$src" -type f 2>/dev/null)
    printf '%s' "$total"
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
  local shard base

  _roots=()
  # Name-glob filter: only matching dirs at shard depth (or depth 1 under --path).
  # Always expands to concrete directories so --no-shard cannot re-scan the whole shelf.
  if [ -n "$NAME_GLOB" ]; then
    local depth="$SHARD_DEPTH"
    [ "$depth" -ge 1 ] 2>/dev/null || depth=1
    while IFS= read -r shard; do
      [ -n "$shard" ] || continue
      base="$(basename "$shard")"
      if name_glob_matches "$base" "$NAME_GLOB"; then
        _roots+=("$shard")
      fi
    done < <(find "$SEARCH_PATH" -mindepth "$depth" -maxdepth "$depth" -type d 2>/dev/null | LC_ALL=C sort)

    if [ "${#_roots[@]}" -eq 0 ]; then
      err "No directories under $SEARCH_PATH match name-glob '$NAME_GLOB' (shard-depth=$depth)"
      return 1
    fi
    return 0
  fi

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

# These sidecar state/log files live at fixed, predictable names -- by
# default directly inside JOB_ROOT (the media library root itself) unless
# it's read-only. A symlink planted at one of these exact names (by another
# fleet machine, another user on a shared NFS/CIFS mount, or by accident)
# would have every subsequent truncating write in this script go straight
# through to whatever it points at, e.g. a real source video. Since we own
# the full lifecycle of these specific files (always created fresh, never
# meant to pre-exist as anything but our own regular file from a prior run),
# removing a stray symlink at one of these names is always safe -- rm on a
# symlink only ever removes the link itself, never its target.
_neutralize_symlink_sidecar_path() {
  local p="$1"
  if [ -L "$p" ]; then
    warn "Sidecar path is a symlink, not our own regular file — removing the link only (target untouched) before use: $p"
    rm -f -- "$p"
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
  RESUME_DONE_LOG="$JOB_SIDECAR_DIR/convert-v5.done"
  local p
  for p in "$RESUME_STATE_FILE" "$RESUME_QUEUE_FILE" "$MKV_STRUCTURE_CACHE_FILE" \
           "$CORRUPT_FILES_LOG" "$BAD_SOURCES_LOG" "$RECONVERT_FILES_LOG" \
           "$RESUME_SHARDS_FILE" "$RESUME_DONE_LOG"; do
    _neutralize_symlink_sidecar_path "$p"
  done
  filecache_init
}

# --- v5.0.1: set-based done-log ------------------------------------------------
# The v4 resume anchor is a single position in a size-sorted queue — fragile when
# the queue shifts between runs (new files, rejected outputs, failed encodes), and
# every restart re-validates all prior outputs before reaching the anchor. The
# done-log records each durably-finished source (status, size, mtime, path); on
# the next run those sources are skipped before any ffprobe/validation work, as
# long as the source file is unchanged. --no-resume bypasses the fast path.
declare -A DONE_SET=()
DONE_SET_LOADED=false
DONE_FAST_SKIPS=0
RESUME_DONE_LOG=""

done_log_load() {
  local st sz mt p n=0
  DONE_SET=()
  DONE_SET_LOADED=true
  [ -n "$RESUME_DONE_LOG" ] && [ -f "$RESUME_DONE_LOG" ] || return 0
  while IFS=$'\t' read -r st sz mt p; do
    [ -n "$p" ] || continue
    case "$st" in done|skip) DONE_SET["$p"]="$sz|$mt"; n=$((n+1)) ;; esac
  done <"$RESUME_DONE_LOG"
  [ "$n" -gt 0 ] && log "Done-log: $n finished source(s) on record — unchanged files fast-skip (bypass with --no-resume)"
}

done_log_append() {  # status src
  local st="$1" src="$2" key
  [ "$DRY_RUN" = true ] && return 0
  [ -n "${RESUME_DONE_LOG:-}" ] || return 0
  is_disk_source "$src" && return 0
  key="$(mkv_structure_stat_key "$src")" || return 0
  printf '%s\t%s\t%s\t%s\n' "$st" "${key%%|*}" "${key##*|}" "$src" >>"$RESUME_DONE_LOG" 2>/dev/null || true
  DONE_SET["$src"]="$key"
}

done_log_should_skip() {  # src -> 0 when durably done and unchanged
  local src="$1" key
  [ "$NO_RESUME" = true ] && return 1
  [ "$DONE_SET_LOADED" = true ] || return 1
  [ -n "${DONE_SET[$src]:-}" ] || return 1
  key="$(mkv_structure_stat_key "$src")" || return 1
  [ "$key" = "${DONE_SET[$src]}" ]
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
    printf 'name_glob=%s\n' "${NAME_GLOB:-}"
    printf 'name_glob_ci=%s\n' "$NAME_GLOB_CI"
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
      name_glob) val="${NAME_GLOB:-}" ;;
      name_glob_ci) val="$NAME_GLOB_CI" ;;
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
name_glob
name_glob_ci
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
  _neutralize_symlink_sidecar_path "$prev_shards"
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
  # resume_init_paths sets RESUME_DONE_LOG to the real sidecar path -- it was
  # previously called AFTER done_log_load, so done_log_load always saw the
  # empty top-level default and silently never loaded convert-v5.done. That
  # disabled the entire done-log fast-skip resume path (every restart fully
  # re-validated every file via ffprobe/mkvalidator instead of fast-skipping
  # already-finished ones) without any visible error.
  resume_init_paths
  done_log_load
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
  local root="$1" skip_merge="${2:-false}"
  local -a raw=()
  while IFS= read -r f; do [ -n "$f" ] && raw+=("$f"); done < <(find_convert_videos_under_cached "$root")
  [ "$skip_merge" = true ] || apply_multipart_merging raw
  printf '%s\n' "${raw[@]}"
}

find_videos_at_root() {
  local root="$1" skip_merge="${2:-false}"
  local -a pred=() raw=()
  build_find_video_pred pred
  while IFS= read -r f; do [ -n "$f" ] && raw+=("$f"); done < <(find "$root" -maxdepth 1 -type f "${pred[@]}" \
    ! -iname '*.AV1.mkv' ! -iname '*.x265.mkv' 2>/dev/null)
  [ "$skip_merge" = true ] || apply_multipart_merging raw
  printf '%s\n' "${raw[@]}"
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
      # Portable 2-arg match (RSTART/RLENGTH are POSIX) -- 3-arg match(...,
      # array) is a gawk extension BSD/macOS awk does not support.
      if (match($0, /title [0-9]+/)) {
        idx = substr($0, RSTART, RLENGTH); sub(/title /, "", idx); idx = idx + 0
      } else idx = 0
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
  _neutralize_symlink_sidecar_path "$MASTER_LOG_FILE"
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
  _neutralize_symlink_sidecar_path "$SHARD_LOG_FILE"
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
  done_log_append done "$src"
  mark_folder_done_if_complete "$(dirname "$src")"
}

record_skip() {
  local src="$1"
  local reason="${2:-already exists}"
  STATS_SKIPPED=$((STATS_SKIPPED + 1))
  stats_log_append "[$(date -u '+%H:%M:%S')] SKIP: $(basename "$src") — $reason"
  stats_log_running_totals
  # Durable skips go on the done-log; transient failures must retry next run.
  case "$(to_lower "$reason")" in
    *fail*|*error*|*unable*) : ;;
    *) done_log_append skip "$src" ;;
  esac
  mark_folder_done_if_complete "$(dirname "$src")"
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
      if (match($0, /title [0-9]+/)) {
        idx = substr($0, RSTART, RLENGTH); sub(/title /, "", idx); idx = idx + 0
      } else idx = 0
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
      done_log_append done "$src"
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
      done_log_append done "$src"
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

  # Translate each path individually BEFORE comma-joining. A path containing
  # a literal comma (e.g. "Movie, The (2020).en.srt") would otherwise get
  # blindly re-split on ',' later (in _handbrake_translate_argv, which only
  # sees the joined string) into two bogus fragments, each wrongly
  # translated. handbrake_path_for_exe() is a no-op outside WSL win-path
  # mode, so this is safe to always apply here.
  local -a subs_out=()
  local sub_i
  for sub_i in "${subs[@]}"; do
    subs_out+=("$(handbrake_path_for_exe "$sub_i")")
  done

  local joined_subs joined_langs joined_codesets
  joined_subs="$(IFS=,; printf '%s' "${subs_out[*]}")"
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

  # Joining with a plain space and re-splitting with Python's default
  # .split() corrupts any command whose path contains a space (e.g. macOS
  # "/Applications/MKVToolNix 88.app/.../mkvpropedit") into bogus argv
  # fragments. \x1f (ASCII unit separator) never legitimately appears in a
  # real path, so it round-trips exactly regardless of spaces in the path.
  CONVERT_MKVMERGE="$(IFS=$'\x1f'; printf '%s' "${MKVMERGE_CMD[*]}")"
  CONVERT_MKVPROPEDIT="$(IFS=$'\x1f'; printf '%s' "${MKVPROPEDIT_CMD[*]}")"
  export CONVERT_MKVMERGE CONVERT_MKVPROPEDIT

  python3 - "$mkv" "$src" "$title" <<'PY'
import json, os, subprocess, sys

mkv, src, title = sys.argv[1:4]
mkvmerge = os.environ.get("CONVERT_MKVMERGE", "mkvmerge").split("\x1f")
mkvpropedit = os.environ.get("CONVERT_MKVPROPEDIT", "mkvpropedit").split("\x1f")

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

# HandBrake often stores channel layout (Stereo/5.1/…) as the track name.
CHANNEL_LAYOUT_NAMES = {
    "mono", "stereo", "joint stereo", "dual channel", "surround",
    "2.0", "2.1", "3.0", "3.1", "4.0", "4.1", "5.0", "5.1", "6.1", "7.1",
    "atmos", "dolby atmos", "dts", "truehd", "flac", "aac", "opus", "ac3", "eac3",
}

try:
    data = json.loads(subprocess.check_output([*mkvmerge, "-J", mkv], text=True))
except Exception:
    sys.exit(0)

fallback = guess_from_path(src)
args = [*mkvpropedit, mkv, "-e", "info", "--set", f"title={title}"]

for track in data.get("tracks", []):
    if track.get("type") not in ("audio", "subtitles"):
        continue
    props = track.get("properties", {}) or {}
    # mkvmerge -J "id" is 0-based; mkvpropedit "track:N" is 1-based and would
    # shift every edit onto the previous track (video gets audio names, langs slide).
    # Prefer unambiguous track UID selectors.
    uid = props.get("uid")
    if uid is None:
        continue
    lang = norm(props.get("language_ietf") or props.get("language") or "")
    if not lang:
        lang = detect_from_filename(src) or fallback
    name = (props.get("track_name") or "").strip()
    if (
        not name
        or name.lower() in {"und", "unknown", "track"}
        or name.lower() in CHANNEL_LAYOUT_NAMES
        or name.upper() == (lang.upper() if lang else "")
    ):
        name = LANG_NAMES.get(lang, lang.upper() if lang else "Unknown")
    # Syntax is track:=UID (not track:@UID) — see mkvpropedit(1).
    args.extend(["--edit", f"track:={uid}", "--set", f"name={name}"])
    if lang:
        args.extend(["--set", f"language={lang}"])

subprocess.run(args, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PY
}

optimize_mkv_for_streaming() {
  local mkv="$1" tmp
  [ "$DRY_RUN" = true ] && return 0
  # A static ".streamopt.tmp.mkv" name is predictable, and rm-then-create
  # leaves a TOCTOU window for another process to plant a symlink there
  # before mkvmerge -o opens it. mktemp creates the file atomically and
  # exclusively, closing both the predictability and the race window.
  # BSD/macOS mktemp requires the X's to be the template's trailing
  # characters -- no suffix after them (unlike GNU, which tolerates one).
  # mkvmerge doesn't care about the temp file's extension, so just drop it.
  tmp="$(mktemp "${mkv%.mkv}.streamopt.XXXXXX")" || return 0
  if run_mkvmerge -o "$tmp" --quiet "$mkv" >/dev/null 2>&1 && [ -s "$tmp" ]; then
    mv -f "$tmp" "$mkv"
  else
    rm -f "$tmp"
    warn "Streaming-optimization remux failed — keeping encoder's original mux: $mkv"
  fi
}

finalize_mkv_output() {
  local mkv="$1"
  local src="$2"
  local title="${3:-$(canonical_title_from_file "$src")}"
  optimize_mkv_for_streaming "$mkv"
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
    # mv -n silently no-ops (exit 0) if dest_video already exists -- without
    # this check we'd wrongly assume the move happened and go on to treat
    # dest_video as if it were $video, while the real source file is quietly
    # left behind, un-organized, with no warning.
    if [ -e "$dest_video" ]; then
      warn "Organize collision — destination already exists, leaving source in place: $video -> $dest_video"
      return 1
    fi
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
        if [ -e "$target" ]; then
          warn "Organize collision — subtitle destination already exists, leaving in place: $item -> $target"
        else
          log "  subtitle: $item -> $target"
          mv -n -- "$item" "$target"
        fi
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
  local tmpf
  [ -n "$cache" ] && [ -f "$cache" ] || return 0
  # A static ".tmp" suffix is a fully predictable path -- mktemp gives a
  # randomized name in the same directory, closing the symlink-race window
  # a fixed name would otherwise leave (see filecache_put's cache_tmp).
  tmpf="$(mktemp "${cache}.XXXXXX")" || return 0
  awk -F '\t' -v p="$dst" '$2!=p { print }' "$cache" >"$tmpf" 2>/dev/null || true
  mv -f "$tmpf" "$cache" 2>/dev/null || rm -f "$tmpf" 2>/dev/null
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
#
# $out only gets here because its filename matches our own derived-output
# naming convention (Title.AV1.mkv / Title.x265.mkv) -- that's a guess, not
# proof, that we created it. A genuine unrelated file a user already had
# (e.g. their own native-AV1 rip of a different edition, sitting beside an
# unconverted source with a matching canonical title) would look identical
# to a broken conversion output once it fails validation against $src. An
# encode we actually produced can only ever exist AFTER its source did, so a
# candidate that predates $src cannot possibly be something we made from
# this exact source -- refuse to delete it and flag for human review instead.
flag_bad_processed_output() {
  local src="$1"
  local out="$2"
  local reason="${3:-invalid processed output}"
  local logf="${RECONVERT_FILES_LOG:-}"
  local src_mt out_mt

  src_mt="$(mkv_structure_stat_key "$src" 2>/dev/null)"; src_mt="${src_mt##*|}"
  out_mt="$(mkv_structure_stat_key "$out" 2>/dev/null)"; out_mt="${out_mt##*|}"
  if [[ "$src_mt" =~ ^[0-9]+$ ]] && [[ "$out_mt" =~ ^[0-9]+$ ]] && [ "$out_mt" -lt "$src_mt" ]; then
    flag_bad_source_for_human "$out" "matches our derived-output naming but predates its supposed source ($src) — likely an unrelated file, not something we created; not deleting ($reason)"
    return 0
  fi
  if ! derived_output_codec_claim_matches "$out"; then
    flag_bad_source_for_human "$out" "named as our AV1/x265 output but its actual video codec doesn't match — not something we created; not deleting ($reason)"
    return 0
  fi

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

# Checks whether a structurally-bad source MKV/WebM's content is actually
# fine (just container-level noise) by remuxing it (stream copy; mkvmerge
# preferred, ffmpeg -c copy as fallback) into a throwaway mktemp -d, entirely
# outside the library tree. Never touches or replaces $src -- there is no
# in-place write, no window where the original is missing/half-written, and
# no leftover artifact beside the source for a later scan to mistake for a
# new title. On success prints the repaired copy's path on stdout purely as
# proof the content is sound (caller removes it immediately, it is never
# used as the actual encode input); the real encode always runs against the
# untouched original -- if ffmpeg itself still can't read it, the normal
# AV1-then-x265-then-fail-safely fallback chain handles that already.
# Returns 0 if the repair validated clean; 1 otherwise ($src is always
# untouched either way).
attempt_source_mkv_structure_remux() {
  local src="$1"
  local reason="${2:-structure errors}"
  local workdir tmp rc

  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] Would remux-repair source MKV ($reason): $src"
    return 1
  fi

  workdir="$(mktemp -d)" || return 1
  tmp="$workdir/repaired.mkv"

  log "Source MKV structure issue ($reason) — attempting remux repair (repaired copy only, source untouched): $src"

  set +e
  if [ "${#MKVMERGE_CMD[@]}" -gt 0 ]; then
    run_mkvmerge -o "$tmp" "$src" >/dev/null 2>&1
    rc=$?
    # mkvmerge: 0=ok, 1=warnings (often still usable), >=2=error
    if [ "$rc" -ge 2 ] || [ ! -s "$tmp" ]; then
      warn "mkvmerge remux repair failed (rc=$rc); trying ffmpeg stream copy"
      run_ffmpeg -y -nostdin -loglevel error -fflags +genpts -i "$src" -map 0 -c copy "$tmp"
      rc=$?
    else
      rc=0
    fi
  else
    run_ffmpeg -y -nostdin -loglevel error -fflags +genpts -i "$src" -map 0 -c copy "$tmp"
    rc=$?
  fi
  set -e

  if [ "$rc" -ne 0 ] || [ ! -s "$tmp" ]; then
    warn "Remux repair failed for $src"
    rm -rf -- "$workdir"
    return 1
  fi

  if ! ffprobe_metadata_ok "$tmp" true; then
    warn "Remux repair produced unreadable metadata: $tmp"
    rm -rf -- "$workdir"
    return 1
  fi
  if ! validate_mkv_ebml_bounds "$tmp"; then
    warn "Remux repair still fails EBML/segment bounds: $tmp"
    rm -rf -- "$workdir"
    return 1
  fi
  if [ "$HAS_MKVALIDATOR" = true ] && ! validate_mkv_mkvalidator "$tmp"; then
    warn "Remux repair still fails mkvalidator: $tmp"
    rm -rf -- "$workdir"
    return 1
  fi

  log "Remux repair succeeded — using repaired copy for this encode; source left untouched: $src"
  printf '%s' "$tmp"
  return 0
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
    # attempt_source_mkv_structure_remux only ever repairs an isolated,
    # throwaway copy under mktemp -d -- $src on disk is NEVER modified by
    # it. Its result here is used purely as a confidence check ("is this
    # source's content fundamentally sound, just container-level noise?"):
    # if the repair validates clean, we proceed to encode from the
    # untouched original as always; if ffmpeg itself still can't read it,
    # the existing AV1-then-x265-then-fail-safely fallback chain in
    # try_av1_convert already handles that without ever touching $src.
    local repaired
    if ! validate_mkv_ebml_bounds "$src"; then
      if repaired="$(attempt_source_mkv_structure_remux "$src" "EBML/segment bounds invalid")"; then
        rm -rf -- "$(dirname "$repaired")"
      else
        flag_bad_source_for_human "$src" "Matroska EBML/segment bounds invalid (remux repair failed)"
        return 1
      fi
    fi
    # Full mkvalidator on sources at encode time only (when available).
    if [ "$HAS_MKVALIDATOR" = true ]; then
      if ! validate_mkv_mkvalidator "$src"; then
        if repaired="$(attempt_source_mkv_structure_remux "$src" "mkvalidator structure errors")"; then
          rm -rf -- "$(dirname "$repaired")"
        else
          flag_bad_source_for_human "$src" "mkvalidator structure errors (remux repair failed)"
          return 1
        fi
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
# EBML failures are deferred to encode-time remux repair (do not flag bad yet).
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
      warn "Matroska EBML/segment bounds look bad — will attempt remux repair at encode time: $src"
      # Still queue; validate_source_media remuxes or flags for human review.
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
  local tmpf
  [ -n "$cache" ] || return 0
  key="$(mkv_structure_stat_key "$dst")" || return 0
  mkdir -p "$(dirname "$cache")" 2>/dev/null || true
  if [ -f "$cache" ]; then
    tmpf="$(mktemp "${cache}.XXXXXX")" || return 0
    awk -F '\t' -v p="$dst" '$2!=p { print }' "$cache" >"$tmpf" 2>/dev/null || true
    mv -f "$tmpf" "$cache" 2>/dev/null || rm -f "$tmpf" 2>/dev/null
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

# True when build_handbrake_args will force -w 1920 -l 1080 (source height < 720).
# Upscale only genuine sub-720p (SD: 480p/540p/576p/320p, ...) sources.
# Many "720p" releases are letterboxed/pillarboxed or otherwise cropped and
# report a height a little under 720 (e.g. 1280x700, 1280x716) -- those are
# not SD and must not be upscaled, so a grace band separates them from real
# SD content instead of using a bare "< 720" cutoff.
UPSCALE_HEIGHT_THRESHOLD=700

source_triggers_1080p_upscale() {
  local src="$1"
  local h
  if is_disk_source "$src"; then
    return 1
  fi
  h="$(video_height "$src" 2>/dev/null || true)"
  [ -n "$h" ] || return 1
  awk -v h="$h" -v t="$UPSCALE_HEIGHT_THRESHOLD" 'BEGIN { exit !(h + 0 > 0 && h + 0 < t) }'
}

size_keep_policy_av1() {
  local orig_sz="$1"
  local new_sz="$2"
  local upscaled="${3:-false}"
  local pct lim="$AV1_MAX_OVERSHOOT_PCT"
  if [ "$new_sz" -le "$orig_sz" ]; then
    echo keep
    return 0
  fi
  # Upscale adds pixels — allow more growth than normal, but still cap (default 50%).
  if [ "$upscaled" = true ]; then
    lim="$UPSCALE_MAX_OVERSHOOT_PCT"
  fi
  pct="$(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { if (o<=0) print 100; else print ((n-o)/o)*100 }')"
  if awk -v p="$pct" -v lim="$lim" 'BEGIN { exit !(p>lim) }'; then
    echo reject
  else
    echo keep
  fi
}

size_keep_policy() {
  local orig_sz="$1"
  local new_sz="$2"
  local upscaled="${3:-false}"
  local pct lim="$SIZE_OVERSHOOT_PCT"
  if [ "$new_sz" -le "$orig_sz" ]; then
    echo keep
    return 0
  fi
  if [ "$upscaled" = true ]; then
    lim="$UPSCALE_MAX_OVERSHOOT_PCT"
  fi
  pct="$(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { if (o<=0) print 100; else print ((n-o)/o)*100 }')"
  if awk -v p="$pct" -v lim="$lim" 'BEGIN { exit !(p>lim) }'; then
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
# Prints ONLY: skip | av1 | x265 (stdout is captured by callers). Use log_err for messages.
# Returns 1 when sampling/encode fails.
av1_source_reencode_sample_decision() {
  local sample_src="$1"
  local orig_sz="$2"
  local tmp clip av1_out x265_out clip_sz av1_sz x265_sz pred_av1 pred_x265 start dur pick

  if [ "$DRY_RUN" = true ]; then
    log_err "[dry-run] Would sample ${SAMPLE_SECONDS}s mid-file; compare predicted AV1 vs x265 vs original ($(human_size_bytes "$orig_sz"))"
    printf 'skip'
    return 0
  fi

  tmp="$(mktemp -d)"
  clip="$tmp/clip.mkv"
  av1_out="$tmp/av1.mkv"
  x265_out="$tmp/x265.mkv"

  dur="$(video_duration "$sample_src")"
  start="$(sample_start_middle "$dur")"
  log_err "AV1 source sample: ${SAMPLE_SECONDS}s from middle (start=${start}s of ${dur}s)"

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
  # Sample encodes may emit HandBrake chatter on stdout; keep this function's stdout clean.
  encode_sample_av1 "$clip" "$av1_out" >/dev/null || { rm -rf "$tmp"; return 1; }
  encode_sample_x265 "$clip" "$x265_out" >/dev/null || { rm -rf "$tmp"; return 1; }
  [ -s "$av1_out" ] && [ -s "$x265_out" ] || { rm -rf "$tmp"; return 1; }

  av1_sz="$(file_size_bytes "$av1_out")"
  x265_sz="$(file_size_bytes "$x265_out")"
  pred_av1="$(extrapolate_size_from_sample "$orig_sz" "$clip_sz" "$av1_sz")"
  pred_x265="$(extrapolate_size_from_sample "$orig_sz" "$clip_sz" "$x265_sz")"

  log_err "AV1 source sample sizes: clip=$(human_size_bytes "$clip_sz") av1=$(human_size_bytes "$av1_sz") x265=$(human_size_bytes "$x265_sz")"
  log_err "Predicted full size: AV1=$(human_size_bytes "$pred_av1") x265=$(human_size_bytes "$pred_x265") original=$(human_size_bytes "$orig_sz")"

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

# --- capability detection -------------------------------------------------

ffmpeg_lists_filter() {
  # no grep -q: with pipefail, early grep exit SIGPIPEs ffmpeg and fails the pipeline
  run_ffmpeg -hide_banner -filters 2>/dev/null | grep " $1 " >/dev/null 2>&1
}

ffmpeg_lists_encoder() {
  run_ffmpeg -hide_banner -encoders 2>/dev/null | grep -E "^ [A-Z.]{6} $1 " >/dev/null 2>&1
}

# Functional probe: a 1s synthetic encode. Compiled-in but broken encoders
# (wrong GPU generation, missing driver, no /dev/dri access) fail here.
probe_ffmpeg_encoder() {
  local enc="$1"
  local -a pre=()
  case "$enc" in
    *_vaapi)
      local dev
      for dev in /dev/dri/renderD*; do
        [ -e "$dev" ] || continue
        if run_ffmpeg -y -v error -vaapi_device "$dev" \
             -f lavfi -i "testsrc2=duration=1:size=640x360:rate=24" \
             -vf "format=nv12,hwupload" -c:v "$enc" -f null - >/dev/null 2>&1; then
          FF_VAAPI_DEVICE="$dev"
          return 0
        fi
      done
      return 1
      ;;
  esac
  run_ffmpeg -y -v error "${pre[@]}" \
    -f lavfi -i "testsrc2=duration=1:size=640x360:rate=24" \
    -c:v "$enc" -f null - >/dev/null 2>&1
}

detect_ffmpeg_capabilities() {
  ffmpeg_lists_filter  "libvmaf"    && FF_HAS_LIBVMAF=true
  ffmpeg_lists_filter  "libplacebo" && FF_HAS_LIBPLACEBO=true
  ffmpeg_lists_encoder "libsvtav1"  && FF_HAS_LIBSVTAV1=true
  ffmpeg_lists_encoder "libx265"    && FF_HAS_LIBX265=true
  ffmpeg_lists_encoder "libopus"    && FF_HAS_LIBOPUS=true
  AB_AV1_BIN="$(command -v ab-av1 2>/dev/null || true)"

  # Hardware encoders: probe in quality-per-bit order, keep the first that works.
  local enc
  for enc in av1_nvenc av1_qsv av1_vaapi; do
    ffmpeg_lists_encoder "$enc" && probe_ffmpeg_encoder "$enc" && { FF_AV1_HW="$enc"; break; }
  done
  for enc in hevc_nvenc hevc_qsv hevc_videotoolbox hevc_vaapi hevc_amf; do
    ffmpeg_lists_encoder "$enc" && probe_ffmpeg_encoder "$enc" && { FF_HEVC_HW="$enc"; break; }
  done

  log "ffmpeg caps: libvmaf=$FF_HAS_LIBVMAF svtav1=$FF_HAS_LIBSVTAV1 x265=$FF_HAS_LIBX265 libplacebo=$FF_HAS_LIBPLACEBO ab-av1=${AB_AV1_BIN:-no}"
  log "ffmpeg hw encoders (functional probe): av1=${FF_AV1_HW:-none} hevc=${FF_HEVC_HW:-none}"

  if [ "$ENCODE_ENGINE" = auto ]; then
    if [ "$FF_HAS_LIBSVTAV1" = true ] && [ "$FF_HAS_LIBX265" = true ]; then
      ENCODE_ENGINE=ffmpeg
    else
      warn "ffmpeg lacks libsvtav1/libx265 — falling back to HandBrake engine (install a full ffmpeg build for VMAF-targeted encoding)"
      ENCODE_ENGINE=handbrake
    fi
  fi
  if [ "$ENCODE_ENGINE" = ffmpeg ] && [ "$FF_HAS_LIBVMAF" != true ] && [ "$VMAF_DISABLED" != true ]; then
    warn "ffmpeg has no libvmaf — VMAF targeting disabled, using fixed CRFs (install a libvmaf-enabled ffmpeg, e.g. BtbN static build, for per-title quality targeting)"
    VMAF_DISABLED=true
  fi
  log "encode engine: $ENCODE_ENGINE (files)$( [ "$ENCODE_ENGINE" = ffmpeg ] && printf '; HandBrake retained for disc sources' )"
}

# --- mount options audit (advisory only) ------------------------------------

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
      mnt="$(df -P "$p" 2>/dev/null | tail -1 | sed -E 's/^.*[0-9]+% *//')"
      [ -n "$mnt" ] || mnt="$(df "$p" 2>/dev/null | tail -1 | awk '{print $NF}')"
      line="$(/sbin/mount | grep -F " on $mnt (" | head -1)"
      case "$line" in
        *"(nfs"*) [ "${line#*read-only}" != "$line" ] && warn "mount audit: $p is mounted READ-ONLY" ;;
        *"(smbfs"*) warn "mount audit: $p is SMB on macOS — NFS usually performs better for encode I/O" ;;
      esac
      return 0
      ;;
  esac
  command -v findmnt >/dev/null 2>&1 || return 0
  src="$(findmnt -no SOURCE --target "$p" 2>/dev/null)" || return 0
  fstype="$(findmnt -no FSTYPE --target "$p" 2>/dev/null)"
  opts="$(findmnt -no OPTIONS --target "$p" 2>/dev/null)"
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

# --- HDR / Dolby Vision helpers ---------------------------------------------

source_is_hdr_transfer() {
  local trc
  trc="$(video_color_transfer "$1")"
  case "$trc" in smpte2084|arib-std-b67) return 0 ;; esac
  return 1
}

source_dovi_profile() {
  run_ffprobe -v error -select_streams v:0 \
    -show_entries stream_side_data=dv_profile -of csv=p=0 "$1" 2>/dev/null \
    | grep -E '^[0-9]+$' | head -1
}

# Extract HDR10 static metadata from the first frame; prints two lines:
#   G(x,y)B(x,y)R(x,y)WP(x,y)L(max,min)   (SVT/x265 master-display string, or empty)
#   maxcll,maxfall                        (or empty)
extract_hdr10_static_metadata() {
  local src="$1"
  run_ffprobe -v error -select_streams v:0 -show_frames -read_intervals "%+#1" \
    -show_entries frame_side_data_list "$src" 2>/dev/null | awk -F= '
    /side_data_type=Mastering display metadata/ { md=1 }
    /side_data_type=Content light level metadata/ { cll=1 }
    /^red_x=/ {rx=$2} /^red_y=/ {ry=$2} /^green_x=/ {gx=$2} /^green_y=/ {gy=$2}
    /^blue_x=/ {bx=$2} /^blue_y=/ {by=$2}
    /^white_point_x=/ {wx=$2} /^white_point_y=/ {wy=$2}
    /^min_luminance=/ {minl=$2} /^max_luminance=/ {maxl=$2}
    /^max_content=/ {mc=$2} /^max_average=/ {ma=$2}
    function frac(s,  a) { n=split(s, a, "/"); if (n==2 && a[2]+0>0) return a[1]/a[2]; return s+0 }
    END {
      if (md && maxl != "")
        printf "G(%.4f,%.4f)B(%.4f,%.4f)R(%.4f,%.4f)WP(%.4f,%.4f)L(%.1f,%.4f)\n",
          frac(gx),frac(gy),frac(bx),frac(by),frac(rx),frac(ry),frac(wx),frac(wy),frac(maxl),frac(minl)
      else print ""
      if (cll) printf "%d,%d\n", mc+0, ma+0; else print ""
    }'
}

# --- ffmpeg encode argument builders ----------------------------------------

# Sets FF_VIDEO_ARGS (array) for the chosen codec/quality/profile.
# Args: codec(av1|hevc) crf src anime(true|false) hdr(true|false)
build_ffmpeg_video_args() {
  local codec="$1" crf="$2" src="$3" anime="$4" hdr="$5"
  local svtp x265p md cll dovi
  FF_VIDEO_ARGS=()
  FF_VF=()

  # 1080p upscale rule carried over from v4
  if source_triggers_1080p_upscale "$src"; then
    FF_VF+=("scale=1920:-2:flags=lanczos")
  fi

  if [ "$hdr" = true ]; then
    dovi="$(source_dovi_profile "$src")"
    if [ "$dovi" = "5" ]; then
      if [ "$FF_HAS_LIBPLACEBO" = true ]; then
        log "Dolby Vision profile 5 — converting to HDR10 via libplacebo"
        FF_VF+=("libplacebo=colorspace=bt2020nc:color_primaries=bt2020:color_trc=pq:format=yuv420p10le")
      else
        return 2   # caller flags for human review
      fi
    elif [ -n "$dovi" ]; then
      log "Dolby Vision profile $dovi — dropping RPU, keeping HDR10 base layer"
    fi
  fi

  local _hdrmeta
  _hdrmeta="$(extract_hdr10_static_metadata "$src")"
  md="$(printf '%s\n' "$_hdrmeta" | sed -n 1p)"
  cll="$(printf '%s\n' "$_hdrmeta" | sed -n 2p)"

  case "$codec" in
    av1)
      svtp="enable-qm=1:qm-min=0:keyint=15s:scd=1:aq-mode=2"
      if [ "$anime" = true ]; then
        svtp="$svtp:film-grain-denoise=1:film-grain=12:enable-tf=0:enable-variance-boost=1:variance-boost-strength=3:variance-octile=4:enable-overlays=1"
      fi
      if [ "$hdr" = true ]; then
        svtp="$svtp:enable-hdr=1"
        [ -n "$md" ] && svtp="$svtp:mastering-display=$md"
        [ -n "$cll" ] && svtp="$svtp:content-light=$cll"
      fi
      FF_VIDEO_ARGS=(-c:v libsvtav1 -preset "$SVT_PRESET_FINAL" -crf "$crf"
                     -pix_fmt yuv420p10le -svtav1-params "$svtp")
      ;;
    hevc)
      x265p="log-level=error:keyint=240:min-keyint=24:bframes=8:ref=5:rc-lookahead=40:aq-mode=3:psy-rd=2.0:psy-rdoq=1.0:deblock=-1,-1"
      if [ "$anime" = true ]; then
        x265p="log-level=error:tune=animation:keyint=240:min-keyint=24:bframes=8:ref=4:rc-lookahead=30:aq-mode=2:psy-rd=1.5:psy-rdoq=0.8"
      fi
      if [ "$hdr" = true ]; then
        x265p="$x265p:hdr10=1:repeat-headers=1"
        [ -n "$md" ] && x265p="$x265p:master-display=$md"
        [ -n "$cll" ] && x265p="$x265p:max-cll=$cll"
      fi
      FF_VIDEO_ARGS=(-c:v libx265 -preset "$X265_PRESET_FINAL" -crf "$crf"
                     -pix_fmt yuv420p10le -x265-params "$x265p")
      ;;
  esac

  if [ "$hdr" = true ]; then
    FF_VIDEO_ARGS+=(-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc)
  fi
  return 0
}

# --- VMAF-targeted CRF search -------------------------------------------------

vmaf_model_for_source() {
  local h
  h="$(video_height "$1")"
  if [ "${h:-0}" -gt 1600 ]; then
    printf 'version=vmaf_4k_v0.6.1'
  else
    printf 'version=vmaf_v0.6.1neg'
  fi
}

vmaf_target_for_source() {
  local src="$1"
  local h
  if uses_anime_profile "$src"; then printf '%s' "$VMAF_TARGET_ANIME"; return; fi
  h="$(video_height "$src")"
  if [ "${h:-0}" -gt 1600 ]; then printf '%s' "$VMAF_TARGET_4K"; return; fi
  printf '%s' "$VMAF_TARGET_MOVIE"
}

fixed_crf_for() {  # codec anime hdr
  local codec="$1" anime="$2" hdr="$3"
  case "$codec" in
    av1)
      [ "$hdr" = true ]   && { printf '%s' "$FIXED_CRF_SVT_HDR"; return; }
      [ "$anime" = true ] && { printf '%s' "$FIXED_CRF_SVT_ANIME"; return; }
      printf '%s' "$FIXED_CRF_SVT_MOVIE" ;;
    hevc)
      [ "$hdr" = true ]   && { printf '%s' "$FIXED_CRF_X265_HDR"; return; }
      [ "$anime" = true ] && { printf '%s' "$FIXED_CRF_X265_ANIME"; return; }
      printf '%s' "$FIXED_CRF_X265_MOVIE" ;;
  esac
}

# One sample-encode + VMAF score. Prints "vmaf bytes". Messages go to stderr.
_vmaf_score_one() {  # clip out_crf codec model
  local clip="$1" crf="$2" codec="$3" model="$4"
  local out vlog v
  out="${clip%.mkv}-enc-$codec-$crf.mkv"
  vlog="${out%.mkv}.vmaf.json"
  case "$codec" in
    av1)
      run_ffmpeg -y -v error -i "$clip" -c:v libsvtav1 -preset "$SVT_PRESET_SEARCH" -crf "$crf" \
        -pix_fmt yuv420p10le -svtav1-params "enable-qm=1:qm-min=0" -an "$out" 2>/dev/null || return 1 ;;
    hevc)
      run_ffmpeg -y -v error -i "$clip" -c:v libx265 -preset medium -crf "$crf" \
        -pix_fmt yuv420p10le -x265-params "log-level=error" -an "$out" 2>/dev/null || return 1 ;;
  esac
  run_ffmpeg -y -v error -i "$out" -i "$clip" -lavfi \
    "[0:v]setpts=PTS-STARTPTS,format=yuv420p10le[d];[1:v]setpts=PTS-STARTPTS,format=yuv420p10le[r];[d][r]libvmaf=model=$model:n_threads=$(nproc 2>/dev/null || sysctl -n hw.ncpu):log_fmt=json:log_path=$vlog" \
    -f null - 2>/dev/null || return 1
  v="$(python3 -c "import json;print(round(json.load(open('$vlog'))['pooled_metrics']['vmaf']['mean'],2))" 2>/dev/null)" || return 1
  printf '%s %s' "$v" "$(file_size_bytes "$out")"
}

# Per-title CRF search. Prints "crf predicted_bytes achieved_vmaf" or fails.
# Internal engine — used when ab-av1 is absent.
vmaf_crf_search_internal() {  # src codec target model
  local src="$1" codec="$2" target="$3" model="$4"
  local work dur clip_bytes=0 i start clip
  local -a clips=()
  local -A score=() bytes=()
  work="$(mktemp -d)"

  dur="$(video_duration "$src")"
  dur="${dur%.*}"
  [ -n "$dur" ] && [ "$dur" -ge $(( VMAF_SAMPLE_SECS * 3 )) ] || { rm -rf "$work"; return 1; }
  # short sources: fewer samples rather than no search
  local nsamples="$VMAF_SAMPLES"
  while [ "$nsamples" -gt 1 ] && [ "$dur" -lt $(( VMAF_SAMPLE_SECS * nsamples * 2 )) ]; do
    nsamples=$(( nsamples - 1 ))
  done

  for ((i = 1; i <= nsamples; i++)); do
    start=$(( dur * (i * 2 - 1) / (nsamples * 2) ))
    clip="$work/clip$i.mkv"
    run_ffmpeg -y -v error -ss "$start" -t "$VMAF_SAMPLE_SECS" -i "$src" \
      -map 0:v:0 -c copy "$clip" 2>/dev/null || { rm -rf "$work"; return 1; }
    [ -s "$clip" ] || { rm -rf "$work"; return 1; }
    clips+=("$clip")
    clip_bytes=$(( clip_bytes + $(file_size_bytes "$clip") ))
  done

  _probe_crf() {  # crf -> populates score/bytes; totals across all samples
    local crf="$1" vsum=0 btot=0 c r v b
    [ -n "${score[$crf]:-}" ] && return 0
    for c in "${clips[@]}"; do
      r="$(_vmaf_score_one "$c" "$crf" "$codec" "$model")" || return 1
      v="${r%% *}"; b="${r##* }"
      vsum="$(awk -v a="$vsum" -v x="$v" 'BEGIN{print a+x}')"
      btot=$(( btot + b ))
    done
    score[$crf]="$(awk -v s="$vsum" -v n="${#clips[@]}" 'BEGIN{printf "%.2f", s/n}')"
    bytes[$crf]=$btot
    log_err "  crf-search [$codec] crf=$crf vmaf=${score[$crf]}"
  }

  # Coarse anchors, then bisect the target crossing.
  local anchors="22 30 38" crf above below gap
  for crf in $anchors; do _probe_crf "$crf" || { rm -rf "$work"; return 1; }; done
  for i in 1 2 3; do
    above=""; below=""
    for crf in $(printf '%s\n' "${!score[@]}" | sort -n); do
      if awk -v s="${score[$crf]}" -v t="$target" 'BEGIN{exit !(s>=t)}'; then above="$crf"; else below="$crf"; break; fi
    done
    if [ -z "$above" ]; then _probe_crf "$VMAF_SEARCH_MIN_CRF" || break; continue; fi
    if [ -z "$below" ]; then _probe_crf "$VMAF_SEARCH_MAX_CRF" || break; continue; fi
    gap=$(( below - above )); [ "$gap" -le 1 ] && break
    _probe_crf $(( above + gap / 2 )) || break
  done

  local best="" bv="" bb=""
  for crf in $(printf '%s\n' "${!score[@]}" | sort -n); do
    if awk -v s="${score[$crf]}" -v t="$target" 'BEGIN{exit !(s>=t)}'; then
      best="$crf"; bv="${score[$crf]}"; bb="${bytes[$crf]}"
    fi
  done
  rm -rf "$work"
  [ -n "$best" ] || return 1
  local orig pred
  orig="$(file_size_bytes "$src")"
  pred="$(awk -v o="$orig" -v c="$clip_bytes" -v e="$bb" 'BEGIN{ if (c<=0) {print 0; exit}; printf "%d", o*(e/c) }')"
  printf '%s %s %s' "$best" "$pred" "$bv"
}

# ab-av1 crf-search wrapper. Prints "crf predicted_size achieved_vmaf".
# Final stdout line: "crf 21.25 VMAF 94.19 predicted video stream size 22.47 MiB (17%) taking 60 seconds"
vmaf_crf_search_abav1() {  # src codec target model
  local src="$1" codec="$2" target="$3" model="$4"
  local enc preset out line crf vmaf pred
  case "$codec" in
    av1)  enc="libsvtav1"; preset="$SVT_PRESET_SEARCH" ;;
    hevc) enc="libx265";   preset="medium" ;;
  esac
  out="$("$AB_AV1_BIN" crf-search -i "$src" -e "$enc" --preset "$preset" \
          --min-vmaf "$target" --min-crf "$VMAF_SEARCH_MIN_CRF" --max-crf "$VMAF_SEARCH_MAX_CRF" \
          --sample-duration "${VMAF_SAMPLE_SECS}s" --samples "$VMAF_SAMPLES" \
          --vmaf "model=$model" 2>/dev/null)" || return 1
  line="$(printf '%s\n' "$out" | grep -E '^crf [0-9.]+ VMAF' | tail -1)"
  # CRFs can be fractional (21.25) — round DOWN (lower CRF = safer/higher quality)
  crf="$(printf '%s' "$line" | sed -n 's/^crf \([0-9.]*\) .*/\1/p' | awk '{printf "%d", $1}')"
  vmaf="$(printf '%s' "$line" | sed -n 's/.*VMAF \([0-9.]*\).*/\1/p')"
  pred="$(printf '%s' "$line" | sed -n 's/.*predicted video stream size \([0-9.]*[[:space:]]*[KMGT]iB\).*/\1/p' | tr -d ' ')"
  [ -n "$crf" ] || return 1
  printf '%s %s %s' "$crf" "${pred:-0}" "${vmaf:-0}"
}

# Resolve the CRF for a source+codec. Echoes CRF; logs how it was chosen.
resolve_crf_for_encode() {  # src codec anime hdr
  local src="$1" codec="$2" anime="$3" hdr="$4"
  local key="${codec}:${src}" target model res crf pred vmaf

  if [ -n "${VMAF_CRF_CACHE[$key]:-}" ]; then
    printf '%s' "${VMAF_CRF_CACHE[$key]}"
    return 0
  fi

  if [ "$hdr" = true ] || [ "$VMAF_DISABLED" = true ] || [ "$FF_HAS_LIBVMAF" != true ]; then
    crf="$(fixed_crf_for "$codec" "$anime" "$hdr")"
    [ "$hdr" = true ] && log_err "HDR source — fixed CRF $crf (VMAF unreliable on PQ/HLG)" \
                      || log_err "Fixed CRF $crf ($codec$( [ "$anime" = true ] && printf ', anime'))"
    VMAF_CRF_CACHE[$key]="$crf"
    printf '%s' "$crf"
    return 0
  fi

  target="$(vmaf_target_for_source "$src")"
  model="$(vmaf_model_for_source "$src")"
  if [ "$DRY_RUN" = true ]; then
    crf="$(fixed_crf_for "$codec" "$anime" "$hdr")"
    log_err "[dry-run] Would VMAF-search CRF (target=$target model=${model#version=}); reporting fixed CRF $crf"
    VMAF_CRF_CACHE[$key]="$crf"
    printf '%s' "$crf"
    return 0
  fi
  log_err "VMAF CRF search: target=$target model=${model#version=} codec=$codec"
  if [ -n "$AB_AV1_BIN" ]; then
    res="$(vmaf_crf_search_abav1 "$src" "$codec" "$target" "$model")" || res=""
  fi
  if [ -z "${res:-}" ]; then
    res="$(vmaf_crf_search_internal "$src" "$codec" "$target" "$model")" || res=""
  fi
  if [ -z "$res" ]; then
    crf="$(fixed_crf_for "$codec" "$anime" "$hdr")"
    warn "VMAF search failed or no CRF met target — fixed CRF $crf"
  else
    read -r crf pred vmaf <<<"$res"
    case "$pred" in
      *iB) log_err "VMAF search chose CRF $crf (sample VMAF $vmaf >= $target; predicted video ~$pred)" ;;
      *)   log_err "VMAF search chose CRF $crf (sample VMAF $vmaf >= $target; predicted $(human_size_bytes "${pred:-0}"))" ;;
    esac
  fi
  VMAF_CRF_CACHE[$key]="$crf"
  printf '%s' "$crf"
}

# --- full-file ffmpeg encode --------------------------------------------------

# ffmpeg_encode src dst codec(av1|hevc)
# Maps all streams; video per build_ffmpeg_video_args; audio Opus (av1) / AAC
# (hevc) matching v4 policy; subtitles copied (mov_text converted for MKV).
# Dialogue-clarity audio filter: matches v4's HandBrake -D/--gain behavior
# (dynamic range compression + static gain) via ffmpeg's dynaudnorm + volume.
# AUDIO_DRC (HandBrake scale, 1.0=none) maps to dynaudnorm's max-gain factor;
# AUDIO_GAIN (dB) applies as a static gain afterward. Always applied — v4
# applies -D/--gain to every audio track regardless of codec.
ffmpeg_audio_filter_chain() {
  local acodec="$1" mgain chain
  mgain="$(awk -v d="$AUDIO_DRC" 'BEGIN{printf "%.1f", d*5}')"
  chain="dynaudnorm=f=250:g=15:m=${mgain},volume=${AUDIO_GAIN}dB"
  if [ "$acodec" = libopus ]; then
    chain="aformat=channel_layouts=7.1|5.1|stereo|mono,$chain"
  fi
  printf '%s' "$chain"
}

ffmpeg_encode() {
  local src="$1" dst="$2" codec="$3"
  local anime=false hdr=false crf rc acodec abr
  local -a args sub_args

  uses_anime_profile "$src" && anime=true
  source_is_hdr_transfer "$src" && hdr=true

  crf="$(resolve_crf_for_encode "$src" "$codec" "$anime" "$hdr")"

  rc=0
  build_ffmpeg_video_args "$codec" "$crf" "$src" "$anime" "$hdr" || rc=$?
  if [ "$rc" -eq 2 ]; then
    flag_bad_source_for_human "$src" "Dolby Vision profile 5 requires libplacebo (not in this ffmpeg build)"
    return 1
  fi

  case "$codec" in
    av1)  if [ "$FF_HAS_LIBOPUS" = true ]; then acodec="libopus"; abr="$OPUS_BITRATE_V5"; else acodec="aac"; abr="$AAC_BITRATE_V5"; fi ;;
    hevc) acodec="aac"; abr="$AAC_BITRATE_V5" ;;
  esac

  # Subtitle handling: bitmap+text subs copy into MKV; mp4 mov_text must convert.
  sub_args=(-c:s copy)
  case "$(to_lower "${src##*.}")" in
    mp4|m4v|mov) sub_args=(-c:s srt) ;;
  esac

  args=(-y -nostdin -v error -stats -i "$src"
        -map 0:v:0 -map "0:a?" -map "0:s?" -map "0:t?"
        -map_chapters 0
        "${FF_VIDEO_ARGS[@]}")
  local vf_joined=""
  if [ "${#FF_VF[@]}" -gt 0 ]; then
    vf_joined="$(IFS=,; printf '%s' "${FF_VF[*]}")"
    args+=(-vf "$vf_joined")
  fi
  args+=(-c:a "$acodec" -b:a "$abr" -af "$(ffmpeg_audio_filter_chain "$acodec")")
  [ "$acodec" = libopus ] && args+=(-mapping_family 1)
  args+=("${sub_args[@]}"
         -max_muxing_queue_size 2048
         -f matroska "$dst")

  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] ffmpeg ${args[*]}"
    return 0
  fi

  log "ffmpeg encode ($codec crf=$crf$( [ "$hdr" = true ] && printf ', HDR10')$( [ "$anime" = true ] && printf ', anime')): $(basename "$src")"
  run_ffmpeg "${args[@]}"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # Retry once without subtitles — odd sub codecs are the most common mux failure.
    warn "ffmpeg encode failed (rc=$rc) — retrying without subtitle streams"
    args=(-y -nostdin -v error -stats -i "$src"
          -map 0:v:0 -map "0:a?" -map_chapters 0
          "${FF_VIDEO_ARGS[@]}")
    if [ "${#FF_VF[@]}" -gt 0 ]; then
      args+=(-vf "$vf_joined")
    fi
    args+=(-c:a "$acodec" -b:a "$abr" -af "$(ffmpeg_audio_filter_chain "$acodec")")
    [ "$acodec" = libopus ] && args+=(-mapping_family 1)
    args+=(-max_muxing_queue_size 2048 -f matroska "$dst")
    run_ffmpeg "${args[@]}"
    rc=$?
  fi
  if [ "$rc" -eq 0 ] && [ ! -s "$dst" ]; then
    warn "ffmpeg reported success but output is missing/empty: $dst"
    rc=1
  fi
  return "$rc"
}

# --- engine dispatch ----------------------------------------------------------

# Route an encode to ffmpeg (files) or HandBrake (discs / --engine handbrake).
# Args mirror handbrake_encode: src dst hb_encoder gpu hb_title
encode_dispatch() {
  local src="$1" dst="$2" hb_encoder="$3" gpu="${4:-}" hb_title="${5:-}"
  local codec

  if [ "$ENCODE_ENGINE" = handbrake ] || [ -n "$hb_title" ] || is_disk_source "$src"; then
    handbrake_encode "$src" "$dst" "$hb_encoder" "$gpu" "$hb_title"
    return $?
  fi

  case "$hb_encoder" in
    *av1*) codec=av1 ;;
    *) codec=hevc ;;
  esac
  # ffmpeg-engine display names are not HandBrake encoders — normalize if a
  # disc/handbrake dispatch ever receives one
  case "$hb_encoder" in
    ffmpeg/*) hb_encoder="$( [ "$codec" = av1 ] && printf svt_av1_10bit || printf x265 )" ;;
  esac

  # --prefer-hw: hardware encoder at fixed quality (speed mode; no VMAF search)
  if [ "$PREFER_HW_ENCODE" = true ]; then
    local hw=""
    case "$codec" in av1) hw="$FF_AV1_HW" ;; hevc) hw="$FF_HEVC_HW" ;; esac
    if [ -n "$hw" ]; then
      ffmpeg_encode_hw "$src" "$dst" "$codec" "$hw"
      return $?
    fi
    warn "--prefer-hw set but no functional hardware $codec encoder — using software"
  fi

  ffmpeg_encode "$src" "$dst" "$codec"
}

# Hardware-encoder speed path (fixed quality, no VMAF search).
ffmpeg_encode_hw() {
  local src="$1" dst="$2" codec="$3" enc="$4"
  local -a vargs pre=()
  local q acodec abr

  case "$enc" in
    av1_nvenc)  q=30; vargs=(-c:v av1_nvenc -preset p7 -tune "${NVENC_AV1_TUNE:-hq}" -rc vbr -cq "$q" -b:v 0 -multipass fullres -spatial-aq 1 -temporal-aq 1 -highbitdepth 1) ;;
    av1_qsv)    q=28; vargs=(-c:v av1_qsv -global_quality "$q" -preset veryslow) ;;
    av1_vaapi)  q=30; pre=(-vaapi_device "${FF_VAAPI_DEVICE:-/dev/dri/renderD128}"); vargs=(-vf "format=nv12,hwupload" -c:v av1_vaapi -rc_mode CQP -qp "$q") ;;
    hevc_nvenc) q=24; vargs=(-c:v hevc_nvenc -preset p7 -tune hq -rc vbr -cq "$q" -b:v 0 -multipass fullres -spatial-aq 1 -temporal-aq 1) ;;
    hevc_qsv)   q=22; vargs=(-c:v hevc_qsv -global_quality "$q" -preset veryslow) ;;
    hevc_videotoolbox) q=58; vargs=(-c:v hevc_videotoolbox -q:v "$q" -tag:v hvc1) ;;
    hevc_vaapi) q=22; pre=(-vaapi_device "${FF_VAAPI_DEVICE:-/dev/dri/renderD128}"); vargs=(-vf "format=nv12,hwupload" -c:v hevc_vaapi -rc_mode CQP -qp "$q") ;;
    hevc_amf)   q=22; vargs=(-c:v hevc_amf -quality quality -rc cqp -qp_i "$q" -qp_p "$q") ;;
    *) return 1 ;;
  esac
  case "$codec" in
    av1)  if [ "$FF_HAS_LIBOPUS" = true ]; then acodec=libopus; abr="$OPUS_BITRATE_V5"; else acodec=aac; abr="$AAC_BITRATE_V5"; fi ;;
    hevc) acodec=aac; abr="$AAC_BITRATE_V5" ;;
  esac
  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] ffmpeg hw encode $enc q=$q: $src -> $dst"
    return 0
  fi
  log "ffmpeg hw encode ($enc q=$q): $(basename "$src")"
  local -a aextra=(-af "$(ffmpeg_audio_filter_chain "$acodec")")
  [ "$acodec" = libopus ] && aextra+=(-mapping_family 1)
  run_ffmpeg -y -nostdin -v error -stats "${pre[@]}" -i "$src" \
    -map 0:v:0 -map "0:a?" -map "0:s?" -map_chapters 0 \
    "${vargs[@]}" -c:a "$acodec" -b:a "$abr" "${aextra[@]}" -c:s copy \
    -max_muxing_queue_size 2048 -f matroska "$dst"
  local rc=$?
  [ "$rc" -eq 0 ] && [ ! -s "$dst" ] && { warn "hw encode empty output: $dst"; rc=1; }
  return "$rc"
}

# ============================================================================
# v5.0.3 — multi-part source detection, validation, and merge
# ============================================================================
# Some sources are split across files in the same folder (Part 1/Part 2, CD1/
# CD2, Disc 1/Disc 2, ...). These are merged into a single continuous source
# before encoding so the output plays as one file with no break — encoding
# each part separately would produce two output files and, worse, the size/
# quality logic would treat them as unrelated titles.
#
# Detection is filename-based (common patterns below). Compatibility is
# verified with ffprobe (codec, resolution, pixel format, frame rate) before
# any merge is attempted — mismatched parts are flagged for human review
# instead of silently concatenated. Merging uses mkvmerge's native append
# ('+') syntax, which mkvmerge itself further validates (it refuses to append
# tracks it considers incompatible). Originals are never deleted or modified;
# the merge output is a new sibling file '{Title}.merged.mkv'.
#
# Merges are cached: a state file records each part's size+mtime plus the
# merged output's own size+mtime; unchanged parts are not re-merged on
# subsequent runs (mirrors the mkv_structure_cache pattern used elsewhere).

MULTIPART_MISMATCH_LOG=""
declare -A MULTIPART_CONSUMED=()   # raw part path -> 1 (excluded from independent queueing)

multipart_part_regex() {
  # Captures: 1=title, 2=marker word (unused), 3=part number.
  # bash [[ =~ ]] is POSIX ERE — no (?:...) non-capturing groups, so the
  # marker is a real capture group and the number is BASH_REMATCH[3].
  printf '%s' '^(.*[^ ._-])[ ._-]*([Pp][Aa][Rr][Tt]|[Pp][Tt]|[Cc][Dd]|[Dd][Ii][Ss][Cc])[ ._-]*([0-9]{1,2})$'
}

# Groups candidate files in one directory by common title; returns groups with
# 2+ members via a nameref array of "title\tpart1|part2|..." (parts sorted by
# number, pipe-separated absolute paths). Non-multipart files are not emitted.
detect_multipart_groups() {
  local dir="$1"
  local -n _groups="$2"
  local -A by_title=()
  local -A order_key=()
  local f base stem ext title num re
  _groups=()

  # Multi-part merging is a movie feature (a film split across Part 1/Part
  # 2/CD1/CD2 discs). "Show - S01E15 - Part 1.mkv" / "Part 2.mkv" are two
  # SEPARATE episodes in every TV naming convention -- same codec/res, so the
  # compat check would pass and mkvmerge would happily concatenate two
  # distinct episodes into one .merged.mkv. A season/show folder is far more
  # likely to hold two-part episodes than a genuinely split movie, so skip
  # multipart detection entirely here.
  is_tv_show_directory "$dir" && return 0

  re="$(multipart_part_regex)"

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="${f##*/}"
    is_derived_output "$f" && continue
    is_multipart_merged_file "$f" && continue
    stem="${base%.*}"
    ext="${base##*.}"
    if [[ "$stem" =~ $re ]]; then
      title="${BASH_REMATCH[1]}"
      num="${BASH_REMATCH[3]}"
      # Zero-pad the sort key so "2" sorts before "10"
      by_title["$title|$ext"]+="$(printf '%03d' "$((10#$num))")::$f"$'\n'
    fi
  done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null)

  local key entries sorted parts
  for key in "${!by_title[@]}"; do
    entries="${by_title[$key]}"
    sorted="$(printf '%s' "$entries" | sort -t: -k1,1)"
    parts="$(printf '%s' "$sorted" | sed -E 's/^[0-9]+:://' | paste -sd'|' -)"
    # require at least 2 parts to treat as a multi-part group
    [ "$(printf '%s' "$parts" | tr '|' '\n' | grep -c .)" -ge 2 ] || continue
    title="${key%|*}"
    _groups+=("${title}"$'\t'"${parts}")
  done
}

# ffprobe-based compatibility check across all parts. Returns 0 if all parts
# share codec/resolution/pix_fmt/frame-rate; logs the mismatch otherwise.
multipart_parts_compatible() {
  local -a parts=("$@")
  local ref="" cur p
  for p in "${parts[@]}"; do
    cur="$(run_ffprobe -v error -select_streams v:0 \
      -show_entries stream=codec_name,width,height,pix_fmt,avg_frame_rate \
      -of csv=p=0 "$p" 2>/dev/null)"
    if [ -z "$ref" ]; then
      ref="$cur"
    elif [ "$cur" != "$ref" ]; then
      warn "Multi-part mismatch — '$(basename "$p")' differs from '$(basename "${parts[0]}")' (codec/resolution/pix_fmt/fps): $cur vs $ref"
      return 1
    fi
  done
  return 0
}

multipart_state_key() {  # concatenated size|mtime of every part, for cache invalidation
  local p key=""
  for p in "$@"; do
    key+="$(mkv_structure_stat_key "$p" 2>/dev/null || printf 'x')|"
  done
  printf '%s' "$key"
}

# Merge one detected group. Prints the merged file's absolute path on success
# (stdout only); all logging goes to stderr. Returns 1 on validation/merge
# failure (group is left for independent per-part processing).
ensure_multipart_merge() {
  local dir="$1" title="$2" parts_pipe="$3"
  local -a parts=()
  IFS='|' read -r -a parts <<<"$parts_pipe"
  local merged="$dir/$title.merged.mkv"
  local state="$dir/.${title}.multipart-merge.state"
  local want_key have_key

  want_key="$(multipart_state_key "${parts[@]}")"
  if [ -f "$merged" ] && [ -f "$state" ]; then
    have_key="$(cat "$state" 2>/dev/null)"
    if [ "$have_key" = "$want_key" ]; then
      printf '%s' "$merged"
      return 0
    fi
    log_err "Multi-part source changed since last merge — re-merging: $title"
  elif [ -f "$merged" ] && [ ! -f "$state" ]; then
    # A regular file already sits at this exact name, but we have no record
    # (.state) of having created it ourselves. "Title.merged.mkv" is an
    # unusual enough pattern that this is unlikely by coincidence, but
    # mkvmerge -o would silently overwrite it either way -- refuse rather
    # than guess.
    warn "Multi-part merge target already exists with no record of us creating it — leaving as-is for human review: $merged"
    return 1
  fi

  if ! multipart_parts_compatible "${parts[@]}"; then
    printf '%s\n' "${parts[@]}" >>"${MULTIPART_MISMATCH_LOG:-/dev/null}" 2>/dev/null
    warn "Multi-part group '$title' has incompatible parts — left as separate sources for human review"
    return 1
  fi

  log_err "Multi-part source detected (${#parts[@]} files) — merging: $title"
  if [ "$DRY_RUN" = true ]; then
    log_err "[dry-run] Would merge: ${parts[*]}"
    return 1
  fi

  # $merged is a predictable name (Title.merged.mkv) beside real source
  # parts. mkvmerge -o follows a symlink there and overwrites whatever it
  # points to, which need not be related to this title at all.
  _neutralize_symlink_sidecar_path "$merged"
  _neutralize_symlink_sidecar_path "$state"

  local -a mm_args=(-o "$merged" --quiet)
  local i
  for i in "${!parts[@]}"; do
    if [ "$i" -eq 0 ]; then
      mm_args+=("${parts[$i]}")
    else
      mm_args+=(+ "${parts[$i]}")
    fi
  done

  # mkvmerge exit codes: 0 clean, 1 succeeded with warnings (e.g. no explicit
  # --append-to given — harmless for a simple sequential append), 2 real failure.
  local mm_rc=0
  run_mkvmerge "${mm_args[@]}" >/dev/null 2>&1 || mm_rc=$?
  if [ "$mm_rc" -ge 2 ]; then
    rm -f "$merged"
    warn "mkvmerge failed to append multi-part group '$title' (exit $mm_rc) — left as separate sources for human review"
    printf '%s\n' "${parts[@]}" >>"${MULTIPART_MISMATCH_LOG:-/dev/null}" 2>/dev/null
    return 1
  fi
  if [ ! -s "$merged" ]; then
    warn "Multi-part merge produced an empty file — discarding: $merged"
    rm -f "$merged"
    return 1
  fi

  printf '%s' "$want_key" >"$state"
  log_err "Multi-part merge OK: $title ($(human_size_bytes "$(file_size_bytes "$merged")"))"
  printf '%s' "$merged"
}

# Rewrites a nameref array of discovered file paths: detects multi-part
# groups per directory, merges them (cached), substitutes the merged file for
# the raw parts, and drops raw parts that were successfully consumed. Files
# that are not part of any group pass through unchanged. Called from
# find_convert_videos_under / find_videos_at_root — every scan path benefits.
apply_multipart_merging() {
  local -n _files="$1"
  [ "${#_files[@]}" -gt 0 ] || return 0
  [ -n "${MULTIPART_MISMATCH_LOG:-}" ] || MULTIPART_MISMATCH_LOG="${JOB_SIDECAR_DIR:-$JOB_ROOT}/multipart_mismatch.txt"

  local -A dirs_seen=()
  local f d
  for f in "${_files[@]}"; do
    d="$(dirname "$f")"
    dirs_seen["$d"]=1
  done

  local -A merged_for_dir=()   # dir -> "merged1 merged2 ..." (space-joined)
  for d in "${!dirs_seen[@]}"; do
    local -a groups=()
    detect_multipart_groups "$d" groups
    [ "${#groups[@]}" -gt 0 ] || continue
    local g title parts_pipe merged
    for g in "${groups[@]}"; do
      title="${g%%$'\t'*}"
      parts_pipe="${g#*$'\t'}"
      merged="$(ensure_multipart_merge "$d" "$title" "$parts_pipe")" || continue
      [ -n "$merged" ] || continue
      merged_for_dir["$d"]+="$merged"$'\n'
      local -a consumed=()
      IFS='|' read -r -a consumed <<<"$parts_pipe"
      local cp
      for cp in "${consumed[@]}"; do MULTIPART_CONSUMED["$cp"]=1; done
    done
  done

  [ "${#MULTIPART_CONSUMED[@]}" -gt 0 ] || return 0

  # A source directory may be scanned more than once in a single run (batch
  # mode re-inspects before queueing); once a merge exists on disk, a later
  # raw find() will see the .merged.mkv file directly as an ordinary video —
  # dedupe against what passthrough already added, not just against itself.
  local -a out=()
  local seen="|"
  for f in "${_files[@]}"; do
    if [ -n "${MULTIPART_CONSUMED[$f]:-}" ]; then
      continue
    fi
    case "$seen" in *"|$f|"*) continue ;; esac
    seen+="$f|"
    out+=("$f")
  done
  for d in "${!merged_for_dir[@]}"; do
    while IFS= read -r merged; do
      [ -n "$merged" ] || continue
      case "$seen" in *"|$merged|"*) continue ;; esac
      seen+="$merged|"
      out+=("$merged")
    done <<<"${merged_for_dir[$d]}"
  done
  _files=("${out[@]}")
}


# ============================================================================
# v5.0.7 — per-directory file-list cache (fixes slow restart enumeration)
# ============================================================================
# find_convert_videos_under() previously re-ran a full recursive `find` over
# the entire --path on every single launch. For a region like
# Television/American (~1,000 show folders, 40k+ episodes) that's thousands
# of NFS readdir+stat round trips every time, even when nothing changed —
# this is the actual source of the ~6 hour restart-enumeration cost reported
# in production, independent of --shard-depth/--no-shard/--name-glob (those
# control how work is grouped, not how many directories get walked).
#
# Fix: cache each immediate subdirectory's file list keyed to that
# subdirectory's own mtime. A show folder's mtime only changes when a file is
# added/removed/renamed directly inside it (standard POSIX behavior) — so on
# a restart where nothing changed, this replaces ~40k file stats with ~1,000
# directory stats, then reuses the cached list for every unchanged folder.
# Works regardless of --shard-depth/--no-shard, since it caches at the
# immediate-subdirectory level inside find_convert_videos_under itself, not
# at the --shard-depth the caller chose for job-queue grouping.

FILECACHE_DIR=""

filecache_init() {
  FILECACHE_DIR="${JOB_SIDECAR_DIR:-$JOB_ROOT}/.convert-v5-filecache"
}

_filecache_key() {
  # Portable path->filename hash: sha1sum (Linux) or shasum -a 1 (macOS).
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha1sum | cut -d' ' -f1
  else
    printf '%s' "$1" | shasum -a 1 | cut -d' ' -f1
  fi
}

# A directory's own mtime only changes when a DIRECT child is added/removed/
# renamed (POSIX). For a nested layout like Show/Season 2/new-episode.mkv,
# adding that episode bumps Season 2's mtime, not Show's -- so keying the
# cache on Show's own mtime alone means new episodes added deep inside a
# season folder are invisible forever (cache/done-flag never invalidates).
# Fix: key on the MAX mtime across the directory and every subdirectory in
# its subtree. Cost is proportional to the number of subdirectories (season
# folders — tens, not the thousands of episode files this cache exists to
# avoid re-stating on every restart), so this keeps the original performance
# win while actually detecting changes anywhere in the subtree.
dir_subtree_max_mtime() {
  local dir="$1"
  # One python3 process walking the whole subtree, not one process PER
  # subdirectory (a season-heavy show folder over NFS previously spawned a
  # python3 + its own stat() round trip for every season dir on every call).
  python3 - "$dir" <<'PY' 2>/dev/null
import os, sys
root = sys.argv[1]
best = 0
try:
    best = int(os.stat(root).st_mtime)
except OSError:
    pass
for cur, dirs, _ in os.walk(root):
    for d in dirs:
        try:
            mt = int(os.stat(os.path.join(cur, d)).st_mtime)
        except OSError:
            continue
        if mt > best:
            best = mt
print(best)
PY
}

filecache_get() {  # dir -> file list on stdout; returns 1 on cache miss
  local dir="$1" cache mtime cached_mtime
  [ -n "$FILECACHE_DIR" ] || return 1
  cache="$FILECACHE_DIR/$(_filecache_key "$dir").list"
  [ -f "$cache" ] || return 1
  mtime="$(dir_subtree_max_mtime "$dir")"
  [ -n "$mtime" ] || return 1
  cached_mtime="$(sed -n 1p "$cache" 2>/dev/null)"
  [ "$mtime" = "$cached_mtime" ] || return 1
  tail -n +2 "$cache" 2>/dev/null
  return 0
}

filecache_put() {  # dir, nameref file-list array
  local dir="$1"
  local -n _files_ref="$2"
  local cache mtime
  [ -n "$FILECACHE_DIR" ] || return 0
  mkdir -p "$FILECACHE_DIR" 2>/dev/null || return 0
  mtime="$(dir_subtree_max_mtime "$dir")"
  [ -n "$mtime" ] || return 0
  cache="$FILECACHE_DIR/$(_filecache_key "$dir").list"
  # Write to a temp file and rename into place atomically -- a direct
  # `>"$cache"` write that's interrupted (crash, NFS hiccup, another fleet
  # machine reading mid-write) can leave just the mtime header on disk.
  # filecache_get() would then read that as a valid cache hit with an empty
  # file list, silently treating every video in the folder as gone until the
  # directory's mtime changes again. mktemp's randomized suffix (not just
  # the PID) keeps this name unpredictable -- a PID alone is guessable/
  # enumerable by another local process wanting to race a symlink into place.
  local cache_tmp
  cache_tmp="$(mktemp "${cache}.XXXXXX")" || return 0
  { printf '%s\n' "$mtime"; printf '%s\n' "${_files_ref[@]}"; } >"$cache_tmp" 2>/dev/null \
    && mv -f "$cache_tmp" "$cache" 2>/dev/null \
    || rm -f "$cache_tmp" 2>/dev/null
}

# Cache-accelerated recursive video find. Falls back to a flat find when
# root has no subdirectories (a single show/movie folder — nothing to cache
# at a coarser level than the flat scan itself).
find_convert_videos_under_cached() {
  local root="$1"
  local -a pred=() raw=() subdirs=()
  build_find_video_pred pred

  while IFS= read -r d; do [ -n "$d" ] && subdirs+=("$d"); done \
    < <(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | LC_ALL=C sort)

  if [ "${#subdirs[@]}" -eq 0 ]; then
    while IFS= read -r f; do [ -n "$f" ] && raw+=("$f"); done \
      < <(find "$root" -type f "${pred[@]}" 2>/dev/null)
    printf '%s\n' "${raw[@]}"
    return 0
  fi

  local d hits=0 misses=0 done_skips=0 cached sub_out
  for d in "${subdirs[@]}"; do
    if folder_marked_done "$d"; then
      done_skips=$((done_skips + 1))
      continue
    fi
    if cached="$(filecache_get "$d")"; then
      hits=$((hits + 1))
      [ -n "$cached" ] && while IFS= read -r f; do [ -n "$f" ] && raw+=("$f"); done <<<"$cached"
    else
      misses=$((misses + 1))
      mark_folder_inprogress "$d"
      local -a sub_files=()
      while IFS= read -r f; do [ -n "$f" ] && sub_files+=("$f"); done \
        < <(find "$d" -type f "${pred[@]}" 2>/dev/null)
      filecache_put "$d" sub_files
      raw+=("${sub_files[@]}")
    fi
  done
  # Loose files directly under root, not inside any subdirectory.
  while IFS= read -r f; do [ -n "$f" ] && raw+=("$f"); done \
    < <(find "$root" -maxdepth 1 -type f "${pred[@]}" 2>/dev/null)

  if [ "$done_skips" -gt 0 ]; then
    log_err "Folder-done: $done_skips subdirectory(ies) already complete (skipped entirely, no scan)"
  fi
  if [ "$hits" -gt 0 ] || [ "$misses" -gt 0 ]; then
    log_err "File-list cache: $hits/$(( hits + misses )) subdirectory(ies) unchanged (skipped re-scan)"
  fi
  printf '%s\n' "${raw[@]}"
}

# ============================================================================
# v5.0.7 — junk-file scan/cleanup (--clean-junk / --clean-junk-apply)
# ============================================================================
# Finds leftover debris from interrupted runs: zero-byte or empty
# .AV1.mkv/.x265.mkv/.merged.mkv outputs, and stale IN_PROGRESS flags whose
# process is gone. Report-only by default; --clean-junk-apply actually
# deletes. Never touches original sources, .merged.mkv files with intact
# output (a merge surviving after its raw parts were cleaned up is the
# expected end state, not junk), or the human-review logs (bad_sources.txt,
# corrupt_files.txt, multipart_mismatch.txt, reconvert_files.txt).


# --- v5.0.7: per-folder done/in-progress semaphores -------------------------
# Complements the file-list cache with a coarser, cheaper skip: once every
# video in a folder (show/movie folder) has a valid finished output, that
# folder is marked done and later runs skip it WITHOUT even a stat-based
# cache lookup -- zero work for folders that will never need touching again.
# A folder's mtime advancing past the done-flag's mtime (new/changed file)
# automatically invalidates the mark; --ignore-done-folders forces a full
# recheck regardless. The in-progress flag is advisory only (not a lock) --
# useful as a hint when multiple fleet machines share the same NFS library,
# but does not prevent two machines from picking up the same folder.
FOLDER_DONE_FLAG_NAME=".convert-v5-folder-done"
FOLDER_INPROGRESS_FLAG_NAME=".convert-v5-folder-inprogress"

folder_done_flag_path() { printf '%s/%s' "$1" "$FOLDER_DONE_FLAG_NAME"; }
folder_inprogress_flag_path() { printf '%s/%s' "$1" "$FOLDER_INPROGRESS_FLAG_NAME"; }

folder_marked_done() {  # dir -> 0 if a valid (non-stale) done-flag exists
  local dir="$1" flag flag_mtime dir_mtime
  [ "$IGNORE_DONE_FOLDERS" = true ] && return 1
  flag="$(folder_done_flag_path "$dir")"
  [ -f "$flag" ] || return 1
  flag_mtime="$(mkv_structure_stat_key "$flag" 2>/dev/null)"; flag_mtime="${flag_mtime##*|}"
  # Same subtree-aware mtime as the file-list cache -- a done-flag on Show/
  # must be invalidated by a new episode added under Show/Season 2/, not
  # just by a change directly inside Show/ itself.
  dir_mtime="$(dir_subtree_max_mtime "$dir")"
  [ -n "$flag_mtime" ] && [ -n "$dir_mtime" ] || return 1
  [ "$dir_mtime" -le "$flag_mtime" ]
}

mark_folder_inprogress() {
  local dir="$1" flag
  [ "$DRY_RUN" = true ] && return 0
  flag="$(folder_inprogress_flag_path "$dir")"
  _neutralize_symlink_sidecar_path "$flag"
  : >"$flag" 2>/dev/null || true
}

# Called after any per-file result is recorded (success, skip, or reject).
# Deliberately cheap: stat()-only signals (fast done-log + bare output
# existence), never ffprobe/mkvalidator -- this runs once per completed file
# and re-checks every sibling in the same folder, so an expensive per-file
# check here would turn into O(n^2) validation calls across a large folder.
# Existing outputs are trusted without re-validation because anything on
# disk as {title}.AV1.mkv/.x265.mkv already passed validate_mkv_output at
# the time it was created (this run or a prior one).
_dir_subtree_all_video_files_done() {  # dir -> 0 if every video file anywhere under it is finished
  local dir="$1" f
  while IFS= read -r f; do
    is_video_file "$f" || continue
    is_derived_output "$f" && continue
    is_multipart_merged_file "$f" && continue
    done_log_should_skip "$f" && continue
    [ -f "$(av1_output_path "$f")" ] && continue
    [ -f "$(x265_output_path "$f")" ] && continue
    return 1
  done < <(find "$dir" -type f 2>/dev/null)
  return 0
}

mark_folder_done_if_complete() {
  local dir="$1" f still_pending=false cached
  [ "$DRY_RUN" = true ] && return 0
  folder_marked_done "$dir" && return 0
  local -a files=()
  if cached="$(filecache_get "$dir")"; then
    [ -n "$cached" ] && while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done <<<"$cached"
  else
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done       < <(find "$dir" -maxdepth 1 -type f 2>/dev/null)
  fi
  [ "${#files[@]}" -gt 0 ] || return 0

  for f in "${files[@]}"; do
    is_video_file "$f" || continue
    is_derived_output "$f" && continue
    is_multipart_merged_file "$f" && continue
    done_log_should_skip "$f" && continue
    [ -f "$(av1_output_path "$f")" ] && continue
    [ -f "$(x265_output_path "$f")" ] && continue
    still_pending=true
    break
  done
  if [ "$still_pending" = false ]; then
    local done_flag="$(folder_done_flag_path "$dir")"
    _neutralize_symlink_sidecar_path "$done_flag"
    : >"$done_flag" 2>/dev/null || true
    rm -f "$(folder_inprogress_flag_path "$dir")" 2>/dev/null
    log "Folder complete — marked done, will be skipped on future runs: $dir"
  fi

  # This function is called with dirname($src) -- for a nested TV layout
  # that's the Season folder, but find_convert_videos_under_cached only ever
  # checks folder_marked_done() at the Show folder (immediate child of the
  # scanned root). A done-flag written only at Season level is never found
  # by that check, so completed shows never actually got skipped. Also try
  # the parent: if the whole show's subtree is finished, mark it done too.
  local parent
  parent="$(dirname "$dir")"
  # Never ascend above the scanned root -- there is nothing above it whose
  # done-flag would ever be consulted, and it may not even be ours to write to.
  case "$parent" in
    "$JOB_ROOT"|"$JOB_ROOT"/*) ;;
    *) parent="$dir" ;;
  esac
  if [ "$parent" != "$dir" ] && [ -d "$parent" ] && ! folder_marked_done "$parent"; then
    if _dir_subtree_all_video_files_done "$parent"; then
      local parent_done_flag="$(folder_done_flag_path "$parent")"
      _neutralize_symlink_sidecar_path "$parent_done_flag"
      : >"$parent_done_flag" 2>/dev/null || true
      rm -f "$(folder_inprogress_flag_path "$parent")" 2>/dev/null
      log "Folder complete — marked done, will be skipped on future runs: $parent"
    fi
  fi
}

junk_flag_is_stale() {  # flag path -> 0 if safe to remove
  local flag="$1" pid host
  pid="$(awk -F= '/^pid=/{print $2; exit}' "$flag" 2>/dev/null)"
  host="$(awk -F= '/^host=/{print $2; exit}' "$flag" 2>/dev/null)"
  if [ -n "$pid" ] && [ "$host" = "$(hostname 2>/dev/null)" ]; then
    kill -0 "$pid" 2>/dev/null && return 1   # still running here — not stale
    return 0   # same host, pid confirmed dead — definitely stale, no need to wait
  fi
  # Different host, or no pid/host recorded at all: stale if older than 2
  # hours (avoid racing a run that just started and hasn't written progress
  # yet, and give a remote machine's own liveness signal time to show up).
  local mtime now age
  mtime="$(mkv_structure_stat_key "$flag" 2>/dev/null)"; mtime="${mtime##*|}"
  now="$(date +%s)"
  age=$(( now - ${mtime:-$now} ))
  [ "$age" -gt 7200 ]
}

clean_junk_scan() {
  local root="$1"
  local -a zero_byte=() stale_flags=()
  local f

  log "Junk scan: $root"

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ ! -s "$f" ]; then
      zero_byte+=("$f")
    fi
  done < <(find "$root" -type f \( -iname '*.AV1.mkv' -o -iname '*.x265.mkv' -o -iname '*.merged.mkv' \) 2>/dev/null)

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    junk_flag_is_stale "$f" && stale_flags+=("$f")
  done < <(find "$root" -type f -name "*.${IN_PROGRESS_FLAG_SUFFIX}" 2>/dev/null)

  # NOTE: a .merged.mkv whose raw Part1/Part2 sources are gone is NOT junk --
  # deleting the raw parts after verifying the merge is the normal, expected
  # cleanup workflow, and at that point the merged file is the ONLY copy.
  # An earlier version of this scan treated "source parts gone" as orphaned
  # and deleted the merge under --clean-junk-apply, which could destroy the
  # only remaining copy of the title. There's no reliable signal to tell
  # "user cleaned up verified parts" apart from "an aborted merge lost its
  # inputs" from file state alone, so this class is never auto-deleted.

  local total=$(( ${#zero_byte[@]} + ${#stale_flags[@]} ))
  if [ "$total" -eq 0 ]; then
    log "Junk scan: nothing to clean"
    return 0
  fi

  log "Junk scan found $total item(s):"
  [ "${#zero_byte[@]}" -gt 0 ] && { log "  Zero-byte/empty outputs (${#zero_byte[@]}):"; printf '    %s\n' "${zero_byte[@]}"; }
  [ "${#stale_flags[@]}" -gt 0 ] && { log "  Stale IN_PROGRESS flags, no live process (${#stale_flags[@]}):"; printf '    %s\n' "${stale_flags[@]}"; }

  if [ "$CLEAN_JUNK_APPLY" != true ]; then
    log "Report only — rerun with --clean-junk-apply to delete these."
    return 0
  fi

  for f in "${zero_byte[@]}" "${stale_flags[@]}"; do
    rm -f -- "$f" && log "  removed: $f"
  done
  log "Junk scan: removed $total item(s)"
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
    # Same reasoning as the guard in try_av1_convert/try_x265_convert: a
    # legitimate output is always a plain file we create ourselves. This
    # branch calls remux_copy_to_mkv (ffmpeg -y) directly and was never
    # covered by that guard, since it's a separate call path.
    if [ -L "$out" ]; then
      err "Refusing to remux — output path is a symlink, not our own plain file: $out"
      flag_bad_source_for_human "$src" "computed output path is an unexpected symlink — needs manual review before encoding"
      return 1
    fi
    # This branch is only reached because the scan phase decided $src still
    # needs converting -- but if $out already exists as a real regular file
    # (not caught above, and not already ruled out during scan for whatever
    # reason), ffmpeg -y would silently clobber it without ever checking
    # whether it's actually ours. Same provenance checks used before any
    # other deletion/overwrite of a "*.AV1.mkv"-named path.
    if [ -e "$out" ]; then
      local out_mt src_mt
      out_mt="$(mkv_structure_stat_key "$out" 2>/dev/null)"; out_mt="${out_mt##*|}"
      src_mt="$(mkv_structure_stat_key "$src" 2>/dev/null)"; src_mt="${src_mt##*|}"
      if { [[ "$out_mt" =~ ^[0-9]+$ ]] && [[ "$src_mt" =~ ^[0-9]+$ ]] && [ "$out_mt" -lt "$src_mt" ]; } \
         || ! derived_output_codec_claim_matches "$out"; then
        flag_bad_source_for_human "$src" "computed output path already exists and doesn't look like our own prior output — needs manual review before overwriting"
        return 1
      fi
    fi
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
    # finalize_mkv_output remuxes + relabels tracks IN PLACE -- only ever
    # apply that to a file we already recognize as our own derived output
    # (named *.AV1.mkv by this script). A genuine original that merely
    # happens to already be AV1 is left completely untouched.
    is_derived_output "$src" && finalize_mkv_output "$src" "$src" "$title"
    record_skip "$src" "AV1 sample test failed"
    return 0
  fi
  # Keep only a real decision token (defensive if any encode chatter leaked to stdout).
  decision="$(printf '%s\n' "$decision" | tr -d '\r' | grep -E '^(skip|av1|x265)$' | tail -n1 || true)"

  case "$decision" in
    skip)
      if is_derived_output "$src"; then
        pct="$(av1_overshoot_pct_vs_original "$src")"
        log "Sample predicts no smaller output — keeping AV1 (${pct}% vs original)"
        finalize_mkv_output "$src" "$src" "$title"
        record_conversion_result "$src" ""
      else
        log "Skip — sample predicts re-encode would not shrink: $src"
        # Genuinely non-derived original (not one of our own outputs) --
        # never remux/relabel it in place, just leave it exactly as-is.
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
      is_derived_output "$src" && finalize_mkv_output "$src" "$src" "$title"
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

  # Universal last-line-of-defense: whatever chain of naming/codec/queueing
  # logic got us here, if the computed output path is literally the source
  # path, ffmpeg -y (or HandBrake) would open $out for writing and truncate
  # it before it could even finish reading $src as input -- destroying the
  # original irrecoverably. This can happen for a file named like our own
  # output convention (e.g. "Movie.AV1.mkv") whose actual codec ISN'T AV1,
  # which reroutes it into this "fresh source" path instead of the existing-
  # AV1 recheck path. Refuse outright rather than trying to enumerate every
  # way this collision could occur upstream.
  if [ "$(canonical_path "$src" 2>/dev/null || printf '%s' "$src")" = "$(canonical_path "$out" 2>/dev/null || printf '%s' "$out")" ]; then
    err "Refusing to encode — computed output path is identical to the source, would destroy it: $src"
    flag_bad_source_for_human "$src" "derived output path collides with source path (name/codec mismatch?) — needs manual rename/review"
    return 1
  fi
  # A legitimate output from this script is always a plain regular file we
  # create ourselves. If $out is a symlink -- to $src (already caught above
  # via canonical_path), or to some OTHER real file entirely -- ffmpeg -y/
  # HandBrake's -o would follow it and truncate/corrupt whatever it points
  # to, which need not be related to this title at all.
  if [ -L "$out" ]; then
    err "Refusing to encode — output path is a symlink, not our own plain file: $out"
    flag_bad_source_for_human "$src" "computed output path is an unexpected symlink — needs manual review before encoding"
    return 1
  fi

  skip_if_complete_canonical_output "$src" "$hb_dur" && return 0

  if [ "$ENCODE_ENGINE" = ffmpeg ] && [ -z "$hb_title" ] && ! is_disk_source "$src"; then
    AV1_ENCODER="ffmpeg/libsvtav1"
    gpu=""
  else
    bakeoff_encoder_for_src "$src" "$hb_title" "$hb_dur"
    [ -n "$AV1_ENCODER" ] || AV1_ENCODER="svt_av1_10bit"
    gpu="$GPU_AV1"
    if [ "$AV1_ENCODER" = "svt_av1_10bit" ] || [ "$USE_NVIDIA_ENCODE" = false ]; then
      gpu=""
    fi
  fi

  log "AV1 transcode ($AV1_ENCODER): $src"
  encode_dispatch "$src" "$out" "$AV1_ENCODER" "$gpu" "$hb_title" || {
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

  local orig_sz new_sz upscaled=false
  if is_disk_source "$src"; then
    orig_sz="$(disc_source_size_bytes "$src")"
  else
    orig_sz="$(file_size_bytes "$src")"
  fi
  new_sz="$(file_size_bytes "$out")"
  if source_triggers_1080p_upscale "$src"; then
    upscaled=true
  fi
  policy="$(size_keep_policy_av1 "$orig_sz" "$new_sz" "$upscaled")"

  if [ "$policy" = keep ]; then
    finalize_mkv_output "$out" "$src" "$title"
    if [ "$upscaled" = true ] && [ "$new_sz" -gt "$orig_sz" ]; then
      log "Kept AV1 ($(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { printf "%.1f%% of original", (n/o)*100 }'); 1080p upscale, ≤${UPSCALE_MAX_OVERSHOOT_PCT}% growth OK): $out"
    else
      log "Kept AV1 ($(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { printf "%.1f%% of original", (n/o)*100 }')): $out"
    fi
    record_conversion_result "$src" "$out"
    return 0
  fi

  if [ "$upscaled" = true ]; then
    warn "AV1 output >${UPSCALE_MAX_OVERSHOOT_PCT}% larger than original after 1080p upscale ($(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { printf "%.1f%%", (n/o)*100 }')) — trying x265 fallback"
  else
    warn "AV1 output >${AV1_MAX_OVERSHOOT_PCT}% larger than original ($(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { printf "%.1f%%", (n/o)*100 }')) — trying x265 fallback"
  fi
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

  # See the matching guard in try_av1_convert -- same reasoning: a file named
  # like our own output convention (e.g. "Movie.x265.mkv") whose actual codec
  # isn't HEVC would otherwise compute an output path identical to itself.
  if [ "$(canonical_path "$src" 2>/dev/null || printf '%s' "$src")" = "$(canonical_path "$out" 2>/dev/null || printf '%s' "$out")" ]; then
    err "Refusing to encode — computed output path is identical to the source, would destroy it: $src"
    flag_bad_source_for_human "$src" "derived output path collides with source path (name/codec mismatch?) — needs manual rename/review"
    return 1
  fi
  # A legitimate output from this script is always a plain regular file we
  # create ourselves. If $out is a symlink -- to $src (already caught above
  # via canonical_path), or to some OTHER real file entirely -- ffmpeg -y/
  # HandBrake's -o would follow it and truncate/corrupt whatever it points
  # to, which need not be related to this title at all.
  if [ -L "$out" ]; then
    err "Refusing to encode — output path is a symlink, not our own plain file: $out"
    flag_bad_source_for_human "$src" "computed output path is an unexpected symlink — needs manual review before encoding"
    return 1
  fi

  skip_if_complete_canonical_output "$src" "$hb_dur" && return 0

  # Never remux-shortcut a Dolby Vision source — stream copy preserves the
  # RPU/DoVi tagging verbatim, defeating the DoVi->HDR10 conversion below.
  # DoVi sources always take the real re-encode path.
  if [ "$ext" = "mkv" ] && is_hevc_codec "$codec" && [ -z "$hb_title" ] \
     && ! source_has_dolby_vision "$src"; then
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

  if [ "$ENCODE_ENGINE" = ffmpeg ] && [ -z "$hb_title" ] && ! is_disk_source "$src"; then
    encoder="ffmpeg/libx265"
    log "x265 transcode (ffmpeg engine): $src"
    encode_dispatch "$src" "$out" "x265" "" "" || { remove_output_only "$out"; return 1; }
  elif [ "$USE_NVIDIA_ENCODE" = true ]; then
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

  local orig_sz new_sz upscaled=false
  if is_disk_source "$src"; then
    orig_sz="$(disc_source_size_bytes "$src")"
  else
    orig_sz="$(file_size_bytes "$src")"
  fi
  new_sz="$(file_size_bytes "$out")"
  if source_triggers_1080p_upscale "$src"; then
    upscaled=true
  fi
  if [ "$src_codec" = "av1" ]; then
    policy="$(size_keep_policy_av1 "$orig_sz" "$new_sz" "$upscaled")"
  else
    policy="$(size_keep_policy "$orig_sz" "$new_sz" "$upscaled")"
  fi

  if [ "$policy" = keep ]; then
    finalize_mkv_output "$out" "$src" "$title"
    if [ "$upscaled" = true ] && [ "$new_sz" -gt "$orig_sz" ]; then
      log "Kept x265 ($(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { printf "%.1f%% of original", (n/o)*100 }'); 1080p upscale, ≤${UPSCALE_MAX_OVERSHOOT_PCT}% growth OK): $out"
    else
      log "Kept x265 ($(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { printf "%.1f%% of original", (n/o)*100 }')): $out"
    fi
    record_conversion_result "$src" "$out"
    return 0
  fi

  if [ "$upscaled" = true ]; then
    warn "x265 output >${UPSCALE_MAX_OVERSHOOT_PCT}% larger after 1080p upscale — rejected (keeping original)"
  elif [ "$src_codec" = "av1" ]; then
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
    # Fast count only, no ffprobe/mkvmerge -- this decides batch vs pipeline
    # mode before any real work has started, so it must not trigger
    # multipart merges (that's real I/O, potentially hours of it on a cold
    # first run across a whole TV region).
    while IFS= read -r _; do
      total=$((total + 1))
      if [ "$total" -ge "$PIPELINE_FILE_THRESHOLD" ]; then
        printf 'over'
        return 0
      fi
    done < <(find_convert_videos_under "$shard" true)
  done

  if [ "$NO_SHARD" = false ] && [ "${#roots[@]}" -gt 1 ]; then
    while IFS= read -r _; do
      total=$((total + 1))
      if [ "$total" -ge "$PIPELINE_FILE_THRESHOLD" ]; then
        printf 'over'
        return 0
      fi
    done < <(find_videos_at_root "$SEARCH_PATH" true)
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

  # v5.0.1 fast path: durably finished + source unchanged -> no ffprobe, no
  # output validation, no queue slot.
  if done_log_should_skip "$f"; then
    DONE_FAST_SKIPS=$((DONE_FAST_SKIPS + 1))
    return 1
  fi

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
  CONVERT_SCAN_TOTAL_FILE="$JOB_SIDECAR_DIR/convert-scan.total"
  rm -f -- "$CONVERT_READY_FILE" "$CONVERT_SCAN_DONE_FILE" "$CONVERT_SCAN_TOTAL_FILE"
  : >"$CONVERT_READY_FILE"
  CONVERT_READY_OFFSET=0
  CONVERT_SCAN_COUNT=0
  # Persistent read fd: sequential `read -u` advances a stream position in
  # O(1) per call, unlike `sed -n Np` which rescans from the start of the
  # (ever-growing) file every time -- O(n^2) total across a large queue.
  exec {CONVERT_READY_FD}<"$CONVERT_READY_FILE"
}

# convert_scan_producer runs as a background process (&) -- variable writes
# there (including CONVERT_JOB_TOTAL) live only in that child and never
# propagate back to this shell. The queued count must cross via a file.
convert_pipeline_scan_total() {
  local n
  [ -n "$CONVERT_SCAN_TOTAL_FILE" ] && [ -f "$CONVERT_SCAN_TOTAL_FILE" ] || { printf '0'; return; }
  n="$(cat "$CONVERT_SCAN_TOTAL_FILE" 2>/dev/null)"
  [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$n" || printf '0'
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
  # This runs in the background scan process -- the CONVERT_JOB_TOTAL
  # assignment above never reaches the parent shell, only this file does.
  printf '%s' "$queued" >"$CONVERT_SCAN_TOTAL_FILE" 2>/dev/null
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
  if ! begin_convert_job "$f" "$idx" "$total_label"; then
    return 0
  fi
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
      IFS= read -r -u "$CONVERT_READY_FD" f || break
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
      if [ -f "$CONVERT_SCAN_DONE_FILE" ]; then
        total_label="$(convert_pipeline_scan_total)"
        [[ "$total_label" =~ ^[1-9][0-9]*$ ]] || total_label='?'
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

  # CONVERT_JOB_TOTAL itself was only ever set inside the background scan
  # process (convert_scan_producer &) and never propagates here -- read the
  # real count back from the file it wrote instead, or this always reads 0.
  local final_total
  final_total="$(convert_pipeline_scan_total)"
  if [ "$final_total" -gt 0 ] 2>/dev/null; then
    log "Convert queue finished: $final_total item(s)"
  else
    log "Convert queue finished: no items needed encoding"
  fi

  exec {CONVERT_READY_FD}<&- 2>/dev/null || true

  if [ "$DRY_RUN" = false ]; then
    resume_clear_state
    log "Convert queue finished — resume state cleared"
  fi

  rm -f -- "$CONVERT_READY_FILE" "$CONVERT_SCAN_DONE_FILE" "$CONVERT_SCAN_TOTAL_FILE"
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
    if ! begin_convert_job "$f" "$CONVERT_JOB_INDEX" "$CONVERT_JOB_TOTAL"; then
      continue
    fi
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

  if [ "$CLEAN_JUNK" = true ]; then
    resume_init_paths
    clean_junk_scan "$SEARCH_PATH"
    exit 0
  fi
  detect_hw_environment
  detect_nvenc_av1_tune
  detect_ffmpeg_capabilities
  mount_audit_for_path "$SEARCH_PATH"
  init_stats_log
  trap resume_on_signal INT TERM
  log "$SCRIPT_NAME v$VERSION"
  log "Path: $SEARCH_PATH (platform=$PLATFORM shell=$(shell_name) dry_run=$DRY_RUN organize=$DO_ORGANIZE convert=$DO_CONVERT skip_av1=$SKIP_AV1 skip_x265=$SKIP_X265 shard_depth=$SHARD_DEPTH no_shard=$NO_SHARD name_glob=${NAME_GLOB:-*} name_glob_ci=$NAME_GLOB_CI pipeline_threshold=$PIPELINE_FILE_THRESHOLD encode_batch=$ENCODE_INSPECT_BATCH_SIZE largest_first=$LARGEST_FIRST force_pipeline=$FORCE_PIPELINE nvidia=$HAS_NVIDIA intel_qsv=$HAS_INTEL_QSV amd_vce=$HAS_AMD_VCE amd_backend=${AMD_ENCODE_BACKEND:-none} videotoolbox=$HAS_VIDEOTOOLBOX active_encode=$ACTIVE_ENCODE_MODE hw_decode=${HW_DECODE_NAME:-none})"
  if [ -n "$NAME_GLOB" ]; then
    local -a _preview_roots=()
    get_scan_roots _preview_roots || exit 1
    log "Name-glob filter: '$NAME_GLOB' → ${#_preview_roots[@]} directory match(es) (${_preview_roots[0]##*/} … ${_preview_roots[-1]##*/})"
  fi
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

  if [ "${DONE_FAST_SKIPS:-0}" -gt 0 ]; then
    log "Done-log fast-skipped $DONE_FAST_SKIPS unchanged finished source(s) (no re-validation)"
  fi
  finalize_stats_log
  trap - INT TERM
  log "Done. Original files were not deleted."
}

main "$@"
