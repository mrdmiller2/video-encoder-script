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
_shot_ffmpeg_timeout() {
  local duration="$1" base=300 per_sec=120 cap=3600
  local d_int extra scaled
  d_int="$(printf '%.0f' "$duration" 2>/dev/null)"
  case "$d_int" in ''|*[!0-9]*) d_int=0 ;; esac
  extra=$(( d_int * per_sec ))
  scaled=$(( base + extra ))
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
_vmaf_score_shot() {
  local src="$1" start="$2" end="$3" qp="$4" codec="$5" model="$6" profile="$7"
  local work clip y4m out out_mkv vlog v b enc_timeout nframes qpfile
  local -a grain_decode_flag=()
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
  run_ffmpeg_validation -y -v error -ss "$_fast_ss" -i "$src" -ss "$_acc_ss" -t "$_clip_dur" \
    -map 0:v:0 -c:v ffv1 -level 3 "$clip" 2>/dev/null || { rm -rf "$work"; return 1; }
  [ -s "$clip" ] || { rm -rf "$work"; return 1; }
  enc_timeout="$(_shot_ffmpeg_timeout "$(awk -v s="$start" -v e="$end" 'BEGIN{d=e-s; if(d<0)d=0; print d}')")"
  case "$codec" in
    av1)
      local svtp; svtp="$(profile_svt_params "$profile")" || { rm -rf "$work"; return 1; }
      y4m="$work/shot.y4m"
      run_ffmpeg_validation -y -v error -i "$clip" -map 0:v:0 -pix_fmt yuv420p10le -strict -1 "$y4m" 2>/dev/null \
        || { rm -rf "$work"; return 1; }
      nframes="$("${FFPROBE_CMD[@]}" -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$clip" 2>/dev/null)"
      [[ "$nframes" =~ ^[0-9]+$ ]] && [ "$nframes" -gt 0 ] || { rm -rf "$work"; return 1; }
      qpfile="$work/uniform-$qp.qp"
      # awk generator, not `yes | head`: under `set -o pipefail` (production
      # convert.sh) the SIGPIPE that stops `yes` makes the pipeline non-zero,
      # which aborts a bare `result="$(resolve_per_shot_qp ...)"` assignment.
      awk -v q="$qp" -v n="$nframes" 'BEGIN{ while (n-- > 0) print q }' > "$qpfile"
      out="$work/shot-enc-$qp.ivf"
      _run_timeout_retry "$enc_timeout" "${SVTAV1ENCAPP_CMD[@]}" -i "$y4m" --use-q-file 1 --qpfile "$qpfile" \
        --svtav1-params "${svtp}:rc=0" -b "$out" 2>/dev/null || { rm -rf "$work"; return 1; }
      [ -s "$out" ] || { rm -rf "$work"; return 1; }
      out_mkv="$work/shot-enc-$qp.mkv"
      run_ffmpeg_validation -y -v error -i "$out" -c copy "$out_mkv" 2>/dev/null || { rm -rf "$work"; return 1; }
      # NOT grain-stripped (was: -export_side_data film_grain). Decoding the
      # AV1 grain-free and comparing to the grainy source penalises a
      # difference that does not exist in playback (the decoder re-synthesises
      # grain), which suppressed the per-shot ceiling on grain profiles by
      # 1-3 VMAF (Conan per-shot A 91.2 vs its low-CRF base 92.6). Score
      # grain-on: synth-grain vs source-grain, which is the honest playback
      # comparison. The matched extracted clips are already frame-aligned by
      # the -ss extraction + the setpts=PTS-STARTPTS below.
      : # grain_decode_flag intentionally left empty
      ;;
    *) rm -rf "$work"; return 1 ;;
  esac
  vlog="${out}.vmaf.json"
  _run_timeout_retry "$enc_timeout" "${FFMPEG_CMD[@]}" -y -v error "${grain_decode_flag[@]}" -i "$out_mkv" -i "$clip" -lavfi \
    "[0:v]setpts=PTS-STARTPTS,format=yuv420p10le[d];[1:v]setpts=PTS-STARTPTS,format=yuv420p10le[r];[d][r]libvmaf=model=$model:n_threads=$(nproc 2>/dev/null || sysctl -n hw.ncpu):log_fmt=json:log_path=$vlog" \
    -f null - 2>/dev/null || { rm -rf "$work"; return 1; }
  v="$(python3 -c "import json;print(round(json.load(open('$vlog'))['pooled_metrics']['vmaf']['mean'],2))" 2>/dev/null)" || { rm -rf "$work"; return 1; }
  b="$(file_size_bytes "$out")"
  rm -rf "$work"
  printf '%s %s' "$v" "$b"
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

