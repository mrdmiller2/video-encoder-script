#!/usr/bin/env bash
# ves-sharded-scan.sh -- shard-directory discovery/snapshotting, the
# find-videos/find-isos/find-bluray-roots helpers, and the mtime-keyed
# per-directory file-list cache (filecache_*) that backs cached repeat
# scans. Pure move from the former monolithic script -- no logic changes.

sample_start_middle() {
  local dur="$1"
  awk -v d="$dur" -v s="$SAMPLE_SECONDS" 'BEGIN {
    if (d <= 0) { print 0; exit }
    if (d <= s) { print 0; exit }
    start = (d / 2) - (s / 2)
    if (start < 0) start = 0
    if (start + s > d) start = d - s
    if (start < 0) start = 0
    printf "%.3f", start
  }'
}

file_size_bytes() {
  case "$PLATFORM" in
    macos) stat -f%z "$1" 2>/dev/null || echo 0 ;;
    linux|wsl) stat -c%s "$1" 2>/dev/null || echo 0 ;;
    # Any other/unrecognized platform (a plain BSD box, not macOS): GNU
    # stat's -c flag isn't guaranteed there. python3's portable os.stat is
    # the same fallback mkv_structure_stat_key already relies on.
    *)
      stat -c%s "$1" 2>/dev/null && return 0
      python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_size)' "$1" 2>/dev/null || echo 0
      ;;
  esac
}

human_size_bytes() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1073741824) printf "%.2f GB", b/1073741824
    else if (b >= 1048576) printf "%.2f MB", b/1048576
    else if (b > 0) printf "%.0f KB", b/1024
    else print "0 B"
  }'
}

sort_paths_by_size_desc() {
  local -n _paths="$1"
  local -a sized=() entry sz path
  local -a sorted_paths=()

  for path in "${_paths[@]}"; do
    if is_disk_source "$path"; then
      sz="$(disc_source_size_bytes "$path")"
    else
      sz="$(file_size_bytes "$path")"
    fi
    sized+=("${sz}"$'\t'"${path}")
  done

  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    path="${entry#*$'\t'}"
    sorted_paths+=("$path")
  done < <(printf '%s\n' "${sized[@]}" | sort -t $'\t' -k1 -nr)

  _paths=("${sorted_paths[@]}")
}

get_scan_roots() {
  local -n _roots="$1"
  local shard base

  _roots=()
  # Name-glob filter: only matching dirs at shard depth (or depth 1 under --path).
  # Always expands to concrete directories so --no-shard cannot re-scan the whole shelf.
  if [ -n "$NAME_GLOB" ]; then
    local depth="$SHARD_DEPTH"
    [ "$depth" -ge 1 ] 2>/dev/null || depth=1
    while IFS= read -r shard; do
      [ -n "$shard" ] || continue
      base="$(basename "$shard")"
      if name_glob_matches "$base" "$NAME_GLOB"; then
        _roots+=("$shard")
      fi
    done < <(find "$SEARCH_PATH" -mindepth "$depth" -maxdepth "$depth" -type d -not -name 'ffmpeg-logs' -not -name 'Deferred' -not -name '.*' 2>/dev/null | LC_ALL=C sort)

    if [ "${#_roots[@]}" -eq 0 ]; then
      err "No directories under $SEARCH_PATH match name-glob '$NAME_GLOB' (shard-depth=$depth)"
      return 1
    fi
    return 0
  fi

  if [ "$NO_SHARD" = true ]; then
    _roots=("$SEARCH_PATH")
    return 0
  fi

  # -not -name 'ffmpeg-logs' -not -name 'Deferred' -not -name '.*': this
  # script's own sidecar dirs (ffmpeg-logs/ for per-title stderr logs,
  # .convert-v5-filecache/ and any other hidden dir for caches/flags) plus
  # Deferred/ (where flag_bad_source_for_human parks files for a human --
  # see there). Without this exclusion, a shard-depth scan of an
  # already-once-processed leaf movie folder mistakes a sidecar dir for the
  # only "shard", finds 0 videos in it, and silently never scans the real
  # video file(s) sitting in the folder itself -- discovered 2026-07-21 when
  # a folder that had already produced ffmpeg-logs/ and
  # .convert-v5-filecache/ (from an earlier encode attempt) came back
  # "0 video(s)" on the next run. Deferred/ needs the same exclusion for a
  # different reason: without it, a deferred file would be silently
  # rediscovered and reprocessed on every subsequent scan instead of staying
  # parked for a person to look at.
  while IFS= read -r shard; do
    [ -n "$shard" ] || continue
    _roots+=("$shard")
  done < <(find "$SEARCH_PATH" -mindepth "$SHARD_DEPTH" -maxdepth "$SHARD_DEPTH" -type d -not -name 'ffmpeg-logs' -not -name 'Deferred' -not -name '.*' 2>/dev/null | LC_ALL=C sort)

  if [ "${#_roots[@]}" -eq 0 ]; then
    _roots=("$SEARCH_PATH")
  fi
}

