#!/usr/bin/env bash
# ves-scene-detect.sh -- Phase 5 of the chunk-parallel + per-shot dynamic
# optimization initiative: real shot-cut detection on the source, used to
# snap chunk-split boundaries to actual scene changes instead of purely
# fixed-interval keyframe positions. A prerequisite for Phase 6 (per-shot
# VMAF-optimized QP selection), which needs real shot boundaries to operate
# on, not just evenly-spaced chunks.
#
# Deliberately distinct from SVT-AV1's own `scd=1` (already present in
# every SVT_PARAMS_* profile, ves-config.sh) -- that only affects keyframe
# placement DURING encode, after a chunk's bytes are already fixed; this
# runs BEFORE any chunk boundary decision is made, on the source itself.

# Prints real shot-cut timestamps (seconds, strictly increasing, does NOT
# include 0 or the file's end -- callers that need those add them) for
# $1, via ffmpeg's own scene-change filter.
#
# Mechanism: `select='gt(scene,THRESHOLD)',showinfo` decodes the source
# once, scores every frame's visual difference from the previous one
# (ffmpeg's own per-frame scene-change heuristic, 0.0-1.0), and showinfo
# prints pts_time for every frame whose score exceeds the threshold --
# each one a real detected cut. Threshold default 0.3 matches ffmpeg's
# own commonly-documented default for this exact use (`select=gt(scene\,0.3)`
# in ffmpeg's own filter docs) -- not independently tuned yet, see
# SCENE_DETECT_THRESHOLD in ves-config.sh.
#
# Cost: a full sequential decode of the source (no `-ss` seeking, matching
# measure_final_vmaf_sequential()'s own reasoning for why a full decode is
# sometimes the only correct choice) -- this is NOT a cheap probe like
# find_complexity_sample_points()/source_content_variance_probe(), it's
# comparable in cost to a full VMAF pass. Deliberately only run once per
# title (result belongs on the chunk manifest, resolved once by the
# splitter, same pattern chunk_split_create_manifest() already uses for
# CRF), never per-chunk or per-encoder.
# Cut-detection filter chain. `scdet` (FFmpeg 4.3+) is a purpose-built
# scene-change detector -- more robust than `select='gt(scene,X)'` on
# low-contrast / soft / grainy B&W masters, where the old frame-difference
# metric barely moves at a cut (no colour change, similar luma) and whole
# reels came back as one 15-minute "shot" (Streetcar 1951: 50 shots for 2h05m).
# `scdet` threshold is 0-100 (default 10); lower = more sensitive. `sc_pass=1`
# passes ONLY scene-change frames to showinfo, so the existing pts_time grep is
# unchanged. Set SCENE_DETECT_METHOD=scene to force the legacy filter.
_scene_detect_filter() {  # $1 = threshold-in-old-scale (0-1); prints the [sc] filter body
  local t="$1"
  if [ "${SCENE_DETECT_METHOD:-scdet}" = "scene" ]; then
    printf "select='gt(scene,%s)',showinfo" "$t"
  else
    # map the 0-1 legacy threshold onto scdet's 0-100 (0.3 -> ~10). A caller
    # that wants the low-contrast setting passes a smaller number (e.g. 0.12).
    local st; st="$(awk -v x="$t" 'BEGIN{ v=x*33.3; if(v<1)v=1; if(v>100)v=100; printf "%.1f", v }')"
    printf "scdet=threshold=%s:sc_pass=1,showinfo" "$st"
  fi
}

