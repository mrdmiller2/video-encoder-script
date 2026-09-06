#!/usr/bin/env bash
# ves-profile-decision.sh -- path-based profile auto-detection (movies/tv/
# anime/wanime/vintage/classic/canime/mtv/vtv), output-path naming,
# oversized-AV1 recheck logic, and the existing-output/queue inspection
# used to skip already-complete canonical outputs. Pure move from the
# former monolithic script -- no logic changes.

is_video_file() {
  local f="$1" ext
  ext="$(to_lower "${f##*.}")"
  local e
  for e in "${VIDEO_EXTS[@]}"; do
    [ "$ext" = "$e" ] && return 0
  done
  return 1
}

# Populate nameref array with find predicates for VIDEO_EXTS: ( -iname '*.avi' -o ... )
build_find_video_pred() {
  local -n _pred="$1"
  local e first=1
  _pred=( '(' )
  for e in "${VIDEO_EXTS[@]}"; do
    if [ "$first" -eq 1 ]; then
      first=0
    else
      _pred+=( -o )
    fi
    _pred+=( -iname "*.${e}" )
  done
  _pred+=( ')' )
}

is_derived_output() {
  local base="${1##*/}"
  [[ "$base" =~ \.(AV1|av1|x265|X265)\.mkv$ ]] && return 0
  [[ "$base" =~ -av1\.mkv$ ]] && return 0
  # Windows port's own default -OutputSuffix (windows/convert.ps1).
  # Fleet machines can share the same NAS-mounted library trees, so a
  # bash machine must also recognize the other platform's output naming
  # -- without this, a bash rescan would treat a Windows-produced
  # "Title.AV1-WIN.mkv" as an unprocessed source (team review, 2026-08-05).
  [[ "$base" =~ \.AV1-WIN\.mkv$ ]] && return 0
  # Windows port's x265 size-guard fallback naming (team review,
  # 2026-08-06) -- same cascade risk as the AV1-WIN case above if missed.
  [[ "$base" =~ \.X265-WIN\.mkv$ ]] && return 0
  return 1
}

# is_derived_output() is a cheap, name-only guess used throughout the broad
# scan/queueing path -- intentionally never ffprobes there. But before any
# DESTRUCTIVE action (deleting a file, or mutating one in place) based on
# "this looks like our own AV1/x265 output", actually confirm the file's
# real video codec matches what its name claims. A file named "*.AV1.mkv"
# whose stream isn't actually AV1 (wrong format entirely, or even just a
# differently-encoded file that happens to share the naming convention) is
# proof it's NOT something this script produced, regardless of filename.
derived_output_codec_claim_matches() {
  local out="$1"
  local base="${out##*/}"
  local codec
  case "$base" in
    *.[Aa][Vv]1.mkv) codec="$(video_codec "$out" 2>/dev/null)"; [ "$codec" = "av1" ] ;;
    *.[Xx]265.mkv)   codec="$(video_codec "$out" 2>/dev/null)"; [ "$codec" = "hevc" ] ;;
    # Windows port's own output naming (team review, 2026-08-06) -- same
    # real codec-claim proof now applies to cross-platform outputs too,
    # closing the gap where a *.AV1-WIN.mkv/*.X265-WIN.mkv candidate fell
    # through to the permissive bare-.mkv case below with no ownership
    # proof at all before flag_bad_processed_output could delete it.
    *.[Aa][Vv]1-WIN.mkv) codec="$(video_codec "$out" 2>/dev/null)"; [ "$codec" = "av1" ] ;;
    *.[Xx]265-WIN.mkv)   codec="$(video_codec "$out" 2>/dev/null)"; [ "$codec" = "hevc" ] ;;
    # A bare Title.mkv (must_eliminate_remux_path's output -- no codec
    # suffix, since it's a plain stream-copy remux, not a re-encode) has no
    # codec claim to verify, so this permissive fallback trusts it. Team
    # review (2026-07-30) flagged the residual gap: callers relying on this
    # for "is this genuinely our own output" (flag_bad_processed_output's
    # deletion-safety check) get no real ownership proof for the bare-.mkv
    # case beyond the mtime-newer-than-source guard already applied there --
    # an unrelated same-named .mkv that's also newer than the source and
    # happens to pass validate_mkv_output's structural/duration check could
    # theoretically still be deleted. Accepted as a narrow, low-probability
    # residual risk rather than adding a new mkvextract dependency
    # fleet-wide just to read the VES_PROCESSED tag for this one case --
    # revisit if a lighter-weight ownership check becomes available.
    *) return 0 ;;
  esac
}

