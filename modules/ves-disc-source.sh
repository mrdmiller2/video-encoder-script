#!/usr/bin/env bash
# ves-disc-source.sh -- ISO/BDMV disc-source discovery, HandBrake title
# scan/selection, and both disc-extraction paths (fast stream-copy and
# the x264 -q0 lossless fallback). Pure move from the former monolithic
# script -- no logic changes.

is_iso_file() {
  [ "$(to_lower "${1##*.}")" = "iso" ]
}

is_bluray_root() {
  [ -d "$1/BDMV" ]
}

is_disk_source() {
  is_iso_file "$1" || is_bluray_root "$1"
}

disc_source_size_bytes() {
  local src="$1"
  if is_iso_file "$src"; then
    file_size_bytes "$src"
  elif is_bluray_root "$src"; then
    # du -b is GNU-only (BSD/macOS du has no -b) -- sum real file sizes
    # instead, via the already-portable file_size_bytes helper.
    local total=0 f sz
    while IFS= read -r f; do
      sz="$(file_size_bytes "$f")"
      total=$((total + sz))
    done < <(find "$src" -type f 2>/dev/null)
    printf '%s' "$total"
  else
    echo 0
  fi
}

discover_disk_sources() {
  local -n _out="$1"
  local -a roots=() raw=()
  local shard line

  _out=()
  get_scan_roots roots

  for shard in "${roots[@]}"; do
    while IFS= read -r line; do
      [ -n "$line" ] && raw+=("$line")
    done < <(find_isos_under "$shard")
    while IFS= read -r line; do
      [ -n "$line" ] && raw+=("$line")
    done < <(find_bluray_roots_under "$shard")
  done

  if roots_need_catchup_scan roots; then
    while IFS= read -r line; do
      [ -n "$line" ] && raw+=("$line")
    done < <(find_isos_at_root "$SEARCH_PATH")
    while IFS= read -r line; do
      [ -n "$line" ] && raw+=("$line")
    done < <(find_bluray_roots_at_root "$SEARCH_PATH")
  fi

  if [ "${#raw[@]}" -eq 0 ]; then
    return 0
  fi

  while IFS= read -r line; do
    [ -n "$line" ] && _out+=("$line")
  done < <(printf '%s\n' "${raw[@]}" | LC_ALL=C sort -u)
}

# HandBrake's own main-feature detector uses stronger signals than a plain
# duration comparison (VTS/angle structure, not just runtime), so it can
# correctly disambiguate discs our duration-dominance threshold below
# flags as "too ambiguous, skip" -- found 2026-07-31 on "Zu Warriors
# (2001).iso" (two genuine feature-length titles, 104min vs 80min, only
# ~29% apart, under our 40% DISK_TITLE_DOMINANCE_PCT threshold) where
# HandBrakeCLI --main-feature correctly and immediately identified title 1
# as the main feature. Per explicit user direction: disc sources should be
# resolved by HandBrake, not punted to manual review, whenever HandBrake
# itself can make the call. Prints "idx:duration" or empty if HandBrake
# didn't mark any title as the main feature (falls through to the
# duration-dominance heuristic below in that case).
# Single full disc scan (no --main-feature restriction), reused by both
# handbrake_scan_main_feature_title() and handbrake_scan_title_durations()
# instead of each running its own separate HandBrake invocation -- team
# review, 2026-08-04: a --main-feature-restricted scan and a full scan were
# previously run back-to-back for every disc even though the full scan's
# own text already carries the "+ Main Feature" flag when one exists. This
# also makes it possible for select_dominant_disk_title() to compute
# duration-uniqueness across every title on the disc without a third scan.
handbrake_full_disc_scan() {
  local src="$1"
  run_handbrake -t 0 --scan -i "$src" 2>&1 || true
}

handbrake_scan_main_feature_title() {
  local scan_txt="$1"
  awk '
    /^\+ title [0-9]+:/ {
      if (match($0, /title [0-9]+/)) {
        idx = substr($0, RSTART, RLENGTH); sub(/title /, "", idx); idx = idx + 0
      } else idx = 0
      dur = 0; is_main = 0
    }
    /\+ Main Feature/ { is_main = 1 }
    /^  \+ duration: / {
      n = split($3, t, ":")
      if (n >= 3) dur = t[1] * 3600 + t[2] * 60 + int(t[3]) + 0
      if (is_main && idx > 0 && dur > 0) { print idx ":" dur; exit }
    }
  ' <<< "$scan_txt"
}

handbrake_scan_title_durations() {
  local scan_txt="$1"
  awk '
    BEGIN { idx = 0; dur = 0 }
    /^\+ title [0-9]+:/ {
      if (idx > 0 && dur > 0) print idx ":" dur
      # Portable 2-arg match (RSTART/RLENGTH are POSIX) -- 3-arg match(...,
      # array) is a gawk extension BSD/macOS awk does not support.
      if (match($0, /title [0-9]+/)) {
        idx = substr($0, RSTART, RLENGTH); sub(/title /, "", idx); idx = idx + 0
      } else idx = 0
      dur = 0
    }
    /^  \+ duration: / {
      n = split($3, t, ":")
      if (n >= 3) dur = t[1] * 3600 + t[2] * 60 + int(t[3]) + 0
    }
    END { if (idx > 0 && dur > 0) print idx ":" dur }
  ' <<< "$scan_txt"
}

# Prints SELECT:<title>:<seconds> or SKIP:<reason>
select_dominant_disk_title() {
  local src="$1"
  local -a lines=()
  local line scan_txt main_feature sel_idx sel_dur

  scan_txt="$(handbrake_full_disc_scan "$src")"
  while IFS= read -r line; do
    [ -n "$line" ] && lines+=("$line")
  done < <(handbrake_scan_title_durations "$scan_txt")

  if [ "${#lines[@]}" -eq 0 ]; then
    printf 'SKIP:%s' "no titles found on disc"
    return 0
  fi

  main_feature="$(handbrake_scan_main_feature_title "$scan_txt")"
  if [ -n "$main_feature" ]; then
    sel_idx="${main_feature%%:*}"
    sel_dur="${main_feature##*:}"
  elif [ "${#lines[@]}" -eq 1 ]; then
    sel_idx="${lines[0]%%:*}"
    sel_dur="${lines[0]##*:}"
  else
    local result
    result="$(printf '%s\n' "${lines[@]}" | awk -v pct="$DISK_TITLE_DOMINANCE_PCT" '
      BEGIN { cnt = 0; thresh = 1 + pct / 100 }
      {
        split($0, a, ":")
        idx[cnt] = a[1]
        dur[cnt] = a[2] + 0
        cnt++
      }
      END {
        max_i = 0
        for (i = 1; i < cnt; i++) {
          if (dur[i] > dur[max_i]) max_i = i
        }
        max_d = dur[max_i]
        for (i = 0; i < cnt; i++) {
          if (i == max_i) continue
          if (max_d <= dur[i] * thresh) {
            print "SKIP"
            exit
          }
        }
        print "SELECT:" idx[max_i] ":" max_d
      }
    ')"
    if [ "$result" = SKIP ]; then
      printf 'SKIP:%s' "Unable to Determine which title you wish to convert, process this manually"
      return 0
    fi
    sel_idx="${result#SELECT:}"; sel_idx="${sel_idx%%:*}"
    sel_dur="${result##*:}"
  fi

  # Duration-uniqueness across every title on the disc, independent of how
  # the title was chosen (main-feature flag, single-title, or dominance) --
  # used to gate the fast stream-copy path in
  # try_fast_stream_copy_disc_extraction(): if another title's duration
  # falls within DISC_STREAM_COPY_DURATION_TOLERANCE_SECONDS of the
  # selected one, a duration-only match can't safely prove libbluray's
  # auto-selected playlist is the SAME title (playlist-obfuscated/multi-
  # angle discs can have two full-length playlists of near-identical
  # runtime) -- team review, 2026-08-04. Encoded as a 4th colon-delimited
  # field on the SELECT: return value (NOT a global variable -- every
  # caller invokes this function via command substitution, which forks a
  # subshell in bash; a global assignment made in here would silently
  # never reach the caller. DISC_EXTRACT_SCRATCH_FILE elsewhere in this
  # script has that exact same latent bug, out of scope to fix here).
  local unique=1
  if printf '%s\n' "${lines[@]}" | awk -F: -v self="$sel_idx" -v d="$sel_dur" -v tol="$DISC_STREAM_COPY_DURATION_TOLERANCE_SECONDS" '
      $1 == self { next }
      { diff = $2 - d; if (diff < 0) diff = -diff; if (diff <= tol) { print "collision"; exit } }
    ' | grep -q collision; then
    unique=0
  fi

  printf 'SELECT:%s:%s:%s' "$sel_idx" "$sel_dur" "$unique"
}

# Basename the extracted-title symlink should have inside media_content_dir
# -- ISO: strip the .iso extension and add .mkv; BDMV: media_content_dir
# already returns the disc root itself, so this is just that dir's own
# name (matching this script's existing av1_output_path naming convention
# for BDMV sources).
disc_extract_link_basename() {
  local src="$1" base
  if is_iso_file "$src"; then
    base="${src##*/}"
    printf '%s.mkv' "${base%.*}"
  else
    printf '%s.mkv' "$(basename "$src")"
  fi
}

# Probes the duration (seconds) libbluray's default title-selection
# picks for a *disc source* (.iso file or BDMV root directory) when
# opened via ffmpeg's `bluray:` protocol with no explicit -playlist
# (auto-selects the main/longest playlist -- the same thing HandBrake's
# own main-feature heuristic almost always lands on). No OS-level mount
# required -- confirmed empirically 2026-08-04 (libbluray has its own
# internal image-reader, works directly against a raw .iso). Prints the
# duration on success; prints nothing and returns 1 on any failure (not
# a Blu-ray structure, corrupt disc, ffprobe missing libbluray support).
#
# NOT for probing an ordinary media file's duration -- use
# video_duration() for that; prepending "bluray:" to a plain .mkv would
# make ffprobe try to parse it as a disc structure and fail.
bluray_probe_duration_seconds() {
  local src="$1" out
  out="$(run_ffprobe -v error -i "bluray:$src" -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 2>/dev/null || true)"
  # Require the ENTIRE output to be a single positive number, not just a
  # numeric-looking prefix -- awk's "d+0" coercion would happily accept
  # multi-line or trailing-garbage output as valid (team review, 2026-08-04).
  case "$out" in
    ''|*[!0-9.]*|*.*.*) return 1 ;;
  esac
  if awk -v d="$out" 'BEGIN { exit !(d+0 > 0) }'; then
    printf '%s' "$out"
    return 0
  fi
  return 1
}

# Stages a disc source (.iso file or BDMV root directory) to a local path
# via `cp -a`, before any libbluray read is attempted against it.
# Empirically required 2026-08-04: libbluray's `bluray:` protocol does
# many small seeky reads for BD navigation structures, which is
# catastrophically slow over a network share -- ~0.27MB/s observed
# reading a real NAS-hosted ISO directly (would take 16+ hours for a
# typical disc), versus ~380MB/s reading the exact same disc already
# staged locally (the original fast-path design validation). A plain
# sequential copy of that same network ISO ran at normal network
# throughput, confirming the bottleneck is libbluray's read pattern, not
# the network link -- so staging locally first, THEN doing the fast
# local stream-copy, is still dramatically faster overall than the
# original x264 -q 0 path even though it's no longer the ~45s this
# feature's early validation measured against an already-local source.
# `cp -a` recurses directories on its own, so this handles both a
# single .iso file and a BDMV directory tree without a separate branch.
# Prints the local path on success; prints nothing and returns 1 on any
# failure or timeout (caller falls back to the original x264 path).
stage_disc_source_local() {
  local src="$1" local_staging_dir="$2"
  local base dest

  mkdir -p -- "$local_staging_dir" 2>/dev/null || return 1
  base="$(basename -- "$src")"
  dest="${local_staging_dir}/${base}"

  run_with_timeout "$DISC_LOCAL_COPY_TIMEOUT_SECONDS" cp -a -- "$src" "$dest" || {
    rm -rf -- "$dest" 2>/dev/null || true
    return 1
  }
  [ -e "$dest" ] || return 1
  printf '%s' "$dest"
  return 0
}

# Genuine zero-recompression extraction: stages the disc source locally
# first (stage_disc_source_local -- required, see its own comment for
# why a direct network read is unusable), then ffmpeg reads the LOCAL
# copy via libbluray (`bluray:$local_src`, auto-selected main playlist)
# and stream-copies every track (-c copy) instead of HandBrake's x264
# -q 0 re-encode. Verified empirically 2026-08-04 against a real
# 83.5-minute Blu-ray title: the local stream-copy itself takes ~45
# seconds versus 12+ hours for x264 -q 0, smaller output (no redundant
# DTS-core-plus-MA duplication from HandBrake's --all-audio expanding
# one physical DTS-HD MA stream into a core track plus an MA track),
# byte-identical video, full DTS-HD MA audio preserved (not just the
# backward-compatible core -- verified via ffprobe profile= on both
# tracks). Total wall time including the local staging copy is a few
# minutes for a real disc, not 45 seconds -- still a dramatic win over
# the original path.
#
# Safety: only trusted when the auto-selected title's probed duration
# matches the title select_dominant_disk_title() already selected
# (within DISC_STREAM_COPY_DURATION_TOLERANCE_SECONDS) -- this reuses
# all of that function's existing selection logic untouched rather than
# trying to independently re-derive HandBrake's title-numbering-to-
# playlist mapping. A disc where the auto-selected playlist doesn't
# match (multi-cut/region discs, ambiguous title sets), or where the
# local staging copy itself fails, safely returns 1 so the caller falls
# back to the slower but unconditionally-correct HandBrake path --
# never silently grabs the wrong title's content. Prints the scratch
# file's path on success (matching
# handbrake_extract_disc_title_lossless's own convention).
try_fast_stream_copy_disc_extraction() {
  local src="$1" expected_dur="$2" scratch_file="$3" duration_unique="$4"
  local probed out_dur local_staging_dir local_src rc=0

  # Duration-match alone can't distinguish two full-length playlists of
  # near-identical runtime (playlist-obfuscated/multi-angle discs) --
  # select_dominant_disk_title() already checked this across every title
  # on the disc; refuse the fast path outright when it found a collision.
  # Team review, 2026-08-04 (all three reviewers independently flagged
  # duration-only matching as unsafe on its own).
  if [ "$duration_unique" != "1" ]; then
    warn "Fast stream-copy skipped: another title on the disc has a duration within ${DISC_STREAM_COPY_DURATION_TOLERANCE_SECONDS}s of the selected one -- duration alone can't safely prove libbluray picked the same title -- falling back to lossless x264 extraction"
    return 1
  fi

  local_staging_dir="$(dirname -- "$scratch_file")/disc-source-local"
  local_src="$(stage_disc_source_local "$src" "$local_staging_dir")" || {
    warn "Fast stream-copy skipped: could not stage the disc source locally -- falling back to lossless x264 extraction"
    return 1
  }
  # Always clean up the local raw copy of the disc once this function
  # returns (success or failure) -- it served its purpose and is as
  # large as the disc itself. IMPORTANT: bash's RETURN trap is a single
  # GLOBAL trap table, not function-scoped, despite how it reads --
  # confirmed empirically 2026-08-04 after two independent AI reviewers
  # gave contradictory answers on this exact question. Left unguarded,
  # this trap would ALSO fire on the next function return anywhere in
  # the script (using whatever "$local_src" happens to be in scope at
  # that later point -- a real, verified data-loss risk, not
  # theoretical). `trap - RETURN` as the trap's own last action clears
  # it the instant it fires for real, before this function's own
  # `return` completes, so it cannot fire again for a caller.
  trap 'rm -rf -- "$local_src" 2>/dev/null || true; trap - RETURN' RETURN

  probed="$(bluray_probe_duration_seconds "$local_src")" || return 1
  if ! awk -v p="$probed" -v e="$expected_dur" -v tol="$DISC_STREAM_COPY_DURATION_TOLERANCE_SECONDS" \
      'BEGIN { d = p - e; if (d < 0) d = -d; exit !(d <= tol) }'; then
    warn "Fast stream-copy skipped: libbluray auto-selected title (${probed}s) doesn't match the selected title (${expected_dur}s) -- falling back to lossless x264 extraction"
    return 1
  fi

  run_with_timeout 600 "${FFMPEG_CMD[@]}" -y -v warning -i "bluray:$local_src" -map 0 -c copy "$scratch_file" || {
    rm -f -- "$scratch_file" 2>/dev/null || true
    return 1
  }
  if [ ! -s "$scratch_file" ]; then
    rm -f -- "$scratch_file" 2>/dev/null || true
    return 1
  fi

  # Final correctness check: the actual written file's duration must also
  # match -- a stream-copy that silently truncated (e.g. a corrupt disc
  # region) would still exit 0 from ffmpeg in some cases, so re-verify
  # against the real output, not just the pre-copy probe. This is a plain
  # media file now, NOT a disc structure -- video_duration(), not
  # bluray_probe_duration_seconds(). Fail CLOSED (discard + fall back) when
  # this probe itself can't produce a positive duration -- "unknown" must
  # never be treated as "trust it" (team review, 2026-08-04: all three
  # reviewers independently flagged the original version of this check as
  # fail-open on an unprobeable/zero-duration output).
  out_dur="$(video_duration "$scratch_file")"
  if ! awk -v p="$out_dur" -v e="$expected_dur" -v tol="$DISC_STREAM_COPY_DURATION_TOLERANCE_SECONDS" \
      'BEGIN { if (p+0 <= 0) exit 1; d = p - e; if (d < 0) d = -d; exit !(d <= tol) }'; then
    warn "Fast stream-copy output duration mismatch or unreadable (${out_dur}s vs expected ${expected_dur}s) -- discarding, falling back"
    rm -f -- "$scratch_file" 2>/dev/null || true
    return 1
  fi

  printf '%s' "$scratch_file"
  return 0
}

# Extracts the selected title losslessly (HandBrake has no video "copy"
# passthrough -- confirmed via --help) into a private file under
# DISC_EXTRACT_SCRATCH_DIR, deliberately NOT the RAM-disk/tmpfs staging
# path (a losslessly re-encoded Blu-ray can be tens of GB). Tries the
# genuine zero-recompression stream-copy path first
# (try_fast_stream_copy_disc_extraction); falls back to x264 -q 0 (not
# ffv1 -- see DISC_EXTRACT_SCRATCH_DIR's own comment for why: HandBrakeCLI
# 1.11.0's ffv1 encoder segfaults on real hardware, reproduced independent
# of source/quality/subtitles; x264 -q 0 verified genuinely lossless and
# working end-to-end) only when the fast path can't confidently identify
# the same title. Prints the scratch file's path on success; prints
# nothing and returns 1 on failure (space check failure, both extraction
# paths failing, or a reported-success-but-empty output -- same defensive
# check handbrake_encode already applies to its own real encodes).
handbrake_extract_disc_title_lossless() {
  local src="$1" title_idx="$2" title_dur="$3" title_dur_unique="${4:-0}"
  local scratch_dir scratch_file need have kind

  if is_iso_file "$src"; then kind="ISO disc"; else kind="Blu-ray disc"; fi

  if ! mkdir -p -- "$DISC_EXTRACT_SCRATCH_DIR" 2>/dev/null; then
    warn "Cannot create disc-extraction scratch dir — skipping $kind: $DISC_EXTRACT_SCRATCH_DIR"
    return 1
  fi
  need=$(( $(disc_source_size_bytes "$src") * DISC_EXTRACT_SPACE_MULTIPLIER ))
  have="$(_dir_free_bytes "$DISC_EXTRACT_SCRATCH_DIR" 2>/dev/null || echo 0)"
  if [ -z "$have" ] || [ "$have" -lt "$need" ] 2>/dev/null; then
    warn "Not enough free space in disc-extraction scratch dir ($DISC_EXTRACT_SCRATCH_DIR: $(human_size_bytes "${have:-0}") free, need ~$(human_size_bytes "$need") at ${DISC_EXTRACT_SPACE_MULTIPLIER}x disc size) — skipping $kind: $src"
    return 1
  fi

  scratch_dir="$(mktemp -d "${DISC_EXTRACT_SCRATCH_DIR}/.disc-extract-XXXXXX" 2>/dev/null)" || {
    warn "Could not create a private extraction scratch dir under $DISC_EXTRACT_SCRATCH_DIR — skipping $kind: $src"
    return 1
  }
  # chmod 1777 (world rwx + sticky bit), NOT 700 (the tighter permission
  # used by every other private staging dir in this script, e.g.
  # _local_stage_dir_for) -- empirically required on WSL-hybrid machines
  # (HandBrake running as the Windows .exe, e.g. PRINCE) where the
  # Windows-side process reaches this path through \\wsl.localhost\
  # interop under a different UID mapping than the Linux-side owner. A 700
  # dir here reproducibly failed with "ERROR: avio_open2 failed, errno -13"
  # (EACCES) from the Windows HandBrake process; verified end-to-end fixed
  # on PRINCE against the real "Zu Warriors (2001).iso". World-writable is
  # acceptable here specifically because this scratch dir is
  # local-machine-only (never NFS/network-shared), not the same trust
  # boundary as the RAM-disk/staging dirs the tighter permission elsewhere
  # is guarding -- the sticky bit still stops one local user/process from
  # deleting or renaming another's files inside it. Team review,
  # 2026-07-31: 1777 over plain 777, 770 rejected (no guaranteed shared
  # group across the WSL/Windows interop boundary).
  chmod 1777 "$scratch_dir" 2>/dev/null || true
  scratch_file="${scratch_dir}/$(canonical_title_from_source "$src").mkv"

  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] HandBrake extract (lossless x264 -q 0, title $title_idx): $src -> $scratch_file"
    rm -rf -- "$scratch_dir" 2>/dev/null || true
    return 1
  fi

  DISC_EXTRACT_SCRATCH_FILE="$scratch_file"

  if [ -n "$title_dur" ] && try_fast_stream_copy_disc_extraction "$src" "$title_dur" "$scratch_file" "$title_dur_unique" >/dev/null; then
    log "Fast stream-copy extraction OK: $scratch_file"
    printf '%s' "$scratch_file"
    return 0
  fi

  local rc=0
  run_handbrake_with_progress "Extracting disc title $title_idx (lossless x264 -q 0)" \
    -i "$src" -t "$title_idx" -o "$scratch_file" \
    -e x264 -q 0 --aencoder copy --all-audio --all-subtitles || rc=$?

  if [ "$rc" -eq 0 ] && [ ! -s "$scratch_file" ]; then
    warn "HandBrake reported success but the extracted title is missing/empty: $scratch_file"
    rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    warn "Lossless disc-title extraction failed (rc=$rc): $src"
    rm -rf -- "$scratch_dir" 2>/dev/null || true
    DISC_EXTRACT_SCRATCH_FILE=""
    return 1
  fi

  printf '%s' "$scratch_file"
  return 0
}
