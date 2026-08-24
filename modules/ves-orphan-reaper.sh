#!/usr/bin/env bash
# ves-orphan-reaper.sh -- the startup orphan-encoder-process/orphan-output
# reaper: process-identity matching, the multi-gate validate-and-dispose
# pipeline for orphaned staged candidates, and stale HandBrake-progress
# directory cleanup. Pure move from the former monolithic script -- no
# logic changes.

_utc_to_epoch() {
  local utc="$1" epoch
  # GNU date
  epoch="$(date -u -d "$utc" +%s 2>/dev/null)" && {
    printf '%s' "$epoch"
    return 0
  }
  # BSD/macOS date
  epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$utc" +%s 2>/dev/null)" && {
    printf '%s' "$epoch"
    return 0
  }
  return 1
}

_process_elapsed_secs() {
  local pid="$1" et
  et="$(ps -p "$pid" -o etimes= 2>/dev/null | tr -d '[:space:]')"
  if [[ "$et" =~ ^[0-9]+$ ]]; then
    printf '%s' "$et"
    return 0
  fi
  # macOS / BSD: etime is [[dd-]hh:]mm:ss
  et="$(ps -p "$pid" -o etime= 2>/dev/null | tr -d '[:space:]')"
  [ -n "$et" ] || return 1
  awk -v e="$et" 'BEGIN {
    n = split(e, a, /[-:]/)
    if (n == 2) { print a[1]*60 + a[2]; exit }
    if (n == 3) { print a[1]*3600 + a[2]*60 + a[3]; exit }
    if (n == 4) { print a[1]*86400 + a[2]*3600 + a[3]*60 + a[4]; exit }
    exit 1
  }'
}

# True if pid looks like a live convert-v*.sh / convert-current.sh instance.
# Used for staging-dir ownership — never use is_encoder_process() on script PIDs.
is_convert_script_process() {
  local pid="$1"
  local args
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
  case "$args" in
    *convert-v*.sh*|*convert-current.sh*) return 0 ;;
  esac
  return 1
}

# Confirm encoder_pid still refers to the encoder we recorded (not a reused PID).
encoder_identity_matches() {
  local pid="$1"
  local started_utc="${2:-}"
  local fingerprint="${3:-}"
  local etime now started_epoch expected_etime skew args
  is_encoder_process "$pid" || return 1
  if [ -n "$fingerprint" ]; then
    args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    case "$args" in
      *"$fingerprint"*) ;;
      *) return 1 ;;
    esac
  fi
  if [ -n "$started_utc" ]; then
    # Fail closed: if start-time metadata is present, both elapsed and UTC
    # parse must succeed — never accept identity on weak fingerprint alone.
    etime="$(_process_elapsed_secs "$pid" 2>/dev/null)" || etime=""
    started_epoch="$(_utc_to_epoch "$started_utc" 2>/dev/null)" || started_epoch=""
    if ! [[ "$etime" =~ ^[0-9]+$ ]] || ! [[ "$started_epoch" =~ ^[0-9]+$ ]]; then
      return 1
    fi
    now="$(date +%s)"
    expected_etime=$(( now - started_epoch ))
    [ "$expected_etime" -lt 0 ] && expected_etime=0
    skew=$(( etime - expected_etime ))
    [ "$skew" -lt 0 ] && skew=$(( -skew ))
    # >2 minutes skew → treat as PID reuse
    [ "$skew" -le 120 ] || return 1
  fi
  return 0
}

# TERM → poll (~5s) → identity-checked KILL for a known orphan encoder PID.
# Does not touch ACTIVE_ENCODER_* (that belongs to this run).
kill_orphaned_encoder_pid() {
  local pid="$1"
  local started_utc="${2:-}"
  local fingerprint="${3:-}"
  local waited=0
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 0
  encoder_identity_matches "$pid" "$started_utc" "$fingerprint" || {
    warn "Orphan reaper: refusing to signal pid=$pid — identity check failed (possible PID reuse)"
    return 1
  }
  warn "Orphan reaper: stopping orphaned encoder pid=$pid"
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$waited" -lt 50 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    if process_is_zombie "$pid"; then
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null && encoder_identity_matches "$pid" "$started_utc" "$fingerprint"; then
    warn "Orphan reaper: encoder pid=$pid did not exit after TERM; sending KILL"
    kill -KILL "$pid" 2>/dev/null || true
  else
    warn "Orphan reaper: pid=$pid changed identity before KILL; leaving untouched"
    return 1
  fi
  # Brief wait for death after KILL
  waited=0
  while [ "$waited" -lt 20 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  kill -0 "$pid" 2>/dev/null && return 1
  return 0
}

_orphan_dir_age_secs() {
  local path="$1" mtime now
  mtime="$(mkv_structure_stat_key "$path" 2>/dev/null)" || true; mtime="${mtime##*|}"
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)"
  printf '%s' $(( now - mtime ))
}

orphan_size_stable() {
  local f="$1" s1 s2 waited=0
  [ -f "$f" ] || return 1
  s1="$(file_size_bytes "$f")"
  [[ "$s1" =~ ^[0-9]+$ ]] && [ "$s1" -gt 0 ] || return 1
  sleep 2
  s2="$(file_size_bytes "$f")"
  if [ "$s1" = "$s2" ]; then
    return 0
  fi
  # This is the only liveness check the staging-dir disposal path has for
  # the actual ENCODER child (as opposed to the script PID, which the
  # flags-loop path separately verifies via kill -0/encoder_pid) -- a script
  # that segfaulted while its encoder child kept running would only be
  # caught here. A short window risks misjudging a still-growing file as
  # "stable" if it happens to land between two GOP writes; 8 tries at 2s
  # (16s total, up from the original 3 tries/8s) meaningfully narrows that
  # false-negative window without adding a new tool dependency (lsof/fuser
  # aren't used anywhere else in this script, and adding one just for this
  # would mean auditing/installing it fleet-wide for one narrow edge case).
  while [ "$waited" -lt 8 ]; do
    s1="$s2"
    sleep 2
    s2="$(file_size_bytes "$f")"
    [ "$s1" = "$s2" ] && return 0
    waited=$((waited + 1))
  done
  return 1
}