is_multipart_merged_file() {
  local base="${1##*/}"
  [[ "$base" =~ \.(merged|MERGED)\.mkv$ ]]
}

# Formats actively worth eliminating regardless of the resulting size: disc
# images (ISO/BDMV), raw transport streams, DVD VOBs, legacy AVI, and OGM.
# The normal size-keep guardrail exists to avoid trading a small size win for
# a much bigger file -- but for these, staying in the original format is
# itself the problem (poor seekability/compatibility for .ts/.m2ts, a disc
# image nobody can play directly, etc.), so the guardrail must not be
# allowed to leave one of these in place forever just because neither AV1
# nor x265 happened to shrink it. See try_av1_convert/try_x265_convert's
# final size-reject branches for where this changes behavior.
is_must_eliminate_format() {
  local src="$1"
  is_disk_source "$src" && return 0
  case "$(to_lower "${src##*.}")" in
    ts|m2ts|vob|avi|ogm|mpg|mpeg|m2v|rm|rmvb|divx|wmv|flv|asf) return 0 ;;
  esac
  return 1
}

x265_output_path() {
  local src="$1"
  local dir title
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src")"
  printf '%s/%s.x265.mkv' "$dir" "$title"
}

av1_output_path() {
  local src="$1"
  local dir title
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src")"
  printf '%s/%s.AV1.mkv' "$dir" "$title"
}

# Windows port's own default -OutputSuffix (windows/convert.ps1) naming
# convention. Used by inspect_existing_outputs_for_queue's cross-platform
# check so a bash machine recognizes a title a Windows fleet machine
# already finished, instead of redundantly re-encoding it (team review,
# 2026-08-06) -- the title-lock cross-check only prevents a SIMULTANEOUS
# collision; without this, sequential duplicate work across platforms was
# still unbounded (bash's own done-log has no record of a Windows-only
# completion).
windows_output_path() {
  local src="$1"
  local dir title
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src")"
  printf '%s/%s.AV1-WIN.mkv' "$dir" "$title"
}

# Windows port's x265 size-guard fallback naming (team review, 2026-08-06)
# -- same cross-platform completion-recognition need as windows_output_path.
windows_x265_output_path() {
  local src="$1"
  local dir title
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src")"
  printf '%s/%s.X265-WIN.mkv' "$dir" "$title"
}

is_oversized_av1() {
  local src="$1"
  local orig orig_sz av1_sz lim
  orig="$(find_original_source_for_av1 "$src")"
  [ -n "$orig" ] || return 1
  orig_sz="$(file_size_bytes "$orig")"
  av1_sz="$(file_size_bytes "$src")"
  lim="$AV1_MAX_OVERSHOOT_PCT"
  # Must agree with size_keep_policy_av1's own upscale-tiered threshold
  # (that's the function that actually decided to keep this file at
  # encode time) -- otherwise a legitimately-kept upscaled output
  # (allowed up to size_keep_policy_av1's more generous tiered limit,
  # e.g. 50-100% growth) would ALWAYS test positive here under the flat
  # 20% limit, causing endless wasted resample/re-encode churn on an
  # output that was correctly kept in the first place. Found in team
  # E2E review, 2026-07-20.
  if source_is_upscaled "$orig" 2>/dev/null; then
    lim="$(effective_upscale_overshoot_pct "$orig_sz")"
  fi
  awk -v o="$orig_sz" -v a="$av1_sz" -v lim="$lim" \
    'BEGIN { if (o <= 0) exit 1; exit !(((a - o) / o) * 100 > lim) }'
}

