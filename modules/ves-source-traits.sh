#!/usr/bin/env bash
# ves-source-traits.sh -- per-file telecine/interlace and black-and-white
# ("source traits") detection, used to drive detelecine/deinterlace filter
# selection and B&W-aware CRF/VMAF tuning.
#
# Standing priority order this module is built to respect (see project plan
# ~/.claude/plans/how-can-we-chaneg-cheeky-goose.md): 1) no data loss,
# 2) no substantial quality/fidelity loss, 3) size reduction. Telecine
# (fieldmatch,decimate -- an IVTC fix) and genuine interlace (bwdif -- a
# deinterlace fix) are classified SEPARATELY, never collapsed into one
# binary "combed" flag: decimate drops duplicate frames, which is correct
# and lossless for true 3:2-pulldown telecine but is real frame data loss
# if wrongly applied to genuinely interlaced content. When classification
# is ambiguous (low signal, or sample windows disagree with each other),
# this module always returns "ambiguous" rather than guessing -- callers
# must never apply a frame-dropping filter on an ambiguous read.
#
# Reuses find_complexity_sample_points() (ves-vmaf-crf-search.sh) for
# sample windows rather than deriving its own -- same low/median/high
# complexity-representative points already used for the AV1-vs-x265
# sample decision, so this doesn't add a second independent sampling pass.

# Runs the idet filter over one sample window and prints:
#   "<progressive_frames> <interlaced_frames> <repeat_neither> <repeat_top> <repeat_bottom> <tff_frames> <bff_frames>"
# using idet's own "Multi frame detection" (more robust than single-frame)
# and "Repeated Fields" summary lines. The tff/bff split (last two fields)
# feeds field-order detection for the real-deinterlace path -- see
# source_traits_field_order(). Prints nothing and returns 1 on failure
# (unreadable window, no idet output, etc).
_idet_probe_window() {  # src start width
  local src="$1" start="$2" width="$3"
  local out line prog tff bff rn rt rb

  out="$(run_ffmpeg_validation -y -loglevel info -nostdin -ss "$start" -t "$width" -i "$src" -vf idet -f null - 2>&1)" || true
  [ -n "$out" ] || return 1

  line="$(printf '%s\n' "$out" | grep 'Multi frame detection:' | tail -1)"
  [ -n "$line" ] || return 1
  prog="$(printf '%s' "$line" | grep -o 'Progressive: *[0-9]*' | grep -o '[0-9]*$')"
  tff="$(printf '%s' "$line" | grep -o 'TFF: *[0-9]*' | grep -o '[0-9]*$')"
  bff="$(printf '%s' "$line" | grep -o 'BFF: *[0-9]*' | grep -o '[0-9]*$')"
  [ -n "$prog" ] || return 1

  line="$(printf '%s\n' "$out" | grep 'Repeated Fields:' | tail -1)"
  rn="$(printf '%s' "$line" | grep -o 'Neither: *[0-9]*' | grep -o '[0-9]*$')"
  rt="$(printf '%s' "$line" | grep -o 'Top: *[0-9]*' | grep -o '[0-9]*$')"
  rb="$(printf '%s' "$line" | grep -o 'Bottom: *[0-9]*' | grep -o '[0-9]*$')"

  printf '%s %s %s %s %s %s %s' "$prog" "$(( ${tff:-0} + ${bff:-0} ))" "${rn:-0}" "${rt:-0}" "${rb:-0}" "${tff:-0}" "${bff:-0}"
}

# Runs signalstats over one sample window and prints the window's mean
# SATAVG (average saturation), or nothing on failure. Uses the
# metadata=print filter (writes per-frame lavfi.signalstats.* tags straight
# to stdout) rather than the ffprobe movie-filter route, which needs
# fragile manual escaping of colons/quotes/parens in real media paths (this
# library's titles routinely contain both, e.g. "Batman (1943)").
_signalstats_probe_window() {  # src start width
  local src="$1" start="$2" width="$3"
  local out avg

  out="$(run_ffmpeg_validation -y -v error -nostdin -ss "$start" -t "$width" -i "$src" -vf "signalstats,metadata=print:file=-" -f null - 2>/dev/null)" || true
  [ -n "$out" ] || return 1

  avg="$(printf '%s\n' "$out" | grep -o 'lavfi\.signalstats\.SATAVG=[0-9.]*' | cut -d= -f2 | \
    awk '{s+=$1; n++} END{ if (n>0) printf "%.3f", s/n; else exit 1 }')" || return 1
  printf '%s' "$avg"
}

