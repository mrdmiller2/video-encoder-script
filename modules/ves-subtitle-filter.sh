#!/usr/bin/env bash
# ves-subtitle-filter.sh -- subtitle language detection/normalization,
# external-subtitle collection, and the tri-state real-content filter
# used to decide which subtitle tracks survive into the output. Pure
# move from the former monolithic script -- no logic changes.

is_subtitle_file() {
  local f="$1" ext
  ext="$(to_lower "${f##*.}")"
  local e
  for e in "${SUB_EXTS[@]}"; do
    [ "$ext" = "$e" ] && return 0
  done
  return 1
}

guess_lang_from_path() {
  local p="$1"
  case "$p" in
    *Chinese*|*Cantonese*|*Mandarin*) echo zh ;;
    *Japanese*) echo ja ;;
    *Korean*) echo ko ;;
    *French*) echo fr ;;
    *German*) echo de ;;
    *Spanish*) echo es ;;
    *English*) echo en ;;
    *) echo en ;;
  esac
}

detect_subtitle_lang() {
  local sub="$1"
  local context_path="$2"
  local base="${sub##*/}"
  local stem="${base%.*}"
  local   ext="$(to_lower "${base##*.}")"

  if [[ "$base" =~ \.(en|eng)\. ]]; then echo eng; return; fi
  if [[ "$base" =~ \.(zh|zho|chi|chs|cht)\. ]]; then echo chi; return; fi
  if [[ "$base" =~ \.(ja|jpn)\. ]]; then echo jpn; return; fi
  if [[ "$base" =~ \.(ko|kor)\. ]]; then echo kor; return; fi
  if [[ "$base" =~ \.(fr|fre)\. ]]; then echo fre; return; fi
  if [[ "$base" =~ \.(de|ger)\. ]]; then echo ger; return; fi
  if [[ "$base" =~ \.(es|spa)\. ]]; then echo spa; return; fi
  if [[ "$base" =~ \.(it|ita)\. ]]; then echo ita; return; fi
  if [[ "$base" =~ \.(pt|por)\. ]]; then echo por; return; fi
  if [[ "$base" =~ \.(ru|rus)\. ]]; then echo rus; return; fi

  if [[ "$stem" =~ \.(en|eng)$ ]]; then echo eng; return; fi
  if [[ "$stem" =~ \.(zh|chi|zho)$ ]]; then echo chi; return; fi
  if [[ "$stem" =~ \.(ja|jpn)$ ]]; then echo jpn; return; fi
  if [[ "$stem" =~ \.(ko|kor)$ ]]; then echo kor; return; fi

  case "$stem" in
    *english*|*English*) echo eng ;;
    *chinese*|*Chinese*|*mandarin*) echo chi ;;
    *japanese*|*Japanese*) echo jpn ;;
    *korean*|*Korean*) echo kor ;;
    *) lang_iso3_from_guess "$(guess_lang_from_path "$context_path")" ;;
  esac
}

lang_iso3_from_guess() {
  case "$1" in
    en) echo eng ;;
    zh) echo chi ;;
    ja) echo jpn ;;
    ko) echo kor ;;
    fr) echo fre ;;
    de) echo ger ;;
    es) echo spa ;;
    *) echo eng ;;
  esac
}

lang_iso3_normalize() {
  local code
  code="$(to_lower "$1")"
  case "$code" in
    en|eng|english) echo eng ;;
    zh|zho|chi|chs|cht|chinese|mandarin|cantonese) echo chi ;;
    ja|jpn|japanese) echo jpn ;;
    ko|kor|korean) echo kor ;;
    fr|fre|french) echo fre ;;
    de|ger|german) echo ger ;;
    es|spa|spanish) echo spa ;;
    it|ita|italian) echo ita ;;
    pt|por|portuguese) echo por ;;
    ru|rus|russian) echo rus ;;
    und|"") echo "" ;;
    *) echo "$code" ;;
  esac
}

lang_display_name() {
  local code
  code="$(lang_iso3_normalize "$1")"
  case "$code" in
    eng) echo English ;;
    chi) echo Chinese ;;
    jpn) echo Japanese ;;
    kor) echo Korean ;;
    fre) echo French ;;
    ger) echo German ;;
    spa) echo Spanish ;;
    ita) echo Italian ;;
    por) echo Portuguese ;;
    rus) echo Russian ;;
    *) [ -n "$code" ] && echo "$code" || echo Unknown ;;
  esac
}

