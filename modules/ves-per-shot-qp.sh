#!/usr/bin/env bash
# ves-per-shot-qp.sh -- Phase 6 of the chunk-parallel + per-shot dynamic
# optimization initiative: real per-shot VMAF-target QP search, reusing
# ves-vmaf-crf-search.sh's proven bounded-bisection pattern
# (vmaf_crf_search_internal/_vmaf_score_one) at shot granularity instead
# of a handful of samples spread across a whole file.
#
# Depends on Phase 5 (ves-scene-detect.sh, scene_detect_boundaries()) for
# real shot boundaries, and on the standalone SvtAv1EncApp CLI's
# --qpfile/--use-q-file mechanism (confirmed live 2026-08-24 to work
# correctly -- a real ~3.3x bitrate difference between QP 10 and QP 50 on
# the same clip -- unlike ffmpeg's -svtav1-params passthrough, which
# silently ignores it; see docs/DESIGN-6x-chunk-redesign.md) for how the
# resolved per-shot QPs actually get applied: ONE continuous encode per
# work-unit, with a per-frame QP file built from these results, not a
# separate encoded file per shot. That was tested and compared directly
# against the alternative (independent per-shot files spliced via the
# Layer-1 seam mechanism) on a real 199-shot/809s episode: the seam
# approach broke catastrophically at this granularity (VMAF 2.26, vs
# 85.32 for the qpfile approach using the same per-shot QP values) --
# see the same design doc section for the full comparison.

# run_ffmpeg_validation's timeout curve (_validation_timeout_for_args) scales
# off the INPUT FILE'S SIZE, calibrated for fast structural validation and
# stream-copy work -- it has nothing to do with how long a real CPU-bound
# encode takes. A short shot clip is tiny on disk (a few MB) but a genuinely
# complex shot at preset 8 with film-grain synthesis enabled can still take
# several minutes to encode (SVT-AV1 itself warns film-grain>0 above preset 6
# has "significant compute overhead"), so the size-scaled timeout comes out
# far too short for the actual encode/VMAF-measurement steps below. Found
# live 2026-08-24: shot 22 of the Yama no Susume S02E12 test episode (5.88s,
# 1080p, heavy motion) took ~5 minutes to encode a single QP candidate on
# JJACKSON -- well past the ~121s the size-based curve computed for its
# ~6MB extracted clip -- so the encode got killed mid-run and the shot
# silently fell back to the static fixed-QP default, defeating the entire
# point of per-shot search for exactly the shots most likely to need it.
# Scales off the shot's own duration instead: real encode/VMAF cost tracks
# how much video there is, not how many bytes the (post-copy, pre-encode)
# clip happens to occupy.
# Overload should only cost TIME, never correctness -- a wall-clock timeout
# converts "slow" into "killed -> search_failed=1 -> silent fixed-QP
# fallback" the instant something takes too long, so anything that makes a
# probe run slower than expected quietly corrupts the search's own data
# instead of just taking longer. Found live 2026-09-04: the VMAF comparison
# below unconditionally asked libvmaf for n_threads=$(nproc) -- the WHOLE
# box's core count -- with no regard for how many SIBLING search workers on
# the SAME host are making the identical call at the same time (dval_research
# .sh's WORKERS[] map runs several per host by design) or for anything else
# sharing the box. 3 workers x n_threads=nproc on a 16-thread box is 48
# threads self-competing for 16 real cores; a fourth (unrelated, e.g. the
# user's own ML jobs on MJACKSON) makes it worse still. That self-inflicted
# 3x-or-more slowdown is what actually tripped the wall-clock timeout, not
# any real content difficulty -- confirmed live: every one of a title's
# permanently-failed shots reproduced with REAL vmaf data when re-run in
# isolation (no sibling workers), including on JJACKSON, a dedicated node
# with no external competing load at all. DVAL_HOST_WORKER_COUNT is set by
# the launcher to the actual worker count it just started on this host, so
# aggregate libvmaf thread demand across all of them never exceeds the box's
# real core count regardless of who else (siblings or unrelated jobs) is
# also running. See project_dval_coordinator_migration_2026_09_04.
_shot_vmaf_threads() {
  local ncpu wc
  ncpu="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)"
  [[ "$ncpu" =~ ^[0-9]+$ ]] && [ "$ncpu" -gt 0 ] || ncpu=1
  wc="${DVAL_HOST_WORKER_COUNT:-1}"
  [[ "$wc" =~ ^[0-9]+$ ]] && [ "$wc" -gt 0 ] || wc=1
  printf '%s' $(( ncpu / wc > 0 ? ncpu / wc : 1 ))
}

# Decode/filter thread cap for the ffmpeg legs of _vmaf_score_shot +
# _shot_encode_bytes_only (class-F fix, 3-peer consult 2026-09-05). Same math
# as _shot_vmaf_threads: libvmaf's own n_threads was capped 2026-09-04, but the
# dav1d (AV1 source), ffv1 (intermediate) and scale (UHD proxy) decode legs
# still spawned a full-host pool PER worker -- 3-4 siblings/host self-competing
# is the residual "slow -> wall-clock timeout -> search_failed=1" cause on
# grainy/4K AV1 (American Pop hard reel, The Dark Tower). Override with
# DVAL_SHOT_DECODE_THREADS.
_shot_decode_threads() {
  local v="${DVAL_SHOT_DECODE_THREADS:-}"
  [[ "$v" =~ ^[1-9][0-9]*$ ]] && { printf '%s' "$v"; return; }
  _shot_vmaf_threads
}

# UHD 1080p VMAF proxy active? (class-F: native-2160p libvmaf + vmaf_4k @ 95 is
# a cache-miss storm that times out every probe.) On => _vmaf_score_shot scales
# both legs to 1080p + swaps to vmaf_v0.6.1neg, and resolve_per_shot_qp drops
# the target 1.0 to offset the downscaler low-pass. SHOT_IS_UHD is exported
# once per shot by shot_search_claimed() from the manifest model string.
_shot_uhd_proxy_active() {
  [ "${PER_SHOT_UHD_VMAF_PROXY:-true}" = "true" ] && [ "${SHOT_IS_UHD:-0}" = "1" ]
}

# Phase timing for a single _vmaf_score_shot call. DVAL_SHOT_DIAG=1 -> one
# stderr line per subprocess phase (extract / y4m / encode / remux / vmaf /
# parse) with elapsed seconds + rc, plus the temp clip size. This is what
# settles "real timeout vs ffv1 I/O bottleneck vs source defect" for a
# permanently-failing shot without guessing.
_shot_diag_now() { [ "${DVAL_SHOT_DIAG:-0}" = "1" ] && date +%s.%N 2>/dev/null || true; }
_shot_diag() {  # $1=phase  $2=start epoch.ns (empty when DIAG off)  $3=rc  [$4=note]
  [ "${DVAL_SHOT_DIAG:-0}" = "1" ] || return 0
  [ -n "${2:-}" ] || return 0
  local now; now="$(date +%s.%N 2>/dev/null)"
  awk -v p="$1" -v s="$2" -v e="$now" -v rc="${3:-0}" -v n="${4:-}" -v pid="$$" \
    'BEGIN{ printf "[shotdiag pid=%s] %-8s %8.2fs rc=%s %s\n", pid, p, e-s, rc, n }' >&2
}

# Per-shot subprocess wall-clock ceiling. Overload must only cost TIME, never
# correctness -- past this, _run_timeout_retry SIGKILLs and the shot silently
# falls back to fixed QP. 2026-09-05: made resolution/profile aware (was a flat
# 300 + 120*dur, cap 3600 -- badly under-calibrated for 4K and heavy grain).
#   $1 = shot duration (s)   $2 = is_uhd (1|0, optional)   $3 = profile (optional)
# DVAL_SHOT_TIMEOUT_OVERRIDE wins outright (diagnostic reruns).
_shot_ffmpeg_timeout() {
  local duration="$1" is_uhd="${2:-0}" profile="${3:-}"
  local base=300 per_sec=120 cap=3600 d_int extra scaled mult
  if [[ "${DVAL_SHOT_TIMEOUT_OVERRIDE:-}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$DVAL_SHOT_TIMEOUT_OVERRIDE"; return
  fi
  if [ "$is_uhd" = "1" ]; then
    base=600 per_sec=240 cap=7200
  fi
  d_int="$(printf '%.0f' "$duration" 2>/dev/null)"
  case "$d_int" in ''|*[!0-9]*) d_int=0 ;; esac
  extra=$(( d_int * per_sec ))
  scaled=$(( base + extra ))
  # Heavy-grain profiles: SVT-AV1 intra/RDO search expands 1.5-10x on rotoscoped
  # / high-grain content -- give it headroom before calling it a failure.
  case "$profile" in
    wanim-classic|wanime-classic|la-classic|wanim|wanime)
      mult="${PER_SHOT_GRAIN_TIMEOUT_MULT:-1.5}"
      scaled="$(awk -v s="$scaled" -v m="$mult" 'BEGIN{ printf "%d", s*m }')"
      [ "$is_uhd" = "1" ] || cap=5400
      ;;
  esac
  [ "$scaled" -gt "$cap" ] && scaled="$cap"
  printf '%s' "$scaled"
}

# Resolves the standalone SvtAv1EncApp binary. Kept separate from
# discover_tools()'s shared startup checklist/banner (ves-tool-discovery.sh)
# since it's only ever needed for Phase 6 (per-shot search + the final
# qpfile-driven encode), not the general whole-file pipeline every run goes
# through -- a machine that's never touched Phase 6 shouldn't fail its
# checklist over a tool it doesn't need yet. Fleet-wide install location is
# fixed (/usr/bin/SvtAv1EncApp, built from source at a pinned commit -- see
# the fleet parity note below), so a plain PATH lookup is enough.
SVTAV1ENCAPP_CMD=()
discover_svtav1encapp() {
  [ "${#SVTAV1ENCAPP_CMD[@]}" -gt 0 ] && return 0
  local tool
  tool="$(command -v SvtAv1EncApp 2>/dev/null)" || return 1
  SVTAV1ENCAPP_CMD=("$tool")
  # VES_SVTAV1_ASM caps the assembly instruction set (SvtAv1EncApp --asm
  # <c|sse2|...|avx512|max>). SVT-AV1 v4.2.0's x86 SIMD kernels SIGSEGV on
  # some pre-AVX microarchitectures (verified: Nehalem Xeon X5570 crashes at
  # sse3 and up, non-deterministically by content); `--asm 0` (pure C) is
  # slower but bit-identical to the AVX fleet output (sha-verified 2026-09-04).
  # A per-host override that reliably reaches an ssh-exec'd worker (a plain
  # SvtAv1EncApp shell wrapper, or the launcher's env) is the affected box's
  # to set; unset everywhere else so a normal node keeps auto-detect / max.
  [ -n "${VES_SVTAV1_ASM:-}" ] && SVTAV1ENCAPP_CMD+=(--asm "$VES_SVTAV1_ASM")
  return 0
}

# Scores one shot at one candidate QP: encodes the shot's own real frame
# range (stream-copy extracted, not re-decoded first) at a HARD uniform
# QP via the exact same mechanism the final application uses (SvtAv1EncApp
# --qpfile, all frames set to the same value), not ffmpeg's -qp flag.
#
# 2026-08-25: this used to use `ffmpeg -c:v libsvtav1 -qp X` -- reasonable
# on its face (both are "the same SVT-AV1 library, just a different QP
# value"), but a real controlled experiment (same isolated clip, same exact
# QP, both encode paths) found ffmpeg's -qp wrapper and the standalone
# --qpfile mechanism do NOT deliver equivalent quality for the same nominal
# QP -- a real, substantial, consistent gap (mean ~8 VMAF points across a
# 6-shot sample, larger than the whole-file target-vs-actual gap this was
# found while investigating). A separate context-padding fix was tried
# first and made things worse, not better, before this was found -- the
# real bug was never "context," it was that the search was calibrating
# against a DIFFERENT encode code path than the one the final continuous
# encode actually uses. Now both use identical SvtAv1EncApp --qpfile
# invocations (a uniform one-QP-per-frame file here; a real varying one in
# the final assembled encode), so whatever quirk distinguishes the two
# paths no longer matters -- the search is calibrated against reality by
# construction, not by guessing at the cause.
#
# Requires SvtAv1EncApp to be fleet-wide version-pinned the same way
# ffmpeg's libsvtav1 already is (see feedback_svtav1_version_constant) --
# confirmed 2026-08-25 the distro-packaged binary on at least one fleet
# machine was a mismatched, much older build entirely missing features the
# real encode depends on (variance-boost, sharpness). Every machine running
# this function must have the fleet-pinned SvtAv1EncApp built from source
# and installed to /usr/bin, not whatever a package manager happens to
# provide.
# Prints "vmaf bytes" or fails.
# Stage a fleet-shared (NFS) source to local disk ONCE so the per-shot search
# stops re-reading a ~30s window over NFS for every QP probe of every shot
# (2026-09-02 -- the dominant cost of the Linux fleet search; PRINCE was ~4x
# faster mostly because it works from local disk). Echoes the local path on
# success, or the original path (unchanged behaviour) on any failure / when
# disabled. Idempotent + shareable: a re-launched worker on the same host that
# finds a same-size copy reuses it. The manifest / claims / status stay on
# NFS -- only the read-heavy extraction source moves local.
_stage_source_local() {
  local src="$1" dir base dst want have h
  [ "${SHOT_SRC_LOCAL_STAGE:-true}" = "true" ] || { printf '%s' "$src"; return 0; }
  [ -f "$src" ] || { printf '%s' "$src"; return 0; }
  dir="${SHOT_SRC_LOCAL_STAGE_DIR:-/var/tmp/ves-srcstage}"
  mkdir -p "$dir" 2>/dev/null || { printf '%s' "$src"; return 0; }
  # Stage filename = sanitized basename + a short hash of the FULL path, so two
  # different sources can never collide onto one file (review 2026-09-02).
  h="$(printf '%s' "$src" | { cksum 2>/dev/null || md5sum 2>/dev/null; } | tr -cd '0-9a-f' | cut -c1-10)"
  base="$(basename -- "$src" | tr -c 'A-Za-z0-9._-' '_')"
  dst="$dir/${h}_${base}"
  want="$(stat -c%s -- "$src" 2>/dev/null || echo 0)"
  # Sweep stale stages (>48h -- a Phase-1 title search should finish well
  # inside that) but NEVER the file we are about to hand back, and prefer
  # atime so a long-lived worker that is still reading its stage keeps it.
  find "$dir" -maxdepth 1 -type f ! -name "$(basename -- "$dst")" \
       \( -atime +2 -o -mmin +2880 \) -delete 2>/dev/null
  have="$(stat -c%s -- "$dst" 2>/dev/null || echo 0)"
  if [ "$want" -gt 0 ] && [ "$have" = "$want" ]; then
    touch -a -- "$dst" 2>/dev/null   # mark in-use so the sweep spares it
    printf '%s' "$dst"; return 0
  fi
  # disk guard: need the file size + 10% headroom on the stage fs
  local free_kb
  free_kb="$(df -Pk "$dir" 2>/dev/null | awk 'NR==2{print $4}')"
  if [ -n "$free_kb" ] && [ "$(( free_kb * 1024 ))" -lt "$(( want + want/10 ))" ]; then
    warn "_stage_source_local: not enough local space in $dir for $(basename "$src") -- reading from NFS"
    printf '%s' "$src"; return 0
  fi
  # Serialize concurrent workers on THIS host (multi-worker per host): an flock
  # on a LOCAL lock file so only one worker copies the ~GB source; the rest
  # block, then find it done. flock releases automatically when the holder exits
  # (killed or not) -- no stale-steal race. The old mkdir-loop let simultaneous
  # starts through (2026-09-04: 4 parallel 9.4 GB copies on RANDYJ) because the
  # re-check window between mkdir failure and the wait sleep was itself racy.
  local lockf="$dir/.stagelock.$h"
  if command -v flock >/dev/null 2>&1; then
    (
      flock -w 2700 9 || exit 99
      _h2="$(stat -c%s -- "$dst" 2>/dev/null || echo 0)"
      [ "$want" -gt 0 ] && [ "$_h2" = "$want" ] && exit 0    # a peer staged it
      _t2="$dst.$$.part"
      if _stage_copy "$src" "$_t2" && [ "$(stat -c%s -- "$_t2" 2>/dev/null || echo 0)" = "$want" ]; then
        mv -f -- "$_t2" "$dst" 2>/dev/null && exit 0
      fi
      rm -f -- "$_t2" 2>/dev/null; exit 1
    ) 9>"$lockf"
    local _rc=$?
    if [ "$_rc" -eq 0 ]; then touch -a -- "$dst" 2>/dev/null; printf '%s' "$dst"; return 0; fi
    printf '%s' "$src"; return 0
  fi
  # no flock (e.g. bare macOS) -- single-shot copy, best effort
  local tmp="$dst.$$.part"
  if _stage_copy "$src" "$tmp" && [ "$(stat -c%s -- "$tmp" 2>/dev/null || echo 0)" = "$want" ]; then
    mv -f -- "$tmp" "$dst" 2>/dev/null && { printf '%s' "$dst"; return 0; }
  fi
  rm -f -- "$tmp" 2>/dev/null
  printf '%s' "$src"
}

# Parallel byte-range copy: a network source over an nconnect=N NFS mount is
# BDP-capped on a single sequential stream (~11 MB/s over the ~17ms site VPN),
# but N parallel readers fan out across the N TCP connections. Falls back to
# plain cp for a small/local file or when the tools are missing. 2026-09-03.
#
# 2026-09-04 (survey/encode slowdown bind): DEFAULT is rsync over VPN — one
# verified stream with --partial, size check, and a global VPN pull slot so
# fleets do not wedge the tunnel with N×hosts parallel dd. Set
# VES_STAGE_COPY_MODE=parallel-dd to restore the old fan-out (discouraged).
_vpn_pull_slot_acquire() {
  # Serialize concurrent heavy NAS→local pulls on THIS host for THIS stage
  # tree only (slots live under SHOT_SRC_LOCAL_STAGE_DIR). D-val survey uses
  # /var/tmp/dval-srcstage so it does not share flock slots with general VES
  # (/var/tmp/ves-srcstage), comics OCR, or ebook staging.
  local max="${VES_VPN_PULL_MAX:-2}" i slotdir
  slotdir="${SHOT_SRC_LOCAL_STAGE_DIR:-/var/tmp/dval-srcstage}/.vpn-pull-slots"
  mkdir -p "$slotdir" 2>/dev/null || return 0
  command -v flock >/dev/null 2>&1 || return 0
  for ((i=0; i<max; i++)); do
    # shellcheck disable=SC2094
    exec {VES_VPN_PULL_FD}>"$slotdir/slot.$i"
    if flock -n -x "$VES_VPN_PULL_FD" 2>/dev/null; then
      return 0
    fi
    eval "exec ${VES_VPN_PULL_FD}>&-"
  done
  # Block on slot 0 up to 45m
  exec {VES_VPN_PULL_FD}>"$slotdir/slot.0"
  flock -w 2700 -x "$VES_VPN_PULL_FD" 2>/dev/null || true
}

