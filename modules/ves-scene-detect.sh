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
scene_detect_boundaries() {
  local src="$1" threshold="${2:-${SCENE_DETECT_THRESHOLD:-0.3}}"
  # showinfo logs at AV_LOG_INFO -- `-v error` would silently suppress every
  # line this function needs; must stay at (or above) info level.
  "${FFMPEG_CMD[@]}" -nostdin -v info -nostats -i "$src" \
    -vf "select='gt(scene,${threshold})',showinfo" -an -sn -f null - 2>&1 \
    | grep -oE 'pts_time:[0-9]+(\.[0-9]+)?' | cut -d: -f2
}
