#!/usr/bin/env bash
# ves-multipart-merge.sh -- multi-part source detection/compatibility
# checking and the lossless merge-before-encode pipeline. Pure move from
# the former monolithic script -- no logic changes.

multipart_part_regex() {
  # Captures: 1=title, 2=marker word (unused), 3=part number.
  # bash [[ =~ ]] is POSIX ERE — no (?:...) non-capturing groups, so the
  # marker is a real capture group and the number is BASH_REMATCH[3].
  printf '%s' '^(.*[^ ._-])[ ._-]*([Pp][Aa][Rr][Tt]|[Pp][Tt]|[Cc][Dd]|[Dd][Ii][Ss][Cc])[ ._-]*([0-9]{1,2})$'
}

# Groups candidate files in one directory by common title; returns groups with
# 2+ members via a nameref array of "title\tpart1|part2|..." (parts sorted by
# number, pipe-separated absolute paths). Non-multipart files are not emitted.
detect_multipart_groups() {
  local dir="$1"
  local -n _groups="$2"
  local -A by_title=()
  local -A order_key=()
  local f base stem ext title num re
  _groups=()

  # Multi-part merging is a movie feature (a film split across Part 1/Part
  # 2/CD1/CD2 discs). "Show - S01E15 - Part 1.mkv" / "Part 2.mkv" are two
  # SEPARATE episodes in every TV naming convention -- same codec/res, so the
  # compat check would pass and mkvmerge would happily concatenate two
  # distinct episodes into one .merged.mkv. A season/show folder is far more
  # likely to hold two-part episodes than a genuinely split movie, so skip
  # multipart detection entirely here.
  is_tv_show_directory "$dir" && return 0

  re="$(multipart_part_regex)"

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="${f##*/}"
    is_derived_output "$f" && continue
    is_multipart_merged_file "$f" && continue
    stem="${base%.*}"
    ext="${base##*.}"
    if [[ "$stem" =~ $re ]]; then
      title="${BASH_REMATCH[1]}"
      # Marker word normalized to lowercase folds "Part"/"PART"/"part" together
      # but keeps "part" and "disc" as distinct groups -- "Movie Part 1.mkv"
      # and "Movie Disc 1.mkv" in the same folder are two different naming
      # conventions for what may be unrelated files, not sequential parts of
      # the same source, and should never merge together just because the
      # title text matches.
      local marker="${BASH_REMATCH[2],,}"
      num="${BASH_REMATCH[3]}"
      # A literal '|' in a filename would corrupt the pipe-joined parts list
      # this function builds below (and the '|'-split read in
      # ensure_multipart_merge) -- refuse to group such a file rather than
      # risk feeding a mis-split path to mkvmerge/ffprobe.
      case "$f" in
        *'|'*) warn "Multi-part detection: skipping '$f' — filename contains '|', which this grouping cannot represent safely"; continue ;;
      esac
      # Zero-pad the sort key so "2" sorts before "10"
      by_title["$title|$marker|$ext"]+="$(printf '%03d' "$((10#$num))")::$f"$'\n'
    fi
  done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null)

  local key entries sorted parts nums
  for key in "${!by_title[@]}"; do
    entries="${by_title[$key]}"
    sorted="$(printf '%s' "$entries" | sort -t: -k1,1)"
    parts="$(printf '%s' "$sorted" | sed -E 's/^[0-9]+:://' | paste -sd'|' -)"
    # require at least 2 parts to treat as a multi-part group
    [ "$(printf '%s' "$parts" | tr '|' '\n' | grep -c .)" -ge 2 ] || continue
    # Numbering must be contiguous (1,2,3,... with no gaps) -- "Part 1" +
    # "Part 3" with "Part 2" missing/misnamed/lost would otherwise merge as
    # a valid-looking 2-part group, silently producing an output missing a
    # whole chunk of the source with nothing here ever flagging the gap.
    nums="$(printf '%s' "$sorted" | sed -E 's/^([0-9]+):.*/\1/')"
    if ! printf '%s' "$nums" | awk '{ n=$0+0; if (NR==1 && n!=1) { exit 1 } if (NR>1 && n!=prev+1) { exit 1 } prev=n }'; then
      title="${key%%|*}"
      warn "Multi-part group '$title' has non-contiguous part numbers — left as separate sources for human review"
      continue
    fi
    title="${key%%|*}"
    _groups+=("${title}"$'\t'"${parts}")
  done
}