# Gate 0 — provenance / source-safety. Fail → do not delete.
orphan_gate0_provenance() {
  local source="$1" candidate="$2" script_pid="$3"
  local src_real cand_real base av1_base x265_base
  if [ ! -e "$source" ]; then
    return 1
  fi
  if [ -L "$candidate" ]; then
    return 1
  fi
  if [ ! -f "$candidate" ]; then
    return 1
  fi
  src_real="$(canonical_path "$source")"
  cand_real="$(canonical_path "$candidate")"
  if [ -z "$src_real" ] || [ -z "$cand_real" ] || [ "$src_real" = "$cand_real" ]; then
    return 1
  fi
  local remux_base=""
  base="$(basename "$candidate")"
  av1_base="$(basename "$(av1_output_path "$source")")"
  x265_base="$(basename "$(x265_output_path "$source")")"
  is_must_eliminate_format "$source" && remux_base="$(basename "$(must_eliminate_remux_path "$source")")"
  # Staged basename: <script_pid>.<Title.AV1.mkv|Title.x265.mkv|Title.mkv>
  if [ -n "$script_pid" ] && {
       [ "$base" = "${script_pid}.${av1_base}" ] || [ "$base" = "${script_pid}.${x265_base}" ] \
       || { [ -n "$remux_base" ] && [ "$base" = "${script_pid}.${remux_base}" ]; }
     }; then
    return 0
  fi
  # Canonical sibling output next to source
  if [ "$base" = "$av1_base" ] || [ "$base" = "$x265_base" ] \
     || { [ -n "$remux_base" ] && [ "$base" = "$remux_base" ]; }; then
    if derived_output_codec_claim_matches "$candidate"; then
      return 0
    fi
  fi
  return 1
}

orphan_canonical_dst_for_candidate() {
  local source="$1" candidate="$2"
  local base
  base="$(basename "$candidate")"
  if [[ "$base" =~ ^[0-9]+\.(.+)$ ]]; then
    base="${BASH_REMATCH[1]}"
  fi
  case "$base" in
    *.[Aa][Vv]1.[Mm][Kk][Vv]) printf '%s' "$(av1_output_path "$source")" ;;
    *.[Xx]265.[Mm][Kk][Vv]) printf '%s' "$(x265_output_path "$source")" ;;
    *.[Mm][Kk][Vv])
      is_must_eliminate_format "$source" || return 1
      printf '%s' "$(must_eliminate_remux_path "$source")" ;;
    *) return 1 ;;
  esac
}

orphan_video_duration() {
  local src="$1"
  local dur rc=0
  set +e
  dur="$(run_with_timeout "$ORPHAN_PROBE_TIMEOUT_SECS" \
    "${FFPROBE_CMD[@]}" -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$src" 2>/dev/null)"
  rc=$?
  set -e
  if [ "$rc" -eq 124 ]; then
    warn "Orphan validation: ffprobe duration timed out for $src"
    return 1
  fi
  if [ -n "$dur" ] && awk -v d="$dur" 'BEGIN { exit !(d+0 > 0) }'; then
    printf '%s' "$dur"
    return 0
  fi
  set +e
  dur="$(run_with_timeout "$ORPHAN_PROBE_TIMEOUT_SECS" \
    "${FFPROBE_CMD[@]}" -v error -select_streams v:0 -show_entries stream=duration \
    -of default=noprint_wrappers=1:nokey=1 "$src" 2>/dev/null)"
  rc=$?
  set -e
  if [ "$rc" -eq 124 ]; then
    warn "Orphan validation: ffprobe stream duration timed out for $src"
    return 1
  fi
  if [ -n "$dur" ] && awk -v d="$dur" 'BEGIN { exit !(d+0 > 0) }'; then
    printf '%s' "$dur"
    return 0
  fi
  return 1
}

# Gate 1 — tight duration: Δ ≤ max(2, min(5, source×0.001)) seconds
#
# Found in team E2E review (2026-07-31): for a disc source
# (ISO/BDMV), $source here is the disc's own path (a raw ISO file or a
# BDMV root directory) -- ffprobe can't derive a duration from either
# directly, so orphan_video_duration always failed and this gate always
# rejected a disc-derived candidate, deleting a possibly hours-of-work
# AV1/x265 output after a crash mid-job instead of salvaging or deferring
# it for review. There's no cheap way to recover which title was selected
# from just the in-progress flag's recorded source path (a full HandBrake
# re-scan would be needed, too expensive for the orphan reaper's per-pass
# cost budget) -- skip this gate outright for disc sources and rely on
# Gates 2/3 (structure + tail decode) as the safety net instead, same as
# every other candidate still has to pass.
orphan_gate1_duration() {
  local source="$1" candidate="$2"
  local d_src d_cand
  is_disk_source "$source" && return 0
  d_src="$(orphan_video_duration "$source")" || return 1
  d_cand="$(orphan_video_duration "$candidate")" || return 1
  awk -v s="$d_src" -v c="$d_cand" 'BEGIN {
    if (s <= 0 || c <= 0) exit 1
    d = s - c; if (d < 0) d = -d
    tol = s * 0.001
    if (tol > 5) tol = 5
    if (tol < 2) tol = 2
    exit !(d <= tol)
  }'
}

