#!/usr/bin/env bash
# ves-validation.sh -- MKV structure/decode/metadata/audio validation,
# VES-processed tag read/write, and the corrupt/bad-source evidence
# capture + flagging paths. Pure move from the former monolithic script --
# no logic changes.

# Cheap, tag-only check for the current major version's processed marker --
# survives renames/moves since it's embedded in the container, not derived from
# the path or filename. Used as a second, defense-in-depth skip signal alongside
# the folder done-log and derived-output naming convention. Defined here
# (rather than alongside write_ves_processed_tag further down) because the
# startup single-file-mode confirmation prompt needs to call it before that
# point in the file is reached.
mkv_ves_tag_present() {
  local f="$1"
  case "${f,,}" in *.mkv) ;; *) return 1 ;; esac
  [ -f "$f" ] || return 1
  run_ffprobe -v error -show_entries "format_tags=${VES_TAG_NAME}" \
    -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null | grep -qF "VES ${VES_MAJOR}."
}

# Reads the VES tag's own embedded " [tools: ...]" bracket (see
# current_tool_versions_tag_suffix / _mkv_write_single_tag, added v5.0.32F)
# and reports whether THIS machine's svtav1/x265 are a meaningfully newer
# major.minor than what's recorded there. A tag with no bracket at all
# (written before v5.0.32F) is never "drifted" -- consistent with the
# done-log/folder-done fingerprint checks: no forced full-library recheck
# the moment this ships, only going forward from a real recorded version.
mkv_ves_tag_tools_drifted() {
  local f="$1" tag_val bracket fp
  case "${f,,}" in *.mkv) ;; *) return 1 ;; esac
  [ -f "$f" ] || return 1
  tag_val="$(run_ffprobe -v error -show_entries "format_tags=${VES_TAG_NAME}" \
    -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null)"
  case "$tag_val" in *"[tools: "*) ;; *) return 1 ;; esac
  bracket="${tag_val#*\[tools: }"
  bracket="${bracket%%]*}"
  fp="svtav1=$(_fp_field "$bracket" svtav1);x265=$(_fp_field "$bracket" x265)"
  tools_fingerprint_is_stale "$fp"
}

video_codec() {
  run_ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null || echo unknown
}

video_height() {
  run_ffprobe -v error -select_streams v:0 -show_entries stream=height \
    -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null || echo 0
}

video_duration() {
  local src="$1"
  local dur
  dur="$(run_ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$src" 2>/dev/null || true)"
  if [ -n "$dur" ] && awk -v d="$dur" 'BEGIN { exit !(d+0 > 0) }'; then
    printf '%s' "$dur"
    return 0
  fi
  # Legacy/transport streams sometimes omit format duration; use primary video stream.
  dur="$(run_ffprobe -v error -select_streams v:0 -show_entries stream=duration \
    -of default=noprint_wrappers=1:nokey=1 "$src" 2>/dev/null || true)"
  if [ -n "$dur" ] && awk -v d="$dur" 'BEGIN { exit !(d+0 > 0) }'; then
    printf '%s' "$dur"
    return 0
  fi
  printf '0'
}

video_width() {
  run_ffprobe -v error -select_streams v:0 -show_entries stream=width \
    -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null || echo 0
}

format_duration_hms() {
  awk -v s="$1" 'BEGIN {
    if (s <= 0) { print "unknown"; exit }
    h = int(s / 3600)
    m = int((s % 3600) / 60)
    sec = int(s % 60)
    printf "%d:%02d:%02d", h, m, sec
  }'
}

video_resolution() {
  local src="$1"
  local w h
  w="$(video_width "$src")"
  h="$(video_height "$src")"
  if [ "$w" -gt 0 ] && [ "$h" -gt 0 ]; then
    printf '%sx%s' "$w" "$h"
  else
    printf 'unknown'
  fi
}

video_color_primaries() {
  run_ffprobe -v error -select_streams v:0 -show_entries stream=color_primaries \
    -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null || echo unknown
}

video_color_transfer() {
  run_ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer \
    -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null || echo unknown
}

source_has_dolby_vision() {
  local src="$1"
  run_ffprobe -v error -select_streams v:0 -show_entries stream_side_data=side_data_type \
    -of csv=p=0 "$src" 2>/dev/null | search_ci 'DOVI configuration record'
}

source_is_hdr10_wcg() {
  local src="$1"
  local prim transfer
  prim="$(video_color_primaries "$src")"
  transfer="$(video_color_transfer "$src")"
  [ "$prim" = bt2020 ] && { [ "$transfer" = smpte2084 ] || [ "$transfer" = arib-std-b67 ]; }
}

hdr_color_note() {
  local src="$1"
  if source_has_dolby_vision "$src"; then
    printf 'Dolby Vision'
  elif source_is_hdr10_wcg "$src"; then
    printf 'HDR10/WCG'
  else
    printf ''
  fi
}

label_mkv_tracks() {
  local mkv="$1"
  local src="$2"
  local title="${3:-$(canonical_title_from_file "$src")}"

  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] label audio/subtitle tracks + title on $mkv"
    return 0
  fi
  [ -f "$mkv" ] || return 0
  # mkvpropedit edits its target in place by reopening the path -- if $mkv
  # were replaced with a symlink in the window since finalize_staged_encode_output
  # (or optimize_mkv_for_streaming's mv) put a real file there, this would edit
  # whatever the symlink points to rather than our own output. Refuse rather
  # than risk mutating an unrelated file's (possibly a real source's) headers.
  [ ! -L "$mkv" ] || { warn "Refusing to label tracks — $mkv is a symlink (possible race)"; return 0; }

  # Joining with a plain space and re-splitting with Python's default
  # .split() corrupts any command whose path contains a space (e.g. macOS
  # "/Applications/MKVToolNix 88.app/.../mkvpropedit") into bogus argv
  # fragments. \x1f (ASCII unit separator) never legitimately appears in a
  # real path, so it round-trips exactly regardless of spaces in the path.
  CONVERT_MKVMERGE="$(IFS=$'\x1f'; printf '%s' "${MKVMERGE_CMD[*]}")"
  CONVERT_MKVPROPEDIT="$(IFS=$'\x1f'; printf '%s' "${MKVPROPEDIT_CMD[*]}")"
  export CONVERT_MKVMERGE CONVERT_MKVPROPEDIT

  python3 - "$mkv" "$src" "$title" <<'PY'
import json, os, subprocess, sys

mkv, src, title = sys.argv[1:4]
mkvmerge = os.environ.get("CONVERT_MKVMERGE", "mkvmerge").split("\x1f")
mkvpropedit = os.environ.get("CONVERT_MKVPROPEDIT", "mkvpropedit").split("\x1f")

LANG_NAMES = {
    "eng": "English", "chi": "Chinese", "jpn": "Japanese", "kor": "Korean",
    "fre": "French", "ger": "German", "spa": "Spanish", "ita": "Italian",
    "por": "Portuguese", "rus": "Russian",
}

def norm(code):
    if not code:
        return ""
    c = code.lower().strip()
    aliases = {
        "en": "eng", "zh": "chi", "zho": "chi", "chi": "chi", "chs": "chi", "cht": "chi",
        "ja": "jpn", "jpn": "jpn", "ko": "kor", "kor": "kor", "fr": "fre", "fre": "fre",
        "de": "ger", "ger": "ger", "es": "spa", "spa": "spa", "it": "ita", "ita": "ita",
        "pt": "por", "por": "por", "ru": "rus", "rus": "rus",
    }
    return aliases.get(c, c if len(c) == 3 else "")

def guess_from_path(path):
    p = path.lower()
    for key, code in (
        ("chinese", "chi"), ("cantonese", "chi"), ("mandarin", "chi"),
        ("japanese", "jpn"), ("korean", "kor"), ("french", "fre"),
        ("german", "ger"), ("spanish", "spa"), ("english", "eng"),
    ):
        if key in p:
            return code
    return "eng"

def detect_from_filename(path):
    name = path.rsplit("/", 1)[-1].lower()
    markers = (
        (".en.", "eng"), (".eng.", "eng"), (".zh.", "chi"), (".chi.", "chi"),
        (".ja.", "jpn"), (".jpn.", "jpn"), (".ko.", "kor"), (".kor.", "kor"),
        (".fr.", "fre"), (".de.", "ger"), (".es.", "spa"),
    )
    for m, code in markers:
        if m in name:
            return code
    return ""

# HandBrake often stores channel layout (Stereo/5.1/…) as the track name.
CHANNEL_LAYOUT_NAMES = {
    "mono", "stereo", "joint stereo", "dual channel", "surround",
    "2.0", "2.1", "3.0", "3.1", "4.0", "4.1", "5.0", "5.1", "6.1", "7.1",
    "atmos", "dolby atmos", "dts", "truehd", "flac", "aac", "opus", "ac3", "eac3",
}

try:
    data = json.loads(subprocess.check_output([*mkvmerge, "-J", mkv], text=True))
except Exception:
    sys.exit(0)

fallback = guess_from_path(src)
args = [*mkvpropedit, mkv, "-e", "info", "--set", f"title={title}"]

for track in data.get("tracks", []):
    if track.get("type") not in ("audio", "subtitles"):
        continue
    props = track.get("properties", {}) or {}
    # mkvmerge -J "id" is 0-based; mkvpropedit "track:N" is 1-based and would
    # shift every edit onto the previous track (video gets audio names, langs slide).
    # Prefer unambiguous track UID selectors.
    uid = props.get("uid")
    if uid is None:
        continue
    lang = norm(props.get("language_ietf") or props.get("language") or "")
    if not lang:
        lang = detect_from_filename(src) or fallback
    name = (props.get("track_name") or "").strip()
    if (
        not name
        or name.lower() in {"und", "unknown", "track"}
        or name.lower() in CHANNEL_LAYOUT_NAMES
        or name.upper() == (lang.upper() if lang else "")
    ):
        name = LANG_NAMES.get(lang, lang.upper() if lang else "Unknown")
    # Syntax is track:=UID (not track:@UID) — see mkvpropedit(1).
    args.extend(["--edit", f"track:={uid}", "--set", f"name={name}"])
    if lang:
        args.extend(["--set", f"language={lang}"])

subprocess.run(args, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PY
}

