#!/usr/bin/env bash
# convert-v5.0.32Y.sh — Organize movie folders, transcode TV/movies to AV1/x265 MKV.
# Version: 5.0.32Y (see CHANGELOG.md for the full per-version history from
# 5.0.32A onward -- the header below was never backfilled past 5.0.32A/32,
# a known documented gap, not a functional issue: CHANGELOG.md is current)
#
# v5.0.32A: Preexisting-desired-format tagging with codec-specific size gates
#   (AV1 <=300MB / x265 <=250MB skip the sample-test entirely), a new
#   process_existing_x265() that reconsiders large/any-size x265 sources for
#   an AV1 (or fresh x265) win, unconditional non-MKV-to-MKV remux for both
#   the AV1 and x265 already-encoded paths (container unification -- every
#   source ends up .mkv regardless of the size-benefit verdict), a
#   force_transcode bypass on try_x265_convert's HEVC-MKV remux shortcut
#   (so a sample-predicted fresh x265 win isn't silently defeated by a
#   same-size remux), and a fix to the shared sample-encode machinery
#   (build_handbrake_args' new no_hw_decode option) where HandBrake's NVDEC
#   hardware decoder could choke on a -ss+-c copy sample clip's irregular
#   timestamps.
#
# v5.0.32: Size-tiered upscale-overshoot guardrail, AV1/x265 rejection-message
#   display consistency fix, and embedded MKV VES-processed tagging (Matroska
#   Tags element records exact version + sampled VMAF/resolution, survives
#   renames/moves, used as a second skip signal alongside the done-log).
#
# v5.0.31: Orphan-process hardening + 7-profile encoding system. Combines five
#   internal development phases (never independently released) into one
#   version:
#   - Orphan-process hardening: full encode/remux subprocesses now run through
#     a tracked background child so INT/TERM/ERR can terminate the in-flight
#     ffmpeg/mkvmerge process instead of leaving it orphaned. The visible
#     IN_PROGRESS flag is updated with encoder_pid, encoder_started_utc, and
#     encoder_fingerprint. HandBrake progress uses a private
#     .convert-hbprog-* FIFO dir instead of a raw pipe, so its real PID is
#     trackable too.
#   - Startup orphan reaper: on every normal invocation (unless
#     --no-auto-reap), walks same-host .convert-v4.IN_PROGRESS flags and
#     staging dirs left by a hard-crashed prior run, kills identity-verified
#     orphan encoders, and either salvages a complete generated output via the
#     normal finalize path or deletes only the verified generated candidate —
#     never the original source. Orphan-output validation follows a 4-gate
#     sequence (provenance → kill+stable-size → tight duration → direct EBML
#     → -sseof -5 tail decode, with mandatory probe timeouts).
#   - Defensive cleanup for the direct-write failure path in ffmpeg_encode():
#     confirmed unreachable today (resolve_encode_stage_path() fails closed),
#     kept as cheap insurance against a future fail-open change.
#   - Timeout guards on every validation-path subprocess (run_ffprobe /
#     run_mkvmerge / run_mkvalidator / EBML-bounds check) via a portable
#     _timeout_cmd()/run_with_timeout() helper (VALIDATION_TIMEOUT_SECS,
#     default 120, works without GNU coreutils via a background+poll+TERM/KILL
#     fallback). A timeout is never misclassified as confirmed corruption —
#     the affected output/source is left in place for retry next run instead
#     of being deleted or flagged.
#   - Replaces the five-profile system (movie/tv/anime/wanime/vintage) with
#     seven path-detected profiles: WANIME, ANIME, MOVIES, CLASSIC, VINTAGE,
#     MTV, and VTV, matching a real on-disk library reorganization
#     (Modern/Classic/Vintage/Animation per language/country). Movies/Anime/
#     is unambiguous ANIME; Movies/<Language>/Animation/ is unambiguous
#     WANIME **except** Movies/Japanese/Animation/, which is genuinely
#     ambiguous and requires an explicit --profile flag rather than a guess.
#     Sample search and final encode share each profile's complete
#     SVT-AV1/x265 parameter strings. SD upscale selection is now a cached
#     two-stage decision: display/SAR/DAR + bits-per-pixel-per-frame metadata
#     first, then a real 720p-vs-1080p sample encode + VMAF comparison only
#     for genuinely uncertain sources; the selected output height is part of
#     the CRF cache key.
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
#   Sources shorter than 700p use the Phase F metadata/sample test to choose a
#   1280x720 or 1920x1080 cap; near-720p sources are left native. Upscale size growth is
#     capped by original file size (smaller sources get more headroom — a fixed container/
#     audio overhead dominates a small file's overshoot % far more than a large one):
#     <=120MB: 100% | <=1200MB: 65% | >1200MB: 50% (UPSCALE_OVERSHOOT_*/UPSCALE_MAX_OVERSHOOT_PCT).
#     Beyond the applicable cap, reject and keep the original (or fall back AV1->x265).
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
#   Resume: convert-v4.<hostname>.state / .queue (per-host, since a fleet run under a
#   shared JOB_ROOT must resume only this machine's own progress) / .shards in --path;
#   use --no-resume for a fresh run
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
# Resolves the directory this script itself lives in, so modules/*.sh can be
# found regardless of the caller's cwd or how the script was invoked (bare
# name via PATH, relative path, symlink via convert-current.sh, etc).
_CONVERT_V4_SCRIPT_DIR="$(cd -- "$(dirname -- "${_CONVERT_V4_SCRIPT_PATH}")" >/dev/null 2>&1 && pwd -P)"
_CONVERT_V4_MODULES_DIR="${_CONVERT_V4_SCRIPT_DIR}/modules"

# Feature/logic modules live in modules/*.sh, sourced here so their function
# definitions are available before argument parsing and main() run. Pure
# function definitions only (no top-level side effects) in every module
# except ves-config.sh, which supplies the defaults/lookup tables every
# other module reads -- sourced explicitly first so load order never
# matters for the rest (team review convention: file-move only, no logic
# changes, during this modularization).
#
# Fails loud, not silent: a missing modules/ directory (partial deploy,
# script copied without its modules/ sibling, wrong cwd) used to let the
# script continue past this block with every module-provided function and
# global undefined, only to crash confusingly deep into execution (e.g.
# "detect_platform: command not found") instead of failing here with a
# clear cause (team review, 2026-08-04).
if [ ! -f "${_CONVERT_V4_MODULES_DIR}/ves-config.sh" ]; then
  echo "[convert] FATAL: modules/ves-config.sh not found under ${_CONVERT_V4_MODULES_DIR}" >&2
  echo "[convert] This script requires its modules/ directory alongside it (deploy the full tree, not just the .sh file)." >&2
  exit 1
fi
# shellcheck source=modules/ves-config.sh
source "${_CONVERT_V4_MODULES_DIR}/ves-config.sh"
for _convert_v4_module in "${_CONVERT_V4_MODULES_DIR}"/ves-*.sh; do
  [ -e "$_convert_v4_module" ] || continue
  [ "$(basename -- "$_convert_v4_module")" = "ves-config.sh" ] && continue
  # shellcheck source=/dev/null
  source "$_convert_v4_module"
