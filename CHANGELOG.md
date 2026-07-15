# Changelog

Detailed record of every bug found and fixed during the v5.0.9 → v5.0.18 hardening
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