# Gate 2 — call validate_mkv_ebml_bounds directly (not validate_mkv_structure /
# mkvalidator). Known caveat: unknown-size Segment skips EOF-match, so this is
# a cheap early filter; duration + tail decode carry mid-encode kills.
# Phase D: EBML timeout lives inside validate_mkv_ebml_bounds (shared helper);
# no outer background+poll wrapper (that was a second mechanism).
orphan_gate2_structure() {
  local candidate="$1"
  local rc=0
  validate_mkv_ebml_bounds "$candidate" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 124 ]; then
    warn "Orphan validation: EBML bounds probe timed out for $candidate"
    return 1
  fi
  [ "$rc" -eq 0 ] || return 1
  # Optional cheap identify (run_mkvmerge already timeout-wrapped)
  if [ "${#MKVMERGE_CMD[@]}" -gt 0 ]; then
    rc=0
    run_mkvmerge --identify "$candidate" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 124 ]; then
      warn "Orphan validation: mkvmerge --identify timed out for $candidate"
      return 1
    fi
    [ "$rc" -eq 0 ] || return 1
  fi
  return 0
}

# Gate 3 — tail decode via -sseof -5 + stderr filter
orphan_gate3_tail_decode() {
  local candidate="$1"
  local errf rc=0
  errf="$(mktemp)" || return 1
  set +e
  run_with_timeout "$ORPHAN_TAIL_TIMEOUT_SECS" \
    "${FFMPEG_CMD[@]}" -v error -sseof -5 -i "$candidate" -map 0:v:0 -f null - \
    >/dev/null 2>"$errf"
  rc=$?
  set -e
  if [ "$rc" -eq 124 ]; then
    warn "Orphan validation: tail decode timed out for $candidate"
    rm -f "$errf"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$errf"
    return 1
  fi
  if ! validate_mkv_ffmpeg_stderr "$errf" "orphan tail decode of $candidate"; then
    rm -f "$errf"
    return 1
  fi
  rm -f "$errf"
  return 0
}

# Delete only a Gate-0-verified generated candidate. Never the source.
orphan_delete_generated_candidate() {
  local source="$1" candidate="$2" script_pid="$3" reason="$4"
  if ! orphan_gate0_provenance "$source" "$candidate" "$script_pid"; then
    warn "Orphan reaper: refusing to delete (failed provenance re-check): $candidate"
    return 1
  fi
  local src_real cand_real
  src_real="$(canonical_path "$source")"
  cand_real="$(canonical_path "$candidate")"
  if [ "$src_real" = "$cand_real" ]; then
    err "Orphan reaper BUG: candidate path equals source — aborting delete: $candidate"
    return 1
  fi
  if [ "$DRY_RUN" = true ]; then
    log "Orphan reaper [dry-run]: would delete generated candidate ($reason): $candidate"
    return 0
  fi
  rm -f -- "$candidate"
  log "Orphan reaper: deleted generated candidate ($reason): $candidate"
  return 0
}

# Full consensus validation sequence. Returns 0 if salvaged, 1 if deleted/failed.
# Salvage uses the normal finalize path (no separate code path).
orphan_validate_and_dispose_output() {
  local source="$1" candidate="$2" script_pid="$3"
  local final_dst title

  if ! orphan_gate0_provenance "$source" "$candidate" "$script_pid"; then
    warn "Orphan reaper: candidate failed Gate 0 provenance — leaving for human review: $candidate"
    return 1
  fi

  if ! orphan_size_stable "$candidate"; then
    log "Orphan reaper: candidate size not stable — not salvageable: $candidate"
    orphan_delete_generated_candidate "$source" "$candidate" "$script_pid" "size not stable"
    return 1
  fi

  if ! orphan_gate1_duration "$source" "$candidate"; then
    log "Orphan reaper: Gate 1 duration failed — deleting: $candidate"
    orphan_delete_generated_candidate "$source" "$candidate" "$script_pid" "duration mismatch"
    return 1
  fi

  if ! orphan_gate2_structure "$candidate"; then
    log "Orphan reaper: Gate 2 structure failed — deleting: $candidate"
    orphan_delete_generated_candidate "$source" "$candidate" "$script_pid" "structure/EBML"
    return 1
  fi

  if ! orphan_gate3_tail_decode "$candidate"; then
    log "Orphan reaper: Gate 3 tail decode failed — deleting: $candidate"
    orphan_delete_generated_candidate "$source" "$candidate" "$script_pid" "tail decode"
    return 1
  fi

  # Defense-in-depth: staged names like <pid>.Title.AV1.mkv still match the
  # *.AV1.mkv codec-claim patterns — reject promote if bitstream ≠ claim.
  if ! derived_output_codec_claim_matches "$candidate"; then
    log "Orphan reaper: candidate codec does not match claimed output type — deleting: $candidate"
    orphan_delete_generated_candidate "$source" "$candidate" "$script_pid" "codec claim mismatch"
    return 1
  fi

  # Full pass — promote via normal finalize path
  final_dst="$(orphan_canonical_dst_for_candidate "$source" "$candidate")" || {
    warn "Orphan reaper: could not resolve canonical destination for $candidate — leaving for human review"
    return 1
  }
  title="$(canonical_title_from_source "$source")"
  if [ "$DRY_RUN" = true ]; then
    log "Orphan reaper [dry-run]: would salvage $candidate → $final_dst"
    return 0
  fi
  if [ "$(canonical_path "$candidate")" != "$(canonical_path "$final_dst")" ]; then
    if ! finalize_staged_encode_output "$candidate" "$final_dst"; then
      warn "Orphan reaper: finalize_staged_encode_output failed for $candidate — attempting delete of staged copy only"
      orphan_delete_generated_candidate "$source" "$candidate" "$script_pid" "finalize failed" || true
      return 1
    fi
  fi
  finalize_mkv_output "$final_dst" "$source" "$title"
  log "Orphan reaper: salvaged complete orphan output via normal finalize: $final_dst"
  return 0
}

