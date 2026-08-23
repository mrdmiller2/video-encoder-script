#!/usr/bin/env bash
# ves-chunk-coordinator.sh -- distributed chunk-parallel encoding
# coordination layer (Layer 1 of the chunk-parallel + per-shot dynamic
# optimization initiative, 2026-08-21).
#
# Today's job discovery (ves-sharded-scan.sh/ves-pipeline-scan.sh) is
# pull-based, single-machine-per-file throughout: any idle machine scans
# the shared library and self-claims one untouched file via
# place_in_progress_flag()'s atomic mkdir lock. There is no existing
# mechanism for multiple specific machines to cooperate on ONE file.
# Rather than introduce a central dispatcher (a real break from this
# project's decentralized philosophy), this module extends the exact same
# atomic-claim idiom to chunk granularity: a manifest lists a title's
# chunks once (written by a "splitter" step), and each chunk is claimed
# via the identical mkdir-lock primitive place_in_progress_flag() already
# uses, just keyed by "<canonical_title>.chunk<N>" instead of
# "<canonical_title>" alone. No new locking primitive, only a new key
# naming convention reusing the existing one.
#
# Manifest storage is one-file-per-chunk, not a single shared
# manifest-plus-status file multiple machines append to -- deliberately,
# per this project's own documented precedent
# (project_elvis_phase3_donelog_2026_08_02: shared-file append proved
# unreliable on this NAS, one-file-per-entry was the fix that shipped).
# The chunk boundaries themselves (index/start/end) are written ONCE by
# the splitter and never modified after -- only each chunk's own STATUS
# file is written by different machines over its lifetime (encoder, then
# verifier), and always via the same mktemp+mv atomic-write pattern every
# other file write in this codebase already uses, so there is no
# concurrent-writer corruption risk even though different hosts touch it
# at different times.

# Directory holding one title's chunk manifest + per-chunk status files.
# Lives beside the source, matching in_progress_flag_path()'s own
# same-directory convention (ves-title-lock.sh) -- not a separate NAS
# location, so it inherits that directory's existing permissions/ACLs
# rather than needing its own.
chunk_manifest_dir() {
  local src="$1"
  local dir title
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src")"
  printf '%s/%s.chunks' "$dir" "$title"
}

# Opt-in threshold: only genuinely long/demanding sources are worth the
# coordination overhead of chunk-parallel encoding. Duration-based (not
# size-based) since encode time tracks runtime much more directly than
# file size (a highly-compressed source and a near-lossless one of the
# same runtime take wildly different encode times, but chunk-parallel's
# actual benefit -- wall-clock reduction -- is a runtime story).
chunk_should_split() {
  local src="$1" dur
  [ "${CONVERT_CHUNK_PARALLEL_ENABLED:-false}" = true ] || return 1
  is_disk_source "$src" && return 1
  dur="$(video_duration "$src" 2>/dev/null)" || return 1
  awk -v d="${dur:-0}" -v m="$CONVERT_CHUNK_MIN_DURATION_SECS" 'BEGIN { exit !(d+0 >= m+0) }'
}

# Prints keyframe-snapped chunk boundary timestamps (seconds, one per
# line, strictly increasing, first is always 0) for $1, targeting
# roughly CONVERT_CHUNK_TARGET_SECS per chunk. Snapped to the *source's
# own* real keyframe positions (not assumed at a fixed interval) via a
# real ffprobe keyframe scan -- necessary for a clean stream-copy
# concat later (every chunk must start on a real keyframe boundary, an
# ffmpeg -ss/-to time-based cut alone does not guarantee this). Does
# NOT depend on SVT_PARAMS' keyint=15s (that only governs the FINAL
# ENCODED output's own keyframes, produced only after chunk encoding
# already happened) -- correctly scans the SOURCE's existing keyframes.
_chunk_keyframe_timestamps() {
  local src="$1"
  # -of csv=print_section=0 still emits a trailing delimiter after the
  # single field on every line (confirmed via a real test against a
  # 6674s movie -- every timestamp came back as e.g. "611.110000,",
  # comma included). Strip it here rather than downstream, so nothing
  # that stores/parses these values needs to know about ffprobe's own
  # CSV formatting quirk.
  "${FFPROBE_CMD[@]}" -v error -select_streams v:0 -skip_frame nokey \
    -show_entries frame=pts_time -of csv=print_section=0 -- "$src" 2>/dev/null | tr -d ','
}

