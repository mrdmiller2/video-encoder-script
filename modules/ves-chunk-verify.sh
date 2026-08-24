#!/usr/bin/env bash
# ves-chunk-verify.sh -- Phase 3 of the chunk-parallel initiative
# (2026-08-22): the verifier + concatenator half of the pipeline that
# ves-chunk-coordinator.sh's manifest/claim/encode machinery (Phase 2) was
# built to feed. Designed to run on Sting specifically (NAS-local, so
# concatenation is a local stream-copy rather than a network transfer;
# see feedback_sting_io_vs_cpu_task_routing and the real 4-machine VMAF
# bake-off in project_chunk_parallel_verifier_bakeoff_2026_08_22 that
# settled this), but nothing here is Sting-specific code -- any machine
# with ffmpeg/mkvmerge and NAS access could run it.
#
# Deliberately does the expensive whole-file VMAF comparison ONCE, on the
# final concatenated output against the true original source, rather than
# a separate windowed VMAF per chunk (which would need offset source-vs-
# output window math this project hasn't built or validated). This is
# exactly the check already empirically proven this session on Mad Heidi
# (10 chunks, clean concat, 98.17 mean VMAF via measure_final_vmaf) --
# reusing that exact function/threshold rather than inventing a new
# quality gate. Per-chunk "verified" status is a real structural/decode
# sanity check (catches a truncated or corrupt chunk before it ever
# reaches concatenation), not a quality judgment -- consistent with the
# project's "verify before delete, never trust exit codes alone" doctrine
# (feedback_verbose_encoder_diagnostics, feedback_verify_before_delete).

# Cheap structural check: does this chunk output decode cleanly start to
# finish with no ffmpeg errors? This is NOT a quality/VMAF judgment --
# see the module header for why whole-file VMAF is deferred to
# chunk_finalize_manifest instead of being duplicated per chunk.
#
# Retries once before condemning a chunk: found live, 2026-08-23, that a
# perfectly good chunk can get a transient decode error under real
# concurrent fleet load (Sting -- or whatever machine runs this -- shares
# its host with unrelated heavy work; a single bad pass is not proof of
# real corruption, only a corrupted/truncated FILE is). Two independent,
# freshly-produced encodes of the same chunk were each condemned once by
# a single-attempt check, then both independently confirmed to decode
# perfectly cleanly moments later once contention eased -- a false
# positive wastes a full re-encode (efficiency loss, not a safety issue,
# since needs-requeue never accepts unverified data -- see
# feedback_verify_before_delete), but is cheap to avoid: a short retry
# after a real failure costs one extra decode pass on the (rare)
# genuinely-bad chunk, and saves a full re-encode cycle on the (more
# common, it turns out) transiently-contended good chunk.
_chunk_output_decodes_clean() {
  local out="$1"
  local errout attempt
  [ -s "$out" ] || return 1
  for attempt in 1 2; do
    errout="$("${FFMPEG_CMD[@]}" -v error -i "$out" -f null - 2>&1)"
    [ -z "$errout" ] && return 0
    [ "$attempt" -eq 1 ] && sleep 20
  done
  return 1
}

# Scans one manifest for chunks sitting at status=encoded and structurally
# verifies each, transitioning to verified or needs-requeue. Never touches
# a chunk that's already verified/needs-requeue (idempotent, safe to call
# repeatedly on the same manifest across scan passes).
chunk_verify_pending() {
  local src="$1"
  local mdir f idx status_file st out

  mdir="$(chunk_manifest_dir "$src")"
  [ -f "$mdir/.complete" ] || return 1

  for f in "$mdir"/chunk-*.meta; do
    [ -e "$f" ] || continue
    idx="$(awk -F= '/^index=/{print $2; exit}' "$f")"
    status_file="$mdir/chunk-$(printf '%03d' "$idx").status"
    [ -f "$status_file" ] || continue
    st="$(awk -F= '/^status=/{print $2; exit}' "$status_file" 2>/dev/null)"
    [ "$st" = encoded ] || continue

    out="$mdir/chunk-$(printf '%03d' "$idx").output.mkv"
    if _chunk_output_decodes_clean "$out"; then
      chunk_mark_status "$src" "$idx" "verified" "output=$out"
      log "Chunk $idx verified (structural): $(basename -- "$src")"
    else
      # Deliberately NOT deleted here -- a bad chunk is left in place for
      # a human/future retry-logic pass to inspect (feedback_verify_before_delete).
      # A future re-claim attempt won't pick this index back up on its own
      # (status isn't "verified"/"encoded" so chunk_claim_next's skip-list
      # doesn't apply, but the lock for this index was already released by
      # chunk_encode_claimed's success path -- it IS reclaimable next scan
      # pass by design, giving a bad chunk one automatic retry).
      chunk_mark_status "$src" "$idx" "needs-requeue" "output=$out reason=decode-error"
      warn "Chunk $idx failed structural verification (will be retried): $(basename -- "$src")"
    fi
  done
}