_orphan_collect_candidates_for_flag() {
  local source="$1" script_pid="$2" root="$3"
  local -n _out="$4"
  local av1_out x265_out av1_base x265_base f
  local remux_out="" remux_base=""
  _out=()
  av1_out="$(av1_output_path "$source")"
  x265_out="$(x265_output_path "$source")"
  av1_base="$(basename "$av1_out")"
  x265_base="$(basename "$x265_out")"
  if is_must_eliminate_format "$source"; then
    remux_out="$(must_eliminate_remux_path "$source")"
    remux_base="$(basename "$remux_out")"
  fi
  # Canonical siblings
  [ -f "$av1_out" ] && [ ! -L "$av1_out" ] && _out+=("$av1_out")
  [ -f "$x265_out" ] && [ ! -L "$x265_out" ] && _out+=("$x265_out")
  [ -n "$remux_out" ] && [ -f "$remux_out" ] && [ ! -L "$remux_out" ] && _out+=("$remux_out")
  # Staged files under root named <script_pid>.<basename>
  if [ -n "$script_pid" ]; then
    local -a name_preds=(-name "${script_pid}.${av1_base}" -o -name "${script_pid}.${x265_base}")
    [ -n "$remux_base" ] && name_preds+=(-o -name "${script_pid}.${remux_base}")
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -f "$f" ] || continue
      [ -L "$f" ] && continue
      _out+=("$f")
    done < <(find "$root" -type f \( "${name_preds[@]}" \) 2>/dev/null)
  fi
}

_orphan_clear_flag() {
  local flag="$1"
  local lockdir="${flag}.lock"
  if [ "$DRY_RUN" = true ]; then
    log "Orphan reaper [dry-run]: would clear flag $flag"
    return 0
  fi
  rmdir -- "$lockdir" 2>/dev/null || true
  # || true (E2E review, 2026-07-30): reached bare from reap_orphaned_encoders(),
  # which is itself called unprotected from main() -- a permission/NFS
  # failure removing one stale flag would otherwise abort the ENTIRE fleet
  # run instead of just leaving that one flag for the next pass.
  rm -f -- "$flag" 2>/dev/null || true
}

# Records which host created a staging/finalize/multipart directory, so the
# orphan reaper can recognize a directory owned by ANOTHER fleet machine
# instead of relying solely on local PID liveness. kill -0 only ever tests
# the local host's own PID namespace -- on an NFS-shared library, a remote
# host's live staging dir has no matching local PID at all, which makes it
# look "dead" here even though it's actively being written to right now.
# Team review (2026-07-24) found the staging-dir cleanup path lacked the
# same cross-host guard the IN_PROGRESS-flag path already had.
_orphan_write_stage_host_marker() {
  local dir="$1"
  # This marker is the ONLY thing that lets another fleet host's orphan
  # reaper tell "still-live encode on a different machine" apart from
  # "genuinely abandoned" -- without it, _orphan_stage_dir_owner_host()
  # returns nothing, the whole PID-correlation/live-check block is skipped,
  # and a live encode on another host can be rm -rf'd once
  # ORPHAN_STALE_DIR_AGE_SECS elapses. A silently swallowed write failure
  # here (NFS hiccup, ENOSPC) is exactly the condition under which orphan
  # reaping is most likely to run soon after, so surface it loudly instead
  # of `|| true`-ing it away. Team review, 2026-07-28.
  if ! { hostname 2>/dev/null || printf 'unknown\n'; } > "${dir}/.convert-stage-host" 2>/dev/null; then
    warn "Could not write cross-host staging marker for $dir — this dir will lack live-process protection from other hosts' orphan reapers until retried"
  fi
}

_orphan_stage_dir_owner_host() {
  local dir="$1"
  [ -f "${dir}/.convert-stage-host" ] || return 1
  head -n1 "${dir}/.convert-stage-host" 2>/dev/null
}

# Extract script PID prefixes from files inside a staging directory.
_orphan_script_pids_in_stage_dir() {
  local dir="$1"
  local f base
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="$(basename "$f")"
    if [[ "$base" =~ ^([0-9]+)\. ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
    fi
  done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null)
}

# List staged generated-output candidates: <script_pid>.<Title.AV1.mkv|Title.x265.mkv>,
# plus (v5.0.33G+) the bare <script_pid>.<Title.mkv> staged by the
# must-eliminate-format remux floor (must_eliminate_remux_path).
_orphan_staged_candidates_in_dir() {
  local dir="$1"
  local f base
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    [ -L "$f" ] && continue
    base="$(basename "$f")"
    if [[ "$base" =~ ^[0-9]+\..+\.[Aa][Vv]1\.[Mm][Kk][Vv]$ ]] || \
       [[ "$base" =~ ^[0-9]+\..+\.[Xx]265\.[Mm][Kk][Vv]$ ]] || \
       [[ "$base" =~ ^[0-9]+\..+\.[Mm][Kk][Vv]$ ]]; then
      printf '%s\n' "$f"
    fi
  done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null)
}

