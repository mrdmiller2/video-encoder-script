#!/usr/bin/env bash
# ves-config.sh -- CLI-default globals, VMAF/CQ/CRF tables, x265/SVT-AV1
# param strings, and color escape codes. Sourced first (before any other
# module) so its defaults/lookup tables are available to every other
# module. Originally a pure move from the former monolithic script;
# MULTIPART_PART_REGEX below is a new global added 2026-08-04 (team-reviewed
# bug fix) -- see its own comment.

VERSION="5.1.1Q"
SCRIPT_NAME="convert-v${VERSION}.sh"
# Multi-part-source filename marker (Part/Pt/CD/Disc N, any of space/./_/-
# as separators -- e.g. "Title - Part 1", "Title CD1", "Title-Disc-2").
# Captures: 1=title, 2=marker word (unused), 3=part number. A real global
# (not a function call) so is_tv_episode()/needs_flat_organize() can test
# against it directly without forking a subshell per file in what can be a
# hot loop over large libraries (team review, 2026-08-04).
MULTIPART_PART_REGEX='^(.*[^ ._-])[ ._-]*([Pp][Aa][Rr][Tt]|[Pp][Tt]|[Cc][Dd]|[Dd][Ii][Ss][Cc])[ ._-]*([0-9]{1,2})$'
# Matroska Tags element (global "Simple Tag") marking a file as already run through
# this script's encode pipeline -- distinct from track properties (Name/Language/
# flags) and from the Segment Info title, so clearing/rewriting it never touches
# subtitle/audio track labels or anything that affects playback. Value records the
# exact VERSION that produced the file (so we can always tell which build touched
# it), plus -- when the source was upscaled -- the output resolution and a sampled
# VMAF score, or just the VMAF score when it wasn't upscaled. The skip-check below
# matches on "VES <MAJOR>." as a prefix: a major version is defined (per project
# versioning constant) as a complete re-architecture, the only point where
# previously "optimized" output is worth reconsidering -- Mid/Minor bumps and
# lettered phases never invalidate a file already tagged by the same major line.
VES_TAG_NAME="VES_PROCESSED"
VES_MAJOR="${VERSION%%.*}"
SEARCH_PATH="."
DRY_RUN=false
DO_ORGANIZE=true
DO_CONVERT=true
SKIP_AV1=false
SKIP_X265=false
# Bypasses the VES-processed tag skip-check for this run. Set by --force-reprocess,
# or interactively when SINGLE_FILE_MODE targets an already-tagged file (see below).
FORCE_REPROCESS_TAGGED=false
# Optional override for the eight path-detected profiles. Empty means auto.
# Movies/Japanese/Animation is deliberately ambiguous and requires this flag.
FORCE_PROFILE=""
# Carries the source's resolved profile into private /tmp sample clips.
PROFILE_CONTEXT=""
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
# Must-eliminate-format sources (see is_must_eliminate_format) bypass the
# normal size-keep guardrails entirely -- eliminating the undesirable
# disc image/transport-stream/legacy container matters more than size here.
# try_av1_convert stashes an oversized AV1 candidate in these globals instead
# of deleting it so try_x265_convert can tie-break between the two oversized
# candidates rather than throwing the format-elimination attempt away.
MUST_ELIMINATE_TIE_PCT=5
MUST_ELIMINATE_AV1_CANDIDATE=""
MUST_ELIMINATE_AV1_CANDIDATE_SIZE=""
# Set by ffmpeg_encode() right after a successful QTGMC-processed encode:
# a same-representation VMAF (encoded output vs. QTGMC's deinterlaced
# intermediate, not the raw interlaced/telecined original) computed while
# the intermediate still exists, since write_ves_processed_tag's own
# measure_final_vmaf call only ever has the original $src available and
# runs after ffmpeg_encode() has already cleaned that intermediate up.
# Comparing a clean deinterlaced frame against a raw combed/interlaced
# frame at the same timestamp is not a meaningful VMAF measurement (they
# are structurally different images by design), and was seen to collapse
# to single-digit VMAF for genuinely correct QTGMC output -- found via a
# real single-file production test, 2026-08-08. Cleared immediately after
# write_ves_processed_tag consumes it so a later, unrelated title can
# never reuse stale state.
QTGMC_FINAL_VMAF_SRC=""
QTGMC_FINAL_VMAF_DST=""
QTGMC_FINAL_VMAF_VALUE=""
# Set by try_av1_convert/try_x265_convert's logical_source param (defaults
# to their own $src when not a disc-extraction job) -- lets
# record_conversion_result and done_log_append account size/identity
# against the TRUE original (e.g. an ISO/BDMV) even when $src is actually
# a symlink to a temporary lossless extraction (see process_disk,
# 2026-07-31). Reset unconditionally at both functions' own entry, so it
# never leaks stale state from a previous, unrelated title in the same run.
JOB_LOGICAL_SOURCE=""
# Disc sources (ISO/BDMV) are extracted losslessly via HandBrake (no video
# passthrough exists in HandBrake -- confirmed via --help) into a dedicated
# LOCAL-DISK scratch directory (explicitly NOT the RAM-disk/tmpfs staging
# path -- a losslessly re-encoded Blu-ray can be tens of GB, more than most
# fleet machines' available RAM), then handed to the exact same ffmpeg
# VMAF-CRF-search pipeline every other file uses via a symlink (see
# process_disk). User direction, 2026-07-31: disc sources should be
# unified into the normal pipeline, not encoded directly by HandBrake as a
# separate special-cased path.
#
# Encoder is x264 at -q 0 (true lossless), NOT ffv1: empirically tested
# ffv1 first (the more obvious "true lossless" choice, and what HandBrake
# --help suggests as the archival-lossless option) but HandBrakeCLI 1.11.0
# segfaults immediately inside encavcodecInit for the FFV1 encoder on real
# hardware -- reproduced twice, independent of quality setting, subtitle
# inclusion, or even disc-vs-plain-file source (crashed identically on a
# disc title AND on a plain library .mkv). x264 -q 0 is genuinely lossless
# (QP 0, not merely high-quality) and was verified end-to-end: real
# extraction succeeds, ffprobe/ffmpeg decode the result cleanly. Revisit
# ffv1 if/when a newer HandBrake build fixes this upstream.
DISC_EXTRACT_SCRATCH_DIR="${CONVERT_DISC_EXTRACT_SCRATCH_DIR:-/var/tmp/ves-disc-extract}"
# Free-space safety multiplier against the disc's own reported size --
# x264 -q 0 lossless can exceed the original compressed payload's size
# (team review, 2026-07-31), so this is deliberately generous
# rather than a 1:1 assumption.
DISC_EXTRACT_SPACE_MULTIPLIER=3
# Tolerance (seconds) for matching libbluray's auto-selected main title
# against the title HandBrake's own scan already selected, when deciding
# whether the fast stream-copy extraction path is safe to trust -- see
# try_fast_stream_copy_disc_extraction()'s comment.
DISC_STREAM_COPY_DURATION_TOLERANCE_SECONDS=5
# Bound on stage_disc_source_local()'s cp -a of the raw disc source to
# local scratch, before the fast stream-copy path reads it via libbluray.
# 3 hours: a 50GB disc needs ~14MB/s sustained to finish in 1 hour --
# comfortable on healthy gigabit LAN/SMB but a real false-fail risk on a
# congested/VPN/slow-Wi-Fi link (team review, 2026-08-04, all three
# reviewers independently flagged the original 3600s as too tight).
# Timing out here falls back to the ORIGINAL x264 -q 0 path (the thing
# this whole feature exists to avoid), so a too-tight bound can quietly
# defeat the fix without being unsafe -- bounded generously rather than
# tightly, matching this project's established preference elsewhere
# (see DISC_EXTRACT_SPACE_MULTIPLIER's own comment for the same
# reasoning applied to space instead of time).
DISC_LOCAL_COPY_TIMEOUT_SECONDS=10800
# Torn down by ramdisk_job_teardown (composed into that same EXIT trap
# rather than installing a second one, which would silently clobber it --
# see resume_init_paths's comment on this exact gotcha).
DISC_EXTRACT_SCRATCH_FILE=""
DISC_EXTRACT_SYMLINK_PATH=""
# When source height < 720 (1080p upscale path), allow more growth vs source before reject.
# Tiered by original file size: a fixed container/audio/metadata overhead dominates a small
# file's overshoot percentage far more than a large one, so smaller sources get more headroom.
UPSCALE_OVERSHOOT_SMALL_MAX_MB="${CONVERT_UPSCALE_OVERSHOOT_SMALL_MAX_MB:-120}"
UPSCALE_OVERSHOOT_SMALL_PCT="${CONVERT_UPSCALE_OVERSHOOT_SMALL_PCT:-100}"
UPSCALE_OVERSHOOT_MED_MAX_MB="${CONVERT_UPSCALE_OVERSHOOT_MED_MAX_MB:-1200}"
UPSCALE_OVERSHOOT_MED_PCT="${CONVERT_UPSCALE_OVERSHOOT_MED_PCT:-65}"
UPSCALE_MAX_OVERSHOOT_PCT="${CONVERT_UPSCALE_MAX_OVERSHOOT_PCT:-50}"
# Already-encoded-source size routing: a small file is already efficient
# enough that a sample-test isn't worth the time -- skip straight to tagging
# it "Preexisting Desired Format". Same short-circuit logic for both codecs,
# different thresholds (x265 is generally less space-efficient than AV1 at
# comparable quality, so a file needs to be LARGER before x265 counts as
# "already small enough" -- the x265 threshold sits higher than AV1's, not
# lower; team review 2026-07-24 caught this comment saying the opposite).
# Above their threshold, both get sample-tested (existing process_existing_av1
# for AV1; process_existing_x265 for x265, which was never previously
# reconsidered at all once converted, regardless of size).
PREEXISTING_SMALL_SKIP_MAX_MB="${CONVERT_PREEXISTING_SMALL_SKIP_MAX_MB:-50}"
PREEXISTING_X265_SMALL_SKIP_MAX_MB="${CONVERT_PREEXISTING_X265_SMALL_SKIP_MAX_MB:-80}"
# RAM-backed output staging: encode writes to a tmpfs/ramdisk (avoids the
# active encode ever touching the NFS write path -- reads tolerate network
# blips fine via retry, but a stalled/interrupted write on a `hard` NFS mount
# can block the whole encode), then the finished file is moved to the real
# destination as one sequential transfer. Only applies when no suitable
# ramdisk/tmpfs is discovered already.
#
# Two-tier sizing (2026-08-20, replaces a flat 60%-of-available formula):
# a real PRINCE production crash (SvtMalloc[fatal]: allocate memory failed,
# 4K/10-bit "Happiness for Beginners") traced to the encoder's own internal
# picture-buffer pool (~7.6GB just for SVT-AV1's picture buffers at that
# resolution/GOP config, before any other internal structures) competing
# with a ramdisk that had already claimed 60% of available memory before
# the encoder even started. Below CONVERT_RAMDISK_TIER_THRESHOLD_GB
# available memory, a flat CONVERT_RAMDISK_CAP_SMALL_GB cap leaves
# generous, predictable headroom for the encoder regardless of ramdisk
# math (explicit user direction: most fleet machines have 64GB+, a 12GB
# cap on a ~32GB machine leaves ~20GB); at or above the threshold,
# CONVERT_RAMDISK_PCT_LARGE% of available is used instead, since a
# large-RAM machine has enough headroom either way and a flat cap there
# would waste real staging capacity for no benefit. Percentage/cap are of
# *available* (free) memory at the moment a ramdisk needs to be created,
# never total installed RAM.
CONVERT_RAMDISK_TIER_THRESHOLD_GB="${CONVERT_RAMDISK_TIER_THRESHOLD_GB:-64}"
CONVERT_RAMDISK_PCT_LARGE="${CONVERT_RAMDISK_PCT_LARGE:-45}"
CONVERT_RAMDISK_CAP_SMALL_GB="${CONVERT_RAMDISK_CAP_SMALL_GB:-12}"
# Opt-out-by-hardware-class gate (2026-08-21, explicit user direction,
# separate from the sizing tier above): whether a ramdisk is used AT ALL
# for this machine, keyed off currently AVAILABLE (free) RAM -- same
# basis _mem_available_bytes() already uses for sizing, not total
# installed RAM. Below this, every job on this machine falls straight
# through to the existing local-disk staging fallback (same
# write-back-to-NAS-on-completion, same local-only logs) instead of ever
# attempting a ramdisk -- see ramdisk_job_start()'s own comment in
# ves-ramdisk.sh for the full incident writeup (a real access-violation
# crash on PRINCE, root-caused to ramdisk staging itself, plus a separate
# ENOSPC failure on ELVIS) that motivated this. Set to 0 to allow ramdisk
# staging on every machine regardless of free RAM.
CONVERT_RAMDISK_MIN_AVAIL_GB="${CONVERT_RAMDISK_MIN_AVAIL_GB:-59}"
CONVERT_NO_RAMDISK="${CONVERT_NO_RAMDISK:-false}"
CONVERT_RAMDISK_DIR="${CONVERT_RAMDISK_DIR:-}"
RAMDISK_SIZE_ESTIMATE_MARGIN_PCT=10
# Set once per run by ramdisk_job_start(), read by every file's
# resolve_encode_stage_path() -- not re-resolved per file, so a run that
# encodes many titles reuses one ramdisk instead of leaking a new one per
# file (macOS RAM disks in particular are real resources that must be
# explicitly ejected, not just abandoned).
RAMDISK_JOB_DIR=""
RAMDISK_JOB_OWNED=false
# Private mktemp -d (mode 700) subdirectory of RAMDISK_JOB_DIR that every
# per-file staged path actually lives in -- never write staged files
# directly in RAMDISK_JOB_DIR itself, which in the discovered case (e.g.
# /tmp) is a shared, world-writable location where a predictable filename
# could be pre-planted as a symlink by another local user/process.
RAMDISK_JOB_STAGE_DIR=""
# Tracks the currently-open private per-file staging dir from
# _local_stage_dir_for (the local, non-ramdisk fallback) so a SIGINT/SIGTERM
# mid-encode can still clean it up -- see resume_on_signal. The ramdisk case
# doesn't need this: RAMDISK_JOB_STAGE_DIR is a single job-scoped dir already
# torn down as a whole by ramdisk_job_teardown's EXIT trap.
ACTIVE_LOCAL_STAGE_DIR=""
# Same idea for finalize_staged_encode_output's private .convert-finalize-*
# copy dir -- an INT/TERM or set -e abort mid-copy needs somewhere other
# than that function's own local variable to find it and clean it up.
ACTIVE_FINALIZE_DIR=""
# Same idea for optimize_mkv_for_streaming's private .convert-streamopt-*
# remux dir -- team review (2026-07-24) found it was tracked only in a
# local variable, so an INT/TERM mid-remux left it behind permanently.
ACTIVE_STREAMOPT_DIR=""
# Stage-1 ffmpeg software encodes now write video+audio only, then the
# final MKV is assembled in a cheap stream-copy remux that adds source
# subtitles/attachments. Track the intermediate explicitly so the existing
# EXIT/signal/error cleanup paths can remove it without installing another
# raw EXIT trap.
ACTIVE_FFMPEG_STAGE1_FILE=""
# NVENC device indices (as seen by `nvidia-smi -L` / CUDA_VISIBLE_DEVICES) --
# override per-machine when a box has multiple GPUs with different NVENC
# capabilities. Not every NVENC generation supports AV1 hardware encode
# (e.g. Ampere-generation cards have HEVC/H.264 NVENC but no AV1 encoder
# block at all -- confirmed via a direct av1_nvenc probe, not a driver/config
# issue), so GPU_AV1 in particular may need to stay pinned to a specific
# card even when a second GPU is present and otherwise idle.
GPU_AV1="${CONVERT_GPU_AV1:-0}"
GPU_HEVC_PRIMARY="${CONVERT_GPU_HEVC_PRIMARY:-0}"
GPU_HEVC_FALLBACK="${CONVERT_GPU_HEVC_FALLBACK:-1}"
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
# mkvalidator (v0.6.0) parses the EBML tree with very small sequential reads
# (~700 bytes/syscall observed) -- fine for typical TV-episode-sized files but
# directly measured at ~340s/GiB on a real 20.15GiB movie (~114 minutes total,
# 2026-07-27) -- worse per-GiB than a smaller 2.59GiB file's ~260s/GiB, so the
# cost isn't flat and keeps climbing past this size.
# Skip full mkvalidator above this size and fall back to the fast EBML-bounds
# check (same as when the binary isn't installed at all) rather than stall.
# Raised from 2GiB to 10GiB (2026-07-27, same day as the 2GiB cut): a full
# library scan (16,615 real movie files) showed 2GiB excluded roughly HALF
# of all movies (49.6% exceed 2GB) -- far too small a ceiling for real
# content, where the distribution is Movies/TV/Anime routinely running
# 3-10GB and a genuine long tail up to ~69GB. 10GiB covers 94.8% of the
# scanned library with full mkvalidator coverage. Directly measured a real
# 20.15GiB file's healthy full scan at ~114 minutes (~340s/GiB, worse than
# the ~260s/GiB seen on a 2.59GiB file -- the per-GiB cost isn't flat, it
# gets worse at scale) -- confirms 10GiB is near the practical ceiling for
# "reasonable single-attempt validation time" (~60 min) before the
# remaining 5.2% of files fall back to the fast EBML-bounds check (still
# catches truncation, the dominant real-world failure mode) rather than
# spending 1.5-2+ hours validating one file. See _validation_timeout_for_args
# and VALIDATION_TIMEOUT_RETRIES for the complementary timeout-side fix.
MKVALIDATOR_MAX_SIZE_BYTES="${CONVERT_MKVALIDATOR_MAX_SIZE:-10737418240}"  # 10 GiB
# Bound for validation-path subprocesses (ffprobe/mkvmerge/mkvalidator/EBML).
# Overridable like CONVERT_MKVALIDATOR_MAX_SIZE. Orphan gates keep their own
# shorter ORPHAN_* timeouts when calling tools directly via run_with_timeout.
VALIDATION_TIMEOUT_SECS="${VALIDATION_TIMEOUT_SECS:-120}"
MKV_STRUCTURE_CACHE_FILE=""
CORRUPT_FILES_LOG=""
BAD_SOURCES_LOG=""
RECONVERT_FILES_LOG=""
STRIPPED_SUBTITLES_LOG=""
LOW_QUALITY_LOG=""
# A kept, valid output whose final measured VMAF still lands below this floor
# (e.g. a must-eliminate legacy source too far gone for a clean re-encode)
# gets logged to LOW_QUALITY_LOG and marked in its tag for human review/manual
# reconvert, rather than being silently treated as a normal successful pass.
LOW_QUALITY_VMAF_THRESHOLD="85.00"
# Set by validate_mkv_structure when quick scan defers full mkvalidator (do not delete yet).
MKV_VALIDATE_DEFERRED=false
# Set by validate_mkv_metadata / validate_mkv_structure / validate_mkv_output when a
# probe times out (rc 124). Callers must leave the output in place and retry next
# run — never fold timeout into corrupt-delete / reconvert logging.
MKV_VALIDATE_TIMED_OUT=false
MKV_VALIDATE_FAILURE_REASON=""
# Set by validate_source_media when it returns 1 because of a stalled-mount
# timeout (ffprobe/EBML/mkvalidator/audio/subtitle check) rather than a
# genuine, durable bad-source verdict (flag_bad_source_for_human already
# handles those permanently -- moved to Deferred/, nothing to retry).
# process_video checks this to propagate a real job failure only for the
# timeout case (team review, 2026-07-25): before this, ANY validate_source_media
# failure -- transient or permanent -- was folded into `return 0`, so an NFS
# stall during source validation silently logged as "Job complete" and got
# wrongly marked `completed` in the resume state, exactly the same class of
# bug the v5.0.32T process_video() fix addressed for the encode/validation
# path, just one step earlier in the same function.
SOURCE_VALIDATE_TIMED_OUT=false
# Set by audio_track_reaches_near_eof when its ffprobe probe times out (rc 124).
# Same reasoning as MKV_VALIDATE_TIMED_OUT: a stalled-mount timeout must never
# be folded into a genuine audio_truncated / bad-source classification.
AUDIO_TRACK_CHECK_TIMED_OUT=false
# Same as AUDIO_TRACK_CHECK_TIMED_OUT, for validate_mkv_subtitle_tracks's probe.
SUBTITLE_CHECK_TIMED_OUT=false
PACKAGE_MANAGER=""
CHECK_TOOLS_ONLY=false
CLEAN_JUNK=false
CLEAN_JUNK_APPLY=false
# Phase B: startup orphan reaper (default on; --no-auto-reap to skip)
AUTO_REAP=true
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
SVT_AV1_CQ_ANIME=26
NVENC_AV1_CQ_ANIME=30
# TV shows get their own named profile (distinct from theatrical movies) so
# they're independently tunable, but start numerically identical to movie —
# no empirical basis yet to diverge, unlike anime's flat-color content which
# has an established rationale for its own values.
SVT_AV1_CQ_TV=26
NVENC_AV1_CQ_TV=24
# Western animation (South Park, Rick and Morty, flat/vector digital ink-
# and-paint) is NOT the same content as Japanese hand-drawn anime -- real
# fleet testing found the anime profile's film-grain/variance-boost tuning
# actively hurt compression on this content (a real episode came out LARGER
# than the source). --profile wanime is a distinct, manually-selected
# profile (never auto-detected -- this content has no reliable folder-name
# convention, it lives mixed inside regular /Television/ folders). Starts
# numerically identical to movie/tv; the real fix is in its own SVT-AV1
# param string (film-grain disabled), not these CQ fallback constants.
SVT_AV1_CQ_WANIME=26
NVENC_AV1_CQ_WANIME=24
# Vintage: old/grainy live-action masters (film scans, older TV masters with
# real photochemical grain) -- --profile vintage, manual-only (never auto-
# detected; "old/grainy" isn't reliably inferable from a folder path the way
# tv/anime paths are). Real grain synthesis is deliberately reintroduced here
# (movie/tv/wanime all keep film-grain off) to spend bits reproducing texture
# instead of literally re-encoding grain as detail. Starts numerically
# identical to movie/tv; the real content-type differentiator is again in the
# SVT-AV1/x265 param string, not these CQ fallback constants.
SVT_AV1_CQ_VINTAGE=24
NVENC_AV1_CQ_VINTAGE=24

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
VMAF_TARGET_MOVIE="${CONVERT_VMAF_TARGET:-94.0}"  # 1080p SDR movies (NEG model; ~= default-model 95.5)
VMAF_TARGET_ANIME="${CONVERT_VMAF_TARGET_ANIME:-94.0}"
# Classic anime (<=1997, see CLASSIC_ANIME_YEAR_CUTOFF) targets a couple
# points higher -- VMAF alone under-penalizes soft line art, so the CRF
# search is biased toward more bits than the modern-anime target.
VMAF_TARGET_CANIME="${CONVERT_VMAF_TARGET_CANIME:-95.0}"
VMAF_TARGET_CLASSIC="${CONVERT_VMAF_TARGET_CLASSIC:-94.0}"
VMAF_TARGET_VINTAGE="${CONVERT_VMAF_TARGET_VINTAGE:-94.0}"
VMAF_TARGET_WANIME="${CONVERT_VMAF_TARGET_WANIME:-94.0}"
VMAF_TARGET_MTV="${CONVERT_VMAF_TARGET_MTV:-94.0}"
VMAF_TARGET_VTV="${CONVERT_VMAF_TARGET_VTV:-94.0}"
VMAF_TARGET_4K="${CONVERT_VMAF_TARGET_4K:-95.0}"  # scored with the 4K model
VMAF_SAMPLES="${CONVERT_VMAF_SAMPLES:-3}"
VMAF_SAMPLE_SECS="${CONVERT_VMAF_SAMPLE_SECS:-20}"
# Task #172: per-sample-window local search radius (in whole frames) for the
# src/out seek-alignment fix in ves-vmaf-crf-search.sh's _vmaf_compare_window.
# A real sweep test (2026-08-17, PRINCE, Falling Skies) showed the true best
# alignment is a sharp single peak that can sit anywhere within a few frames
# of the nominal timestamp -- not a fixed measured offset -- so the fix
# searches -N..+N frame-durations and keeps whichever scores highest. 3 was
# chosen as a safety margin around the widest real misalignment observed (~1
# frame); raise if a future case needs more.
VMAF_ALIGN_SEARCH_FRAMES="${CONVERT_VMAF_ALIGN_SEARCH_FRAMES:-3}"
VMAF_SEARCH_MIN_CRF=16
VMAF_SEARCH_MAX_CRF=46
VMAF_DISABLED=false                               # --no-vmaf
PREFER_HW_ENCODE=false                            # --prefer-hw (speed over size)
# Fixed CRFs used when VMAF search is unavailable/disabled, and always for HDR:
FIXED_CRF_SVT_MOVIE=26
FIXED_CRF_SVT_ANIME=26
FIXED_CRF_SVT_CANIME=24
FIXED_CRF_SVT_CLASSIC=25
FIXED_CRF_SVT_WANIME=26
FIXED_CRF_SVT_VINTAGE=24
FIXED_CRF_SVT_MTV=26
FIXED_CRF_SVT_VTV=25
FIXED_CRF_SVT_HDR=24
FIXED_CRF_X265_MOVIE=20
FIXED_CRF_X265_ANIME=22
FIXED_CRF_X265_CANIME=20
FIXED_CRF_X265_CLASSIC=20
FIXED_CRF_X265_WANIME=20
FIXED_CRF_X265_VINTAGE=20
FIXED_CRF_X265_MTV=20
FIXED_CRF_X265_VTV=21
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
declare -A UPSCALE_TARGET_CACHE=()
UPSCALE_TARGET_HEIGHT=0
declare -A SOURCE_TRAITS_CACHE=()  # $src -> "field_mode=<progressive|telecine|interlaced|ambiguous>;is_bw=<0|1>;field_order=<tff|bff>;frame_rate_mode=<cfr|vfr|unknown>;baseline_vmaf=<N.N>"
NO_AUTO_DETELECINE=false           # --no-auto-detelecine: detect+log only, never insert IVTC/deinterlace filter
NO_BW_TUNING=false                 # --no-bw-tuning: detect+log only, never relax CRF/VMAF target for B&W sources
REPORT_SOURCE_TRAITS=false         # --report-source-traits: Phase 1 validation mode, detect+log across the queue, no encoding

