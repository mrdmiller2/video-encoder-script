#!/usr/bin/env bash
# ves-qtgmc.sh -- QTGMC (VapourSynth) real field-based deinterlace as a
# pipeline pre-process stage, for confidently-detected genuine interlace
# within the vintage profile.
#
# Scope, per the approved plan (~/.claude/plans/how-can-we-chaneg-cheeky-goose.md)
# and project_qtgmc_merit_test_2026_08_07 memory: this module only runs
# QTGMC's real field-based deinterlace (classic havsfunc.py QTGMC,
# InputType=0 -- genuine bob+weave motion-compensated deinterlace on
# content with real separate fields) for the `interlaced` field_mode tier.
# It deliberately does NOT use QTGMC's InputType=2/3 "progressive repair"
# mode (the one that fixed Batman (1943)'s ringing artifact) -- that mode
# discards real lines and reconstructs them via NNEDI3 interpolation, a
# real data-fabrication concern the user explicitly kept as a separate,
# manual, human-invoked tool, not part of this auto-detect path. The
# `telecine` field_mode tier uses ffmpeg-native `fieldmatch,decimate` (IVTC)
# instead -- QTGMC is not the right tool for cadence/frame-rate correction,
# only for real per-field motion-compensated deinterlace.
#
# Toolchain is installed by fleet-tools/install-qtgmc-{fedora,ubuntu,macos}.sh
# under $HOME/qtgmc (the account actually running the encode -- normally
# `worker`) -- NOT bundled with this repo, an optional/degrade-gracefully
# tool exactly like mkvalidator or ab-av1 (see
# feedback_fleet_tool_parity_optional_tools).

QTGMC_HOME="${QTGMC_HOME:-$HOME/qtgmc}"

# Prints nothing; returns 0 if the QTGMC toolchain is fully installed and
# importable on this machine, 1 otherwise. Cheap enough to call on every
# job (no subprocess beyond a few stat calls plus one python import check,
# cached after the first call within a run).
qtgmc_available() {
  if [ -n "${_QTGMC_AVAILABLE_CACHED:-}" ]; then
    [ "$_QTGMC_AVAILABLE_CACHED" = "yes" ]
    return
  fi

  local lib="$QTGMC_HOME/lib"
  local py_bin=""
  for candidate in "$QTGMC_HOME/.local/bin/python3" python3; do
    command -v "$candidate" >/dev/null 2>&1 && { py_bin="$candidate"; break; }
  done

  if [ -z "$py_bin" ] || [ ! -f "$lib/mvtools.so" ] && [ ! -f "$lib/mvtools.dylib" ] || \
     [ ! -f "$QTGMC_HOME/havsfunc_classic.py" ]; then
    _QTGMC_AVAILABLE_CACHED=no
    return 1
  fi

  if "$py_bin" -c "
import sys, os
sys.path.insert(0, '$QTGMC_HOME')
import vapoursynth as vs
core = vs.core
# Try both extensions -- macOS installs mvtools.dylib, Linux mvtools.so.
# An earlier version of this probe only ever tried .so, so a macOS-only
# install (which the file-existence check above correctly allows) still
# failed the actual import check and cached 'unavailable' forever, forcing
# bwdif on every interlaced vintage title on macOS even with a fully
# working toolchain.
for _name in ('mvtools.so', 'mvtools.dylib'):
    _p = os.path.join('$lib', _name)
    if os.path.exists(_p):
        core.std.LoadPlugin(_p)
        break
assert hasattr(core, 'mv') or hasattr(core, 'znedi3')
import havsfunc_classic
assert hasattr(havsfunc_classic, 'QTGMC')
" >/dev/null 2>&1; then
    _QTGMC_AVAILABLE_CACHED=yes
    return 0
  fi
  _QTGMC_AVAILABLE_CACHED=no
  return 1
}

