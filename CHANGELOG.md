# Changelog

Detailed record of every bug found and fixed during the v5.0.9 → v5.0.28 hardening
passes. The [README](README.md) version table has one line per release; this file
has the full story — what was wrong, why it mattered, and how it was fixed.

Reviews were run using this repo's own script plus three external independent
reviewers at high reasoning effort, each re-run after
every round of fixes. Every finding from every reviewer was independently verified
against the actual code before any fix was applied — several proposed findings
turned out to be non-issues on inspection, and are not listed here.

## Picture quality / correctness

- **Dolby Vision Profile 5 sources produced a visible green/red color tint.**
  Found via a real user report on a live encode of *Godzilla (2014)* (a genuine
  Profile 5 source: DoVi RPU present, no HDR10 base layer), and confirmed by
  extracting matching frames from the actual affected file before and after the
  fix — the buggy output is visibly green-tinted throughout, the fixed output
  shows correct natural greys and whites.

  Two compounding bugs, both in `ffmpeg_encode()`/`build_ffmpeg_video_args()`:

  1. The `hdr` flag that gates *all* Dolby Vision handling was only ever set from
     `source_is_hdr_transfer()`, which checks the container's `color_transfer`
     tag. A genuine Profile 5 source has no standard PQ/HLG tag at the container
     level by design — its tone curve lives entirely in the proprietary RPU, not
     in a container-level flag. `hdr` stayed `false`, so the entire
     DoVi-detection/libplacebo-conversion branch was silently skipped and the raw
     Dolby Vision base layer was encoded as-is, with no RPU-based color
     reconstruction. Fixed by also setting `hdr=true` whenever
     `source_has_dolby_vision()` is true, regardless of the container's
     `color_transfer` tag.

  2. Even when the DoVi branch *did* run (Profile 5 with `hdr=true`), the
     libplacebo filter string used `color_trc=pq` — not a valid option value in
     this ffmpeg build (confirmed via `ffmpeg -h filter=libplacebo`; the correct
     enum name is `smpte2084`). This means the Profile-5-to-HDR10 conversion path
     had never actually worked correctly since it was introduced — it just never
     got a chance to fail loudly, because bug (1) was skipping the branch
     entirely. Fixed the filter option value.

  *(v5.0.15)*

- **The v5.0.15 fix was necessary but not the complete permanent solution.**
  After shipping it, three independent reviewers were each independently
  asked (given the full current Dolby Vision/HDR code, with no cross-talk between
  them) whether it was the right permanent fix for *all* Dolby Vision use cases.
  All three converged on the same four remaining gaps:

  1. **HLG content was unconditionally tagged as PQ.** Every `hdr=true` path
     emitted `-color_trc smpte2084` / x265 `hdr10=1` regardless of whether the
     source was actually PQ or HLG (`arib-std-b67`) — including plain HLG
     content and DoVi profile 8.4 (HLG base layer). A player decoding real HLG
     data with a PQ transfer curve gets crushed shadows and blown highlights.

  2. **DoVi profile 8 was treated as a single case.** `dv_profile` reports `8`
     for profile 8.1 (HDR10/PQ base — safe as previously handled), 8.2 (SDR
     base), and 8.4 (HLG base) alike; it can't tell them apart. Profile
     8.2/8.4 sources were being forced into an HDR/PQ encode they were never
     mastered for.

  3. **The exact bug class could recur silently.** If Dolby Vision side-data is
     present but `source_dovi_profile()` can't parse a profile number (a
     muxing quirk, or an older ffprobe), the code fell through to blind PQ
     tagging with zero reconstruction — the identical failure shape that
     produced the original Profile 5 tint, just triggered a different way.

  4. **Hardware encode paths had no Dolby Vision handling at all.** Neither
     `--prefer-hw` (NVENC/QSV/VAAPI/VideoToolbox) nor the AMD-specific VAAPI
     HEVC path had any libplacebo-equivalent reconstruction step, or even any
     HDR color-tagging. A Profile 5 source encoded via `--prefer-hw` would hit
     the original tint bug today, on a supposedly-fixed script.

  All three agreed the disc/BDMV HandBrake path's existing "flag for human
  review" behavior for Profile 5 is fine as-is — Profile 5 is a
  streaming-only profile that essentially never appears on physical discs,
  and HandBrake has no equivalent reconstruction filter regardless.

  **Fix:** replaced the ad hoc `hdr`-flag-plus-profile-check logic with a
  single classifier, `determine_hdr_mode()`, used consistently everywhere an
  HDR-related encoding or tagging decision is made. It returns one of:
  - `pq` — plain HDR10, DoVi profile 7, or profile 8 with a PQ base layer.
  - `pq_reconstruct` — DoVi profile 5 (no compatible base layer; needs
    libplacebo RPU reconstruction; software-only).
  - `hlg` — plain HLG, or DoVi profile 8 with an HLG base layer.
  - `sdr` — no HDR handling needed (includes DoVi profile 8 with an SDR base
    layer, e.g. 8.2 — an HDR/PQ encode would wash it out).
  - `unknown` — Dolby Vision side-data present, but neither the profile
    number nor the base layer's own transfer tag give a confident answer.
    Never guessed; the caller flags the source for human review instead.

  Profile 8's sub-variant is resolved by falling back to the base layer's own
  `color_transfer` tag, since `dv_profile` alone can't distinguish 8.1/8.2/8.4.
  All PQ-specific encoder tagging (SVT-AV1 `mastering-display`/`content-light`,
  x265 `hdr10=1`/`master-display`/`max-cll`, and the ffmpeg output
  `-color_trc`) is now conditioned on the resolved mode instead of applied
  unconditionally to every `hdr=true` source. `--prefer-hw` and the AMD VAAPI
  path now check the same classifier before dispatching: `pq_reconstruct`/
  `unknown` sources gracefully fall back to software (which can actually do
  the reconstruction) instead of silently producing wrong colors, and `pq`/
  `hlg` sources now get correct output color tagging on the hardware path too
  (previously: none at all, on any hardware path, HDR or not).

  Verified with 13 classification test cases spanning every profile/
  transfer-tag combination the reviewers raised (profile 5, 7, 8 with each of
  PQ/HLG/SDR-implied base layers, unparseable profile with and without a
  usable transfer tag, plain HDR10/HLG/SDR with no Dolby Vision at all), then
  re-confirmed against the actual Godzilla (Profile 5 → `pq_reconstruct`) and
  Clueless (Profile 8.1-style → `pq`) files. Writing the test cases by hand
  caught a real inconsistency in the first draft of the classifier itself
  (an unparseable-profile source with a clear PQ transfer tag was being
  routed to `unknown` instead of trusting the tag) — fixed before shipping.

  *(v5.0.16)*