# ffprobe-based compatibility check across all parts. Returns 0 if all parts
# share codec/resolution/pix_fmt/frame-rate; logs the mismatch otherwise.
multipart_parts_compatible() {
  local -a parts=("$@")
  local ref="" cur ref_a="" cur_a p ref_a_seen=false
  for p in "${parts[@]}"; do
    cur="$(run_ffprobe -v error -select_streams v:0 \
      -show_entries stream=codec_name,width,height,pix_fmt,avg_frame_rate \
      -of csv=p=0 "$p" 2>/dev/null)"
    if [ -z "$ref" ]; then
      ref="$cur"
    elif [ "$cur" != "$ref" ]; then
      warn "Multi-part mismatch — '$(basename "$p")' differs from '$(basename "${parts[0]}")' (codec/resolution/pix_fmt/fps): $cur vs $ref"
      return 1
    fi
    # Video-only compatibility isn't enough: two parts can share codec/
    # resolution/fps and still have genuinely different audio (e.g. Part 1 =
    # 5.1, Part 2 = stereo down-mix), which mkvmerge will happily append
    # anyway, producing a merged file with an audio discontinuity at the
    # seam. Compare every audio track's codec+channel-count line-for-line.
    cur_a="$(run_ffprobe -v error -select_streams a \
      -show_entries stream=codec_name,channels \
      -of csv=p=0 "$p" 2>/dev/null)"
    # "$ref_a" being empty is a genuine, legitimate value here (a silent
    # part, no audio track at all) -- unlike the video check above, where an
    # empty ref only ever means "not yet set" since every real video file
    # has a video stream. Using emptiness alone as the "unset" sentinel
    # would let a silent first part + an audio-bearing second part slip
    # through uncaught (ref_a looks "unset" both times, mismatch branch
    # never triggers). An explicit seen-flag disambiguates the two cases.
    if [ "$ref_a_seen" = false ]; then
      ref_a="$cur_a"
      ref_a_seen=true
    elif [ "$cur_a" != "$ref_a" ]; then
      warn "Multi-part mismatch — '$(basename "$p")' has different audio tracks than '$(basename "${parts[0]}")' (codec/channel-count): $cur_a vs $ref_a"
      return 1
    fi
  done
  return 0
}

multipart_state_key() {  # concatenated size|mtime of every part, for cache invalidation
  local p key=""
  for p in "$@"; do
    key+="$(mkv_structure_stat_key "$p" 2>/dev/null || printf 'x')|"
  done
  printf '%s' "$key"
}