resolve_per_shot_qp() {
  local src="$1" start="$2" end="$3" codec="$4" target="$5" model="$6" profile="$7"
  local -A score=() bytes=()
  local qp above below gap
  LAST_SHOT_SEARCH_SAMPLES=()

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

  _probe_qp() {
    local q="$1" r
    [ -n "${score[$q]:-}" ] && return 0
    r="$(_vmaf_score_shot "$src" "$start" "$end" "$q" "$codec" "$model" "$profile")" || return 1
    score[$q]="${r%% *}"; bytes[$q]="${r##* }"
    LAST_SHOT_SEARCH_SAMPLES+=("${q}:${score[$q]}:${bytes[$q]}")
    log_err "  per-shot qp-search [$codec] shot=${start}-${end} qp=$q vmaf=${score[$q]}"
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
  local qp_lo="$PER_SHOT_QP_MIN" qp_hi="$PER_SHOT_QP_MAX"
  local anchors="$qp_lo 30 $qp_hi"
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
        _c=$(( _center - _d )); [ "$_c" -ge "$PER_SHOT_QP_EXTEND_FLOOR" ] && _probe_qp "$_c" 2>/dev/null || true
        _c=$(( _center + _d )); [ "$_c" -le "$PER_SHOT_QP_EXTEND_CEIL" ] && _probe_qp "$_c" 2>/dev/null || true
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
  local dir title
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src")"
  printf '%s/%s.shots' "$dir" "$title"
}

shot_lock_path() {
  local src="$1" idx="$2"
  local dir title
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src")"
  printf '%s/%s.shot%s' "$dir" "$title" "$idx"
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
  if ! mkdir -- "$mdir" 2>/dev/null; then
    # Stale-build reclaim: mkdir is the atomic claim, but a builder that
    # crashes or is killed mid-scan (this is a full-file scene-detect
    # decode pass, can run well past 10min on a long episode) never
    # writes .complete, leaving an empty mdir that silently blocks every
    # future attempt forever. Found live 2026-08-27: a killed foreground
    # run left exactly this state and permanently return-1'd this
    # function for that title. Same 1800s ceiling as shot_claim_next()'s
    # own staleness reclaim -- a manifest build still incomplete past
    # that is almost certainly a dead builder, not slow-but-alive work.
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
  local _boundaries _nb=0
  _boundaries="$(scene_detect_boundaries "$src")" || {
    err "scene_detect_boundaries() failed for $src"
    rm -rf -- "$tmpdir"; rmdir -- "$mdir" 2>/dev/null; return 1
  }
  while IFS= read -r ts; do
    [ -n "$ts" ] || continue
    cat >"${tmpdir}/shot-$(printf '%03d' "$n").meta" <<EOF
index=$n
start_ts=$prev
end_ts=$ts
EOF
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
  cat >"${tmpdir}/shot-$(printf '%03d' "$n").meta" <<EOF
index=$n
start_ts=$prev
end_ts=$dur
EOF
  n=$((n + 1))

  cat >"${tmpdir}/manifest.meta" <<EOF
source=$src
shot_count=$n
codec=$codec
profile=$profile
target=$target
model=$model
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
# own comments for why. Staleness ceiling is deliberately much shorter
# than chunk-encode's 7200s: a shot's bounded QP search (a handful of
# short sample encodes) should finish in minutes, confirmed live
# 2026-08-24 (~3-9 min for a single shot including VMAF measurement), not
# hours -- a search still "claimed" past 1800s is almost certainly a dead
# worker, not slow-but-alive work.
shot_claim_next() {
  local src="$1" this_host
  local mdir f idx lockdir status_file reclaim_name
  mdir="$(shot_manifest_dir "$src")"
  [ -f "$mdir/.complete" ] || return 1
  this_host="$(hostname 2>/dev/null || echo unknown)"

  for f in "$mdir"/shot-*.meta; do
    [ -e "$f" ] || continue
    idx="$(awk -F= '/^index=/{print $2; exit}' "$f")"
    status_file="$mdir/shot-$(printf '%03d' "$idx").status"
    if [ -f "$status_file" ]; then
      local st
      st="$(awk -F= '/^status=/{print $2; exit}' "$status_file" 2>/dev/null)"
      [ "$st" = "resolved" ] && continue
    fi
    lockdir="$(shot_lock_path "$src" "$idx").lock"
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
    if [ -n "$mtime" ] && [ "$age" -gt "${SHOT_SEARCH_STALE_SECS:-1800}" ]; then
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
  rm -rf -- "$(shot_lock_path "$src" "$idx").lock" 2>/dev/null || true
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
  local count=0 idle=0 idx rc
  _shot_scratch_sweep
  while [ "$count" -lt "$max_shots" ]; do
    idx="$(shot_claim_next "$src")"
    if [ -n "$idx" ]; then
      idle=0
      echo "claimed shot $idx"
      shot_search_claimed "$src" "$idx"; rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "resolved shot $idx"; count=$((count + 1))
      else
        warn "shot-search: shot $idx did not resolve (rc=$rc) -- will retry"
      fi
      _shot_scratch_sweep
      continue
    fi
    if shot_manifest_all_resolved "$src"; then
      echo "shot-search: manifest fully resolved"
      break
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
  if [ -f "$status_file" ]; then
    local already_st
    already_st="$(awk -F= '/^status=/{print $2; exit}' "$status_file" 2>/dev/null)"
    if [ "$already_st" = "resolved" ]; then
      shot_release_claim "$src" "$idx"
      return 0
    fi
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

  result="$(resolve_per_shot_qp "$src" "$start_ts" "$end_ts" "$codec" "$target" "$model" "$profile")"
  local samples="" search_failed=0
  if [ -n "$result" ]; then
    # 3 whitespace-separated fields (qp, vmaf, samples) -- read, not the
    # old first/last-field shortcut, since the samples field itself would
    # otherwise be mistaken for the last field (see resolve_per_shot_qp()'s
    # own header comment for why this isn't a side-channel global instead).
    read -r qp vmaf samples <<<"$result"
  else
    qp="$(fixed_crf_for "$codec" "$profile" false)"
    vmaf=""
    search_failed=1
    warn "Shot search failed for shot $idx ($start_ts-$end_ts) on $(hostname 2>/dev/null) -- falling back to fixed qp=$qp"
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
    printf 'searched_host=%s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf 'searched_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } >"$tmp"
  mv -f -- "$tmp" "$status_file"
  _restore_default_file_mode "$status_file"
  shot_release_claim "$src" "$idx"
  return 0
}

# True if every shot in the manifest has a resolved status -- the signal
# that a title is ready for assemble_qpfile_from_shot_manifest().
shot_manifest_all_resolved() {
  local src="$1" mdir f idx status_file st
  mdir="$(shot_manifest_dir "$src")"
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
  mdir="$(shot_manifest_dir "$src")"
  shot_manifest_all_resolved "$src" || return 1

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
    local _baseline
    local _pst_num; _pst_num="$(awk -v x="$_pst_target" 'BEGIN{printf "%.4f", x+0}')"
    _baseline="$(for st in "$mdir"/shot-*.status; do
      awk -F= -v pst="$_pst_num" '/^samples=/{
        line=substr($0,index($0,"=")+1); nf=split(line,a,","); best=-1; bb=0; bv=""
        for(i=1;i<=nf;i++){ n=split(a[i],t,":"); if(n==3 && t[2]+0 >= pst && t[1]+0 > best){best=t[1]+0; bb=t[3]+0} }
        if(best<0){ for(i=1;i<=nf;i++){ n=split(a[i],t,":"); if(n==3){bv=(bv==""?t[2]+0:bv); if(t[2]+0>=bv){bv=t[2]+0; bb=t[3]+0}} } }
        print bb
      }' "$st"
    done | awk '{s+=$1} END{printf "%.0f", s+0}')"
    byte_budget="$(awk -v f="$byte_budget" -v base="$_baseline" 'BEGIN{printf "%.0f", f*base}')"
    log_err "  equal-slope budget: fraction mode -> baseline=${_baseline} B, budget=${byte_budget} B"
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