_orphan_source_from_flag_for_pid() {
  local root="$1" script_pid="$2" this_host="$3"
  local flag pid host source
  if [ -z "${_ORPHAN_FLAG_LIST_CACHE[$root]+set}" ]; then
    _ORPHAN_FLAG_LIST_CACHE[$root]="$(find "$root" -type f -name "*.${IN_PROGRESS_FLAG_SUFFIX}" 2>/dev/null)"
  fi
  while IFS= read -r flag; do
    [ -n "$flag" ] || continue
    [ -f "$flag" ] || continue
    pid="$(awk -F= '/^pid=/{print $2; exit}' "$flag" 2>/dev/null || true)"
    [ "$pid" = "$script_pid" ] || continue
    host="$(awk -F= '/^host=/{print $2; exit}' "$flag" 2>/dev/null || true)"
    if [ -n "$host" ] && [ "$host" != "$this_host" ]; then
      continue
    fi
    source="$(awk -F= '/^source=/{print substr($0,index($0,"=")+1); exit}' "$flag" 2>/dev/null || true)"
    if [ -n "$source" ] && [ -e "$source" ]; then
      printf '%s' "$source"
      return 0
    fi
  done <<<"${_ORPHAN_FLAG_LIST_CACHE[$root]}"
  return 1
}

# Reverse <pid>.Title.AV1.mkv / <pid>.Title.x265.mkv → Title.{mkv,mp4,...} under content_dir.
_orphan_source_from_staged_basename() {
  local content_dir="$1" base="$2"
  local rest title ext f bare_mkv_candidate=false
  [[ "$base" =~ ^[0-9]+\.(.+)$ ]] || return 1
  rest="${BASH_REMATCH[1]}"
  if [[ "$rest" =~ ^(.+)\.[Aa][Vv]1\.[Mm][Kk][Vv]$ ]]; then
    title="${BASH_REMATCH[1]}"
  elif [[ "$rest" =~ ^(.+)\.[Xx]265\.[Mm][Kk][Vv]$ ]]; then
    title="${BASH_REMATCH[1]}"
  elif [[ "$rest" =~ ^(.+)\.[Mm][Kk][Vv]$ ]]; then
    # Bare Title.mkv, no codec suffix: only the must_eliminate_remux_path
    # fallback (v5.0.33G) stages a candidate this way, so a source match
    # below is only trusted if it's genuinely a must-eliminate-format
    # source (avi/mpg/ts/etc, never already .mkv itself, so there's no
    # ambiguity with a real pre-existing .mkv source landing here).
    title="${BASH_REMATCH[1]}"
    bare_mkv_candidate=true
  else
    return 1
  fi
  for ext in mkv mp4 avi ts m2ts vob ogm mpg mpeg m2v rm rmvb divx wmv flv asf m4v; do
    f="${content_dir}/${title}.${ext}"
    [ -f "$f" ] || continue
    if [ "$bare_mkv_candidate" = true ] && [ "$ext" = "mkv" ]; then
      continue
    fi
    if [ "$bare_mkv_candidate" = true ] && ! is_must_eliminate_format "$f"; then
      continue
    fi
    if declare -F is_derived_output >/dev/null 2>&1; then
      is_derived_output "$f" && continue
    fi
    printf '%s' "$f"
    return 0
  done
  return 1
}

# Resolve source for a staged candidate: matching same-host flag, else naming reverse.
_orphan_resolve_source_for_staged() {
  local root="$1" candidate="$2" script_pid="$3" this_host="$4"
  local source content_dir
  source="$(_orphan_source_from_flag_for_pid "$root" "$script_pid" "$this_host" 2>/dev/null)" || source=""
  if [ -n "$source" ] && [ -e "$source" ]; then
    printf '%s' "$source"
    return 0
  fi
  # Stage dirs live under the media content dir (parent of .convert-stage-*).
  content_dir="$(dirname "$(dirname "$candidate")")"
  source="$(_orphan_source_from_staged_basename "$content_dir" "$(basename "$candidate")" 2>/dev/null)" || source=""
  if [ -n "$source" ] && [ -e "$source" ]; then
    printf '%s' "$source"
    return 0
  fi
  return 1
}

# Dispose staged candidates in a dead-owner stage dir via Gate 0→3.
# Returns: 0 = safe to rm -rf dir; 1 = leave (review); 2 = age-gate fallback (no source).
_orphan_dispose_stage_dir_candidates() {
  local root="$1" dir="$2" this_host="$3"
  local -n _salvaged_ref="$4"
  local -n _deleted_ref="$5"
  local cand base spid source unresolved=false left_review=false

  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    base="$(basename "$cand")"
    if [[ "$base" =~ ^([0-9]+)\. ]]; then
      spid="${BASH_REMATCH[1]}"
    else
      unresolved=true
      continue
    fi
    source="$(_orphan_resolve_source_for_staged "$root" "$cand" "$spid" "$this_host" 2>/dev/null)" || source=""
    if [ -z "$source" ] || [ ! -e "$source" ]; then
      warn "Orphan reaper: cannot resolve source for staged candidate — age-gating dir: $cand"
      unresolved=true
      continue
    fi
    if orphan_validate_and_dispose_output "$source" "$cand" "$spid"; then
      _salvaged_ref=$((_salvaged_ref + 1))
    else
      if [ ! -e "$cand" ]; then
        _deleted_ref=$((_deleted_ref + 1))
      else
        left_review=true
      fi
    fi
  done < <(_orphan_staged_candidates_in_dir "$dir")

  if [ "$left_review" = true ]; then
    return 1
  fi
  if [ "$unresolved" = true ]; then
    return 2
  fi
  # No candidates, or all salvaged/deleted — safe to remove remaining debris.
  return 0
}