optimize_mkv_for_streaming() {
  local mkv="$1" tmp_dir tmp
  [ "$DRY_RUN" = true ] && return 0
  # An unpredictable mktemp name defeats an attacker who has to *guess* the
  # path, but the containing directory here is the same shared, often
  # world-writable media folder -- an attacker actively watching it (e.g.
  # via inotify) can still see the exact name the instant it's created and
  # race a symlink into place before mkvmerge reopens it by pathname. A
  # private mktemp -d, mode-0700 directory closes that too: only this UID
  # can even list its contents, let alone write into it.
  tmp_dir="$(mktemp -d "$(dirname "$mkv")/.convert-streamopt-XXXXXX" 2>/dev/null)" || return 0
  chmod 700 "$tmp_dir" 2>/dev/null || true
  ACTIVE_STREAMOPT_DIR="$tmp_dir"
  tmp="$tmp_dir/$(basename "${mkv%.mkv}").streamopt.mkv"
  if run_tracked_encoder "streaming remux" "${MKVMERGE_CMD[@]}" -o "$tmp" --quiet "$mkv" >/dev/null 2>&1 && [ -s "$tmp" ]; then
    mv -f "$tmp" "$mkv" && _restore_default_file_mode "$mkv"
  else
    warn "Streaming-optimization remux failed — keeping encoder's original mux: $mkv"
  fi
  # || true (E2E review, 2026-07-30): a permission race/stale-NFS-handle
  # failure here would otherwise abort the whole script via `set -e` right
  # after a successful remux, and would also leak ACTIVE_STREAMOPT_DIR by
  # never reaching the line below.
  rm -rf -- "$tmp_dir" 2>/dev/null || true
  ACTIVE_STREAMOPT_DIR=""
}

# Clears every existing Tags-element scope (global + per-track + chapters) and
# writes exactly one global Simple tag of our own. Track *properties* (Name,
# Language, FlagDefault/FlagForced -- set by label_mkv_tracks) and the Segment
# Info title live outside the Tags element entirely and are never touched here.
# src (the pre-encode original) is optional -- when given and distinct from mkv,
# a sampled VMAF is appended (plus resolution+"upscaled" if the source was
# upscaled); when src is omitted or equal to mkv (metadata-only re-tag of an
# already-AV1 file, no fresh transcode happened), only the base tag is written.
# Shared low-level step for every VES tag write: clears every existing
# Tags-element scope (global + per-track + chapters) and writes exactly one
# global Simple tag with the given value, in a single mkvpropedit call. Track
# *properties* (Name, Language, FlagDefault/FlagForced) and the Segment Info
# title live outside the Tags element entirely and are never touched here.
_xml_escape() {
  local s="$1"
  # `&` in a bash `${var//pattern/replacement}` replacement means "the
  # matched text" (like sed's `&`), not a literal ampersand -- found via
  # this function's own unit test on bash 5.3. Must escape it as `\&` in
  # each replacement string below or the escaping corrupts the string
  # instead of fixing it (e.g. "<" -> "<lt;" instead of "&lt;").
  s="${s//&/\&amp;}"
  s="${s//</\&lt;}"
  s="${s//>/\&gt;}"
  printf '%s' "$s"
}

# Every caller's tag_value gets the current tool-versions suffix appended
# here, centrally -- this is the one place all three tag call sites
# (write_ves_processed_tag for both real encodes AND remux-only passes,
# tag_guardrail_exceeded, tag_preexisting_desired_format) funnel through, so
# this single change gives every output file coverage per the user's
# CONSTANT ("even if it's just remuxed"). See the tool-version/fingerprint
# block above profile_svt_params for the probe/caching functions.
_mkv_write_single_tag() {
  local f="$1" tag_value="$2"
  [ -f "$f" ] || return 0
  [ ! -L "$f" ] || { warn "Refusing to tag — $f is a symlink (possible race)"; return 0; }

  tag_value="${tag_value}$(current_tool_versions_tag_suffix)"
  tag_value="$(_xml_escape "$tag_value")"

  local tagfile
  tagfile="$(mktemp "${TMPDIR:-/tmp}/ves-tags-XXXXXX.xml")" || { warn "Could not create temp tags file for $f"; return 0; }
  cat >"$tagfile" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE Tags SYSTEM "matroskatags.dtd">
<Tags>
  <Tag>
    <Targets></Targets>
    <Simple>
      <Name>${VES_TAG_NAME}</Name>
      <String>${tag_value}</String>
    </Simple>
  </Tag>
</Tags>
XML

  if run_mkvpropedit "$f" --tags all: --tags global:"$tagfile" >/dev/null 2>&1; then
    log "Tagged ($tag_value): $f"
  else
    warn "Failed to write VES tag: $f"
  fi
  rm -f "$tagfile"
}

write_ves_processed_tag() {
  local mkv="$1"
  local src="${2:-}"
  local tag_value="VES ${VERSION} processed"

  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] clear existing tags + write '$tag_value' (+ quality readout) on $mkv"
    return 0
  fi
  [ -f "$mkv" ] || return 0
  # Checked here too (not just inside _mkv_write_single_tag) so a symlinked
  # $mkv skips the VMAF measurement below entirely rather than spending CPU
  # computing a quality readout that would just be thrown away.
  [ ! -L "$mkv" ] || { warn "Refusing to tag — $mkv is a symlink (possible race)"; return 0; }

  if [ -n "$src" ] && [ "$src" != "$mkv" ] && [ -f "$src" ]; then
    local upscaled=false target_height=0 res_str="" vmaf=""
    if source_is_upscaled "$src"; then
      upscaled=true
      resolve_upscale_target "$src"
      target_height="$UPSCALE_TARGET_HEIGHT"
      case "$target_height" in
        720) res_str="1280x720" ;;
        1080) res_str="1920x1080" ;;
      esac
    fi
    vmaf="$(measure_final_vmaf "$src" "$mkv" "$target_height" 2>/dev/null)" || vmaf=""
    if [ "$upscaled" = true ]; then
      if [ -n "$vmaf" ]; then
        tag_value="${tag_value} — ${res_str} upscaled VMAF ${vmaf}"
      else
        tag_value="${tag_value} — ${res_str} upscaled"
      fi
    elif [ -n "$vmaf" ]; then
      tag_value="${tag_value} — VMAF ${vmaf}"
    fi
  fi

  _mkv_write_single_tag "$mkv" "$tag_value"
}

# Marks an original .mkv whose every re-encode candidate was rejected by the
# size guardrails (both AV1 and x265 exceeded the acceptable overshoot) so a
# future scan doesn't repeat the same doomed VMAF-search + encode + reject
# cycle. Written to the SOURCE itself (no output exists to tag) -- an
# explicit, narrower exception to "never touch the source" than the general
# encode pipeline gets, per the project's tagging spec. Same tag name/skip-
# check as a real conversion, so mkv_ves_tag_present recognizes it either way.
tag_guardrail_exceeded() {
  local src="$1"
  case "${src,,}" in *.mkv) ;; *) return 0 ;; esac
  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] clear existing tags + write guardrail-exceeded marker on $src"
    return 0
  fi
  _mkv_write_single_tag "$src" "VES ${VERSION} Processed - Conversion size exceeds guardrails"
}

# Marks an original .mkv that a sample-test (or a size-based short-circuit)
# determined is already in its optimal/desired form -- re-encoding wouldn't
# shrink it further, or it's small enough already that testing isn't worth
# the time. Tag-only (mkvpropedit, no remux/track-relabel), same reasoning
# and same exception to "never touch the source" as tag_guardrail_exceeded.
tag_preexisting_desired_format() {
  local src="$1"
  # This title's processing decision (no re-encode needed) is final as soon
  # as we get here, regardless of which branch below actually runs -- clear
  # the in-progress flag before returning rather than waiting for
  # end_convert_job, so an interrupt landing right after this function can't
  # make resume_on_signal tell a human to delete a file that was never even
  # touched. But team review (2026-07-22) found the ORIGINAL ordering here
  # cleared the flag BEFORE the actual tag mutation below, which let a
  # concurrent fleet machine see this source as unlocked and start its own
  # sample-test/encode attempt on the same NFS-shared file while
  # _mkv_write_single_tag's mkvpropedit rewrite was still in flight on it --
  # a real, reachable race given multiple machines scan the same library.
  # Only the two early-return branches below (nothing on disk mutated) clear
  # the flag immediately; the real mutation path clears it only after the
  # write actually completes.
  case "${src,,}" in *.mkv) ;; *) clear_in_progress_flag "$src"; return 0 ;; esac
  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] clear existing tags + write preexisting-desired-format marker on $src"
    clear_in_progress_flag "$src"
    return 0
  fi
  _mkv_write_single_tag "$src" "VES ${VERSION} Processed - Preexisting Desired Format"
  clear_in_progress_flag "$src"
}

finalize_mkv_output() {
  local mkv="$1"
  local src="$2"
  local title="${3:-$(canonical_title_from_file "$src")}"
  optimize_mkv_for_streaming "$mkv"
  label_mkv_tracks "$mkv" "$src" "$title"
  write_ves_processed_tag "$mkv" "$src"
  maybe_chown_for_media_user "$mkv"
  # $mkv is now the real, durable, final output -- clear the in-progress
  # flag here rather than waiting for end_convert_job, closing the window
  # where an interrupt right after this point would otherwise make
  # resume_on_signal warn a human to delete what is actually finished work.
  clear_in_progress_flag "$src"
}

set_mkv_title() {
  local mkv="$1"
  local title="$2"
  finalize_mkv_output "$mkv" "$mkv" "$title"
}

validate_mkv_ffmpeg_stderr() {
  local errf="$1"
  local label="$2"
  local filtered
  # Drop benign null-muxer DTS warnings (common on VFR/anime). The word "invalid"
  # in those lines used to false-fail validation even when ffmpeg exited 0 and
  # the same warnings appear on the original source.
  filtered="$(mktemp)"
  grep -Eiv 'non monotonically increasing dts|Application provided invalid, non monotonically increasing dts' "$errf" >"$filtered" 2>/dev/null || true
  if search_cie 'corrupt|error while decoding|invalid data found|error opening|error initializing' "$filtered"; then
    warn "Validation failed: ffmpeg reported issues in ${label}"
    cat "$filtered" >&2
    rm -f "$filtered"
    return 1
  fi
  rm -f "$filtered"
  return 0
}