done
unset _convert_v4_module


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
  --force-reprocess       Bypass the VES-processed tag skip-check without prompting
                          (batch scans always skip tagged files; a single-file target
                          that's already tagged prompts interactively unless this is set)
  --profile MODE          Force profile: wanime|anime|canime|movies|classic|vintage|mtv|vtv,
                          overriding path-based auto-detection for this whole run.
                          (canime = classic/heavily-lined anime, auto-detected for
                          "(YYYY)" <= 1997 under Anime paths; force it explicitly for
                          undated titles or to override the year cutoff.)
                          Movies/Japanese/Animation is ambiguous and requires an
                          explicit anime or wanime override; all other library tiers
                          are detected from Movies/ or Television/ path components.
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
  --vmaf-target N         VMAF (NEG model) floor for all eight SDR profiles (default 94.0)
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
  --report-source-traits  Detect telecine/interlace + B&W per file under --path,
                          print a classification table, then exit (no encoding)
  --no-auto-detelecine    Detect source traits but never auto-apply IVTC/deinterlace
  --no-bw-tuning          Detect B&W but never relax the CRF/VMAF target for it
  --no-auto-reap          Skip the Phase B startup orphan-reaper sweep (default: reap on)
  --ignore-done-folders   Force a full recheck of folders marked complete by a prior run
                          (use after adding/changing files in an already-finished folder)

CIFS/SMB (WSL/NFS-style shares — logs and MKV outputs need writable mount):
  Default: ensure parent CIFS mount uses file_mode=0777,dir_mode=0777,noperm
  CONVERT_CIFS_MOUNT_SRC   e.g. //192.0.2.50/BabyBear (mount when DST is empty)
  CONVERT_CIFS_MOUNT_DST   e.g. /mnt/BabyBear (default: inferred from --path)
  CONVERT_CIFS_CREDENTIALS path to credentials file
  CONVERT_SMB_USER / CONVERT_SMB_PASSWORD  alternative to credentials file

Telegram job-completion notifications (optional, off by default):
  CONVERT_TELEGRAM_BOT_TOKEN   bot token from @BotFather
  CONVERT_TELEGRAM_CHAT_ID     destination chat/channel/group id
  Sends one message per job (success or failure), tagged with the
  hostname, so a shared bot/chat works across the whole fleet. Silently
  disabled if either variable is unset. Never a CLI flag -- a flag value
  is visible to any local user via `ps aux`, an env var isn't.

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
  Apple TV 3rd generation cannot hardware-decode AV1/HEVC/MKV; Plex must transcode
  for that legacy client (this is not fixable with encoder profile flags).
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






master_log_write() {
  [ -n "$MASTER_LOG_FD" ] || return 0
  printf '%s\n' "$@" >&"$MASTER_LOG_FD" 2>/dev/null || true
}

shard_log_write() {
  [ "$SHARD_LOG_ACTIVE" = true ] && [ -n "$SHARD_LOG_FD" ] || return 0
  printf '%s\n' "$@" >&"$SHARD_LOG_FD" 2>/dev/null || true
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





























































_TIMEOUT_CMD_RESOLVED=""
_TIMEOUT_DEGRADE_WARNED=false
_TIMEOUT_HAS_FOREGROUND=""





# Retry-on-timeout wrapper (2026-07-26/27): direct measurement showed the
# SAME file's validation time can vary 2x+ between consecutive attempts due
# to genuine NFS timing variance (confirmed: a file that hit rc=124 at its
# full size-scaled timeout succeeded cleanly in under half that time on an
# immediate retry). No fixed timeout eliminates that variance, so rather
# than keep inflating it, retry a FEW times specifically on rc=124 (timeout)
# before giving up -- a genuine structural failure (mkvalidator says the
# file is actually invalid, rc=1/2) is never retried here, only timeouts
# are, since a bad file won't become good on a second attempt but a slow
# NFS moment often clears. VALIDATION_TIMEOUT_RETRIES counts EXTRA attempts
# after the first (default 2 => up to 3 total tries).
case "${VALIDATION_TIMEOUT_RETRIES:-}" in
  ''|*[!0-9]*) VALIDATION_TIMEOUT_RETRIES=2 ;;
esac




# Deliberate scope boundary: short probe/sample-clip ffmpeg calls stay
# synchronous. Only full encode/remux subprocesses use run_tracked_encoder().






























while [ $# -gt 0 ]; do
  case "$1" in
    -p|--path) SEARCH_PATH="$2"; shift 2 ;;
    -g|--name-glob) NAME_GLOB="$2"; shift 2 ;;
    --name-glob-ci) NAME_GLOB_CI=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --skip-av1) SKIP_AV1=true; shift ;;
    --skip-x265) SKIP_X265=true; shift ;;
    --force-reprocess) FORCE_REPROCESS_TAGGED=true; shift ;;
    --profile)
      case "$2" in
        wanime|anime|canime|movies|classic|vintage|mtv|vtv) FORCE_PROFILE="$2" ;;
        *) err "--profile must be wanime, anime, canime, movies, classic, vintage, mtv, or vtv (got: $2)"; exit 1 ;;
      esac
      shift 2 ;;
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
    --report-source-traits) REPORT_SOURCE_TRAITS=true; shift ;;
    --no-auto-detelecine) NO_AUTO_DETELECINE=true; shift ;;
    --no-bw-tuning) NO_BW_TUNING=true; shift ;;
    --no-auto-reap) AUTO_REAP=false; shift ;;
    --ignore-done-folders) IGNORE_DONE_FOLDERS=true; shift ;;
    --check-tools) CHECK_TOOLS_ONLY=true; shift ;;
    --vmaf-target)
      VMAF_TARGET_MOVIE="$2"; VMAF_TARGET_ANIME="$2"; VMAF_TARGET_CANIME="$2"; VMAF_TARGET_CLASSIC="$2"
      VMAF_TARGET_VINTAGE="$2"; VMAF_TARGET_WANIME="$2"; VMAF_TARGET_MTV="$2"; VMAF_TARGET_VTV="$2"
      shift 2 ;;
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

# --force-reprocess only ever means "yes, re-process THIS single tagged file
# I explicitly targeted" -- a batch/folder scan must always skip tagged files
# regardless of this flag, or it would silently re-encode every already-
# optimized file in the library on one accidental/careless invocation.
if [ "$FORCE_REPROCESS_TAGGED" = true ] && [ "$SINGLE_FILE_MODE" != true ]; then
  warn "--force-reprocess only applies to a single-file target (-p pointed at a directory) — ignoring for this batch/folder scan"
  FORCE_REPROCESS_TAGGED=false
fi

ensure_cifs_mount_for_path "$SEARCH_PATH" || exit 1

if [ -n "$NAME_GLOB" ] && [ "$NO_SHARD" = true ]; then
  warn "--name-glob '$NAME_GLOB' forces filtered per-directory shards (ignoring --no-shard for shelf-wide find)"
fi

init_text_search || exit 1
discover_tools || exit 1

# A batch/folder scan silently skips any already-tagged file (see the
# embedded-tag check in convert_file_should_queue) -- that's the right default
# for unattended runs over a whole library. A single explicit file target is
# a deliberate ask, though, so if it's already VES-tagged, confirm rather than
# silently doing nothing (or silently re-encoding). --force-reprocess skips
# the prompt for scripted/non-interactive invocations.
if [ "$SINGLE_FILE_MODE" = true ] && [ "$FORCE_REPROCESS_TAGGED" != true ] \
   && mkv_ves_tag_present "$SEARCH_PATH" 2>/dev/null; then
  if [ -t 0 ] && [ -t 1 ]; then
    reply=""
    read -r -p "Already VES-tagged as processed: $SEARCH_PATH — re-process anyway? [y/N] " reply
    case "$reply" in
      [Yy]*) FORCE_REPROCESS_TAGGED=true ;;
      *) log "Skip — already tagged, declined to force re-process: $SEARCH_PATH"; exit 0 ;;
    esac
  else
    warn "Skip — already VES-tagged and no TTY to confirm re-process (pass --force-reprocess to override): $SEARCH_PATH"
    exit 0
  fi
fi

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

































# Phase F profile resolver. Matching is component-based and case-sensitive
# because the library structure is controlled. Explicit --profile wins before
# every path rule, including the intentionally ambiguous Japanese animation
# shelf. Return 2 only for that ambiguity, 1 for a path outside the known tree.
# Classic/heavily-lined anime (thick hand-inked line art, physical cel
# paint, pre-digital-production era) needs different SVT-AV1/x265 tuning
# than modern anime (thin uniform lines, digital paints/gradients) -- see
# feedback from the 2026-07-20 team review of the Angel Cop softness
# report. Cutoff decided by the user: 1997 and earlier is "classic"
# (Ninja Scroll/Yuu Yuu Hakusho era and older); 1998+ (Cowboy Bebop,
# Trigun, Lain and later) stays on the modern anime profile. Year is
# parsed from a "(YYYY)" marker anywhere in the path -- this is the
# pervasive title-folder naming convention already used throughout the
# library -- taking the LAST match so a nested title's own year wins
# over any year that might appear in an ancestor folder name.
CLASSIC_ANIME_YEAR_CUTOFF=1997













# --- v5.0.1: set-based done-log ------------------------------------------------
# v5.0.32F added a 5th tab-separated column (tools fingerprint, see
# tools_fingerprint_is_stale) -- backward compatible for a v5.0.32F+ reader
# opening an OLDER 4-column log, but NOT the reverse: an OLDER (pre-32F)
# script's `read -r st sz mt p` has only 4 variables, so on a 5-column line
# it folds column 5 (and its separating tab) into `p`, corrupting the path
# and breaking that entry's fast-skip until rewritten. Since the done-log is
# shared, multi-writer, NAS-stored state per this project's own multi-
# machine design goal, this fleet must upgrade to 32F together, not
# piecemeal -- confirmed low-risk in practice since that's exactly how it's
# being deployed (team review, 2026-07-20).
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
# Opened once (see resolve_job_sidecar_paths' neighbor init) rather than
# reopening RESUME_DONE_LOG by path on every completed title -- same
# reasoning as MASTER_LOG_FD/SHARD_LOG_FD.
DONE_LOG_FD=""































































































# Per-run dedup: subtitle_stream_has_real_content() is re-checked once per
# encoder attempt (AV1, then an x265 fallback) on the same source, which
# would otherwise write duplicate manifest lines for the same stream.
declare -A STRIPPED_SUBTITLE_LOGGED=()





















# Catches a real bug found 2026-07-20 on Angel Cop (1989) and 5 Centimeters
# Per Second (2007): ffmpeg_encode()'s single-process video+audio+subs
# encode can exit 0 with the video track complete but one or more audio
# tracks having silently stopped partway through (root cause: audio
# filter/encode path faltering under A/V pipeline pressure on long/complex
# files; team review couldn't fully confirm the trigger since -v error
# suppressed whatever warning ffmpeg emitted -- see convert-v5.0.32D fix:
# stderr is now persisted per-title and -v raised to warning). The
# duration check above in validate_mkv_output is useless against this --
# format=duration is dominated by the longest (video) stream and was
# unaffected in both real cases (Angel Cop's video played the full
# 2h55m42s while both audio tracks were dead by the 44% mark).
#
# Cheap-by-design: seeks near EOF (same -sseof idiom as
# validate_mkv_decode_windows) rather than scanning every packet from the
# start, which is what actually diagnosing this by hand showed to be slow
# and NFS-hostile on multi-GB files. A tolerance window rather than an
# exact pts comparison against the source: real masters occasionally have
# a few seconds of trailing silence/black after their last audio packet,
# and this shouldn't false-fail on that -- 30s comfortably catches both
# real incidents (172s and ~5900s short) while giving legitimate small
# mismatches room.
AUDIO_TRUNCATION_CHECK_WINDOW_SECS=30