# Source-traits classification thresholds. Tunable without touching
# detect_source_traits() itself. See project plan
# ~/.claude/plans/how-can-we-chaneg-cheeky-goose.md -- these encode the
# 3-tier field-mode classification (progressive/telecine/interlaced) plus
# the ambiguity guard (window-to-window disagreement forces "ambiguous"
# rather than trusting a noisy average), and the B&W saturation floor.
SOURCE_TRAITS_PROBE_WIDTH_SECS=10
SOURCE_TRAITS_PROGRESSIVE_MIN=0.95     # avg progressive-frame ratio >= this -> progressive, no filter
SOURCE_TRAITS_TELECINE_REPEAT_MIN=0.12 # avg repeated-field ratio in [MIN,MAX] -> telecine cadence (IVTC)
SOURCE_TRAITS_TELECINE_REPEAT_MAX=0.30
SOURCE_TRAITS_INTERLACE_MIN=0.10       # avg interlaced-frame ratio >= this (repeat ratio out of telecine band) -> interlaced (deinterlace)
SOURCE_TRAITS_WINDOW_SPREAD_MAX=0.25   # max-min progressive ratio across sample windows above this -> ambiguous, never guess
SOURCE_TRAITS_BW_SATAVG_MAX=4.0        # avg signalstats SATAVG at/below this -> classified black-and-white