- **Final output and cache files were silently ending up mode `0600` instead
  of a normal, umask-derived mode, on NFS shares.** Reported directly by the
  user, who noticed a just-finished Clueless (1995) `.AV1.mkv` sitting at
  `-rw-------` next to everything else in its folder at `644`/`777`.

  Root cause: GNU `mktemp` intentionally creates its temp file at `0600`
  regardless of the process umask (it's the same "close the symlink-race
  window" rationale already used for the CIFS credentials temp file). Four
  places in the script use an atomic "write to a `mktemp`'d temp file, then
  `mv -f` it directly over the real path" pattern to avoid a predictable-name
  TOCTOU race — but none of them restored a normal mode afterward, so `mv`
  (which preserves the source file's mode) carried the `0600` straight
  through onto the file it replaced:
  - `optimize_mkv_for_streaming` — the **final `.mkv` output itself**, after
    its streaming-optimization remux pass. This is the one that actually hit
    the user's media library.
  - `mkv_structure_cache_invalidate` and `mkv_structure_cache_store` — the
    MKV-structure-check cache file.
  - `filecache_put` — the per-directory file-list cache.

  Fix: added `_restore_default_file_mode()` (`chmod` to `0666 & ~umask`,
  i.e. exactly what a normal `>`-created file would have gotten) and called
  it immediately after each of the four successful `mv -f` swaps. The
  `mktemp` usage itself — and the symlink-race protection it provides — is
  unchanged; only the final permission bits are restored.

  *(v5.0.17)*

## Performance

- **Encode output now writes to a RAM-backed staging path instead of the
  real (often NFS) destination during the encode itself.** Motivated by a
  direct observation while testing the Plex-server fleet node: a `hard` NFS
  mount (the correct choice for data-safety reasons) means a network hiccup
  mid-write can block the writing process indefinitely, putting a live,
  multi-minute CPU-bound encode at risk of stalling on something outside its
  own control. Reads already tolerate this fine (retry, and FS-Cache already
  caches repeat reads locally) — only the write side carried this risk.

  Design, in order of preference:
  1. **Discover** an already-mounted, sufficiently-sized RAM-backed
     directory (`/tmp`, `/dev/shm`, `/mnt/ramdisk`, or an explicit
     `CONVERT_RAMDISK_DIR` override) — true on every Linux/WSL fleet machine
     surveyed (docm workstation, PRINCE, MacFedora all already have a
     suitably-sized tmpfs at `/tmp`).
  2. **Create** one sized at `CONVERT_RAMDISK_PCT`% (default 40, adjustable)
     of *available* memory at the moment it's needed — deliberately not a
     percentage of total installed RAM, since the encoder process itself
     needs real headroom on top of it (observed ~6GB RSS for a real Dolby
     Vision `libplacebo` reconstruction encode; naively handing out 50% of
     total RAM to the ramdisk on a small box could starve the encoder
     itself). macOS has no built-in tmpfs, so creation there uses a genuine
     `hdiutil`/`diskutil` RAM disk instead, verified working end-to-end.
  3. **Fall back to direct-write** (the prior, unchanged behavior) if
     neither applies, or if a pre-flight size-fit check says the estimated
     output (source file size + 10% margin — output is almost always
     smaller, but not reliably enough to skip the margin) wouldn't
     comfortably fit in whatever candidate was found/created.

  Deliberately does **not** attempt a live mid-encode rescue if a ramdisk
  fills up unexpectedly (e.g. partially flushing and reassembling a
  still-growing MKV) — a single actively-written Matroska file can't be
  safely copied out from under ffmpeg without pausing writes, and the
  container's seek head/cues aren't necessarily finalized until muxing
  completes. A true segmented-and-reassembled approach exists (ffmpeg's
  `segment` muxer + a watcher + `mkvmerge --append`) but multiplies the
  failure surface considerably (segment ordering, timestamp/chapter/
  subtitle continuity across the join) for a case the pre-flight check
  already prevents in the first place. The `.IN_PROGRESS` semaphore and
  per-folder logs stay on the source path throughout, unaffected — so other
  fleet machines scanning the same library still see accurate in-progress
  state regardless of where the actual write is happening.

  Verified with 17 unit tests (tmpfs/RAM-disk detection per platform,
  discovery ordering, size-fit math including the explicit-override edge
  cases, staging-decision logic, and the finalize/move step including its
  failure paths) plus a real end-to-end encode through the actual modified
  script (not just the isolated helpers) confirming the full
  stage → encode → finalize-move sequence. Caught one real bug before
  shipping: the staging decision's own log messages were using `log()`
  (stdout) instead of `log_err()` (stderr) inside a function whose stdout is
  captured via command substitution by its caller — exactly the mistake the
  codebase's own `log_err` comment already warns against — which would have
  silently corrupted the returned staging path with log text prepended to
  it. Fixed before shipping.

  *(v5.0.18)*

- **v5.0.18's ramdisk staging had two real symlink/TOCTOU gaps against the
  hard source-safety invariant, found by an explicit three-way independent
  external re-audit requested specifically
  because "more changes were done" to a security-sensitive area.** All
  three reviewers were given the actual new code and asked, directly: does
  this satisfy "the original source is never touched," and is it safe to
  run in production. Two of the three independently converged on the same
  two blocking findings (the third reviewer's response was largely
  positive but did not surface these two — convergence across the other
  two, both citing the identical code paths, was treated as a strong
  signal these were real rather than a single reviewer's false positive):

  1. **Predictable staged path in a shared directory.** `resolve_encode_
     stage_path` built its per-file staged path as `$RAMDISK_JOB_DIR/
     .convert-stage.$$.basename` — a plain string directly inside
     `RAMDISK_JOB_DIR`, which in the common (discovered) case is a shared,
     world-writable system location like `/tmp`. Since the PID and output
     basename are both either predictable or directly observable (`ps`,
     directory listing), another local user or process could pre-create a
     symlink at that exact path pointing anywhere — including at an
     original source file — before the encode started. `ffmpeg -y ... "$dst"`
     opens its output path by name and follows symlinks, so it would
     write/truncate straight through to whatever the symlink pointed at.
  2. **TOCTOU in the finalize/move step.** `finalize_staged_encode_output`
     created a temp file with `mktemp "${final_dst}.stageXXXXXX"` (fine —
     unpredictable, atomically created), but then *reopened that same path
     by name* via `cp "$staged" "$tmp_on_dst"` to actually write the
     content into it. Between the `mktemp` call and the `cp` call, another
     writer with access to the destination directory could swap that name
     for a symlink; `cp` would follow it on the next write.

  Neither issue requires an untrusted local user on this specific fleet
  today to be worth fixing — the whole point of the hard invariant, already
  established over 5+ prior audit rounds of this codebase, is defending
  against exactly this class of scenario even when it currently seems
  unlikely, because "currently seems unlikely" is precisely how this
  project's very first security rounds described the bugs they later found
  and fixed.

  **Fix:** replaced every predictable-path construction with a private,
  `mktemp -d`-created, mode `0700` directory — one per job for staging
  during the encode itself (`RAMDISK_JOB_STAGE_DIR`, created once in
  `ramdisk_job_start` alongside the outer ramdisk resolution), and one
  freshly created per call inside `finalize_staged_encode_output` for the
  copy-into-place step. An unpredictable name plus owner-only permissions
  means there is nothing left for another local actor to usefully race
  against, even if they could guess the PID and filename exactly. This
  closes the vulnerability class rather than patching the specific
  reported instances of it.

  Also fixed, from the same review round (none individually blocking, but
  each a real gap):
  - `CONVERT_RAMDISK_DIR` is now validated as genuinely tmpfs-backed (the
    same `_is_tmpfs_dir` check every other candidate goes through) instead
    of being trusted merely for existing and having free space — a
    misconfigured override could otherwise have silently redirected
    staging onto a normal disk, or worse an NFS/CIFS path, widening the
    same symlink attack surface findings 1–2 already closed.
  - macOS's stale-ramdisk detection had a loose fallback (`mount | grep`
    for *any* mount at `/Volumes/ConvertRAMDisk`) that could misidentify
    and eject an unrelated volume a user happened to mount at that exact
    name. Removed; detection now relies solely on the existing positive
    Virtual-Interface check.
  - Linux's owned-resource detection used `findmnt --target`, which
    reports the filesystem *containing* a path, not whether that path is
    itself a mountpoint — since `/run` is already tmpfs on Fedora, a stale
    plain (never separately mounted) leftover directory could be
    misclassified as "mounted." Now requires an exact mountpoint match
    (`mountpoint -q` / `findmnt --mountpoint`) before treating it as ours.
  - `finalize_staged_encode_output`'s final `mv` wasn't checked for
    failure — a failed move (disk full, permission issue) would still run
    the cleanup steps and report success, silently discarding the only
    completed copy of a successful encode. Now explicitly checked, and on
    failure the staged copy is deliberately preserved for manual recovery
    instead of being deleted.
  - `ramdisk_job_start` now returns immediately during `--dry-run` (a
    reviewer-suggested optimization — dry-run never actually encodes, so
    creating/clearing a ramdisk for it was pure overhead).

  Verified with 20 unit tests, including direct regression tests that
  replicate the exact symlink pre-plant and TOCTOU scenarios both
  reviewers described (a pre-planted symlink at the *old* predictable
  path/pattern is confirmed to never be touched by the new code), plus
  real end-to-end encodes on both docm workstation (Linux, discovered
  `/tmp`) and Crystalight (macOS, created-and-torn-down RAM disk)
  confirming the fully hardened stage → encode → finalize path.

  *(v5.0.19)*

- **v5.0.19's fix only covered the software-ffmpeg encode path -- a full-
  script re-audit (three independent reviewers again, this time asked
  to review the entire ~8900-line file rather than just the ramdisk
  section) found the same class of symlink/TOCTOU gap in every OTHER
  encoder invocation, plus several independent findings in sidecar-file
  handling and `set -e` correctness.** All three reviewers were pointed at
  the file directly (an earlier attempt embedding the full script inline in
  the CLI argument hit the OS's ARG_MAX limit) and asked to find anything
  new beyond what v5.0.19 already fixed.

  **Critical -- direct encoder writes outside the software-ffmpeg path.**
  `ffmpeg_encode` was the only function routed through `resolve_encode_
  stage_path`/`finalize_staged_encode_output`. `ffmpeg_encode_hw` (hardware
  NVENC/QSV/VAAPI/AMF/VideoToolbox), `handbrake_encode`, `vaapi_hevc_encode`
  (AMD VCN), and `remux_copy_to_mkv` all still opened the final, predictable
  output path directly. The caller's `[ -L "$out" ]` check is a one-time
  snapshot taken *before* the bake-off/VMAF-search/encode itself runs --
  easily minutes -- leaving a real window for another writer with access to
  the destination directory to swap that path for a symlink before the
  encoder actually opens it. Fixed by extending the same private-staging
  model (a job's encode writes to an unpredictable, mode-0700 directory,
  then gets moved into place afterward) to all four of these paths.

  **Critical -- the multi-part merge had the identical gap.**
  `ensure_multipart_merge`'s one-time `_neutralize_symlink_sidecar_path`
  check on `$merged`/`$state`, followed later by `mkvmerge -o "$merged"`
  opening that same predictable path directly, had the same check-then-use
  race. Fixed by merging into a private `mktemp -d` sibling directory,
  validating the result there, then moving both the merged file and its
  cache-state sidecar into place.

  **High -- `optimize_mkv_for_streaming`'s "unpredictable name" wasn't
  actually enough.** Its `mktemp`-created temp file had an unguessable
  name, but lived in the same shared, often world-writable media directory
  as everything else -- an attacker doesn't have to *guess* the name if
  they can just watch the directory (e.g. via `inotify`) and react the
  instant the file appears, before `mkvmerge -o` reopens it by pathname a
  moment later. A mode-0700 private directory closes this regardless of
  whether the name itself is predictable, since only this UID can even
  list the directory's contents.

  **High -- several predictable sidecar files had the same one-time-check-
  then-repeatedly-reopen-by-path pattern**, most notably the
  `.convert-v4.IN_PROGRESS` semaphore (`cat >"$flag"` after an earlier
  `[ -L "$flag" ]` check, with real time between the two), plus
  `resume_persist_state`, `write_queue_snapshot`, and the pipeline's
  ready-item queue. Fixed with two different patterns depending on write
  frequency: infrequent whole-file writes (state, queue snapshot, the
  in-progress flag) now build their content in a private `mktemp`'d file
  and `mv` it into place -- `mv`/`rename()` replaces whatever sits at the
  destination, including a symlink, directly and atomically, without ever
  following it. Continuously-appended files (the master log, shard logs,
  and the done-log) now open a file descriptor *once*, at path-resolution
  time (right after the existing one-time symlink check), and write
  through that same fd for the rest of the run instead of reopening the
  path by name on every single log line -- a file descriptor refers to the
  underlying inode directly and is immune to the path later being replaced
  by something else, closing the window for the file's entire lifetime
  after that one initial (checked) open.

  **Medium -- `done_log_load` had a `set -e` correctness bug matching the
  exact class found (and, it turns out, only partially understood) in
  v5.0.18: not every bare `[ cond ] && action` is dangerous under `set -e`
  -- only when it is the *last statement* of a function that is itself
  invoked as a bare, non-if/while/&&/||-guarded statement all the way up
  the call chain, since the function's own return value then becomes that
  statement's truthiness.** `done_log_load`'s last line was exactly this
  shape (`[ "$n" -gt 0 ] && log ...`), called bare through `resume_prepare_
  convert` from `main()`. Whenever the done-log file existed but happened
  to have zero matching `done`/`skip` entries, the function's implicit
  "false" return silently aborted the entire script at startup, before any
  conversion work happened. A hand-written test replicating the exact
  shape (last-statement-in-function, called bare from a non-exempt
  context) confirmed the mechanism and the fix; a broader sweep for the
  identical shape elsewhere in the file found no other instances.

  **Medium -- unguarded pipeline command substitutions under `pipefail`.**
  A related but distinct `set -e` nuance both external reviewers
  independently flagged: `set -o pipefail` (part of the script's `set
  -euo pipefail`) means a *multi-stage pipe's* exit status reflects any
  stage's failure, not just the last one -- so `dev="$(df ... | awk
  ...)"`, `free_pages="$(vm_stat ... | awk ...)"`, `home="$(getent ... |
  cut ...)"`, `home="$(dscl ... | awk ...)"`, and the mount-audit's `mnt="$
  (df -P ... | tail ... | sed ...)"` could all abort the script if the
  *first* stage failed (e.g. `df`/`vm_stat`/`getent`/`dscl` erroring on a
  stale NFS handle or an unusual platform variant) even though the final
  stage (`awk`/`cut`/`sed`) would have succeeded on empty input. All five
  guarded with an explicit `|| var=""` fallback.

  **Medium -- `--clean-junk-apply` could delete a real (if oddly named)
  original.** The zero-byte-output cleanup matched purely on filename
  (`*.AV1.mkv`, `*.x265.mkv`, `*.merged.mkv`) and size, with no check that
  the candidate was actually something this script had created. A genuine
  original file that happened to be zero bytes (a bad download, a failed
  copy) and coincidentally named like our own output convention would be
  deleted -- the hard invariant doesn't get to assume unusual filenames
  never happen. Fixed: a zero-byte candidate is now only auto-deleted if a
  plausible real source file (matching title, non-derived extension) is
  found beside it; otherwise it's reported but left for manual review,
  matching the precedent this same function already set for `.merged.mkv`
  files with missing source parts.

  **Noted but not changed this round:** the existing `flag_bad_processed_
  output` mtime+codec-claim heuristic (deciding whether an existing file at
  a computed output path is safe to treat as "ours") already has an
  explicit code comment acknowledging that a genuine unrelated file could
  in rare cases still pass both checks; closing that gap fully would need
  a persistent provenance record of every file this script has created,
  which is a larger change than this round's scope. The distributed
  cross-host lock's 2-hour staleness window (a very long encode on another
  machine being incorrectly reclaimed) and Plex-host resource contention
  beyond CPU (memory/GPU/I-O, not addressed by the existing CPUQuota
  wrapper) are both operational risk-acceptance calls, not correctness
  bugs, and are left to the user's judgment rather than auto-fixed.

  Verified with 30 unit tests (the previous 20 plus 10 new, including a
  direct reproduction of the pre-fix symlink-race vulnerability against a
  live pre-planted symlink, confirming the source file is never touched)
  plus real end-to-end encodes with ramdisk staging both forced off
  (exercising the new local-private-directory fallback) and left at
  defaults.

  *(v5.0.20)*

## v5.0.21 — fourth-round external re-audit: stale-review discipline + new gaps

  A fourth round of the same three-way independent external re-audit, run after v5.0.20 shipped. This round's biggest lesson wasn't a
  new bug class — it was a process failure that had to be caught before trusting
  any of the three reports: **all three reviewers' "critical" findings were
  against a stale copy** of the script in the repo clone that hadn't yet been
  re-synced with the live working file's v5.0.20 fixes. Every one of those
  "critical" findings — the fail-open staging fallback, the master-log
  bypassing its own fd, the folder in-progress/done flags using check-then-
  truncate, and the pipeline queue files' unguarded `rm`-then-recreate — was
  already fixed. Confirmed by diffing the live working file directly rather
  than trusting the reviewers' line numbers or quoted code at face value.

  Genuinely new findings that survived that verification:

  - **`label_mkv_tracks()` reopened the final output path by name for
    `mkvpropedit` with no symlink check** (one reviewer). `mkvpropedit` edits its
    target in place by reopening the path given to it — if the file at `$mkv`
    had been swapped for a symlink in the window since
    `optimize_mkv_for_streaming`'s `mv` last put a real file there, this step
    would silently edit whatever the symlink pointed at (title, track names,
    languages) rather than our own output. Since that target could be a real
    source file elsewhere in the library, this was a genuine — if narrow —
    path to violating the hard invariant. Fixed with an `[ -L "$mkv" ]` guard
    immediately before the edit, matching the same defensive style already
    used in `maybe_chown_for_media_user`.

  - **`mkv_structure_cache_store()` and `build_shard_snapshot()` still had a
    TOCTOU window despite already using the mv-into-place pattern.** Both
    functions correctly rebuilt their sidecar file into a private `mktemp`
    file and `mv`'d it into place — but then reopened the *same predictable
    path a second time* for one final truncating write or append
    (`>>"$cache"` / `: >"$out_file"` respectively), leaving a window between
    the `mv` and that second reopen where a symlink raced into place would
    get followed. Fixed by folding every write (the filtered old entries and
    the new one) into the single private tempfile before one `mv` into place
    — no second reopen-by-path exists anymore.

  - **`source_dovi_profile()`'s bare, unguarded assignment could abort the
    whole script under `pipefail`** (one reviewer) — `run_ffprobe ... | grep -E
    '^[0-9]+$' | head -1` returns non-zero when `grep` finds no numeric
    `dv_profile`, which is exactly the shape of source (Dolby Vision side-data
    present, profile number unparseable) that the HDR classifier is supposed
    to route to its "unknown, never guess" fallback rather than crash on.
    Fixed by guarding both call sites with `|| dovi=""`; confirmed the empty
    value still falls through to the classifier's existing catch-all case
    correctly.

  - **The three lower-frequency bookkeeping logs (`corrupt_files.txt`,
    `bad_sources.txt`, `reconvert_files.txt`) were still only symlink-
    neutralized once at init, then reopened by path on every append** — this
    was previously accepted as lower-risk on the reasoning that "corrupting
    these only breaks our own logs, not the user's media." Revisiting that
    reasoning this round: it doesn't actually hold, since a symlink raced
    into place at one of these predictable names could redirect the appended
    text into *any* file the process can write, including a real source —
    the same fd-based hardening already applied to the master/done logs was
    extended to these three. The two scan-progress sidecars
    (`convert-scan.total`, `convert-scan.done`) got the equivalent
    private-tempfile/`mv` and `_safe_touch_empty_flag` treatment for the same
    reason — they're `rm -f`'d at pipeline init but were being recreated via
    a direct truncating `>`/`touch` later, the same gap already closed
    elsewhere for the pipeline queue files.

  - **Resource-leak hardening (not a source-safety bug, but worth closing):**
    a `SIGINT`/`SIGTERM` mid-encode had no way to clean up the per-file
    private local staging directory (the non-ramdisk fallback) — nothing else
    would ever remove it, so repeated interrupted runs could strand
    `.convert-stage-XXXXXX` directories on the destination filesystem
    indefinitely (another reviewer). Added a global tracking variable
    (`ACTIVE_LOCAL_STAGE_DIR`) set whenever that directory is created and
    referenced from the signal handler for a best-effort cleanup.

  **Self-caught bug worth recording:** the first draft of that last fix used a
  bare `[ cond ] && action` as the final statement of `_cleanup_staged_file_dir`
  — precisely the `set -e` landmine class this entire series of reviews has
  been hunting elsewhere in the script. The existing unit-test suite caught it
  immediately (a test run aborted mid-script instead of completing), and it
  was rewritten as an explicit `if`/`fi`, which unlike the bare `&&` form
  always returns exit status 0 when its condition is false. A repo-wide sweep
  afterward confirmed no other instance of the same pattern was introduced
  this round.

  **Noted but not changed:** the root `chown` TOCTOU in
  `maybe_chown_for_media_user` (check-then-chown, not atomic) was re-flagged
  by one reviewer but is the same already-documented, already-reasoned-through
  accepted risk as before — it only ever runs on our own just-created outputs,
  and `chown` doesn't modify file content, so the blast radius is an ownership
  change, not data loss or corruption. The WSL2 observation that RAM-disk
  staging combined with a native Windows HandBrake binary forces I/O through
  the 9P interop layer (another reviewer) is a real operational performance concern, not
  a correctness or safety bug — left as a note for anyone tuning that specific
  machine's config, not auto-fixed.

  Verified via `bash -n`, the existing 30-test suite (all still passing after
  each change), and a targeted regression test that caught the self-inflicted
  `set -e` bug above before it ever shipped.

  *(v5.0.21)*

## v5.0.22 — TV shows get their own encoder profile

  A fleet-wide smoke test (one small real source file per machine, all 5:
  docm, PRINCE, Crystalight, MacFedora, Plex) surfaced two follow-on items,
  neither a bug in the shipped v5.0.21 code but both worth fixing while the
  topic was fresh.

  **Profile detection is source-path-only, verified.** The test setup itself
  (copying files into a scratch dir with no `/Anime/` segment) initially
  produced a false alarm — every run used the generic movie profile even
  though the content was genuine anime. Traced through every call site of
  `uses_anime_profile`/`is_tv_episode`/`load_encoder_profile`/
  `bakeoff_profile_key`/`pick_av1_encoder`: all of it keys off `$src`, the
  real original source path, threaded consistently from the initial file
  scan through the encoder dispatch and bake-off logic. The ramdisk/local
  staging path (`resolve_encode_stage_path`) is a completely separate
  mechanism that only decides where output bytes get written during the
  encode — it was never involved in any classification decision. Once the
  test paths were corrected to include an `Anime` segment, all 5 machines
  correctly activated the anime profile (`ffmpeg encode (av1 crf=NN,
  anime)`), confirming the existing behavior was already correct.

  **TV shows previously shared the movie profile with no way to diverge.**
  Non-anime TV content (`/Television/`, `/TV/`, `/TV Shows/`, `/Series/`)
  fell through to the exact same encoder tuning as theatrical movies — there
  was no distinct profile to independently tune even if a reason arose
  later. Added a third named profile, `tv`, parallel to how `anime` already
  works:

  - `uses_tv_profile()` — path-based (like `uses_anime_profile`), not
    filename-episode-pattern based (`is_tv_episode` has false-positive
    shapes, e.g. a movie title ending "... 2", that are fine for cosmetic
    logging but too risky to drive actual encode-tuning decisions). Anime
    always takes precedence, since `is_tv_library_path` also matches
    `/Anime/` paths (anime libraries are laid out the same way).
  - New independently-configurable quality knobs: `SVT_AV1_CQ_TV`,
    `NVENC_AV1_CQ_TV`, `FIXED_CRF_SVT_TV`, `FIXED_CRF_X265_TV`, and
    `VMAF_TARGET_TV` (new `--vmaf-target-tv N` flag / `CONVERT_VMAF_TARGET_TV`
    env var, mirroring the existing `--vmaf-target-4k` pattern). All default
    to the exact same numeric values as the movie profile — there's no
    empirical basis yet to diverge, unlike anime's flat-color/line-art
    content, which has an established rationale for `tune=animation` and
    film-grain synthesis. The infrastructure now exists to tune TV
    independently later without touching movies.
  - `load_encoder_profile()`, `fixed_crf_for()`, `resolve_crf_for_encode()`,
    `vmaf_target_for_source()`, and `bakeoff_profile_key()` all updated to
    recognize the three-way movie/tv/anime split consistently.
  - `is_tv_library_path()` also now accepts a bare `TV` top-level folder name
    as a variant of `Television` (both were already accepted alongside `TV
    Shows`/`Series`/`Anime`).

  **Self-caught bug in this round's own first draft:** an early version used
  `[ "$anime" = true ] || uses_tv_profile "$src" && tv=true` to derive the tv
  flag inside `resolve_crf_for_encode()`. Bash's `&&`/`||` are left-
  associative with *equal* precedence, so this parses as `([ anime ] ||
  uses_tv_profile) && tv=true` — not the intended `anime || (tv_check &&
  set)` — meaning `tv` would have incorrectly been set to `true` whenever
  content was anime too. Caught before shipping and rewritten as an explicit
  `if`/`fi`.

  Verified with 18 new isolated unit tests (9 covering `uses_tv_profile`/
  `uses_anime_profile` path classification and mutual exclusivity across
  `Television`/`TV`/`TV Shows`/`Series`/`Anime`/plain-movie paths, 9 covering
  `fixed_crf_for`/`vmaf_target_for_source` constant selection), the existing
  30-test staging suite (unaffected, still passing), and a real end-to-end
  encode against a `/Television/`-path source confirming `ffmpeg encode (av1
  crf=NN, tv)` in the live log output.

  *(v5.0.22)*

## v5.0.23 — manual override for movie/tv/anime profile classification

  Reported immediately after v5.0.22 shipped: `/mnt/BabyBear/Media/Television/
  American` contains adult animation (e.g. shows like South Park, Rick and
  Morty) mixed in with live-action TV — content the path-based `tv`/`anime`
  detection added in v5.0.22 can't tell apart, since both sit under the same
  `/Television/American/` folder. Path-only classification has no way to
  know which specific titles are actually animated.

  Added `--profile movie|tv|anime`, which overrides auto-detection entirely
  for the whole run — point it directly at the specific animated show's
  folder with `--profile anime` (or the reverse: force `--profile tv`/`movie`
  on a folder that would otherwise misclassify). Invalid values are rejected
  immediately (`--profile must be movie, tv, or anime`) rather than silently
  falling through to auto-detection.

  Implementation: a new `FORCE_PROFILE` global, checked first thing inside
  both `uses_anime_profile()` and `uses_tv_profile()` — when set, it's the
  sole answer, path detection is skipped entirely; when unset (the default),
  behavior is byte-for-byte identical to v5.0.22.

  Verified with 10 new unit tests (all three override values against both
  Television and Anime paths, confirming the override always wins over the
  path, and that the unset/default case is unaffected) plus a real end-to-end
  encode: a source file placed in a synthetic `/Television/American/` folder,
  run with `--profile anime`, produced `ffmpeg encode (av1 crf=44, anime)` in
  the live log — confirming the override reaches all the way through to the
  actual encoder dispatch, not just the classification functions in
  isolation.

  *(v5.0.23)*

## v5.0.24 — sidecar/log files stuck at restrictive permissions

  Reported after the fleet-wide Rick and Morty test: files (encoded outputs
  and sidecars alike) were coming out with inconsistent, sometimes overly
  restrictive permissions across the fleet's shared NFS library, where
  different machines/user accounts write to the same files.

  Two separate root causes, both stemming from the same `mktemp`-then-`mv`
  atomic-write pattern used throughout the script (writes to a private temp
  file, then `mv -f`'s it over the real path to close TOCTOU/symlink-race
  windows established in earlier rounds):

  1. `_restore_default_file_mode()` — the helper that's supposed to undo
     `mktemp`'s forced `0600` after the swap — computed a *umask-derived*
     mode (`0666 & ~umask`), typically landing on `644`. On a fleet shared
     over NFS/CIFS across multiple machines and user accounts with no common
     identity mapping, `644` still locks a file to whichever UID happened to
     write it. Changed to unconditionally force `0666` (the most permissive
     mode meaningful for a non-executable file — matching this project's own
     CIFS mount policy of `file_mode=0777,dir_mode=0777` used elsewhere).

  2. Several `mktemp`+`mv` call sites never called
     `_restore_default_file_mode()` at all, so they silently stayed at
     `mktemp`'s forced `0600` (owner-only) indefinitely: the folder in-
     progress/done flags (`_safe_touch_empty_flag`), the per-title
     `.IN_PROGRESS` semaphore, `write_queue_snapshot`/`resume_persist_state`
     (the resume queue and state files), `build_shard_snapshot`'s output, the
     multi-part-merge cache state file, and the scan-progress total file.
     Added the missing restore call to every one. Also added an explicit
     `chmod 0666` right after each continuously-appended log file's `exec
     {FD}>>path` fd open (master/done/corrupt/bad-sources/reconvert/shard
     logs) — these are created via a plain redirect (not `mktemp`), so they
     were already respecting the umask rather than being stuck at `0600`,
     but still weren't guaranteed permissive across different machines'
     umask settings.

  Verified with a direct test confirming `_safe_touch_empty_flag` now
  produces a `666` file regardless of the process umask, plus the existing
  30-test staging suite (unaffected, still passing).

  *(v5.0.24)*

## v5.0.25 — anime SVT-AV1 tuning aligned with community best practice

  Triggered by the Rick and Morty comparison test above: the user provided
  community-sourced SVT-AV1 best practices for anime (10-bit, preset 4/5,
  CRF 24-28, `tune=0` for line-art sharpness, large keyframe interval).
  Checked each against the current anime profile:

  - Pixel format (`yuv420p10le`), preset (5), and keyframe interval
    (`keyint=15s` + scene-cut detection, already more efficient than the
    suggested 10s) were already aligned — no change needed.
  - Confirmed this fleet runs mainline SVT-AV1 (bundled with ffmpeg), not
    the SVT-AV1-PSY fork — `tune=3` (PSY-specific) isn't a valid option
    here; only mainline's `tune=0`/`tune=1` apply.
  - `tune=0` was **not** currently set (anime used SVT-AV1's un-tuned
    default). This needed care: `tune=0` was already tried fleet-wide in
    v5.0.0 and reverted in v5.0.4 after real Plex A/B playback testing found
    it noticeably softer than the default — but that finding was against
    **live-action TV content**, never re-validated against anime's flat-
    color/line-art visual character, which the community consensus
    specifically favors `tune=0` for. Added `tune=0` scoped *only* to the
    anime SVT-AV1 params (both the primary `build_ffmpeg_video_args()` path
    and `load_encoder_profile()`'s HandBrake-dispatch path) — movie and tv
    profiles are untouched, keeping the already-validated live-action
    behavior exactly as-is.
  - Tightened the fixed-CRF fallback constants (`SVT_AV1_CQ_ANIME`,
    `FIXED_CRF_SVT_ANIME`) from 35/32 down to 26, inside the recommended
    24-28 range. These only affect the HDR/no-libvmaf/`--no-vmaf` fallback
    path — the primary VMAF-targeted search picks its own CRF regardless
    and was left alone, since it was already producing good results on
    genuine hand-drawn anime sources in earlier fleet testing (only Western
    CG-style content like Rick and Morty showed the poor-compression
    behavior that motivated the `--profile` override in v5.0.23).

  Verified via `bash -n` and the existing 30-test staging suite (unaffected,
  still passing). Not yet validated with a real playback A/B test against
  genuine anime content — recommended before treating `tune=0` as settled
  for the anime profile the way the movie/tv default already is.

  *(v5.0.25)*

## v5.0.26 — anime film-grain aligned with SVT-AV1's own documented range

  A deeper research pass (fetching SVT-AV1's own `Parameters.md` from its
  GitLab repo, rather than relying on secondary summaries) turned up a real
  mismatch: the anime profile's `film-grain=12` was well above SVT-AV1's own
  documented guidance of **4-6 for 2D animation**. Lowered to `6` in both
  code paths (the primary `build_ffmpeg_video_args()` softare path and
  `load_encoder_profile()`'s HandBrake-dispatch path).

  Also confirmed against the authoritative parameter reference (not a blog
  summary): mainline SVT-AV1's `tune` only has meaningful values 0 (VQ) and
  1 (PSNR) for our purposes (higher values are SSIM/IQ/MS-SSIM/VMAF tuning
  modes, mostly still-image-oriented or requiring specific downstream
  pipelines we don't use) — confirms the v5.0.25 finding that `tune=3`
  (PSY-fork-specific) was never applicable here. `enable-variance-boost`,
  `enable-overlays`, `scd`, and `enable-tf=0` were all already correctly
  configured against the reference docs; `aq-mode=2` was found to be
  redundant (already SVT-AV1's own default) but harmless, left as explicit
  documentation of intent rather than removed.

  One caveat surfaced by a secondary (non-SVT-AV1) source, noted in a code
  comment rather than acted on: `tune=0`'s psycho-visual optimizer can
  reportedly ring around strong edges in flat-color animation — exactly the
  line-art scenario this tuning targets. Deliberately not hedged against
  here (e.g. by reverting to `tune=1`) without evidence specific to this
  script's own anime content; needs a real playback A/B test to judge
  rather than a defensive guess.

  Verified via `bash -n` and the existing 30-test staging suite (unaffected,
  still passing).

  *(v5.0.26)*

## v5.0.27 — anime sharpness, and correcting misinformation about tune values

  The user surfaced a second piece of online guidance recommending `tune=2`
  as an "animation" mode with a claimed "-tune animation" ffmpeg flag, and
  citing `tune=3` for animation more generally. Checked both claims against
  the same authoritative source used in v5.0.26 (SVT-AV1's own
  `Parameters.md`) rather than accepting them:

  - **`tune=2` is SSIM-metric tuning, not an animation mode.** The
    documented enum is `0=VQ, 1=PSNR, 2=SSIM, 3=IQ (still-image only),
    4=MS-SSIM, 5=VMAF` — nothing in the official reference describes any
    value as "retaining flat geometries and high contrast." That claim
    doesn't match the parameter's actual documented behavior.
  - **`tune=3`/"animation" is real, but only in the SVT-AV1-PSY fork** —
    already confirmed this fleet runs mainline SVT-AV1 (v5.0.25/26), where
    `tune=3` means still-image IQ tuning, not animation.
  - ffmpeg's `libsvtav1` wrapper has no top-level `-tune` flag at all (no
    `"-tune animation"` string option exists for this codec the way it does
    for libx264/libx265) — tune only goes through `-svtav1-params tune=N`,
    numeric only.

  **What *is* real and newly added:** `sharpness` (range -7 to 7, default
  0, "bias towards decreased/increased sharpness" per the same authoritative
  doc) — a genuine, previously-unused SVT-AV1 parameter that targets
  line-art crispness more surgically than `tune=0`'s broader perceptual
  optimization, without `tune=0`'s documented ringing-artifact caveat. Added
  `sharpness=2` alongside (not instead of) `tune=0` in both anime SVT-AV1
  param strings.

  Also researched, at the user's request, whether to support the SVT-AV1-PSY
  fork fleet-wide: confirmed VMAF-targeted search has zero compatibility
  risk either way (`libvmaf` scores whatever file it's given regardless of
  which SVT-AV1 variant produced it, and `ab-av1`/the internal search both
  just shell out to system `ffmpeg`) — but PSY has no distro package for 4
  of the fleet's 5 machines (only macOS/Homebrew has one), meaning a
  from-source ffmpeg build-and-maintain burden on Fedora/Ubuntu/WSL2 hosts
  with no confirmed quality win over mainline + the tuning already applied
  here. Not pursued for now; revisit after real playback validates (or
  doesn't) the current mainline tuning.

  Verified via `bash -n` and the existing 30-test staging suite (unaffected,
  still passing).

  *(v5.0.27)*

## v5.0.28 — split anime into anime (Japanese) + wanime (Western animation)

  The Rick and Morty three-way comparison test (movie/tv vs. two rounds of
  anime tuning) produced a consistent, striking result across all three
  completed episodes: the anime profile's tuning (built around Japanese
  hand-drawn line-art characteristics) made this content measurably *worse*
  than even doing nothing special to it — one episode came out **larger
  than its own source** (116.4% for E03) under the updated anime tuning,
  versus 78.0% under the plain tv profile for the same episode. Research
  independently confirmed the root cause, naming this exact content:
  "for shows like South Park and Rick and Morty, film grain should be
  disabled... for animation, CGI... where synthesized grain would look
  unnatural." Western flat/vector-style digital ink-and-paint animation is
  visually a distinct content class from Japanese hand-drawn anime, and the
  single "anime" profile was applying line-art-oriented tuning
  (film-grain synthesis, variance-boost) to both indiscriminately.

  Added a fourth profile, `wanime`, alongside movie/tv/anime:

  - **`anime` keeps its existing name and behavior unchanged** (Japanese-
    style, auto-detected via `/Anime/` library paths) — no renaming churn,
    already validated this session.
  - **`wanime` has no path-based auto-detection at all** — Western
    animation lives mixed inside ordinary `/Television/` folders with no
    reliable folder-naming convention to key off, the same reasoning that
    motivated `--profile` in the first place. `--profile wanime` is the
    only way to select it, ever; `uses_wanime_profile()` is a pure
    `FORCE_PROFILE` check, no path logic.
  - **wanime's tuning is deliberately close to movie/tv's plain settings**
    (film-grain implicitly off, since it's never set — matching the
    documented film-grain=0 guidance for this content) plus `sharpness=2`
    (not `tune=0`): flat vector art has the sharpest, highest-contrast
    edges of any content type here, exactly where `tune=0`'s documented
    ringing-artifact risk is most acute, so the more surgical `sharpness`
    knob was chosen instead for the crispness goal.
  - New independently-tunable constants (`SVT_AV1_CQ_WANIME`,
    `NVENC_AV1_CQ_WANIME`, `FIXED_CRF_SVT_WANIME`, `FIXED_CRF_X265_WANIME`,
    `VMAF_TARGET_WANIME`) and `wanime` added to `--profile`'s valid values,
    `bakeoff_profile_key()`'s cache classes, `fixed_crf_for()`'s and
    `resolve_crf_for_encode()`'s signatures, `build_ffmpeg_video_args()`'s
    svtp branch, `load_encoder_profile()`'s HandBrake-dispatch branch, and
    `process_video()`'s logging.

  Verified with 11 new isolated unit tests (wanime never auto-detects;
  `--profile wanime` overrides anime/tv/movie regardless of path, including
  on genuine `/Anime/` paths; `--profile movie|tv|anime` never trigger
  wanime), the existing 30-test staging suite (unaffected), and a real
  end-to-end dry-run + encode confirming `Processing (wanime movie)` and
  the correct `sharpness=2`-only (no film-grain/variance-boost/tune=0)
  SVT-AV1 param string in the live ffmpeg command.

  *(v5.0.28)*

## v5.0.29 — fixed the real cause of anime bloat, added a fifth profile (vintage)

  Before starting a new test round, researched optimal ffmpeg/SVT-AV1/x265
  settings across all content profiles (primary sources: SVT-AV1's own
  `Parameters.md`, x265's own docs, VMAF industry literature, plus
  independent second opinions from two other reviewers). That research
  led to finding the actual root cause of v5.0.28's Rick and Morty bloat —
  not a tuning problem, a search/encode consistency bug:

  - **The bug:** `vmaf_crf_search_abav1()` and the internal
    `_vmaf_score_one()` search both encoded probe samples with only the
    *base* svtav1-params (`enable-qm=1:qm-min=0`), never the profile's extra
    params (film-grain, variance-boost, tune, sharpness). The final encode
    then applied those extras at the *same* CRF the search chose. Since
    film-grain synthesis and variance-boost both spend real bits, the final
    file grew past what the search predicted at that CRF — exactly the shape
    of E03's 116.4%-of-source result.
  - **The fix:** extracted one `svtav1_profile_extras()` function (anime /
    wanime / vintage extras) shared by both `build_ffmpeg_video_args()`
    (final encode) and the search path, so the CRF chosen is always
    calibrated against what the final encode will actually spend.
  - **A second, independent problem for grain-using profiles:** synthesized
    AV1 film grain is applied pseudo-randomly at decode time and doesn't
    align pixel-for-pixel with the source, which corrupts VMAF scoring
    during the search (confirmed against an ab-av1 GitHub issue, #139, that
    remains open/unfixed as of the installed 0.11.4 — ab-av1 has no way to
    disable synthesized-grain decode during its own internal VMAF scoring).
    Fix: any AV1 profile using real film-grain synthesis (anime, and the new
    vintage profile) now always uses the internal search
    (`vmaf_crf_search_internal`), which decodes probe encodes with
    `-export_side_data film_grain` before scoring so libvmaf sees the true
    encoded quality rather than synthesized-grain noise. Non-grain profiles
    (movie/tv/wanime) still prefer ab-av1 when installed, now with their
    extras passed through via repeated `--svt key=value` flags so that
    search stays consistent with the final encode too.

  **New fifth profile: `vintage`**, for old/grainy live-action masters (film
  scans, older TV masters with real photochemical grain) — manual-only via
  `--profile vintage`, never auto-detected, same reasoning as wanime
  (no reliable folder-naming convention for "old and grainy"). Unlike
  movie/tv/wanime, film-grain synthesis is deliberately re-enabled: research
  and community/streaming-industry guidance is that grain synthesis on
  genuinely grainy sources can save on the order of 50% bitrate versus
  literally re-encoding real grain as detail, since the encoder denoises to
  a clean base layer and the decoder regenerates matching-looking grain.
  SVT-AV1 params: `film-grain-denoise=1:film-grain=12:enable-tf=1:
  enable-variance-boost=1:variance-boost-strength=2:variance-octile=4:
  tune=0:sharpness=1` — lighter `sharpness`/`variance-boost-strength` than
  anime's, and `enable-tf=1` (not anime's `0`) since live-action doesn't have
  hand-drawn-frame smearing risk from temporal filtering. x265 fallback uses
  `tune=grain`, a real x265 tune value (confirmed against x265's own docs)
  distinct from anime's `tune=animation`. New independently-tunable
  constants throughout (`SVT_AV1_CQ_VINTAGE`, `NVENC_AV1_CQ_VINTAGE`,
  `FIXED_CRF_SVT/X265_VINTAGE`, `VMAF_TARGET_VINTAGE`) and `vintage` wired
  into every profile-aware function (`--profile`, `uses_vintage_profile()`,
  `bakeoff_profile_key()`, `vmaf_target_for_source()`, `fixed_crf_for()`,
  `load_encoder_profile()`, `build_ffmpeg_video_args()`, `ffmpeg_encode()`,
  `process_video()`).

  Design and specific parameter values were cross-checked via
  independent second opinions before implementation. One
  factual claim surfaced in that research — that SVT-AV1's `tune=2` is
  "VMAF tuning" — was caught and rejected against SVT-AV1's own
  `Parameters.md` (the documented enum is `0=VQ, 1=PSNR, 2=SSIM, 3=IQ,
  4=MS-SSIM, 5=VMAF`; `tune=2` is SSIM, `tune=5` is VMAF), consistent with
  this project's standing practice of verifying secondary claims against
  primary sources before acting on them.

  Verified with 24 new isolated unit tests (`uses_vintage_profile()`
  manual-only behavior; `svtav1_profile_extras()` exact strings per profile;
  `svtav1_profile_uses_grain_synthesis()` correctness; `vmaf_target_for_source()`
  and `fixed_crf_for()`'s new 6-argument signature), the existing 30-test
  and 11-test staging suites (unaffected, still passing), and `bash -n`.

  *(v5.0.29)*

## Source-file safety

The hard invariant throughout this project: **an original source video file must
never be deleted, truncated, overwritten, or corrupted, under any code path,
including errors, interrupts, and symlink attacks on a shared NFS/CIFS library.**
Every finding in this section was a real, demonstrable way that invariant could
have been violated.

- **In-place "repair" replaced the original.** `attempt_source_mkv_structure_remux()`
  remuxed a structurally-broken source MKV and then `mv -f`'d the repaired copy
  directly onto the original path. Rewrote so the repair happens entirely inside an
  isolated `mktemp -d`, outside the library tree — the repair now only proves the
  source's content is sound; the real encode always runs against the untouched
  original. If ffmpeg itself can't read the original, the existing
  AV1-then-x265-then-fail-safely fallback chain already handles that without
  touching the source. *(v5.0.12)*

- **`finalize_mkv_output` mutated genuine originals.** `process_existing_av1()`
  called `finalize_mkv_output` (remux + `mkvpropedit`, both in-place) on any source
  whose video codec was already AV1 — including a user's own original AV1 file that
  this script had never touched before, not just its own prior outputs. Gated on
  `is_derived_output()` so a real original is left completely alone. *(v5.0.12)*

- **Deleting a "bad output" trusted the filename alone.** `flag_bad_processed_output()`
  deleted any file matching the `*.AV1.mkv`/`*.x265.mkv` naming convention that
  failed validation against a source — but a real, unrelated file that happens to
  share that naming convention (e.g. a user's own native-AV1 rip sitting beside an
  unconverted copy of the same title) would look identical to a broken output.
  Added two independent provenance checks before any such delete: the candidate's
  mtime can't predate its supposed source (an encode we made can only exist after
  its source did), and its actual video codec must match what the filename claims
  — **a file named `*.AV1.mkv` must actually contain AV1 video, `*.x265.mkv` must
  actually be HEVC.** Either mismatch now flags the file for human review instead
  of deleting it. *(v5.0.12, extended in v5.0.14)*

- **Output path could collide with the source path.** A file named like this
  script's own output convention (e.g. `Movie.AV1.mkv`) but whose actual codec
  ISN'T AV1 gets rerouted into the "fresh source" encode path — where
  `av1_output_path()` computes an output name identical to the input. `ffmpeg -y`
  would then open that path for writing and truncate it before it could even
  finish reading it as input, destroying the source irrecoverably. Added a hard,
  unconditional refusal in `try_av1_convert`/`try_x265_convert` (and later
  `process_existing_av1`'s remux branch) if the computed output path canonically
  equals the source path. *(v5.0.12, extended v5.0.14)*

- **Output path could be a symlink to an unrelated file.** The collision guard
  above only caught a symlink pointing back at the *same* source. A computed
  output path that's a symlink to a **different**, unrelated real file wasn't
  caught — `ffmpeg -y`/HandBrake's `-o` would follow it and truncate/corrupt
  whatever it points to. Every encode entry point now refuses outright if the
  output path is a symlink at all; a legitimate output from this script is always
  a plain regular file it creates itself. *(v5.0.13, extended v5.0.14)*

- **Predictable sidecar paths could be symlink-attacked.** The per-title
  in-progress flag, resume state/queue/shards files, the master log, per-folder
  done/in-progress flags, the per-shard scan log, the shard-snapshot `.prev` diff
  file, and the multipart-merge cache/output files all live at fixed, guessable
  names — often directly inside the writable media root on a shared NFS/CIFS
  library. A symlink planted at any of these (by another fleet machine, another
  user, or by accident) would have every subsequent write from this script go
  straight through to whatever it points at, e.g. a real source video. Added a
  shared `_neutralize_symlink_sidecar_path()` guard and applied it to every one of
  these paths — removing a stray symlink at one of these exact names is always
  safe, since `rm` on a symlink only ever removes the link itself, never its
  target. *(v5.0.13, extended v5.0.14)*

- **Multipart merge could clobber an unrelated file.** `ensure_multipart_merge()`'s
  `mkvmerge -o` target (`Title.merged.mkv`) had no check that a pre-existing
  regular file there was actually something this script had created. Now requires
  a matching `.state` provenance record before ever merging over an existing file
  at that name; without one, it refuses and flags for human review. *(v5.0.14)*

- **`chown` followed symlinks.** `maybe_chown_for_media_user()` used plain `chown`,
  which follows a symlink and re-owns whatever it points to. Under `sudo`, a
  symlinked sidecar/output path could hand ownership of an unrelated real file to
  `SUDO_USER`. Now skips anything that's a symlink. *(v5.0.13)*

## Security

- **Two separate `eval`-based command-injection paths on `SUDO_USER`.**
  `_runtime_home()`'s fallback used `eval echo "~$SUDO_USER"` — reproducibly
  exploitable with `SUDO_USER='x$(payload)'`, confirmed via direct testing. First
  fix replaced it with `~"$SUDO_USER"` (quoted tilde expansion, no eval). *(v5.0.12)*

  **That fix was itself found to be silently non-functional**: direct testing
  confirmed bash tilde expansion never substitutes a variable's value into the
  tilde-prefix position at all, quoted or unquoted, for *any* username, resolvable
  or not — `~"$V"` and `~$V` both stay a literal `"~value"` string. The safe
  replacement had quietly been falling through to `$HOME` on every run. Replaced
  with real `getent` (Linux) / `dscl` (macOS, since `getent` is glibc-only) /
  python3 `pwd.getpwnam` lookups — none of them `eval`, all of them actually
  working, verified against a real resolvable user. *(v5.0.13)*

  A third `eval` remains, in `_cifs_mount_fresh`'s trap-restoration path — this one
  was reviewed and confirmed safe by construction, since it only ever evaluates
  bash's own `trap -p` output to restore a previously-registered handler, never
  anything derived from user input or the environment. Left as-is. *(flagged and
  confirmed safe in v5.0.14)*

- **SMB credentials file had a permission race.** `mktemp` respects the process
  umask, briefly leaving the plaintext credentials file group/world-readable
  before a later `chmod 600` locked it down (a TOCTOU window). Now created under a
  forced `umask 077` so it's `0600` from the moment it exists, atomically. *(v5.0.12)*

- **SMB credentials file could be orphaned in `/tmp`.** If `mount` hung against an
  offline/firewalled SMB host and the user interrupted, nothing after that point
  ran, leaving the plaintext credentials behind. Added a cleanup trap. *(v5.0.12)*

  **That trap itself had a bug**: `trap ... EXIT INT TERM` is process-wide, not
  function-scoped, and this runs during early option parsing, before `main()` sets
  up its own `resume_on_signal` handler — so it would have permanently clobbered
  that handler for the rest of the run, silently breaking interrupt-triggered
  resume-state saving. Fixed by saving the prior handlers and restoring them via a
  `RETURN` trap, which fires on every exit path out of the function; `INT`/`TERM`
  also re-exit after cleanup to preserve the normal "Ctrl-C actually stops the
  script" behavior a custom trap would otherwise suppress. Verified with a direct
  nested-function trap test. *(v5.0.13)*

- **Predictable temp-file names for cache writes.** `mkv_structure_cache_invalidate`/
  `_store` used a fully static `.tmp` suffix; `filecache_put` used a PID suffix
  (`$$`) — guessable/enumerable by another local process wanting to race a symlink
  into place. Both upgraded to a real randomized `mktemp` name in the same
  directory. *(v5.0.13)*

  **One of those `mktemp` calls had its own bug**: `optimize_mkv_for_streaming`'s
  new template ended in `...XXXXXX.mkv` — a suffix *after* the `X`s. GNU `mktemp`
  tolerates that; BSD/macOS `mktemp` does not (the `X`s must be the template's
  trailing characters). On the fleet's one real macOS machine this would have
  silently reintroduced the exact predictable-name race the fix was meant to
  close. Every other `mktemp` template added this session was re-checked for the
  same mistake; only this one had it. *(v5.0.14)*

- **A leading `-` in `--path` broke `find`/`realpath`.** `-p -Media` got misread as
  a command flag regardless of quoting — quoting only stops the shell from
  word-splitting, not a program's own argv parsing from treating a leading dash as
  an option. Normalized with a leading `./` the same way any other relative path
  already is. *(v5.0.12)*

## Correctness

- **Done-log fast-resume was silently dead.** `resume_prepare_convert()` called
  `done_log_load()` *before* `resume_init_paths()` set `RESUME_DONE_LOG` to its
  real path, so it always saw the empty top-level default and never loaded
  `convert-v5.done`. Every restart fully re-validated every already-finished file
  via ffprobe/mkvalidator instead of fast-skipping it — silently reintroducing the
  exact multi-hour restart cost the done-log was built to eliminate. Fixed the
  call order. *(v5.0.11)*

- **WSL_INTEROP stripped by `sudo`, breaking Windows HandBrake/nvidia-smi calls.**
  `sudo` clears almost the entire environment by default, including the socket
  path WSL2's Linux userspace needs to invoke a Windows `.exe` host binary at all.
  Running as root and dropping to a real user (`sudo -u "$SUDO_USER"`) to call
  Windows `HandBrakeCLI.exe`/`nvidia-smi.exe` therefore failed with "cannot
  execute binary file" — not a real capability gap, just a stripped env var —
  silently forcing software-only fallback. Added a `sudo_drop_user()` helper that
  forwards `WSL_INTEROP` explicitly; inlined the same logic for the one call site
  wrapped in `timeout` (which can't exec a shell function). *(v5.0.11)*

- **Missing cross-machine atomic claim before encoding.** Fleet machines sharing
  the same NFS/SMB library had no way to prevent two machines from both deciding a
  title needs encoding and racing to write the same output file. Added an atomic
  `mkdir`-based lock (a `.lock` sibling directory, additive — the existing
  human-visible `.IN_PROGRESS` file's format is unchanged) with stale-lock
  detection for genuinely abandoned claims. *(v5.0.11)*

  Building this surfaced a real bug in the underlying staleness check: a
  same-host PID confirmed dead via `kill -0` was still treated as "not stale" for
  a further 2 hours — which would have locked out re-claiming a title that had
  just been killed (exactly what happened earlier in the same session). Fixed to
  recognize a confirmed-dead same-host process as immediately stale. *(v5.0.11)*

## Portability

- **Gawk-only `match(..., array)` broke disc title scanning on macOS.** 3-arg
  `match()` with array capture is a gawk extension; BSD/macOS `awk` doesn't
  support it — the exact bug class already fixed once elsewhere in this script,
  reintroduced here. Replaced with a portable 2-arg `match()` + `RSTART`/`RLENGTH`
  (POSIX-standard, works on both). *(pre-v5.0.10)*

- **`du -sb` is GNU-only.** macOS/BSD `du` has no `-b` flag. Blu-ray root size now
  sums real file sizes via the already-portable `file_size_bytes` helper.
  *(pre-v5.0.10)*

- **`file_size_bytes`'s fallback assumed GNU `stat -c` for any non-macOS
  platform.** Extended it to fall back to python3's `os.stat` (the same portable
  pattern already used by `mkv_structure_stat_key`) for any platform that's
  neither macOS nor recognized as Linux/WSL. *(v5.0.14)*

- **macOS mount-audit broke on mount points containing spaces.** `df | awk
  '{print $NF}'` only grabs the last whitespace-separated word. Fixed via a `sed`
  pattern anchored on the Capacity (`NN%`) column, which never legitimately
  appears inside a real path. *(v5.0.11)*

- **`dir_subtree_max_mtime` spawned one python3 process per subdirectory.** A
  season-heavy show folder over NFS previously paid a full python3 + `stat()`
  round trip for every season directory, on every scan. Consolidated into a
  single python3 `os.walk()` call. *(v5.0.11)*

- **External subtitle paths broke on filenames containing a literal comma.**
  Subtitle paths were comma-joined for HandBrake's `--srt-file`, then blindly
  re-split on `,` later during WSL path translation — corrupting any path like
  `"Movie, The (2020).en.srt"` into bogus fragments. Now each path is translated
  individually *before* joining, so no re-split is ever needed. *(v5.0.11)*

- **Non-essential `seq` dependency.** Replaced with bash's native C-style
  `for ((i=1; i<=n; i++))` loop in the VMAF sample-search inner loop. *(v5.0.11)*

- **Space in a custom mkvtoolnix path broke track labeling.** A configured
  `mkvmerge`/`mkvpropedit` path was joined with a plain space for the bash→python
  handoff, then Python's default `.split()` re-split on it — silently corrupting
  any custom binary path containing a space (e.g. a macOS `.app` bundle) into
  bogus argv fragments, with track labeling then just silently doing nothing. Now
  uses `\x1f` (ASCII unit separator, never legitimate in a real path) for the
  round trip instead of relying on whitespace splitting. *(v5.0.13)*

## Performance / logic gaps

- **`mv -n` organize collisions silently lost track of files.** `mv -n` no-ops
  (exit 0) if the destination already exists — the code then treated the
  untouched source as if it had moved, leaving the real file behind, un-organized,
  with no warning. Now detected and logged instead of silently mis-tracked.
  *(pre-v5.0.10)*

- **O(n²) pipeline queue reads.** `sed -n Np` against an ever-growing queue file
  rescans from the start on every single read — O(n) per item, O(n²) total across
  a large queue. Replaced with a persistent read file descriptor (O(1) per read).
  *(pre-v5.0.10)*

- **Pipeline job-count never propagated out of its own background scan process.**
  The scan producer runs as `... &` (a subshell); its own `CONVERT_JOB_TOTAL`
  assignment only ever existed in that child process, never the parent — "Convert
  queue finished: no items needed encoding" was reachable even after successfully
  encoding many items. The count now crosses via a file, the same way the
  scan-done signal already did. *(pre-v5.0.10)*

- **TV-library file-cache and folder-done flags went permanently stale.** Both
  keyed on a directory's own mtime, which per POSIX only changes on direct-child
  add/remove — adding an episode to `Show/Season 2/` never bumped `Show`'s own
  mtime, so the whole show's cache/done-flag silently stayed valid forever and new
  episodes became invisible. Re-keyed on the max mtime across the entire subtree.
  Also fixed the done-flag being *written* at Season level but only ever *checked*
  at Show level, so it was never actually consulted. *(pre-v5.0.10)*

- **Multipart merge ate two-part TV episodes.** `Show - S01E15 - Part 1.mkv` /
  `Part 2.mkv` are two separate episodes in every TV naming convention — same
  codec/resolution, so the compatibility check passed and `mkvmerge` happily
  concatenated two distinct episodes into one file. Now excluded entirely for any
  TV show/season directory, using Plex's own `Season NN` folder-naming convention
  plus existing episode-marker heuristics. *(pre-v5.0.10)*

- **`--clean-junk-apply` could delete the only remaining copy of a title.** A
  `.merged.mkv` was classified as orphaned junk whenever its raw `Part1`/`Part2`
  source files were gone — which is the *normal, expected* state after a user
  verifies a merge and deletes the originals. That rule was removed entirely.
  *(pre-v5.0.10)*

- **Merge detection ran during the fast pre-scan count.** The count used only to
  decide batch-vs-pipeline mode was triggering real ffprobe/mkvmerge work via
  multipart detection, turning a cheap count into potentially hours of I/O on a
  cold run across a large TV region. Given an explicit opt-out for that one
  caller. *(pre-v5.0.10)*

- **Non-atomic file-cache write.** `filecache_put()` wrote directly to the final
  cache file; an interrupted write (crash, NFS hiccup, a concurrent read from
  another fleet machine) could leave just the mtime header on disk, which
  `filecache_get()` would then accept as a valid cache hit with an empty file
  list — silently treating every video in that folder as gone until the
  directory's mtime changed again. Now writes to a temp file and renames into
  place atomically. *(v5.0.11)*