_vpn_pull_slot_release() {
  if [ -n "${VES_VPN_PULL_FD:-}" ]; then
    eval "exec ${VES_VPN_PULL_FD}>&-" 2>/dev/null || true
    unset VES_VPN_PULL_FD
  fi
}

_stage_copy_rsync() {  # <src> <dst>
  local s="$1" d="$2" sz have
  sz="$(stat -c%s -- "$s" 2>/dev/null)" || return 1
  command -v rsync >/dev/null 2>&1 || return 1
  _vpn_pull_slot_acquire
  # --inplace avoids double space; --partial allows resume after VPN blip.
  rsync -a --partial --inplace --timeout=600 \
    --info=name0,progress0 \
    "$s" "$d" 2>/dev/null
  local rc=$?
  _vpn_pull_slot_release
  [ "$rc" -eq 0 ] || return "$rc"
  have="$(stat -c%s -- "$d" 2>/dev/null || echo 0)"
  [ "$have" = "$sz" ] || return 1
  # Optional strong verify (expensive on multi-GB titles).
  if [ "${VES_STAGE_VERIFY_HASH:-0}" = "1" ] && command -v sha256sum >/dev/null 2>&1; then
    local hs hd
    hs="$(sha256sum -- "$s" 2>/dev/null | awk '{print $1}')"
    hd="$(sha256sum -- "$d" 2>/dev/null | awk '{print $1}')"
    [ -n "$hs" ] && [ "$hs" = "$hd" ] || return 1
  fi
  return 0
}

_stage_copy_parallel_dd() {  # <src> <dst>
  local s="$1" d="$2" n="${VES_STAGE_COPY_STREAMS:-3}" sz i chunk ok
  local -a pids=()
  sz="$(stat -c%s -- "$s" 2>/dev/null)" || { cp -f -- "$s" "$d" 2>/dev/null; return $?; }
  if [ "${sz:-0}" -lt 67108864 ] || [ "$n" -le 1 ]; then
    cp -f -- "$s" "$d" 2>/dev/null; return $?
  fi
  { fallocate -l "$sz" -- "$d" 2>/dev/null \
    || truncate -s "$sz" -- "$d" 2>/dev/null; } || { cp -f -- "$s" "$d" 2>/dev/null; return $?; }
  chunk=$(( (sz + n - 1) / n ))
  for ((i=0; i<n; i++)); do
    dd if="$s" of="$d" bs=4M conv=notrunc \
       iflag=skip_bytes,count_bytes oflag=seek_bytes \
       skip=$((i*chunk)) seek=$((i*chunk)) count="$chunk" 2>/dev/null &
    pids+=("$!")
  done
  ok=1; for i in "${pids[@]}"; do wait "$i" || ok=0; done
  [ "$ok" = 1 ] && [ "$(stat -c%s -- "$d" 2>/dev/null || echo 0)" = "$sz" ]
}

_stage_copy() {  # <src> <dst>
  local s="$1" d="$2" mode="${VES_STAGE_COPY_MODE:-rsync}" sz
  sz="$(stat -c%s -- "$s" 2>/dev/null)" || { cp -f -- "$s" "$d" 2>/dev/null; return $?; }
  # Small / already-local: plain cp
  if [ "${sz:-0}" -lt 67108864 ]; then
    cp -f -- "$s" "$d" 2>/dev/null; return $?
  fi
  case "$mode" in
    parallel-dd|dd)
      _vpn_pull_slot_acquire
      _stage_copy_parallel_dd "$s" "$d"
      local rc=$?
      _vpn_pull_slot_release
      return "$rc"
      ;;
    cp)
      _vpn_pull_slot_acquire
      cp -f -- "$s" "$d" 2>/dev/null
      local rc=$?
      _vpn_pull_slot_release
      return "$rc"
      ;;
    rsync|*)
      if _stage_copy_rsync "$s" "$d"; then
        return 0
      fi
      # Fall back to single-stream cp (never parallel-dd unless explicitly asked)
      warn "_stage_copy: rsync failed for $(basename "$s") -- falling back to cp"
      _vpn_pull_slot_acquire
      cp -f -- "$s" "$d" 2>/dev/null
      local rc=$?
      _vpn_pull_slot_release
      [ "$rc" -eq 0 ] && [ "$(stat -c%s -- "$d" 2>/dev/null || echo 0)" = "$sz" ]
      ;;
  esac
}

_vmaf_score_shot() {
  local src="$1" start="$2" end="$3" qp="$4" codec="$5" model="$6" profile="$7"
  # Read the extraction from a local stage when the worker set one up.
  src="${SHOT_SRC_LOCAL:-$src}"
  local work clip y4m out out_mkv vlog v b enc_timeout nframes qpfile _t0
  local -a grain_decode_flag=()
  local _dthreads _vmaf_scale="" _lp_arg=()
  _dthreads="$(_shot_decode_threads)"
  _lp_arg=(--lp "$_dthreads")
  # FGS on the VMAF compare (class-F consult 2026-09-05): grain stays ON on
  # BOTH legs by default -- the measured, playback-calibrated choice (grain-off
  # suppressed the per-shot ceiling 1-3 VMAF; the decoder re-synthesises grain
  # at playback). PER_SHOT_VMAF_FGS=off strips it SYMMETRICALLY (both -i
  # inputs) for diagnostics only; reference-only stripping is never allowed
  # (biases VIF/DLM 2-5 pts on uncorrelated synthetic grain).
  if [ "${PER_SHOT_VMAF_FGS:-on}" = "off" ]; then
    grain_decode_flag=(-filmgrain 0)
  fi
  # UHD 1080p proxy: scale both legs down + standard neg model. Native-4K VMAF
  # (vmaf_4k) stays available with PER_SHOT_UHD_VMAF_PROXY=false for spot checks.
  if _shot_uhd_proxy_active; then
    _vmaf_scale="scale=1920:1080:flags=bicubic,"
    model="version=vmaf_v0.6.1neg"
  fi
  discover_svtav1encapp || return 1
  work="$(mktemp -d "${RAMDISK_JOB_DIR:-${TMPDIR:-/tmp}}/ves-shotqp-XXXXXX")" || return 1
  clip="$work/shot.mkv"
  # Extraction of a boundary-precise LOSSLESS clip. Two real constraints,
  # each learned the hard way:
  #
  #  1) (2026-08-25, Star Trek Discovery per-shot search) pre-input
  #     -ss/-to + `-c copy` cannot cut mid-GOP -- it snaps the END up to
  #     the next keyframe, overshooting a short shot by 1.5-3x (28->74,
  #     212->296 frames on two real shots), feeding junk trailing content
  #     into every VMAF probe and inflating every recorded byte cost (the
  #     equal-slope allocator's own lambda-bisection input). The cut must
  #     be a real decode into an ffv1 re-encode, never a stream copy.
  #
  #  2) (2026-08-28, Raised by Wolves regional-survey search) a bare
  #     post-input `-ss "$start"` with no pre-input seek makes ffmpeg
  #     demux from frame 0 to $start every call -- for a shot ~20 min into
  #     a ~40 min episode that is ~1200 s of throwaway lossless decode per
  #     probe, several probes per shot. Seen live at 5+ min per 2 s shot,
  #     fleet load average ~3x core count.
  #
  # Fix for (2), keeping (1): two-stage seek. Fast pre-input -ss to a
  # keyframe a safe margin (30 s, comfortably longer than any real GOP)
  # BEFORE the target, then an accurate post-input -ss for exactly that
  # margin, then -t for the exact duration. ffmpeg's post-input -ss is
  # frame-accurate regardless of where the preceding fast seek landed, as
  # long as it landed at/before the target frame -- which a
  # nearest-preceding-keyframe seek guarantees -- so the output is
  # frame-identical to the single-stage accurate seek from (1)
  # (re-verified frame-exact 2026-08-28). Use -t (duration), not -to
  # (absolute ts): -to's meaning after a post-input -ss varies by ffmpeg
  # version.
  local _seek_margin=30 _fast_ss _acc_ss _clip_dur
  _fast_ss="$(awk -v s="$start" -v m="$_seek_margin" 'BEGIN{ f=s-m; if(f<0)f=0; printf "%.6f", f }')"
  _acc_ss="$(awk -v s="$start" -v f="$_fast_ss" 'BEGIN{ printf "%.6f", s-f }')"
  _clip_dur="$(awk -v s="$start" -v e="$end" 'BEGIN{ d=e-s; if(d<0)d=0; printf "%.6f", d }')"
  _t0="$(_shot_diag_now)"
  run_ffmpeg_validation -y -v error -threads "$_dthreads" -ss "$_fast_ss" -i "$src" -ss "$_acc_ss" -t "$_clip_dur" \
    -map 0:v:0 -c:v ffv1 -level 3 "$clip" 2>/dev/null
  { local _rc=$?; _shot_diag extract "$_t0" "$_rc" "clip=$(stat -c%s -- "$clip" 2>/dev/null || echo 0)B"; [ "$_rc" -eq 0 ]; } || { rm -rf "$work"; return 1; }
  [ -s "$clip" ] || { rm -rf "$work"; return 1; }
  enc_timeout="$(_shot_ffmpeg_timeout "$(awk -v s="$start" -v e="$end" 'BEGIN{d=e-s; if(d<0)d=0; print d}')" "${SHOT_IS_UHD:-0}" "$profile")"
  case "$codec" in
    av1)
      local svtp; svtp="$(profile_svt_params "$profile")" || { rm -rf "$work"; return 1; }
      y4m="$work/shot.y4m"
      _t0="$(_shot_diag_now)"
      run_ffmpeg_validation -y -v error -threads "$_dthreads" -i "$clip" -map 0:v:0 -pix_fmt yuv420p10le -strict -1 "$y4m" 2>/dev/null
      { local _rc=$?; _shot_diag y4m "$_t0" "$_rc"; [ "$_rc" -eq 0 ]; } || { rm -rf "$work"; return 1; }
      # trailing-comma guard: see the note in _shot_encode_bytes_only. 4K HDR10
      # (The Dark Tower) made `-of csv=p=0` print "40," -> the ^[0-9]+$ check
      # failed -> every shot fell back to search_failed=1 (found live 2026-09-03).
      nframes="$("${FFPROBE_CMD[@]}" -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of default=nokey=1:noprint_wrappers=1 "$clip" 2>/dev/null | grep -m1 -oE '[0-9]+' || true)"
      [[ "$nframes" =~ ^[0-9]+$ ]] && [ "$nframes" -gt 0 ] || { rm -rf "$work"; return 1; }
      qpfile="$work/uniform-$qp.qp"
      # awk generator, not `yes | head`: under `set -o pipefail` (production
      # convert.sh) the SIGPIPE that stops `yes` makes the pipeline non-zero,
      # which aborts a bare `result="$(resolve_per_shot_qp ...)"` assignment.
      awk -v q="$qp" -v n="$nframes" 'BEGIN{ while (n-- > 0) print q }' > "$qpfile"
      out="$work/shot-enc-$qp.ivf"
      _t0="$(_shot_diag_now)"
      _run_timeout_retry "$enc_timeout" "${SVTAV1ENCAPP_CMD[@]}" -i "$y4m" --use-q-file 1 --qpfile "$qpfile" \
        "${_lp_arg[@]}" --svtav1-params "${svtp}:rc=0" -b "$out" 2>/dev/null
      { local _rc=$?; _shot_diag encode "$_t0" "$_rc" "out=$(stat -c%s -- "$out" 2>/dev/null || echo 0)B"; [ "$_rc" -eq 0 ]; } || { rm -rf "$work"; return 1; }
      [ -s "$out" ] || { rm -rf "$work"; return 1; }
      out_mkv="$work/shot-enc-$qp.mkv"
      _t0="$(_shot_diag_now)"
      run_ffmpeg_validation -y -v error -threads "$_dthreads" -i "$out" -c copy "$out_mkv" 2>/dev/null
      { local _rc=$?; _shot_diag remux "$_t0" "$_rc"; [ "$_rc" -eq 0 ]; } || { rm -rf "$work"; return 1; }
      # FGS default: grain stays ON on both legs (grain_decode_flag empty) --
      # decoding grain-free and comparing to the grainy source penalises a
      # difference that does not exist in playback (the decoder re-synthesises
      # grain), which suppressed the per-shot ceiling 1-3 VMAF (Conan per-shot A
      # 91.2 vs its low-CRF base 92.6). PER_SHOT_VMAF_FGS=off overrides
      # symmetrically (set in the function preamble) for diagnostics.
      ;;
    *) rm -rf "$work"; return 1 ;;
  esac
  vlog="${out}.vmaf.json"
  # VMAF frame stride: score every Sth frame in the SEARCH only (relative QP
  # comparison is stable under subsampling; the final whole-file measure is
  # never strided). S>1 ONLY when the source is confirmed progressive --
  # telecine/interlaced/ambiguous/unknown alias badly under frame decimation
  # (combing on alternate fields, 3:2 pulldown dupes). SHOT_FIELD_MODE is set
  # per-title by shot_search_claimed() from manifest.meta.
  local _stride=1 _sel=""
  if [ "${SHOT_FIELD_MODE:-unknown}" = "progressive" ]; then
    _stride="${PER_SHOT_VMAF_STRIDE:-2}"
  fi
  [ "${_stride:-1}" -gt 1 ] 2>/dev/null && _sel="select='not(mod(n\,${_stride}))',"
  # grain_decode_flag (empty by default; -filmgrain 0 when PER_SHOT_VMAF_FGS=off)
  # goes before BOTH -i so the strip is symmetric. -threads caps dav1d/scale on
  # this leg; libvmaf gets its own n_threads. _vmaf_scale downscales both legs
  # for the UHD 1080p proxy path.
  _t0="$(_shot_diag_now)"
  _run_timeout_retry "$enc_timeout" "${FFMPEG_CMD[@]}" -y -v error -threads "$_dthreads" \
    "${grain_decode_flag[@]}" -i "$out_mkv" "${grain_decode_flag[@]}" -i "$clip" -lavfi \
    "[0:v]${_sel}${_vmaf_scale}setpts=PTS-STARTPTS,format=yuv420p10le[d];[1:v]${_sel}${_vmaf_scale}setpts=PTS-STARTPTS,format=yuv420p10le[r];[d][r]libvmaf=model=$model:n_threads=$(_shot_vmaf_threads):log_fmt=json:log_path=$vlog" \
    -f null - 2>/dev/null
  { local _rc=$?; _shot_diag vmaf "$_t0" "$_rc" "model=$model${_vmaf_scale:+ proxy1080}"; [ "$_rc" -eq 0 ]; } || { rm -rf "$work"; return 1; }
  _t0="$(_shot_diag_now)"
  v="$(python3 -c "import json;print(round(json.load(open('$vlog'))['pooled_metrics']['vmaf']['mean'],2))" 2>/dev/null)"
  { local _rc=$?; _shot_diag parse "$_t0" "$_rc" "vmaf=${v:-?}"; [ "$_rc" -eq 0 ] && [ -n "$v" ]; } || { rm -rf "$work"; return 1; }
  b="$(file_size_bytes "$out")"
  rm -rf "$work"
  printf '%s %s' "$v" "$b"
}

# Encode the WHOLE shot once at a fixed QP and print its byte size (no VMAF).
# Used to de-bias multi-window byte estimates: 3 isolated 8s windows under
# keyint=15s carry more I-frame overhead per second than one continuous
# encode, so mean(window_bytes/sec)*shot_secs runs high -- and the bias is
# title-composition-dependent, not constant, so it does not cancel in the
# survey's fraction ratio (review 2026-09-02). One real full-shot encode at
# the chosen QP anchors the byte scale.
_shot_encode_bytes_only() {
  local src="$1" start="$2" end="$3" qp="$4" codec="$5" profile="$6"
  local work clip y4m out nframes qpfile svtp enc_timeout b _dthreads
  discover_svtav1encapp || return 1
  [ "$codec" = av1 ] || return 1
  svtp="$(profile_svt_params "$profile")" || return 1
  _dthreads="$(_shot_decode_threads)"
  work="$(mktemp -d "${RAMDISK_JOB_DIR:-${TMPDIR:-/tmp}}/ves-shotbytes-XXXXXX")" || return 1
  clip="$work/shot.mkv"; y4m="$work/shot.y4m"; out="$work/shot.ivf"
  local _fast_ss _acc_ss _dur
  _fast_ss="$(awk -v s="$start" 'BEGIN{f=s-30; if(f<0)f=0; printf "%.6f", f}')"
  _acc_ss="$(awk -v s="$start" -v f="$_fast_ss" 'BEGIN{printf "%.6f", s-f}')"
  _dur="$(awk -v s="$start" -v e="$end" 'BEGIN{d=e-s; if(d<0)d=0; printf "%.6f", d}')"
  enc_timeout="$(_shot_ffmpeg_timeout "$_dur" "${SHOT_IS_UHD:-0}" "$profile")"
  run_ffmpeg_validation -y -v error -threads "$_dthreads" -ss "$_fast_ss" -i "${SHOT_SRC_LOCAL:-$src}" -ss "$_acc_ss" -t "$_dur" \
    -map 0:v:0 -c:v ffv1 -level 3 "$clip" 2>/dev/null || { rm -rf "$work"; return 1; }
  run_ffmpeg_validation -y -v error -threads "$_dthreads" -i "$clip" -map 0:v:0 -pix_fmt yuv420p10le -strict -1 "$y4m" 2>/dev/null \
    || { rm -rf "$work"; return 1; }
  # `-of csv=p=0` can emit a trailing "," for the ffv1 re-encode of some
  # sources (seen live 2026-09-03 on The Dark Tower -- 4K HDR10: ffprobe
  # prints "40," so the `^[0-9]+$` guard failed and EVERY shot fell back to
  # search_failed=1). Same trailing-comma class as _source_is_uhd (v6.0.1F).
  # `default=nokey=1:noprint_wrappers=1` never adds separators; grep the int.
  nframes="$("${FFPROBE_CMD[@]}" -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of default=nokey=1:noprint_wrappers=1 "$clip" 2>/dev/null | grep -m1 -oE '[0-9]+' || true)"
  [[ "$nframes" =~ ^[0-9]+$ ]] && [ "$nframes" -gt 0 ] || { rm -rf "$work"; return 1; }
  qpfile="$work/uniform.qp"
  awk -v q="$qp" -v n="$nframes" 'BEGIN{ while (n-- > 0) print q }' > "$qpfile"
  _run_timeout_retry "$enc_timeout" "${SVTAV1ENCAPP_CMD[@]}" -i "$y4m" --use-q-file 1 --qpfile "$qpfile" \
    --lp "$_dthreads" --svtav1-params "${svtp}:rc=0" -b "$out" 2>/dev/null || { rm -rf "$work"; return 1; }
  [ -s "$out" ] || { rm -rf "$work"; return 1; }
  b="$(file_size_bytes "$out")"
  rm -rf "$work"
  printf '%s' "$b"
}