# Cheap analog of validate_mkv_audio_tracks for subtitles: catches a subtitle
# stream truncated partway through (a bad rip, a botched extraction), NOT
# true dialogue-timing accuracy -- verifying a subtitle line actually lands
# when the matching line of dialogue is spoken would need OCR/speech
# analysis, well beyond what a structural check can do cheaply. What this
# CAN check safely: does the primary subtitle track have any cue at all in
# the film's last ${SUBTITLE_SYNC_TAIL_GAP_PCT}%.
#
# Redesigned after team review (2026-07-22) found the first version unsafe
# to ship: (1) it dumped EVERY subtitle packet from the start of the file
# with no seek, unlike audio's near-EOF -read_intervals seek -- on a large
# file this meant sequentially reading the ENTIRE file just to extract a
# sparse subtitle stream, defeating "cheap by design" and risking a timeout
# that produces a partial (non-empty) packet list, which the old code then
# treated as a confirmed truncation instead of a timeout; (2) it tried to
# distinguish a forced/sign-only track from a full dialogue track by cue
# COUNT alone (a minimum-cues threshold), but a real forced track can easily
# have far more than a small handful of cues on a heavily-foreign-language
# film, and rippers commonly place a forced track at stream index s:0 (first
# by index) -- count can't reliably tell them apart. Fixed by (a) seeking
# only the tail window via -read_intervals, same idiom as audio, so this
# stays cheap regardless of file size; (b) asking ffprobe's own disposition
# flag whether s:0 IS a forced track and skipping entirely if so, instead of
# guessing from cue count; (c) a generous 25% tail-gap threshold (vs audio's
# fixed 30s) since a subtitle track legitimately going quiet near a
# dialogue-free/musical ending is common and not a defect, and percentage
# scales with film length rather than penalizing long films.
SUBTITLE_SYNC_TAIL_GAP_PCT=25


# Builds an explicit "-map <input>:s:N" list (as $1, the ffmpeg input
# index feeding the subtitle streams -- e.g. "1" in stage 2's remux)
# containing only subtitle indices in $2 (source file) that pass
# subtitle_stream_has_real_content, so a blanket "?:s?" map never carries
# a flagged-but-empty track into the output. Result left in the global
# array REAL_SUBTITLE_MAP_ARGS (reset each call).
REAL_SUBTITLE_MAP_ARGS=()

# Phase F two-stage SD upscale decision. 0 means native/no upscale.
UPSCALE_HEIGHT_THRESHOLD=700
# Midpoint of the independently recommended 0.06-0.07 low-information band:
# conservative enough to avoid spending 1080p pixels on bitrate-starved SD.
UPSCALE_LOW_BPPPF=0.065
UPSCALE_SAMPLE_SECS=10














# Per-encoder profile tuning is defined by the Phase F canonical accessors below.
# Phase F canonical profile accessors. Keeping full strings in one place makes
# HandBrake, ffmpeg, internal VMAF, and ab-av1 consume identical tuning.
# `sharpness` (SVT-AV1-PSY's deblock-sharpness/rate-distortion option) only
# landed in mainline SVT-AV1 in a late-2024 merge -- older builds reject it
# outright, for ANY value including 0, as an unrecognized option ("Error
# parsing option sharpness: N"), not a range problem. Found 2026-07-20 via
# the new per-title stderr capture (see _run_capturing_stderr): half the
# fleet (SVT-AV1 v2.3.0 on AI-PROCESSOR/GruntVM/PRINCE/GruntBox2) has been
# silently dropping this option from every profile that sets it (anime,
# classic, vintage, vtv, wanime, canime) since it was first added --
# individual unrecognized -svtav1-params entries are skipped rather than
# aborting the whole string, so encodes were never broken, just missing
# this one tuning knob on those machines. Probed once per run (cheap: a
# 1-frame null encode) rather than gated on a hardcoded version-number
# cutoff, since that's fragile against forks/custom builds (e.g. SVT-AV1-
# PSY) that may carry it on a different version schedule than mainline.
FF_SVTAV1_SUPPORTS_SHARPNESS=""

# --- tool-version tagging & drift detection (2026-07-20) ---------------------
# User CONSTANT: every output MKV (even a remux-only pass) must record the
# encode-tool versions used, and an already-tagged/already-optimal file must
# not be exempt from re-checking forever once the toolchain has moved on
# meaningfully. Design reviewed before implementing; key
# decisions from that review:
#   - Only SVT-AV1 and x265 (MAJOR.MINOR) drive the drift decision -- mkvmerge
#     is muxing-only (recorded for humans, never triggers a re-check) and
#     ffmpeg's own version string is a git-describe/distro-build string, not
#     comparable semver (recorded for humans only).
#   - Directional/monotonic: a re-check fires only when THIS machine's tools
#     are a strictly NEWER major.minor than what's on record, never on a
#     lateral or older difference -- a fleet with slightly staggered tool
#     rollout must not ping-pong the same title back and forth forever.
#   - A missing/empty fingerprint (every file tagged before this feature
#     existed) is NOT treated as stale -- that would force a one-time full-
#     library re-check burn the moment this ships. Drift detection only
#     applies going forward from whenever a file first gets a real fingerprint.
# Known scope gaps, not yet covered (documented rather than rushed): checking
# a source whose derived output (Title.AV1.mkv) already exists reads only the
# per-directory done-log/folder-done markers, not the derived output's own
# tag -- closing that would mean opening every derived output file on every
# scan, which defeats the whole point of the cheap stat-only fast paths.

CURRENT_SVTAV1_MAJOR_MINOR=""

CURRENT_X265_MAJOR_MINOR=""

# Compact fingerprint used for drift *decisions* (folder-done flags, done-log
# entries): deliberately just the two tools that actually affect encoded
# bitstream quality. Kept separate from the fuller human-readable tag suffix
# below, which also records mkvmerge/ffmpeg for reference.
TOOLS_FINGERPRINT=""




# Full human-readable suffix embedded in every VES tag (see _mkv_write_single_tag).
# Includes mkvmerge/ffmpeg for reference even though they never drive the
# drift decision above.
TOOL_VERSIONS_TAG_SUFFIX=""

















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







# ============================================================================
# v5.0.32 — Phase B startup orphan reaper
# ============================================================================
# Walks same-host .convert-v4.IN_PROGRESS flags and staging dirs left by a
# hard-crashed prior run. Kills identity-verified orphan encoders, then either
# salvages a complete generated output via the normal finalize path or deletes
# only the verified generated candidate. Never touches the original source.
# Orphan-output validation sequence is the settled 4-way team consensus
# (Gate 0 provenance → kill+stable-size → tight duration → EBML → tail decode).

ORPHAN_PROBE_TIMEOUT_SECS="${ORPHAN_PROBE_TIMEOUT_SECS:-30}"
ORPHAN_TAIL_TIMEOUT_SECS="${ORPHAN_TAIL_TIMEOUT_SECS:-90}"
ORPHAN_STALE_DIR_AGE_SECS="${ORPHAN_STALE_DIR_AGE_SECS:-7200}"

# Timeout helpers (_timeout_cmd / run_with_timeout, used by the orphan gates
# below) now live in modules/ves-timeout-retry.sh.






















# Find source= from a same-host IN_PROGRESS flag whose pid= matches script_pid.
# Memoized per $root: this is called once per staged candidate needing
# source resolution during a single reaper run, and after a fleet-wide crash
# leaves many orphaned staging dirs behind, that's a full recursive find over
# the whole (possibly NFS-shared, library-sized) $root repeated once per
# candidate, on top of the main reaper loop's own identical scan -- O(N)
# full-tree walks in a single run. Cache the flag list the first time any
# root is scanned within this process and reuse it for the rest of the run.
declare -A _ORPHAN_FLAG_LIST_CACHE=()






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