# Once every chunk is status=verified: concatenate via mkvmerge, run the
# SAME whole-file VMAF gate (measure_final_vmaf) and threshold
# (vmaf_target_for_source) a normal whole-file encode is held to, then
# hand off to the canonical output path. Deliberately does NOT touch the
# original source or write the done-log itself -- the existing scan-time
# path (inspect_existing_outputs_for_queue -> validate_mkv_output ->
# done_log_append) already does that correctly for ANY valid file sitting
# at av1_output_path, chunk-parallel or not, so duplicating that logic
# here would only add a second, harder-to-keep-in-sync copy of safety-
# critical code. This function's only job is: produce a valid, tagged
# file at the canonical path, or don't -- change nothing else.
chunk_finalize_manifest() {
  local src="$1"
  local mdir out_final concat_tmp vmaf_score target f idx
  local -a parts=()

  mdir="$(chunk_manifest_dir "$src")"
  [ -f "$mdir/.complete" ] || return 1
  [ -f "$mdir/.finalized" ] && return 0
  chunk_all_verified "$src" || return 1

  out_final="$(av1_output_path "$src")"
  if [ -e "$out_final" ]; then
    log "Chunk-parallel: canonical output already exists, nothing to finalize: $out_final"
    : >"$mdir/.finalized" 2>/dev/null || true
    return 0
  fi

  for f in "$mdir"/chunk-*.meta; do
    [ -e "$f" ] || continue
    idx="$(awk -F= '/^index=/{print $2; exit}' "$f")"
    parts+=("$mdir/chunk-$(printf '%03d' "$idx").output.mkv")
  done
  [ "${#parts[@]}" -gt 0 ] || { warn "Chunk-parallel finalize: no chunk outputs found: $src"; return 1; }

  # Plain concatenation, in manifest index order (2026-08-23 -- see
  # project_chunk_parallel_phase4_2026_08_23 / reference_chunk_parallel_
  # pts_fix_consultation_2026_08_23 in project memory for the full
  # investigation this came from). No PTS/timestamp manipulation of any
  # kind is needed here. Splicing two independently-encoded chunks with
  # SVT-AV1's default hierarchical B-frame ("random access") prediction
  # structure directly against each other produces genuine packet
  # decode-order corruption on concatenation -- confirmed empirically,
  # and confirmed NOT fixable by relabeling timestamps (three different
  # strategies tried and falsified: global rank-based, global rank with
  # a pre-computed absolute offset, per-chunk local rank-based -- all
  # either baked in existing corruption or were simply insufficient,
  # per full untruncated decode verification). The actual fix lives
  # upstream in ves-chunk-coordinator.sh's chunk_split_create_manifest:
  # small independently-encoded SEAM segments are now inserted between
  # body chunks (covering [boundary-overlap, boundary+overlap], with body
  # chunks trimmed to stop/start short of the boundary instead of exactly
  # at it), so no two directly-hierarchical-B-GOP-encoded body chunks are
  # ever spliced against each other -- verified via a full, untimed,
  # un-truncated decode: zero DTS errors. This finalize step now trusts
  # that upstream design and simply concatenates whatever units the
  # manifest lists, in index order (bodies and seams interleaved by the
  # splitter already).
  concat_tmp="${mdir}/.concat.$$.mkv"
  local -a mm_args=(-o "$concat_tmp" "${parts[0]}")
  local p
  for p in "${parts[@]:1}"; do
    mm_args+=(+"$p")
  done
  local mm_out
  # Diagnostics MUST be captured, not swallowed -- found live, 2026-08-23:
  # an earlier version of this call redirected mkvmerge's output to
  # /dev/null, so the actual root cause (mismatched per-chunk audio
  # codecs; see chunk_encode_claimed's audio-codec-pinning fix) was
  # invisible from the log alone and had to be reproduced by hand.
  # feedback_verbose_encoder_diagnostics: never trust exit codes alone.
  if ! mm_out="$(run_mkvmerge "${mm_args[@]}" 2>&1)"; then
    warn "Chunk-parallel finalize: mkvmerge concat failed: $src -- $mm_out"
    rm -f -- "$concat_tmp" 2>/dev/null
    return 1
  fi

  if ! validate_mkv_output "$src" "$concat_tmp" "" true; then
    warn "Chunk-parallel finalize: concatenated output failed structural validation, leaving chunks in place for review: $src"
    rm -f -- "$concat_tmp" 2>/dev/null
    return 1
  fi

  # Safety net (2026-08-23): a strict decode check catches DTS/structural
  # corruption that validate_mkv_output and even a full whole-file VMAF
  # pass can both miss -- VMAF compares decoded pixel content and
  # ffmpeg's own decoder is lenient about muxer-level DTS errors, so a
  # structurally broken file can still score well on VMAF (confirmed
  # live: an earlier, since-superseded version of this fix produced a
  # DTS-corrupted file that scored 99.2). This is a single fast decode
  # pass (seconds) run before the expensive VMAF measurement, not after.
  if ! _chunk_output_decodes_clean "$concat_tmp"; then
    warn "Chunk-parallel finalize: concatenated output failed strict decode check (DTS/structural) -- leaving chunks in place for review, NOT proceeding to VMAF: $(basename -- "$src")"
    rm -f -- "$concat_tmp" 2>/dev/null
    return 1
  fi

  # measure_final_vmaf_sequential, NOT measure_final_vmaf -- the windowed
  # dual-`-ss` construction the latter uses was found (2026-08-24) to
  # manufacture false catastrophic scores specifically on multi-segment-
  # concatenated content like this finalize step's output. See
  # measure_final_vmaf_sequential's own header comment and
  # project_chunk_parallel_vmaf_false_positive_2026_08_24 memory for the
  # full investigation. Costs a full-file decode instead of a few short
  # windows -- accepted here since chunk-parallel finalize is not yet a
  # high-frequency path and correctness matters more than speed for this
  # specific gate.
  vmaf_score="$(measure_final_vmaf_sequential "$src" "$concat_tmp" 0)" || {
    warn "Chunk-parallel finalize: VMAF measurement failed, leaving chunks in place for review: $src"
    rm -f -- "$concat_tmp" 2>/dev/null
    return 1
  }
  target="$(vmaf_target_for_source "$src")"
  if ! awk -v v="$vmaf_score" -v t="${target:-0}" 'BEGIN{exit !(v+0 >= t+0)}'; then
    warn "Chunk-parallel finalize: VMAF $vmaf_score below target $target -- leaving chunks in place, NOT promoting to canonical output: $src"
    rm -f -- "$concat_tmp" 2>/dev/null
    return 1
  fi

  if ! mv -f -- "$concat_tmp" "$out_final"; then
    warn "Chunk-parallel finalize: failed to move concatenated output into place: $out_final"
    rm -f -- "$concat_tmp" 2>/dev/null
    return 1
  fi
  _restore_default_file_mode "$out_final"
  write_ves_processed_tag "$out_final" "$src" false

  log "Chunk-parallel finalize: $(basename -- "$src") assembled and validated (VMAF $vmaf_score >= $target) -> $out_final"
  : >"$mdir/.finalized" 2>/dev/null || true

  # Reclaim NAS space now that the canonical output is valid and in
  # place -- the manifest dir's status/meta files are kept (small, and a
  # useful audit trail) but the multi-GB chunk outputs are not needed
  # again once .finalized is set.
  for p in "${parts[@]}"; do
    rm -f -- "$p" 2>/dev/null
  done
  return 0
}

