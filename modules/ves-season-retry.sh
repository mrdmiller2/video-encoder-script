#!/usr/bin/env bash
# ves-season-retry.sh -- TV episode/season detection and the season-level
# shrink-vs-predicted-no-shrink retry heuristic. Originally a pure move from
# the former monolithic script; is_tv_episode() below got a real bug fix on
# 2026-08-04 (team-reviewed) -- see its own comment.

# Naming/organization still uses this broad library-path predicate; encoding
# profile selection never does.
is_tv_library_path() {
  case "$1" in */Television/*|*/Television) return 0 ;; esac
  return 1
}

# TV episode markers: S01E01, EP1, Episode 1, 1x01, trailing -01, leading 01-/065-
is_tv_episode() {
  local f="$1"
  local stem
  stem="$(movie_title_from_file "$f")"

  [[ "$stem" =~ [Ss][0-9]{1,2}[Ee][0-9]{1,3} ]] && return 0
  [[ "$stem" =~ [Ss][0-9]{1,2}[[:space:]_\.-]+[Ee][0-9]{1,3} ]] && return 0
  [[ "$stem" =~ [Ee][Pp][[:space:]]*[0-9]{1,3} ]] && return 0
  [[ "$stem" =~ [Ee]pisode[[:space:]]*[0-9]{1,3} ]] && return 0
  [[ "$stem" =~ [0-9]{1,2}[xX][0-9]{1,2} ]] && return 0
  # The two generic trailing-number catch-alls below (dash-prefixed and
  # bare-space-prefixed -- e.g. "Show - 05" / "Show 05") both false-positive
  # on multi-part-source markers (Part/Pt/CD/Disc N, in any of their
  # supported separator forms: "Title - Part 1", "Title CD-1", "Title.Pt.1"
  # -- see MULTIPART_PART_REGEX in ves-config.sh), which are a movie-split
  # convention, not TV numbering. Checked once, up front, to guard both
  # rules identically -- an earlier version of this fix only guarded the
  # space-prefixed rule, missing hyphen-joined forms like "Title-Part-1"
  # (team review, 2026-08-04). Without this exemption, real 2+ part movies
  # were silently misclassified as TV episodes: is_tv_show_directory() then
  # flagged their folder as a TV show directory from a single false-positive
  # file, which made detect_multipart_groups() skip the whole folder and
  # never merge them -- found via real-content regression testing,
  # 2026-08-04, confirmed pre-existing (present unchanged since before this
  # file's own extraction). Genuine multi-part TV episodes remain protected
  # two other ways, both unaffected by this exemption: an explicit
  # season/episode marker anywhere in the name is caught by the rules above
  # it, and is_tv_show_directory()'s is_tv_library_path() fallback still
  # treats any 2+-video folder under a real Television/ path as a TV show
  # directory regardless of individual filenames -- matching this project's
  # past, opposite-direction incident ("Multipart merge ate two-part TV
  # episodes"), which this exemption is deliberately scoped not to reopen.
  if ! [[ "$stem" =~ $MULTIPART_PART_REGEX ]]; then
    [[ "$stem" =~ -[[:space:]]*[0-9]{1,2}$ ]] && return 0
    [[ "$stem" =~ [[:space:]][0-9]{1,2}$ ]] && return 0
  fi
  # 2-3 digits only: covers sequential numbering up to 999 episodes (e.g.
  # "065-The Obsolete Man") without also matching a 4-digit year-prefixed
  # movie title ("1999-Title", "2001-A Space Odyssey").
  [[ "$stem" =~ ^[0-9]{2,3}- ]] && return 0
  return 1
}