# ffmpeg hevc_vaapi encode (AMD VCN via mesa). Used when HandBrake lacks vce/vcn.
vaapi_hevc_encode() {
  local src="$1"
  local dst="$2"
  local hb_title="${3:-}"
  local qp bitrate af_args hdr_mode
  local -a ff_args=()
  local real_dst="$dst"

  if [ -n "$hb_title" ]; then
    warn "AMD VAAPI path cannot select HandBrake disc titles — falling back to software x265"
    handbrake_encode "$src" "$dst" "x265" "" "$hb_title"
    return $?
  fi

  # Same reasoning as ffmpeg_encode_hw: no libplacebo-equivalent filter is
  # available on this path, so a Profile 5 (or unclassifiable DoVi) source
  # can't be handled safely here.
  hdr_mode="$(determine_hdr_mode "$src")"
  case "$hdr_mode" in
    pq_reconstruct|unknown)
      warn "AMD VAAPI path can't handle this source's Dolby Vision — falling back to software x265: $src"
      handbrake_encode "$src" "$dst" "x265" "" "$hb_title"
      return $?
      ;;
  esac

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

  dst="$(resolve_encode_stage_path "$src" "$real_dst")" || {
    warn "Cannot safely stage output for this title — skipping rather than risk the direct-write symlink race: $real_dst"
    return 1
  }
  _configure_amd_vaapi_runtime_env
  af_args="volume=${AUDIO_GAIN}"
  # Approximate HandBrake DRC with a light compressor when DRC > 1.
  if awk -v d="$AUDIO_DRC" 'BEGIN { exit !(d > 1.01) }'; then
    af_args="acompressor=threshold=-18dB:ratio=3:attack=20:release=250,volume=${AUDIO_GAIN}"
  fi

  local -a hdr_tags=()
  case "$hdr_mode" in
    pq)  hdr_tags=(-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc) ;;
    hlg) hdr_tags=(-color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc) ;;
  esac

  log "Encoding (hevc_vaapi / AMD VCN on $AMD_VAAPI_DEVICE)..."
  build_real_subtitle_map_args 0 "$src"
  # mp4/m4v/mov -> srt exception, same as try_av1_convert's sub_args and
  # remux_copy_to_mkv's sub_codec -- Matroska cannot hold mov_text at all.
  # This hw-encode path hardcoded "-c:s copy" and was missed when that fix
  # went in elsewhere, so it would fail outright on any MP4 source with
  # subtitles (found in team review, 2026-08-02).
  local sub_codec="copy"
  case "$(to_lower "${src##*.}")" in
    mp4|m4v|mov) sub_codec="srt" ;;
  esac
  ff_args=(
    -y -nostdin -stats -loglevel warning
    -init_hw_device "vaapi=amd:${AMD_VAAPI_DEVICE}"
    -filter_hw_device amd
    -i "$src"
    -map 0:v:0 -map 0:a? "${REAL_SUBTITLE_MAP_ARGS[@]}"
    -vf "format=nv12,hwupload"
    -c:v hevc_vaapi -rc_mode CQP -qp "$qp"
    "${hdr_tags[@]}"
    -c:a aac -b:a "${bitrate}k" -af "$af_args"
    -c:s "$sub_codec"
    -f matroska
    "$dst"
  )
  # rc=0; cmd || rc=$? -- see ffmpeg_encode_hw's comment: a bare failing
  # command here aborts the whole script under `set -e` before `rc=$?` on
  # the next line ever runs (verified via direct bash testing, 2026-07-22).
  local rc=0
  # Force radeonsi on the ffmpeg process — do not rely on ambient LIBVA (QSV may set iHD).
  run_tracked_encoder "ffmpeg AMD VAAPI encode" env LIBVA_DRIVER_NAME=radeonsi LIBVA_DRI3_DISABLE="${LIBVA_DRI3_DISABLE:-1}" \
    "${FFMPEG_CMD[@]}" "${ff_args[@]}" || rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$dst" ]; then
    warn "ffmpeg hevc_vaapi reported success but output is missing/empty: $dst"
    rc=1
  fi
  if [ "$rc" -eq 0 ] && [ "$dst" != "$real_dst" ]; then
    if ! finalize_staged_encode_output "$dst" "$real_dst"; then
      warn "Output staging: failed to move staged hevc_vaapi output to $real_dst"
      rc=1
    fi
  elif [ "$rc" -ne 0 ] && [ "$dst" != "$real_dst" ]; then
    rm -f "$dst" 2>/dev/null
    _cleanup_staged_file_dir "$dst"
  fi
  return "$rc"
}

remux_copy_to_mkv() {
  local src="$1"
  local dst="$2"
  local real_dst="$dst"
  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] remux $src -> $dst"
    return 0
  fi
  dst="$(resolve_encode_stage_path "$src" "$real_dst")" || {
    warn "Cannot safely stage output for this title — skipping rather than risk the direct-write symlink race: $real_dst"
    return 1
  }
  log "Remuxing (stream copy)..."
  # Subtitle codec: same mp4/m4v/mov -> srt exception the full re-encode
  # path already applies (see try_av1_convert's sub_args) -- Matroska
  # cannot hold mov_text (MP4's native text-subtitle codec) at all. Found
  # 2026-08-01 on "Under the Microscope (2023) S01E11.mp4" (already-HEVC,
  # taking the plain remux-shortcut path): a blanket `-c copy` for every
  # stream (this function's prior behavior) hit
  # "Subtitle codec mov_text (94213) is not supported" ->
  # "Could not write header" -> the WHOLE remux failed, not just the
  # subtitle track, so a source needing container elimination could never
  # be eliminated. This function is shared by every remux-shortcut call
  # site (must-eliminate-format floor, HEVC-in-MKV shortcut, legacy-
  # container "x265 remux to MKV" path), so this was a real gap
  # everywhere, not just the one file that happened to surface it.
  local sub_codec="copy"
  case "$(to_lower "${src##*.}")" in
    mp4|m4v|mov) sub_codec="srt" ;;
  esac
  # -map 0:v/0:a?/0:t?/0:d? plus a filtered subtitle list, not a blanket
  # "-map 0" -- same flagged-but-empty subtitle problem as the main encode
  # path (see build_real_subtitle_map_args): this remux-shortcut is a real
  # final-output path too (must-eliminate-format floor, HEVC-in-MKV
  # shortcut, legacy-container remux), so it needs the same filtering.
  build_real_subtitle_map_args 0 "$src"
  # rc=0; cmd || rc=$? -- see ffmpeg_encode_hw's comment: a bare failing
  # command here aborts the whole script under `set -e` before `rc=$?` on
  # the next line ever runs (verified via direct bash testing, 2026-07-22).
  # Especially reachable here: this remux is the exact operation used for
  # must-eliminate-format container elimination and the HEVC-in-MKV
  # lossless-remux shortcut, both common paths at fleet scale.
  local rc=0
  # "0:v?" not "0:v" -- an audio-only source (no video stream at all)
  # would otherwise fail outright with "Stream map '0:v' matches no
  # streams" instead of losslessly remuxing the audio (found in team
  # review, 2026-08-02). -map_chapters 0 -map_metadata 0 made explicit
  # rather than relying on ffmpeg's default behavior now that every other
  # map is explicit too.
  run_tracked_encoder "ffmpeg remux" "${FFMPEG_CMD[@]}" -y -nostdin -stats -loglevel warning -i "$src" \
    -map "0:v?" -map "0:a?" -map "0:t?" -map "0:d?" "${REAL_SUBTITLE_MAP_ARGS[@]}" \
    -map_chapters 0 -map_metadata 0 \
    -c:v copy -c:a copy -c:s "$sub_codec" "$dst" || rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$dst" ]; then
    warn "remux reported success but output is missing/empty: $dst"
    rc=1
  fi
  if [ "$rc" -eq 0 ] && [ "$dst" != "$real_dst" ]; then
    if ! finalize_staged_encode_output "$dst" "$real_dst"; then
      warn "Output staging: failed to move staged remux output to $real_dst"
      return 1
    fi
  elif [ "$rc" -ne 0 ]; then
    if [ "$dst" != "$real_dst" ]; then
      rm -f "$dst" 2>/dev/null
      _cleanup_staged_file_dir "$dst"
    fi
    return 1
  fi
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
      out_mt="$(mkv_structure_stat_key "$out" 2>/dev/null)" || true; out_mt="${out_mt##*|}"
      src_mt="$(mkv_structure_stat_key "$src" 2>/dev/null)" || true; src_mt="${src_mt##*|}"
      if { [[ "$out_mt" =~ ^[0-9]+$ ]] && [[ "$src_mt" =~ ^[0-9]+$ ]] && [ "$out_mt" -lt "$src_mt" ]; } \
         || ! derived_output_codec_claim_matches "$out"; then
        flag_bad_source_for_human "$src" "computed output path already exists and doesn't look like our own prior output — needs manual review before overwriting"
        return 1
      fi
    fi
    log "AV1 remux to MKV: $src -> $out"
    remux_copy_to_mkv "$src" "$out" || { warn "Remux failed — skipping title: $src"; return 1; }
    if ! validate_mkv_output "$src" "$out"; then
      if [ "$MKV_VALIDATE_TIMED_OUT" = true ]; then
        warn "Validation timed out for $out — leaving output in place for retry next run"
        return 1
      fi
      remove_output_only "$out"
      return 1
    fi
    finalize_mkv_output "$out" "$src" "$title"
    record_conversion_result "$src" "$out"
    return 0
  fi

  encode_src="$src"
  ref_sz="$(file_size_bytes "$src")"

  if is_derived_output "$src"; then
    orig_sibling="$(find_original_source_for_av1 "$src")" || orig_sibling=""
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
        # Deliberately NOT enrolled in the season-retry cohort. A first
        # attempt to do so (team review, 2026-07-24) was reverted after a
        # second review pass found it would have actively misbehaved rather
        # than just missing a bonus retry: season_retry_pass routes purely
        # on the stored file's current codec, and encode_src here is
        # usually the pre-conversion original (often not AV1), so it would
        # get force-routed through try_x265_convert only, never attempting
        # AV1 first the way this cohort actually needs; separately, the
        # oversized .AV1.mkv this branch is reconsidering already exists and
        # validates, so try_av1_convert/try_x265_convert's own existing-
        # output shortcut (skip_if_complete_canonical_output) would return
        # success immediately without re-encoding anything, since only
        # FORCE_REPROCESS_TAGGED bypasses that check, not
        # SEASON_RETRY_IN_PROGRESS. Fixing this properly needs changes to
        # season_retry_pass's routing/bypass logic, not just this call
        # site -- left as documented accepted scope (see ROADMAP.md)
        # instead of shipping a season-retry entry that silently no-ops.
      else
        log "Skip — sample predicts re-encode would not shrink: $src"
        # Genuinely non-derived original (not one of our own outputs) --
        # never remux/relabel it in place, just a tag-only write (no full
        # finalize_mkv_output/streaming-remux) so a future scan can skip
        # this cheaply instead of repeating the same sample-test.
        tag_preexisting_desired_format "$src"
        record_skip "$src" "AV1 re-encode sample predicts no size win"
      fi
      return 0
      ;;
    av1)
      log "Sample predicts AV1 re-encode would shrink — proceeding with AV1"
      local __rc
      SEASON_SAMPLE_DECISION_CONTEXT=true
      try_av1_convert "$encode_src" && __rc=0 || __rc=$?
      SEASON_SAMPLE_DECISION_CONTEXT=false
      return $__rc
      ;;
    x265)
      log "Sample predicts x265 re-encode would shrink — proceeding with x265"
      local __rc
      SEASON_SAMPLE_DECISION_CONTEXT=true
      try_x265_convert "$encode_src" && __rc=0 || __rc=$?
      SEASON_SAMPLE_DECISION_CONTEXT=false
      return $__rc
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
  # Set by process_disk for a disc-extraction job: $src is actually a
  # symlink to a temporary lossless intermediate, and logical_source is the
  # TRUE original (the ISO/BDMV) that size-guardrail/must-eliminate-format/
  # done-log accounting must be anchored on instead. Defaults to $src for
  # every ordinary (non-disc) call site. Team review, 2026-07-31.
  local logical_source="${4:-$src}"
  local dir title out gpu policy
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src")"
  out="$(av1_output_path "$src")"
  JOB_LOGICAL_SOURCE="$logical_source"
  # try_av1_convert is the sole entry point for a fresh (non-av1/non-hevc)
  # source (see process_video) -- reset any stale candidate from a prior
  # source before this run might stash (or fail to stash) its own. Also
  # clean up any orphaned staging file this exact source might have left
  # behind from a prior run that hit an early-return path (path collision,
  # symlink refusal) without consuming it -- idempotent, self-healing on
  # every retry rather than accumulating forever.
  rm -f -- "${out}.must_eliminate_stash" 2>/dev/null || true
  MUST_ELIMINATE_AV1_CANDIDATE=""
  MUST_ELIMINATE_AV1_CANDIDATE_SIZE=""

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

  # Bypassed when the user explicitly approved re-processing this exact
  # tagged single-file target -- otherwise an existing valid derived
  # output would silently defeat that approval the same way the done-log
  # and tag-check would have (FORCE_REPROCESS_TAGGED is guaranteed
  # single-file-scoped by startup, see the SINGLE_FILE_MODE guard above).
  if [ "$FORCE_REPROCESS_TAGGED" != true ]; then
    skip_if_complete_canonical_output "$src" "$hb_dur" && return 0
  fi

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
    try_x265_convert "$src" "$hb_title" "$hb_dur" false false "$logical_source"
    return $?
  }

  if [ "$DRY_RUN" = true ]; then
    return 0
  fi

  validate_mkv_output "$src" "$out" "$hb_dur" || {
    if [ "$MKV_VALIDATE_TIMED_OUT" = true ]; then
      warn "AV1 validation timed out — leaving output in place for retry next run: $out"
      return 1
    fi
    capture_validation_failure_evidence "$src" "$out" "${MKV_VALIDATE_FAILURE_REASON:-validation_failed}" "$hb_dur"
    remove_output_only "$out"
    warn "AV1 validation failed — trying x265 fallback"
    try_x265_convert "$src" "$hb_title" "$hb_dur" false false "$logical_source"
    return $?
  }

  local orig_sz new_sz upscaled=false
  if is_disk_source "$logical_source"; then
    orig_sz="$(disc_source_size_bytes "$logical_source")"
  else
    orig_sz="$(file_size_bytes "$src")"
  fi
  new_sz="$(file_size_bytes "$out")"
  if source_is_upscaled "$src"; then
    upscaled=true
  fi
  policy="$(size_keep_policy_av1 "$orig_sz" "$new_sz" "$upscaled")"
  local eff_upscale_lim=""
  [ "$upscaled" = true ] && eff_upscale_lim="$(effective_upscale_overshoot_pct "$orig_sz")"

  if [ "$policy" = keep ]; then
    finalize_mkv_output "$out" "$src" "$title"
    if [ "$upscaled" = true ] && [ "$new_sz" -gt "$orig_sz" ]; then
      log "Kept AV1 ($(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { printf "%.1f%% of original", (n/o)*100 }'); ${UPSCALE_TARGET_HEIGHT}p upscale, ≤${eff_upscale_lim}% growth OK): $out"
    else
      log "Kept AV1 ($(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { printf "%.1f%% of original", (n/o)*100 }')): $out"
    fi
    record_conversion_result "$src" "$out"
    return 0
  fi

  if [ "$upscaled" = true ]; then
    warn "AV1 output >${eff_upscale_lim}% larger than original after ${UPSCALE_TARGET_HEIGHT}p upscale ($(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { printf "%.1f%%", ((n-o)/o)*100 }')) — trying x265 fallback"
  else
    warn "AV1 output >${AV1_MAX_OVERSHOOT_PCT}% larger than original ($(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { printf "%.1f%%", ((n-o)/o)*100 }')) — trying x265 fallback"
  fi
  if is_must_eliminate_format "$logical_source"; then
    # Don't throw away an oversized-but-successful AV1 encode for a format
    # we're actively trying to eliminate -- stash it so try_x265_convert can
    # tie-break against its own result instead of giving up entirely. Stashed
    # under a non-canonical name (not $out) so skip_if_complete_canonical_output
    # can never mistake this unfinalized candidate for a finished job on the
    # very next call (try_x265_convert checks that first thing) -- it's moved
    # back to $out only once actually chosen as the winner.
    local stash="${out}.must_eliminate_stash"
    if mv -f -- "$out" "$stash" 2>/dev/null; then
      MUST_ELIMINATE_AV1_CANDIDATE="$stash"
      MUST_ELIMINATE_AV1_CANDIDATE_SIZE="$new_sz"
      log "Source is a must-eliminate format — oversized AV1 stashed as fallback candidate pending x265 tie-break: $stash"
    else
      warn "Could not stash oversized AV1 candidate — discarding: $out"
      remove_output_only "$out"
    fi
  else
    remove_output_only "$out"
  fi
  try_x265_convert "$src" "$hb_title" "$hb_dur" true false "$logical_source"
}