# Non-derived sibling used as size reference for an AV1 output or AV1 library file.
find_original_source_for_av1() {
  local src="$1"
  local dir title ext f
  dir="$(dirname "$src")"
  title="$(canonical_title_from_file "$src")"
  for ext in mkv mp4 avi ts; do
    f="$dir/$title.$ext"
    [ -f "$f" ] || continue
    [ "$f" = "$src" ] && continue
    is_derived_output "$f" && continue
    printf '%s' "$f"
    return 0
  done
  return 1
}

av1_overshoot_pct_vs_original() {
  local src="$1"
  local orig orig_sz av1_sz
  orig="$(find_original_source_for_av1 "$src")"
  [ -n "$orig" ] || return 0
  orig_sz="$(file_size_bytes "$orig")"
  av1_sz="$(file_size_bytes "$src")"
  awk -v o="$orig_sz" -v a="$av1_sz" 'BEGIN {
    if (o <= 0) { print 0; exit }
    printf "%.1f", ((a - o) / o) * 100
  }'
}

needs_oversized_av1_recheck() {
  local f="$1"
  is_derived_output "$f" || return 1
  is_oversized_av1 "$f" || return 1
  [ ! -f "$(x265_output_path "$f")" ]
}

anime_title_year() {
  local p="$1" year=""
  while [[ "$p" =~ \(([0-9]{4})\) ]]; do
    year="${BASH_REMATCH[1]}"
    p="${p#*"${BASH_REMATCH[0]}"}"
  done
  [ -n "$year" ] && printf '%s' "$year"
}

anime_profile_for_path() {
  local p="$1" year
  year="$(anime_title_year "$p")"
  if [ -n "$year" ] && [ "$year" -le "$CLASSIC_ANIME_YEAR_CUTOFF" ] 2>/dev/null; then
    printf 'canime'
  else
    printf 'anime'
  fi
}