# Merge one detected group. Prints the merged file's absolute path on success
# (stdout only); all logging goes to stderr. Returns 1 on validation/merge
# failure (group is left for independent per-part processing).
ensure_multipart_merge() {
  local dir="$1" title="$2" parts_pipe="$3"
  local -a parts=()
  IFS='|' read -r -a parts <<<"$parts_pipe"
  local merged="$dir/$title.merged.mkv"
  local state="$dir/.${title}.multipart-merge.state"
  local want_key have_key

  want_key="$(multipart_state_key "${parts[@]}")"
  if [ -f "$merged" ] && [ -f "$state" ]; then
    have_key="$(cat "$state" 2>/dev/null)"
    if [ "$have_key" = "$want_key" ]; then
      printf '%s' "$merged"
      return 0
    fi
    log_err "Multi-part source changed since last merge — re-merging: $title"
  elif [ -f "$merged" ] && [ ! -f "$state" ]; then
    # A regular file already sits at this exact name, but we have no record
    # (.state) of having created it ourselves. "Title.merged.mkv" is an
    # unusual enough pattern that this is unlikely by coincidence, but
    # mkvmerge -o would silently overwrite it either way -- refuse rather
    # than guess.
    warn "Multi-part merge target already exists with no record of us creating it — leaving as-is for human review: $merged"
    return 1
  fi

  if ! multipart_parts_compatible "${parts[@]}"; then
    printf '%s\n' "${parts[@]}" >>"${MULTIPART_MISMATCH_LOG:-/dev/null}" 2>/dev/null
    warn "Multi-part group '$title' has incompatible parts — left as separate sources for human review"
    return 1
  fi

  log_err "Multi-part source detected (${#parts[@]} files) — merging: $title"
  if [ "$DRY_RUN" = true ]; then
    log_err "[dry-run] Would merge: ${parts[*]}"
    return 1
  fi

  # $merged is a predictable name (Title.merged.mkv) beside real source
  # parts. A one-time neutralization-then-later-open pattern still leaves a
  # real race window (mkvmerge's own merge time) for another writer to swap
  # in a symlink between the check and the open -- an external review round
  # found this exact gap. Merge into a private, mktemp -d'd, mode-0700
  # sibling directory instead, validate the result there, then mv it into
  # place -- mkvmerge never opens the final predictable path directly.
  local tmp_dir tmp_merged
  tmp_dir="$(mktemp -d "${dir}/.convert-multipart-XXXXXX" 2>/dev/null)" || {
    warn "Could not create a private merge staging directory in $dir — leaving multi-part group '$title' for human review"
    return 1
  }
  chmod 700 "$tmp_dir" 2>/dev/null || true
  _orphan_write_stage_host_marker "$tmp_dir"
  tmp_merged="$tmp_dir/$title.merged.mkv"

  local -a mm_args=(-o "$tmp_merged" --quiet)
  local i
  for i in "${!parts[@]}"; do
    if [ "$i" -eq 0 ]; then
      mm_args+=("${parts[$i]}")
    else
      mm_args+=(+ "${parts[$i]}")
    fi
  done

  # mkvmerge exit codes: 0 clean, 1 succeeded with warnings (e.g. no explicit
  # --append-to given — harmless for a simple sequential append), 2 real failure.
  # 124 = validation-path timeout (possible stalled mount) — leave parts alone.
  local mm_rc=0
  run_mkvmerge "${mm_args[@]}" >/dev/null 2>&1 || mm_rc=$?
  if [ "$mm_rc" -eq 124 ]; then
    rm -rf "$tmp_dir"
    warn "mkvmerge multi-part merge timed out (possible stalled mount) for '$title' — left as separate sources"
    return 1
  fi
  if [ "$mm_rc" -ge 2 ]; then
    rm -rf "$tmp_dir"
    warn "mkvmerge failed to append multi-part group '$title' (exit $mm_rc) — left as separate sources for human review"
    printf '%s\n' "${parts[@]}" >>"${MULTIPART_MISMATCH_LOG:-/dev/null}" 2>/dev/null
    return 1
  fi
  if [ ! -s "$tmp_merged" ]; then
    warn "Multi-part merge produced an empty file — discarding: $merged"
    rm -rf "$tmp_dir"
    return 1
  fi

  # mkvmerge exiting 0/1 and producing a non-empty file isn't proof the
  # merge captured every part's content -- a partial append or a degraded
  # ("succeeded with warnings") run could still silently drop content, the
  # same "exit code alone isn't proof of real work" gap already found and
  # fixed once this session in validate_mkv_decode_windows(). Cheap
  # cross-check: the merged output's duration should be approximately the
  # sum of the parts' own durations. Generous tolerance (10%) since container
  # overhead/rounding differs from a straight sum; this is a coarse sanity
  # check for "silently missing a whole part," not a frame-accurate audit.
  local parts_dur_sum=0 p_dur merged_dur dur_diff_pct p
  for p in "${parts[@]}"; do
    p_dur="$(video_duration "$p")"
    parts_dur_sum="$(awk -v a="$parts_dur_sum" -v b="${p_dur:-0}" 'BEGIN { printf "%.3f", a+b }')"
  done
  merged_dur="$(video_duration "$tmp_merged")"
  if awk -v a="$parts_dur_sum" -v b="$merged_dur" 'BEGIN { exit !(a>0 && b>0) }'; then
    dur_diff_pct="$(awk -v a="$parts_dur_sum" -v b="$merged_dur" 'BEGIN { d=(a>b)?a-b:b-a; printf "%.1f", (d/a)*100 }')"
    if awk -v p="$dur_diff_pct" 'BEGIN { exit !(p>10.0) }'; then
      warn "Multi-part merge duration mismatch for '$title': parts sum to ${parts_dur_sum}s but merged output is ${merged_dur}s (${dur_diff_pct}% off) — discarding, left as separate sources for human review"
      rm -rf "$tmp_dir"
      printf '%s\n' "${parts[@]}" >>"${MULTIPART_MISMATCH_LOG:-/dev/null}" 2>/dev/null
      return 1
    fi
  fi

  # Same private-staging trick for the cache state file: write it fresh in
  # the private dir, then mv both into their real predictable paths. mv
  # replaces whatever is at the destination (including a symlink) directly,
  # atomically, without ever dereferencing/following it. Both mv's are
  # explicitly checked (team review, 2026-07-24): a bare mv failing here
  # under set -e would abort the whole script mid-finalization instead of
  # falling back gracefully. If the state mv fails after the merge mv
  # already succeeded, retry it once (the merge itself is expensive to
  # redo, so don't throw it away over what's usually a transient hiccup on
  # the very next filesystem op); if that ALSO fails, undo the merge move
  # entirely instead of leaving $merged present with no $state -- a later
  # scan hitting that exact combination treats it as an unexplained
  # pre-existing file and permanently defers to human review rather than
  # retrying (team review, second pass: the original fallback here claimed
  # "a future scan will re-evaluate this merge," which is not what actually
  # happens). Reverting cleanly means the next run just redoes the merge
  # from scratch, the same as if nothing had been attempted yet.
  printf '%s' "$want_key" >"$tmp_dir/state"
  if ! mv -f -- "$tmp_merged" "$merged" 2>/dev/null; then
    warn "Could not move merged output into place for '$title' — leaving parts for retry: $merged"
    rm -rf "$tmp_dir" 2>/dev/null
    return 1
  fi
  if ! mv -f -- "$tmp_dir/state" "$state" 2>/dev/null; then
    sleep 1
    if ! mv -f -- "$tmp_dir/state" "$state" 2>/dev/null; then
      warn "Merged output written but its state cache could not be moved into place for '$title' — reverting the merge so the next run retries cleanly: $merged"
      rm -f -- "$merged" 2>/dev/null
      rm -rf "$tmp_dir" 2>/dev/null
      return 1
    fi
  fi
  _restore_default_file_mode "$merged"
  _restore_default_file_mode "$state"
  rm -rf "$tmp_dir" 2>/dev/null
  log_err "Multi-part merge OK: $title ($(human_size_bytes "$(file_size_bytes "$merged")"))"
  printf '%s' "$merged"
}