# Multi-window scorer for a LONG shot: instead of extracting + encoding +
# scoring the whole shot (a 6-min take => 20-40GB ffv1, hours per QP probe),
# score 3 short windows placed by content (SHOT_MW_OFFSETS, seconds from the
# shot start -- content-driven from _shot_long_windows(), or evenly spaced as
# a fallback) and combine:
#   vmaf  = MEDIAN of the 3 window VMAFs   (robust to one odd window)
#   bytes = mean(window_bytes / window_secs) * shot_secs   (rate-scaled)
# Same (qp,vmaf,bytes) contract as _vmaf_score_shot so resolve_per_shot_qp()
# is agnostic. Env in: SHOT_MW_OFFSETS (csv), SHOT_MW_LEN (default 8).
_vmaf_score_shot_mw() {
  local src="$1" start="$2" end="$3" qp="$4" codec="$5" model="$6" profile="$7"
  local wl="${SHOT_MW_LEN:-8}" offs="${SHOT_MW_OFFSETS:-}" shot_dur o ws we r wv wb
  local -a vs=() rates=()
  shot_dur="$(awk -v a="$start" -v b="$end" 'BEGIN{d=b-a; if(d<0)d=0; printf "%.6f", d}')"
  [ -n "$offs" ] || offs="$(awk -v d="$shot_dur" -v l="$wl" 'BEGIN{
      for(k=0;k<3;k++){o=d*(2*k+1)/6.0 - l/2.0; if(o<0)o=0; if(o+l>d)o=d-l; if(o<0)o=0; printf "%s%.2f",(k?",":""),o}}')"
  local IFS=,
  for o in $offs; do
    IFS=' '
    ws="$(awk -v s="$start" -v o="$o" 'BEGIN{printf "%.6f", s+o}')"
    we="$(awk -v s="$ws" -v l="$wl" -v e="$end" 'BEGIN{x=s+l; if(x>e)x=e; printf "%.6f", x}')"
    r="$(_vmaf_score_shot "$src" "$ws" "$we" "$qp" "$codec" "$model" "$profile")" || continue
    wv="${r%% *}"; wb="${r##* }"
    [ -n "$wv" ] && [ -n "$wb" ] || continue
    vs+=("$wv")
    rates+=("$(awk -v b="$wb" -v s="$ws" -v e="$we" 'BEGIN{d=e-s; if(d<=0){print 0;exit} printf "%.6f", b/d}')")
  done
  # Need >=2 usable windows for a median; 1 lone window can bias a shot's QP.
  if [ "${#vs[@]}" -lt 2 ]; then
    log_err "  per-shot mw: only ${#vs[@]} usable window(s) shot=${start}-${end} -- full-shot fallback"
    _vmaf_score_shot "$src" "$start" "$end" "$qp" "$codec" "$model" "$profile"
    return $?
  fi
  # median vmaf
  local med; med="$(printf '%s\n' "${vs[@]}" | sort -n | awk '{a[NR]=$1} END{print (NR%2)? a[int(NR/2)+1] : (a[NR/2]+a[NR/2+1])/2}')"
  # rate-scaled bytes
  local est; est="$(printf '%s\n' "${rates[@]}" | awk -v d="$shot_dur" '{s+=$1;n++} END{if(n) printf "%d", (s/n)*d; else print 0}')"
  printf '%s %s' "$med" "$est"
}

# Linear interpolation between two real, bracketing (QP,VMAF) samples to
# predict which QP's VMAF should land closest to target -- ported from
# Av1an's real target-quality search (av1an-core/src/target_quality.rs
# predict_quantizer(), the n==2-history case), used here once >=2 real
# samples bracket the target instead of blindly bisecting the QP range.
# Clamped strictly inside (above_qp, below_qp) so it can never repeat an
# already-probed point or extrapolate past the known-bracketing pair.
_interp_qp() {
  local above_qp="$1" above_score="$2" below_qp="$3" below_score="$4" target="$5"
  awk -v aq="$above_qp" -v as="$above_score" -v bq="$below_qp" -v bs="$below_score" -v t="$target" '
    BEGIN {
      # No integer strictly between aq and bq -- callers guard against this
      # (the gap<=1 check breaks the search loop before ever calling this
      # function), but degenerate input would otherwise double-clamp and
      # bounce back to aq below; return aq directly instead.
      if (bq - aq <= 1) { print aq; exit; }
      if (bs == as) { q = int((aq + bq) / 2 + 0.5); }
      else { q = aq + (t - as) * (bq - aq) / (bs - as); q = int(q + 0.5); }
      if (q <= aq) q = aq + 1;
      if (q >= bq) q = bq - 1;
      print q;
    }'
}

# Bounded search for one shot -- anchors match vmaf_crf_search_internal()'s
# shape (QP instead of CRF), refinement steps use curve interpolation
# instead of blind bisection to reach the same guaranteed-optimal (gap<=1)
# answer faster (see _interp_qp() above and the comment inline below).
# Scored via _vmaf_score_shot() instead of sampling several clips. Prints
# "qp achieved_vmaf samples" (3 whitespace-separated fields -- parse with
# `read -r qp vmaf samples <<<"$result"`, NOT the old first/last-field
# shortcut) or fails (caller should fall back to a fixed default QP for
# this shot, same "search failed, don't block the pipeline" philosophy
# resolve_crf_for_encode() already uses for whole-file search). `samples`
# is every (qp,vmaf,bytes) this call actually probed, comma-joined
# "qp:vmaf:bytes" entries -- feeds the Phase 6.1 equal-slope allocator's
# per-shot rate-distortion data (the search already produces these as a
# side effect of finding its own winner; this just stops discarding them).
#
# LAST_SHOT_SEARCH_SAMPLES below is populated during the search purely as
# this function's own internal accumulator for building that 3rd field --
# NOT a usable side-channel for callers. Every real caller invokes this
# function via $(...) command substitution, which forks a subshell; a
# global written inside that subshell never reaches the caller. Found
# live 2026-08-25: an earlier version of this comment described the
# global itself as the intended hand-off mechanism, and it was silently
# always empty in every caller as a result.
LAST_SHOT_SEARCH_SAMPLES=()

# SCAFFOLDING (2026-09-02) -- per-profile QP search bracket. Returns "lo hi"
# for the anchor/refine range in resolve_per_shot_qp. When
# PER_SHOT_QP_BRACKET_ENABLE is false (default) or no band is defined for the
# profile, returns the global PER_SHOT_QP_MIN/MAX -- i.e. a pure no-op until
# the bands are researched and the flag flipped. The band NEVER clamps the
# final answer: the (B) extend logic in resolve_per_shot_qp still probes past
# a bound, and _shot_status_bracket_edge() records when a shot resolved
# at/past the band so a mis-bracketed title can be re-run wide (guard:
# PER_SHOT_QP_BRACKET_EDGE_FAIL_PCT).
_per_shot_qp_bracket_for() {
  local profile="$1" band="" up
  [ "${PER_SHOT_QP_BRACKET_ENABLE:-false}" = "true" ] || {
    printf '%s %s' "${PER_SHOT_QP_MIN:-14}" "${PER_SHOT_QP_MAX:-50}"; return 0
  }
  up="$(printf '%s' "$profile" | tr '[:lower:]-' '[:upper:]_')"
  eval "band=\"\${PER_SHOT_QP_BRACKET_${up}:-}\""
  if printf '%s' "$band" | grep -Eq '^[0-9]+ +[0-9]+$'; then
    printf '%s' "$band"
  else
    printf '%s %s' "${PER_SHOT_QP_MIN:-14}" "${PER_SHOT_QP_MAX:-50}"
  fi
}

# Zero-signal shot? Pure black / fade / flat static card -- carries no
# rate-distortion calibration signal and ~0 bytes, so a full QP search on it
# is wasted. Triple-gated on the manifest complexity fields (no encode):
#   cx_luma  < NOSIG_BLACK_LUMA      (near-black)
#   cx_motion < NOSIG_STATIC_MOTION  (nothing moving)
#   cx_detail < NOSIG_FLAT_DETAIL    (genuinely flat -- excludes credits text,
#                                     grain on a dark scene, etc.)
# Reads the shot meta ($1). Returns 0 (is zero-signal) / 1 (search it).
_shot_is_nosignal() {
  local meta="$1" l m d
  [ "${PER_SHOT_NOSIGNAL_FASTPATH:-true}" = "true" ] || return 1
  [ -f "$meta" ] || return 1
  l="$(awk -F= '/^cx_luma=/{print $2; exit}' "$meta")"
  m="$(awk -F= '/^cx_motion=/{print $2; exit}' "$meta")"
  d="$(awk -F= '/^cx_detail=/{print $2; exit}' "$meta")"
  [ -n "$l" ] && [ -n "$m" ] && [ -n "$d" ] || return 1
  awk -v l="$l" -v m="$m" -v d="$d" \
      -v L="${NOSIG_BLACK_LUMA:-16}" -v M="${NOSIG_STATIC_MOTION:-1.0}" -v D="${NOSIG_FLAT_DETAIL:-3.0}" \
      'BEGIN{ exit !(l+0 < L && m+0 < M && d+0 < D) }'
}

# SCAFFOLDING -- was this shot's resolved QP at/past its search band edge?
# Args: <resolved_qp> <band_lo> <band_hi>.  echoes "1" (edge) or "0".
# Consumed by the (not-yet-wired) title-level bracket-health check that
# re-runs a title wide when > EDGE_FAIL_PCT of its shots hit an edge.
_shot_status_bracket_edge() {
  local q="$1" lo="$2" hi="$3"
  { [ "${q:-30}" -le "${lo:-0}" ] || [ "${q:-30}" -ge "${hi:-63}" ]; } && echo 1 || echo 0
}