# Source frame-rate mode (CFR/VFR) + baseline self-VMAF. Added 2026-08-13
# after the VMAF-VFR false-positive bug (v5.1.0S/T): that bug was only
# ever caught reactively, by noticing a suspiciously low encode-vs-source
# score after the fact. These two checks run proactively, once per source,
# so a source with unreliable measurement characteristics is flagged
# BEFORE any encode-vs-source comparison is ever trusted for it.
# SOURCE_TRAITS_VFR_CV_MAX is deliberately untuned (same caveat as the
# field-mode thresholds above) -- calibrate against real confirmed-CFR and
# confirmed-VFR sources before relying on it for anything beyond logging.
SOURCE_TRAITS_VFR_CV_MAX=0.05          # packet dts-delta coefficient of variation at/below this -> CFR, above -> VFR
SOURCE_BASELINE_VMAF_MIN=97.0          # self-vs-self VMAF below this -> measurement methodology unreliable for this source, flag for human review

# OUTPUT_DUPLICATE_FRAME_CV_MAX (2026-08-16, detect_output_frame_duplication()):
# same CV technique as SOURCE_TRAITS_VFR_CV_MAX above, but applied to a
# FINISHED OUTPUT rather than a source, and only ever invoked once VMAF has
# already come back below LOW_QUALITY_VMAF_THRESHOLD (a diagnostic, not an
# independent gate). Set with wide margin, not a tuned boundary: clean
# encodes measured avg_cv 0.01-0.05 (same ballpark as a clean source); the
# confirmed-defective 38-file backlog that motivated this check all
# measured avg_cv 0.5-0.8+ on the identical technique.
OUTPUT_DUPLICATE_FRAME_CV_MAX=0.15

