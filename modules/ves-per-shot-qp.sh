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

# Scores one shot at one candidate QP: encodes the shot's own real frame
# range (stream-copy extracted, not re-decoded first) at a HARD uniform
# QP -- deliberately -qp, never -crf, because the final application (one
# continuous encode driven by a per-frame qpfile) applies an explicit,
# non-adaptive QP to every frame in this shot's range; searching with an
# internally-adaptive -crf would not predict that behavior correctly.
# Prints "vmaf bytes" or fails.
_vmaf_score_shot() {
  local src="$1" start="$2" end="$3" qp="$4" codec="$5" model="$6" profile="$7"
  local work clip out vlog v b enc_timeout
  local -a grain_decode_flag=()
  work="$(mktemp -d "${RAMDISK_JOB_DIR:-${TMPDIR:-/tmp}}/ves-shotqp-XXXXXX")" || return 1
  clip="$work/shot.mkv"
  run_ffmpeg_validation -y -v error -ss "$start" -to "$end" -i "$src" \
    -map 0:v:0 -c copy "$clip" 2>/dev/null || { rm -rf "$work"; return 1; }
  [ -s "$clip" ] || { rm -rf "$work"; return 1; }
  out="$work/shot-enc-$qp.mkv"
  vlog="${out}.vmaf.json"
  enc_timeout="$(_shot_ffmpeg_timeout "$(awk -v s="$start" -v e="$end" 'BEGIN{d=e-s; if(d<0)d=0; print d}')")"
  case "$codec" in
    av1)
      local svtp; svtp="$(profile_svt_params "$profile")" || { rm -rf "$work"; return 1; }
      _run_timeout_retry "$enc_timeout" "${FFMPEG_CMD[@]}" -y -v error -i "$clip" -c:v libsvtav1 -preset "$SVT_PRESET_SEARCH" -qp "$qp" \
        -pix_fmt yuv420p10le -svtav1-params "${svtp}:rc=0" -an "$out" 2>/dev/null || { rm -rf "$work"; return 1; }
      svtav1_profile_uses_grain_synthesis "$profile" && grain_decode_flag=(-export_side_data film_grain)
      ;;
    *) rm -rf "$work"; return 1 ;;
  esac
  _run_timeout_retry "$enc_timeout" "${FFMPEG_CMD[@]}" -y -v error "${grain_decode_flag[@]}" -i "$out" -i "$clip" -lavfi \
    "[0:v]setpts=PTS-STARTPTS,format=yuv420p10le[d];[1:v]setpts=PTS-STARTPTS,format=yuv420p10le[r];[d][r]libvmaf=model=$model:n_threads=$(nproc 2>/dev/null || sysctl -n hw.ncpu):log_fmt=json:log_path=$vlog" \
    -f null - 2>/dev/null || { rm -rf "$work"; return 1; }
  v="$(python3 -c "import json;print(round(json.load(open('$vlog'))['pooled_metrics']['vmaf']['mean'],2))" 2>/dev/null)" || { rm -rf "$work"; return 1; }
  b="$(file_size_bytes "$out")"
  rm -rf "$work"
  printf '%s %s' "$v" "$b"
}