detect_profile_for_path() {
  local p="/${1#/}/"
  if [ -n "$FORCE_PROFILE" ]; then
    printf '%s' "$FORCE_PROFILE"
    return 0
  fi
  case "$p" in
    */Movies/Japanese/Animation/*) return 2 ;;
    */Movies/Anime/*) anime_profile_for_path "$p"; return 0 ;;
    # Anime TV shows (Japanese/Chinese/Korean anime-styled) live at a
    # top-level Anime/ folder, sibling to Movies/Television at the media
    # root -- not nested under Television/<Country>/*. No separate TV-anime
    # profile exists (matches Movies/Anime's tuning; MTV/VTV only split
    # western live-action TV, not anime).
    */Anime/*) anime_profile_for_path "$p"; return 0 ;;
    # Routing-layer compound buckets (2026-09-06): a title whose per-shot-search
    # BEHAVIOUR matches a different anchor than its metadata era gets moved to a
    # "<container>-<modifier>" folder that reuses an existing proven profile plus
    # ONE carried adjustment -- no scattered per-title overrides.
    #
    # `Animation-Grain` = western animation whose film grain makes VMAF target 94
    # cost MORE bits than the source (e.g. American Pop 1981, Bakshi rotoscope --
    # measured: wanime@VMAF94 = 131% of source on grain-heavy reels, allocator
    # baseline-unfit). It keeps the `wanime` encode params (line-art tuning is
    # still right; `classic`/`vintage` grain-synth measured *worse* here) but
    # carries a relaxed VMAF target via vmaf_target_for_source() -- VMAF
    # over-penalizes heavy grain, so ~92 there is playback-equivalent to ~94 on
    # clean content and stays inside the project fidelity ceiling.
    # Checked before */Animation/* (order-safe regardless -- "/Animation-Grain/"
    # is not "/Animation/").
    */Animation-Grain/*)   printf 'wanime';  return 0 ;;
    # Concerts / Stand-Up Comedy / Learning Series (2026-09-05): own libraries,
    # own profiles. Single encode profile each -- the era subfolders
    # (Vintage/Classic/Modern) exist for library organisation + the D-val
    # budget-fraction survey's per-era measurement, but do not (yet) split the
    # encode profile the way live-action movie eras do. Learning Series is flat
    # by design (instructional talking-heads -- no era dimension). Checked before
    # */Animation/* so an animated concert film still routes to concert.
    */Concerts/*) printf 'concert'; return 0 ;;
    */Stand-Up\ Comedy/*) printf 'standup'; return 0 ;;
    */Learning\ Series/*) printf 'learning'; return 0 ;;
    */Animation/*) printf 'wanime'; return 0 ;;
    */Movies/*/Modern/*) printf 'movies'; return 0 ;;
    */Movies/*/Classic/*) printf 'classic'; return 0 ;;
    */Movies/*/Vintage/*) printf 'vintage'; return 0 ;;
    */Television/*/Modern/*) printf 'mtv'; return 0 ;;
    */Television/*/Vintage/*) printf 'vtv'; return 0 ;;
  esac
  return 1
}

profile_for_source() {
  local src="${1:-$SEARCH_PATH}" profile rc
  if [ -n "$PROFILE_CONTEXT" ]; then
    printf '%s' "$PROFILE_CONTEXT"
    return 0
  fi
  profile="$(detect_profile_for_path "$src")" && { printf '%s' "$profile"; return 0; }
  rc=$?
  if [ "$rc" -eq 2 ]; then
    err "Ambiguous profile for Movies/Japanese/Animation: use --profile anime or --profile wanime explicitly ($src)"
    return 2
  fi
  if [ "$src" != "$SEARCH_PATH" ]; then
    profile="$(detect_profile_for_path "$SEARCH_PATH")" && { printf '%s' "$profile"; return 0; }
    rc=$?
    if [ "$rc" -eq 2 ]; then
      err "Ambiguous profile for Movies/Japanese/Animation: use --profile anime or --profile wanime explicitly ($SEARCH_PATH)"
      return 2
    fi
  fi
  err "Cannot auto-detect an encoding profile from path; use --profile explicitly: $src"
  return 1
}

uses_profile() {
  local wanted="$1" src="${2:-$SEARCH_PATH}" actual
  actual="$(profile_for_source "$src" 2>/dev/null)" || return 1
  [ "$actual" = "$wanted" ]
}

uses_anime_profile() { uses_profile anime "${1:-$SEARCH_PATH}"; }

uses_wanime_profile() { uses_profile wanime "${1:-$SEARCH_PATH}"; }

uses_vintage_profile() { uses_profile vintage "${1:-$SEARCH_PATH}"; }

uses_classic_profile() { uses_profile classic "${1:-$SEARCH_PATH}"; }

uses_mtv_profile() { uses_profile mtv "${1:-$SEARCH_PATH}"; }

uses_vtv_profile() { uses_profile vtv "${1:-$SEARCH_PATH}"; }

record_media_inspection() {
  local src="$1"
  local note="${2:-}"
  local name codec dur dur_h res
  [ "$DRY_RUN" = true ] || return 0
  name="$(basename "$src")"
  codec="$(video_codec "$src")"
  dur="$(video_duration "$src")"
  dur_h="$(format_duration_hms "$dur")"
  res="$(video_resolution "$src")"
  local hdr_note
  hdr_note="$(hdr_color_note "$src")"
  stats_log_append "[$(date -u '+%H:%M:%S')] INSPECT: $name"
  stats_log_append "  format: $codec | length: $dur_h (${dur}s) | resolution: $res"
  [ -n "$hdr_note" ] && stats_log_append "  hdr: $hdr_note"
  [ -n "$note" ] && stats_log_append "  note: $note"
  STATS_INSPECTED=$((STATS_INSPECTED + 1))
}

record_disk_inspection() {
  local src="$1"
  local note="${2:-}"
  local sel title_idx title_dur res kind dur_h name
  [ "$DRY_RUN" = true ] || return 0
  name="$(basename "$src")"
  if is_iso_file "$src"; then
    kind="ISO"
  else
    kind="Blu-ray"
  fi
  sel="$(select_dominant_disk_title "$src")"
  case "$sel" in
    SKIP:*)
      stats_log_append "[$(date -u '+%H:%M:%S')] INSPECT: $name"
      stats_log_append "  format: disc ($kind) | length: n/a | resolution: n/a"
      if [ -n "$note" ]; then
        stats_log_append "  note: $note — ${sel#SKIP:}"
      else
        stats_log_append "  note: ${sel#SKIP:}"
      fi
      ;;
    SELECT:*)
      IFS=':' read -r _ title_idx title_dur _ <<< "$sel"
      dur_h="$(format_duration_hms "$title_dur")"
      res="$(handbrake_title_resolution "$src" "$title_idx")"
      stats_log_append "[$(date -u '+%H:%M:%S')] INSPECT: $name"
      stats_log_append "  format: disc ($kind) title $title_idx | length: $dur_h (${title_dur}s) | resolution: $res"
      [ -n "$note" ] && stats_log_append "  note: $note"
      ;;
    *)
      stats_log_append "[$(date -u '+%H:%M:%S')] INSPECT: $name"
      stats_log_append "  format: disc ($kind) | length: unknown | resolution: unknown"
      stats_log_append "  note: title scan failed"
      ;;
  esac
  STATS_INSPECTED=$((STATS_INSPECTED + 1))
}

is_hevc_codec() {
  case "$1" in
    hevc|h265|x265) return 0 ;;
  esac
  return 1
}

# True when --skip-av1 / --skip-x265 excludes this source from conversion.
should_skip_source_format() {
  local src="$1"
  local codec
  is_disk_source "$src" && return 1
  codec="$(video_codec "$src")"
  if [ "$SKIP_AV1" = true ] && [ "$codec" = "av1" ]; then
    return 0
  fi
  if [ "$SKIP_X265" = true ] && is_hevc_codec "$codec"; then
    return 0
  fi
  return 1
}

skip_reason_for_format() {
  local src="$1"
  local codec
  codec="$(video_codec "$src")"
  if [ "$SKIP_AV1" = true ] && [ "$codec" = "av1" ]; then
    printf 'AV1 source (--skip-av1)'
    return 0
  fi
  if [ "$SKIP_X265" = true ] && is_hevc_codec "$codec"; then
    printf 'HEVC/x265 source (--skip-x265)'
    return 0
  fi
  return 1
}

# Returns 0 and prints the path when a canonical output exists and passes validate_mkv_output.
find_complete_canonical_output() {
  local src="$1"
  local hb_dur="${2:-}"
  local quick="${3:-false}"
  local av1_out x265_out remux_out=""

  av1_out="$(av1_output_path "$src")"
  x265_out="$(x265_output_path "$src")"
  is_must_eliminate_format "$src" && remux_out="$(must_eliminate_remux_path "$src")"
  if [ ! -f "$av1_out" ] && [ ! -f "$x265_out" ] && { [ -z "$remux_out" ] || [ ! -f "$remux_out" ]; }; then
    return 1
  fi

  if [ -f "$av1_out" ] && validate_mkv_output "$src" "$av1_out" "$hb_dur" "$quick"; then
    printf '%s' "$av1_out"
    return 0
  fi

  if [ -f "$x265_out" ] && validate_mkv_output "$src" "$x265_out" "$hb_dur" "$quick"; then
    printf '%s' "$x265_out"
    return 0
  fi

  # Must-eliminate-format sources can also be "done" via the plain
  # stream-copy remux fallback (see must_eliminate_fallback_or_fail) when
  # both AV1 and x265 genuinely failed. Without this, a source that already
  # has a valid plain-MKV remux would never be recognized as complete and
  # would retry the whole (doomed) AV1/x265 pipeline every single scan.
  if [ -n "$remux_out" ] && [ -f "$remux_out" ] && validate_mkv_output "$src" "$remux_out" "$hb_dur" "$quick"; then
    printf '%s' "$remux_out"
    return 0
  fi
  return 1
}

has_complete_canonical_output() {
  local src="$1"
  local hb_dur="${2:-}"
  local quick="${3:-false}"
  find_complete_canonical_output "$src" "$hb_dur" "$quick" >/dev/null
}

clear_incomplete_canonical_outputs() {
  local src="$1"
  local hb_dur="${2:-}"
  local av1_out x265_out
  local any_timeout=false

  av1_out="$(av1_output_path "$src")"
  if [ -f "$av1_out" ]; then
    MKV_VALIDATE_DEFERRED=false
    MKV_VALIDATE_TIMED_OUT=false
    if ! validate_mkv_output "$src" "$av1_out" "$hb_dur"; then
      if [ "$MKV_VALIDATE_DEFERRED" = true ]; then
        warn "Deferred mkvalidator for $av1_out — leaving file for full structure check"
      elif [ "$MKV_VALIDATE_TIMED_OUT" = true ]; then
        warn "Validation timed out for $av1_out — leaving output in place for retry next run"
        any_timeout=true
      else
        flag_bad_processed_output "$src" "$av1_out" "invalid/incomplete AV1 output"
      fi
    fi
  fi

  x265_out="$(x265_output_path "$src")"
  if [ -f "$x265_out" ]; then
    MKV_VALIDATE_DEFERRED=false
    MKV_VALIDATE_TIMED_OUT=false
    if ! validate_mkv_output "$src" "$x265_out" "$hb_dur"; then
      if [ "$MKV_VALIDATE_DEFERRED" = true ]; then
        warn "Deferred mkvalidator for $x265_out — leaving file for full structure check"
      elif [ "$MKV_VALIDATE_TIMED_OUT" = true ]; then
        warn "Validation timed out for $x265_out — leaving output in place for retry next run"
        any_timeout=true
      else
        flag_bad_processed_output "$src" "$x265_out" "invalid/incomplete x265 output"
      fi
    fi
  fi

  if is_must_eliminate_format "$src"; then
    local remux_out
    remux_out="$(must_eliminate_remux_path "$src")"
    if [ -f "$remux_out" ]; then
      MKV_VALIDATE_DEFERRED=false
      MKV_VALIDATE_TIMED_OUT=false
      if ! validate_mkv_output "$src" "$remux_out" "$hb_dur"; then
        if [ "$MKV_VALIDATE_DEFERRED" = true ]; then
          warn "Deferred mkvalidator for $remux_out — leaving file for full structure check"
        elif [ "$MKV_VALIDATE_TIMED_OUT" = true ]; then
          warn "Validation timed out for $remux_out — leaving output in place for retry next run"
          any_timeout=true
        else
          flag_bad_processed_output "$src" "$remux_out" "invalid/incomplete plain remux output"
        fi
      fi
    fi
  fi

  # Sticky for skip_if_complete_canonical_output: any timeout aborts encode this run.
  if [ "$any_timeout" = true ]; then
    MKV_VALIDATE_TIMED_OUT=true
  fi
}

# During scan: accept good outputs; delete truly bad processed MKVs; queue deferred/missing.
# Returns 0 if source should be queued for convert/reconvert; 1 if skip (complete or bad source).
inspect_existing_outputs_for_queue() {
  local src="$1"
  local av1_out x265_out

  av1_out="$(av1_output_path "$src")"
  x265_out="$(x265_output_path "$src")"

  if [ -f "$av1_out" ]; then
    MKV_VALIDATE_DEFERRED=false
    MKV_VALIDATE_TIMED_OUT=false
    if validate_mkv_output "$src" "$av1_out" "" true; then
      done_log_append done "$src"
      return 1
    fi
    if [ "$MKV_VALIDATE_DEFERRED" = true ]; then
      return 0
    fi
    if [ "$MKV_VALIDATE_TIMED_OUT" = true ]; then
      warn "Validation timed out for $av1_out — leaving output in place for retry next run"
      return 1
    fi
    flag_bad_processed_output "$src" "$av1_out" "invalid processed AV1 (scan)"
  fi

  if [ -f "$x265_out" ]; then
    MKV_VALIDATE_DEFERRED=false
    MKV_VALIDATE_TIMED_OUT=false
    if validate_mkv_output "$src" "$x265_out" "" true; then
      done_log_append done "$src"
      return 1
    fi
    if [ "$MKV_VALIDATE_DEFERRED" = true ]; then
      return 0
    fi
    if [ "$MKV_VALIDATE_TIMED_OUT" = true ]; then
      warn "Validation timed out for $x265_out — leaving output in place for retry next run"
      return 1
    fi
    flag_bad_processed_output "$src" "$x265_out" "invalid processed x265 (scan)"
  fi

  # Cross-platform: a Windows fleet machine may have already finished this
  # title (windows/convert.ps1's own default -OutputSuffix naming). Without
  # this, bash's done-log has no record of a Windows-only completion, so
  # every scan would redundantly re-encode a title someone else already
  # finished (team review, 2026-08-06) -- the title-lock cross-check only
  # prevents a SIMULTANEOUS collision, not this sequential duplicate work.
  # Same validate-then-trust-or-reject pattern as the two checks above;
  # validate_mkv_output has no bash-specific expectations (no VES tag
  # check), so a genuinely valid Windows output passes identically.
  local win_out
  win_out="$(windows_output_path "$src")"
  if [ -f "$win_out" ]; then
    MKV_VALIDATE_DEFERRED=false
    MKV_VALIDATE_TIMED_OUT=false
    if validate_mkv_output "$src" "$win_out" "" true; then
      done_log_append done "$src"
      return 1
    fi
    if [ "$MKV_VALIDATE_DEFERRED" = true ]; then
      return 0
    fi
    if [ "$MKV_VALIDATE_TIMED_OUT" = true ]; then
      warn "Validation timed out for $win_out — leaving output in place for retry next run"
      return 1
    fi
    flag_bad_processed_output "$src" "$win_out" "invalid processed Windows-port output (scan)"
  fi

  # Same cross-platform reasoning as the AV1-WIN check just above, for
  # Windows's x265 size-guard fallback naming (team review, 2026-08-06).
  local win_x265_out
  win_x265_out="$(windows_x265_output_path "$src")"
  if [ -f "$win_x265_out" ]; then
    MKV_VALIDATE_DEFERRED=false
    MKV_VALIDATE_TIMED_OUT=false
    if validate_mkv_output "$src" "$win_x265_out" "" true; then
      done_log_append done "$src"
      return 1
    fi
    if [ "$MKV_VALIDATE_DEFERRED" = true ]; then
      return 0
    fi
    if [ "$MKV_VALIDATE_TIMED_OUT" = true ]; then
      warn "Validation timed out for $win_x265_out — leaving output in place for retry next run"
      return 1
    fi
    flag_bad_processed_output "$src" "$win_x265_out" "invalid processed Windows-port x265 output (scan)"
  fi

  if is_must_eliminate_format "$src"; then
    local remux_out
    remux_out="$(must_eliminate_remux_path "$src")"
    if [ -f "$remux_out" ]; then
      MKV_VALIDATE_DEFERRED=false
      MKV_VALIDATE_TIMED_OUT=false
      if validate_mkv_output "$src" "$remux_out" "" true; then
        done_log_append done "$src"
        return 1
      fi
      if [ "$MKV_VALIDATE_DEFERRED" = true ]; then
        return 0
      fi
      if [ "$MKV_VALIDATE_TIMED_OUT" = true ]; then
        warn "Validation timed out for $remux_out — leaving output in place for retry next run"
        return 1
      fi
      flag_bad_processed_output "$src" "$remux_out" "invalid processed plain remux (scan)"
    fi
  fi

  return 0
}

skip_if_complete_canonical_output() {
  local src="$1"
  local hb_dur="${2:-}"
  local complete_out

  if complete_out="$(find_complete_canonical_output "$src" "$hb_dur")"; then
    log "Skip — complete output exists: $complete_out"
    record_skip "$src" "complete output exists"
    return 0
  fi
  clear_incomplete_canonical_outputs "$src" "$hb_dur"
  # Timeout on an existing output: leave file, do not encode/overwrite this run.
  if [ "$MKV_VALIDATE_TIMED_OUT" = true ]; then
    warn "Validation timed out for existing output of $src — leaving in place for retry next run (not encoding)"
    return 0
  fi
  return 1
}