# Phase F resolved constants. These complete strings are shared by sample
# search and final encode so profile tuning cannot drift (the v5.0.29 lesson).
SVT_PARAMS_WANIME='enable-qm=1:qm-min=0:keyint=15s:scd=1:aq-mode=2:sharpness=2'
SVT_PARAMS_ANIME='enable-qm=1:film-grain-denoise=1:film-grain=6:qm-min=0:scd=1:enable-tf=0:keyint=15s:aq-mode=2:enable-variance-boost=1:variance-boost-strength=3:variance-octile=4:enable-overlays=1:tune=0:sharpness=2'
# Classic/heavily-lined anime (<=1997 -- see CLASSIC_ANIME_YEAR_CUTOFF): a
# line-art preservation problem, not a photochemical-grain problem (team
# review + user confirmation, 2026-07-20). No film-grain-denoise/film-grain
# at all -- pre-1998 cel paint is flat, hard-segmented color blocks with no
# soft gradients to band, so grain synthesis only adds unwanted texture over
# clean fills without buying any real anti-banding protection; aq-mode=2 +
# qm-min=0 + 10-bit already cover that. No tune=0 (the v5.0.4 lesson that
# tune=0 caused visible softness elsewhere in the script was never applied
# to the anime profile -- this fixes that for the classic split). Lower
# variance-boost-strength than modern anime (high variance-boost starves
# flat regions of bits, the opposite of what hard-edged flat cel color needs).
SVT_PARAMS_CANIME='enable-qm=1:qm-min=0:scd=1:enable-tf=0:keyint=15s:aq-mode=2:enable-variance-boost=1:variance-boost-strength=1:variance-octile=4:enable-overlays=1:sharpness=3'
SVT_PARAMS_MOVIES='enable-qm=1:qm-min=0:keyint=15s:scd=1:aq-mode=2'
SVT_PARAMS_CLASSIC='enable-qm=1:film-grain-denoise=1:film-grain=6:qm-min=0:scd=1:enable-tf=1:keyint=15s:aq-mode=2:enable-variance-boost=1:variance-boost-strength=1:variance-octile=4:sharpness=1'
SVT_PARAMS_VINTAGE='enable-qm=1:film-grain-denoise=1:film-grain=12:qm-min=0:scd=1:enable-tf=1:keyint=15s:aq-mode=2:enable-variance-boost=1:variance-boost-strength=2:variance-octile=4:sharpness=1'
SVT_PARAMS_MTV="$SVT_PARAMS_MOVIES"
SVT_PARAMS_VTV='enable-qm=1:film-grain-denoise=1:film-grain=5:qm-min=0:scd=1:enable-tf=1:keyint=15s:aq-mode=2:enable-variance-boost=1:variance-boost-strength=2:variance-octile=4:sharpness=1'
# NOTE: `tune=` is deliberately NOT embedded in these x265-params strings.
# Found 2026-07-29: x265's own param parser (x265_param_parse(), what
# ffmpeg's -x265-params/-enc x265-params= and HandBrake's --encopts all
# call) does not accept "tune" as a settable key -- tune is a whole-preset
# convenience applied by a DIFFERENT function (x265_param_default_preset())
# that none of these interfaces invoke. Every encode that set tune=animation/
# tune=grain this way printed "Unknown option: tune." and silently got NO
# tuning applied at all, fleet-wide, for as long as this script has existed
# (confirmed: reproduced identically on every machine tested, not a
# fleet-version-divergence issue). The real fix is profile_x265_tune()
# below, passed via each interface's own dedicated tune flag (ffmpeg's
# -tune, HandBrake's --encoder-tune, ab-av1's --enc tune=...).
X265_PARAMS_WANIME='log-level=error:keyint=240:min-keyint=24:bframes=8:ref=4:rc-lookahead=30:aq-mode=2:psy-rd=1.0:psy-rdoq=0.8'
X265_PARAMS_ANIME='log-level=error:keyint=240:min-keyint=24:bframes=8:ref=4:rc-lookahead=30:aq-mode=2:psy-rd=1.5:psy-rdoq=0.8'
# Classic anime x265 fallback: same animation tune, but higher psy-rd (line
# with MOVIES/CLASSIC's live-action psy-rd=2.0) to spend more bits retaining
# fine hand-inked line detail instead of the softer modern-anime default.
X265_PARAMS_CANIME='log-level=error:keyint=240:min-keyint=24:bframes=8:ref=4:rc-lookahead=30:aq-mode=2:psy-rd=2.0:psy-rdoq=1.0'
X265_PARAMS_MOVIES='log-level=error:keyint=240:min-keyint=24:bframes=8:ref=5:rc-lookahead=40:aq-mode=3:psy-rd=2.0:psy-rdoq=1.0:deblock=-1,-1'
X265_PARAMS_CLASSIC='log-level=error:keyint=240:min-keyint=24:bframes=8:ref=5:rc-lookahead=40:aq-mode=3:psy-rd=2.0:psy-rdoq=1.5:deblock=-1,-1'
X265_PARAMS_VINTAGE='log-level=error:keyint=240:min-keyint=24:bframes=6:ref=4:rc-lookahead=30'
X265_PARAMS_MTV="$X265_PARAMS_MOVIES"
X265_PARAMS_VTV='log-level=error:keyint=240:min-keyint=24:bframes=8:b-adapt=2:ref=5:rc-lookahead=50:aq-mode=3:no-sao=1:psy-rd=1.5:psy-rdoq=1.0'