resolve_per_shot_qp() {
  local src="$1" start="$2" end="$3" codec="$4" target="$5" model="$6" profile="$7"
  local -A score=() bytes=()
  local qp above below gap
  LAST_SHOT_SEARCH_SAMPLES=()
  # read all probes from the worker's local stage when one is set (the
  # manifest key derived upstream from the ORIGINAL path is unaffected)
  src="${SHOT_SRC_LOCAL:-$src}"

  # UHD 1080p VMAF proxy (class-F 2026-09-05): _vmaf_score_shot scores the
  # downscaled 1080p pair with vmaf_v0.6.1neg; drop the target 1.0 here so the
  # search aims at an equivalent quality point (a 1080p downscale low-passes
  # fine 4K texture, so the same bitstream reads ~1 VMAF higher on the proxy).
  if _shot_uhd_proxy_active; then
    target="$(awk -v t="$target" -v d="${PER_SHOT_UHD_VMAF_PROXY_TARGET_DELTA:-1.0}" \
      'BEGIN{ printf "%.1f", (t+0) - (d+0) }')"
  fi

  # --- (#2, GATED) content-adaptive per-shot target -------------------------
  # One cheap ffmpeg read of the shot (no encode): mean luma + inter-frame
  # difference energy. High motion -> lower target (the eye can't resolve the
  # detail and it is cheaper); dark + low motion -> higher target (banding
  # shows at 94 on smooth gradients). Clamped to base +/- 3. Off unless
  # PER_SHOT_ADAPTIVE_TARGET=true.
  if [ "${PER_SHOT_ADAPTIVE_TARGET:-false}" = "true" ]; then
    local _base_t="$target" _span="${PER_SHOT_ADAPTIVE_TARGET_SPAN:-2.0}"
    local _fss _ass _dur _yavg _motion
    _fss="$(awk -v s="$start" 'BEGIN{f=s-30; if(f<0)f=0; printf "%.6f", f}')"
    _ass="$(awk -v s="$start" -v f="$_fss" 'BEGIN{printf "%.6f", s-f}')"
    _dur="$(awk -v s="$start" -v e="$end" 'BEGIN{d=e-s; if(d<0)d=0; printf "%.6f", d}')"
    _yavg="$("${FFMPEG_CMD[@]}" -v error -nostats -ss "$_fss" -i "$src" -ss "$_ass" -t "$_dur" \
      -map 0:v:0 -vf "signalstats,metadata=print:file=-" -f null - 2>/dev/null \
      | awk -F= '/lavfi\.signalstats\.YAVG/{s+=$2;n++} END{if(n)printf "%.1f", s/n; else print "128"}')"
    _motion="$("${FFMPEG_CMD[@]}" -v error -nostats -ss "$_fss" -i "$src" -ss "$_ass" -t "$_dur" \
      -map 0:v:0 -vf "tblend=all_mode=difference,signalstats,metadata=print:file=-" -f null - 2>/dev/null \
      | awk -F= '/lavfi\.signalstats\.YAVG/{s+=$2;n++} END{if(n)printf "%.2f", s/n; else print "0"}')"
    target="$(awk -v t="$_base_t" -v sp="$_span" -v y="${_yavg:-128}" -v m="${_motion:-0}" 'BEGIN{
      adj=0
      if (m+0 >= 6.0)            adj = -sp          # busy motion
      else if (y+0 <= 55 && m+0 <= 2.0) adj = sp    # dark + static -> banding risk
      nt = t + adj
      if (nt > t+3) nt = t+3; if (nt < t-3) nt = t-3
      printf "%.1f", nt
    }')"
    log_err "  per-shot adaptive-target shot=${start}-${end} yavg=${_yavg} motion=${_motion} base=${_base_t} -> target=${target}"
  fi

  # Long-shot multi-window path: shot_search_claimed() sets SHOT_MW_ACTIVE=1
  # (+ SHOT_MW_OFFSETS) when this shot is longer than SHOT_LONG_SECS and
  # PER_SHOT_MULTIWINDOW_ENABLE is on.
  local _score_fn=_vmaf_score_shot
  if [ "${SHOT_MW_ACTIVE:-0}" = "1" ] && declare -F _vmaf_score_shot_mw >/dev/null 2>&1; then
    _score_fn=_vmaf_score_shot_mw
  fi
  _probe_qp() {
    local q="$1" r
    [ -n "${score[$q]:-}" ] && return 0
    r="$("$_score_fn" "$src" "$start" "$end" "$q" "$codec" "$model" "$profile")" || return 1
    score[$q]="${r%% *}"; bytes[$q]="${r##* }"
    LAST_SHOT_SEARCH_SAMPLES+=("${q}:${score[$q]}:${bytes[$q]}")
    log_err "  per-shot qp-search [$codec]${SHOT_MW_ACTIVE:+ mw} shot=${start}-${end} qp=$q vmaf=${score[$q]}"
  }

  # QP shares CRF's exact 0-63 scale and direction in this SVT-AV1 build
  # (lower value = more bits = higher quality) -- same anchor/bisect shape
  # as vmaf_crf_search_internal(), "above"/"below" naming kept identical
  # to that function on purpose so the two stay easy to compare.
  #
  # 2026-08-25: refinement probe PLACEMENT switched from blind bisection to
  # linear interpolation on the real (QP,VMAF) curve once two bracketing
  # samples exist -- ported from Av1an's real target-quality search
  # (av1an-core/src/target_quality.rs predict_quantizer(), confirmed via
  # its actual GitHub source). Pure speed win, no downside: it still
  # searches for the same true answer (gap<=1, i.e. the highest/most
  # bit-efficient QP that still meets target), just reaches it in fewer
  # probes than blindly halving the remaining range, since it uses where
  # the curve actually crosses the target instead of the range's midpoint.
  #
  # An earlier version of this fix also added a tolerance-band EARLY EXIT
  # (stop the instant any probe lands within [target,target+0.5], not only
  # once gap<=1) -- ported from the same Av1an source, but REVERTED same
  # day after review: it stops before confirming no more-efficient
  # (higher, fewer-bits) QP exists just beyond the accepted one, trading
  # guaranteed bit-optimality for speed. That's the wrong tradeoff given
  # this project's own priority order (quality > size > *speed* last) --
  # confirmed on a real shot where the old bisection search's extra probes
  # (which the tolerance exit would have skipped) were doing exactly this
  # check: shot 52.594-52.803 of the 2026-08-24 test episode landed on the
  # identical qp=30/vmaf=94.17 either way, but bisection spent 4 extra
  # probes (all landing below target) specifically confirming nothing
  # between 30 and 46 could beat 30 -- real, deliberate thoroughness, not
  # wasted work. Keep interpolation (faster path to the same guaranteed-
  # optimal answer); don't accept "good enough" in its place.
  # Per-shot search bounds are independent of the whole-file VMAF_SEARCH_*_CRF
  # (see ves-config.sh, section B) so the wider range here can't move
  # production whole-file behaviour.
  # Per-profile band when PER_SHOT_QP_BRACKET_ENABLE=true, else the global
  # PER_SHOT_QP_MIN/MAX (unchanged behaviour). The (B) extend logic below
  # still probes past whichever bound applies, so a too-tight band never
  # clamps the real answer -- it only changes where the search anchors.
  local qp_lo qp_hi qp_mid
  read -r qp_lo qp_hi <<<"$(_per_shot_qp_bracket_for "$profile")"
  : "${qp_lo:=${PER_SHOT_QP_MIN:-14}}" "${qp_hi:=${PER_SHOT_QP_MAX:-50}}"
  # middle anchor: 30 when the band spans it (keeps a consistent cross-profile
  # reference), else the band midpoint
  if [ "$qp_lo" -le 30 ] && [ "$qp_hi" -ge 30 ]; then qp_mid=30; else qp_mid=$(( (qp_lo + qp_hi) / 2 )); fi
  local anchors="$qp_lo $qp_mid $qp_hi"
  for qp in $anchors; do _probe_qp "$qp" || return 1; done
  for i in 1 2 3; do
    above=""; below=""
    for qp in $(printf '%s\n' "${!score[@]}" | sort -n); do
      if awk -v s="${score[$qp]}" -v t="$target" 'BEGIN{exit !(s>=t)}'; then above="$qp"; else below="$qp"; break; fi
    done
    # Nothing meets target even at qp_lo (or everything meets it even at
    # qp_hi): the bound is already probed, so re-probing is a cache-hit no-op
    # that just burns the remaining iterations. Stop -- the (B) window
    # extension below probes past the bound to give the allocator a real
    # rate-distortion curve.
    if [ -z "$above" ] || [ -z "$below" ]; then break; fi
    gap=$(( below - above )); [ "$gap" -le 1 ] && break
    local next_qp
    next_qp="$(_interp_qp "$above" "${score[$above]}" "$below" "${score[$below]}" "$target")"
    _probe_qp "$next_qp" || break
  done

  # --- (B) content-adaptive window extension --------------------------------
  # The search above is clipped to [qp_lo, qp_hi]. If a shot bottomed out at
  # a bound, probe PAST it so the allocator gets a real rate-distortion curve
  # (never one clipped at the window edge) -- this is what lets genuinely
  # cheap shots bank bytes and genuinely hard shots be protected, with no
  # per-position logic (the survey showed position != viewer-value).
  local _hi_qp="" _hi_v="" _q _p
  for qp in $(printf '%s\n' "${!score[@]}" | sort -n); do
    awk -v s="${score[$qp]}" -v t="$target" 'BEGIN{exit !(s>=t)}' && { _hi_qp="$qp"; _hi_v="${score[$qp]}"; }
  done
  if [ -n "$_hi_qp" ] && [ "$_hi_qp" -ge "$qp_hi" ] \
     && awk -v v="$_hi_v" -v t="$target" -v m="$PER_SHOT_QP_EXTEND_MARGIN" 'BEGIN{exit !(v >= t + m)}'; then
    # cheap end: still target+MARGIN or better at the ceiling -> keep going up
    # (fewer bits) as long as target still holds
    _q="$qp_hi"
    for _p in $(seq 1 "$PER_SHOT_QP_EXTEND_PROBES"); do
      _q=$(( _q + PER_SHOT_QP_EXTEND_STEP ))
      [ "$_q" -le "$PER_SHOT_QP_EXTEND_CEIL" ] || break
      _probe_qp "$_q" || break
      awk -v s="${score[$_q]:-0}" -v t="$target" 'BEGIN{exit !(s>=t)}' || break
    done
  elif [ -z "$_hi_qp" ]; then
    # hard end: nothing met target -> probe below the floor to map the
    # quality ceiling (gives the allocator an expensive-end RD sample)
    _q="$qp_lo"
    for _p in $(seq 1 "$PER_SHOT_QP_EXTEND_PROBES"); do
      _q=$(( _q - PER_SHOT_QP_EXTEND_STEP ))
      [ "$_q" -ge "$PER_SHOT_QP_EXTEND_FLOOR" ] || break
      _probe_qp "$_q" || break
      awk -v s="${score[$_q]:-0}" -v t="$target" 'BEGIN{exit !(s>=t)}' && break
    done
  fi

  # --- (#3) crossover refinement -------------------------------------------
  # VMAF-vs-QP is not monotone-smooth; probe +/-N QP around the current
  # highest-QP-meeting-target so a real RD inversion (an adjacent QP that is
  # both higher-VMAF and fewer-bytes) is caught and the allocator gets a
  # denser curve where its lambda lands.
  if [ "${PER_SHOT_QP_CROSSOVER_PROBES:-0}" -gt 0 ]; then
    local _center="" _ccv="" _d _c
    for qp in $(printf '%s\n' "${!score[@]}" | sort -n); do
      awk -v s="${score[$qp]}" -v t="$target" 'BEGIN{exit !(s>=t)}' && _center="$qp"
    done
    if [ -z "$_center" ]; then
      for qp in $(printf '%s\n' "${!score[@]}" | sort -n); do
        if [ -z "$_ccv" ] || awk -v s="${score[$qp]}" -v c="$_ccv" 'BEGIN{exit !(s>c)}'; then
          _center="$qp"; _ccv="${score[$qp]}"
        fi
      done
    fi
    if [ -n "$_center" ]; then
      for _d in $(seq 1 "$PER_SHOT_QP_CROSSOVER_PROBES"); do
        # `[ range ] && _probe_qp || true` conflated "out of range" with
        # "probe failed" -- an encode failure looked like a skip. Split them:
        # only probe when in range, and let a probe failure be non-fatal but
        # visible.
        _c=$(( _center - _d ))
        if [ "$_c" -ge "$PER_SHOT_QP_EXTEND_FLOOR" ]; then
          _probe_qp "$_c" || warn "per-shot crossover probe qp=$_c failed (non-fatal)"
        fi
        _c=$(( _center + _d ))
        if [ "$_c" -le "$PER_SHOT_QP_EXTEND_CEIL" ]; then
          _probe_qp "$_c" || warn "per-shot crossover probe qp=$_c failed (non-fatal)"
        fi
      done
    fi
  fi

  local best="" bv="" closest="" cv=""
  for qp in $(printf '%s\n' "${!score[@]}" | sort -n); do
    if awk -v s="${score[$qp]}" -v t="$target" 'BEGIN{exit !(s>=t)}'; then
      # Highest QP (fewest bits) that still meets target -- keep overwriting
      # as qp increases since we sort ascending.
      best="$qp"; bv="${score[$qp]}"
    fi
    if [ -z "$cv" ] || awk -v s="${score[$qp]}" -v c="$cv" 'BEGIN{exit !(s>c)}'; then
      closest="$qp"; cv="${score[$qp]}"
    fi
  done
  if [ -z "$best" ]; then
    # No sampled QP reached target -- same "return the best real
    # measurement, don't discard it for a disconnected static fallback"
    # reasoning as vmaf_crf_search_internal's own 2026-08-16 fix.
    best="$closest"; bv="$cv"
  fi
  [ -n "$best" ] || return 1

  # Multi-window byte de-bias: anchor the whole RD-sample byte scale to ONE
  # real full-shot encode at the chosen QP, then rescale every sample's bytes
  # by the same ratio (curve SHAPE from the windows, byte MAGNITUDE from the
  # real encode). Keeps the allocator's baseline + solve honest for long
  # shots without a full-shot encode per probe.
  if [ "${SHOT_MW_ACTIVE:-0}" = "1" ] && [ "${SHOT_MW_DEBIAS:-1}" = "1" ] \
     && declare -F _shot_encode_bytes_only >/dev/null 2>&1 && [ -n "${bytes[$best]:-}" ]; then
    local _realb
    _realb="$(_shot_encode_bytes_only "$src" "$start" "$end" "$best" "$codec" "$profile" 2>/dev/null)"
    if [[ "$_realb" =~ ^[0-9]+$ ]] && [ "$_realb" -gt 0 ] && [ "${bytes[$best]:-0}" -gt 0 ]; then
      local _ratio; _ratio="$(awk -v r="$_realb" -v w="${bytes[$best]}" 'BEGIN{printf "%.6f", r/w}')"
      log_err "  per-shot mw byte de-bias shot=${start}-${end} qp=$best window=${bytes[$best]} real=$_realb ratio=$_ratio"
      local _i _q _v _b
      for _i in "${!LAST_SHOT_SEARCH_SAMPLES[@]}"; do
        IFS=: read -r _q _v _b <<<"${LAST_SHOT_SEARCH_SAMPLES[$_i]}"
        [[ "$_b" =~ ^[0-9]+$ ]] || continue
        LAST_SHOT_SEARCH_SAMPLES[$_i]="${_q}:${_v}:$(awk -v b="$_b" -v r="$_ratio" 'BEGIN{printf "%d", b*r}')"
      done
      bytes[$best]="$_realb"
    fi
  fi
  # 3rd field: every (qp,vmaf,bytes) sample this search actually probed,
  # comma-joined -- feeds the Phase 6.1 equal-slope allocator. Printed
  # here (not via a global) because every real caller invokes this
  # function through $(...) command substitution, which forks a subshell;
  # a global set inside that subshell never reaches the caller (found
  # live 2026-08-25: LAST_SHOT_SEARCH_SAMPLES was silently always empty in
  # every caller despite being populated correctly inside this function).
  # Callers must parse 3 whitespace-separated fields (e.g. `read -r qp
  # vmaf samples <<<"$result"`), not the old first/last-field shortcut.
  local IFS=,
  printf '%s %s %s' "$best" "$bv" "${LAST_SHOT_SEARCH_SAMPLES[*]}"
}

