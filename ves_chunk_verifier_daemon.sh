#!/usr/bin/env bash
# ves_chunk_verifier_daemon.sh -- Phase 4 of the chunk-parallel initiative:
# the missing runner around modules/ves-chunk-verify.sh's
# chunk_verifier_scan_once(). That module's own header names this the one
# piece "not yet built as of this writing (deliberately: needs its own live
# validation pass, Phase 4, before being left running unattended against
# production data)" -- this script + its validation pass (see the D-val
# production-bridge plan) is that Phase 4.
#
# One-shot per invocation, flock-guarded -- matches this codebase's own
# established convention for every other periodic fleet task
# (dval_local_supervisor.sh, dval_watchdog.sh: cron-scheduled, one tick,
# guarded by a lock) rather than a free-standing `while true` daemon that
# would then need its own separate liveness supervision. Intended cron:
#   * * * * *  ves_chunk_verifier_daemon.sh >> logs/chunk-verifier.log 2>&1
#
# Designed to run on STING specifically (NAS-local, so concatenation is a
# local stream-copy rather than a network transfer -- see ves-chunk-
# verify.sh's own header and the real 4-machine bake-off that settled
# this), but nothing here is Sting-specific code; runs anywhere with
# ffmpeg/mkvmerge and NAS access to the library.
set -u

_SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
_SCRIPT_DIR="$(cd -- "$(dirname -- "$_SCRIPT_PATH")" >/dev/null 2>&1 && pwd -P)"
_MODULES_DIR="${VES_MODULES_DIR:-${_SCRIPT_DIR}/modules}"

# Same fail-loud pattern as convert-v6.0.0D.sh's own module load (team
# review 2026-08-04): a missing modules/ dir must not silently continue
# with every chunk_* function undefined, only to crash confusingly deep
# into a scan pass.
if [ ! -f "${_MODULES_DIR}/ves-config.sh" ]; then
  echo "[chunk-verifier] FATAL: modules/ves-config.sh not found under ${_MODULES_DIR}" >&2
  echo "[chunk-verifier] This script requires the full modules/ tree alongside it (or VES_MODULES_DIR set)." >&2
  exit 1
fi
# shellcheck source=modules/ves-config.sh
source "${_MODULES_DIR}/ves-config.sh"
for _m in "${_MODULES_DIR}"/ves-*.sh; do
  [ -e "$_m" ] || continue
  [ "$(basename -- "$_m")" = "ves-config.sh" ] && continue
  # shellcheck source=/dev/null
  source "$_m"
done
unset _m

declare -F chunk_verifier_scan_once >/dev/null 2>&1 || {
  echo "[chunk-verifier] FATAL: chunk_verifier_scan_once not defined after sourcing modules/ -- ves-chunk-verify.sh missing or failed to load" >&2
  exit 1
}

# v6.0.7 stability review (2026-09-14): this daemon never called
# discover_tools() -- FFMPEG_CMD/FFPROBE_CMD/MKVMERGE_CMD are declared as
# empty arrays by ves-config.sh and populated ONLY inside discover_tools()
# (confirmed: grep shows no other assignment site in the whole modules/
# tree). Without it, `"${FFMPEG_CMD[@]}"` in _chunk_output_decodes_clean()
# actually executed `-v error -i ...` as a bogus command name -- every
# chunk output would have failed its decode-clean check, every finalize
# would have failed its mkvmerge/VMAF step, and no manifest could ever
# reach verified/.finalized through this daemon. Never caught earlier
# because no real multi-chunk title has gone through it yet (chunking only
# triggers above CONVERT_CHUNK_MIN_DURATION_SECS, default 3600s).
# discover_tools()'s own overall return code is all-or-nothing across the
# FULL production toolset (ffmpeg/ffprobe/HandBrakeCLI/mkvpropedit/mkvmerge/
# python3) -- confirmed live on STING: HandBrakeCLI is not installed there
# (an I/O-tier host, never an encode host) and its absence alone makes
# discover_tools() return 1, even though it still correctly populates
# FFMPEG_CMD/FFPROBE_CMD/MKVMERGE_CMD/MKVPROPEDIT_CMD (each tool's array is
# set independently before the overall `failed` flag is computed). Only
# those four are actually used by _chunk_output_decodes_clean/run_mkvmerge/
# measure_final_vmaf_sequential -- check them directly rather than trusting
# discover_tools()'s own exit code, so a HandBrake-less verify-only host
# isn't wrongly refused.
discover_tools >/dev/null 2>&1
if [ "${#FFMPEG_CMD[@]}" -eq 0 ] || [ "${#FFPROBE_CMD[@]}" -eq 0 ] || [ "${#MKVMERGE_CMD[@]}" -eq 0 ]; then
  echo "[chunk-verifier] FATAL: ffmpeg/ffprobe/mkvmerge not resolvable on this host after discover_tools (FFMPEG_CMD=${#FFMPEG_CMD[@]} FFPROBE_CMD=${#FFPROBE_CMD[@]} MKVMERGE_CMD=${#MKVMERGE_CMD[@]})" >&2
  exit 1