reap_orphaned_encoders() {
  local root="$1"
  local this_host
  local -i flags_seen=0 orphans_killed=0 salvaged=0 deleted=0
  local -i legacy_review=0 skipped_live=0 skipped_cross_host=0 stale_both_dead=0
  local -i dirs_removed=0 dirs_left_live=0 dirs_age_kept=0 dirs_skipped_cross_host=0
  local flag pid host encoder_pid encoder_started encoder_fp source
  local -a candidates=()
  local cand age owner_host

  this_host="$(hostname 2>/dev/null || echo unknown)"
  log "Orphan reaper: scanning $root (host=$this_host)"

  while IFS= read -r flag; do
    [ -n "$flag" ] || continue
    [ -f "$flag" ] || continue
    flags_seen=$((flags_seen + 1))

    pid="$(awk -F= '/^pid=/{print $2; exit}' "$flag" 2>/dev/null || true)"
    host="$(awk -F= '/^host=/{print $2; exit}' "$flag" 2>/dev/null || true)"
    encoder_pid="$(awk -F= '/^encoder_pid=/{print $2; exit}' "$flag" 2>/dev/null || true)"
    encoder_started="$(awk -F= '/^encoder_started_utc=/{print $2; exit}' "$flag" 2>/dev/null || true)"
    encoder_fp="$(awk -F= '/^encoder_fingerprint=/{print $2; exit}' "$flag" 2>/dev/null || true)"
    source="$(awk -F= '/^source=/{print substr($0,index($0,"=")+1); exit}' "$flag" 2>/dev/null || true)"

    if [ -n "$host" ] && [ "$host" != "$this_host" ]; then
      skipped_cross_host=$((skipped_cross_host + 1))
      continue
    fi

    # Live script job on this host — never touch
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      skipped_live=$((skipped_live + 1))
      continue
    fi

    # Script PID dead (or missing). Legacy flags lack encoder_pid.
    if [ -z "$encoder_pid" ]; then
      warn "Orphan reaper: pre-patch orphan, encoder PID unknown — manual review needed: $flag"
      legacy_review=$((legacy_review + 1))
      continue
    fi

    if ! [[ "$encoder_pid" =~ ^[0-9]+$ ]]; then
      warn "Orphan reaper: invalid encoder_pid in $flag — manual review needed"
      legacy_review=$((legacy_review + 1))
      continue
    fi

    if kill -0 "$encoder_pid" 2>/dev/null; then
      # Genuine orphan: script dead, encoder still alive
      if ! encoder_identity_matches "$encoder_pid" "$encoder_started" "$encoder_fp"; then
        warn "Orphan reaper: encoder_pid=$encoder_pid alive but identity mismatch — leaving alone: $flag"
        continue
      fi
      if ! kill_orphaned_encoder_pid "$encoder_pid" "$encoder_started" "$encoder_fp"; then
        warn "Orphan reaper: failed to stop orphan encoder_pid=$encoder_pid — leaving flag: $flag"
        continue
      fi
      orphans_killed=$((orphans_killed + 1))
      log "Orphan reaper: reaped orphan encoder_pid=$encoder_pid for $flag"

      if [ -z "$source" ] || [ ! -e "$source" ]; then
        warn "Orphan reaper: source missing for reaped orphan — cannot validate outputs safely: $flag"
        _orphan_clear_flag "$flag"
        continue
      fi

      candidates=()
      _orphan_collect_candidates_for_flag "$source" "$pid" "$root" candidates
      if [ "${#candidates[@]}" -eq 0 ]; then
        log "Orphan reaper: no generated candidates found after reaping $flag"
        _orphan_clear_flag "$flag"
        continue
      fi
      for cand in "${candidates[@]}"; do
        if orphan_validate_and_dispose_output "$source" "$cand" "$pid"; then
          salvaged=$((salvaged + 1))
        else
          # dispose function logs; count delete only if file gone
          if [ ! -e "$cand" ]; then
            deleted=$((deleted + 1))
          fi
        fi
      done
      _orphan_clear_flag "$flag"
    else
      # Both dead — normal stale flag; no process work (leave for --clean-junk)
      stale_both_dead=$((stale_both_dead + 1))
    fi
  done < <(find "$root" -type f -name "*.${IN_PROGRESS_FLAG_SUFFIX}" 2>/dev/null)

  # Staging / finalize / multipart / hbprog directory cleanup under root.
  # PID in staged *filenames* is the script PID — never is_encoder_process() on it.
  # Dead-owner dirs with generated candidates go through Gate 0→3 salvage first;
  # only rm -rf after candidates are salvaged/deleted (or age-gate if no source).
  local dir spid any_live matched_dead stage_rc
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] || continue

    # Cross-host guard: an NFS-shared staging dir created by another fleet
    # machine must never be judged by local PID liveness -- kill -0 only
    # tests THIS host's PID namespace, so a live remote owner's script PID
    # always looks "dead" here even while it's actively encoding right now.
    # Mirrors the same host= check the IN_PROGRESS-flag loop above already
    # does.
    owner_host="$(_orphan_stage_dir_owner_host "$dir" 2>/dev/null)" || owner_host=""
    if [ -n "$owner_host" ] && [ "$owner_host" != "$this_host" ]; then
      dirs_skipped_cross_host=$((dirs_skipped_cross_host + 1))
      continue
    fi

    any_live=false
    matched_dead=false
    # A dir with NO marker at all (pre-fix leftover, or the write itself
    # failed) can never be confirmed as ours -- a marker-less dir that's
    # actually live on another host would still look locally "dead" via
    # kill -0, exactly the vulnerability this whole guard exists to close.
    # Team review (2026-07-24, second pass) found the original fix only
    # protected successfully-marked dirs. Skip the local-PID correlation
    # entirely for an unmarked dir and fall through to the age-gate-only
    # path below -- slower to clean up a genuinely dead local orphan that
    # happens to lack a marker, but never wrongly disposes a live remote
    # one. Every dir created going forward always gets a marker, so this
    # is a one-time transitional gap, not a permanent blind spot.
    if [ -n "$owner_host" ]; then
      while IFS= read -r spid; do
        [ -n "$spid" ] || continue
        if is_convert_script_process "$spid"; then
          any_live=true
          break
        fi
        if [[ "$spid" =~ ^[0-9]+$ ]] && ! kill -0 "$spid" 2>/dev/null; then
          matched_dead=true
        fi
      done < <(_orphan_script_pids_in_stage_dir "$dir" | sort -u)
    fi

    if [ "$any_live" = true ]; then
      dirs_left_live=$((dirs_left_live + 1))
      continue
    fi

    age="$(_orphan_dir_age_secs "$dir" 2>/dev/null)" || age=""

    if [ "$matched_dead" = true ]; then
      set +e
      _orphan_dispose_stage_dir_candidates "$root" "$dir" "$this_host" salvaged deleted
      stage_rc=$?
      set -e
      if [ "$stage_rc" -eq 1 ]; then
        # Candidate left for human review — do not rm -rf
        dirs_age_kept=$((dirs_age_kept + 1))
        continue
      fi
      if [ "$stage_rc" -eq 2 ]; then
        # No resolvable source — age-gate instead of immediate delete
        if [[ "$age" =~ ^[0-9]+$ ]] && [ "$age" -gt "$ORPHAN_STALE_DIR_AGE_SECS" ]; then
          if [ "$DRY_RUN" = true ]; then
            log "Orphan reaper [dry-run]: would remove age-gated staging dir (no source): $dir"
          else
            rm -rf -- "$dir"
            log "Orphan reaper: removed age-gated staging dir (no source): $dir"
          fi
          dirs_removed=$((dirs_removed + 1))
        else
          dirs_age_kept=$((dirs_age_kept + 1))
        fi
        continue
      fi
      # stage_rc==0: candidates salvaged/deleted or none — remove remaining debris
      if [ "$DRY_RUN" = true ]; then
        log "Orphan reaper [dry-run]: would remove stale staging dir: $dir"
      else
        rm -rf -- "$dir"
        log "Orphan reaper: removed stale staging dir: $dir"
      fi
      dirs_removed=$((dirs_removed + 1))
      continue
    fi

    # No live owner and no dead PID correlation — age-gate only.
    if [[ "$age" =~ ^[0-9]+$ ]] && [ "$age" -gt "$ORPHAN_STALE_DIR_AGE_SECS" ]; then
      if [ "$DRY_RUN" = true ]; then
        log "Orphan reaper [dry-run]: would remove stale staging dir: $dir"
      else
        rm -rf -- "$dir"
        log "Orphan reaper: removed stale staging dir: $dir"
      fi
      dirs_removed=$((dirs_removed + 1))
    else
      dirs_age_kept=$((dirs_age_kept + 1))
    fi
  done < <(find "$root" -type d \( \
    -name '.convert-stage-*' -o -name '.convert-finalize-*' \
    -o -name '.convert-multipart-*' \
  \) 2>/dev/null)

  log "Orphan reaper summary: flags_seen=$flags_seen orphans_killed=$orphans_killed salvaged=$salvaged deleted=$deleted legacy_review=$legacy_review skipped_live=$skipped_live skipped_cross_host=$skipped_cross_host stale_both_dead=$stale_both_dead dirs_removed=$dirs_removed dirs_left_live=$dirs_left_live dirs_age_kept=$dirs_age_kept dirs_skipped_cross_host=$dirs_skipped_cross_host"
  if [ "$flags_seen" -eq 0 ] && [ "$dirs_removed" -eq 0 ] && [ "$dirs_left_live" -eq 0 ] && [ "$dirs_age_kept" -eq 0 ] && [ "$dirs_skipped_cross_host" -eq 0 ]; then
    log "Orphan reaper: 0 stale flags, 0 stale dirs"
  fi

  _reap_orphaned_hbprog_dirs
}