# Merges key=value into SOURCE_TRAITS_CACHE[$src]'s semicolon-delimited
# string, replacing an existing key or appending a new one -- lets
# detect_source_traits() (telecine/B&W, vintage-only) and
# detect_frame_rate_mode()/measure_source_baseline_vmaf() (universal, every
# profile) populate the same cache entry independently of call order,
# without either clobbering fields the other already wrote.
_source_traits_cache_set() {  # src key value
  local src="$1" key="$2" value="$3"
  local cur="${SOURCE_TRAITS_CACHE[$src]:-}"
  if [[ "$cur" =~ (^|\;)${key}=[^\;]* ]]; then
    SOURCE_TRAITS_CACHE["$src"]="$(printf '%s' "$cur" | sed -E "s/(^|;)${key}=[^;]*/\1${key}=${value}/")"
  elif [ -n "$cur" ]; then
    SOURCE_TRAITS_CACHE["$src"]="${cur};${key}=${value}"
  else
    SOURCE_TRAITS_CACHE["$src"]="${key}=${value}"
  fi
}

source_traits_frame_rate_mode() {  # src -> cfr|vfr|unknown ("unknown" if never detected)
  local v="${SOURCE_TRAITS_CACHE[$1]:-}"
  [[ "$v" =~ frame_rate_mode=([a-z]+) ]] && printf '%s' "${BASH_REMATCH[1]}" || printf 'unknown'
}

source_traits_baseline_vmaf() {  # src -> N.N or "" if never measured
  local v="${SOURCE_TRAITS_CACHE[$1]:-}"
  [[ "$v" =~ baseline_vmaf=([0-9.]+) ]] && printf '%s' "${BASH_REMATCH[1]}" || printf ''
}

# Computes the coefficient of variation (stddev/mean) of packet dts-time
# deltas within one sample window, sorted into presentation order first
# (raw ffprobe packet order is decode order, which B-frames make
# non-monotonic -- sorting before diffing is required for the deltas to
# reflect actual playback frame spacing). A tightly-clustered CFR source
# scores near 0; genuine VFR timing scores much higher. Prints nothing and
# returns 1 on failure (too few packets, zero mean, etc).
_dts_delta_cv() {  # src start width
  local src="$1" start="$2" width="$3"
  local out
  out="$(run_ffprobe -v error -select_streams v:0 -show_entries packet=dts_time \
    -of csv=p=0 -read_intervals "${start}%+${width}" "$src" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | awk '
    NF==0 { next }
    # ffprobe prints the literal string "N/A" for a packets dts_time when
    # the decoder has not yet filled its B-frame reordering buffer near a
    # -ss seek boundary -- discovered live against a real Battlestar
    # Galactica sample window, 2026-08-13, where these polluted the
    # numeric sort/delta math and made every probe window silently fail.
    $1 !~ /^[0-9.]+$/ { next }
    { t[n++] = $1 }
    END {
      if (n < 4) { exit 1 }
      for (i=0;i<n;i++) for (j=i+1;j<n;j++) if (t[j]<t[i]) { tmp=t[i]; t[i]=t[j]; t[j]=tmp }
      m=0
      for (i=1;i<n;i++) { d[i-1]=t[i]-t[i-1]; m+=d[i-1] }
      m/=(n-1)
      if (m<=0) { exit 1 }
      s=0
      for (i=0;i<n-1;i++) { s += (d[i]-m)*(d[i]-m) }
      s = sqrt(s/(n-1))
      printf "%.4f", s/m
    }
  ' || return 1
}