# Rewrites a nameref array of discovered file paths: detects multi-part
# groups per directory, merges them (cached), substitutes the merged file for
# the raw parts, and drops raw parts that were successfully consumed. Files
# that are not part of any group pass through unchanged. Called from
# find_convert_videos_under / find_videos_at_root — every scan path benefits.
apply_multipart_merging() {
  local -n _files="$1"
  [ "${#_files[@]}" -gt 0 ] || return 0
  [ -n "${MULTIPART_MISMATCH_LOG:-}" ] || MULTIPART_MISMATCH_LOG="${JOB_SIDECAR_DIR:-$JOB_ROOT}/multipart_mismatch.txt"

  local -A dirs_seen=()
  local f d
  for f in "${_files[@]}"; do
    d="$(dirname "$f")"
    dirs_seen["$d"]=1
  done

  local -A merged_for_dir=()   # dir -> "merged1 merged2 ..." (space-joined)
  for d in "${!dirs_seen[@]}"; do
    local -a groups=()
    detect_multipart_groups "$d" groups
    [ "${#groups[@]}" -gt 0 ] || continue
    local g title parts_pipe merged
    for g in "${groups[@]}"; do
      title="${g%%$'\t'*}"
      parts_pipe="${g#*$'\t'}"
      merged="$(ensure_multipart_merge "$d" "$title" "$parts_pipe")" || continue
      [ -n "$merged" ] || continue
      merged_for_dir["$d"]+="$merged"$'\n'
      local -a consumed=()
      IFS='|' read -r -a consumed <<<"$parts_pipe"
      local cp
      for cp in "${consumed[@]}"; do MULTIPART_CONSUMED["$cp"]=1; done
    done
  done

  [ "${#MULTIPART_CONSUMED[@]}" -gt 0 ] || return 0

  # A source directory may be scanned more than once in a single run (batch
  # mode re-inspects before queueing); once a merge exists on disk, a later
  # raw find() will see the .merged.mkv file directly as an ordinary video —
  # dedupe against what passthrough already added, not just against itself.
  local -a out=()
  local seen="|"
  for f in "${_files[@]}"; do
    if [ -n "${MULTIPART_CONSUMED[$f]:-}" ]; then
      continue
    fi
    case "$seen" in *"|$f|"*) continue ;; esac
    seen+="$f|"
    out+=("$f")
  done
  for d in "${!merged_for_dir[@]}"; do
    while IFS= read -r merged; do
      [ -n "$merged" ] || continue
      case "$seen" in *"|$merged|"*) continue ;; esac
      seen+="$merged|"
      out+=("$merged")
    done <<<"${merged_for_dir[$d]}"
  done
  _files=("${out[@]}")
}