# Recursively lists every descendant PID of $1, one per line (depth-first,
# via repeated `pgrep -P`). Local-host only -- pgrep can't see other hosts,
# which is fine since the caller only ever needs this for its own machine.
_all_descendants_of() {
  local root="$1"
  local -a queue=("$root") out=()
  local cur child
  while [ "${#queue[@]}" -gt 0 ]; do
    cur="${queue[0]}"
    queue=("${queue[@]:1}")
    while IFS= read -r child; do
      [[ "$child" =~ ^[0-9]+$ ]] || continue
      out+=("$child")
      queue+=("$child")
    done < <(pgrep -P "$cur" 2>/dev/null)
  done
  [ "${#out[@]}" -gt 0 ] && printf '%s\n' "${out[@]}"
  return 0
}

# Finds and reaps top-level convert-vX.sh/convert-current.sh SCRIPT
# processes that are alive but genuinely wedged -- the complement of
# reap_orphaned_encoders() above, which only ever handles the opposite
# case (script dead, encoder orphaned) and explicitly leaves any script
# PID that's still alive alone ("Live script job on this host — never
# touch"). That assumption -- alive script PID implies legitimate
# progress -- doesn't hold: found live 2026-08-24 on JJACKSON, three
# nested `convert-v5.1.2A.sh` processes sitting at 0.0% CPU for up to
# ~3 hours, referencing a script file that had already been deleted by a
# routine version-deploy days earlier. Left running, these confuse
# tracking/logs and never self-clear (see feedback request that prompted
# this function).
#
# Deliberately conservative (feedback_never_delete_live_lock,
# feedback_verify_before_delete): a script PID is only reaped when BOTH of
# the following hold, not either alone --
#   1. No live encoder-tool process (ffmpeg/HandBrakeCLI/mkvmerge, via the
#      existing is_encoder_process()) anywhere in its full descendant
#      tree. If one exists, it's genuinely working regardless of how long
#      that's taken -- a real 4K encode can legitimately run for hours.
#   2. It has been alive for at least STUCK_SCRIPT_GRACE_SECS (default
#      900s, matching the 6.x branch's chunk-splitter stale-reclaim
#      threshold -- "no legitimate non-encoding step should take longer
#      than this"). A script briefly between steps (ffprobe scan, staging
#      copy, VMAF setup) shows no encoder-tool descendant for well under
#      900s; only a genuinely wedged process fails both checks at once.
#
# Host-local only, like reap_orphaned_encoders() -- ps/pgrep can't see
# other machines' processes, so there's no cross-host race to guard
# against for the kill decision itself.
reap_stuck_script_processes() {
  local this_host self_pid self_chain walk ppid
  local -i candidates_seen=0 reaped=0 survived=0
  local pid args elapsed has_encoder_child descendant

  this_host="$(hostname 2>/dev/null || echo unknown)"
  self_pid=$$
  # Never touch our own process or any of its ancestors.
  self_chain=" $self_pid "
  walk="$self_pid"
  while :; do
    ppid="$(ps -o ppid= -p "$walk" 2>/dev/null | tr -d '[:space:]')"
    [[ "$ppid" =~ ^[0-9]+$ ]] || break
    [ "$ppid" -le 1 ] && break
    self_chain="$self_chain $ppid "
    walk="$ppid"
  done

  log "Stuck-script reaper: scanning (host=$this_host, grace=${STUCK_SCRIPT_GRACE_SECS:-900}s)"

  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    case "$self_chain" in *" $pid "*) continue ;; esac
    is_convert_script_process "$pid" || continue
    candidates_seen=$((candidates_seen + 1))

    elapsed="$(_process_elapsed_secs "$pid")" || continue
    [ "${elapsed:-0}" -ge "${STUCK_SCRIPT_GRACE_SECS:-900}" ] || continue

    has_encoder_child=false
    while IFS= read -r descendant; do
      if is_encoder_process "$descendant"; then
        has_encoder_child=true
        break
      fi
    done < <(_all_descendants_of "$pid")
    [ "$has_encoder_child" = true ] && continue

    args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    warn "Stuck-script reaper: PID $pid alive ${elapsed}s with no live encoder-tool descendant -- reaping: $args"
    kill -TERM "$pid" 2>/dev/null
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
      sleep "${STUCK_SCRIPT_KILL_GRACE_SECS:-8}"
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
    fi
    if kill -0 "$pid" 2>/dev/null; then
      warn "Stuck-script reaper: PID $pid survived SIGTERM+SIGKILL -- manual review needed"
      survived=$((survived + 1))
    else
      reaped=$((reaped + 1))
      log "Stuck-script reaper: reaped PID $pid (wedged ${elapsed}s, no active encoder)"
    fi
  done < <(pgrep -f 'convert-v[0-9]|convert-current\.sh' 2>/dev/null)

  log "Stuck-script reaper summary: candidates=$candidates_seen reaped=$reaped survived=$survived"
}