try_x265_convert() {
  local src="$1"
  local hb_title="${2:-}"
  local hb_dur="${3:-}"
  # Set only by try_av1_convert's genuine size-overshoot fallback (not its
  # encode-failure or validation-failure fallbacks, and not
  # process_existing_av1's sample-predicted direct call, where AV1 was never
  # actually evaluated against the size guardrail this run) -- gates
  # tag_guardrail_exceeded below so a transient AV1 tool/hardware failure
  # can never get permanently mistaken for "doesn't fit within guardrails".
  local av1_size_rejected="${4:-false}"
  # Set by process_existing_x265's "x265" sample decision (the sample
  # predicted a FRESH x265 pass would shrink the file further, which the
  # ordinary HEVC-MKV stream-copy remux shortcut below could never deliver --
  # it doesn't re-encode at all) and by season_retry_pass's own HEVC/x265-
  # cohort retries, for the identical reason -- both force past that shortcut
  # into a real transcode so the intended re-encode is actually attempted.
  local force_transcode="${5:-false}"
  # See try_av1_convert's matching param -- defaults to $src for every
  # ordinary (non-disc) call site.
  local logical_source="${6:-$src}"
  local dir title out gpu encoder codec ext src_codec policy
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src")"
  out="$(x265_output_path "$src")"
  codec="$(video_codec "$src")"
  src_codec="$codec"
  ext="$(to_lower "${src##*.}")"
  JOB_LOGICAL_SOURCE="$logical_source"

  # See the matching guard in try_av1_convert -- same reasoning: a file named
  # like our own output convention (e.g. "Movie.x265.mkv") whose actual codec
  # isn't HEVC would otherwise compute an output path identical to itself.
  if [ "$(canonical_path "$src" 2>/dev/null || printf '%s' "$src")" = "$(canonical_path "$out" 2>/dev/null || printf '%s' "$out")" ]; then
    err "Refusing to encode — computed output path is identical to the source, would destroy it: $src"
    flag_bad_source_for_human "$src" "derived output path collides with source path (name/codec mismatch?) — needs manual rename/review"
    # Don't leak a stashed AV1 candidate for this source into orphanhood --
    # $src is about to move into Deferred/ and won't be retried normally, so
    # nothing will ever clean this up via try_av1_convert's entry cleanup.
    # Ownership check first: a leaked global from an unrelated title must
    # never be deleted here (see must_eliminate_fallback_or_fail).
    if [ -n "$MUST_ELIMINATE_AV1_CANDIDATE" ] && [ "$MUST_ELIMINATE_AV1_CANDIDATE" = "$(av1_output_path "$src").must_eliminate_stash" ]; then
      rm -f -- "$MUST_ELIMINATE_AV1_CANDIDATE" 2>/dev/null || true
      MUST_ELIMINATE_AV1_CANDIDATE=""
      MUST_ELIMINATE_AV1_CANDIDATE_SIZE=""
    fi
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
    if [ -n "$MUST_ELIMINATE_AV1_CANDIDATE" ] && [ "$MUST_ELIMINATE_AV1_CANDIDATE" = "$(av1_output_path "$src").must_eliminate_stash" ]; then
      rm -f -- "$MUST_ELIMINATE_AV1_CANDIDATE" 2>/dev/null || true
      MUST_ELIMINATE_AV1_CANDIDATE=""
      MUST_ELIMINATE_AV1_CANDIDATE_SIZE=""
    fi
    return 1
  fi

  # Bypassed when the user explicitly approved re-processing this exact
  # tagged single-file target -- otherwise an existing valid derived
  # output would silently defeat that approval the same way the done-log
  # and tag-check would have (FORCE_REPROCESS_TAGGED is guaranteed
  # single-file-scoped by startup, see the SINGLE_FILE_MODE guard above).
  if [ "$FORCE_REPROCESS_TAGGED" != true ]; then
    skip_if_complete_canonical_output "$src" "$hb_dur" && return 0
  fi

  # Never remux-shortcut a Dolby Vision source — stream copy preserves the
  # RPU/DoVi tagging verbatim, defeating the DoVi->HDR10 conversion below.
  # DoVi sources always take the real re-encode path.
  if [ "$force_transcode" != true ] && [ "$ext" = "mkv" ] && is_hevc_codec "$codec" && [ -z "$hb_title" ] \
     && ! source_has_dolby_vision "$src"; then
    log "x265 remux (HEVC stream copy to MKV): $src -> $out"
    remux_copy_to_mkv "$src" "$out" || { warn "Remux failed — skipping title: $src"; return 1; }
    if [ "$DRY_RUN" = true ]; then
      return 0
    fi
    validate_mkv_output "$src" "$out" "$hb_dur" || {
      if [ "$MKV_VALIDATE_TIMED_OUT" = true ]; then
        warn "Validation timed out for $out — leaving output in place for retry next run"
        return 1
      fi
      remove_output_only "$out"
      return 1
    }
    finalize_mkv_output "$out" "$src" "$title"
    log "Kept x265 remux ($(awk -v o="$(file_size_bytes "$src")" -v n="$(file_size_bytes "$out")" 'BEGIN { printf "%.1f%% of original", (n/o)*100 }')): $out"
    record_conversion_result "$src" "$out"
    return 0
  fi

  if [ "$ENCODE_ENGINE" = ffmpeg ] && [ -z "$hb_title" ] && ! is_disk_source "$src"; then
    encoder="ffmpeg/libx265"
    log "x265 transcode (ffmpeg engine): $src"
    encode_dispatch "$src" "$out" "x265" "" "" || { remove_output_only "$out"; must_eliminate_fallback_or_fail "$src" "$title" "$logical_source" && return 0; return 1; }
  elif [ "$USE_NVIDIA_ENCODE" = true ]; then
    encoder="nvenc_h265"
    gpu="$GPU_HEVC_PRIMARY"
    log "x265 transcode (nvenc_h265, GPU $gpu): $src"
    handbrake_encode "$src" "$out" "$encoder" "$gpu" "$hb_title" || {
      if [ "$NVIDIA_GPU_COUNT" -gt 1 ]; then
        warn "Primary GPU HEVC failed; trying GPU $GPU_HEVC_FALLBACK"
        handbrake_encode "$src" "$out" "$encoder" "$GPU_HEVC_FALLBACK" "$hb_title" || { remove_output_only "$out"; must_eliminate_fallback_or_fail "$src" "$title" "$logical_source" && return 0; return 1; }
      else
        remove_output_only "$out"
        must_eliminate_fallback_or_fail "$src" "$title" "$logical_source" && return 0
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
      handbrake_encode "$src" "$out" "$encoder" "" "$hb_title" || { remove_output_only "$out"; must_eliminate_fallback_or_fail "$src" "$title" "$logical_source" && return 0; return 1; }
    fi
  elif [ "$USE_VT_ENCODE" = true ]; then
    encoder="vt_h265"
    log "x265 transcode (vt_h265, VideoToolbox): $src"
    handbrake_encode "$src" "$out" "$encoder" "" "$hb_title" || { remove_output_only "$out"; must_eliminate_fallback_or_fail "$src" "$title" "$logical_source" && return 0; return 1; }
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
      handbrake_encode "$src" "$out" "$encoder" "" "$hb_title" || { remove_output_only "$out"; must_eliminate_fallback_or_fail "$src" "$title" "$logical_source" && return 0; return 1; }
    fi
  else
    encoder="x265"
    log "x265 transcode (software x265): $src"
    handbrake_encode "$src" "$out" "$encoder" "" "$hb_title" || { remove_output_only "$out"; must_eliminate_fallback_or_fail "$src" "$title" "$logical_source" && return 0; return 1; }
  fi

  if [ "$DRY_RUN" = true ]; then
    return 0
  fi

  validate_mkv_output "$src" "$out" "$hb_dur" || {
    if [ "$MKV_VALIDATE_TIMED_OUT" = true ]; then
      warn "Validation timed out for $out — leaving output in place for retry next run"
      return 1
    fi
    capture_validation_failure_evidence "$src" "$out" "${MKV_VALIDATE_FAILURE_REASON:-validation_failed}" "$hb_dur"
    remove_output_only "$out"
    must_eliminate_fallback_or_fail "$src" "$title" "$logical_source" && return 0
    return 1
  }

  local orig_sz new_sz upscaled=false
  if is_disk_source "$logical_source"; then
    orig_sz="$(disc_source_size_bytes "$logical_source")"
  else
    orig_sz="$(file_size_bytes "$src")"
  fi
  new_sz="$(file_size_bytes "$out")"
  if source_is_upscaled "$src"; then
    upscaled=true
  fi
  if [ "$src_codec" = "av1" ]; then
    policy="$(size_keep_policy_av1 "$orig_sz" "$new_sz" "$upscaled")"
  else
    policy="$(size_keep_policy "$orig_sz" "$new_sz" "$upscaled")"
  fi
  local eff_upscale_lim=""
  [ "$upscaled" = true ] && eff_upscale_lim="$(effective_upscale_overshoot_pct "$orig_sz")"

  if [ "$policy" = keep ]; then
    # A must-eliminate-format source may still be holding an oversized AV1
    # candidate stashed by try_av1_convert -- x265 came in within the normal
    # guardrail on its own, so the stash is no longer needed, only cleanup.
    # Ownership check: only touch it if it's actually this src's own stash --
    # a leaked global from an unrelated title (e.g. one that hit a validation
    # timeout without clearing it) must never be deleted here, or that OTHER
    # title's still-pending candidate would be destroyed out from under it.
    if [ -n "$MUST_ELIMINATE_AV1_CANDIDATE" ] && [ "$MUST_ELIMINATE_AV1_CANDIDATE" = "$(av1_output_path "$src").must_eliminate_stash" ]; then
      rm -f -- "$MUST_ELIMINATE_AV1_CANDIDATE" 2>/dev/null || true
      MUST_ELIMINATE_AV1_CANDIDATE=""
      MUST_ELIMINATE_AV1_CANDIDATE_SIZE=""
    fi
    finalize_mkv_output "$out" "$src" "$title"
    if [ "$upscaled" = true ] && [ "$new_sz" -gt "$orig_sz" ]; then
      log "Kept x265 ($(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { printf "%.1f%% of original", (n/o)*100 }'); ${UPSCALE_TARGET_HEIGHT}p upscale, ≤${eff_upscale_lim}% growth OK): $out"
    else
      log "Kept x265 ($(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { printf "%.1f%% of original", (n/o)*100 }')): $out"
    fi
    record_conversion_result "$src" "$out"
    return 0
  fi

  # Both AV1 and x265 exceed the normal size guardrail, but the source is a
  # format we actively want to eliminate (disc image, raw transport stream,
  # legacy container -- see is_must_eliminate_format). Eliminating the
  # undesirable format/codec matters more than the size cap here, so tie-break
  # between the two oversized candidates instead of giving up and leaving the
  # original in place: within MUST_ELIMINATE_TIE_PCT of each other, prefer
  # AV1 (better long-term codec); otherwise take whichever is smaller.
  if [ -n "$MUST_ELIMINATE_AV1_CANDIDATE" ] && [ -f "$MUST_ELIMINATE_AV1_CANDIDATE" ] && is_must_eliminate_format "$logical_source" \
     && [ "$MUST_ELIMINATE_AV1_CANDIDATE" = "$(av1_output_path "$src").must_eliminate_stash" ]; then
    # Ownership check (see must_eliminate_fallback_or_fail for why): without
    # it, a leaked global from an unrelated title could get tie-broken
    # against or deleted by THIS title's x265 result -- wrong file entirely.
    local av1_cand="$MUST_ELIMINATE_AV1_CANDIDATE" av1_cand_sz="$MUST_ELIMINATE_AV1_CANDIDATE_SIZE" delta_pct canonical_av1_out
    canonical_av1_out="$(av1_output_path "$src")"
    # Guard against a zero/empty stashed size (shouldn't happen -- the stash
    # only ever comes from a just-validated real encode's file_size_bytes --
    # but awk division by zero under mawk/BSD awk aborts the whole script
    # under set -e, so fail closed to the x265 side rather than crash.
    if [ -z "$av1_cand_sz" ] || [ "$av1_cand_sz" -le 0 ] 2>/dev/null; then
      warn "Stashed AV1 candidate has an invalid size — discarding, keeping oversized x265 instead: $av1_cand"
      rm -f -- "$av1_cand" 2>/dev/null || true
      MUST_ELIMINATE_AV1_CANDIDATE=""
      MUST_ELIMINATE_AV1_CANDIDATE_SIZE=""
      finalize_mkv_output "$out" "$src" "$title"
      record_conversion_result "$src" "$out"
      return 0
    fi
    delta_pct="$(awk -v a="$av1_cand_sz" -v x="$new_sz" 'BEGIN { d=a-x; if (d<0) d=-d; printf "%.4f", (d/a)*100 }')"
    MUST_ELIMINATE_AV1_CANDIDATE=""
    MUST_ELIMINATE_AV1_CANDIDATE_SIZE=""
    if awk -v d="$delta_pct" -v t="$MUST_ELIMINATE_TIE_PCT" 'BEGIN { exit !(d<=t) }'; then
      log "Must-eliminate format: oversized AV1/x265 within ${MUST_ELIMINATE_TIE_PCT}% of each other — keeping AV1 (format elimination overrides size cap): $canonical_av1_out"
      # Team review (2026-07-22): move the stash into place and CONFIRM it
      # succeeded before deleting the (already-validated, working) x265
      # fallback -- the old order deleted x265 unconditionally, then ran an
      # UNCHECKED mv. If the mv failed (NFS ESTALE/ENOSPC/permission), the
      # source ended up with neither output in place, yet
      # record_conversion_result unconditionally marks it done regardless of
      # whether the output path actually exists -- exactly the "silently
      # marked processed but nothing was actually produced" class of bug
      # this whole feature exists to prevent.
      if mv -f -- "$av1_cand" "$canonical_av1_out" 2>/dev/null; then
        remove_output_only "$out"
        finalize_mkv_output "$canonical_av1_out" "$src" "$title"
        record_conversion_result "$src" "$canonical_av1_out"
        return 0
      fi
      warn "Could not move stashed AV1 candidate into place ($av1_cand -> $canonical_av1_out) — keeping the already-validated x265 output instead: $out"
      rm -f -- "$av1_cand" 2>/dev/null || true
      finalize_mkv_output "$out" "$src" "$title"
      record_conversion_result "$src" "$out"
      return 0
    elif [ "$av1_cand_sz" -lt "$new_sz" ]; then
      log "Must-eliminate format: oversized AV1 candidate smaller than x265 — keeping AV1 (format elimination overrides size cap): $canonical_av1_out"
      if mv -f -- "$av1_cand" "$canonical_av1_out" 2>/dev/null; then
        remove_output_only "$out"
        finalize_mkv_output "$canonical_av1_out" "$src" "$title"
        record_conversion_result "$src" "$canonical_av1_out"
        return 0
      fi
      warn "Could not move stashed AV1 candidate into place ($av1_cand -> $canonical_av1_out) — keeping the already-validated x265 output instead: $out"
      rm -f -- "$av1_cand" 2>/dev/null || true
      finalize_mkv_output "$out" "$src" "$title"
      record_conversion_result "$src" "$out"
      return 0
    else
      log "Must-eliminate format: oversized x265 candidate smaller than AV1 — keeping x265 (format elimination overrides size cap): $out"
      rm -f -- "$av1_cand" 2>/dev/null || true
      finalize_mkv_output "$out" "$src" "$title"
      record_conversion_result "$src" "$out"
      return 0
    fi
  fi

  # Must-eliminate format with no AV1 candidate to tie-break against (AV1
  # itself failed to encode/validate this run, or was never attempted) --
  # x265 is the only surviving candidate, and it's still better than leaving
  # the undesirable disc image/transport-stream/legacy container in place.
  # Keep it despite exceeding the normal size cap.
  if is_must_eliminate_format "$logical_source"; then
    log "Must-eliminate format: no AV1 candidate to compare — keeping oversized x265 anyway (format elimination overrides size cap): $out"
    finalize_mkv_output "$out" "$src" "$title"
    record_conversion_result "$src" "$out"
    return 0
  fi

  if [ "$upscaled" = true ]; then
    warn "x265 output >${eff_upscale_lim}% larger after ${UPSCALE_TARGET_HEIGHT}p upscale ($(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { printf "%.1f%%", ((n-o)/o)*100 }')) — rejected (keeping original)"
  elif [ "$src_codec" = "av1" ]; then
    warn "x265 output not smaller than oversized AV1 — rejected"
  else
    warn "x265 output >${SIZE_OVERSHOOT_PCT}% larger ($(awk -v o="$orig_sz" -v n="$new_sz" 'BEGIN { printf "%.1f%%", ((n-o)/o)*100 }')) — rejected"
  fi
  remove_output_only "$out"
  # Only tag when AV1 was itself genuinely size-rejected this run (not when
  # it merely failed to encode/validate, or was never attempted at all) --
  # otherwise a transient tool/hardware failure could get permanently
  # mistaken for "doesn't fit within guardrails" and never retried once
  # fixed. When true, both candidates really did exceed the size guardrails,
  # so a future scan doesn't need to repeat the same doomed cycle.
  [ "$av1_size_rejected" = true ] && tag_guardrail_exceeded "$logical_source"
  return 1
}

# Extracts the selected title losslessly via HandBrake, symlinks it into
# media_content_dir under the disc's own name, then runs it through the
# EXACT SAME ffmpeg VMAF-CRF-search pipeline every other library file uses
# (rather than HandBrake doing the final AV1/x265 encode itself, the old
# behavior) -- user direction, 2026-07-31. The symlink is what makes this
# work with zero changes to canonical_title_from_source/media_content_dir/
# av1_output_path/profile_for_source/ffprobe-based codec detection: they
# all just see an ordinary, real .mkv (ffmpeg/ffprobe/HandBrake all follow
# read-side symlinks transparently). try_av1_convert's logical_source param
# (team review) keeps size-guardrail/must-eliminate-format/done-log
# accounting anchored on the TRUE original disc, not the temporary
# lossless intermediate. The original ISO/BDMV is never touched or
# deleted, matching this script's existing convention for every other
# must-eliminate format (e.g. .avi) -- it's simply left in place once a
# new AV1/x265 output exists alongside it.
process_disk() {
  local src="$1"
  local sel title_idx title_dur title_dur_unique kind
  local extracted link_name rc=0
  # Reset unconditionally at every per-file entry point (here and in
  # process_video) -- record_conversion_result reads this as a sticky
  # global, so without a reset here a PREVIOUS disc job's logical source
  # would otherwise leak into this job's accounting if this job's own
  # try_av1_convert call never re-set it (can't happen on the success path,
  # but a defensive reset costs nothing and removes the class of bug
  # entirely). Found in team review, 2026-07-31.
  JOB_LOGICAL_SOURCE=""

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
      IFS=':' read -r _ title_idx title_dur title_dur_unique <<< "$sel"
      ;;
    *)
      warn "Skipping $kind: title scan failed"
      record_skip "$src" "title scan failed"
      return 0
      ;;
  esac

  link_name="$(media_content_dir "$src")/$(disc_extract_link_basename "$src")"
  if [ -e "$link_name" ] && [ ! -L "$link_name" ]; then
    warn "Skipping $kind: extraction target already exists and isn't our own symlink — needs manual review: $link_name"
    record_skip "$src" "extraction target collides with an existing real file"
    return 0
  fi
  # A leftover symlink from a prior crashed/interrupted run at this exact
  # name is always safe to remove outright -- rm on a symlink only ever
  # removes the link itself, never whatever it used to point at (same
  # reasoning already established for the sidecar-state-file symlink guard
  # in resume_init_paths).
  [ -L "$link_name" ] && rm -f -- "$link_name" 2>/dev/null

  log "Processing ($kind title $title_idx, ${title_dur}s): $src"
  extracted="$(handbrake_extract_disc_title_lossless "$src" "$title_idx" "$title_dur" "$title_dur_unique")" || {
    warn "Skipping $kind: lossless title extraction failed"
    record_skip "$src" "lossless title extraction failed"
    return 0
  }

  ln -s -- "$extracted" "$link_name" || {
    warn "Skipping $kind: could not create extraction symlink: $link_name"
    record_skip "$src" "could not create extraction symlink"
    rm -rf -- "$(dirname -- "$extracted")" 2>/dev/null || true
    DISC_EXTRACT_SCRATCH_FILE=""
    return 0
  }
  DISC_EXTRACT_SYMLINK_PATH="$link_name"

  try_av1_convert "$link_name" "" "" "$src" || rc=$?

  rm -f -- "$link_name" 2>/dev/null || true
  rm -rf -- "$(dirname -- "$extracted")" 2>/dev/null || true
  DISC_EXTRACT_SYMLINK_PATH=""
  DISC_EXTRACT_SCRATCH_FILE=""
  return "$rc"
}

process_video() {
  local src="$1"
  local codec kind ext profile
  # See process_disk's matching reset -- both are per-file entry points,
  # and JOB_LOGICAL_SOURCE must never leak a previous disc job's identity
  # into an unrelated ordinary file's accounting.
  JOB_LOGICAL_SOURCE=""
  profile="$(profile_for_source "$src")" || return $?
  codec="$(video_codec "$src")"
  ext="$(to_lower "${src##*.}")"
  if is_tv_episode "$src"; then
    kind="TV episode"
  else
    kind="movie"
  fi

  kind="$profile $kind"

  log "Processing ($kind): $src (codec=$codec container=$ext)"

  if ! validate_source_media "$src"; then
    # A durable bad-source verdict (flag_bad_source_for_human already moved
    # it to Deferred/) is a legitimate, final "nothing more to do" outcome --
    # return 0 there is correct. But a transient stalled-mount timeout is
    # not: it must surface as a real job failure so it isn't silently logged
    # as "Job complete" and, more importantly, isn't wrongly marked
    # `completed` in the resume state (which would make a later resumed run
    # skip it forever instead of retrying once the mount recovers). See
    # SOURCE_VALIDATE_TIMED_OUT's declaration for the full reasoning.
    if [ "$SOURCE_VALIDATE_TIMED_OUT" = true ]; then
      return 1
    fi
    return 0
  fi

  if [ "$codec" = "av1" ]; then
    # Size short-circuit only applies to a genuine, non-derived .mkv library
    # file -- a non-mkv AV1 source still needs the remux-to-MKV path below
    # (process_existing_av1 handles that), and a derived *.AV1.mkv queued for
    # an oversized recheck must actually go through that recheck, not get
    # short-circuited into a tag write that would wipe its existing VMAF tag.
    if [ "$ext" = "mkv" ] && ! is_derived_output "$src"; then
      local av1_mb=$(( $(file_size_bytes "$src") / 1048576 ))
      if [ "$av1_mb" -le "$PREEXISTING_SMALL_SKIP_MAX_MB" ]; then
        log "AV1 source already ≤${PREEXISTING_SMALL_SKIP_MAX_MB}MB — skipping sample-test, already the desired format: $src"
        tag_preexisting_desired_format "$src"
        record_skip "$src" "AV1 source already small enough — preexisting desired format"
        return 0
      fi
    fi
    local rc=0
    process_existing_av1 "$src" || rc=$?
    return "$rc"
  fi
  if is_hevc_codec "$codec"; then
    if [ "$ext" = "mkv" ] && ! is_derived_output "$src"; then
      local x265_mb=$(( $(file_size_bytes "$src") / 1048576 ))
      if [ "$x265_mb" -le "$PREEXISTING_X265_SMALL_SKIP_MAX_MB" ]; then
        log "x265 source already ≤${PREEXISTING_X265_SMALL_SKIP_MAX_MB}MB — skipping sample-test, already the desired format: $src"
        tag_preexisting_desired_format "$src"
        record_skip "$src" "x265 source already small enough — preexisting desired format"
        return 0
      fi
    fi
    local rc=0
    process_existing_x265 "$src" || rc=$?
    return "$rc"
  fi
  try_av1_convert "$src"
}

# x265 sources were previously never reconsidered at all once converted --
# always sample-test first (regardless of size) whether AV1 (or a fresh
# x265 re-encode) would shrink it further, rather than committing straight
# to a full real re-encode attempt.
# avoids committing to a full real re-encode attempt (which for a multi-GB
# file can mean hours) only to have it rejected post-hoc by the size-keep
# guardrail anyway. Reuses the same sample primitive as the AV1-source
# recheck, since it's codec-agnostic on input.
process_existing_x265() {
  local src="$1"
  local title ext out decision ref_sz

  title="$(movie_title_from_file "$src")"
  ext="$(to_lower "${src##*.}")"

  # Container unification: a non-mkv x265 source (mp4/ts/etc.) always gets
  # remuxed to .x265.mkv first, before any sample-testing -- the project
  # goal is eliminating every non-MKV container, and a lossless stream-copy
  # remux achieves that regardless of what the size-benefit sample-test
  # would say. Mirrors process_existing_av1's identical non-mkv handling.
  if [ "$ext" != "mkv" ]; then
    out="$(x265_output_path "$src")"
    if [ -L "$out" ]; then
      err "Refusing to remux — output path is a symlink, not our own plain file: $out"
      flag_bad_source_for_human "$src" "computed output path is an unexpected symlink — needs manual review before encoding"
      return 1
    fi
    if [ -e "$out" ]; then
      local out_mt src_mt
      out_mt="$(mkv_structure_stat_key "$out" 2>/dev/null)" || true; out_mt="${out_mt##*|}"
      src_mt="$(mkv_structure_stat_key "$src" 2>/dev/null)" || true; src_mt="${src_mt##*|}"
      if { [[ "$out_mt" =~ ^[0-9]+$ ]] && [[ "$src_mt" =~ ^[0-9]+$ ]] && [ "$out_mt" -lt "$src_mt" ]; } \
         || ! derived_output_codec_claim_matches "$out"; then
        flag_bad_source_for_human "$src" "computed output path already exists and doesn't look like our own prior output — needs manual review before overwriting"
        return 1
      fi
    fi
    log "x265 remux to MKV: $src -> $out"
    remux_copy_to_mkv "$src" "$out" || { warn "Remux failed — skipping title: $src"; return 1; }
    if ! validate_mkv_output "$src" "$out"; then
      if [ "$MKV_VALIDATE_TIMED_OUT" = true ]; then
        warn "Validation timed out for $out — leaving output in place for retry next run"
        return 1
      fi
      remove_output_only "$out"
      return 1
    fi
    finalize_mkv_output "$out" "$src" "$title"
    record_conversion_result "$src" "$out"
    return 0
  fi

  ref_sz="$(file_size_bytes "$src")"
  log "x265 source — sample-testing whether AV1 re-encode would shrink: $src"

  if ! decision="$(av1_source_reencode_sample_decision "$src" "$ref_sz")"; then
    warn "x265 sample test failed — leaving as-is: $src"
    record_skip "$src" "x265 sample test failed"
    return 0
  fi
  decision="$(printf '%s\n' "$decision" | tr -d '\r' | grep -E '^(skip|av1|x265)$' | tail -n1 || true)"

  case "$decision" in
    skip)
      log "Skip — sample predicts AV1 re-encode would not shrink further: $src"
      tag_preexisting_desired_format "$src"
      record_skip "$src" "x265 re-encode sample predicts no size win"
      ;;
    av1)
      log "Sample predicts AV1 re-encode would shrink — proceeding with AV1"
      local __rc
      SEASON_SAMPLE_DECISION_CONTEXT=true
      try_av1_convert "$src" && __rc=0 || __rc=$?
      SEASON_SAMPLE_DECISION_CONTEXT=false
      return $__rc
      ;;
    x265)
      log "Sample predicts a fresh x265 re-encode would shrink further — proceeding with x265"
      # force_transcode=true: without it, try_x265_convert's HEVC-MKV
      # stream-copy remux shortcut would fire (src is already HEVC/.mkv),
      # producing a same-size remux instead of the real re-encode the
      # sample just predicted would shrink the file.
      local __rc
      SEASON_SAMPLE_DECISION_CONTEXT=true
      try_x265_convert "$src" "" "" false true && __rc=0 || __rc=$?
      SEASON_SAMPLE_DECISION_CONTEXT=false
      return $__rc
      ;;
    *)
      warn "x265 sample returned unknown decision '$decision' — leaving as-is: $src"
      record_skip "$src" "x265 sample test failed"
      ;;
  esac
  return 0
}



