mkv_structure_cache_invalidate() {
  local dst="$1"
  local cache="${MKV_STRUCTURE_CACHE_FILE:-}"
  local tmpf
  [ -n "$cache" ] && [ -f "$cache" ] || return 0
  # A static ".tmp" suffix is a fully predictable path -- mktemp gives a
  # randomized name in the same directory, closing the symlink-race window
  # a fixed name would otherwise leave (see filecache_put's cache_tmp).
  # This whole read-modify-write is a fleet-wide shared-file race without
  # the mutex: two hosts reading the same baseline then each mv -f'ing their
  # own filtered copy back would silently lose whichever wrote first (team
  # review, 2026-07-24).
  local _mtok
  _mtok="$(_shared_mutex_acquire "${cache}.lock")"
  tmpf="$(mktemp "${cache}.XXXXXX")" || { _shared_mutex_release "${cache}.lock" "$_mtok"; return 0; }
  awk -F '\t' -v p="$dst" '$2!=p { print }' "$cache" >"$tmpf" 2>/dev/null || true
  if mv -f "$tmpf" "$cache" 2>/dev/null; then
    _restore_default_file_mode "$cache"
  else
    rm -f "$tmpf" 2>/dev/null
  fi
  _shared_mutex_release "${cache}.lock" "$_mtok"
}

record_stripped_subtitle() {
  local src="$1"
  local idx="$2"
  local key="${src}#${idx}"
  [ -z "${STRIPPED_SUBTITLE_LOGGED[$key]:-}" ] || return 0
  STRIPPED_SUBTITLE_LOGGED[$key]=1
  local lang title
  lang="$(run_ffprobe -v error -select_streams "s:$idx" -show_entries stream_tags=language \
    -of default=nw=1:nk=1 "$src" 2>/dev/null)"
  title="$(run_ffprobe -v error -select_streams "s:$idx" -show_entries stream_tags=title \
    -of default=nw=1:nk=1 "$src" 2>/dev/null)"
  local logf="${STRIPPED_SUBTITLES_LOG:-}"
  [ -n "$logf" ] || logf="${JOB_SIDECAR_DIR:-.}/stripped_subtitles.txt"
  local line
  line="$(printf '%s\t%s\ts:%s\tlang=%s\ttitle=%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$src" "$idx" "${lang:-und}" "${title:-none}")"
  if [ -n "$STRIPPED_SUBTITLES_LOG_FD" ]; then
    printf '%s' "$line" >&"$STRIPPED_SUBTITLES_LOG_FD" 2>/dev/null || true
  else
    printf '%s' "$line" >>"$logf" 2>/dev/null || true
  fi
  maybe_chown_for_media_user "$logf"
}

record_corrupt_mkv() {
  local dst="$1"
  local reason="${2:-structure error}"
  local logf="${CORRUPT_FILES_LOG:-}"
  [ -n "$logf" ] || logf="${JOB_SIDECAR_DIR:-.}/corrupt_files.txt"
  if [ -n "$CORRUPT_FILES_LOG_FD" ]; then
    printf '%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$dst" "$reason" >&"$CORRUPT_FILES_LOG_FD" 2>/dev/null || true
  else
    {
      printf '%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$dst" "$reason"
    } >>"$logf" 2>/dev/null || true
  fi
  maybe_chown_for_media_user "$logf"
}