# Extracts just the season digits from an episode filename (e.g. "S01E13" ->
# "01"), for grouping same-season episodes under the season-level shrink-
# heuristic retry (see SEASON_RETRY_THRESHOLD_PCT). Falls back to a single
# shared bucket for filenames that don't carry a season number at all
# (sequential-numbered libraries), treating the whole folder as one implicit
# season in that case.
season_number_from_filename() {
  local f="$1"
  local stem
  stem="$(movie_title_from_file "$f")"
  if [[ "$stem" =~ [Ss]([0-9]{1,2})[[:space:]_.-]*[Ee][0-9]{1,3} ]]; then
    # Zero-pad after stripping any leading zero (forced base-10 so bash
    # doesn't misread e.g. "08"/"09" as an invalid octal literal) -- "S1E01"
    # and "S01E01" must land in the same bucket, not split across two.
    printf '%02d\n' "$((10#${BASH_REMATCH[1]}))"
    return 0
  fi
  printf '%s\n' "_unknown"
}

# Groups by show/season folder AND season number together (a unit-separator
# byte joins them, since it can never appear in a real path) -- a bare season
# number alone would pool unrelated shows' "S01" episodes into one bucket,
# letting one show's shrink rate force retries on a completely different
# show's sample-rejected episodes. See season_retry_pass.
season_retry_key() {
  local f="$1"
  printf '%s\x1f%s' "$(dirname "$f")" "$(season_number_from_filename "$f")"
}

# Parent folder holds TV episodes — keep the folder intact.
# Plex requires season folders to be literally named "Season NN" (or
# "Specials" for season 0) -- see support.plex.tv's TV naming guide. That's a
# cheaper and more reliable TV signal than scanning file contents: a
# directory named this way IS a season folder, full stop, regardless of what
# the episode filenames inside it look like.
is_plex_season_dir_name() {
  local base="$1"
  [[ "$base" =~ ^[Ss]eason[[:space:]]+[0-9]+$ ]] && return 0
  [[ "$base" =~ ^[Ss]pecials$ ]] && return 0
  return 1
}

is_tv_show_directory() {
  local dir="$1"
  local f count=0 videos=0
  is_plex_season_dir_name "$(basename "$dir")" && return 0
  shell_nullglob_on
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    is_video_file "$f" || continue
    is_derived_output "$f" && continue
    videos=$((videos + 1))
    is_tv_episode "$f" && count=$((count + 1))
  done
  shell_nullglob_off
  [ "$count" -ge 1 ] && return 0
  if is_tv_library_path "$dir" && [ "$videos" -ge 2 ]; then
    return 0
  fi
  return 1
}