_convert_on_err() {
  local exit_code=$?
  kill_active_encoder
  if [ "${CONVERT_SCAN_PID:-0}" -gt 0 ] 2>/dev/null; then
    kill "$CONVERT_SCAN_PID" 2>/dev/null || true
    wait "$CONVERT_SCAN_PID" 2>/dev/null || true
    CONVERT_SCAN_PID=0
  fi
  # Mirrors resume_on_signal's cleanup -- a genuine script error (not just an
  # interrupt) mid-encode was previously leaking these same private staging
  # dirs, since only the signal path used to clean them up.
  if [ -n "${ACTIVE_LOCAL_STAGE_DIR:-}" ]; then
    rm -rf -- "$ACTIVE_LOCAL_STAGE_DIR" 2>/dev/null || true
    ACTIVE_LOCAL_STAGE_DIR=""
  fi
  if [ -n "${ACTIVE_FINALIZE_DIR:-}" ]; then
    rm -rf -- "$ACTIVE_FINALIZE_DIR" 2>/dev/null || true
    ACTIVE_FINALIZE_DIR=""
  fi
  if [ -n "${ACTIVE_STREAMOPT_DIR:-}" ]; then
    rm -rf -- "$ACTIVE_STREAMOPT_DIR" 2>/dev/null || true
    ACTIVE_STREAMOPT_DIR=""
  fi
  if [ -n "${ACTIVE_FFMPEG_STAGE1_FILE:-}" ]; then
    rm -f -- "$ACTIVE_FFMPEG_STAGE1_FILE" 2>/dev/null || true
    ACTIVE_FFMPEG_STAGE1_FILE=""
  fi
  err "Script aborted (exit $exit_code near line ${BASH_LINENO[0]:-?})"
  exit "$exit_code"
}