scene_detect_boundaries() {
  local src="$1" threshold="${2:-${SCENE_DETECT_THRESHOLD:-0.3}}" stats_out="${3:-}"
  # showinfo logs at AV_LOG_INFO -- `-v error` would silently suppress every
  # line this function needs; must stay at (or above) info level.
  #
  # Optional 3rd arg: a writable path. When given AND SHOT_COMPLEXITY_ENABLE
  # is not "false", the SAME single decode also fans the stream to a
  # signalstats+entropy branch (sampled at SHOT_COMPLEXITY_FPS) whose
  # per-frame lavfi.* metadata is written to $stats_out -- the raw material
  # for _shot_complexity_table() (per-shot luma / motion / spatial-detail /
  # saturation, consumed by credits detection, QP-band refinement, and shot
  # clustering). Purely additive: callers that pass no path, or set the flag
  # false, get the exact original behaviour and cost.
  if [ -n "$stats_out" ] && [ "${SHOT_COMPLEXITY_ENABLE:-true}" != "false" ]; then
    : > "$stats_out" 2>/dev/null || stats_out=""
  else
    stats_out=""
  fi
  local _scf; _scf="$(_scene_detect_filter "$threshold")"
  if [ -n "$stats_out" ]; then
    local _fps="${SHOT_COMPLEXITY_FPS:-4}"
    "${FFMPEG_CMD[@]}" -nostdin -v info -nostats -i "$src" -filter_complex "\
[0:v]split=2[sc][st];\
[sc]${_scf}[cuts];\
[st]fps=${_fps},signalstats,entropy=mode=normal,metadata=print:file='${stats_out}',nullsink" \
      -map '[cuts]' -an -sn -f null - 2>&1 \
      | grep -oE 'pts_time:[0-9]+(\.[0-9]+)?' | cut -d: -f2
  else
    "${FFMPEG_CMD[@]}" -nostdin -v info -nostats -i "$src" \
      -vf "${_scf}" -an -sn -f null - 2>&1 \
      | grep -oE 'pts_time:[0-9]+(\.[0-9]+)?' | cut -d: -f2
  fi
}

# Aggregate a scene_detect_boundaries() stats file into per-shot complexity.
# Args: <stats_file> <boundaries_csv>  where boundaries_csv is the comma- or
# newline-joined cut timestamps (NOT including 0 or EOF -- same as the
# scene_detect_boundaries stdout). Emits one line per shot:
#   <idx> <luma> <motion> <detail> <sat>
#   luma   = mean signalstats YAVG   (0-255; low => dark/near-black)
#   motion = mean signalstats YDIF   (inter-frame luma delta; ~0 => static)
#   detail = mean entropy.normal.Y   (bits ~0-8; low => flat/simple)
#   sat    = mean signalstats SATAVG (0 => greyscale)
# A shot with no sampled frames in range emits all-zero (caller decides).
_shot_complexity_table() {
  local stats_file="$1" bounds="$2"
  [ -s "$stats_file" ] || return 1
  awk -v bounds="$(printf '%s' "$bounds" | tr '\n' ',' )" '
    BEGIN {
      n=split(bounds, bb, ",")
      nb=0
      for (i=1;i<=n;i++) if (bb[i] ~ /^[0-9]/) B[nb++]=bb[i]+0
      # B is sorted ascending already (scene_detect emits increasing)
      cur=0
    }
    /^frame:/ {
      # new frame block: the previous block is complete -> attribute it
      if (have) attribute()
      have=1; t=-1; yavg=""; ydif=""; ent=""; sat=""
      # pts_time is on this same line
      for (i=1;i<=NF;i++) if ($i ~ /^pts_time:/) { split($i,a,":"); t=a[2]+0 }
      next
    }
    /^lavfi\.signalstats\.YAVG=/ { split($0,a,"="); yavg=a[2]+0; next }
    /^lavfi\.signalstats\.YDIF=/ { split($0,a,"="); ydif=a[2]+0; next }
    /^lavfi\.signalstats\.SATAVG=/ { split($0,a,"="); sat=a[2]+0; next }
    /^lavfi\.entropy\.entropy\.normal\.Y=/ { split($0,a,"="); ent=a[2]+0; next }
    function attribute(   s) {
      s=0
      while (s < nb && t >= B[s]) s++
      SL[s]+=yavg; SM[s]+=ydif; SD[s]+=ent; SS[s]+=sat; SC[s]++
    }
    END {
      if (have) attribute()
      for (s=0; s<=nb; s++) {
        # NO row for a shot with zero sampled frames (a micro-cut shorter than
        # 1/SHOT_COMPLEXITY_FPS, or samples that all landed outside its range).
        # Emitting 0/0/0 there made _shot_is_nosignal() fire on real content
        # (review 2026-09-02). Absent cx_* => the shot is searched normally.
        if (SC[s] < 2) continue
        printf "%d %.2f %.4f %.4f %.2f\n", s, SL[s]/SC[s], SM[s]/SC[s], SD[s]/SC[s], SS[s]/SC[s]
      }
    }
  ' "$stats_file"
}

