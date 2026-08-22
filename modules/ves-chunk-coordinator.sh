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

# Creates the manifest directory + one boundary file per chunk. Idempotent
# -- if a complete manifest already exists (a ".complete" marker written
# last, after every chunk file), does nothing and returns success, so a
# second machine racing to split the same title is harmless (whichever
# wins the mkdir below does the real work; the loser just walks away).
chunk_split_create_manifest() {
  local src="$1"
  local mdir tmpdir n prev_ts ts
  mdir="$(chunk_manifest_dir "$src")"
  [ -f "$mdir/.complete" ] && return 0

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

  cat >"${tmpdir}/manifest.meta" <<EOF
source=$src
chunk_count=$n
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
        verified) continue ;;
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