subtitle_matches_video() {
  local sub="$1"
  local video="$2"
  local title stem
  title="$(canonical_title_from_source "$video")"
  stem="$(movie_title_from_file "$sub")"
  stem="${stem%.*}"
  [[ "$stem" == "$title"* ]] || [[ "$title" == *"$stem"* ]]
}

collect_external_subtitles() {
  local src="$1"
  local dir item
  dir="$(media_content_dir "$src")"
  shell_nullglob_on
  for item in "$dir"/*; do
    [ -f "$item" ] || continue
    is_subtitle_file "$item" || continue
    subtitle_matches_video "$item" "$src" && printf '%s\n' "$item"
  done
  shell_nullglob_off
}

subtitle_target_name() {
  local sub="$1"
  local movie_file="$2"
  local lang ext
  lang="$(detect_subtitle_lang "$sub" "$movie_file")"
  ext="$(to_lower "${sub##*.}")"
  printf '%s.%s' "$lang" "$ext"
}

validate_mkv_subtitle_tracks() {
  local dst="$1"
  local n_subs dur subs_list src_rc window start
  local i forced forced_rc pts rc any_ok=false any_checked=false any_ambiguous=false

  SUBTITLE_CHECK_TIMED_OUT=false
  # `&& src_rc=0 || src_rc=$?`, not a bare assignment followed by `src_rc=$?`
  # on the next line -- see audio_track_reaches_near_eof's comment: a bare
  # failing assignment aborts the whole script under `set -e` right there,
  # before the rc= line ever runs (verified via direct bash testing,
  # 2026-07-22).
  subs_list="$(run_ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$dst" 2>/dev/null)" && src_rc=0 || src_rc=$?
  # E2E review (2026-07-30): was `-eq 124` only, treating any OTHER non-zero
  # probe error (not a confirmed timeout, but still not a confirmed "no
  # subtitle streams" either) the same as a clean, successful empty result --
  # inconsistent with this same function's own per-track ambiguity handling
  # further down, and could wrongly skip subtitle validation entirely for a
  # file that genuinely has subtitle tracks ffprobe just failed to enumerate.
  # A truly subtitle-free file has ffprobe exit 0 with empty output (not an
  # error), so `src_rc -ne 0` here only catches genuine probe failures.
  if [ -z "$subs_list" ] && [ "$src_rc" -ne 0 ]; then
    SUBTITLE_CHECK_TIMED_OUT=true
    return 124
  fi
  n_subs="$(printf '%s\n' "$subs_list" | grep -c . || true)"
  [ "${n_subs:-0}" -gt 0 ] || return 0

  dur="$(video_duration "$dst")"
  window="$(awk -v d="$dur" -v p="$SUBTITLE_SYNC_TAIL_GAP_PCT" 'BEGIN { w = d*p/100; if (w<1) w=1; print w }')"
  # Nothing meaningful to judge a tail-gap window against on a very short clip.
  awk -v d="$dur" -v w="$window" 'BEGIN { exit !(d>60 && d>w) }' || return 0
  start="$(awk -v d="$dur" -v w="$window" 'BEGIN { r = d - w; if (r < 0) r = 0; print r }')"

  # Check EVERY subtitle track, not just s:0 (the first/default one) -- a
  # real source can have its default-flagged subtitle track authored wrong
  # (empty, broken) while a DIFFERENT, non-default track has the complete,
  # real subtitles. Failing the whole source over one mis-flagged empty
  # track when a working track exists elsewhere is disproportionate: a
  # source found during the 2026-07-29 fleet test ("The Great Beauty
  # (2013)") had exactly this shape -- s:0 (default=1) was completely
  # empty, s:2 (default=0) had the full, complete subtitles running to
  # within minutes of the film's actual end. User decision, same date: only
  # defer when EVERY non-forced subtitle track lacks a cue in the tail
  # window, not just the default one. A forced track (foreign-dialogue-
  # only, signs-only) is still expected to stop long before the end by
  # design -- keep asking ffprobe's disposition flag directly per track
  # rather than guessing from cue density, same reasoning as before.
  #
  # Ambiguity handling: a timeout or probe error on any ONE track's checks
  # must not by itself confirm or deny the verdict -- keep examining the
  # remaining tracks. Only commit to a hard failure if every non-forced
  # track gave a clean, unambiguous "no cues" result; if none passed but at
  # least one was ambiguous, soft-fail (124) the same as before rather than
  # risk turning an NFS hiccup into a permanent Deferred/ move.
  for i in $(seq 0 $((n_subs - 1))); do
    # `&& forced_rc=0 || forced_rc=$?` -- a bare assignment here would
    # crash the script under `set -e` on any ffprobe failure/timeout.
    forced="$(run_ffprobe -v error -select_streams "s:$i" -show_entries stream_disposition=forced \
      -of default=noprint_wrappers=1:nokey=1 "$dst" 2>/dev/null)" && forced_rc=0 || forced_rc=$?
    if [ "$forced_rc" -ne 0 ]; then
      any_ambiguous=true
      continue
    fi
    [ "$forced" = "1" ] && continue
    any_checked=true

    # `&& rc=0 || rc=$?`, not `rc=${PIPESTATUS[0]}` after a bare assignment
    # -- verified via direct bash testing (2026-07-22) that the bare form
    # crashes the whole script under `set -e` the instant the pipe's
    # pipefail-computed exit status is non-zero.
    pts="$(run_ffprobe -v error -read_intervals "${start}%+${window}" -select_streams "s:$i" \
      -show_entries packet=pts_time -of csv=p=0 "$dst" 2>/dev/null | head -1)" && rc=0 || rc=$?
    if [ "$rc" -eq 124 ]; then
      any_ambiguous=true
      continue
    fi
    if [ -z "$pts" ] && [ "$rc" -ne 0 ] && [ "$rc" -ne 141 ]; then
      any_ambiguous=true
      continue
    fi
    if [ -n "$pts" ]; then
      any_ok=true
      break
    fi
  done

  # No non-forced tracks existed at all -- nothing to judge.
  [ "$any_checked" = true ] || return 0
  if [ "$any_ok" = true ]; then
    return 0
  fi
  if [ "$any_ambiguous" = true ]; then
    SUBTITLE_CHECK_TIMED_OUT=true
    return 124
  fi
  warn "Validation failed: no subtitle track has cues in the last ${SUBTITLE_SYNC_TAIL_GAP_PCT}% (${window}s) of $dst -- likely a truncated/mismatched subtitle track"
  record_corrupt_mkv "$dst" "subtitle_truncated"
  return 1
}

# A source can flag a subtitle stream (container-level track present,
# player shows it as a selectable option) while carrying zero actual
# renderable content -- either no packets at all, or packets whose text
# payload is empty/whitespace once cue-timing markup is stripped. Mapping
# these into the output gives a player a meaningless empty selection.
# Checked once per subtitle stream index against the ORIGINAL source
# (stage 2 reads subtitles from the source, not the video-only stage-1
# file) so the filtered list can replace a blanket "-map 0:s?"/"1:s?".
subtitle_stream_has_real_content() {
  local src="$1" idx="$2" codec first_pkt pkt_rc raw_srt dec_rc decode_out

  # `&& pkt_rc=0 || pkt_rc=$?` -- a bare failing assignment would abort
  # the whole script under `set -e`; same idiom as
  # validate_mkv_subtitle_tracks' pts check just above. `head -1` legitimately
  # SIGPIPEs ffprobe once it has its one line (rc 141) -- not an error, and
  # a deliberate short-circuit: the original `| grep -c .` form scanned
  # every packet in the WHOLE file before counting, which on a dense
  # multi-subtitle-track file over NAS could mean dozens of near-full-file
  # ffprobe passes (found in team review, 2026-08-02) -- `head -1` only
  # needs ffprobe to find ONE packet before stopping.
  #
  # E2E team review (2026-08-02): the original form
  # (`... | grep -c .` with a bare `|| pkt_count=0` fallback) collapsed a
  # genuine ffprobe failure/timeout into the same "0 packets" result as a
  # confirmed-empty stream, silently stripping REAL subtitle content on
  # any transient probe error. Now distinguishes "confirmed no packets"
  # (rc 0 or 141, empty output) from "probe failed/timed out" (any other
  # rc) -- the latter keeps the stream rather than risk discarding real
  # data (verify-before-delete: a subprocess failure is never proof of
  # absence).
  first_pkt="$(run_ffprobe -v error -select_streams "s:$idx" -show_entries packet=pts_time \
    -of csv=p=0 "$src" 2>/dev/null | head -1)" && pkt_rc=0 || pkt_rc=$?
  if [ -z "$first_pkt" ] && [ "$pkt_rc" -ne 0 ] && [ "$pkt_rc" -ne 141 ]; then
    warn "Subtitle stream s:$idx in $src: packet-presence probe failed/timed out -- keeping rather than risk discarding real content"
    return 0
  fi
  [ -n "$first_pkt" ] || return 1

  codec="$(run_ffprobe -v error -select_streams "s:$idx" -show_entries stream=codec_name \
    -of default=nw=1:nk=1 "$src" 2>/dev/null)"
  case "$codec" in
    subrip|srt|ass|ssa|mov_text|webvtt|text)
      # Capture ffmpeg's raw SRT output and check ITS OWN exit status
      # first (not the exit status of a trailing sed/grep filter pipeline,
      # which would mask a real ffmpeg failure behind grep's own routine
      # "found nothing" rc=1 -- found in the same 2026-08-02 review).
      raw_srt="$(run_ffmpeg_validation -v error -i "$src" -map "0:s:$idx" -f srt - 2>/dev/null)" && dec_rc=0 || dec_rc=$?
      if [ -z "$raw_srt" ] && [ "$dec_rc" -ne 0 ]; then
        warn "Subtitle stream s:$idx in $src: text-decode probe failed/timed out -- keeping rather than risk discarding real content"
        return 0
      fi
      # Strip cue numbers/timing lines/blank lines, then ASS override
      # blocks ({\an5}, {\pos(...)}, etc.) and any <tag>/</tag> wrapper
      # ffmpeg's srt encoder adds for styled ASS cues -- anything left
      # over is real text. A track can have packets but still be
      # functionally empty (e.g. every cue authored as "" or as
      # position-only override codes with no dialogue) -- found via
      # direct testing (2026-08-02): an ASS cue containing only "{\an5}"
      # survived the original cue-number/timing-only strip as
      # "<font size=...>{\an5}</font>", a false negative.
      decode_out="$(printf '%s\n' "$raw_srt" \
        | sed -E 's/\{\\[^}]*\}//g; s/<[^>]*>//g' \
        | grep -vE '^[0-9]+$|^[0-9:,]+ --> [0-9:,]+$|^[[:space:]]*$')"
      [ -n "$decode_out" ]
      ;;
    *)
      # Bitmap/other subtitle codecs (dvd_subtitle, hdmv_pgs_subtitle,
      # etc.) can't be text-stripped -- packet presence (already confirmed
      # above) is the only reliable signal for these. The original
      # decode-error grep here (stripping on any stderr line containing
      # "error"/"invalid") was removed after team review (2026-08-02)
      # flagged it as a false-positive risk: PGS/DVD tracks pulled from
      # physical media routinely produce benign, non-fatal decode
      # warnings containing those exact words, which was silently
      # stripping perfectly viewable subtitle tracks.
      return 0
      ;;
  esac
}

build_real_subtitle_map_args() {
  local input_idx="$1" src="$2" n_subs subs_list i

  REAL_SUBTITLE_MAP_ARGS=()
  # `&& subs_rc=0 || subs_rc=$?` -- same ambiguous-vs-confirmed-empty
  # distinction as subtitle_stream_has_real_content(). Team review
  # (2026-08-02): the original bare form treated any ffprobe
  # failure/timeout enumerating subtitle streams as "this source has zero
  # subtitle streams", which would have silently dropped EVERY subtitle
  # track (real or not) rather than just the empty ones. On ambiguous
  # failure, fall back to an unfiltered blanket map instead.
  local subs_rc
  subs_list="$(run_ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$src" 2>/dev/null)" && subs_rc=0 || subs_rc=$?
  if [ -z "$subs_list" ] && [ "$subs_rc" -ne 0 ]; then
    warn "Subtitle stream enumeration failed/timed out for $src -- falling back to unfiltered subtitle mapping rather than risk discarding all subtitles"
    REAL_SUBTITLE_MAP_ARGS=(-map "${input_idx}:s?")
    return 0
  fi
  n_subs="$(printf '%s\n' "$subs_list" | grep -c . || true)"
  [ "${n_subs:-0}" -gt 0 ] || return 0

  for i in $(seq 0 $((n_subs - 1))); do
    if subtitle_stream_has_real_content "$src" "$i"; then
      REAL_SUBTITLE_MAP_ARGS+=(-map "${input_idx}:s:${i}")
    else
      warn "Subtitle stream s:$i in $src has no renderable content -- stripping from output"
      record_stripped_subtitle "$src" "$i"
    fi
  done
}