# Content-driven window placement for a long shot. Reads the per-frame YDIF
# samples in [start,end), splits the shot into N equal segments, and in each
# segment finds the <win_len>s window whose summed inter-frame motion is
# highest -- so the sample windows land where the shot actually changes, not
# at fixed marks. Prints "o1,o2,...,oN" (window START offsets in seconds,
# relative to the shot start, ascending). Falls back to a segment's centre
# when it has too few samples. Empty output => caller uses even spacing or a
# full-shot search.
#
# v6.0.4 (2026-09-10): N was a flat 3. It now scales with duration --
#   N = clamp(round(D / gap), nmin, nmax)
# -- so a 176s take is sampled by ~10 windows (65% coverage) instead of 3
# (14%). $5=gap_secs (default 18), $6=nmin (4), $7=nmax (12).
_shot_long_windows() {
  local stats_file="$1" start="$2" end="$3" win_len="${4:-12}"
  local gap="${5:-${PER_SHOT_MW_GAP_SECS:-18}}"
  local nmin="${6:-${PER_SHOT_MW_WINDOWS_MIN:-4}}"
  local nmax="${7:-${PER_SHOT_MW_WINDOWS_MAX:-12}}"
  [ -s "$stats_file" ] || return 1
  awk -v S="$start" -v E="$end" -v L="$win_len" -v GAP="$gap" -v NMIN="$nmin" -v NMAX="$nmax" '
    /^frame:/ { ct=-1; for(i=1;i<=NF;i++) if($i ~ /^pts_time:/){ split($i,a,":"); ct=a[2]+0 }; next }
    /^lavfi\.signalstats\.YDIF=/ {
      if (ct < S || ct >= E) next
      split($0,a,"="); T[n]=ct; Y[n]=a[2]+0; n++
      next
    }
    END {
      D = E - S
      if (n < 6 || D <= L*1.5) exit 1
      NW = int(D/GAP + 0.5); if (NW < NMIN) NW = NMIN; if (NW > NMAX) NW = NMAX
      # never ask for more non-overlapping windows than fit
      maxfit = int(D/L); if (maxfit >= 1 && NW > maxfit) NW = maxfit
      if (NW < 2) NW = 2
      step = (T[n-1]-T[0])/(n-1); if (step <= 0) step = 0.25
      wspan = int(L/step + 0.5); if (wspan < 1) wspan = 1
      # sliding-window YDIF sum starting at each sample i (window = wspan samples)
      for (i=0; i<n; i++) {
        s=0; c=0
        for (j=i; j<n && j<i+wspan; j++) { s+=Y[j]; c++ }
        WS[i] = (c ? s/c : 0)
      }
      out=""
      for (k=0; k<NW; k++) {
        lo = S + k*D/NW; hi = S + (k+1)*D/NW
        centre = (lo-S) + (D/NW - L)/2.0; if (centre<0) centre=0
        best=-1; boff=centre; msum=0; mc=0
        for (i=0; i<n; i++) {
          if (T[i] < lo || T[i] >= hi) continue
          if (T[i] + L > E) continue
          msum += WS[i]; mc++
          if (WS[i] > best) { best=WS[i]; boff=T[i]-S }
        }
        # flat segment (peak within 8% of the segment mean) => centre it, dont
        # chase sampling noise
        if (mc > 0 && best <= (msum/mc) * 1.08) boff = centre
        if (boff < 0) boff=0
        if (S + boff + L > E) boff = (E-S) - L
        if (boff < 0) boff=0
        out = out (k?",":"") sprintf("%.2f", boff)
      }
      print out
    }
  ' "$stats_file"
}