fi

# get_scan_roots() (ves-sharded-scan.sh) reads $SEARCH_PATH, which ves-
# config.sh defaults to "." (cwd) -- correct for convert-v6.0.0D.sh's own
# --path CLI arg, but this daemon has no such arg and would otherwise
# silently scan whatever directory cron happens to invoke it from (almost
# certainly not the media library) rather than failing loudly. Found before
# ever relying on it live, not discovered the hard way.
SEARCH_PATH="${VES_LIBRARY_ROOT:-/mnt/BigMomma/Media}"
if [ ! -d "$SEARCH_PATH" ]; then
  echo "[chunk-verifier] FATAL: library root not found: $SEARCH_PATH (set VES_LIBRARY_ROOT if this host mounts it elsewhere)" >&2
  exit 1
fi

# Singleton guard -- this daemon concatenates chunks and moves the result
# into the canonical output path; two instances racing the same manifest is
# exactly the class of bug this codebase has repeatedly had to retrofit a
# lock for elsewhere (dval_dispatch.sh, dval_kb_ingest.sh, dval_kb_refine.sh).
_LK="/tmp/ves_chunk_verifier_daemon.lock"
# NOT `2>/dev/null` on this bare `exec` -- found live 2026-09-13, confirmed
# with an isolated test: a bare `exec N>file 2>/dev/null` redirects the
# CURRENT SHELL's stderr permanently (exec with no command applies its
# redirects to the shell itself, not scoped to one command), silently
# swallowing every later `>&2` write for the rest of the script's life --
# a real, confirmed bug found this exact way in dval_dispatch.sh/dval_kb_
# ingest.sh's copy of this same pattern (fixed alongside this file). A rare
# failure to open the lock file (e.g. /tmp unwritable) is worth seeing, not
# suppressing -- `|| true` alone is enough to survive it under `set -e`.
exec 9>"$_LK" || true
flock -n 9 2>/dev/null || { echo "[chunk-verifier] $(date -u +%FT%TZ) another instance already running -- exit" >&2; exit 0; }

_t0=$(date +%s)
echo "[chunk-verifier] $(date -u +%FT%TZ) scan pass starting on $(hostname -s 2>/dev/null || hostname)"
# chunk_verifier_scan_once already isolates a single bad manifest internally
# (both chunk_verify_pending and chunk_finalize_manifest are called with
# `|| true` inside it) -- this outer guard is a second, redundant safety net
# for a failure outside that (e.g. get_scan_roots itself), not the primary
# isolation mechanism.
if ! chunk_verifier_scan_once; then
  echo "[chunk-verifier] $(date -u +%FT%TZ) scan pass returned non-zero -- a single bad manifest should not cause this; investigate get_scan_roots/environment" >&2
fi
_el=$(( $(date +%s) - _t0 ))
echo "[chunk-verifier] $(date -u +%FT%TZ) scan pass done (${_el}s)"

# v6.0.8 (2026-09-14 peer review finding #2, fixed same night): a NAS-
# visible heartbeat, not just STING's own local log -- so the coordinator
# (dval_watchdog.sh) can tell this daemon is alive without SSH. Originally
# an mtime-based empty-file touch (matching searchwalk.log/dispatch.log's
# own liveness convention) -- but THOSE are written and read by the SAME
# host (RANDYJ); this one is written by STING (direct-ZFS, real-time) and
# read by RANDYJ over an NFSv4 mount with `acregmax=1800` (confirmed live,
# 2026-09-14: a real ALERT fired minutes after a genuinely-fresh write,
# because RANDYJ's cached stat() of the file's mtime can lag the real
# server-side value by up to 30 minutes). A fresh read of the file's own
# DATA doesn't have the same staleness -- write the actual epoch as
# CONTENT and have the watchdog compare that, not the filesystem's mtime.
_HB_DIR="${DVAL_SHARED_DIR:-/mnt/BigMomma/Media/_dval-survey}/state"
mkdir -p "$_HB_DIR" 2>/dev/null
date +%s > "$_HB_DIR/chunk-verifier.heartbeat" 2>/dev/null || true