main() {
  trap '_convert_on_err' ERR
  trap resume_on_signal INT TERM
  assert_script_name_matches_version

  if [ -z "$FORCE_PROFILE" ]; then
    local _root_profile_rc=0
    detect_profile_for_path "$SEARCH_PATH" >/dev/null || _root_profile_rc=$?
    if [ "$_root_profile_rc" -eq 2 ]; then
      err "Movies/Japanese/Animation is ambiguous; rerun with --profile anime or --profile wanime"
      exit 1
    fi
  fi

  if [ "$CLEAN_JUNK" = true ]; then
    resume_init_paths
    clean_junk_scan "$SEARCH_PATH"
    exit 0
  fi

  if [ "$REPORT_SOURCE_TRAITS" = true ]; then
    resume_init_paths
    report_source_traits_for_path "$SEARCH_PATH"
    exit 0
  fi

  # Phase B: reap orphans left by a past hard crash before claiming new work.
  if [ "$AUTO_REAP" = true ]; then
    reap_orphaned_encoders "$SEARCH_PATH"
  else
    log "Orphan reaper: skipped (--no-auto-reap)"
  fi

  detect_hw_environment
  detect_nvenc_av1_tune
  detect_ffmpeg_capabilities
  mount_audit_for_path "$SEARCH_PATH"
  init_stats_log
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
    ramdisk_job_start
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