# HandBrake's progress-FIFO staging dirs (run_handbrake_with_progress,
# .convert-hbprog-*) live under the machine's OWN local ${TMPDIR:-/tmp}, not
# under the NAS-shared $root the reaper above walks -- a crashed/killed
# HandBrake run leaves one behind there, and nothing was ever cleaning those
# up (the reaper above searched for the name pattern under the wrong root
# entirely, a dead find clause that could never match). Purely local, so
# unlike the NAS-shared staging dirs there is no cross-host live-process risk
# to worry about here: only this same machine could ever be the owner.
# Age-gate only, matching the same fallback the NAS reaper uses when no
# stronger correlation is available.
_reap_orphaned_hbprog_dirs() {
  local base="${TMPDIR:-/tmp}" d age now removed=0
  now="$(date -u +%s)"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    age=$(( now - $(stat -c%Y "$d" 2>/dev/null || stat -f%m "$d" 2>/dev/null || echo "$now") ))
    [ "$age" -gt "$ORPHAN_STALE_DIR_AGE_SECS" ] || continue
    if [ "$DRY_RUN" = true ]; then
      log "Orphan reaper [dry-run]: would remove stale local hbprog dir: $d"
    else
      if rm -rf -- "$d" 2>/dev/null; then
        removed=$((removed + 1))
      else
        warn "Orphan reaper: could not remove stale local hbprog dir: $d"
      fi
    fi
  done < <(find "$base" -maxdepth 1 -type d -name '.convert-hbprog-*' 2>/dev/null)
  if [ "$removed" -gt 0 ]; then
    log "Orphan reaper: removed $removed stale local hbprog dir(s) from $base"
  fi
  return 0
}