capture_validation_failure_evidence() {
  local src="$1"
  local out="$2"
  local reason="${3:-validation_failed}"
  local src_dur="${4:-}"
  local root dir stamp raw_title title preserved start ff_log

  [ "$DRY_RUN" = true ] && return 0
  [ -s "$out" ] || return 0
  case "$reason" in
    video_truncated|zero_frames_decoded) ;;
    *) return 0 ;;
  esac

  root="$(dirname -- "$out")/.convert-v5-validation-failures"
  mkdir -p -- "$root" 2>/dev/null || {
    root="${JOB_SIDECAR_DIR:-/tmp}/validation-failures"
    mkdir -p -- "$root" 2>/dev/null || return 0
  }
  stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  raw_title="$(canonical_title_from_source "$src")"
  title="$(printf '%s' "$raw_title" | tr -cd '[:alnum:]_. -' | sed 's/[[:space:]]\+/_/g')"
  [ -n "$title" ] || title="media"
  dir="$root/${stamp}.$$.$title.$reason"
  mkdir -p -- "$dir" 2>/dev/null || return 0

  {
    printf 'captured_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'reason=%s\n' "$reason"
    printf 'source=%s\n' "$src"
    printf 'output=%s\n' "$out"
    printf 'script_pid=%s\n' "$$"
    printf 'ffmpeg='
    "${FFMPEG_CMD[@]}" -version 2>/dev/null | sed -n '1p'
    printf 'ffprobe='
    "${FFPROBE_CMD[@]}" -version 2>/dev/null | sed -n '1p'
    printf 'mkvmerge='
    run_mkvmerge --version 2>/dev/null | sed -n '1p'
  } >"$dir/manifest.txt" 2>/dev/null || true

  run_ffprobe -v error -show_format -show_streams -of json "$src" >"$dir/source.ffprobe.json" 2>"$dir/source.ffprobe.err" || true
  run_ffprobe -v error -show_format -show_streams -of json "$out" >"$dir/output.ffprobe.json" 2>"$dir/output.ffprobe.err" || true
  ff_log="${JOB_SIDECAR_DIR:-/tmp}/ffmpeg-logs/${raw_title}.$$.stderr.log"
  [ -s "$ff_log" ] && cp -p -- "$ff_log" "$dir/ffmpeg-encode.stderr.log" 2>/dev/null || true
  ff_log="${JOB_SIDECAR_DIR:-/tmp}/ffmpeg-logs/${raw_title}.$$.retry.stderr.log"
  [ -s "$ff_log" ] && cp -p -- "$ff_log" "$dir/ffmpeg-encode.retry.stderr.log" 2>/dev/null || true
  run_mkvmerge --identify --identification-format json "$out" >"$dir/output.mkvmerge.json" 2>"$dir/output.mkvmerge.err" \
    || run_mkvmerge --identify "$out" >"$dir/output.mkvmerge.txt" 2>>"$dir/output.mkvmerge.err" || true

  [ -n "$src_dur" ] || src_dur="$(video_duration "$src")"
  if awk -v d="$src_dur" 'BEGIN { exit !(d>0) }'; then
    start="$(awk -v d="$src_dur" 'BEGIN { s=d-120; if (s<0) s=0; printf "%.3f", s }')"
    run_ffprobe -v error -read_intervals "${start}%+120" -select_streams v:0 \
      -show_entries packet=pts_time,dts_time,duration_time,pos,size,flags -of csv=p=0 "$src" \
      >"$dir/source.video-packets-near-source-eof.csv" 2>"$dir/source.video-packets-near-source-eof.err" || true
    run_ffprobe -v error -read_intervals "${start}%+120" -select_streams v:0 \
      -show_entries packet=pts_time,dts_time,duration_time,pos,size,flags -of csv=p=0 "$out" \
      >"$dir/output.video-packets-near-source-eof.csv" 2>"$dir/output.video-packets-near-source-eof.err" || true
  fi

  preserved="$dir/rejected-output.mkv"
  if mv -n -- "$out" "$preserved" 2>/dev/null; then
    _restore_default_file_mode "$preserved"
    maybe_chown_for_media_user "$preserved"
    log "Validation evidence captured: $dir (rejected output moved out of normal path)"
  elif ln -- "$out" "$preserved" 2>/dev/null; then
    _restore_default_file_mode "$preserved"
    maybe_chown_for_media_user "$preserved"
    log "Validation evidence captured: $dir (rejected output hardlinked)"
  else
    warn "Validation evidence metadata captured but rejected output could not be preserved: $dir"
  fi
  maybe_chown_for_media_user "$dir" "$dir"/*
}

# Delete a bad processed .AV1.mkv / .x265.mkv and flag the source for reconversion.
#
# $out only gets here because its filename matches our own derived-output
# naming convention (Title.AV1.mkv / Title.x265.mkv) -- that's a guess, not
# proof, that we created it. A genuine unrelated file a user already had
# (e.g. their own native-AV1 rip of a different edition, sitting beside an
# unconverted source with a matching canonical title) would look identical
# to a broken conversion output once it fails validation against $src. An
# encode we actually produced can only ever exist AFTER its source did, so a
# candidate that predates $src cannot possibly be something we made from
# this exact source -- refuse to delete it and flag for human review instead.
flag_bad_processed_output() {
  local src="$1"
  local out="$2"
  local reason="${3:-invalid processed output}"
  local logf="${RECONVERT_FILES_LOG:-}"
  local src_mt out_mt

  # Trailing `|| true` on every mkv_structure_stat_key call below and at the
  # other 7 sites using this same pattern elsewhere in the file (team
  # review, 2026-07-22): a bare failing command substitution here (e.g. the
  # file vanished or a stat call errored between being listed and being
  # checked -- routine at fleet scale) aborts the WHOLE script right at this
  # line under `set -e`, before the following `${var##*|}` extraction ever
  # runs. Verified via direct bash testing. An empty src_mt/out_mt already
  # falls through safely -- the regex guards below require pure digits.
  src_mt="$(mkv_structure_stat_key "$src" 2>/dev/null)" || true; src_mt="${src_mt##*|}"
  out_mt="$(mkv_structure_stat_key "$out" 2>/dev/null)" || true; out_mt="${out_mt##*|}"
  if [[ "$src_mt" =~ ^[0-9]+$ ]] && [[ "$out_mt" =~ ^[0-9]+$ ]] && [ "$out_mt" -lt "$src_mt" ]; then
    flag_bad_source_for_human "$out" "matches our derived-output naming but predates its supposed source ($src) — likely an unrelated file, not something we created; not deleting ($reason)"
    return 0
  fi
  if ! derived_output_codec_claim_matches "$out"; then
    flag_bad_source_for_human "$out" "named as our AV1/x265 output but its actual video codec doesn't match — not something we created; not deleting ($reason)"
    return 0
  fi

  [ -n "$logf" ] || logf="${JOB_SIDECAR_DIR:-.}/reconvert_files.txt"
  warn "Bad processed output — deleting and flagging for reconversion: $out ($reason)"
  if [ -n "$RECONVERT_FILES_LOG_FD" ]; then
    printf '%s\t%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$src" "$out" "$reason" >&"$RECONVERT_FILES_LOG_FD" 2>/dev/null || true
  else
    {
      printf '%s\t%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$src" "$out" "$reason"
    } >>"$logf" 2>/dev/null || true
  fi
  maybe_chown_for_media_user "$logf"
  record_corrupt_mkv "$out" "$reason"
  mkv_structure_cache_invalidate "$out"
  if [ "$DRY_RUN" = true ]; then
    return 0
  fi
  rm -f -- "$out"
}

# Bad source media: never delete; log for human review and skip conversion.
flag_bad_source_for_human() {
  local src="$1"
  local reason="${2:-unplayable or corrupt source}"
  local logf="${BAD_SOURCES_LOG:-}"
  local dir base deferred_dir dest

  [ -n "$logf" ] || logf="${JOB_SIDECAR_DIR:-.}/bad_sources.txt"

  # Move the file into a Deferred/ subfolder alongside its siblings, rather
  # than just logging its path -- still visible to Plex/Sonarr/etc. (nothing
  # was deleted), but now self-documenting: a person can find every title
  # needing attention by browsing/searching for Deferred/ folders instead of
  # having to know to check bad_sources.txt. get_scan_roots and the video
  # file-discovery loop both exclude Deferred/ by name so a parked file is
  # never silently rediscovered and reprocessed. Skipped for dry-run (no
  # filesystem changes) and disc sources (a BDMV root/ISO isn't a single
  # file to relocate -- log only, same as before).
  if [ "$DRY_RUN" = true ] || is_disk_source "$src"; then
    warn "Bad source — skipping for human processing (original kept): $src ($reason)"
  else
    dir="$(dirname -- "$src")"
    base="$(basename -- "$src")"
    deferred_dir="$dir/Deferred"
    if mkdir -p -- "$deferred_dir" 2>/dev/null; then
      dest="$deferred_dir/$base"
      # Don't clobber an earlier deferred file of the same name.
      [ -e "$dest" ] && dest="$deferred_dir/$(date -u '+%Y%m%dT%H%M%SZ')-$base"
      if mv -n -- "$src" "$dest" 2>/dev/null; then
        warn "Bad source — moved to Deferred/ for human review: $dest ($reason)"
        src="$dest"
      else
        warn "Bad source — could not move to Deferred/, left in place: $src ($reason)"
      fi
    else
      warn "Bad source — could not create Deferred/, left in place: $src ($reason)"
    fi
  fi

  if [ -n "$BAD_SOURCES_LOG_FD" ]; then
    printf '%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$src" "$reason" >&"$BAD_SOURCES_LOG_FD" 2>/dev/null || true
  else
    {
      printf '%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$src" "$reason"
    } >>"$logf" 2>/dev/null || true
  fi
  maybe_chown_for_media_user "$logf"
  record_skip "$src" "bad source — human review: $reason"
}

# Checks whether a structurally-bad source MKV/WebM's content is actually
# fine (just container-level noise) by remuxing it (stream copy; mkvmerge
# preferred, ffmpeg -c copy as fallback) into a throwaway mktemp -d, entirely
# outside the library tree. Never touches or replaces $src -- there is no
# in-place write, no window where the original is missing/half-written, and
# no leftover artifact beside the source for a later scan to mistake for a
# new title. On success prints the repaired copy's path on stdout purely as
# proof the content is sound (caller removes it immediately, it is never
# used as the actual encode input); the real encode always runs against the
# untouched original -- if ffmpeg itself still can't read it, the normal
# AV1-then-x265-then-fail-safely fallback chain handles that already.
# Returns 0 if the repair validated clean; 1 otherwise ($src is always
# untouched either way).
attempt_source_mkv_structure_remux() {
  local src="$1"
  local reason="${2:-structure errors}"
  local workdir tmp rc

  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] Would remux-repair source MKV ($reason): $src"
    return 1
  fi

  workdir="$(mktemp -d)" || return 1
  tmp="$workdir/repaired.mkv"

  log "Source MKV structure issue ($reason) — attempting remux repair (repaired copy only, source untouched): $src"

  set +e
  if [ "${#MKVMERGE_CMD[@]}" -gt 0 ]; then
    run_mkvmerge -o "$tmp" "$src" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 124 ]; then
      warn "mkvmerge remux repair timed out (possible stalled mount; rc=124); trying ffmpeg stream copy"
      # run_ffmpeg_remux (timeout-wrapped, generous full-file-copy curve --
      # not run_ffmpeg_validation's short-probe curve, see _remux_timeout_for_args)
      # -- this is the fallback AFTER mkvmerge already timed out or failed,
      # so an unbounded ffmpeg retry here could hang on the exact same
      # stalled mount it exists to route around. Found 2026-07-29.
      run_ffmpeg_remux -y -nostdin -loglevel error -fflags +genpts -i "$src" -map 0 -c copy "$tmp"
      rc=$?
    # mkvmerge: 0=ok, 1=warnings (often still usable), >=2=error
    elif [ "$rc" -ge 2 ] || [ ! -s "$tmp" ]; then
      warn "mkvmerge remux repair failed (rc=$rc); trying ffmpeg stream copy"
      # run_ffmpeg_remux (timeout-wrapped, generous full-file-copy curve --
      # not run_ffmpeg_validation's short-probe curve, see _remux_timeout_for_args)
      # -- this is the fallback AFTER mkvmerge already timed out or failed,
      # so an unbounded ffmpeg retry here could hang on the exact same
      # stalled mount it exists to route around. Found 2026-07-29.
      run_ffmpeg_remux -y -nostdin -loglevel error -fflags +genpts -i "$src" -map 0 -c copy "$tmp"
      rc=$?
    else
      rc=0
    fi
  else
    # run_ffmpeg_remux (timeout-wrapped, generous full-file-copy curve) --
    # no mkvmerge available, so this is the only repair attempt; still
    # shouldn't hang forever on a stalled mount. Found 2026-07-29.
    run_ffmpeg_remux -y -nostdin -loglevel error -fflags +genpts -i "$src" -map 0 -c copy "$tmp"
    rc=$?
  fi
  set -e

  if [ "$rc" -ne 0 ] || [ ! -s "$tmp" ]; then
    warn "Remux repair failed for $src"
    rm -rf -- "$workdir"
    return 1
  fi

  if ! ffprobe_metadata_ok "$tmp" true; then
    warn "Remux repair produced unreadable metadata: $tmp"
    rm -rf -- "$workdir"
    return 1
  fi
  if ! validate_mkv_ebml_bounds "$tmp"; then
    warn "Remux repair still fails EBML/segment bounds: $tmp"
    rm -rf -- "$workdir"
    return 1
  fi
  local _tmp_size
  _tmp_size="$(file_size_bytes "$tmp")"
  if [ "$HAS_MKVALIDATOR" = true ] && { [ -z "$_tmp_size" ] || [ "$_tmp_size" -le "$MKVALIDATOR_MAX_SIZE_BYTES" ]; } && ! validate_mkv_mkvalidator "$tmp"; then
    warn "Remux repair still fails mkvalidator: $tmp"
    rm -rf -- "$workdir"
    return 1
  fi

  log "Remux repair succeeded — using repaired copy for this encode; source left untouched: $src"
  printf '%s' "$tmp"
  return 0
}

# Validate a source before convert. Disks (ISO/BDMV) are left to HandBrake title scan.
# Returns 0 if OK to process; 1 if bad (already logged/skipped).
validate_source_media() {
  local src="$1"
  local ext codec

  SOURCE_VALIDATE_TIMED_OUT=false

  if is_disk_source "$src"; then
    return 0
  fi
  if is_derived_output "$src"; then
    return 0
  fi

  if [ ! -s "$src" ]; then
    flag_bad_source_for_human "$src" "empty or missing file"
    return 1
  fi

  local _meta_rc=0
  ffprobe_metadata_ok "$src" true || _meta_rc=$?
  if [ "$_meta_rc" -eq 124 ]; then
    warn "ffprobe timed out (possible stalled mount) — skipping this run (not flagging as bad source): $src"
    SOURCE_VALIDATE_TIMED_OUT=true
    record_skip "$src" "ffprobe timed out (possible stalled mount)"
    return 1
  fi
  if [ "$_meta_rc" -ne 0 ]; then
    # A single ffprobe failure that isn't a clean timeout could still be a
    # transient NFS/network blip -- a brief server hiccup often surfaces as
    # a read error rather than a hang, so it would never hit the 124 branch
    # above. Retry once after a short pause before concluding the source
    # itself is genuinely bad and taking the permanent Deferred/ move.
    # Team review (2026-07-24) found the original single-attempt version
    # could misclassify a realistic transient failure as source corruption.
    sleep 2
    _meta_rc=0
    ffprobe_metadata_ok "$src" true || _meta_rc=$?
    if [ "$_meta_rc" -eq 124 ]; then
      warn "ffprobe timed out on retry (possible stalled mount) — skipping this run (not flagging as bad source): $src"
      SOURCE_VALIDATE_TIMED_OUT=true
      record_skip "$src" "ffprobe timed out (possible stalled mount)"
      return 1
    fi
    if [ "$_meta_rc" -ne 0 ]; then
      flag_bad_source_for_human "$src" "missing duration or video stream (ffprobe, confirmed on retry)"
      return 1
    fi
  fi

  ext="$(to_lower "${src##*.}")"
  if [ "$ext" = "mkv" ] || [ "$ext" = "webm" ]; then
    # attempt_source_mkv_structure_remux only ever repairs an isolated,
    # throwaway copy under mktemp -d -- $src on disk is NEVER modified by
    # it. Its result here is used purely as a confidence check ("is this
    # source's content fundamentally sound, just container-level noise?"):
    # if the repair validates clean, we proceed to encode from the
    # untouched original as always; if ffmpeg itself still can't read it,
    # the existing AV1-then-x265-then-fail-safely fallback chain in
    # try_av1_convert already handles that without ever touching $src.
    local repaired ebml_rc=0 mv_rc=0
    validate_mkv_ebml_bounds "$src" || ebml_rc=$?
    if [ "$ebml_rc" -eq 124 ]; then
      warn "EBML bounds check timed out (possible stalled mount) — skipping this run (not flagging as bad source): $src"
      SOURCE_VALIDATE_TIMED_OUT=true
      record_skip "$src" "EBML bounds timed out (possible stalled mount)"
      return 1
    fi
    if [ "$ebml_rc" -ne 0 ]; then
      if repaired="$(attempt_source_mkv_structure_remux "$src" "EBML/segment bounds invalid")"; then
        rm -rf -- "$(dirname "$repaired")"
      else
        flag_bad_source_for_human "$src" "Matroska EBML/segment bounds invalid (remux repair failed)"
        return 1
      fi
    fi
    # Full mkvalidator on sources at encode time only (when available), and
    # only below MKVALIDATOR_MAX_SIZE_BYTES -- mkvalidator (v0.6.0) parses via
    # very small sequential reads (~700 bytes/syscall observed), which is fine
    # for typical TV-episode-sized files but drops to ~170KB/s on a 20GB+
    # movie, i.e. tens of hours to validate one file (found via the fleet
    # performance test, 2026-07). EBML/segment bounds above already gate
    # structural soundness; skip the slow full parse above the threshold
    # rather than stall indefinitely.
    local _src_size
    _src_size="$(file_size_bytes "$src")"
    if [ "$HAS_MKVALIDATOR" = true ] && { [ -z "$_src_size" ] || [ "$_src_size" -le "$MKVALIDATOR_MAX_SIZE_BYTES" ]; }; then
      validate_mkv_mkvalidator "$src" || mv_rc=$?
      if [ "$mv_rc" -eq 124 ]; then
        warn "mkvalidator timed out (possible stalled mount) — skipping this run (not flagging as bad source): $src"
        SOURCE_VALIDATE_TIMED_OUT=true
        record_skip "$src" "mkvalidator timed out (possible stalled mount)"
        return 1
      fi
      if [ "$mv_rc" -ne 0 ]; then
        if repaired="$(attempt_source_mkv_structure_remux "$src" "mkvalidator structure errors")"; then
          rm -rf -- "$(dirname "$repaired")"
        else
          flag_bad_source_for_human "$src" "mkvalidator structure errors (remux repair failed)"
          return 1
        fi
      fi
    elif [ "$HAS_MKVALIDATOR" = true ]; then
      log_err "mkvalidator skipped ($(human_size_bytes "$_src_size") > $(human_size_bytes "$MKVALIDATOR_MAX_SIZE_BYTES") threshold) — EBML bounds already OK: $src"
    fi

    # Catch a genuinely truncated/corrupt audio track up front, before ever
    # attempting an expensive real encode -- found via Dune (2021): its
    # source's audio track was short relative to the video, which only
    # surfaced AFTER a full ~2-hour real AV1 encode (and even a lossless
    # stream-copy remux of the untouched original) both failed this same
    # check post-encode. A stream copy can't introduce new truncation, so
    # the defect was already in the source. Cheap by design (seeks near EOF
    # via container index, doesn't scan the whole file), so safe to run
    # regardless of file size, unlike the mkvalidator threshold above.
    local audio_rc=0
    validate_mkv_audio_tracks "$src" || audio_rc=$?
    if [ "$audio_rc" -eq 124 ]; then
      warn "Audio-track check timed out (possible stalled mount) — skipping this run (not flagging as bad source): $src"
      SOURCE_VALIDATE_TIMED_OUT=true
      record_skip "$src" "audio track check timed out (possible stalled mount)"
      return 1
    fi
    if [ "$audio_rc" -ne 0 ]; then
      flag_bad_source_for_human "$src" "primary audio track truncated relative to video length (audio_truncated) — likely a genuinely corrupt/incomplete source, not an encoding artifact; caught before an expensive re-encode was attempted"
      return 1
    fi

    # Same idea for subtitles: a primary subtitle track that stops well
    # short of the film's actual end (not just going quiet near a
    # dialogue-free ending, and not a forced/signs-only track that's
    # expected to -- see validate_mkv_subtitle_tracks's own tail-gap-
    # percentage/disposition guards) usually means a bad rip or a botched
    # extraction, not something an encode would introduce or fix.
    local subtitle_rc=0
    validate_mkv_subtitle_tracks "$src" || subtitle_rc=$?
    if [ "$subtitle_rc" -eq 124 ]; then
      warn "Subtitle-track check timed out (possible stalled mount) — skipping this run (not flagging as bad source): $src"
      SOURCE_VALIDATE_TIMED_OUT=true
      record_skip "$src" "subtitle track check timed out (possible stalled mount)"
      return 1
    fi
    if [ "$subtitle_rc" -ne 0 ]; then
      flag_bad_source_for_human "$src" "primary subtitle track truncated relative to video length (subtitle_truncated) — likely a bad rip or botched extraction, not an encoding artifact; caught before an expensive re-encode was attempted"
      return 1
    fi
  fi

  local vc_rc=0
  codec="$(run_ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 "$src" 2>/dev/null)" || vc_rc=$?
  if [ "$vc_rc" -eq 124 ]; then
    warn "ffprobe codec probe timed out (possible stalled mount) — skipping this run (not flagging as bad source): $src"
    SOURCE_VALIDATE_TIMED_OUT=true
    record_skip "$src" "ffprobe codec timed out (possible stalled mount)"
    return 1
  fi
  if [ -z "$codec" ] || [ "$codec" = "unknown" ]; then
    flag_bad_source_for_human "$src" "unknown/unreadable video codec"
    return 1
  fi
  return 0
}

# Quick source gate during scan (metadata + EBML only — no full mkvalidator).
# EBML failures are deferred to encode-time remux repair (do not flag bad yet).
# Timeouts skip queueing this run without permanently flagging the source.
# Team review (2026-07-25): this quick pre-queue gate runs during the
# unlocked scan phase, before any file has been claimed for real -- but on a
# non-timeout ffprobe/EBML failure it can call flag_bad_source_for_human,
# which does an unlocked `mv` of the source into Deferred/. On a shared NFS
# library scanned by multiple hosts, another host could already be actively
# encoding this exact title (holding the real per-title lock) when this
# host's independent scan pass reaches the same file and decides to move
# it -- a genuine race against a live job, not just wasted duplicate work.
#
# First fix attempt (same review round) wrapped the check in an actual
# acquire/release of the real per-title lock -- re-review correctly
# caught that this created a NEW failure mode: if this process is killed
# (SIGTERM) while the lock is held (mid-ffprobe/EBML, up to
# VALIDATION_TIMEOUT_SECS), the release never runs, and other hosts treat
# that leaked lock as live for up to 2 hours (the cross-host staleness
# window sized for genuine multi-hour encode jobs, not a brief scan check) --
# blocking a real encode of that title fleet-wide for the remainder of that
# window. Fixed properly by never acquiring the lock at all here: a plain
# read-only existence check has nothing to leak if this process dies
# mid-check, and is sufficient to answer the only question that matters --
# "is someone else actively working this title right now?"
#
# A second re-review caught that a plain existence check treats a
# genuinely stale/abandoned lock (the real owner crashed) the same as a
# live one -- that title would then never even reach place_in_progress_flag,
# so its own junk_flag_is_stale reclaim never runs either, silently
# regressing recovery to depend on the separate orphan reaper instead of the
# normal path. Fixed by checking staleness too: a stale lock is treated as
# "not actually held" (proceed with the quick check as usual; the real
# reclaim still happens later, at actual encode-claim time, not here).
source_looks_processable_quick() {
  local src="$1"
  if is_disk_source "$src" || is_derived_output "$src"; then
    return 0
  fi
  local _lockdir _flag
  _flag="$(in_progress_flag_path "$src")"
  _lockdir="${_flag}.lock"
  if [ -d "$_lockdir" ] && ! junk_flag_is_stale "$_flag" 2>/dev/null; then
    # Another host (or another process on this one) is actively encoding
    # this title right now -- not something this scan pass should touch or
    # judge. Don't queue it this round; whoever holds the lock is the
    # authority on its outcome. A benign TOCTOU window remains (the lock
    # could be acquired a moment after this check) -- same residual race
    # the rest of the fleet already accepts for non-blocking lock checks
    # elsewhere in this file, and far narrower than doing no check at all.
    return 1
  fi
  _source_looks_processable_quick_impl "$src"
}

_source_looks_processable_quick_impl() {
  local src="$1"
  local ext meta_rc=0 ebml_rc=0

  if is_disk_source "$src"; then
    return 0
  fi
  if is_derived_output "$src"; then
    return 0
  fi
  if [ ! -s "$src" ]; then
    flag_bad_source_for_human "$src" "empty or missing file"
    return 1
  fi
  meta_rc=0
  ffprobe_metadata_ok "$src" true || meta_rc=$?
  if [ "$meta_rc" -eq 124 ]; then
    warn "ffprobe timed out (possible stalled mount) during quick scan — not queueing this run: $src"
    return 1
  fi
  if [ "$meta_rc" -ne 0 ]; then
    # See validate_source_media's identical retry for the reasoning: a
    # single non-timeout ffprobe failure during the quick pre-queue scan
    # (run with no lock held yet) could be a transient NFS blip rather than
    # real corruption -- retry once before taking the permanent Deferred/
    # move, instead of relying on a single probe during an unlocked scan.
    sleep 2
    meta_rc=0
    ffprobe_metadata_ok "$src" true || meta_rc=$?
    if [ "$meta_rc" -eq 124 ]; then
      warn "ffprobe timed out on retry (possible stalled mount) during quick scan — not queueing this run: $src"
      return 1
    fi
    if [ "$meta_rc" -ne 0 ]; then
      flag_bad_source_for_human "$src" "missing duration or video stream (ffprobe, confirmed on retry)"
      return 1
    fi
  fi
  ext="$(to_lower "${src##*.}")"
  if [ "$ext" = "mkv" ] || [ "$ext" = "webm" ]; then
    ebml_rc=0
    validate_mkv_ebml_bounds "$src" || ebml_rc=$?
    if [ "$ebml_rc" -eq 124 ]; then
      warn "EBML bounds timed out (possible stalled mount) during quick scan — not queueing this run: $src"
      return 1
    fi
    if [ "$ebml_rc" -ne 0 ]; then
      warn "Matroska EBML/segment bounds look bad — will attempt remux repair at encode time: $src"
      # Still queue; validate_source_media remuxes or flags for human review.
    fi
  fi
  return 0
}

mkv_structure_stat_key() {
  local dst="$1"
  # size|mtime. Was an unconditional python3 spawn per file (this runs on
  # every file during a library scan, so tens of thousands of fork+execs
  # added real minutes just for a stat()) — native `stat` per platform is
  # the fast path, python3 kept only as a fallback for anything else.
  case "$PLATFORM" in
    macos) stat -f '%z|%m' "$dst" 2>/dev/null && return 0 ;;
    linux|wsl) stat -c '%s|%Y' "$dst" 2>/dev/null && return 0 ;;
  esac
  python3 - "$dst" <<'PY' 2>/dev/null || return 1
import os, sys
p = sys.argv[1]
st = os.stat(p)
print(f"{st.st_size}|{int(st.st_mtime)}")
PY
}

mkv_structure_cache_hit() {
  local dst="$1"
  local key cache="${MKV_STRUCTURE_CACHE_FILE:-}"
  [ -n "$cache" ] && [ -f "$cache" ] || return 1
  key="$(mkv_structure_stat_key "$dst")" || return 1
  # key is size|mtime; line is size|mtime<TAB>path
  awk -F '\t' -v k="$key" -v p="$dst" '$1==k && $2==p { found=1; exit } END { exit !found }' "$cache" 2>/dev/null
}

mkv_structure_cache_store() {
  local dst="$1"
  local key cache="${MKV_STRUCTURE_CACHE_FILE:-}"
  local tmpf
  [ -n "$cache" ] || return 0
  key="$(mkv_structure_stat_key "$dst")" || return 0
  mkdir -p "$(dirname "$cache")" 2>/dev/null || true
  # Everything (the filtered old entries AND the new one) goes into the same
  # private mktemp file before the single mv into place -- the previous
  # version rebuilt via mv but then reopened $cache by name for the final
  # append, leaving a TOCTOU window between that mv and the reopen.
  # Fleet-shared file, same lost-update race as mkv_structure_cache_invalidate
  # without the mutex: two hosts reading the same baseline then each mv -f'ing
  # their own rebuilt copy back would silently lose whichever wrote first
  # (team review, 2026-07-24).
  local _mtok
  _mtok="$(_shared_mutex_acquire "${cache}.lock")"
  tmpf="$(mktemp "${cache}.XXXXXX" 2>/dev/null)" || { _shared_mutex_release "${cache}.lock" "$_mtok"; return 0; }
  if [ -f "$cache" ]; then
    awk -F '\t' -v p="$dst" '$2!=p { print }' "$cache" >"$tmpf" 2>/dev/null || true
  fi
  printf '%s\t%s\n' "$key" "$dst" >>"$tmpf"
  if mv -f "$tmpf" "$cache" 2>/dev/null; then
    _restore_default_file_mode "$cache"
  else
    rm -f "$tmpf" 2>/dev/null
  fi
  _shared_mutex_release "${cache}.lock" "$_mtok"
  maybe_chown_for_media_user "$cache"
}

# Fast Matroska header/structure check: EBML Segment size must match EOF, and any
# SeekHead→Cues offset must lie within the file. Catches truncated remuxes that
# still pass mkvmerge --identify and ffprobe duration (duration lives in Info).
# Returns 0 on OK, 1 on structural failure, 124 on timeout (possible stalled mount).
# Callers that record_corrupt / flag_bad_source MUST treat 124 as "unable to
# validate," never as confirmed corrupt.
validate_mkv_ebml_bounds() {
  local dst="$1"
  local out rc=0
  # Capture status via || so we never toggle set -e (toggling -e then
  # `return 124` exits the whole shell when the caller used set +e; fn; rc=$?).
  # NOT _run_timeout_retry: this call's script body is a heredoc, and a
  # heredoc's stdin is consumed on first read -- a retry attempt would see
  # an empty script instead of the real one. Single attempt, still with the
  # size-scaled timeout.
  out="$(run_with_timeout "$(_validation_timeout_for_args "$dst")" python3 - "$dst" <<'PY'
import os, sys

path = sys.argv[1]
size = os.path.getsize(path)

def read_vint(f):
    b = f.read(1)
    if not b:
        return None, 0
    first = b[0]
    mask = 0x80
    length = 1
    while length <= 8 and not (first & mask):
        mask >>= 1
        length += 1
    if length > 8:
        return None, 0
    val = first & (mask - 1)
    if length > 1:
        rest = f.read(length - 1)
        if len(rest) != length - 1:
            return None, 0
        for r in rest:
            val = (val << 8) | r
    return val, length

def read_id(f):
    b = f.read(1)
    if not b:
        return None, 0
    first = b[0]
    mask = 0x80
    length = 1
    while length <= 4 and not (first & mask):
        mask >>= 1
        length += 1
    if length > 4:
        return None, 0
    data = b + f.read(length - 1)
    if len(data) != length:
        return None, 0
    val = 0
    for x in data:
        val = (val << 8) | x
    return val, length

with open(path, "rb") as f:
    eid, _ = read_id(f)
    if eid != 0x1A45DFA3:
        print("missing EBML head")
        sys.exit(2)
    esize, _ = read_vint(f)
    if esize is None:
        print("bad EBML size")
        sys.exit(2)
    f.seek(esize, os.SEEK_CUR)

    sid, _ = read_id(f)
    if sid != 0x18538067:
        print("missing Segment")
        sys.exit(2)
    ssize, slen = read_vint(f)
    if ssize is None:
        print("bad Segment size")
        sys.exit(2)
    seg_data = f.tell()
    unknown = (1 << (7 * slen)) - 1
    if ssize != unknown:
        expected_end = seg_data + ssize
        if expected_end != size:
            print(f"Segment size {ssize} expects EOF {expected_end}, file is {size}")
            sys.exit(2)

    end = size if ssize == unknown else min(size, seg_data + ssize)
    while f.tell() < end:
        pos = f.tell()
        cid, _ = read_id(f)
        if cid is None:
            break
        csize, clen = read_vint(f)
        if csize is None:
            print(f"bad element size at {pos}")
            sys.exit(2)
        cstart = f.tell()
        c_unknown = (1 << (7 * clen)) - 1
        if csize != c_unknown and cstart + csize > end:
            print(f"element at {pos} extends past Segment end")
            sys.exit(2)
        if cid == 0x1F43B675:  # Cluster — stop header walk
            break
        if cid == 0x114D9B74:  # SeekHead
            seek_end = cstart + csize if csize != c_unknown else end
            while f.tell() < seek_end:
                eid2, _ = read_id(f)
                if eid2 is None:
                    break
                esz2, _ = read_vint(f)
                if esz2 is None:
                    break
                estart = f.tell()
                if eid2 == 0x4DBB:  # Seek
                    sid_v = None
                    spos = None
                    send = estart + esz2
                    while f.tell() < send:
                        kid, _ = read_id(f)
                        if kid is None:
                            break
                        ksz, _ = read_vint(f)
                        if ksz is None:
                            break
                        data = f.read(ksz)
                        if kid == 0x53AB and data:  # SeekID
                            sid_v = int.from_bytes(data, "big")
                        elif kid == 0x53AC and data:  # SeekPosition
                            spos = int.from_bytes(data, "big")
                    if sid_v == 0x1C53BB6B and spos is not None:  # Cues
                        abs_pos = seg_data + spos
                        if abs_pos < 0 or abs_pos >= size:
                            print(f"Cues SeekPosition {spos} -> {abs_pos} outside file ({size})")
                            sys.exit(2)
                f.seek(estart + esz2)
            f.seek(seek_end)
            continue
        if csize == c_unknown:
            break
        f.seek(cstart + csize)

print("ok")
sys.exit(0)
PY
)" || rc=$?
  if [ "$rc" -eq 124 ]; then
    warn "Validation timed out (possible stalled mount): EBML/segment bounds check for $dst"
    return 124
  fi
  if [ "$rc" -ne 0 ]; then
    warn "Validation failed: Matroska structure (EBML/segment bounds): ${out:-$dst}"
    return 1
  fi
  return 0
}

validate_mkv_mkvalidator() {
  local dst="$1"
  local errf rc=0
  if [ "$HAS_MKVALIDATOR" != true ]; then
    return 0
  fi
  errf="$(mktemp)"
  # --quiet --no-warn: structure/errors only (ERR* lines). Exit != 0 => corrupt.
  # Exit 124 => timeout (possible stalled mount) — not confirmed corrupt.
  run_mkvalidator --quiet --no-warn "$dst" >/dev/null 2>"$errf" || rc=$?
  if [ "$rc" -eq 124 ]; then
    warn "Validation timed out (possible stalled mount): mkvalidator for $dst"
    rm -f "$errf"
    return 124
  fi
  if [ "$rc" -ne 0 ] || grep -qE '^[\r]?ERR[0-9A-Fa-f]{3}:' "$errf" 2>/dev/null; then
    warn "Validation failed: mkvalidator reported structure errors in $dst"
    # Show a few ERR lines (strip CR from mkvalidator output)
    tr -d '\r' <"$errf" | grep -E '^ERR[0-9A-Fa-f]{3}:' | head -20 >&2 || cat "$errf" >&2
    rm -f "$errf"
    return 1
  fi
  rm -f "$errf"
  return 0
}

# Header/structure validation for existing (and new) MKV outputs.
# Always: EBML segment/SeekHead bounds (fast; catches truncation mkvmerge misses).
# mkvalidator (when installed): full ERR* structure check; results cached by size+mtime.
# Quick scan without cache: if CONVERT_MKVALIDATOR_ON_QUICK=0 (default), return failure so
# the file is queued and encode-time full validation runs mkvalidator once, then caches.
validate_mkv_structure() {
  local dst="$1"
  local quick="${2:-false}"
  local ebml_rc=0 mv_rc=0

  MKV_VALIDATE_DEFERRED=false
  MKV_VALIDATE_TIMED_OUT=false

  if mkv_structure_cache_hit "$dst"; then
    return 0
  fi

  validate_mkv_ebml_bounds "$dst" || ebml_rc=$?
  if [ "$ebml_rc" -eq 124 ]; then
    # Timeout ≠ corrupt: do not record_corrupt_mkv.
    MKV_VALIDATE_TIMED_OUT=true
    return 1
  fi
  if [ "$ebml_rc" -ne 0 ]; then
    record_corrupt_mkv "$dst" "ebml_bounds"
    return 1
  fi

  if [ "$HAS_MKVALIDATOR" != true ]; then
    # No mkvalidator — EBML bounds are the structure gate; cache that.
    mkv_structure_cache_store "$dst"
    return 0
  fi

  local _size
  _size="$(file_size_bytes "$dst")"
  if [ -n "$_size" ] && [ "$_size" -gt "$MKVALIDATOR_MAX_SIZE_BYTES" ]; then
    # Too large for mkvalidator's small-read parsing to finish in reasonable
    # time — EBML bounds already passed above, treat that as the gate here too.
    log_err "mkvalidator skipped ($(human_size_bytes "$_size") > $(human_size_bytes "$MKVALIDATOR_MAX_SIZE_BYTES") threshold) — EBML bounds already OK: $dst"
    mkv_structure_cache_store "$dst"
    return 0
  fi

  if [ "$quick" = true ] && [ "${MKVALIDATOR_ON_QUICK}" = "0" ]; then
    # Defer full mkvalidator to encode-time skip/validate (do not delete yet).
    MKV_VALIDATE_DEFERRED=true
    return 1
  fi

  validate_mkv_mkvalidator "$dst" || mv_rc=$?
  if [ "$mv_rc" -eq 124 ]; then
    # Timeout ≠ corrupt: do not record_corrupt_mkv.
    MKV_VALIDATE_TIMED_OUT=true
    return 1
  fi
  if [ "$mv_rc" -ne 0 ]; then
    record_corrupt_mkv "$dst" "mkvalidator"
    return 1
  fi

  mkv_structure_cache_store "$dst"
  return 0
}

# ffmpeg's own progress meter (frame=N ...) writes via \r, not \n, so a whole
# run's worth of updates can land on a single physical text line in a
# redirected file -- grep -o still finds every occurrence regardless of \r,
# we just need the last one. Printed to stderr independent of -loglevel
# (confirmed against a real captured -v error log), so this works even though
# the decode calls below run at -v error.
decoded_frame_count() {
  local errf="$1"
  local val
  # `|| true` on the assignment itself, not just the pipeline: with
  # `pipefail` active, zero matches makes the last grep exit 1, which
  # propagates as this function's own return status -- a bare
  # `frames="$(decoded_frame_count ...)"` at the call site would then abort
  # the whole script under `set -e` right at the exact moment (zero frames
  # found) this check exists to catch gracefully. Team review, 2026-07-27.
  val="$(grep -o 'frame=[[:space:]]*[0-9]\+' "$errf" 2>/dev/null | tail -1 | grep -o '[0-9]\+$')" || true
  printf '%s' "${val:-0}"
}

validate_mkv_decode_windows() {
  local dst="$1"
  local window="${2:-$MKV_VALIDATE_WINDOW_SECONDS}"
  local errf dur rc frames

  errf="$(mktemp)"

  # Team review (2026-07-22): run_ffmpeg_validation (timeout-wrapped), not
  # bare run_ffmpeg -- a `-t "$window"` argument only bounds decoded OUTPUT
  # duration, not wall-clock time, so a stalled NFS read during this probe
  # could otherwise hang the whole machine indefinitely, unlike every other
  # validation helper (ffprobe/mkvmerge/mkvalidator) which already times
  # out. `rc=0; cmd || rc=$?` distinguishes a real decode failure from a
  # timeout (124) instead of treating both identically as "decode error" --
  # a stalled mount must never get misread as confirmed corruption and
  # trigger deletion of a possibly-good output.
  rc=0
  run_ffmpeg_validation -v error -stats -t "$window" -i "$dst" -map 0:v:0 -f null - 2>"$errf" || rc=$?
  if [ "$rc" -eq 124 ]; then
    warn "Validation timed out (possible stalled mount): decode of first ${window}s of $dst"
    MKV_VALIDATE_TIMED_OUT=true
    rm -f "$errf"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    warn "Validation failed: decode error in first ${window}s of $dst"
    MKV_VALIDATE_FAILURE_REASON="decode_first"
    cat "$errf" >&2
    rm -f "$errf"
    return 1
  fi
  validate_mkv_ffmpeg_stderr "$errf" "first ${window}s of $dst" || { rm -f "$errf"; return 1; }

  # Catches a real bug found 2026-07-27 on "For Whom the Alchemist Exists
  # (2019)": ffmpeg exiting 0 here was being trusted as proof real content
  # exists in the window, but a `-t`/`-sseof` decode probe landing past
  # where a source's actual frames end (source had severely corrupted PTS,
  # decoding to only ~324 real frames despite the container reporting the
  # full ~2h nominal runtime) also exits 0 with zero frames processed --
  # exit code alone can't tell "healthy content decoded" from "found
  # nothing here, gave up cleanly."
  frames="$(decoded_frame_count "$errf")"
  if [ "${frames:-0}" -eq 0 ]; then
    warn "Validation failed: zero frames decoded in first ${window}s of $dst (container/stream duration may not reflect real content)"
    MKV_VALIDATE_FAILURE_REASON="zero_frames_decoded"
    record_corrupt_mkv "$dst" "zero_frames_decoded"
    rm -f "$errf"
    return 1
  fi

  dur="$(video_duration "$dst")"
  if awk -v d="$dur" -v w="$window" 'BEGIN { exit !(d>w) }'; then
    : > "$errf"
    rc=0
    run_ffmpeg_validation -v error -stats -sseof -"${window}" -i "$dst" -map 0:v:0 -f null - 2>"$errf" || rc=$?
    if [ "$rc" -eq 124 ]; then
      warn "Validation timed out (possible stalled mount): decode of last ${window}s of $dst"
      MKV_VALIDATE_TIMED_OUT=true
      rm -f "$errf"
      return 1
    fi
    if [ "$rc" -ne 0 ]; then
      warn "Validation failed: decode error in last ${window}s of $dst"
      MKV_VALIDATE_FAILURE_REASON="decode_last"
      cat "$errf" >&2
      rm -f "$errf"
      return 1
    fi
    validate_mkv_ffmpeg_stderr "$errf" "last ${window}s of $dst" || { rm -f "$errf"; return 1; }

    frames="$(decoded_frame_count "$errf")"
    if [ "${frames:-0}" -eq 0 ]; then
      warn "Validation failed: zero frames decoded in last ${window}s of $dst (container/stream duration may not reflect real content)"
      MKV_VALIDATE_FAILURE_REASON="zero_frames_decoded"
      record_corrupt_mkv "$dst" "zero_frames_decoded"
      rm -f "$errf"
      return 1
    fi
  fi

  rm -f "$errf"
  return 0
}

# Found 2026-07-31 on "KanColle The Movie (2016)": both an AV1 and an x265
# attempt independently produced an output whose video stream stopped
# advancing well before the source's real runtime while audio/container
# duration still read as ~full length (dur_dst ~= dur_src, so the
# duration-drift check above passed) -- validate_mkv_decode_windows still
# caught it here only because it happens to seek from the DESTINATION's own
# reported EOF, which matched the source's in this case. Team review
# (2026-07-31): that's incidental, not guaranteed -- a future case
# where the destination's own reported duration also shrinks (following the
# truncated video) would seek near the wrong point and could pass falsely.
# This check anchors on the SOURCE's duration instead, so it verifies real
# decodable video exists near where the file OUGHT to end regardless of
# what the destination container claims about itself. Root cause of why
# the video stream itself stalls on this class of long/subtitle+attachment-
# heavy source is not yet proven (competing theories from team research,
# neither confirmed against a real multi-hour reproduction) -- this is a
# defense-in-depth catch, not a fix for the underlying stall.
validate_mkv_video_reaches_source_eof() {
  local dst="$1" src_dur="$2"
  local window="${3:-$MKV_VALIDATE_WINDOW_SECONDS}"
  local start errf rc frames

  awk -v d="$src_dur" -v w="$window" 'BEGIN { exit !(d>w) }' || return 0
  start="$(awk -v d="$src_dur" -v w="$window" 'BEGIN { s=d-w; if (s<0) s=0; printf "%.3f", s }')"
  errf="$(mktemp)"

  rc=0
  run_ffmpeg_validation -v error -stats -ss "$start" -t "$window" \
    -i "$dst" -map 0:v:0 -f null - 2>"$errf" || rc=$?
  if [ "$rc" -eq 124 ]; then
    warn "Validation timed out (possible stalled mount): source-EOF video decode of $dst"
    MKV_VALIDATE_TIMED_OUT=true
    rm -f "$errf"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    warn "Validation failed: decode error near expected source EOF of $dst"
    MKV_VALIDATE_FAILURE_REASON="decode_source_eof"
    cat "$errf" >&2
    rm -f "$errf"
    return 1
  fi
  validate_mkv_ffmpeg_stderr "$errf" "source-EOF video decode of $dst" || { rm -f "$errf"; return 1; }

  frames="$(decoded_frame_count "$errf")"
  if [ "${frames:-0}" -eq 0 ]; then
    warn "Validation failed: zero video frames decoded near expected source EOF of $dst"
    MKV_VALIDATE_FAILURE_REASON="video_truncated"
    record_corrupt_mkv "$dst" "video_truncated"
    rm -f "$errf"
    return 1
  fi

  rm -f "$errf"
  return 0
}

# Missing-metadata gate: empty/unplayable files often have no duration or no video stream.
# quiet=true: return status only (no warn / corrupt log) — used for source triage.
# Returns 124 on ffprobe timeout (possible stalled mount) — callers must not
# treat that as confirmed corrupt / permanently-bad source.
ffprobe_metadata_ok() {
  local dst="$1"
  local quiet="${2:-false}"
  local errf dur codec rc=0

  errf="$(mktemp)"
  dur="$(run_ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$dst" 2>"$errf")" || rc=$?

  if [ "$rc" -eq 124 ]; then
    if [ "$quiet" != true ]; then
      warn "Validation timed out (possible stalled mount): ffprobe metadata for $dst"
    fi
    rm -f "$errf"
    return 124
  fi

  if [ "$rc" -ne 0 ] || search_cie 'error' "$errf"; then
    if [ "$quiet" != true ]; then
      warn "Validation failed: ffprobe error reading metadata from $dst"
      cat "$errf" >&2
    fi
    rm -f "$errf"
    return 1
  fi
  rm -f "$errf"

  if [ -z "$dur" ] || ! awk -v d="$dur" 'BEGIN { exit !(d+0 > 0) }'; then
    # Some .ts/.m2ts/.avi lack format duration but still have a playable video stream.
    rc=0
    dur="$(run_ffprobe -v error -select_streams v:0 -show_entries stream=duration \
      -of default=noprint_wrappers=1:nokey=1 "$dst" 2>/dev/null)" || rc=$?
    if [ "$rc" -eq 124 ]; then
      if [ "$quiet" != true ]; then
        warn "Validation timed out (possible stalled mount): ffprobe stream duration for $dst"
      fi
      return 124
    fi
  fi
  if [ -z "$dur" ] || ! awk -v d="$dur" 'BEGIN { exit !(d+0 > 0) }'; then
    if [ "$quiet" != true ]; then
      warn "Validation failed: missing/zero duration in $dst"
    fi
    return 1
  fi

  rc=0
  codec="$(run_ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 "$dst" 2>/dev/null)" || rc=$?
  if [ "$rc" -eq 124 ]; then
    if [ "$quiet" != true ]; then
      warn "Validation timed out (possible stalled mount): ffprobe codec for $dst"
    fi
    return 124
  fi
  if [ -z "$codec" ] || [ "$codec" = "unknown" ]; then
    if [ "$quiet" != true ]; then
      warn "Validation failed: no video stream mapping in $dst"
    fi
    return 1
  fi
  return 0
}

validate_mkv_metadata() {
  local dst="$1"
  local meta_rc=0
  MKV_VALIDATE_TIMED_OUT=false
  ffprobe_metadata_ok "$dst" false || meta_rc=$?
  if [ "$meta_rc" -eq 124 ]; then
    # Timeout ≠ corrupt: do not record_corrupt_mkv.
    MKV_VALIDATE_TIMED_OUT=true
    return 1
  fi
  if [ "$meta_rc" -ne 0 ]; then
    # Classify for corrupt log (best-effort).
    local dur
    dur="$(video_duration "$dst")"
    if [ -z "$dur" ] || ! awk -v d="$dur" 'BEGIN { exit !(d+0 > 0) }'; then
      record_corrupt_mkv "$dst" "missing_duration"
    else
      record_corrupt_mkv "$dst" "ffprobe_metadata"
    fi
    return 1
  fi
  return 0
}

validate_mkv_output() {
  local src="$1"
  local dst="$2"
  local src_dur_override="${3:-}"
  local quick="${4:-false}"
  local dur_src dur_dst diff pct

  MKV_VALIDATE_TIMED_OUT=false
  MKV_VALIDATE_DEFERRED=false
  MKV_VALIDATE_FAILURE_REASON=""

  if [ ! -s "$dst" ]; then
    warn "Validation failed: empty output $dst"
    MKV_VALIDATE_FAILURE_REASON="empty"
    record_corrupt_mkv "$dst" "empty"
    return 1
  fi

  # Metadata first: empty/unplayable files fail here without structure/decode work.
  if ! validate_mkv_metadata "$dst"; then
    # Propagate timeout side-channel set by validate_mkv_metadata.
    return 1
  fi

  local id_rc=0
  run_mkvmerge --identify "$dst" >/dev/null 2>&1 || id_rc=$?
  if [ "$id_rc" -eq 124 ]; then
    warn "Validation timed out (possible stalled mount): mkvmerge --identify for $dst"
    MKV_VALIDATE_TIMED_OUT=true
    return 1
  fi
  if [ "$id_rc" -ne 0 ]; then
    warn "Validation failed: mkvmerge cannot identify $dst"
    MKV_VALIDATE_FAILURE_REASON="mkvmerge_identify"
    record_corrupt_mkv "$dst" "mkvmerge_identify"
    return 1
  fi

  # Structure before duration-drift/decode: truncated MKVs often still identify.
  if ! validate_mkv_structure "$dst" "$quick"; then
    # Propagate MKV_VALIDATE_TIMED_OUT / MKV_VALIDATE_DEFERRED from structure.
    return 1
  fi

  if [ -n "$src_dur_override" ]; then
    dur_src="$src_dur_override"
  else
    dur_src="$(video_duration "$src")"
  fi
  dur_dst="$(video_duration "$dst")"
  # Destination duration is already required by validate_mkv_metadata.
  if awk -v a="$dur_src" -v b="$dur_dst" 'BEGIN { exit !(a>0 && b>0) }'; then
    diff="$(awk -v a="$dur_src" -v b="$dur_dst" 'BEGIN { printf "%.6f", (a>b)?a-b:b-a }')"
    pct="$(awk -v d="$diff" -v a="$dur_src" 'BEGIN { if (a<=0) print 100; else print (d/a)*100 }')"
    if awk -v p="$pct" 'BEGIN { exit !(p>3.0) }'; then
      warn "Validation failed: duration drift ${pct}% (src=${dur_src}s dst=${dur_dst}s)"
      MKV_VALIDATE_FAILURE_REASON="duration_drift"
      return 1
    fi
  fi

  if [ "$quick" != true ]; then
    validate_mkv_decode_windows "$dst" || return 1
    if awk -v a="$dur_src" 'BEGIN { exit !(a>0) }'; then
      validate_mkv_video_reaches_source_eof "$dst" "$dur_src" || return 1
    fi
    local audio_rc=0
    validate_mkv_audio_tracks "$dst" || audio_rc=$?
    if [ "$audio_rc" -eq 124 ]; then
      warn "Validation timed out (possible stalled mount): audio-track check for $dst"
      MKV_VALIDATE_TIMED_OUT=true
      return 1
    elif [ "$audio_rc" -ne 0 ]; then
      return 1
    fi
    local subtitle_rc=0
    validate_mkv_subtitle_tracks "$dst" || subtitle_rc=$?
    if [ "$subtitle_rc" -eq 124 ]; then
      warn "Validation timed out (possible stalled mount): subtitle-track check for $dst"
      MKV_VALIDATE_TIMED_OUT=true
      return 1
    elif [ "$subtitle_rc" -ne 0 ]; then
      return 1
    fi
  fi
  return 0
}

audio_track_reaches_near_eof() {
  local f="$1" idx="$2" window="$3" dur="$4"
  local start pts rc
  AUDIO_TRACK_CHECK_TIMED_OUT=false
  # -sseof is an ffmpeg-only input-seek flag; ffprobe's arg parser rejects
  # it outright ("Option not found"), so an ffprobe -sseof invocation
  # always silently fails and returns no packets -- discovered 2026-07-21
  # when a genuinely intact encode was rejected and deleted as
  # "audio_truncated". Use -read_intervals "START%+DURATION" instead
  # (ffprobe-native, confirmed working directly against a known-good
  # file): seek to an absolute timestamp window% seconds from start.
  start="$(awk -v d="$dur" -v w="$window" 'BEGIN { r = d - w; if (r < 0) r = 0; print r }')"
  # `&& rc=0 || rc=$?` (NOT `rc=${PIPESTATUS[0]}` after a bare assignment,
  # and NOT a trailing `|| true` inside the substitution) so a stalled-mount
  # timeout (rc 124) can be told apart from a genuine "no packets here" --
  # this script runs under `set -o pipefail`, and `head -1` deliberately
  # closing the pipe early sends ffprobe a SIGPIPE (exit 141) once it has
  # enough packets queued to write, which under pipefail makes the WHOLE
  # assignment statement's own exit status non-zero. A bare `pts="$(...)"`
  # followed on the next line by `rc=${PIPESTATUS[0]}` looks reasonable but
  # is a real crash: `set -e` sees the assignment itself fail and aborts the
  # entire script right there -- the rc= line, and everything below it in
  # this function, never runs (found via direct bash testing, 2026-07-22,
  # after team review flagged this pattern elsewhere in the file; verified
  # this exact construct crashes real bash, not merely a style concern). The
  # `&&`/`||` form keeps the failing exit status out of `set -e`'s reach
  # while still capturing the real code in `rc` (confirmed empirically: this
  # correctly yields 141 for the SIGPIPE case and 124 for a real timeout).
  pts="$(run_ffprobe -v error -read_intervals "${start}%+${window}" -select_streams "a:${idx}" \
    -show_entries packet=pts_time -of csv=p=0 "$f" 2>/dev/null | head -1)" && rc=0 || rc=$?
  # Team review (2026-07-22, round 2): treat rc==124 as a confirmed timeout
  # unconditionally (not only when $pts is also empty), mirroring
  # validate_mkv_subtitle_tracks's near-EOF check -- consistent handling
  # across both, even though a partial single packet before a timeout-kill
  # in this narrow window is arguably already sufficient positive proof of
  # audio presence.
  if [ "$rc" -eq 124 ]; then
    AUDIO_TRACK_CHECK_TIMED_OUT=true
    return 1
  fi
  # Team review (2026-07-22): a probe error that is neither a clean success
  # (rc 0), the benign head-closed-early SIGPIPE (141), nor a confirmed
  # timeout (124) is NOT itself proof the audio is actually missing here --
  # it's an ambiguous ffprobe failure (e.g. a brief NFS hiccup). Given the
  # source-side caller can turn a confirmed "truncated" verdict into a
  # permanent Deferred/ file move, treat this the same as a timeout (retry
  # next run) rather than folding it into a genuine audio_truncated verdict.
  if [ -z "$pts" ] && [ "$rc" -ne 0 ] && [ "$rc" -ne 141 ]; then
    AUDIO_TRACK_CHECK_TIMED_OUT=true
    return 1
  fi
  [ -n "$pts" ]
}

validate_mkv_audio_tracks() {
  local dst="$1"
  local n_audio i window dur audio_list arc
  AUDIO_TRACK_CHECK_TIMED_OUT=false
  # `&& arc=0 || arc=$?` (not a bare assignment then `arc=$?` on the next
  # line, and not a `| wc -l` pipe, which loses run_ffprobe's own exit code
  # to pipefail either way): a bare failing assignment aborts the whole
  # script right there under `set -e` before `arc=$?` ever runs -- verified
  # via direct bash testing, 2026-07-22 (see audio_track_reaches_near_eof's
  # comment for the full explanation). This form keeps a stalled-mount
  # timeout (124) from both crashing the script AND silently masquerading as
  # "0 audio streams found".
  audio_list="$(run_ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$dst" 2>/dev/null)" && arc=0 || arc=$?
  if [ -z "$audio_list" ] && [ "$arc" -eq 124 ]; then
    AUDIO_TRACK_CHECK_TIMED_OUT=true
    return 124
  fi
  # grep -c . (not wc -l): counts non-empty lines only, exits 0 either way
  # here since we already guard the zero-match case explicitly below.
  n_audio="$(printf '%s\n' "$audio_list" | grep -c . || true)"
  [ "${n_audio:-0}" -gt 0 ] || return 0
  dur="$(video_duration "$dst")"
  window="$AUDIO_TRUNCATION_CHECK_WINDOW_SECS"
  # A file shorter than the check window has nothing meaningful to seek
  # into near EOF -- skip rather than risk seeking past start-of-file.
  awk -v d="$dur" -v w="$window" 'BEGIN { exit !(d>w) }' || return 0
  # Only track a:0 (the primary/default track) is required to run the full
  # length. Checking every track was a real bug (team E2E review,
  # 2026-07-20): a secondary track that legitimately ends early -- a
  # commentary or isolated-score track not covering end credits, an
  # alternate-language dub that's simply shorter -- would fail this check
  # on a perfectly good encode, get deleted as "corrupt", get re-encoded,
  # and fail again identically every single run: an infinite reject loop
  # burning real compute on a file that was never actually broken. The
  # original incident this check exists for (Angel Cop) failed on ALL
  # tracks identically, so track 0 alone still catches that class of bug.
  if ! audio_track_reaches_near_eof "$dst" 0 "$window" "$dur"; then
    if [ "$AUDIO_TRACK_CHECK_TIMED_OUT" = true ]; then
      return 124
    fi
    warn "Validation failed: primary audio track a:0 has no packets in the last ${window}s of $dst -- likely a silent mid-encode audio dropout"
    record_corrupt_mkv "$dst" "audio_truncated"
    return 1
  fi
  return 0
}