# Orchestrates the full per-shot search for one title and writes a
# per-frame qpfile (one QP integer per line, one line per frame, matching
# SvtAv1EncApp's --qpfile format) ready for a single continuous encode.
# Real cost: one bounded QP search per shot (up to ~6 short sample
# encodes each) -- meaningfully more total work than the single whole-
# file search, by design (this is the "order of magnitude more encode
# passes" the original plan explicitly anticipated), which is why this is
# meant to run distributed across fleet verifier-tier idle time, not
# stacked onto one machine's encoder-tier work.
build_per_shot_qpfile() {
  local src="$1" codec="$2" profile="$3" qpfile_out="$4"
  local dur fps_rate fps_num fps_den fps target model
  local -a bounds=()
  local ts qp_result qp shot_start shot_end total_frames frame

  dur="$(video_duration "$src")" || return 1
  fps_rate="$("${FFPROBE_CMD[@]}" -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 -- "$src" 2>/dev/null)"
  fps_num="${fps_rate%/*}"; fps_den="${fps_rate#*/}"
  fps="$(awk -v n="$fps_num" -v d="$fps_den" 'BEGIN{printf "%.6f", n/d}')"
  target="$(vmaf_target_for_source "$src")" || return 1
  model="$(vmaf_model_for_source "$src")"

  bounds=("0.0")
  while IFS= read -r ts; do
    [ -n "$ts" ] && bounds+=("$ts")
  done < <(scene_detect_boundaries "$src")
  bounds+=("$dur")

  local -a shot_qps=()
  local i n=$(( ${#bounds[@]} - 1 ))
  for ((i = 0; i < n; i++)); do
    shot_start="${bounds[$i]}"
    shot_end="${bounds[$((i+1))]}"
    qp_result="$(resolve_per_shot_qp "$src" "$shot_start" "$shot_end" "$codec" "$target" "$model" "$profile")"
    if [ -n "$qp_result" ]; then
      qp="${qp_result%% *}"
    else
      qp="$(fixed_crf_for "$codec" "$profile" false)"
      warn "Per-shot QP search failed for shot $i ($shot_start-$shot_end) -- falling back to fixed $qp"
    fi
    shot_qps+=("$shot_start:$shot_end:$qp")
  done

  total_frames="$(awk -v d="$dur" -v f="$fps" 'BEGIN{printf "%d", d*f + 1}')"
  _write_shot_qps_to_qpfile shot_qps "$total_frames" "$fps" "$qpfile_out"
  log "Per-shot QP search: ${#shot_qps[@]} shots, qpfile written to $qpfile_out ($total_frames frames)"
}

# Expands a "start:end:qp" array (one entry per shot, in order) into a
# per-frame qpfile -- shared by both the single-machine path above
# (build_per_shot_qpfile) and the distributed manifest path below
# (assemble_qpfile_from_shot_manifest), so the two never drift apart on
# how frame timestamps map to shots.
_write_shot_qps_to_qpfile() {
  local -n _shots_ref="$1"
  local total_frames="$2" fps="$3" qpfile_out="$4"
  local si=0 t qp frame shot_end_check
  : >"$qpfile_out"
  for ((frame = 0; frame < total_frames; frame++)); do
    t="$(awk -v fr="$frame" -v f="$fps" 'BEGIN{printf "%.6f", fr/f}')"
    while [ "$si" -lt $(( ${#_shots_ref[@]} - 1 )) ]; do
      shot_end_check="${_shots_ref[$si]#*:}"; shot_end_check="${shot_end_check%%:*}"
      awk -v t="$t" -v e="$shot_end_check" 'BEGIN{exit !(t>=e)}' && si=$((si+1)) || break
    done
    qp="${_shots_ref[$si]##*:}"
    printf '%s\n' "$qp" >>"$qpfile_out"
  done
}

# ---------------------------------------------------------------------
# Distributed shot-search coordination -- reuses ves-chunk-coordinator.sh's
# exact proven atomic-claim primitives (mkdir-lock, mv-based stale
# reclaim) at shot granularity, so any idle fleet machine can claim and
# search individual shots for a title in parallel, independent of which
# machine will eventually own that title's final continuous encode. This
# is the fleet-distribution half of Phase 6: the expensive part (up to
# ~6 short sample-encode+VMAF passes per shot, confirmed live 2026-08-24
# to take several minutes per shot even on simple content) is what needs
# spreading across the fleet's idle capacity, not the final encode itself
# (which stays a single continuous pass per work-unit, same as Layer 1).
# ---------------------------------------------------------------------

# Directory holding one title's shot-search manifest + per-shot status
# files. Sibling to chunk_manifest_dir()'s own <title>.chunks convention.
shot_manifest_dir() {
  local src="$1"
  # Phase B (2026-09-04): the per-shot manifest + status live under the source's
  # <base>_WORKING/shots/ folder (see working_dir_for_source in ves-organize.sh),
  # not a <canonical_title>.shots sibling. A worker keeps its in-flight copy on
  # LOCAL disk (SHOT_MANIFEST_DIR_LOCAL) and rsyncs each completed shot-NNN.status
  # back here; unset = operate directly on this NAS path (coordinator, migration).
  if [ -n "${SHOT_MANIFEST_DIR_LOCAL:-}" ]; then
    printf '%s' "$SHOT_MANIFEST_DIR_LOCAL"; return 0
  fi
  if declare -F working_dir_for_source >/dev/null 2>&1; then
    printf '%s/shots' "$(working_dir_for_source "$src")"; return 0
  fi
  # pre-Phase-B fallback (module load order / callers without ves-organize.sh)
  printf '%s/%s.shots' "$(media_content_dir "$src")" "$(canonical_title_from_source "$src")"
}

# NAS-side manifest dir (never the local override) -- for the sync-back target
# and the coordinator's read-back.
shot_manifest_dir_nas() {
  local src="$1"
  if declare -F working_dir_for_source >/dev/null 2>&1; then
    printf '%s/shots' "$(working_dir_for_source "$src")"; return 0
  fi
  printf '%s/%s.shots' "$(media_content_dir "$src")" "$(canonical_title_from_source "$src")"
}

# Epoch mtime of a path (file or dir), or empty. Tries both stat dialects
# regardless of $PLATFORM (fleet workers frequently run with PLATFORM=unknown)
# then a python3 fallback. Used for stale-lock age in shot_claim_next().
_shot_path_mtime() {
  local p="$1"
  [ -e "$p" ] || return 1
  stat -c '%Y' -- "$p" 2>/dev/null && return 0
  stat -f '%m' -- "$p" 2>/dev/null && return 0
  python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$p" 2>/dev/null && return 0
  return 1
}

# Runs scene_detect_boundaries() ONCE (the expensive full-decode pass) and
# writes one shot-NNN.meta file per shot (start_ts/end_ts) plus
# manifest.meta (codec/profile/target/model, resolved once so every
# machine searching a shot for this title uses identical search
# parameters). Idempotent via the same .complete-written-last convention
# chunk_split_create_manifest() uses -- a second machine racing to split
# the same title just walks away once it sees mkdir fail.
shot_split_create_manifest() {
  local src="$1" codec="$2" profile="$3"
  local mdir tmpdir dur target model n=0 prev="0.0" ts
  mdir="$(shot_manifest_dir "$src")"
  [ -f "$mdir/.complete" ] && return 0
  # Ensure the <base>_WORKING/ parent exists. The working-set migration
  # (dval_migrate_working.sh / prestage) normally creates it, but a title
  # that reaches the per-shot search without that step (e.g. added straight
  # to the D-val survey TITLES array) would otherwise fail here forever:
  # `mkdir -- "$mdir"` has no -p, so with the parent absent it returns 1,
  # the census sees 0 shots, and searchwalk quarantines the title after 3
  # "FELL SHORT (meta=0)" rounds. Found live 2026-09-06: the 60-title survey
  # expansion mass-quarantined (17 titles in 3h) for exactly this. `mkdir -p`
  # on the PARENT only -- the `mkdir -- "$mdir"` below stays the atomic
  # build-claim.
  mkdir -p -- "$(dirname -- "$mdir")" 2>/dev/null || true
  if ! mkdir -- "$mdir" 2>/dev/null; then
    # Stale-build reclaim: mkdir is the atomic claim, but a builder that
    # crashes or is killed mid-scan (this is a full-file scene-detect
    # decode pass, can run well past 10min on a long episode) never
    # writes .complete, leaving an empty mdir that silently blocks every
    # future attempt forever. Found live 2026-08-27: a killed foreground
    # run left exactly this state and permanently return-1'd this
    # A manifest build (scene-detect decode only, no encoding) is far
    # faster than a per-shot search, so it keeps the tighter 1800s ceiling
    # rather than shot_claim_next()'s multi-hour SHOT_SEARCH_STALE_SECS --
    # incomplete past 30min is almost certainly a dead builder.
    local mdir_age
    mdir_age=$(( $(date +%s) - $(stat -c%Y -- "$mdir" 2>/dev/null || stat -f%m -- "$mdir" 2>/dev/null || echo 0) ))
    if [ -d "$mdir" ] && [ ! -f "$mdir/.complete" ] && [ "$mdir_age" -gt 1800 ]; then
      rm -rf -- "$mdir" 2>/dev/null
      mkdir -- "$mdir" 2>/dev/null || return 1
    else
      return 1
    fi
  fi
  chmod 0777 -- "$mdir" 2>/dev/null || true
  tmpdir="$(mktemp -d "${mdir}.build.XXXXXX")" || { rmdir -- "$mdir" 2>/dev/null; return 1; }

  dur="$(video_duration "$src")" || { rm -rf -- "$tmpdir"; rmdir -- "$mdir" 2>/dev/null; return 1; }
  target="$(vmaf_target_for_source "$src")" || { rm -rf -- "$tmpdir"; rmdir -- "$mdir" 2>/dev/null; return 1; }
  model="$(vmaf_model_for_source "$src")"

  # Guard: scene_detect_boundaries() must actually be available and must
  # actually find cuts. Found live 2026-08-28: on a fleet host missing
  # modules/ves-scene-detect.sh the function was simply "command not
  # found", the process substitution below yielded nothing, and this
  # function happily wrote a single whole-file "shot" + .complete and
  # returned 0 -- a bogus manifest that every downstream consumer then
  # trusted. A real episode has dozens-to-hundreds of cuts; a 1-shot
  # result for anything longer than a couple of minutes is a detection
  # failure, not a real answer.
  if ! command -v scene_detect_boundaries >/dev/null 2>&1 && ! declare -F scene_detect_boundaries >/dev/null 2>&1; then
    err "scene_detect_boundaries() unavailable (ves-scene-detect.sh not loaded?) -- cannot build manifest for $src"
    rm -rf -- "$tmpdir"; rmdir -- "$mdir" 2>/dev/null; return 1
  fi
  local _boundaries _nb=0 _cx_stats="" _cx_out=""
  # Per-shot complexity piggyback: scene_detect_boundaries() fans its single
  # decode to a signalstats+entropy branch when handed a stats path. The raw
  # per-frame file is LOCAL + transient (can be 10s of MB); only the small
  # aggregated per-shot table lands in the manifest. Best-effort -- a failure
  # here leaves the cx_* fields empty, nothing downstream hard-depends on them.
  if [ "${SHOT_COMPLEXITY_ENABLE:-true}" != "false" ]; then
    _cx_stats="$(mktemp "${RAMDISK_JOB_DIR:-${TMPDIR:-/tmp}}/ves-cxstats-XXXXXX" 2>/dev/null)" || _cx_stats=""
  fi
  _boundaries="$(scene_detect_boundaries "$src" "${SCENE_DETECT_THRESHOLD:-0.3}" "$_cx_stats")" || {
    err "scene_detect_boundaries() failed for $src"
    [ -n "$_cx_stats" ] && rm -f -- "$_cx_stats"
    rm -rf -- "$tmpdir"; rmdir -- "$mdir" 2>/dev/null; return 1
  }
  # idx -> "luma motion detail sat"  (raw stats file kept until after the meta
  # loop -- _shot_long_windows() re-reads it per long shot for window placement)
  local -A _CX=()
  if [ -n "$_cx_stats" ] && [ -s "$_cx_stats" ] && declare -F _shot_complexity_table >/dev/null 2>&1; then
    local _ci _cl _cm _cd _cs
    while read -r _ci _cl _cm _cd _cs; do
      [ -n "$_ci" ] && _CX[$_ci]="$_cl $_cm $_cd $_cs"
    done < <(_shot_complexity_table "$_cx_stats" "$_boundaries" 2>/dev/null)
  fi

  local _long_secs="${SHOT_LONG_SECS:-45}" _mw_len="${PER_SHOT_MW_LEN:-8}"
  _write_shot_cx() {  # <idx> <start_ts> <end_ts> -> appends cx_* lines to stdout
    local c="${_CX[$1]:-}" _sdur _win
    if [ -n "$c" ]; then
      set -- "$1" "$2" "$3" $c   # $4..$7 = luma motion detail sat
      printf 'cx_luma=%s\ncx_motion=%s\ncx_detail=%s\ncx_sat=%s\n' "$4" "$5" "$6" "$7"
      set -- "$1" "$2" "$3"
    fi
    # content-driven multi-window offsets for a LONG shot
    _sdur="$(awk -v a="$2" -v b="$3" 'BEGIN{d=b-a; if(d<0)d=0; printf "%.3f", d}')"
    if [ -n "$_cx_stats" ] && [ -s "$_cx_stats" ] \
       && awk -v d="$_sdur" -v l="$_long_secs" 'BEGIN{exit !(d+0 > l+0)}' \
       && declare -F _shot_long_windows >/dev/null 2>&1; then
      _win="$(_shot_long_windows "$_cx_stats" "$2" "$3" "$_mw_len" 2>/dev/null)"
      [ -n "$_win" ] && printf 'cx_windows=%s\n' "$_win"
    fi
  }

  while IFS= read -r ts; do
    [ -n "$ts" ] || continue
    { cat <<EOF
index=$n
start_ts=$prev
end_ts=$ts
EOF
      _write_shot_cx "$n" "$prev" "$ts"
    } >"${tmpdir}/shot-$(printf '%03d' "$n").meta"
    n=$((n + 1)); _nb=$((_nb + 1))
    prev="$ts"
  done <<EOF
$_boundaries
EOF
  # No cuts found at all for a non-trivial runtime -> detection is broken
  # (missing decoder, wrong ffmpeg, unreadable file). Refuse rather than
  # emit a 1-shot manifest.
  if [ "$_nb" -eq 0 ] && awk -v d="$dur" 'BEGIN{exit !(d+0 > 180)}'; then
    err "scene_detect_boundaries() found 0 cuts in a ${dur}s file -- refusing bogus 1-shot manifest for $src"
    rm -rf -- "$tmpdir"; rmdir -- "$mdir" 2>/dev/null; return 1
  fi
  # Final shot runs from the last detected cut to the real end of the file.
  { cat <<EOF
index=$n
start_ts=$prev
end_ts=$dur
EOF
    _write_shot_cx "$n" "$prev" "$dur"
  } >"${tmpdir}/shot-$(printf '%03d' "$n").meta"
  n=$((n + 1))
  [ -n "$_cx_stats" ] && rm -f -- "$_cx_stats"

  # Field mode (progressive/telecine/interlaced/ambiguous) + B&W, resolved once
  # so every search worker uses the same VMAF-stride decision (stride only when
  # progressive -- telecine/interlace/ambiguous/unknown alias under frame
  # subsampling). detect_source_traits() is a read-only idet probe, cached.
  # Skipped entirely when nothing that needs it is enabled (keeps a
  # fully-disabled Phase-1 config a true no-op).
  local _fm="unknown" _bw="0" _st _need_traits=0
  { [ "${PER_SHOT_VMAF_STRIDE:-2}" -gt 1 ] 2>/dev/null || [ "${SHOT_COMPLEXITY_ENABLE:-true}" != "false" ] \
      || [ "${PER_SHOT_MULTIWINDOW_ENABLE:-true}" != "false" ]; } && _need_traits=1
  if [ "$_need_traits" = 1 ] && declare -F detect_source_traits >/dev/null 2>&1; then
    _st="$(detect_source_traits "$src" 2>/dev/null)" || _st=""
    [[ "$_st" =~ field_mode=([a-z]+) ]] && _fm="${BASH_REMATCH[1]}"
    [[ "$_st" =~ is_bw=([01]) ]] && _bw="${BASH_REMATCH[1]}"
  fi

  cat >"${tmpdir}/manifest.meta" <<EOF
source=$src
shot_count=$n
codec=$codec
profile=$profile
target=$target
model=$model
field_mode=$_fm
is_bw=$_bw
created_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
created_host=$(hostname 2>/dev/null || echo unknown)
EOF

  local f
  for f in "$tmpdir"/*; do
    mv -f -- "$f" "$mdir/$(basename -- "$f")"
  done
  rmdir -- "$tmpdir" 2>/dev/null
  : >"$mdir/.complete"
  log "Shot split: $n shot(s) created for $(basename -- "$src")"
  return 0
}

# Claims one not-yet-searched shot for $src. Prints the claimed shot index
# on stdout and returns 0, or returns 1 if none are available (caller
# should move on, same contract as chunk_claim_next()). Identical
# mkdir-lock + mv-based-stale-reclaim shape -- see chunk_claim_next()'s
# own comments for why. Staleness ceiling = SHOT_SEARCH_STALE_SECS (default
# 25200s / 7h, ves-config.sh): a single shot's bounded QP search is minutes
# on short 1080p content but can genuinely run hours on 4K, heavy grain, or
# a long uninterrupted take (many candidate encodes + full VMAF each), so
# the ceiling is set well above the worst legitimate case -- past it, the
# owner is almost certainly dead. shot_search_worker_loop's idle timeout is
# kept above this so a live worker is always around to do the reclaim.

# Self-healing retry gate (2026-09-04): a search_failed=1 shot was being
# treated as permanently done -- shot_claim_next() skipped it forever (it IS
# status=resolved) and _shot_manifest_all_resolved_at() counted it as
# complete, so every worker (including ones a stalled-90min relaunch spun up
# fresh) saw "manifest fully resolved" and exited without ever retrying it.
# A transient cause (one host under heavy unrelated load at that moment --
# see project_dval_coordinator_migration_2026_09_04) then wedges a title
# forever with no human-visible signal beyond a stale watchdog alert that
# nothing acts on. True only for a resolved-but-failed shot that hasn't used
# up its retry budget -- i.e. "not really done yet, still claimable".
SHOT_SEARCH_RETRY_CAP="${SHOT_SEARCH_RETRY_CAP:-2}"
_shot_status_retriable() {
  local sfile="$1" st sf rc
  [ -f "$sfile" ] || return 1
  st="$(awk -F= '/^status=/{print $2; exit}' "$sfile" 2>/dev/null)"
  [ "$st" = "resolved" ] || return 1
  sf="$(awk -F= '/^search_failed=/{print $2; exit}' "$sfile" 2>/dev/null)"
  [ "$sf" = "1" ] || return 1
  rc="$(awk -F= '/^retry_count=/{print $2; exit}' "$sfile" 2>/dev/null)"
  [[ "$rc" =~ ^[0-9]+$ ]] || rc=0
  [ "$rc" -lt "$SHOT_SEARCH_RETRY_CAP" ]
}
# True (skip-claiming) only once a shot has REAL data or has exhausted its
# retry budget -- mirrors the old "status=resolved" gate but no longer treats
# a fresh search_failed as permanent.
_shot_status_claim_done() {
  local sfile="$1" st
  [ -f "$sfile" ] || return 1
  st="$(awk -F= '/^status=/{print $2; exit}' "$sfile" 2>/dev/null)"
  [ "$st" = "resolved" ] || return 1
  _shot_status_retriable "$sfile" && return 1
  return 0
}
# True if any shot in the manifest is resolved-but-failed with retry budget
# left -- the worker-loop's "truly nothing left to do" exit gate must stay
# false while this is true, or a relaunch just spins up workers that
# immediately re-exit on the same stale "fully resolved" read.
shot_manifest_has_retriable_failures() {
  local mdir="$1" f
  for f in "$mdir"/shot-*.status; do
    [ -e "$f" ] || continue
    _shot_status_retriable "$f" && return 0
  done
  return 1
}

shot_claim_next() {
  local src="$1" this_host
  local mdir f idx lockdir status_file reclaim_name
  mdir="$(shot_manifest_dir "$src")"
  [ -f "$mdir/.complete" ] || return 1
  this_host="$(hostname 2>/dev/null || echo unknown)"
  # shot_lock_path retired (Phase B) -- recompute the legacy NFS lock path here
  # so the non-survey pipeline (no VES_CLAIM_CMD) still works.
  _legacy_lock_path() {
    local d t
    d="$(media_content_dir "$1")"
    t="$(canonical_title_from_source "$1" 2>/dev/null)" || t="$(basename -- "$1")"
    printf '%s/%s.shot%s' "$d" "$t" "$2"
  }

  # Phase B (2026-09-04): when a lease backend is configured (survey: redis on
  # the coordinator with an SSH fallback), delegate. VES_CLAIM_CMD is a command
  # that takes  <slug> <idx> <host>  and prints OK / TAKEN. Falls through to the
  # NFS dir-lock below only when no backend is set (the non-survey pipeline,
  # until redis is proven fleet-wide).
  if [ -n "${VES_CLAIM_CMD:-}" ]; then
    local _slug _st _r _nasdir _nas_sf
    _slug="$(basename -- "$src" | tr -c 'A-Za-z0-9._-' '_')"
    _nasdir="$(shot_manifest_dir_nas "$src")"
    for f in "$mdir"/shot-*.meta; do
      [ -e "$f" ] || continue
      idx="$(awk -F= '/^index=/{print $2; exit}' "$f")"
      status_file="$mdir/shot-$(printf '%03d' "$idx").status"
      _shot_status_claim_done "$status_file" && continue
      if [ "$mdir" != "$_nasdir" ]; then
        _nas_sf="$_nasdir/shot-$(printf '%03d' "$idx").status"
        [ -f "$_nas_sf" ] && _shot_status_claim_done "$_nas_sf" && continue
      fi
      : "${VES_CLAIM_OWNER:=$this_host:$$}"
      _r="$($VES_CLAIM_CMD "$_slug" "$idx" "$VES_CLAIM_OWNER" 2>/dev/null)"
      [ "$_r" = "OK" ]   && { printf '%s' "$idx"; return 0; }
      [ "$_r" = "WAIT" ] && return 2      # redis unreachable -- loop should pause, not exit
    done
    return 1
  fi

  for f in "$mdir"/shot-*.meta; do
    [ -e "$f" ] || continue
    idx="$(awk -F= '/^index=/{print $2; exit}' "$f")"
    status_file="$mdir/shot-$(printf '%03d' "$idx").status"
    _shot_status_claim_done "$status_file" && continue
    lockdir="$(_legacy_lock_path "$src" "$idx").lock"
    if mkdir -- "$lockdir" 2>/dev/null; then
      cat >"${lockdir}/owner.meta" <<EOF
host=$this_host
pid=$$
claimed_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
      printf '%s' "$idx"
      return 0
    fi
    local owner_meta age mtime now
    owner_meta="${lockdir}/owner.meta"
    # Lock age from owner.meta's mtime, falling back to the lockdir's own
    # mtime -- the claiming mkdir sets it and nothing rewrites it during a
    # search, so it's a faithful claim-time marker even when owner.meta is
    # missing or unreadable (a dead worker that never got to write it, or an
    # NFS idmap that hides it). Only skip the staleness check if BOTH are
    # unavailable, which means the lock is already gone.
    mtime="$(_shot_path_mtime "$owner_meta")"
    [ -n "$mtime" ] || mtime="$(_shot_path_mtime "$lockdir")"
    now="$(date +%s)"
    if [ -n "$mtime" ]; then age=$(( now - mtime )); else age=0; fi
    if [ -n "$mtime" ] && [ "$age" -gt "${SHOT_SEARCH_STALE_SECS:-25200}" ]; then
      # Steal it: rename aside (needs only parent-dir write -- works across
      # this NFS's root-squash idmap, where rm of a foreign-owned owner.meta
      # gets EPERM), then re-create. A renamed orphan that rm can't remove is
      # harmless -- it no longer matches the *.lock glob.
      reclaim_name="${lockdir}.stale.${this_host}.$$.$RANDOM"
      if mv -- "$lockdir" "$reclaim_name" 2>/dev/null; then
        rm -rf -- "$reclaim_name" 2>/dev/null || true
        if mkdir -- "$lockdir" 2>/dev/null; then
          cat >"${lockdir}/owner.meta" <<EOF
host=$this_host
pid=$$
claimed_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
          printf '%s' "$idx"
          return 0
        fi
      fi
    fi
  done
  return 1
}

shot_release_claim() {
  local src="$1" idx="$2"
  if [ -n "${VES_CLAIM_RELEASE_CMD:-}" ]; then
    local _slug _owner
    _slug="$(basename -- "$src" | tr -c 'A-Za-z0-9._-' '_')"
    _owner="${VES_CLAIM_OWNER:-$(hostname 2>/dev/null || echo '?'):$$}"
    # owner token passed so the backend only frees a lease WE still hold --
    # a lease that expired mid-search and was re-taken by a peer is left alone.
    $VES_CLAIM_RELEASE_CMD "$_slug" "$idx" "$_owner" 2>/dev/null || true
    return 0
  fi
  # legacy dir-lock (path recomputed inline -- shot_lock_path retired Phase B)
  local dir title
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src" 2>/dev/null)" || title="$(basename -- "$src")"
  rm -rf -- "$dir/$title.shot$idx.lock" 2>/dev/null || true
}

# One fleet worker: claim -> search -> release, looping until the manifest is
# fully resolved or genuinely stuck. Key difference from a naive
# `while idx=$(claim); do ...; done`: an empty claim does NOT end the worker
# while shots are still unresolved -- it sleeps and retries. A worker must
# stay alive past SHOT_SEARCH_STALE_SECS so it can reclaim a lock stranded by
# a peer that dropped mid-search (seen 2026-08-30: JJACKSON fell offline
# holding 10 shots, every other worker had already exited, search wedged at
# 215/225 with nothing alive to run the reclaim). Gives up only after
# max_idle_secs of no claimable work with shots still outstanding.
# Sweep this host's per-shot / VMAF scratch that no live process is touching.
# _vmaf_score_shot already rm -rf's its own tmpdir on every normal and error
# exit -- this only mops up `kill -9` / OOM orphans between shots so a long
# run can't accrete multi-GB ffv1/y4m junk in tmpfs (2026-08-28 wave). The
# system-level fleet-scratch-reaper is the backstop; this keeps it tidy in
# the common case without waiting for the 10-min timer.
_shot_scratch_sweep() {
  local base="${RAMDISK_JOB_DIR:-${TMPDIR:-/tmp}}" d age
  # Only the SIGKILL-orphan case -- _vmaf_score_shot rm -rf's its own dir on
  # every normal/error exit. A LIVE shot search legitimately runs for hours
  # (grain / 4K / long takes) and its scratch can sit write-quiet during a
  # long VMAF read, so a short mtime window would delete a sibling worker's
  # in-flight scratch on a multi-worker host. Gate on the same staleness
  # ceiling as a dead lock (SHOT_SEARCH_STALE_SECS): a scratch dir older than
  # that with nothing recently touched is a dead worker's. The 10-min
  # system fleet-scratch-reaper (with its own busy-detection) covers the
  # in-between window.
  local ceil="${SHOT_SEARCH_STALE_SECS:-25200}"
  for d in "$base"/ves-shotqp-* "$base"/ves-crf-* "$base"/ves-vmaf-* "$base"/ves-oldenh-*; do
    [ -e "$d" ] || continue
    age="$(_shot_path_mtime "$d")"; [ -n "$age" ] || continue
    [ "$(( $(date +%s) - age ))" -gt "$ceil" ] || continue
    [ -n "$(find "$d" -mmin -60 -print -quit 2>/dev/null)" ] && continue
    command -v fuser >/dev/null 2>&1 && fuser -s -- "$d" 2>/dev/null && continue
    rm -rf -- "$d" 2>/dev/null && echo "shot-search: swept dead-worker scratch $d"
  done
}

shot_search_worker_loop() {
  local src="$1" max_shots="${2:-99999}"
  # Idle ceiling MUST exceed SHOT_SEARCH_STALE_SECS (default 25200s / 7h) or a
  # worker gives up long before a dead peer's lock becomes reclaimable, and
  # the search wedges again (the v6.0.0Y failure). Default = stale ceiling +
  # a couple retry intervals so at least one worker is guaranteed alive to
  # perform the reclaim.
  local retry_wait="${SHOT_SEARCH_RETRY_WAIT:-60}"
  local max_idle_secs="${3:-$(( ${SHOT_SEARCH_STALE_SECS:-25200} + retry_wait * 3 ))}"
  local count=0 idle=0 idx rc claim_rc _slug _hbpid sync_rc
  _slug="$(basename -- "$src" | tr -c 'A-Za-z0-9._-' '_')"
  # Phase B: with a redis lease backend, dead claims free at the lease TTL
  # (VES_CLAIM_TTL, 2700s) + the reaper -- but the idle ceiling MUST still
  # exceed the TTL so at least one live worker is around when a dead claim
  # frees (else all idle workers exit and nothing reclaims -- review HIGH #8).
  if [ -n "${VES_CLAIM_CMD:-}" ]; then
    max_idle_secs="${3:-$(( ${VES_CLAIM_TTL:-2700} + retry_wait * 10 ))}"
    # while this worker holds a shot, refresh the lease every ~10 min so a
    # genuinely long (4K / grain / long take) search can't lose its claim.
    : "${VES_CLAIM_OWNER:=$(hostname 2>/dev/null || echo '?'):$$}"
    # $_wl_pid = the worker-loop shell. If it dies (incl. SIGKILL, which skips
    # every trap -- dval_research.sh stops nodes with `pkill -9`), the bg
    # heartbeat is reparented to init and would EXPIRE the lease forever,
    # making it immortal. Bail the instant the parent is gone.
    local _wl_pid=$$
    _dval_hb_bg() { while :; do sleep 600; kill -0 "$_wl_pid" 2>/dev/null || exit 0
      declare -F dval_heartbeat >/dev/null 2>&1 \
      && dval_heartbeat "$_slug" "$1" "$VES_CLAIM_OWNER" || exit 0; done; }
  fi
  _shot_scratch_sweep
  while [ "$count" -lt "$max_shots" ]; do
    idx="$(shot_claim_next "$src")"; claim_rc=$?
    if [ "$claim_rc" -eq 2 ]; then
      warn "shot-search: claim backend unreachable -- pausing ${retry_wait}s"
      sleep "$retry_wait"; continue
    fi
    if [ -n "$idx" ]; then
      idle=0
      echo "claimed shot $idx"
      _hbpid=""
      if [ -n "${VES_CLAIM_CMD:-}" ]; then _dval_hb_bg "$idx" & _hbpid=$!; fi
      # Phase B: don't let shot_search_claimed release the lease on success --
      # the loop releases AFTER the status has landed on the NAS (review CRIT #1).
      SHOT_CLAIM_DEFER_RELEASE="${VES_CLAIM_CMD:+1}" shot_search_claimed "$src" "$idx"; rc=$?
      if [ "$rc" -eq 0 ]; then
        count=$((count + 1))
        if declare -F _dval_sync_status >/dev/null 2>&1; then
          # Retry the NAS push IN PLACE, heartbeat still alive so the lease
          # can't lapse under us (review CRIT #1: a bare `continue` here does
          # NOT retry -- shot_claim_next skips this now-locally-resolved idx
          # forever, and a sole worker then idles out with the title stuck).
          local _st; sync_rc=1
          for _st in 1 2 3 4 5; do
            _dval_sync_status "$src" "$idx"; sync_rc=$?
            [ "$sync_rc" -eq 0 ] && break
            warn "shot-search: shot $idx resolved, NAS status sync failed (rc=$sync_rc), attempt $_st/5 -- retrying in $((_st*30))s"
            sleep "$((_st*30))"
          done
          if [ "$sync_rc" -ne 0 ]; then
            # Permanent failure -- fail LOUD, don't gamble on the TTL. Move the
            # local resolved status aside so shot_claim_next stops skipping it,
            # release the lease so any worker (incl. this one) re-searches it,
            # and drop an ALERT for the watchdog / human.
            local _lsf _aside_ok=1
            _lsf="$(shot_manifest_dir "$src")/shot-$(printf '%03d' "$idx").status"
            if [ -f "$_lsf" ]; then
              mv -f -- "$_lsf" "${_lsf}.syncfailed.$(date +%s)" 2>/dev/null || _aside_ok=0
            fi
            if [ -n "${DVAL_SHARED_DIR:-}" ]; then
              printf '%s %s shot %s on %s: NAS status sync failed 5x -- re-queued locally\n' \
                "$(date -u +%FT%TZ)" "$_slug" "$idx" "$(hostname 2>/dev/null || echo '?')" \
                >> "$DVAL_SHARED_DIR/ALERT.status-sync-failed" 2>/dev/null || true
            fi
            if [ "$_aside_ok" -eq 1 ]; then
              # local status is out of the way -> safe to release; this or any
              # worker re-claims and re-searches the idx.
              warn "shot-search: shot $idx STATUS SYNC TO NAS FAILED 5x -- re-queued for a fresh search, releasing lease"
              declare -F shot_release_claim >/dev/null 2>&1 && shot_release_claim "$src" "$idx"
              [ -n "$_hbpid" ] && kill "$_hbpid" 2>/dev/null
            else
              # couldn't move the local resolved status -> releasing now would let
              # shot_claim_next skip this idx forever (the silent-wedge class).
              # KEEP the lease + heartbeat; the human alert above is the signal.
              warn "shot-search: shot $idx sync failed AND could not set local status aside -- KEEPING the lease, needs a human"
            fi
            _shot_scratch_sweep; continue
          fi
        fi
        echo "resolved shot $idx"
        declare -F shot_release_claim >/dev/null 2>&1 && shot_release_claim "$src" "$idx"
      else
        warn "shot-search: shot $idx did not resolve (rc=$rc) -- releasing for retry"
        declare -F shot_release_claim >/dev/null 2>&1 && shot_release_claim "$src" "$idx"
      fi
      [ -n "$_hbpid" ] && kill "$_hbpid" 2>/dev/null
      _shot_scratch_sweep
      continue
    fi
    # exit check: in Phase B the worker's LOCAL view lags the fleet -- the
    # authoritative "all resolved" is the NAS manifest. Don't exit while a
    # search_failed shot still has retry budget left -- that's what used to
    # let a transient fleet-wide hiccup wedge a title forever (every worker,
    # including a stalled-90min relaunch, saw "fully resolved" and quit).
    if [ -n "${VES_CLAIM_CMD:-}" ]; then
      if shot_manifest_all_resolved_nas "$src" \
         && ! shot_manifest_has_retriable_failures "$(shot_manifest_dir_nas "$src")"; then
        echo "shot-search: manifest fully resolved (NAS)"; break
      fi
    else
      if shot_manifest_all_resolved "$src" \
         && ! shot_manifest_has_retriable_failures "$(shot_manifest_dir "$src")"; then
        echo "shot-search: manifest fully resolved"; break
      fi
    fi
    idle=$((idle + retry_wait))
    if [ "$idle" -ge "$max_idle_secs" ]; then
      warn "shot-search: ${max_idle_secs}s idle with shots still unresolved -- giving up on $(hostname 2>/dev/null || echo '?')"
      break
    fi
    echo "shot-search: nothing claimable, ${idle}s/${max_idle_secs}s idle -- retry in ${retry_wait}s"
    sleep "$retry_wait"
  done
  echo "shot-search worker done: processed $count shots"
}

# Runs resolve_per_shot_qp() for one already-claimed shot and records the
# result. Callers (any idle fleet machine) loop: shot_claim_next -> this
# -> shot_release_claim, same shape as the chunk encoder loop.
shot_search_claimed() {
  local src="$1" idx="$2"
  local mdir shot_meta start_ts end_ts codec profile target model result qp vmaf status_file tmp
  mdir="$(shot_manifest_dir "$src")"
  shot_meta="$mdir/shot-$(printf '%03d' "$idx").meta"
  [ -f "$shot_meta" ] || { shot_release_claim "$src" "$idx"; return 1; }

  # Re-check status now that we actually hold the lock. shot_claim_next()'s
  # own pre-claim check can be fooled by NFS attribute-cache staleness (this
  # fleet's shared media mount uses actimeo=1800 -- up to 30 minutes before a
  # client re-validates cached directory/file state against the server), so
  # two machines can both see an already-resolved shot as unresolved and both
  # attempt to claim it. The mkdir a moment ago in shot_claim_next() was
  # itself a write requiring a fresh server round-trip, which makes a
  # same-process read immediately after it far more likely to be fresh than
  # the read that drove the original claim decision. This doesn't make the
  # check airtight (still a cache, still possibly stale), but it's a cheap
  # real reduction in wasted duplicate search work. Found live 2026-08-24:
  # Sting redundantly re-searched 3 shots MJACKSON had already resolved.
  status_file="$mdir/shot-$(printf '%03d' "$idx").status"
  # Bail early only if truly done (real data, or a failed shot with no retry
  # budget left) -- a retriable search_failed=1 falls through to re-search.
  if _shot_status_claim_done "$status_file"; then
    shot_release_claim "$src" "$idx"
    return 0
  fi
  local _prior_retry_count=0
  if [ -f "$status_file" ]; then
    _prior_retry_count="$(awk -F= '/^retry_count=/{print $2; exit}' "$status_file" 2>/dev/null)"
    [[ "$_prior_retry_count" =~ ^[0-9]+$ ]] || _prior_retry_count=0
  fi
  start_ts="$(awk -F= '/^start_ts=/{print $2; exit}' "$shot_meta")"
  end_ts="$(awk -F= '/^end_ts=/{print $2; exit}' "$shot_meta")"
  codec="$(awk -F= '/^codec=/{print $2; exit}' "$mdir/manifest.meta")"
  profile="$(awk -F= '/^profile=/{print $2; exit}' "$mdir/manifest.meta")"
  target="$(awk -F= '/^target=/{print $2; exit}' "$mdir/manifest.meta")"
  # substr(...,index(...)+1), not $2 -- model's own value contains a
  # literal "=" (e.g. "version=vmaf_v0.6.1neg"), and -F= splits on every
  # "=" in the line, so a plain $2 silently truncates it to "version".
  # Found live 2026-08-24: this exact truncation broke every shot search
  # on MJACKSON (invalid libvmaf model= argument -> every ffmpeg call
  # failed -> every shot fell back to the static fixed-QP default).
  model="$(awk -F= '/^model=/{print substr($0,index($0,"=")+1); exit}' "$mdir/manifest.meta")"
  # UHD flag for the per-shot timeout curve + the 1080p VMAF proxy. Derived
  # from the manifest model string (vmaf_4k => the title was fingerprinted UHD
  # upstream by _source_is_uhd) so no extra ffprobe per shot. 2026-09-05.
  case "$model" in *vmaf_4k*) export SHOT_IS_UHD=1;; *) export SHOT_IS_UHD=0;; esac

  # Per-title / per-shot search modifiers, resolved from the manifest here so
  # resolve_per_shot_qp() + _vmaf_score_shot() stay signature-stable:
  #  - SHOT_FIELD_MODE drives the VMAF frame-stride decision
  #  - SHOT_MW_ACTIVE / SHOT_MW_OFFSETS drive the long-shot multi-window path
  local _fieldmode _cxwin _sdur
  _fieldmode="$(awk -F= '/^field_mode=/{print $2; exit}' "$mdir/manifest.meta")"
  export SHOT_FIELD_MODE="${_fieldmode:-unknown}"
  unset SHOT_MW_ACTIVE SHOT_MW_OFFSETS
  if [ "${PER_SHOT_MULTIWINDOW_ENABLE:-true}" = "true" ]; then
    _sdur="$(awk -v a="$start_ts" -v b="$end_ts" 'BEGIN{d=b-a; if(d<0)d=0; printf "%.3f", d}')"
    if awk -v d="$_sdur" -v l="${SHOT_LONG_SECS:-45}" 'BEGIN{exit !(d+0 > l+0)}'; then
      _cxwin="$(awk -F= '/^cx_windows=/{print $2; exit}' "$shot_meta")"
      export SHOT_MW_ACTIVE=1
      export SHOT_MW_OFFSETS="$_cxwin"        # empty => _vmaf_score_shot_mw uses even spacing
      export SHOT_MW_LEN="${PER_SHOT_MW_LEN:-8}"
    fi
  fi

  # Zero-signal single-probe path: pure black / fade / flat static carries no
  # RD calibration signal, so instead of a full ~6-probe search do ONE encode
  # at NOSIG_QP and record its REAL (qp,vmaf,bytes) -- the shot is trivial so
  # this is a couple of seconds, and it gives the allocator honest data
  # (review 2026-09-02: an empty samples= line made the allocator price these
  # by shot-count share, over-reserving budget and starving real shots).
  # Gated on a min duration so a micro-cut (whose cx_* would be unreliable
  # anyway) always takes the real search.
  local nosignal=0 _nsdur
  result=""
  _nsdur="$(awk -v a="$start_ts" -v b="$end_ts" 'BEGIN{d=b-a; if(d<0)d=0; printf "%.3f", d}')"
  if declare -F _shot_is_nosignal >/dev/null 2>&1 \
     && awk -v d="$_nsdur" -v m="${NOSIG_MIN_SECS:-0.5}" 'BEGIN{exit !(d+0 >= m+0)}' \
     && _shot_is_nosignal "$shot_meta"; then
    local _nq="${NOSIG_QP:-${PER_SHOT_QP_EXTEND_CEIL:-48}}" _nr
    _nr="$(SHOT_MW_ACTIVE=0 _vmaf_score_shot "${SHOT_SRC_LOCAL:-$src}" "$start_ts" "$end_ts" "$_nq" "$codec" "$model" "$profile" 2>/dev/null)"
    if [ -n "$_nr" ]; then
      nosignal=1
      result="$_nq ${_nr%% *} ${_nq}:${_nr%% *}:${_nr##* }"
      warn "per-shot NOSIGNAL (black/static) shot ${start_ts}-${end_ts} -> single probe qp=$_nq vmaf=${_nr%% *}"
    fi
  fi
  [ -n "$result" ] || result="$(resolve_per_shot_qp "$src" "$start_ts" "$end_ts" "$codec" "$target" "$model" "$profile")"
  local samples="" search_failed=0 bracket_edge=0 _bl _bh retry_count=0
  if [ "$nosignal" = 1 ]; then
    read -r qp vmaf samples <<<"$result"
  elif [ -n "$result" ]; then
    # 3 whitespace-separated fields (qp, vmaf, samples) -- read, not the
    # old first/last-field shortcut, since the samples field itself would
    # otherwise be mistaken for the last field (see resolve_per_shot_qp()'s
    # own header comment for why this isn't a side-channel global instead).
    read -r qp vmaf samples <<<"$result"
  else
    qp="$(fixed_crf_for "$codec" "$profile" false)"
    vmaf=""
    search_failed=1
    retry_count=$((_prior_retry_count + 1))
    warn "Shot search failed for shot $idx ($start_ts-$end_ts) on $(hostname 2>/dev/null) -- falling back to fixed qp=$qp (attempt $retry_count/$SHOT_SEARCH_RETRY_CAP retries)"
  fi

  # SCAFFOLDING (2026-09-02): record whether this shot resolved at/past its
  # per-profile QP band edge. No-op payload while PER_SHOT_QP_BRACKET_ENABLE
  # is false (band == global, edge only if qp hit the global 14/50 -- rare).
  # A real search failure is not a band-edge signal.
  if [ "$search_failed" -eq 0 ]; then
    read -r _bl _bh <<<"$(_per_shot_qp_bracket_for "$profile")"
    bracket_edge="$(_shot_status_bracket_edge "$qp" "$_bl" "$_bh")"
  fi

  status_file="$mdir/shot-$(printf '%03d' "$idx").status"
  tmp="$(mktemp "${status_file}.XXXXXX" 2>/dev/null)" || { shot_release_claim "$src" "$idx"; return 1; }
  {
    printf 'status=resolved\n'
    printf 'qp=%s\n' "$qp"
    printf 'vmaf=%s\n' "$vmaf"
    printf 'samples=%s\n' "$samples"
    # 1 when resolve_per_shot_qp() returned nothing and we blind-fell-back
    # to a fixed QP -- the shot has no real rate/VMAF data. Kept as a
    # resolved status (don't block the pipeline) but marked so the
    # allocator and credits detection can tell it apart from a real result.
    printf 'search_failed=%s\n' "$search_failed"
    # How many times this shot has failed search and fallen back to fixed
    # QP. shot_claim_next() lets a worker re-claim a search_failed shot
    # while this is below SHOT_SEARCH_RETRY_CAP -- past the cap it's
    # accepted as permanent fallback noise (the existing bracket-health /
    # allocator tolerance for a few % of shots already assumes this).
    printf 'retry_count=%s\n' "$retry_count"
    # 1 = deliberate zero-signal skip (black/fade/flat static): fixed QP, no
    # search. Distinct from a real search_failed -- the coverage gate counts
    # nosignal shots as accounted-for.
    printf 'nosignal=%s\n' "$nosignal"
    # SCAFFOLDING: 1 if this shot's resolved QP sat at/past its per-profile
    # search band edge (band unfit for this shot). Title-level guard (TODO,
    # searchwalk) re-runs a title wide when >PER_SHOT_QP_BRACKET_EDGE_FAIL_PCT
    # of its real shots carry bracket_edge=1.
    printf 'bracket_edge=%s\n' "$bracket_edge"
    printf 'searched_host=%s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf 'searched_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } >"$tmp" || { rm -f -- "$tmp"; shot_release_claim "$src" "$idx"; return 1; }
  mv -f -- "$tmp" "$status_file" || { rm -f -- "$tmp"; shot_release_claim "$src" "$idx"; return 1; }
  _restore_default_file_mode "$status_file"
  grep -q '^status=resolved' "$status_file" 2>/dev/null || { shot_release_claim "$src" "$idx"; return 1; }
  # Phase B (review CRIT #1): the caller releases AFTER the status lands on the
  # NAS. SHOT_CLAIM_DEFER_RELEASE is set by shot_search_worker_loop in that mode.
  [ -n "${SHOT_CLAIM_DEFER_RELEASE:-}" ] || shot_release_claim "$src" "$idx"
  return 0
}

# True if every shot in the manifest has a resolved status -- the signal
# that a title is ready for assemble_qpfile_from_shot_manifest().
shot_manifest_all_resolved() {
  _shot_manifest_all_resolved_at "$(shot_manifest_dir "$1")"
}
# Same check against the NAS manifest regardless of any SHOT_MANIFEST_DIR_LOCAL
# override -- the authoritative "title is fully searched" gate for the worker
# loop's exit and for coordinator/encode readiness (review HIGH).
shot_manifest_all_resolved_nas() {
  _shot_manifest_all_resolved_at "$(shot_manifest_dir_nas "$1")"
}
_shot_manifest_all_resolved_at() {
  local mdir="$1" f idx status_file st
  [ -f "$mdir/.complete" ] || return 1
  for f in "$mdir"/shot-*.meta; do
    [ -e "$f" ] || continue
    idx="$(awk -F= '/^index=/{print $2; exit}' "$f")"
    status_file="$mdir/shot-$(printf '%03d' "$idx").status"
    [ -f "$status_file" ] || return 1
    st="$(awk -F= '/^status=/{print $2; exit}' "$status_file" 2>/dev/null)"
    [ "$st" = "resolved" ] || return 1
  done
  return 0
}

# SCAFFOLDING (2026-09-02) -- per-profile QP bracket health for one title.
# Counts real (search_failed=0) shots whose bracket_edge=1 -- i.e. that
# resolved at/past their per-profile search band. Echoes "<edge> <real> <pct>";
# returns 0 if pct <= PER_SHOT_QP_BRACKET_EDGE_FAIL_PCT (band fit or bracket
# disabled), 1 if the band was too tight for this title and it should be
# re-searched wide (PER_SHOT_QP_BRACKET_ENABLE=false).
# NOT yet wired -- searchwalk should call this after a title reaches
# all-resolved and, on return 1, wipe + re-search with the flag off.
shot_manifest_bracket_health() {
  local src="$1" mdir f edge=0 real=0 pct=0 lim
  mdir="$(shot_manifest_dir "$src")"
  lim="${PER_SHOT_QP_BRACKET_EDGE_FAIL_PCT:-5}"
  for f in "$mdir"/shot-*.status; do
    [ -e "$f" ] || continue
    grep -q '^search_failed=0' "$f" 2>/dev/null || continue
    grep -q '^vmaf=[0-9]' "$f" 2>/dev/null || continue
    real=$((real + 1))
    grep -q '^bracket_edge=1' "$f" 2>/dev/null && edge=$((edge + 1))
  done
  [ "$real" -gt 0 ] && pct=$(( edge * 100 / real ))
  printf '%s %s %s' "$edge" "$real" "$pct"
  [ "${PER_SHOT_QP_BRACKET_ENABLE:-false}" = "true" ] || return 0
  [ "$pct" -le "$lim" ]
}

# Reads every shot's resolved QP from the manifest (all shot_manifest_
# all_resolved() must already be true) and writes the final per-frame
# qpfile -- the step whichever machine owns the final continuous encode
# for this title runs once, after the distributed search across the
# fleet has finished. Mirrors build_per_shot_qpfile()'s own frame-
# expansion exactly via the shared _write_shot_qps_to_qpfile() helper.
assemble_qpfile_from_shot_manifest() {
  local src="$1" qpfile_out="$2"
  local mdir f idx start_ts end_ts qp dur fps_rate fps_num fps_den fps total_frames
  local -a shot_qps=()
  mdir="$(shot_manifest_dir "$src")"
  shot_manifest_all_resolved "$src" || return 1

  for f in "$mdir"/shot-*.meta; do
    [ -e "$f" ] || continue
    idx="$(awk -F= '/^index=/{print $2; exit}' "$f")"
    start_ts="$(awk -F= '/^start_ts=/{print $2; exit}' "$f")"
    end_ts="$(awk -F= '/^end_ts=/{print $2; exit}' "$f")"
    qp="$(awk -F= '/^qp=/{print $2; exit}' "$mdir/shot-$(printf '%03d' "$idx").status")"
    shot_qps[$idx]="$start_ts:$end_ts:$qp"
  done

  dur="$(video_duration "$src")" || return 1
  fps_rate="$("${FFPROBE_CMD[@]}" -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 -- "$src" 2>/dev/null)"
  fps_num="${fps_rate%/*}"; fps_den="${fps_rate#*/}"
  fps="$(awk -v n="$fps_num" -v d="$fps_den" 'BEGIN{printf "%.6f", n/d}')"
  total_frames="$(awk -v d="$dur" -v f="$fps" 'BEGIN{printf "%d", d*f + 1}')"

  _write_shot_qps_to_qpfile shot_qps "$total_frames" "$fps" "$qpfile_out"
  log "Assembled qpfile from shot manifest: ${#shot_qps[@]} shots, $qpfile_out ($total_frames frames)"
}

# Phase 6.1 (docs/DESIGN-6x-chunk-redesign.md): equal-slope global bit
# allocation, an alternative to assemble_qpfile_from_shot_manifest()'s
# "every shot independently picks the QP that meets the same fixed target"
# policy. Instead: given a global shadow price (lambda) for one more byte,
# every shot independently picks whichever of ITS OWN already-probed
# samples maximizes (vmaf - lambda*bytes) -- the standard Lagrangian
# relaxation of "maximize quality subject to a bit budget", here solved in
# the dual direction (find the lambda whose resulting duration-weighted
# mean VMAF lands at the target) via bisection on log(lambda), mirroring
# vmaf_crf_search_internal()'s own bisection shape.
#
# No new encodes: reuses the (qp,vmaf,bytes) samples resolve_per_shot_qp()
# already produced and shot_search_claimed() now persists in each shot's
# status file (`samples=`). At any fixed lambda, the per-shot optimum is
# provably just argmax over that shot's own samples -- no explicit convex-
# hull construction needed, since a dominated (non-hull) sample can never
# win that argmax for any lambda, so hull-filtering happens for free.
#
# REAL POLICY CHANGE from assemble_qpfile_from_shot_manifest(): individual
# shots are no longer guaranteed to hit the target -- only the duration-
# weighted whole-title average is. "No quality regression" today is
# enforced per-shot; this relaxes it to per-title-average, trading some
# hard-shot quality for cheap-shot bit savings. Not shipped as the default
# path -- call explicitly, compare against assemble_qpfile_from_shot_
# manifest()'s output, and get real user sign-off before switching.
assemble_qpfile_via_equal_slope() {
  local src="$1" qpfile_out="$2" target="$3"
  local mdir f idx start_ts end_ts dur fps_rate fps_num fps_den fps total_frames
  local -a shot_qps=()
  mdir="$(shot_manifest_dir "$src")"
  shot_manifest_all_resolved "$src" || return 1

  local samples_flat durations_flat
  samples_flat="$(mktemp)" || return 1
  durations_flat="$(mktemp)" || { rm -f "$samples_flat"; return 1; }
  local -A shot_start=() shot_end=()
  # Shots whose search produced no real samples at all (a total search
  # failure that fell back to a fixed QP -- see shot_search_claimed()) --
  # there is no rate-distortion curve to optimize over, so these are kept
  # OUT of the lambda bisection entirely (excluded from both the weighted-
  # mean numerator and its duration denominator) and merged back in
  # afterward using their own already-recorded fallback QP. Found live
  # 2026-08-25: leaving such a shot out of durations_flat but still in
  # dur[] via awk's "for (idx in dur)" silently treated its VMAF as 0 in
  # the weighted mean (awk's uninitialized-array-read default), badly
  # understating the true achievable mean and making the bisection
  # converge somewhere meaningless.
  local -a no_sample_idx=()

  for f in "$mdir"/shot-*.meta; do
    [ -e "$f" ] || continue
    idx="$(awk -F= '/^index=/{print $2; exit}' "$f")"
    start_ts="$(awk -F= '/^start_ts=/{print $2; exit}' "$f")"
    end_ts="$(awk -F= '/^end_ts=/{print $2; exit}' "$f")"
    shot_start[$idx]="$start_ts"; shot_end[$idx]="$end_ts"
    local status_file samples_line
    status_file="$mdir/shot-$(printf '%03d' "$idx").status"
    samples_line="$(awk -F= '/^samples=/{print substr($0,index($0,"=")+1); exit}' "$status_file")"
    local _valid=0
    : >"$samples_flat.tmp"
    if [ -n "$samples_line" ]; then
      local IFS=,; local -a parts=($samples_line); unset IFS
      local p
      for p in "${parts[@]}"; do
        [ -n "$p" ] || continue
        local IFS=:; local -a triple=($p); unset IFS
        { [ "${#triple[@]}" -eq 3 ] && [[ "${triple[0]}${triple[1]}${triple[2]}" =~ [0-9] ]]; } || continue
        printf '%s %s %s %s\n' "$idx" "${triple[0]}" "${triple[1]}" "${triple[2]}" >>"$samples_flat.tmp"
        _valid=$((_valid + 1))
      done
    fi
    # empty OR non-empty-but-unparseable -> fixed-QP fallback shot, not a
    # hole in the qpfile (a shot in durations_flat with no sample rows gets
    # no pick from the solve and would be dropped from the output).
    if [ "$_valid" -eq 0 ]; then
      no_sample_idx+=("$idx"); rm -f "$samples_flat.tmp"; continue
    fi
    printf '%s %s %s\n' "$idx" "$start_ts" "$end_ts" >>"$durations_flat"
    cat "$samples_flat.tmp" >>"$samples_flat"; rm -f "$samples_flat.tmp"
  done

  local qp_lines
  qp_lines="$(awk -v target="$target" -v durations_file="$durations_flat" '
    BEGIN {
      while ((getline line < durations_file) > 0) {
        split(line, a, " ")
        d = a[3] - a[2]; if (d < 0) d = 0
        dur[a[1]] = d
        total_dur += d
      }
      close(durations_file)
    }
    { n++; sidx[n]=$1; sqp[n]=$2; svmaf[n]=$3; sbytes[n]=$4 }
    END {
      if (total_dur <= 0 || n == 0) { exit 1 }
      lo = 1e-10; hi = 1e-1
      for (iter = 0; iter < 50; iter++) {
        lambda = exp((log(lo) + log(hi)) / 2)
        for (idx in dur) has_best[idx] = 0
        for (i = 1; i <= n; i++) {
          idx = sidx[i]
          obj = svmaf[i] - lambda * sbytes[i]
          if (!has_best[idx] || obj > best_obj[idx]) {
            has_best[idx] = 1; best_obj[idx] = obj
            best_qp[idx] = sqp[i]; best_vmaf[idx] = svmaf[i]
          }
        }
        wsum = 0
        for (idx in dur) wsum += best_vmaf[idx] * dur[idx]
        mean_vmaf = wsum / total_dur
        if (mean_vmaf > target) { lo = lambda } else { hi = lambda }
      }
      printf "LAMBDA=%.10g FINAL_MEAN_VMAF=%.4f\n", lambda, mean_vmaf > "/dev/stderr"
      for (idx in best_qp) printf "%s %s %s\n", idx, best_qp[idx], best_vmaf[idx]
    }
  ' "$samples_flat")" || { rm -f "$samples_flat" "$durations_flat"; return 1; }
  rm -f "$samples_flat" "$durations_flat"

  local line
  while IFS=' ' read -r idx qp vmaf; do
    [ -n "$idx" ] || continue
    shot_qps[$idx]="${shot_start[$idx]}:${shot_end[$idx]}:$qp"
  done <<<"$qp_lines"

  # Merge back in the shots excluded from the lambda bisection above --
  # their own already-recorded fallback QP, unchanged (nothing to optimize
  # without real samples).
  local ni
  for ni in "${no_sample_idx[@]}"; do
    local fallback_qp
    fallback_qp="$(awk -F= '/^qp=/{print substr($0,index($0,"=")+1); exit}' "$mdir/shot-$(printf '%03d' "$ni").status")"
    shot_qps[$ni]="${shot_start[$ni]}:${shot_end[$ni]}:$fallback_qp"
  done

  dur="$(video_duration "$src")" || return 1
  fps_rate="$("${FFPROBE_CMD[@]}" -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 -- "$src" 2>/dev/null)"
  fps_num="${fps_rate%/*}"; fps_den="${fps_rate#*/}"
  fps="$(awk -v n="$fps_num" -v d="$fps_den" 'BEGIN{printf "%.6f", n/d}')"
  total_frames="$(awk -v d="$dur" -v f="$fps" 'BEGIN{printf "%d", d*f + 1}')"

  _write_shot_qps_to_qpfile shot_qps "$total_frames" "$fps" "$qpfile_out"
  log "Assembled qpfile via equal-slope allocation: ${#shot_qps[@]} shots, $qpfile_out ($total_frames frames)"
}

# Same equal-slope mechanism as assemble_qpfile_via_equal_slope() above,
# but bisecting lambda against a TOTAL BYTE BUDGET instead of a target mean
# VMAF. Found live 2026-08-25 (real user pushback, both anime and Reacher
# test episodes): a mean-VMAF target that isn't reachable by any shot
# combination in the isolated search data forces the bisection to its
# floor -- lambda->0, i.e. "spend maximum on every shot" -- which never
# exercises the actual redistribution the allocator exists for (taking
# bits from shots that don't need them, giving them to shots that do). A
# byte budget doesn't have that failure mode: it's always achievable (the
# search range's own min/max bytes bound it), so the bisection is
# guaranteed to find a real, non-degenerate lambda that genuinely
# discriminates between easy and hard shots. This is also the more
# faithful match to Netflix's own actual formulation (a fixed bit budget,
# not a target quality average -- see Phase 6.1 in docs/DESIGN-6x-chunk-
# redesign.md) and directly answers the real question this allocator is
# for: given about the same bits standard already spends, can they be
# redistributed for a better result (higher floor on hard shots) instead
# of a higher average?

# Phase 6.2 (2026-08-26), first increment: detect a plausible end-credits
# segment via the file's own last chapter marker. Checked against real
# files in this library first (Discovery/Reacher/one anime title): none
# carry semantic chapter names ("Chapter 01", not "Credits"), but the
# boundaries themselves are real structural cuts -- Reacher's last
# chapter starts at 50:59 in a ~55min episode, a plausible credits-length
# remainder. Gate on a plausible duration (30s-5min) so a short final
# SCENE (not credits) doesn't get misclassified and starved. Prints
# "start end" (seconds) on stdout if a plausible range is found; prints
# nothing and returns 1 otherwise -- callers must treat "not detected" as
# "don't deprioritize anything", never guess.
#
# Deliberately NOT attempting opening-titles detection here -- explicit
# user direction 2026-08-26 (Star Trek Lower Decks example: real story,
# then intro, then back to story, cold-open length varies per episode)
# ruled out any fixed-position/duration heuristic for that case. The
# right tool is cross-episode audio fingerprinting (the same mechanism
# Jellyfin's Intro Skipper / Plex's own intro detection use, both built
# on Chromaprint -- confirmed already present on this machine as
# /usr/bin/fpcalc + a python chromaprint binding). That's real, separate
# work (needs a handful of episodes of the same show to compare against,
# not a single-file heuristic) -- queued as the next Phase 6.2 increment,
# not built yet.
detect_credits_range() {
  local src="$1"
  local dur last_start last_dur
  dur="$(video_duration "$src")" || return 1
  local chap_starts
  chap_starts="$(run_ffprobe -v error -show_chapters -show_entries chapter=start_time -of csv=p=0 -- "$src" 2>/dev/null)"
  if [ -n "$chap_starts" ]; then
    last_start="$(printf '%s\n' "$chap_starts" | tail -1 | cut -d, -f1)"
    if [[ "$last_start" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      last_dur="$(awk -v d="$dur" -v s="$last_start" 'BEGIN{print d-s}')"
      if awk -v d="$last_dur" 'BEGIN{exit !(d>=30 && d<=300)}'; then
        printf '%s %s\n' "$last_start" "$dur"
        return 0
      fi
    fi
  fi
  # No byte-cost fallback: retired 2026-08-30 after the American + Discovery +
  # British/Japanese survey (~30 titles, exactly one chaptered file) showed
  # (a) the library is effectively chapterless so this path almost never
  # fires, and (b) credits that roll over live-action / animation carry no
  # low-byte signature at all -- 4 of 5 J-drama titles missed with a
  # perfectly clean per-shot search (0 failed shots). There is no reliable
  # byte-only credits signal. The equal-slope allocator's smooth position
  # weight (ves-config.sh section C) now carries the "head/tail is lower
  # viewer value" prior instead, letting the allocator decide from real RD
  # data rather than a guessed range. Chapter-marker detection above stays.
  return 1
}

assemble_qpfile_via_equal_slope_budget() {
  local src="$1" qpfile_out="$2" byte_budget="$3"
  local deprio_start="${4:-}" deprio_end="${5:-}" deprio_weight="${6:-1.0}"
  local mdir f idx start_ts end_ts dur fps_rate fps_num fps_den fps total_frames
  local -a shot_qps=()
  # always the NAS manifest -- this runs on the encode node / coordinator, never
  # against a search worker's partial local copy (review HIGH).
  mdir="$(shot_manifest_dir_nas "$src")"
  shot_manifest_all_resolved_nas "$src" || return 1

  # (#1) per-shot VMAF floor: no shot below (target - drop). target is the
  # same per-source figure the per-shot search aimed at.
  local _pst_target _floor_drop _pin_rounds
  _pst_target="$(vmaf_target_for_source "$src" 2>/dev/null)" || _pst_target=94
  # guard empty stdout (unknown profile / empty VMAF_TARGET_*), not just rc
  [[ "$_pst_target" =~ ^[0-9]+(\.[0-9]+)?$ ]] || _pst_target=94
  _floor_drop="${ALLOC_MIN_SHOT_VMAF_DROP:-0}"
  _pin_rounds="${ALLOC_MIN_SHOT_PIN_ROUNDS:-4}"

  # --- budget interpretation --------------------------------------------------
  # The per-shot search encodes each shot as an ISOLATED clip (cold keyframe,
  # no cross-shot temporal prediction, per-clip AQ statistics). The continuous
  # full-file encode of the SAME qpfile comes out systematically LARGER --
  # measured k = actual/estimated = 1.07-1.14 on Discovery S01E02 (higher when
  # #1 pins more hard shots to low QP). So an ABSOLUTE byte target handed to
  # the lambda bisection (which only sees sample bytes) produces a file ~13%
  # over target. Two ways to give a meaningful budget:
  #
  #   * a FRACTION (0 < x <= 4): budget = x * baseline, where baseline is the
  #     sample-byte sum of the pure per-shot-target qpfile (the same estimator,
  #     so k cancels in the ratio -- actual(frac)/actual(1.0) ~= frac). This
  #     is the robust default and matches the archived budget90/95 runs.
  #   * an ABSOLUTE byte count (> 4): divided by ALLOC_BYTES_CALIBRATION_K
  #     before the solve so the *final encode* lands near the target.
  local _cal_k _budget_mode="absolute"
  _cal_k="${ALLOC_BYTES_CALIBRATION_K:-1.0}"
  if awk -v b="$byte_budget" 'BEGIN{exit !(b+0 > 0 && b+0 <= 4)}'; then
    _budget_mode="fraction"
    local _baseline _frac="$byte_budget"
    local _pst_num; _pst_num="$(awk -v x="$_pst_target" 'BEGIN{printf "%.4f", x+0}')"
    # Per-shot baseline = the smallest file that meets the shot's VMAF target.
    # FALLBACK (shot cannot reach target at any probed QP): price it at the most
    # aggressive quality the equal-slope solver may actually drive it to --
    #   floor ON  (drop>0): highest QP still clearing target-drop
    #   floor OFF (drop==0): highest QP available (the solver has no per-shot floor)
    # The old code priced every hard shot at its max-VMAF / qp-min / max-bytes
    # sample, over-counting them and skewing the fraction baseline (A Few Moments:
    # baseline vs CRF base wildly off -> BUDGET_UNREACHABLE -> f90=f80=f70=f60
    # byte-identical). Only when even the drop-floor is unreachable do we fall to
    # the shot's best-effort (max-VMAF) sample.
    _baseline="$(for st in "$mdir"/shot-*.status; do
      awk -F= -v pst="$_pst_num" -v drop="${_floor_drop:-0}" '/^samples=/{
        line=substr($0,index($0,"=")+1); nf=split(line,a,","); best=-1; bb=0
        for(i=1;i<=nf;i++){ n=split(a[i],t,":"); if(n==3 && t[2]+0 >= pst && t[1]+0 > best){best=t[1]+0; bb=t[3]+0} }
        if(best<0){
          if(drop+0 > 0){
            flr=pst-drop; fb=-1
            for(i=1;i<=nf;i++){ n=split(a[i],t,":"); if(n==3 && t[2]+0 >= flr && t[1]+0 > fb){fb=t[1]+0; bb=t[3]+0} }
            if(fb<0){ bv=-1; for(i=1;i<=nf;i++){ n=split(a[i],t,":"); if(n==3 && t[2]+0 > bv){bv=t[2]+0; bb=t[3]+0} } }
          } else {
            hq=-1
            for(i=1;i<=nf;i++){ n=split(a[i],t,":"); if(n==3 && t[1]+0 > hq){hq=t[1]+0; bb=t[3]+0} }
          }
        }
        print bb
      }' "$st"
    done | awk '{s+=$1} END{printf "%.0f", s+0}')"
    # Physical floor = sum of each shot's SMALLEST sample (highest QP the search
    # probed). The solver can never spend less than this. If the fallback above
    # under-priced hard shots and pushed _baseline below the floor, the whole
    # fraction sweep would collapse to the minimum (review MEDIUM: under-count).
    # Clamp up + note it.
    local _floor_sum
    _floor_sum="$(for st in "$mdir"/shot-*.status; do
      awk -F= '/^samples=/{ line=substr($0,index($0,"=")+1); nf=split(line,a,","); mn=-1
        for(i=1;i<=nf;i++){ n=split(a[i],t,":"); if(n==3 && (mn<0 || t[3]+0<mn)) mn=t[3]+0 }
        if(mn>=0) print mn }' "$st"
    done | awk '{s+=$1} END{printf "%.0f", s+0}')"
    if [ "${_floor_sum:-0}" -gt "${_baseline:-0}" ] 2>/dev/null; then
      log_err "  equal-slope budget: baseline ${_baseline} B < physical floor ${_floor_sum} B -- clamping up (hard-shot fallback under-priced)"
      _baseline="$_floor_sum"
    fi
    # SANITY (Option 3 safety net): a per-shot-optimal AV1 encode bigger than the
    # source, or well above the CRF base, means the search data or the VMAF
    # target is wrong for this title. Fail loud rather than emit a degenerate
    # fraction sweep. Survey caller exports ALLOC_BASELINE_SANITY_BYTES=<base>.
    local _srcbytes; _srcbytes="$(stat -c%s "$src" 2>/dev/null || echo 0)"
    if [ "${_baseline:-0}" -ge "${_srcbytes:-0}" ] 2>/dev/null && [ "${_srcbytes:-0}" -gt 0 ]; then
      log_err "  equal-slope budget: BASELINE UNFIT -- baseline ${_baseline} B >= source ${_srcbytes} B; search data / VMAF target suspect for this title. Refusing to build a fraction qpfile."
      return 2
    fi
    if [ -n "${ALLOC_BASELINE_SANITY_BYTES:-}" ] && [ "${ALLOC_BASELINE_SANITY_BYTES:-0}" -gt 0 ] 2>/dev/null; then
      local _maxr="${ALLOC_BASELINE_MAX_RATIO:-1.15}"
      if awk -v b="$_baseline" -v s="$ALLOC_BASELINE_SANITY_BYTES" -v r="$_maxr" 'BEGIN{exit !(b > s*r)}'; then
        log_err "  equal-slope budget: BASELINE UNFIT -- baseline ${_baseline} B > ${_maxr}x CRF base ${ALLOC_BASELINE_SANITY_BYTES} B; hard shots inflating the sum. Refusing to build a fraction qpfile."
        return 2
      fi
    fi
    byte_budget="$(awk -v f="$byte_budget" -v base="$_baseline" 'BEGIN{printf "%.0f", f*base}')"
    log_err "  equal-slope budget: fraction mode -> baseline=${_baseline} B (frac ${_frac}), budget=${byte_budget} B"
  else
    byte_budget="$(awk -v b="$byte_budget" -v k="$_cal_k" 'BEGIN{printf "%.0f", b / (k>0?k:1)}')"
    log_err "  equal-slope budget: absolute mode, /K=${_cal_k} -> internal budget=${byte_budget} B"
  fi

  local samples_flat durations_flat
  samples_flat="$(mktemp)" || return 1
  durations_flat="$(mktemp)" || { rm -f "$samples_flat"; return 1; }
  local -A shot_start=() shot_end=()
  local -a no_sample_idx=()

  for f in "$mdir"/shot-*.meta; do
    [ -e "$f" ] || continue
    idx="$(awk -F= '/^index=/{print $2; exit}' "$f")"
    start_ts="$(awk -F= '/^start_ts=/{print $2; exit}' "$f")"
    end_ts="$(awk -F= '/^end_ts=/{print $2; exit}' "$f")"
    shot_start[$idx]="$start_ts"; shot_end[$idx]="$end_ts"
    local status_file samples_line
    status_file="$mdir/shot-$(printf '%03d' "$idx").status"
    samples_line="$(awk -F= '/^samples=/{print substr($0,index($0,"=")+1); exit}' "$status_file")"
    local _valid=0
    : >"$samples_flat.tmp"
    if [ -n "$samples_line" ]; then
      local IFS=,; local -a parts=($samples_line); unset IFS
      local p
      for p in "${parts[@]}"; do
        [ -n "$p" ] || continue
        local IFS=:; local -a triple=($p); unset IFS
        { [ "${#triple[@]}" -eq 3 ] && [[ "${triple[0]}${triple[1]}${triple[2]}" =~ [0-9] ]]; } || continue
        printf '%s %s %s %s\n' "$idx" "${triple[0]}" "${triple[1]}" "${triple[2]}" >>"$samples_flat.tmp"
        _valid=$((_valid + 1))
      done
    fi
    # empty OR non-empty-but-unparseable -> fixed-QP fallback shot, not a
    # hole in the qpfile (a shot in durations_flat with no sample rows gets
    # no pick from the solve and would be dropped from the output).
    if [ "$_valid" -eq 0 ]; then
      no_sample_idx+=("$idx"); rm -f "$samples_flat.tmp"; continue
    fi
    printf '%s %s %s\n' "$idx" "$start_ts" "$end_ts" >>"$durations_flat"
    cat "$samples_flat.tmp" >>"$samples_flat"; rm -f "$samples_flat.tmp"
  done

  # Reserve budget for the fixed-QP fallback shots (search_failed / no
  # sample): they are encoded but never enter the equal-slope solve, so the
  # solve would allocate the FULL budget to the solvable shots and the final
  # encode overruns. Reserve their proportional duration share.
  local _n_total="$(ls "$mdir"/shot-*.meta 2>/dev/null | wc -l)"
  local _n_fb="${#no_sample_idx[@]}"
  if [ "$_n_fb" -gt 0 ] && [ "${_n_total:-0}" -gt "$_n_fb" ]; then
    byte_budget="$(awk -v b="$byte_budget" -v nf="$_n_fb" -v nt="$_n_total" \
      'BEGIN{printf "%.0f", b * (nt - nf) / nt}')"
    log_err "  equal-slope budget: reserved for $_n_fb/$_n_total fallback shots -> solve budget=${byte_budget} B"
  fi

  local qp_lines
  qp_lines="$(awk -v budget="$byte_budget" -v durations_file="$durations_flat" \
    -v deprio_start="$deprio_start" -v deprio_end="$deprio_end" -v deprio_weight="$deprio_weight" \
    -v head_frac="$ALLOC_POS_WEIGHT_HEAD_FRAC" -v tail_frac="$ALLOC_POS_WEIGHT_TAIL_FRAC" \
    -v wmin="$ALLOC_POS_WEIGHT_MIN" \
    -v target="$_pst_target" -v floor_drop="$_floor_drop" -v pin_rounds="$_pin_rounds" '
    # (C) smooth position weight: wmin at the very edges of the file, linearly
    # up to 1.0 by head_frac / tail_frac. The allocator objective is
    #   weight[idx]*vmaf - lambda*bytes
    # so a weight < 1.0 makes the low-QP (more-bytes, higher-vmaf) samples
    # less attractive there -> allocator picks a higher QP -> fewer bytes in
    # the head/tail under a tight budget, while still choosing from real RD
    # data. wmin=1.0 disables it.
    function pos_weight(p,   w) {
      if (head_frac > 0 && p < head_frac)
        return wmin + (1.0 - wmin) * (p / head_frac)
      if (tail_frac > 0 && p > 1.0 - tail_frac)
        return wmin + (1.0 - wmin) * ((1.0 - p) / tail_frac)
      return 1.0
    }
    BEGIN {
      # Explicit deprio range (deprio_start/end) still honoured as an override
      # for callers that pass one; otherwise the smooth position weight applies.
      have_deprio = (deprio_start != "" && deprio_end != "")
      max_e = 0
      while ((getline line < durations_file) > 0) {
        split(line, a, " ")
        dur[a[1]] = 1
        shot_s[a[1]] = a[2]; shot_e[a[1]] = a[3]
        if (a[3] + 0 > max_e) max_e = a[3] + 0
      }
      close(durations_file)
      total_dur = (max_e > 0) ? max_e : 1
      for (idx in dur) {
        mid = (shot_s[idx] + shot_e[idx]) / 2
        if (have_deprio) {
          weight[idx] = (mid >= deprio_start && mid <= deprio_end) ? deprio_weight : 1.0
        } else {
          weight[idx] = pos_weight(mid / total_dur)
        }
      }
    }
    {
      n++; sidx[n]=$1; sqp[n]=$2; svmaf[n]=$3; sbytes[n]=$4
      # per-shot highest-VMAF sample -- the pick a (#1) pinned shot is forced to
      if (!($1 in maxv_v) || $3+0 > maxv_v[$1]) {
        maxv_v[$1]=$3+0; maxv_qp[$1]=$2; maxv_b[$1]=$4+0
      }
    }
    # one equal-slope pick per shot at a given lambda, honouring pinned[]
    function select_picks(lambda,   i, idx, obj) {
      for (idx in dur) has_best[idx] = 0
      for (i = 1; i <= n; i++) {
        idx = sidx[i]
        if (idx in pinned) {
          if (!has_best[idx]) {
            has_best[idx]=1
            best_qp[idx]=maxv_qp[idx]; best_vmaf[idx]=maxv_v[idx]; best_bytes[idx]=maxv_b[idx]
          }
          continue
        }
        obj = weight[idx] * svmaf[i] - lambda * sbytes[i]
        if (!has_best[idx] || obj > best_obj[idx]) {
          has_best[idx]=1; best_obj[idx]=obj
          best_qp[idx]=sqp[i]; best_vmaf[idx]=svmaf[i]; best_bytes[idx]=sbytes[i]
        }
      }
    }
    END {
      if (n == 0) { exit 1 }
      floor_v = (floor_drop + 0 > 0) ? (target + 0 - floor_drop) : -1

      # (#1) outer loop: solve the equal-slope byte budget, then pin any shot
      # the solve dropped below the VMAF floor to its best sample and re-solve
      # the budget over the rest. Position-weighted head/tail shots are exempt
      # (they exist to absorb loss). Pinning can only tighten lambda on the
      # remaining shots, so it converges in a few rounds; if the budget is so
      # tight even all-pinned overspends, we stop and just report it.
      # round 0 is the initial solve; ALLOC_MIN_SHOT_PIN_ROUNDS is the number
      # of *pin+re-solve* passes after that, hence <= (N+1 solves total).
      pin_added_total = 0
      for (round = 0; round <= (pin_rounds + 0); round++) {
        lo = 1e-12; hi = 1.0
        for (iter = 0; iter < 60; iter++) {
          lambda = exp((log(lo) + log(hi)) / 2)
          select_picks(lambda)
          total_bytes = 0
          for (idx in dur) total_bytes += best_bytes[idx]
          if (total_bytes > budget) lo = lambda; else hi = lambda
        }
        lambda = exp((log(lo) + log(hi)) / 2)
        select_picks(lambda)
        if (floor_v < 0) break
        new_pins = 0
        for (idx in dur) {
          if ((idx in pinned)) continue
          if (weight[idx] < 0.999) continue
          if (best_vmaf[idx] < floor_v && maxv_v[idx] > best_vmaf[idx] + 0.01) {
            pinned[idx] = 1; new_pins++; pin_added_total++
          }
        }
        if (new_pins == 0) break
      }

      total_bytes = 0; min_vmaf = 999; min_idx = ""; min_body_vmaf = 999; min_body_idx = ""; weighted_n = 0
      for (idx in best_vmaf) {
        total_bytes += best_bytes[idx]
        if (best_vmaf[idx] < min_vmaf) { min_vmaf = best_vmaf[idx]; min_idx = idx }
        if (weight[idx] < 0.999) {
          weighted_n++
        } else if (best_vmaf[idx] < min_body_vmaf) {
          min_body_vmaf = best_vmaf[idx]; min_body_idx = idx
        }
      }
      over_pct = (budget > 0) ? (100.0 * (total_bytes - budget) / budget) : 0
      printf "LAMBDA=%.10g TOTAL_BYTES=%d BUDGET=%d OVERSHOOT_PCT=%.1f MIN_SHOT_VMAF=%.2f (shot %s) MIN_BODY_VMAF=%.2f (shot %s) POS_WEIGHTED_SHOTS=%d FLOOR_PINNED=%d (floor %.1f)\n", lambda, total_bytes, budget, over_pct, min_vmaf, min_idx, min_body_vmaf, min_body_idx, weighted_n, pin_added_total, floor_v > "/dev/stderr"
      for (idx in best_qp) printf "%s %s %s\n", idx, best_qp[idx], best_vmaf[idx]
    }
  ' "$samples_flat" 2>"$samples_flat.rpt")" || { rm -f "$samples_flat" "$samples_flat.rpt" "$durations_flat"; return 1; }
  cat "$samples_flat.rpt" >&2
  # BUDGET_UNREACHABLE: the equal-slope solve + floor pins can overspend a
  # very tight budget (all hard shots pinned to their best sample, nothing
  # left to trade). The qpfile is still the best allocation under the floor
  # constraint, just larger than requested -- warn loudly, don't fail.
  local _ov
  _ov="$(awk '/OVERSHOOT_PCT=/{for(i=1;i<=NF;i++) if($i ~ /^OVERSHOOT_PCT=/){sub(/OVERSHOOT_PCT=/,"",$i); print $i}}' "$samples_flat.rpt")"
  if [ -n "$_ov" ] && awk -v o="$_ov" 'BEGIN{exit !(o+0 > 10)}'; then
    log_err "  equal-slope budget: BUDGET_UNREACHABLE -- solve overshoots by ${_ov}% (floor pins + tight budget); qpfile is the constrained best, not the requested size"
  fi
  rm -f "$samples_flat" "$samples_flat.rpt" "$durations_flat"

  local line
  while IFS=' ' read -r idx qp vmaf; do
    [ -n "$idx" ] || continue
    shot_qps[$idx]="${shot_start[$idx]}:${shot_end[$idx]}:$qp"
  done <<<"$qp_lines"

  local ni
  for ni in "${no_sample_idx[@]}"; do
    local fallback_qp
    fallback_qp="$(awk -F= '/^qp=/{print substr($0,index($0,"=")+1); exit}' "$mdir/shot-$(printf '%03d' "$ni").status")"
    shot_qps[$ni]="${shot_start[$ni]}:${shot_end[$ni]}:$fallback_qp"
  done

  dur="$(video_duration "$src")" || return 1
  fps_rate="$("${FFPROBE_CMD[@]}" -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 -- "$src" 2>/dev/null)"
  fps_num="${fps_rate%/*}"; fps_den="${fps_rate#*/}"
  fps="$(awk -v n="$fps_num" -v d="$fps_den" 'BEGIN{printf "%.6f", n/d}')"
  total_frames="$(awk -v d="$dur" -v f="$fps" 'BEGIN{printf "%d", d*f + 1}')"

  _write_shot_qps_to_qpfile shot_qps "$total_frames" "$fps" "$qpfile_out"
  log "Assembled qpfile via equal-slope budget allocation: ${#shot_qps[@]} shots, $qpfile_out ($total_frames frames)"
}