# Detects whether $src has genuinely constant (CFR) or variable (VFR)
# frame timing, using packet-level DTS-delta variance rather than the
# unreliable r_frame_rate==avg_frame_rate container-metadata heuristic --
# Battlestar Galactica slipped through that check entirely (its
# avg_frame_rate matches r_frame_rate despite real per-packet timing
# irregularities, discovered 2026-08-11/12 while chasing the VMAF-VFR
# false-positive bug). Caches into SOURCE_TRAITS_CACHE alongside
# field_mode/is_bw/field_order. Safe to call repeatedly (cache hit after
# the first call) and safe under --dry-run (read-only probing).
detect_frame_rate_mode() {  # src -> prints cfr|vfr|unknown
  local src="$1"
  local cached
  cached="$(source_traits_frame_rate_mode "$src")"
  [ "$cached" = unknown ] || { printf '%s' "$cached"; return 0; }

  local dur points
  local -a starts=()
  dur="$(video_duration "$src")"; dur="${dur%.*}"
  if [ -n "${dur:-}" ] && [ "$dur" -gt 0 ] 2>/dev/null; then
    points="$(find_complexity_sample_points "$src" "$dur")" || points=""
  fi
  if [ -n "$points" ]; then
    read -r -a starts <<<"$points"
  else
    starts=("$(sample_start_middle "${dur:-0}")")
  fi

  local width="$SOURCE_TRAITS_PROBE_WIDTH_SECS"
  local start cv n_windows=0 avg_cv="" mode="unknown"
  local -a cvs=()
  for start in "${starts[@]}"; do
    [ -n "$start" ] || continue
    cv="$(_dts_delta_cv "$src" "$start" "$width")" || continue
    cvs+=("$cv")
    n_windows=$((n_windows + 1))
  done

  if [ "$n_windows" -gt 0 ]; then
    avg_cv="$(printf '%s\n' "${cvs[@]}" | awk '{s+=$1;n++} END{printf "%.4f", s/n}')"
    if awk -v c="$avg_cv" -v t="$SOURCE_TRAITS_VFR_CV_MAX" 'BEGIN{exit !(c<=t)}'; then
      mode="cfr"
    else
      mode="vfr"
    fi
  fi

  _source_traits_cache_set "$src" "frame_rate_mode" "$mode"
  log_err "Source frame-rate mode: $src -> $mode (avg_cv=${avg_cv:-n/a} windows=$n_windows)"
  printf '%s' "$mode"
}

# Diagnostic companion to detect_frame_rate_mode(), but checks the FINISHED
# OUTPUT rather than the source, and only runs when a final VMAF measurement
# has already come back below LOW_QUALITY_VMAF_THRESHOLD (write_ves_processed_tag
# is the only caller). Found 2026-08-16 auditing a 38-file fleet-wide
# below-floor backlog (all traced to a single 2026-08-13 batch run, root
# cause not pinned down -- tool binaries and encode command both unchanged,
# a clean isolated re-encode of the same content doesn't reproduce it,
# pattern is consistent with fleet-wide concurrent-NAS-load frame stalls
# during that specific run rather than a persistent defect): real, literal
# duplicate packets in the AV1 output's own timestamps (identical PTS twice
# in a row, then a compensating double-length gap) -- invisible to a
# still-frame comparison (individual frames decode fine) but catastrophic
# to VMAF (measured 42-49 on files that SSIM'd at 0.96-0.997), because the
# duplication/gap pattern is exactly the kind of judder VMAF's motion-aware
# scoring is built to penalize. The existing VMAF floor already catches
# these files (that's how the 38-file backlog was found at all) -- this
# function's only job is turning "NEEDS REVIEW" into a self-diagnosing
# "LIKELY FRAME DUPLICATION" tag so a human doesn't have to re-derive this
# investigation from scratch every time it (or something with the same
# below-floor symptom) recurs. Same CV-based technique as
# detect_frame_rate_mode() -- reuses _dts_delta_cv() unchanged -- but on
# $out instead of $src. A healthy encode's own PTS spacing is just as
# regular as its source's (confirmed empirically: today's clean re-encodes
# read avg_cv 0.01-0.05, same ballpark as clean sources); the 38 confirmed-
# defective files all measured avg_cv 0.5-0.8+ on the SAME technique, so
# OUTPUT_DUPLICATE_FRAME_CV_MAX is set with wide margin on both sides
# rather than tuned to a boundary.
detect_output_frame_duplication() {  # out -> prints ok|duplicated|unknown
  local out="$1"
  local dur points
  local -a starts=()
  dur="$(video_duration "$out")"; dur="${dur%.*}"
  if [ -n "${dur:-}" ] && [ "$dur" -gt 0 ] 2>/dev/null; then
    points="$(find_complexity_sample_points "$out" "$dur")" || points=""
  fi
  if [ -n "$points" ]; then
    read -r -a starts <<<"$points"
  else
    starts=("$(sample_start_middle "${dur:-0}")")
  fi

  local width="$SOURCE_TRAITS_PROBE_WIDTH_SECS"
  local start cv n_windows=0 avg_cv="" mode="unknown"
  local -a cvs=()
  for start in "${starts[@]}"; do
    [ -n "$start" ] || continue
    cv="$(_dts_delta_cv "$out" "$start" "$width")" || continue
    cvs+=("$cv")
    n_windows=$((n_windows + 1))
  done

  if [ "$n_windows" -gt 0 ]; then
    avg_cv="$(printf '%s\n' "${cvs[@]}" | awk '{s+=$1;n++} END{printf "%.4f", s/n}')"
    if awk -v c="$avg_cv" -v t="$OUTPUT_DUPLICATE_FRAME_CV_MAX" 'BEGIN{exit !(c<=t)}'; then
      mode="ok"
    else
      mode="duplicated"
    fi
  fi

  log_err "Output frame-pacing check: $out -> $mode (avg_cv=${avg_cv:-n/a} windows=$n_windows)"
  printf '%s' "$mode"
}