NVENC_AV1_TUNE=hq
AUDIO_DRC=2.0
AUDIO_GAIN=1.0
JOB_ROOT=""
JOB_ROOT_WRITABLE=false
JOB_SIDECAR_DIR=""
MASTER_LOG_FILE=""
SHARD_LOG_FILE=""
# File descriptors opened once, at path-resolution time, rather than
# reopening the log path by name on every single write. An external review
# found that repeatedly reopening a predictable log path (`printf ... >>
# "$MASTER_LOG_FILE"`) leaves a standing window for another writer to swap
# that path for a symlink between any two writes -- once opened, a file
# descriptor refers to the underlying inode directly and is immune to the
# path later being replaced, so this closes the window for the entire
# lifetime of the log after the one initial (symlink-checked) open.
MASTER_LOG_FD=""
CORRUPT_FILES_LOG_FD=""
BAD_SOURCES_LOG_FD=""
RECONVERT_FILES_LOG_FD=""
STRIPPED_SUBTITLES_LOG_FD=""
LOW_QUALITY_LOG_FD=""
SHARD_LOG_FD=""
SHARD_LOG_ROOT=""
SHARD_LOG_ACTIVE=false
STATS_LOG_FILE=""
STATS_OUTPUT_BYTES=0
STATS_SAVED_BYTES=0
STATS_PROCESSED=0
STATS_SKIPPED=0
STATS_INSPECTED=0
# Season-level shrink-vs-predicted-no-shrink heuristic: within a single
# whole-folder/batch run, if this percentage or more of a season's sample-
# tested episodes actually shrank, the remaining episodes the sample test
# predicted wouldn't shrink get one real forced-encode retry instead of
# trusting that prediction -- same-season episodes are similar enough in
# content that sibling results are a better predictor than the 3-point sample
# alone. Scoped per (show folder, season number) pair, not season number
# alone -- a show folder can hold multiple seasons with very different
# compressibility, and a bare season number would also wrongly pool unrelated
# shows' "S01" episodes together on a whole-library run. Only engages for a
# whole-folder/batch run -- a single-file target has no season peers to
# compare against.
SEASON_RETRY_THRESHOLD_PCT="${CONVERT_SEASON_RETRY_THRESHOLD_PCT:-60}"
if ! [[ "$SEASON_RETRY_THRESHOLD_PCT" =~ ^[0-9]+$ ]] || [ "$SEASON_RETRY_THRESHOLD_PCT" -gt 100 ]; then
  SEASON_RETRY_THRESHOLD_PCT=60