# True when the roots from get_scan_roots() are real subdirectories rather
# than its zero-subdirectory fallback of roots=("$SEARCH_PATH"). Every scan
# that iterates shards from get_scan_roots() also needs a separate pass over
# $SEARCH_PATH itself for loose files sitting directly in it (e.g. the main
# movie file next to a single Featurettes/ subfolder) -- but gating that
# extra pass on "more than one shard" (the original condition at every call
# site below) silently skipped it whenever exactly one real subdirectory
# existed, since that's still a single "shard" yet not $SEARCH_PATH itself.
# Discovered 2026-07-22 via a live fleet test: Oppenheimer (2023)'s main .mkv
# was never scanned at all (no log line, no skip entry) because its lone
# Featurettes/ subfolder was the only shard found.
roots_need_catchup_scan() {
  local -n _r="$1"
  [ "$NO_SHARD" = false ] || return 1
  [ "${#_r[@]}" -ge 1 ] || return 1
  [ "${_r[0]}" != "$SEARCH_PATH" ]
}

# Which scan-root shard contains this source path.
shard_for_path() {
  local src="$1"
  local -a roots=()
  local root best=""
  get_scan_roots roots
  for root in "${roots[@]}"; do
    case "$src" in
      "$root"|"$root"/*) best="$root" ;;
    esac
  done
  [ -n "$best" ] && printf '%s' "$best" || printf '%s' "$SEARCH_PATH"
}

count_videos_under_shard() {
  local shard="$1"
  local f count=0 bytes=0 sz
  while IFS= read -r f; do
    is_derived_output "$f" && continue
    is_video_file "$f" || continue
    count=$((count + 1))
    sz="$(file_size_bytes "$f")"
    bytes=$((bytes + sz))
  done < <(find_convert_videos_under "$shard")
  printf '%s %s' "$count" "$bytes"
}

count_disks_under_shard() {
  local shard="$1"
  local -a disks=()
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && disks+=("$line")
  done < <(find_isos_under "$shard")
  while IFS= read -r line; do
    [ -n "$line" ] && disks+=("$line")
  done < <(find_bluray_roots_under "$shard")
  printf '%s' "${#disks[@]}"
}

build_shard_snapshot() {
  local out_file="$1"
  local -a roots=()
  local shard vinfo vcount vbytes dcount
  local tmpf
  get_scan_roots roots
  # Build entirely into a private mktemp file and mv into place once at the
  # end -- the previous version truncated/appended $out_file by path on
  # every line, reopening a predictable path repeatedly (same symlink-race
  # class as the folder-flag and pipeline-queue fixes elsewhere this round).
  tmpf="$(mktemp "${out_file}.XXXXXX" 2>/dev/null)" || return 1
  for shard in "${roots[@]}"; do
    vinfo="$(count_videos_under_shard "$shard")"
    vcount="${vinfo%% *}"
    vbytes="${vinfo##* }"
    dcount="$(count_disks_under_shard "$shard")"
    printf '%s\t%s\t%s\t%s\n' "$shard" "$vcount" "$vbytes" "$dcount" >>"$tmpf"
  done
  if roots_need_catchup_scan roots; then
    vcount=0
    vbytes=0
    local f sz
    while IFS= read -r f; do
      is_derived_output "$f" && continue
      is_video_file "$f" || continue
      vcount=$((vcount + 1))
      sz="$(file_size_bytes "$f")"
      vbytes=$((vbytes + sz))
    done < <(find_videos_at_root "$SEARCH_PATH")
    dcount=0
    local line
    while IFS= read -r line; do
      [ -n "$line" ] && dcount=$((dcount + 1))
    done < <(find_isos_at_root "$SEARCH_PATH")
    while IFS= read -r line; do
      [ -n "$line" ] && dcount=$((dcount + 1))
    done < <(find_bluray_roots_at_root "$SEARCH_PATH")
    printf '%s\t%s\t%s\t%s\n' "$SEARCH_PATH" "$vcount" "$vbytes" "$dcount" >>"$tmpf"
  fi
  LC_ALL=C sort -o "$tmpf" "$tmpf"
  if mv -f "$tmpf" "$out_file" 2>/dev/null; then
    _restore_default_file_mode "$out_file"
  else
    rm -f "$tmpf" 2>/dev/null
  fi
}

compare_shard_snapshots() {
  local old_file="$1"
  local new_file="$2"
  [ -f "$old_file" ] || return 0
  awk -F '\t' -v oldf="$old_file" -v newf="$new_file" '
    FNR == NR {
      old[$1] = $2 "\t" $3 "\t" $4
      next
    }
    {
      new[$1] = $2 "\t" $3 "\t" $4
    }
    END {
      for (s in old) {
        if (!(s in new)) print "removed\t" s "\t" old[s]
      }
      for (s in new) {
        if (!(s in old)) print "added\t" s "\t" new[s]
        else if (old[s] != new[s]) print "changed\t" s "\t" old[s] "\t->\t" new[s]
      }
    }
  ' "$old_file" "$new_file"
}

find_videos_under() {
  local root="$1"
  local -a pred=()
  build_find_video_pred pred
  find "$root" -type f "${pred[@]}" \
    ! -iname '*.AV1.mkv' ! -iname '*.x265.mkv' ! -path '*/Deferred/*' 2>/dev/null
}

find_convert_videos_under() {
  local root="$1" skip_merge="${2:-false}"
  local -a raw=()
  while IFS= read -r f; do [ -n "$f" ] && raw+=("$f"); done < <(find_convert_videos_under_cached "$root")
  [ "$skip_merge" = true ] || apply_multipart_merging raw
  # printf '%s\n' with a truly empty argument list still runs the format
  # string once, emitting a single spurious blank line -- a shard/root with
  # genuinely zero matching files would otherwise inject a phantom empty-
  # string entry into every caller's video list.
  [ "${#raw[@]}" -eq 0 ] || printf '%s\n' "${raw[@]}"
}

find_videos_at_root() {
  local root="$1" skip_merge="${2:-false}"
  local -a pred=() raw=()
  build_find_video_pred pred
  while IFS= read -r f; do [ -n "$f" ] && raw+=("$f"); done < <(find "$root" -maxdepth 1 -type f "${pred[@]}" \
    ! -iname '*.AV1.mkv' ! -iname '*.x265.mkv' 2>/dev/null)
  [ "$skip_merge" = true ] || apply_multipart_merging raw
  [ "${#raw[@]}" -eq 0 ] || printf '%s\n' "${raw[@]}"
}

find_isos_under() {
  local root="$1"
  find "$root" -type f -iname '*.iso' ! -path '*/Deferred/*' 2>/dev/null
}

find_isos_at_root() {
  local root="$1"
  find "$root" -maxdepth 1 -type f -iname '*.iso' 2>/dev/null
}

find_bluray_roots_under() {
  local root="$1"
  find "$root" -type d -name BDMV ! -path '*/Deferred/*' 2>/dev/null | while IFS= read -r bdmv; do
    [ -n "$bdmv" ] || continue
    dirname "$bdmv"
  done | LC_ALL=C sort -u
}

find_bluray_roots_at_root() {
  local root="$1"
  find "$root" -mindepth 1 -maxdepth 2 -type d -name BDMV 2>/dev/null | while IFS= read -r bdmv; do
    [ -n "$bdmv" ] || continue
    dirname "$bdmv"
  done | LC_ALL=C sort -u
}

filecache_init() {
  FILECACHE_DIR="${JOB_SIDECAR_DIR:-$JOB_ROOT}/.convert-v5-filecache"
}

_filecache_key() {
  # Portable path->filename hash: sha1sum (Linux) or shasum -a 1 (macOS).
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha1sum | cut -d' ' -f1
  else
    printf '%s' "$1" | shasum -a 1 | cut -d' ' -f1
  fi
}

# A directory's own mtime only changes when a DIRECT child is added/removed/
# renamed (POSIX). For a nested layout like Show/Season 2/new-episode.mkv,
# adding that episode bumps Season 2's mtime, not Show's -- so keying the
# cache on Show's own mtime alone means new episodes added deep inside a
# season folder are invisible forever (cache/done-flag never invalidates).
# Fix: key on the MAX mtime across the directory and every subdirectory in
# its subtree. Cost is proportional to the number of subdirectories (season
# folders — tens, not the thousands of episode files this cache exists to
# avoid re-stating on every restart), so this keeps the original performance
# win while actually detecting changes anywhere in the subtree.
dir_subtree_max_mtime() {
  local dir="$1"
  # One python3 process walking the whole subtree, not one process PER
  # subdirectory (a season-heavy show folder over NFS previously spawned a
  # python3 + its own stat() round trip for every season dir on every call).
  python3 - "$dir" <<'PY' 2>/dev/null
import os, sys, fnmatch
root = sys.argv[1]
# Internal staging/junk dirs this script creates and destroys as part of
# normal operation (RAM-disk staging, multipart-merge scratch space, the
# Deferred quarantine folder, etc.) are already excluded from the actual
# video find() this cache serves. Moving a file into/out of one of these
# still bumps ITS PARENT's own mtime, which would otherwise force a full
# cache-invalidating re-scan even though the real video listing never
# changed -- exclude them here too, and prune descent into them entirely
# since nothing under them is ever relevant to this cache.
SKIP_PATTERNS = (
    'Deferred', '.convert-stage-*', '.convert-multipart-*',
    '.convert-finalize-*', '.convert-streamopt-*', '.convert-hbprog-*',
)
def is_skip(name):
    return any(fnmatch.fnmatch(name, p) for p in SKIP_PATTERNS)
best = 0
try:
    best = int(os.stat(root).st_mtime)
except OSError:
    pass
for cur, dirs, _ in os.walk(root):
    dirs[:] = [d for d in dirs if not is_skip(d)]
    for d in dirs:
        try:
            mt = int(os.stat(os.path.join(cur, d)).st_mtime)
        except OSError:
            continue
        if mt > best:
            best = mt
print(best)
PY
}

filecache_get() {  # dir -> file list on stdout; returns 1 on cache miss
  local dir="$1" cache mtime cached_mtime
  [ -n "$FILECACHE_DIR" ] || return 1
  cache="$FILECACHE_DIR/$(_filecache_key "$dir").list"
  [ -f "$cache" ] || return 1
  mtime="$(dir_subtree_max_mtime "$dir")" || true
  [ -n "$mtime" ] || return 1
  cached_mtime="$(sed -n 1p "$cache" 2>/dev/null)"
  [ "$mtime" = "$cached_mtime" ] || return 1
  tail -n +2 "$cache" 2>/dev/null
  return 0
}

filecache_put() {  # dir, nameref file-list array
  local dir="$1"
  local -n _files_ref="$2"
  local cache mtime
  [ -n "$FILECACHE_DIR" ] || return 0
  mkdir -p "$FILECACHE_DIR" 2>/dev/null || return 0
  mtime="$(dir_subtree_max_mtime "$dir")" || true
  [ -n "$mtime" ] || return 0
  cache="$FILECACHE_DIR/$(_filecache_key "$dir").list"
  # Write to a temp file and rename into place atomically -- a direct
  # `>"$cache"` write that's interrupted (crash, NFS hiccup, another fleet
  # machine reading mid-write) can leave just the mtime header on disk.
  # filecache_get() would then read that as a valid cache hit with an empty
  # file list, silently treating every video in the folder as gone until the
  # directory's mtime changes again. mktemp's randomized suffix (not just
  # the PID) keeps this name unpredictable -- a PID alone is guessable/
  # enumerable by another local process wanting to race a symlink into place.
  local cache_tmp
  cache_tmp="$(mktemp "${cache}.XXXXXX")" || return 0
  { printf '%s\n' "$mtime"; printf '%s\n' "${_files_ref[@]}"; } >"$cache_tmp" 2>/dev/null \
    && mv -f "$cache_tmp" "$cache" 2>/dev/null \
    && _restore_default_file_mode "$cache" \
    || rm -f "$cache_tmp" 2>/dev/null
}

# Cache-accelerated recursive video find. Falls back to a flat find when
# root has no subdirectories (a single show/movie folder — nothing to cache
# at a coarser level than the flat scan itself).
find_convert_videos_under_cached() {
  local root="$1"
  local -a pred=() raw=() subdirs=()
  build_find_video_pred pred

  while IFS= read -r d; do [ -n "$d" ] && subdirs+=("$d"); done \
    < <(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name 'Deferred' ! -name '.*' 2>/dev/null | LC_ALL=C sort)

  if [ "${#subdirs[@]}" -eq 0 ]; then
    while IFS= read -r f; do [ -n "$f" ] && raw+=("$f"); done \
      < <(find "$root" -type f "${pred[@]}" ! -path '*/Deferred/*' 2>/dev/null)
    [ "${#raw[@]}" -eq 0 ] || printf '%s\n' "${raw[@]}"
    return 0
  fi

  local d hits=0 misses=0 done_skips=0 cached sub_out
  for d in "${subdirs[@]}"; do
    if folder_marked_done "$d"; then
      done_skips=$((done_skips + 1))
      continue
    fi
    if cached="$(filecache_get "$d")"; then
      hits=$((hits + 1))
      [ -n "$cached" ] && while IFS= read -r f; do [ -n "$f" ] && raw+=("$f"); done <<<"$cached"
    else
      misses=$((misses + 1))
      mark_folder_inprogress "$d"
      local -a sub_files=()
      while IFS= read -r f; do [ -n "$f" ] && sub_files+=("$f"); done \
        < <(find "$d" -type f "${pred[@]}" ! -path '*/Deferred/*' 2>/dev/null)
      filecache_put "$d" sub_files
      raw+=("${sub_files[@]}")
    fi
  done
  # Loose files directly under root, not inside any subdirectory.
  while IFS= read -r f; do [ -n "$f" ] && raw+=("$f"); done \
    < <(find "$root" -maxdepth 1 -type f "${pred[@]}" 2>/dev/null)

  if [ "$done_skips" -gt 0 ]; then
    log_err "Folder-done: $done_skips subdirectory(ies) already complete (skipped entirely, no scan)"
  fi
  if [ "$hits" -gt 0 ] || [ "$misses" -gt 0 ]; then
    log_err "File-list cache: $hits/$(( hits + misses )) subdirectory(ies) unchanged (skipped re-scan)"
  fi
  [ "${#raw[@]}" -eq 0 ] || printf '%s\n' "${raw[@]}"
}