chunk_split_compute_boundaries() {
  local src="$1" target="$CONVERT_CHUNK_TARGET_SECS"
  local dur next_target ts
  dur="$(video_duration "$src" 2>/dev/null)" || return 1
  [ -n "$dur" ] && [ "$dur" != "0" ] || return 1

  printf '0\n'
  next_target="$target"
  while IFS= read -r ts; do
    [ -n "$ts" ] || continue
    if awk -v t="$ts" -v nt="$next_target" 'BEGIN { exit !(t+0 >= nt+0) }'; then
      printf '%s\n' "$ts"
      next_target=$(awk -v t="$ts" -v add="$target" 'BEGIN { printf "%.3f", t+add }')
    fi
  done < <(_chunk_keyframe_timestamps "$src")
}

# Creates the manifest directory + one boundary file per chunk, PLUS
# resolves and caches the profile/codec/HDR/CRF that every chunk encoder
# must use -- resolved exactly ONCE here (by the splitter), not
# independently per chunk. Chunks are pieces of one continuous encode;
# if each chunk's own encoder ran its own CRF search, different chunks
# could land on different CRFs and produce visibly inconsistent
# quality/bitrate across chunk boundaries in the final concatenated file.
# Reuses resolve_crf_for_encode() (ves-vmaf-crf-search.sh) unchanged --
# same VMAF-target search the whole-file path already runs, just cached
# fleet-wide via the manifest instead of per-process.
#
# Idempotent -- if a complete manifest already exists (a ".complete"
# marker written last, after every chunk file), does nothing and returns
# success, so a second machine racing to split the same title is
# harmless (whichever wins the mkdir below does the real work, including
# the CRF search; the loser just walks away and reads the winner's
# cached result later).
chunk_split_create_manifest() {
  local src="$1" codec="${2:-av1}"
  local mdir tmpdir n prev_ts ts profile hdr hdr_mode crf
  mdir="$(chunk_manifest_dir "$src")"
  [ -f "$mdir/.complete" ] && return 0

  # Stale-split reclaim: an mdir that exists with no .complete is
  # ambiguous -- either another host is actively splitting right now (a
  # real keyframe scan of a multi-GB source can take a couple minutes), or
  # a prior splitter died mid-build (crash, kill, network drop) and left a
  # permanently-stuck empty directory behind. Unlike chunk_claim_next's
  # per-chunk locks, an incomplete mdir had NO staleness/reclaim logic at
  # all until this fix -- mkdir below always fails against an already-
  # existing dir, so a single interrupted split permanently broke this
  # title's chunk-parallel path forever (found live via a real interrupted-
  # splitter test, 2026-08-23). Threshold is far shorter than the 7200s
  # per-chunk-encode lock ceiling since a split is just a keyframe scan,
  # not an hours-long encode -- a genuinely still-splitting host should
  # finish well inside 900s even on a very large 4K source.
  if [ -d "$mdir" ]; then
    local mdir_age mdir_mtime now
    mdir_mtime="$(mkv_structure_stat_key "$mdir" 2>/dev/null)"; mdir_mtime="${mdir_mtime##*|}"
    now="$(date +%s)"
    mdir_age=$(( now - ${mdir_mtime:-$now} ))
    if [ "$mdir_age" -gt 900 ]; then
      warn "Chunk split: reclaiming stale incomplete manifest dir (age ${mdir_age}s, no .complete): $mdir"
      rm -rf -- "$mdir" "${mdir}".build.* 2>/dev/null
    fi
  fi

  # mkdir as the race-avoidance primitive, same reasoning as
  # place_in_progress_flag's lockdir: atomic even on NFS/CIFS, and the
  # loser of the race backs off rather than duplicating the splitter's
  # (expensive, full-file ffprobe keyframe scan) work.
  if ! mkdir -- "$mdir" 2>/dev/null; then
    # Another machine is already splitting (or finished and is about to
    # write .complete) -- not this function's job to wait; caller should
    # just retry chunk_should_split's caller path on its next scan pass.
    return 1
  fi
  # This directory is shared write-target for every encoder-tier machine
  # claiming chunks, not just the splitter -- fleet worker accounts are NOT
  # UID/GID-aligned across machines (confirmed 2026-08-22: LAYTOYAJ=1000,
  # Plex=1001, MJACKSON=1002, Sting=3000), so a restrictive default mkdir
  # mode leaves every other host's writes silently failing. Matches this
  # project's File Permissions CONSTANT (666/777 as needed).
  chmod 0777 -- "$mdir" 2>/dev/null || true

  tmpdir="$(mktemp -d "${mdir}.build.XXXXXX")" || { rmdir -- "$mdir" 2>/dev/null; return 1; }

  local boundaries=()
  while IFS= read -r ts; do
    boundaries+=("$ts")
  done < <(chunk_split_compute_boundaries "$src")
  if [ "${#boundaries[@]}" -lt 2 ]; then
    warn "Chunk split: fewer than 2 keyframe-snapped boundaries found — refusing to split, falling back to whole-file encode: $src"
    rm -rf -- "$tmpdir"
    rmdir -- "$mdir" 2>/dev/null
    return 1
  fi

  n=0
  prev_ts="${boundaries[0]}"
  local i
  for ((i = 1; i < ${#boundaries[@]}; i++)); do
    ts="${boundaries[$i]}"
    cat >"${tmpdir}/chunk-$(printf '%03d' "$n").meta" <<EOF
index=$n
start_ts=$prev_ts
end_ts=$ts
EOF
    n=$((n + 1))
    prev_ts="$ts"
  done
  # Final chunk runs to the real end of the file -- end_ts=EOF, not a
  # numeric timestamp, since the source's exact end may not land on a
  # detected keyframe and ffmpeg's own -to naturally handles an EOF cut.
  cat >"${tmpdir}/chunk-$(printf '%03d' "$n").meta" <<EOF
index=$n
start_ts=$prev_ts
end_ts=EOF
EOF
  n=$((n + 1))

  profile="$(profile_for_source "$src")" || profile=""
  hdr_mode="$(determine_hdr_mode "$src")"
  case "$hdr_mode" in
    pq|pq_reconstruct|hlg) hdr=true ;;
    *) hdr=false ;;
  esac
  # Resolve upscale target FIRST, as its own statement, not inside the
  # crf="$(...)" capture below. resolve_upscale_target logs a one-time
  # "Upscale decision: ..." line via log() (stdout, this codebase's own
  # convention) the first time it runs for a given source, then caches
  # the result (UPSCALE_TARGET_CACHE) and stays silent on every later
  # call. resolve_crf_for_encode calls it internally too -- if THAT were
  # the first call, the log line would leak into this function's own
  # $(...) capture and corrupt the stored CRF value. Found via a real
  # live test: manifest.meta's crf field came back containing the log
  # line's text instead of a clean number. Matches the exact call-order
  # discipline the whole-file path (ffmpeg_encode()) already follows.
  resolve_upscale_target "$src"
  crf="$(resolve_crf_for_encode "$src" "$codec" "$profile" "$hdr")"

  cat >"${tmpdir}/manifest.meta" <<EOF
source=$src
chunk_count=$n
codec=$codec
profile=$profile
hdr=$hdr
hdr_mode=$hdr_mode
crf=$crf
created_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
created_host=$(hostname 2>/dev/null || echo unknown)
EOF

  # Move populated files into the real manifest dir, then write .complete
  # LAST -- any reader that sees .complete is guaranteed every chunk file
  # already exists (mv within the same filesystem is effectively atomic
  # per-file; the ordering guarantee comes from writing .complete only
  # after every other mv has already succeeded, not from any single mv
  # itself being atomic across files).
  local f
  for f in "$tmpdir"/*; do
    mv -f -- "$f" "$mdir/$(basename -- "$f")"
  done
  rmdir -- "$tmpdir" 2>/dev/null
  : >"$mdir/.complete"
  log "Chunk split: $n chunk(s) created for $(basename -- "$src")"
  return 0
}

chunk_manifest_read_field() {
  local src="$1" field="$2"
  local mdir
  mdir="$(chunk_manifest_dir "$src")"
  awk -F= -v f="^${field}=" '$0 ~ f{sub(f,""); print; exit}' "$mdir/manifest.meta" 2>/dev/null
}

chunk_lock_path() {
  local src="$1" idx="$2"
  local dir title
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src")"
  printf '%s/%s.chunk%s' "$dir" "$title" "$idx"
}

# Claims one not-yet-claimed, not-yet-done chunk for $src. Prints the
# claimed chunk index on stdout and returns 0, or returns 1 if none are
# available right now (caller should move on to scanning other titles,
# not block). Reuses place_in_progress_flag's exact mkdir-lock +
# mv-based-stale-reclaim reasoning (ves-title-lock.sh) at chunk
# granularity -- see that function's own comments for why mkdir (atomic
# on NFS/CIFS) and mv-not-rmdir-then-mkdir (avoids a two-syscall reclaim
# race) are each the right primitive.
chunk_claim_next() {
  local src="$1" this_host
  local mdir f idx lockdir status_file reclaim_name
  mdir="$(chunk_manifest_dir "$src")"
  [ -f "$mdir/.complete" ] || return 1
  this_host="$(hostname 2>/dev/null || echo unknown)"

  for f in "$mdir"/chunk-*.meta; do
    [ -e "$f" ] || continue
    idx="$(awk -F= '/^index=/{print $2; exit}' "$f")"
    status_file="$mdir/chunk-$(printf '%03d' "$idx").status"
    if [ -f "$status_file" ]; then
      local st
      st="$(awk -F= '/^status=/{print $2; exit}' "$status_file" 2>/dev/null)"
      case "$st" in
        verified|encoded) continue ;;
      esac
    fi
    lockdir="$(chunk_lock_path "$src" "$idx").lock"
    if mkdir -- "$lockdir" 2>/dev/null; then
      cat >"${lockdir}/owner.meta" <<EOF
host=$this_host
pid=$$
claimed_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
      printf '%s' "$idx"
      return 0
    fi
    # Stale-claim reclaim, identical shape to place_in_progress_flag: age
    # against the SAME 7200s ceiling every other title/chunk lock in this
    # project uses (see ves-config.sh), reclaim via mv (single atomic
    # rename) never rmdir-then-mkdir.
    local owner_meta age mtime now
    owner_meta="${lockdir}/owner.meta"
    mtime="$(mkv_structure_stat_key "$owner_meta" 2>/dev/null)" || true
    mtime="${mtime##*|}"
    now="$(date +%s)"
    age=$(( now - ${mtime:-$now} ))
    if [ "$age" -gt 7200 ]; then
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

chunk_release_claim() {
  local src="$1" idx="$2"
  # rm -rf, not rmdir: the lock dir holds an owner.meta file (unlike
  # place_in_progress_flag's plain empty lockdir), so it's never bare.
  rm -rf -- "$(chunk_lock_path "$src" "$idx").lock" 2>/dev/null || true
}

# Records a chunk's outcome. $status is one of: encoded | verify-failed |
# verified. $extra (optional) is additional key=value lines, e.g.
# "vmaf_score=94.2" -- deliberately free-form rather than a fixed schema,
# since Layer 2 (per-shot QP selection) needs to add fields
# (qp_candidate, verdict) this function's callers don't know about yet;
# see the plan's Phase 3 note that the verifier's output shape is a
# decision, not just a boolean, from day one.
chunk_mark_status() {
  local src="$1" idx="$2" status="$3" extra="${4:-}"
  local mdir status_file tmp
  mdir="$(chunk_manifest_dir "$src")"
  status_file="$mdir/chunk-$(printf '%03d' "$idx").status"
  tmp="$(mktemp "${status_file}.XXXXXX" 2>/dev/null)" || return 1
  {
    printf 'status=%s\n' "$status"
    printf 'updated_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'updated_host=%s\n' "$(hostname 2>/dev/null || echo unknown)"
    [ -n "$extra" ] && printf '%s\n' "$extra"
  } >"$tmp"
  mv -f -- "$tmp" "$status_file"
  _restore_default_file_mode "$status_file"
}

# Encodes ONE already-claimed chunk and moves the result into the
# manifest directory (NAS-visible, so other machines -- verifiers, the
# concatenator -- can reach it later; this is the "sub directory under
# the primary working file" every fleet machine writes chunks into,
# explicit user direction). The actual ffmpeg write-in-progress still
# stages locally/on the RAM disk first, exactly like the whole-file path
# (RAMDISK_JOB_STAGE_DIR if set, else a local scratch dir) -- never
# writes a partial/in-progress file directly into the NAS-visible
# manifest dir.
#
# Reuses build_ffmpeg_video_args() (ves-twostage-encode.sh) unchanged for
# the actual codec/profile/CRF args, and run_tracked_encoder/
# _run_capturing_stderr (ves-tracked-process.sh) unchanged for process
# tracking + diagnostic capture -- same machinery the whole-file encode
# path already uses, just windowed to one chunk's time range via input-
# side -ss/-to. Input-side (not output-side) -ss is both fast (a real
# keyframe seek, not a full decode-from-start) and frame-accurate here
# specifically because chunk boundaries are already real keyframes from
# chunk_split_compute_boundaries()'s own ffprobe scan -- an arbitrary
# (non-keyframe-aligned) -ss would need output-side seeking instead for
# accuracy, which this function deliberately does not need to handle.
chunk_encode_claimed() {
  local src="$1" idx="$2"
  local mdir chunk_meta start_ts end_ts codec profile hdr hdr_mode crf
  local stage_dir out_tmp out_final errfile args rc acodec abr

  mdir="$(chunk_manifest_dir "$src")"
  chunk_meta="$mdir/chunk-$(printf '%03d' "$idx").meta"
  [ -f "$chunk_meta" ] || { warn "Chunk encode: no manifest entry for chunk $idx: $src"; return 1; }
  start_ts="$(awk -F= '/^start_ts=/{print $2; exit}' "$chunk_meta")"
  end_ts="$(awk -F= '/^end_ts=/{print $2; exit}' "$chunk_meta")"

  codec="$(chunk_manifest_read_field "$src" codec)"
  profile="$(chunk_manifest_read_field "$src" profile)"
  hdr="$(chunk_manifest_read_field "$src" hdr)"
  hdr_mode="$(chunk_manifest_read_field "$src" hdr_mode)"
  crf="$(chunk_manifest_read_field "$src" crf)"
  if [ -z "$codec" ] || [ -z "$crf" ]; then
    warn "Chunk encode: manifest.meta missing codec/crf for $src -- was it created by chunk_split_create_manifest?"
    return 1
  fi

  build_ffmpeg_video_args "$codec" "$crf" "$src" "$profile" "$hdr" "$hdr_mode" || {
    warn "Chunk encode: build_ffmpeg_video_args failed for chunk $idx: $src"
    return 1
  }

  # Audio codec MUST be pinned explicitly, matching the whole-file path's
  # own resolution exactly (ves-twostage-encode.sh) -- found live,
  # 2026-08-23: chunk_encode_claimed originally had no -c:a at all, letting
  # ffmpeg's own default audio-encoder selection decide per invocation.
  # That produced genuinely different audio codecs across chunks of the
  # SAME source (Vorbis on some, AC-3 on others), which made mkvmerge's
  # concat step hard-fail ("the formats do not match") -- a real,
  # concat-blocking bug, not a cosmetic one. build_ffmpeg_video_args only
  # ever set VIDEO args (by name and by design); audio was always resolved
  # separately at each whole-file call site, and chunk_encode_claimed had
  # never picked that up.
  case "$codec" in
    av1)  if [ "$FF_HAS_LIBOPUS" = true ]; then acodec="libopus"; abr="$OPUS_BITRATE_V5"; else acodec="aac"; abr="$AAC_BITRATE_V5"; fi ;;
    hevc) acodec="aac"; abr="$AAC_BITRATE_V5" ;;
  esac

  # Staging dir: RAM disk if this run has one, else a local scratch dir
  # beside the script's own deployment (guaranteed real local disk, not
  # tmpfs-only-on-Linux/NFS -- same fallback _CONVERT_V4_SCRIPT_DIR-based
  # convention this codebase already uses for diagnostic logs).
  if [ -n "${RAMDISK_JOB_STAGE_DIR:-}" ]; then
    stage_dir="$RAMDISK_JOB_STAGE_DIR"
  else
    stage_dir="${_CONVERT_V4_SCRIPT_DIR:-/tmp}/chunk-stage"
    mkdir -p "$stage_dir" 2>/dev/null
  fi
  out_tmp="${stage_dir}/$(canonical_title_from_source "$src").chunk${idx}.$$.mkv"
  out_final="${mdir}/chunk-$(printf '%03d' "$idx").output.mkv"

  local _local_log_dir="${_CONVERT_V4_SCRIPT_DIR:-/tmp}/logs/ffmpeg-tmp"
  mkdir -p "$_local_log_dir" 2>/dev/null
  errfile="${_local_log_dir}/$(canonical_title_from_source "$src").chunk${idx}.${codec}.$$.stderr.log"

  args=(-y -nostdin -v warning -stats -ss "$start_ts")
  if [ "$end_ts" != "EOF" ]; then
    args+=(-to "$end_ts")
  fi
  args+=(-thread_queue_size 4096 -i "$src" -map 0:v:0 -map "0:a?" "${FF_VIDEO_ARGS[@]}")
  if [ "${#FF_VF[@]}" -gt 0 ]; then
    local vf_joined
    vf_joined="$(IFS=,; printf '%s' "${FF_VF[*]}")"
    args+=(-vf "$vf_joined")
  fi
  args+=(-c:a "$acodec" -b:a "$abr" -af "$(ffmpeg_audio_filter_chain "$acodec")")
  if [ "$acodec" = libopus ]; then args+=(-mapping_family 1); fi
  args+=(-max_muxing_queue_size 8192 -fps_mode cfr -f matroska "$out_tmp")

  rc=0
  run_tracked_encoder "chunk $idx encode" _run_capturing_stderr "$errfile" "${FFMPEG_CMD[@]}" "${args[@]}" || rc=$?
  if [ "$rc" -ne 0 ] || [ ! -s "$out_tmp" ]; then
    warn "Chunk encode failed (chunk $idx, rc=$rc): $src -- stderr: $errfile"
    rm -f -- "$out_tmp" 2>/dev/null
    chunk_mark_status "$src" "$idx" "encode-failed" "rc=$rc"
    return 1
  fi

  if ! mv -f -- "$out_tmp" "$out_final"; then
    warn "Chunk encode: failed to move output into manifest dir (chunk $idx, permission/space?): $out_final"
    rm -f -- "$out_tmp" 2>/dev/null
    chunk_mark_status "$src" "$idx" "encode-failed" "rc=mv-failed"
    return 1
  fi
  _restore_default_file_mode "$out_final"
  if ! chunk_mark_status "$src" "$idx" "encoded" "output=$out_final"; then
    warn "Chunk encode: output written but failed to record status (chunk $idx, permission?): $out_final"
    return 1
  fi
  log "Chunk $idx encoded: $(basename -- "$src") [$start_ts-$end_ts]"
  return 0
}

# Encoder-tier entry point (Phase 3 wiring, 2026-08-22): called from
# try_av1_convert in place of a whole-file encode whenever
# chunk_should_split "$src" is true. Splits (idempotent -- a no-op if
# another machine already split or is mid-split) then claims and encodes
# AT MOST ONE chunk before returning, matching this codebase's existing
# one-job-per-call convention (the outer scan loop's own iteration is what
# provides "keep going" -- see convert_run_pipeline_jobs/
# convert_library_batch, both of which just call this again next pass).
# Returns 0 whenever there was nothing IMMEDIATELY actionable (already
# fully claimed by other machines, or fully encoded pending verification)
# so the scan loop moves on to the next file rather than busy-looping on
# one title; returns 1 only on a real encode failure, matching
# process_video's other entry points' return-code contract.
chunk_parallel_process_video() {
  local src="$1"
  local idx rc=0

  if ! chunk_split_create_manifest "$src"; then
    # Either another machine is mid-split (transient -- retry next scan
    # pass) or .complete already existed (chunk_split_create_manifest's own
    # early-return, not a failure). Either way, fall through to try
    # claiming -- a manifest may already exist even though this call
    # didn't create it.
    :
  fi

  idx="$(chunk_claim_next "$src")" || {
    log "Chunk-parallel: no claimable chunk right now for $(basename -- "$src") (fully claimed or awaiting verification) -- moving on"
    return 0
  }

  chunk_encode_claimed "$src" "$idx" || rc=$?
  # Release the claim lock on BOTH outcomes, not just failure: once
  # chunk_mark_status has durably recorded a terminal-for-now status
  # (encoded or encode-failed), that status field -- not the lock -- is
  # what chunk_claim_next checks to decide eligibility. A lock left held
  # after a SUCCESSFUL encode is harmless today (status=encoded is already
  # skipped outright), but it becomes a real problem the moment the
  # verifier later marks this same index needs-requeue (ves-chunk-
  # verify.sh): needs-requeue is NOT in chunk_claim_next's skip list, so
  # another machine SHOULD be able to reclaim it immediately -- but an
  # orphaned lock from the original (successful) claim would force that
  # reclaim to wait out the full 7200s stale-lock ceiling instead. Found
  # via reasoning through the corrupted-chunk failure-path test before
  # running it live, 2026-08-23.
  chunk_release_claim "$src" "$idx" 2>/dev/null || true
  [ "$rc" -eq 0 ] || return 1
  return 0
}

# True (exit 0) only once every chunk in the manifest has status=verified.
chunk_all_verified() {
  local src="$1"
  local mdir f idx status_file st
  mdir="$(chunk_manifest_dir "$src")"
  [ -f "$mdir/.complete" ] || return 1
  for f in "$mdir"/chunk-*.meta; do
    [ -e "$f" ] || continue
    idx="$(awk -F= '/^index=/{print $2; exit}' "$f")"
    status_file="$mdir/chunk-$(printf '%03d' "$idx").status"
    [ -f "$status_file" ] || return 1
    st="$(awk -F= '/^status=/{print $2; exit}' "$status_file" 2>/dev/null)"
    [ "$st" = verified ] || return 1
  done
  return 0
}