fi
declare -A SEASON_SAMPLE_TESTED_COUNT=()
declare -A SEASON_SHRINK_COUNT=()
declare -A SEASON_NO_SHRINK_FILES=()
# Set true only while season_retry_pass's own forced-encode retries are
# running -- record_skip/record_conversion_result must not feed a retried
# file's outcome back into these same counters a second time (the file was
# already counted once, at its original sample-skip).
SEASON_RETRY_IN_PROGRESS=false
# Set true only around the av1/x265 case branches inside process_existing_av1
# and process_existing_x265 -- i.e. only while a result is actually the
# outcome of THIS sample-test decision. Without this, record_conversion_result
# would also count fresh (never-AV1/x265) first-time conversions, disc-source
# encodes, and plain container remuxes toward the season ratio, none of which
# went through the sample-test this heuristic is meant to second-guess.
SEASON_SAMPLE_DECISION_CONTEXT=false
CONVERT_JOB_INDEX=0
CONVERT_JOB_TOTAL=0
CONVERT_JOB_OK=true
CONVERT_JOB_START_EPOCH=0
CONVERT_JOB_SRC_DURATION=0
CONVERT_BATCH_ENCODE_SECONDS=0
# Telegram job-completion notifications -- opt-in via environment variables
# only (never a CLI flag, same reasoning as CONVERT_SMB_USER/PASSWORD: a
# flag value is visible to any local user via `ps aux`, an env var isn't).
# Silently disabled (no-op) if either is unset -- notifications are
# best-effort and never load-bearing for the actual encode.
TELEGRAM_BOT_TOKEN="${CONVERT_TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${CONVERT_TELEGRAM_CHAT_ID:-}"
TELEGRAM_HOST_TAG="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
CONVERT_SCAN_COUNT=0
CONVERT_READY_FILE=""
CONVERT_SCAN_DONE_FILE=""
CONVERT_SCAN_TOTAL_FILE=""
CONVERT_SCAN_PID=0
ACTIVE_ENCODER_PID=0
ACTIVE_ENCODER_LABEL=""
ACTIVE_ENCODER_FINGERPRINT=""
ACTIVE_ENCODER_STARTED_UTC=""
ACTIVE_ENCODER_FIFO_DIR=""
# PID of run_tracked_encoder's periodic in-progress-flag heartbeat subshell,
# if one is currently running (0 = none). A global (not a local inside
# run_tracked_encoder) so kill_active_encoder -- called from the SIGINT/
# SIGTERM trap handler, a different function entirely -- can also kill it
# immediately instead of leaving it to self-terminate on its own next
# sleep-wake (bounded to <=300s, but a real gap; found 2026-08-04).
ACTIVE_ENCODER_HEARTBEAT_PID=0
CONVERT_READY_OFFSET=0
CONVERT_READY_FD=""
CONVERT_READY_WRITE_FD=""
RESUME_QUEUE_WRITE_FD=""
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