# One verifier-daemon pass: find every chunk manifest under the given
# root(s) (defaults to get_scan_roots, same roots the normal scan uses)
# that isn't finalized yet, verify newly-encoded chunks, and finalize any
# manifest that just became fully verified. Intended to be called in a
# sleep-loop by a dedicated verifier entry point (Sting) -- see the plan's
# Phase 3 section for the intended daemon wrapper; not yet built as of
# this writing (deliberately: needs its own live validation pass, Phase 4,
# before being left running unattended against production data).
chunk_verifier_scan_once() {
  local -a roots=()
  local root mdir src

  get_scan_roots roots
  for root in "${roots[@]}"; do
    while IFS= read -r mdir; do
      [ -n "$mdir" ] || continue
      [ -f "$mdir/.finalized" ] && continue
      [ -f "$mdir/manifest.meta" ] || continue
      src="$(awk -F= '/^source=/{sub(/^source=/,""); print; exit}' "$mdir/manifest.meta")"
      [ -n "$src" ] && [ -f "$src" ] || continue
      # Both calls guarded with `|| true`: under this codebase's `set -e`,
      # a bare failing call here (e.g. chunk_finalize_manifest returning
      # 1 on a bad/incomplete manifest -- found live, 2026-08-23, when a
      # manifest whose chunk parts had already been cleaned up by an
      # earlier successful finalize was retried and failed) would abort
      # the ENTIRE verifier process on the very next scan pass, not just
      # skip that one manifest -- a single bad title should never be able
      # to take down verification for every other title in flight.
      chunk_verify_pending "$src" || true
      if chunk_all_verified "$src"; then
        chunk_finalize_manifest "$src" || true
      fi
    done < <(find "$root" -type d -name '*.chunks' 2>/dev/null)
  done
}