# Bounded bisection QP search for one shot -- same anchor+bisect shape as
# vmaf_crf_search_internal(), just over QP instead of CRF and scored via
# _vmaf_score_shot() instead of sampling several clips. Prints
# "qp achieved_vmaf" or fails (caller should fall back to a fixed default
# QP for this shot, same "search failed, don't block the pipeline"
# philosophy resolve_crf_for_encode() already uses for whole-file search).
resolve_per_shot_qp() {
  local src="$1" start="$2" end="$3" codec="$4" target="$5" model="$6" profile="$7"
  local -A score=() bytes=()
  local qp above below gap

  _probe_qp() {
    local q="$1" r
    [ -n "${score[$q]:-}" ] && return 0
    r="$(_vmaf_score_shot "$src" "$start" "$end" "$q" "$codec" "$model" "$profile")" || return 1
    score[$q]="${r%% *}"; bytes[$q]="${r##* }"
    log_err "  per-shot qp-search [$codec] shot=${start}-${end} qp=$q vmaf=${score[$q]}"
  }

  # QP shares CRF's exact 0-63 scale and direction in this SVT-AV1 build
  # (lower value = more bits = higher quality) -- same anchor/bisect shape
  # as vmaf_crf_search_internal(), "above"/"below" naming kept identical
  # to that function on purpose so the two stay easy to compare.
  local anchors="$VMAF_SEARCH_MIN_CRF 30 $VMAF_SEARCH_MAX_CRF"
  for qp in $anchors; do _probe_qp "$qp" || return 1; done
  for i in 1 2 3; do
    above=""; below=""
    for qp in $(printf '%s\n' "${!score[@]}" | sort -n); do
      if awk -v s="${score[$qp]}" -v t="$target" 'BEGIN{exit !(s>=t)}'; then above="$qp"; else below="$qp"; break; fi
    done
    if [ -z "$above" ]; then _probe_qp "$VMAF_SEARCH_MIN_CRF" || break; continue; fi
    if [ -z "$below" ]; then _probe_qp "$VMAF_SEARCH_MAX_CRF" || break; continue; fi
    gap=$(( below - above )); [ "$gap" -le 1 ] && break
    _probe_qp $(( above + gap / 2 )) || break
  done

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
  printf '%s %s' "$best" "$bv"
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
  mkdir -- "$mdir" 2>/dev/null || return 1
  chmod 0777 -- "$mdir" 2>/dev/null || true
  tmpdir="$(mktemp -d "${mdir}.build.XXXXXX")" || { rmdir -- "$mdir" 2>/dev/null; return 1; }

  dur="$(video_duration "$src")" || { rm -rf -- "$tmpdir"; rmdir -- "$mdir" 2>/dev/null; return 1; }
  target="$(vmaf_target_for_source "$src")" || { rm -rf -- "$tmpdir"; rmdir -- "$mdir" 2>/dev/null; return 1; }
  model="$(vmaf_model_for_source "$src")"

  while IFS= read -r ts; do
    [ -n "$ts" ] || continue
    cat >"${tmpdir}/shot-$(printf '%03d' "$n").meta" <<EOF
index=$n
start_ts=$prev
end_ts=$ts
EOF
    n=$((n + 1))
    prev="$ts"
  done < <(scene_detect_boundaries "$src")
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
    mtime="$(mkv_structure_stat_key "$owner_meta" 2>/dev/null)" || true
    mtime="${mtime##*|}"
    now="$(date +%s)"
    age=$(( now - ${mtime:-$now} ))
    if [ "$age" -gt "${SHOT_SEARCH_STALE_SECS:-1800}" ]; then
      reclaim_name="${lockdir}.reclaim.${this_host}.$$.$RANDOM"
      if mv -- "$lockdir" "$reclaim_name" 2>/dev/null; then
        rm -rf -- "$reclaim_name" 2>/dev/null
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
  if [ -n "$result" ]; then
    qp="${result%% *}"; vmaf="${result##* }"
  else
    qp="$(fixed_crf_for "$codec" "$profile" false)"
    vmaf=""
    warn "Shot search failed for shot $idx ($start_ts-$end_ts) on $(hostname 2>/dev/null) -- falling back to fixed qp=$qp"
  fi

  status_file="$mdir/shot-$(printf '%03d' "$idx").status"
  tmp="$(mktemp "${status_file}.XXXXXX" 2>/dev/null)" || { shot_release_claim "$src" "$idx"; return 1; }
  {
    printf 'status=resolved\n'
    printf 'qp=%s\n' "$qp"
    printf 'vmaf=%s\n' "$vmaf"
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