# Measures VMAF of $src against itself -- a pure measurement-methodology
# sanity check, not a real quality assessment (identical content is being
# compared, so a healthy source should score ~100). Its only purpose is
# confirming the comparison technique this pipeline uses actually works for
# THIS source's specific frame-timing characteristics, BEFORE any later
# encode-vs-source comparison is trusted for it. Reuses measure_final_vmaf
# unchanged (same measure-both-ways-take-max fps handling already hardened
# for the VMAF-VFR bug, v5.1.0T) rather than duplicating VMAF-comparison
# logic -- this function is a thin cached wrapper, not a new measurement
# pipeline. A source that fails this baseline (e.g. Battlestar Galactica --
# real per-frame irregularities beyond simple VFR, not just a measurement
# artifact) gets flagged for human review immediately, instead of silently
# producing a misleading low "quality" number after a real encode.
measure_source_baseline_vmaf() {  # src -> prints VMAF or fails
  local src="$1"
  local cached
  cached="$(source_traits_baseline_vmaf "$src")"
  [ -z "$cached" ] || { printf '%s' "$cached"; return 0; }

  [ -f "$src" ] || return 1
  local vmaf
  vmaf="$(measure_final_vmaf "$src" "$src" 0 2>/dev/null)" || return 1
  [[ "$vmaf" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1

  _source_traits_cache_set "$src" "baseline_vmaf" "$vmaf"
  if awk -v v="$vmaf" -v t="$SOURCE_BASELINE_VMAF_MIN" 'BEGIN{exit !(v+0 < t+0)}'; then
    log_err "Source baseline VMAF LOW: $src -> $vmaf (below ${SOURCE_BASELINE_VMAF_MIN} — measurement methodology unreliable for this source)"
    flag_source_traits_ambiguous "$src" "baseline self-VMAF ${vmaf} below ${SOURCE_BASELINE_VMAF_MIN} — frame_rate_mode=$(source_traits_frame_rate_mode "$src")"
  else
    log_err "Source baseline VMAF: $src -> $vmaf"
  fi
  printf '%s' "$vmaf"
}

source_traits_field_mode() {  # src -> field_mode string ("unknown" if never detected)
  local v="${SOURCE_TRAITS_CACHE[$1]:-}"
  [[ "$v" =~ field_mode=([a-z]+) ]] && printf '%s' "${BASH_REMATCH[1]}" || printf 'unknown'
}

source_traits_is_bw() {  # src -> 0|1 ("0" if never detected)
  local v="${SOURCE_TRAITS_CACHE[$1]:-}"
  [[ "$v" =~ is_bw=([01]) ]] && printf '%s' "${BASH_REMATCH[1]}" || printf '0'
}

# Only meaningful when field_mode=interlaced (the real-deinterlace tier) --
# dominant field order across sample windows, for bwdif/QTGMC's tff/bff
# parameter. Defaults to "tff" (far more common in practice) if the field
# was never actually detected/cached, e.g. progressive or telecine sources
# where this was never computed.
source_traits_field_order() {  # src -> tff|bff
  local v="${SOURCE_TRAITS_CACHE[$1]:-}"
  [[ "$v" =~ field_order=(tff|bff) ]] && printf '%s' "${BASH_REMATCH[1]}" || printf 'tff'
}

# Log-only flag for an ambiguous field-mode read -- NOT the same mechanism
# as flag_bad_source_for_human (which moves the file to Deferred/): an
# ambiguous source-traits read means "don't auto-apply IVTC/deinterlace",
# not "this file is broken" -- it still encodes normally, just without the
# auto-filter, so the source must stay exactly where it is.
flag_source_traits_ambiguous() {  # src detail
  local src="$1" detail="$2"
  local logf="${SOURCE_TRAITS_LOG:-}"
  [ -n "$logf" ] || logf="${JOB_SIDECAR_DIR:-.}/source_traits_ambiguous.txt"

  warn "Source traits ambiguous — auto-detelecine/deinterlace skipped, needs human review: $src ($detail)"

  [ "$DRY_RUN" = true ] && return 0

  local _mtok
  _mtok="$(_shared_mutex_acquire "${logf}.appendlock")"
  {
    printf '%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$src" "$detail"
  } >>"$logf" 2>/dev/null || true
  _shared_mutex_release "${logf}.appendlock" "$_mtok"
  maybe_chown_for_media_user "$logf"
}

# Detects field mode (progressive/telecine/interlaced/ambiguous) and
# black-and-white status for $src, caches the result in
# SOURCE_TRAITS_CACHE[$src], and prints it ("field_mode=...;is_bw=...").
# Safe to call repeatedly -- second+ calls are a pure cache hit. Read-only
# (ffmpeg -f null probing only); safe to run under --dry-run and does not
# require DRY_RUN gating the way an actual encode step would.
detect_source_traits() {  # src
  local src="$1"

  if [ -n "${SOURCE_TRAITS_CACHE[$src]+set}" ]; then
    printf '%s' "${SOURCE_TRAITS_CACHE[$src]}"
    return 0
  fi

  local dur points
  local -a starts=()
  dur="$(video_duration "$src")"; dur="${dur%.*}"
  if [ -n "${dur:-}" ] && [ "$dur" -gt 0 ] 2>/dev/null; then
    points="$(find_complexity_sample_points "$src" "$dur")" || points=""
  fi
  if [ -n "$points" ]; then
    read -r -a starts <<<"$points"
  else
    starts=("$(sample_start_middle "${dur:-0}")")
  fi

  local width="$SOURCE_TRAITS_PROBE_WIDTH_SECS"
  local start idet_result prog interlaced rn rt rb tff bff total repeat repeat_total pr ir rr sat
  local -a prog_ratios=() interlace_ratios=() repeat_ratios=() satavgs=()
  local n_windows=0 tff_total=0 bff_total=0

  for start in "${starts[@]}"; do
    [ -n "$start" ] || continue
    idet_result="$(_idet_probe_window "$src" "$start" "$width")" || continue
    read -r prog interlaced rn rt rb tff bff <<<"$idet_result"
    total=$(( prog + interlaced ))
    [ "$total" -gt 0 ] || continue
    repeat=$(( rt + rb ))
    repeat_total=$(( rn + rt + rb ))
    [ "$repeat_total" -gt 0 ] || repeat_total="$total"
    pr="$(awk -v p="$prog" -v t="$total" 'BEGIN{printf "%.4f", p/t}')"
    ir="$(awk -v i="$interlaced" -v t="$total" 'BEGIN{printf "%.4f", i/t}')"
    rr="$(awk -v r="$repeat" -v t="$repeat_total" 'BEGIN{printf "%.4f", r/t}')"
    prog_ratios+=("$pr"); interlace_ratios+=("$ir"); repeat_ratios+=("$rr")
    tff_total=$(( tff_total + tff )); bff_total=$(( bff_total + bff ))

    sat="$(_signalstats_probe_window "$src" "$start" "$width")" && satavgs+=("$sat")

    n_windows=$((n_windows + 1))
  done

  if [ "$n_windows" -eq 0 ]; then
    log_err "Source traits: no usable probe windows for $src — treating as ambiguous"
    SOURCE_TRAITS_CACHE["$src"]="field_mode=ambiguous;is_bw=0;field_order=tff"
    flag_source_traits_ambiguous "$src" "no usable probe windows"
    printf '%s' "${SOURCE_TRAITS_CACHE[$src]}"
    return 0
  fi

  local avg_prog avg_interlace avg_repeat min_prog max_prog spread field_mode="ambiguous" is_bw=0
  avg_prog="$(printf '%s\n' "${prog_ratios[@]}" | awk '{s+=$1;n++} END{printf "%.4f", s/n}')"
  avg_interlace="$(printf '%s\n' "${interlace_ratios[@]}" | awk '{s+=$1;n++} END{printf "%.4f", s/n}')"
  avg_repeat="$(printf '%s\n' "${repeat_ratios[@]}" | awk '{s+=$1;n++} END{printf "%.4f", s/n}')"
  min_prog="$(printf '%s\n' "${prog_ratios[@]}" | sort -n | head -1)"
  max_prog="$(printf '%s\n' "${prog_ratios[@]}" | sort -n | tail -1)"
  spread="$(awk -v a="$min_prog" -v b="$max_prog" 'BEGIN{d=b-a; if(d<0)d=-d; printf "%.4f", d}')"

  if awk -v p="$avg_prog" -v m="$SOURCE_TRAITS_PROGRESSIVE_MIN" 'BEGIN{exit !(p>=m)}'; then
    field_mode="progressive"
  elif awk -v r="$avg_repeat" -v lo="$SOURCE_TRAITS_TELECINE_REPEAT_MIN" -v hi="$SOURCE_TRAITS_TELECINE_REPEAT_MAX" -v sp="$spread" -v spmax="$SOURCE_TRAITS_WINDOW_SPREAD_MAX" \
      'BEGIN{exit !(r>=lo && r<=hi && sp<=spmax)}'; then
    field_mode="telecine"
  elif awk -v i="$avg_interlace" -v m="$SOURCE_TRAITS_INTERLACE_MIN" -v sp="$spread" -v spmax="$SOURCE_TRAITS_WINDOW_SPREAD_MAX" \
      'BEGIN{exit !(i>=m && sp<=spmax)}'; then
    field_mode="interlaced"
  else
    field_mode="ambiguous"
  fi

  if [ "${#satavgs[@]}" -gt 0 ]; then
    local avg_sat
    avg_sat="$(printf '%s\n' "${satavgs[@]}" | awk '{s+=$1;n++} END{printf "%.3f", s/n}')"
    awk -v s="$avg_sat" -v m="$SOURCE_TRAITS_BW_SATAVG_MAX" 'BEGIN{exit !(s<=m)}' && is_bw=1
  fi

  local field_order="tff"
  [ "$bff_total" -gt "$tff_total" ] && field_order="bff"

  SOURCE_TRAITS_CACHE["$src"]="field_mode=${field_mode};is_bw=${is_bw};field_order=${field_order}"
  log_err "Source traits: $src -> field_mode=$field_mode (avg_prog=$avg_prog avg_interlace=$avg_interlace avg_repeat=$avg_repeat window_spread=$spread windows=$n_windows field_order=$field_order tff=$tff_total bff=$bff_total) is_bw=$is_bw"

  if [ "$field_mode" = "ambiguous" ]; then
    flag_source_traits_ambiguous "$src" "avg_prog=$avg_prog avg_interlace=$avg_interlace avg_repeat=$avg_repeat window_spread=$spread"
  fi

  printf '%s' "${SOURCE_TRAITS_CACHE[$src]}"
}

# Phase 1 validation entry point (--report-source-traits): detect and log
# source traits for every file the normal scan would find under $1, print a
# summary table, and return without encoding anything. Read-only.
report_source_traits_for_path() {  # root_path
  local root="$1"
  local src field_mode is_bw n=0
  local -a files=() pred=()

  log "Source-traits report: scanning $root"
  # Plain find, not find_convert_videos_under_cached -- this is a read-only
  # reporting mode, and the cached scan has the side effect of writing
  # per-folder in-progress advisory flags, which shouldn't happen for a
  # detection-only dry run.
  build_find_video_pred pred
  while IFS= read -r src; do
    [ -n "$src" ] && files+=("$src")
  done < <(find "$root" -type f "${pred[@]}" ! -path '*/Deferred/*' 2>/dev/null | LC_ALL=C sort)

  if [ "${#files[@]}" -eq 0 ]; then
    warn "Source-traits report: no video files found under $root"
    return 1
  fi

  printf '\n%-90s %-12s %-6s\n' "File" "Field mode" "B&W"
  printf '%s\n' "--------------------------------------------------------------------------------------------------------------"
  for src in "${files[@]}"; do
    # Must NOT be `x="$(detect_source_traits "$src")"` -- that command
    # substitution forks a subshell, so the SOURCE_TRAITS_CACHE write inside
    # detect_source_traits() never reaches this function's copy of the
    # (global, but subshell-inherited-by-value-here) associative array, and
    # every subsequent source_traits_field_mode() lookup silently reports
    # "unknown" even though detection itself succeeded. Found while hunting
    # a real positive-control telecine/interlace title for Phase D
    # calibration -- every file's mode was printing "unknown" despite the
    # log line right above it showing the correct classification.
    detect_source_traits "$src" >/dev/null
    field_mode="$(source_traits_field_mode "$src")"
    is_bw="$(source_traits_is_bw "$src")"
    printf '%-90s %-12s %-6s\n' "$(basename -- "$src")" "$field_mode" "$([ "$is_bw" = 1 ] && echo yes || echo no)"
    n=$((n + 1))
  done
  printf '\n'
  log "Source-traits report: $n file(s) classified under $root"
}