# Locates vspipe -- installed under $HOME/.local/bin by pip on Linux
# (NOT $QTGMC_HOME/.local/bin -- pip's --user installs always go to the
# real user home, regardless of QTGMC_HOME), alongside python on macOS via
# Homebrew. Deliberately does NOT fall back to a bare `command -v vspipe`:
# Fedora's `vapoursynth-tools` dnf package ships its own `/usr/sbin/vspipe`
# tied to the system-package VapourSynth (R72), which silently fails with
# "Failed to initialize VSScript" when pointed at a script that expects
# this toolchain's plugins/paths -- found empirically, not a hypothetical.
# Only ever use the specific binary this toolchain installed.
_qtgmc_vspipe_bin() {
  local candidate
  for candidate in "$HOME/.local/bin/vspipe" "/opt/homebrew/bin/vspipe"; do
    [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

# Runs QTGMC's real field-based deinterlace on $src, staged in the active
# RAM disk (never the NAS-visible tree -- same `.convert-stage-*` naming
# convention as ves-ramdisk.sh's other staging, so orphan-reaper/cleanup
# code already recognizes it), and prints the resulting lossless
# intermediate's path on success. Caller is responsible for treating that
# path as the new $src for the rest of the encode pipeline and for cleaning
# it up when done (RAM disk teardown already sweeps the whole staging dir
# on job exit via ramdisk_job_teardown, so an explicit rm is a nice-to-have
# not a requirement).
#
# Only ever call this for field_mode=interlaced -- see the module header
# for why telecine/progressive/ambiguous must never reach this function.
qtgmc_deinterlace_to_intermediate() {  # src -> prints intermediate path, or fails
  local src="$1"
  local field_order
  field_order="$(source_traits_field_order "$src")"

  qtgmc_available || { warn "QTGMC toolchain not available on this machine — falling back to bwdif for: $src"; return 1; }

  local py_bin vspipe_bin
  py_bin="$QTGMC_HOME/.local/bin/python3"
  command -v "$py_bin" >/dev/null 2>&1 || py_bin="python3"
  vspipe_bin="$(_qtgmc_vspipe_bin)"
  [ -n "$vspipe_bin" ] || { warn "vspipe not found — falling back to bwdif for: $src"; return 1; }

  # RAMDISK_JOB_DIR (not CONVERT_RAMDISK_DIR, a rarely-set user override --
  # see ves-ramdisk.sh) is the actual runtime-resolved/created per-job
  # ramdisk from ramdisk_init. Using the override var here meant this
  # multi-GB lossless intermediate fell through to plain ${TMPDIR:-/tmp}
  # on every real run: harmless on Linux (tmpfs), but on macOS that's real
  # local disk, not the /Volumes/ConvertRAMDisk this job already created,
  # and it shared neither that ramdisk's disk-budget accounting nor its
  # single-teardown lifecycle. Found during the 2026-08-19 NAS-load audit.
  local stage_dir
  stage_dir="$(mktemp -d "${RAMDISK_JOB_DIR:-${TMPDIR:-/tmp}}/.convert-stage-qtgmc-XXXXXX" 2>/dev/null)" || {
    warn "Could not create QTGMC staging dir — falling back to bwdif for: $src"
    return 1
  }

  local script="$stage_dir/qtgmc.py"
  local intermediate="$stage_dir/qtgmc-deinterlaced.mkv"
  local tff_bool="True"
  [ "$field_order" = "bff" ] && tff_bool="False"

  # Sample aspect ratio (SAR/PAR): the QTGMC intermediate is a fresh
  # VapourSynth render with no SAR tag of its own (bs.VideoSource doesn't
  # propagate the container's PAR into the raw frame, and the y4m/x264
  # write-out below doesn't add one either) -- for a genuinely anamorphic
  # source (e.g. a real 720x480/720x576 DVD-style vintage rip, non-1:1
  # SAR), that would silently reset display aspect to square pixels,
  # stretching/squishing the picture end to end. Read the real SAR from
  # $src and stamp it onto the intermediate via a `setsar` video filter so
  # the rest of the pipeline (which reads dimensions/DAR from $video_src
  # once QTGMC succeeds) sees the correct value automatically, no changes
  # needed anywhere else.
  #
  # NOT `-aspect $sar` (present in an earlier version of this script) --
  # confirmed by team review and a direct empirical test, `-aspect` sets
  # ffmpeg's *display* aspect ratio (DAR), not sample aspect ratio (SAR):
  # `-aspect 8:9` on a 720x480 frame produced sample_aspect_ratio=16:27
  # (wrong) and display_aspect_ratio=8:9, while `-vf setsar=8/9` correctly
  # produced sample_aspect_ratio=8:9 and the correct derived
  # display_aspect_ratio=4:3. This was the exact same class of bug as the
  # ChromaEdi one -- a "fix" that looked plausible and would not have
  # shown up in any duration/codec/frame-count check, only in the real
  # stored SAR/DAR values.
  local sar sar_vf_args=()
  sar="$(run_ffprobe -v error -select_streams v:0 -show_entries stream=sample_aspect_ratio -of csv=p=0 "$src" 2>/dev/null | head -1)"
  if [ -n "$sar" ] && [ "$sar" != "0:1" ] && [ "$sar" != "1:1" ] && [[ "$sar" == *:* ]]; then
    sar_vf_args=(-vf "setsar=${sar/:/\/}")
  fi

  # SRC_PATH is passed via env var (read below with plain open(), never
  # embedded in the generated script's source text) specifically so a path
  # containing a single quote (e.g. "Mickey's Vintage Short.mkv") can never
  # break out of the r'...' literal a naive shell-into-Python interpolation
  # would produce -- confirmed by team review as a real crash (Python
  # SyntaxError, not just a cosmetic issue) that would otherwise silently
  # eat the QTGMC attempt and fall back to bwdif for every such title.
  cat >"$script" <<PYEOF
import sys, os
sys.path.insert(0, '$QTGMC_HOME')
import vapoursynth as vs
core = vs.core
lib = '$QTGMC_HOME/lib'
for name in ('mvtools.so', 'mvtools.dylib', 'vsznedi3.so', 'libremovegrain.so', 'libremovegrain.dylib',
             'libmiscfilters.so', 'libmiscfilters.dylib', 'libfmtconv.so', 'libfmtconv.dylib'):
    p = os.path.join(lib, name)
    if os.path.exists(p):
        core.std.LoadPlugin(p)
import havsfunc_classic as hf
src = core.bs.VideoSource(source=os.environ['QTGMC_SRC_PATH'])
# KNOWN LIMITATION, deliberately not fixed yet: this always downconverts to
# 8-bit even when the source is genuinely >8-bit, a real fidelity loss for
# that case (team review flagged this). Every real vintage source tested
# this session (Batman 1943, Cosmos 1980 S01E10) was already 8-bit, so this
# hasn't been exercised against real >8-bit interlaced content, and a blind
# fix (switching to YUV420P10 + a 10-bit y4m/x264 intermediate) is exactly
# the kind of untested pixel-path change that hid the ChromaEdi bug above --
# do not "fix" this without real 10-bit interlaced test footage and the
# same raw-pixel-value + rendered-frame verification used for that bug.
src8 = core.resize.Bicubic(src, format=vs.YUV420P8) if src.format.bits_per_sample != 8 else src
# QTGMC's Bob() calls SeparateFields, which requires the chroma plane's
# height to be even -- i.e. luma height divisible by 4, not just 2 -- for
# 4:2:0 content. Real vintage sources hit this: a genuinely-interlaced 1980
# broadcast documentary (Cosmos S01E10) had a cropped 1412x1074 frame
# (1074/2=537, odd) and failed with "SeparateFields: clip height must be
# mod 2 in the smallest subsampled plane" every time, correctly triggering
# this module's bwdif fallback -- safe, but throwing away QTGMC's real
# quality advantage on otherwise-normal content purely over a stray pixel
# of height. Pad to the next multiple of 4 with AddBorders (duplicates the
# bottom row, no data loss on the real frame), then crop the same amount
# back off the QTGMC output before it leaves this script.
_pad_h = (4 - (src8.height % 4)) % 4
if _pad_h:
    src8 = core.std.AddBorders(src8, bottom=_pad_h)
# InputType=0: real field-based deinterlace (genuine bob+weave motion
# compensation) -- not the InputType=2/3 progressive-repair mode.
# FPSDivisor=1 (explicit, matches QTGMC's own default): full bob output,
# each real field becomes its own progressive frame, doubling the frame
# rate (e.g. 25i -> 50p). Confirmed with user 2026-08-07: this is the
# intended behavior, not an oversight -- it keeps every real field as a
# distinct temporal sample (no data discarded/blended), consistent with
# this project's #1 priority (no data loss) outranking #3 (size). The
# alternative, FPSDivisor=2, would blend bobbed frame pairs back down to
# the source's nominal rate, trading away real temporal information for a
# smaller file and unchanged cadence -- rejected.
#
# ChromaEdi='none' (present in earlier versions of this script) is a REAL
# BUG, not a stylistic choice -- confirmed by dumping raw chroma-plane
# pixel values: with it, U/V came out as wild noise (e.g. 17,96,8,96,8,97...
# instead of the correct near-flat ~127-128 for actual B&W content),
# producing a solid green-tinted, unwatchable frame end to end (verified
# visually on both Batman (1943) and Cosmos (1980) S01E10 -- present
# regardless of the mod-4 height padding above, so NOT related to that).
# Leaving ChromaEdi unset (QTGMC then mirrors EdiMode, i.e. NNEDI3 for
# chroma too) produces correct, clean chroma -- verified pixel-for-pixel
# against the untouched source's own neutral-gray chroma plane. This was
# never caught earlier in this session because every prior "successful"
# QTGMC test only checked ffprobe metadata (duration/frame count/codec) --
# never actually rendered and looked at a frame. Do not reintroduce
# ChromaEdi='none' without dumping raw plane values first.
out = hf.QTGMC(src8, Preset='Slower', InputType=0, TFF=$tff_bool, FPSDivisor=1, EdiMode='NNEDI3')
if _pad_h:
    out = core.std.Crop(out, bottom=_pad_h)
out.set_output()
PYEOF

  log_err "QTGMC real deinterlace (field_order=$field_order): $src"
  # run_tracked_encoder (unbounded, same wrapper the real encode itself
  # uses), NOT run_ffmpeg_validation -- run_ffmpeg_validation scales its
  # timeout off a real file size found via "-i <file>" or a bare filename
  # argument, but this ffmpeg call reads from a pipe ("-i -") and its
  # output file doesn't exist yet when the timeout would be calculated, so
  # the scaling logic always found nothing and fell back to the short,
  # validation-probe-sized VALIDATION_TIMEOUT_SECS base. On any real,
  # full-length content that base elapses long before the real transcode
  # finishes, and _run_timeout_retry kills it mid-write -- confirmed via
  # direct reproduction (partial 1.5GB intermediate, empty stderr log,
  # RC=1) against a real 8-minute vintage clip, 2026-08-08. This means
  # QTGMC's real deinterlace had never actually succeeded on real
  # production-length content all session; every prior "successful" test
  # used short manual clips fast enough to dodge the short timeout.
  #
  # Outer `timeout` (not just run_tracked_encoder's own PID tracking):
  # without `shopt -s lastpipe` (not set anywhere in this codebase),
  # run_tracked_encoder -- the RHS of this pipe -- executes in a subshell,
  # so ACTIVE_ENCODER_PID/the SIGINT/SIGTERM interrupt handler in the
  # parent shell can never see or kill it; this pipe was left completely
  # unbounded by the fix above, a real (if narrower) regression from the
  # bug it fixed. `timeout --kill-after` bounds the whole pipeline's own
  # process group directly, independent of that subshell/tracking gap.
  # Generously duration-scaled (not a short fixed cap) since QTGMC is
  # real, slow, motion-compensated work -- found by independent
  # multi-tool review, 2026-08-08.
  local src_dur qtgmc_timeout
  src_dur="$(video_duration "$src" 2>/dev/null)"; src_dur="${src_dur%.*}"
  case "$src_dur" in ''|*[!0-9]*) src_dur=0 ;; esac
  qtgmc_timeout=$(( 1800 + src_dur * 20 ))
  # NOT run_with_timeout (ves-timeout-retry.sh) -- that wrapper uses
  # `timeout --foreground` whenever available, which per GNU timeout's
  # own docs does NOT put the command in a new process group ("children
  # of COMMAND will not be timed out"). Confirmed directly: a
  # `--foreground --kill-after` run against `bash -c 'yes | sleep 30'`
  # left both `yes` and `sleep 30` running as orphans after the wrapper
  # was killed -- the exact bug this whole timeout fix exists to close.
  # --foreground is correct for run_with_timeout's OTHER callers (it
  # exists specifically so a timeout signal can't kill an enclosing bash
  # function's own redirected stdout/stderr), just wrong for this one, so
  # this call resolves the timeout binary itself (_timeout_cmd, same
  # macOS/gtimeout-aware resolution run_with_timeout uses) and invokes it
  # WITHOUT --foreground -- confirmed directly that plain `timeout
  # --kill-after` DOES put the command in its own process group and kills
  # the whole group (including pipe-subshell children) on timeout. Found
  # by independent multi-tool review, 2026-08-08.
  local _qtgmc_tc="" _qtgmc_rc=0 _qtgmc_has_kill_after=0
  if _timeout_cmd >/dev/null; then
    _qtgmc_tc="$_TIMEOUT_CMD_RESOLVED"
    # Probe --kill-after support (mirrors run_with_timeout's own
    # --foreground probe below) rather than assuming every resolved
    # "timeout" binary is GNU coreutils -- a non-GNU timeout on some
    # future fleet member's PATH could otherwise fail this call outright
    # before QTGMC ever runs. Found by independent multi-tool review,
    # 2026-08-08.
    "$_qtgmc_tc" --help 2>&1 | grep -q -- '--kill-after' && _qtgmc_has_kill_after=1
    local -a _qtgmc_tc_args=("$qtgmc_timeout")
    [ "$_qtgmc_has_kill_after" = 1 ] && _qtgmc_tc_args=(--kill-after=30 "$qtgmc_timeout")
    # if/then, not a bare statement -- under this script's `set -e`, a
    # bare command's nonzero exit aborts the whole script immediately
    # (same bug class the team already found once in this exact module:
    # a bare `qtgmc_intermediate="$(...)"` command-substitution
    # assignment did the same thing). Assignments/commands inside an
    # `if` condition are exempted from errexit.
    if "$_qtgmc_tc" "${_qtgmc_tc_args[@]}" bash -c \
        'QTGMC_SRC_PATH="$1" "$2" -c y4m "$3" - 2>"$4" | "${@:5}"' _ \
        "$src" "$vspipe_bin" "$script" "$stage_dir/qtgmc.log" \
        "${FFMPEG_CMD[@]}" -y -v error -i - "${sar_vf_args[@]}" -c:v libx264 -crf 0 -preset veryfast -an "$intermediate"; then
      _qtgmc_rc=0
    else
      _qtgmc_rc=$?
    fi
  else
    # No timeout/gtimeout on PATH at all. setsid (when present) gives the
    # child its own process group so a timeout here can still killpg the
    # whole pipeline (negative PID) instead of only the immediate child --
    # but setsid itself is NOT guaranteed present (confirmed absent on a
    # real fleet macOS member, MARLONJ, alongside timeout/gtimeout, before
    # `brew install coreutils` was run there) -- without this check,
    # `setsid: command not found` (exit 127) would silently degrade every
    # QTGMC run to bwdif on any machine reaching this branch. Falls back
    # further to plain backgrounding (positive PID kill only -- pipe
    # children may survive; better than crashing the fallback entirely).
    # Found by independent multi-tool review, 2026-08-08.
    local -a _qtgmc_launch=(bash -c \
        'QTGMC_SRC_PATH="$1" "$2" -c y4m "$3" - 2>"$4" | "${@:5}"' _ \
        "$src" "$vspipe_bin" "$script" "$stage_dir/qtgmc.log" \
        "${FFMPEG_CMD[@]}" -y -v error -i - "${sar_vf_args[@]}" -c:v libx264 -crf 0 -preset veryfast -an "$intermediate")
    local _qtgmc_have_setsid=0
    command -v setsid >/dev/null 2>&1 && _qtgmc_have_setsid=1
    if [ "$_qtgmc_have_setsid" = 1 ]; then
      setsid "${_qtgmc_launch[@]}" &
    else
      "${_qtgmc_launch[@]}" &
    fi
    local _qtgmc_pgid=$!
    local _qtgmc_waited=0
    while [ "$_qtgmc_waited" -lt "$qtgmc_timeout" ]; do
      kill -0 "$_qtgmc_pgid" 2>/dev/null || break
      sleep 1
      _qtgmc_waited=$((_qtgmc_waited + 1))
    done
    if kill -0 "$_qtgmc_pgid" 2>/dev/null; then
      if [ "$_qtgmc_have_setsid" = 1 ]; then
        kill -TERM -"$_qtgmc_pgid" 2>/dev/null || true
        sleep 5
        kill -KILL -"$_qtgmc_pgid" 2>/dev/null || true
      else
        kill -TERM "$_qtgmc_pgid" 2>/dev/null || true
        sleep 5
        kill -KILL "$_qtgmc_pgid" 2>/dev/null || true
      fi
    fi
    if wait "$_qtgmc_pgid" 2>/dev/null; then
      _qtgmc_rc=0
    else
      _qtgmc_rc=$?
    fi
  fi
  if [ "$_qtgmc_rc" -ne 0 ]; then
    warn "QTGMC deinterlace failed (see $stage_dir/qtgmc.log) — falling back to bwdif for: $src"
    rm -rf "$stage_dir"
    return 1
  fi

  if [ ! -s "$intermediate" ]; then
    warn "QTGMC deinterlace produced an empty output — falling back to bwdif for: $src"
    rm -rf "$stage_dir"
    return 1
  fi

  printf '%s' "$intermediate"
}