# Season-level shrink-vs-predicted-no-shrink heuristic (see
# SEASON_RETRY_THRESHOLD_PCT): for each (show folder, season number) seen
# during this run, if at least that percentage of its sample-tested episodes
# actually shrank, the remaining episodes the sample test predicted wouldn't
# shrink get one real forced-encode attempt (bypassing the sample-test gate
# entirely, routed by the file's actual codec -- try_av1_convert for an AV1
# source, try_x265_convert with force_transcode=true for an HEVC/x265 source
# -- both of which already judge the actual result against the same
# guardrails as a normal encode). Keyed by folder+season together
# (season_retry_key), not season
# number alone -- otherwise one show's "S01" shrink rate could force retries
# on a completely different show's sample-rejected "S01" episodes. A single-
# file run, or a season with fewer sample-tested episodes than would ever
# reach the threshold, naturally never triggers this -- nothing special-
# cased for that, the ratio math alone handles it.
#
# On failure, this deliberately does NOT re-tag the file itself. try_av1_convert
# can return non-zero for reasons that have nothing to do with size (encode
# tool failure, validation timeout, an unexpected output-path collision) --
# blindly treating any non-zero return as "confirmed no size win" would
# wrongly tag a merely-transient failure as permanently settled. The one case
# that IS a genuine, confirmed size rejection (AV1 and the x265 fallback both
# exceeded the guardrail) is already tagged correctly by try_x265_convert's
# own existing tag_guardrail_exceeded call in that exact path -- nothing
# further is needed here for that case either. Every other failure is simply
# left as still-tagged-preexisting from its original sample-skip, to be
# reconsidered on a future run same as any other transient failure would be.
season_retry_pass() {
  local key tested shrink file dir season idx=0 total ok codec
  for key in "${!SEASON_SAMPLE_TESTED_COUNT[@]}"; do
    tested="${SEASON_SAMPLE_TESTED_COUNT[$key]}"
    shrink="${SEASON_SHRINK_COUNT[$key]:-0}"
    [ "$tested" -gt 0 ] || continue
    [ -n "${SEASON_NO_SHRINK_FILES[$key]:-}" ] || continue
    if ! awk -v s="$shrink" -v t="$tested" -v thresh="$SEASON_RETRY_THRESHOLD_PCT" \
         'BEGIN { exit !((s / t) * 100 >= thresh) }'; then
      continue
    fi
    dir="${key%$'\x1f'*}"
    season="${key##*$'\x1f'}"
    total="$(printf '%s' "${SEASON_NO_SHRINK_FILES[$key]}" | grep -c .)"
    log "Season $season ($dir): ${shrink}/${tested} sample-tested episodes shrank (>=${SEASON_RETRY_THRESHOLD_PCT}%) — retrying $total episode(s) the sample predicted wouldn't shrink"
    idx=0
    SEASON_RETRY_IN_PROGRESS=true
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      [ -f "$file" ] || continue
      idx=$((idx + 1))
      ok=false
      if ! begin_convert_job "$file" "$idx" "$total"; then
        continue
      fi
      log "Season heuristic retry — forcing a real encode attempt (bypassing the sample prediction): $file"
      # Route by the file's actual current codec, not unconditionally through
      # try_av1_convert -- an HEVC/x265 source (the process_existing_x265
      # skip cohort) would otherwise fall into try_x265_convert's HEVC-MKV
      # stream-copy remux shortcut on any AV1 rejection/failure, which
      # "succeeds" by just repackaging the same bytes into a new container
      # instead of actually re-encoding, silently defeating the whole point
      # of this retry. force_transcode=true (5th arg) forces the real
      # re-encode path instead, same as process_existing_x265's own "x265"
      # decision branch already does for exactly this reason.
      codec="$(video_codec "$file" 2>/dev/null)" || codec=""
      if [ "$codec" = "av1" ]; then
        try_av1_convert "$file" && ok=true || ok=false
      else
        try_x265_convert "$file" "" "" false true && ok=true || ok=false
      fi
      if [ "$ok" = false ]; then
        log "Season heuristic retry did not produce a smaller file (or hit an unrelated failure) — leaving prior tag/state in place: $file"
      fi
      end_convert_job "$file" "$idx" "$total" "$ok"
    done <<<"${SEASON_NO_SHRINK_FILES[$key]}"
    SEASON_RETRY_IN_PROGRESS=false
    # Defensive verification (2026-08-11): found via real fleet monitoring
    # that a season-retry pass on JJACKSON logged "retrying 3 episode(s)"
    # but only "Job 1 of 3" ever appeared before the run reported "Done" --
    # root cause not pinned down despite an isolated repro of this exact
    # loop (with a mocked always-rejecting try_x265_convert) behaving
    # correctly through all 3 iterations, and every begin_convert_job
    # failure path already warn()s on skip (none of those warnings
    # appeared either). Whatever the mechanism, silently completing fewer
    # retries than promised, with zero trace, is exactly the kind of gap
    # this project's whole "verify before trusting" posture exists to
    # catch -- this makes any future recurrence loud and diagnosable
    # instead of invisible, without changing behavior when idx and total
    # already agree (the overwhelmingly common case).
    if [ "$idx" -ne "$total" ]; then
      warn "Season $season ($dir): retry pass only processed $idx of $total promised episode(s) — investigate before trusting this run's season-retry results"
    fi
  done
}
