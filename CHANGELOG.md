# Changelog

Detailed record of every bug found and fixed during the v5.0.9 → v5.0.28 hardening
passes. The [README](README.md) version table has one line per release; this file
has the full story — what was wrong, why it mattered, and how it was fixed.

## v5.0.33D — 2026-07-29

Fixes a false-positive subtitle-corruption deferral found while investigating
"bad source" files flagged by the large-scale 8-machine production-readiness
test. The user tested several deferred files directly and found some played
back correctly with no visible errors, prompting a root-cause investigation
rather than accepting the deferral verdict at face value.

Root cause: `validate_mkv_subtitle_tracks()` only ever checked the **first**
subtitle stream (`s:0`) for cues in a tail window near the end of the file,
treating a lack of cues there as truncated/mismatched subtitles and
permanently deferring the source. This assumed the first subtitle stream is
always the meaningful one to judge — but a source's disposition-`default`
flag (which usually corresponds to the first subtitle stream) can be
mis-authored independent of whether that specific track's content is valid.

Confirmed real case: **"The Great Beauty (2013)"**. `ffprobe` showed three
subtitle streams; the disposition-`default`-flagged track (`s:0`, absolute
stream index 2) contained only a byte-order-mark — genuinely empty — while a
different, non-default track (absolute stream index 4) had the complete,
valid English subtitles running to within about 8 minutes of the film's true
~2h20m40s runtime. Extracted and confirmed directly via `mkvextract tracks`
(chosen over `ffprobe -show_entries packet=pts_time`, which requires
sequentially demuxing large portions of an interleaved MKV container and was
extremely slow over NFS on this 8.4GB file). Separately, another deferred
file from the same test batch, "Bad Genius (2017)," was independently
confirmed by the user to be genuinely corrupt (does not play in VLC) and has
since been deleted — a true positive, unrelated to this bug.

**Fix**: `validate_mkv_subtitle_tracks()` now loops over every subtitle
stream on the file (`s:0` through `s:(n-1)`), skipping forced tracks exactly
as before (still queried per-track via ffprobe's disposition flag, never
guessed from cue density). It only fails the source if **every** non-forced
subtitle track lacks cues in the tail window — checking stops early the
moment any track passes. Ambiguity handling was hardened at the same time: a
timeout or probe error on any individual track's checks no longer determines
the outcome by itself; the function keeps examining the remaining tracks,
and only soft-fails (`return 124`, retryable) rather than confirming
corruption if no track passed and at least one was ambiguous. A hard failure
(`return 1`, permanent `Deferred/` move) now only fires when every non-forced
track gave a clean, unambiguous "no cues" result. Team-reviewed by two independent reviewers in parallel — both independently traced all four flag-combination
cases (all-forced, all-clean-fail, mixed-ambiguous, one-passes-early) and
confirmed the logic and `set -e` safety of the new per-track loop; no issues
found in the new code itself.

## v5.0.33C — 2026-07-29

Fixes an alarming (but functionally harmless) log message found during the
large-scale 8-machine production-readiness test: Plex's AMD iGPU VAAPI
`hevc_vaapi` encode capability probe crashed (`SIGABRT`, core dump) instead
of exiting cleanly when the driver genuinely doesn't support the requested
profile. This was already safe from a correctness standpoint — the probe
runs under `set +e`, captures the real exit code, and treats any nonzero
(or crashed) result as "not available," so hardware detection still fell
back correctly and no job was affected — but bash itself prints a
`PID Aborted (core dumped) <command>` line directly to the script's own
stderr for *any* foreground command that dies by signal, and this specific
message is not the command's own output — it comes from bash's own
job-control reporting, so `>/dev/null 2>&1` on the command itself does
nothing to suppress it (verified empirically). For anyone actually
depending on working AMD/Intel iGPU hardware, seeing what looks like a
crash in the logs on every single run would be needlessly alarming, even
though nothing was actually broken.

**Fix**: route the exact same probe command through a command substitution
(`probe_err="$(cmd 2>&1 >/dev/null)"`) instead of running it as a bare
foreground statement. Verified directly via isolated reproduction: an
identical command dying by `SIGABRT` prints the alarming line when run
bare in the foreground, and does not print it at all when run inside
`$(...)` — `$?` still correctly reflects the same exit status (134)
either way. Applied to both `_probe_amd_vaapi_on_device()` (the original
crash site) and `_probe_qsv_encode_available()` (Intel QSV path, same
probe shape, same theoretical risk, no observed crash there yet but fixed
proactively for consistency). `detect_nvenc_av1_tune()` (the NVENC probe)
was deliberately left untouched — it already writes to a log file rather
than `/dev/null`, has a different branching structure (timeout/sudo
combinations), and has been exercised on every single fleet job all
session without ever showing this symptom; its failure mode there is a
clean nonzero exit, not a signal crash.

Team-reviewed by two independent reviewers in parallel — both confirmed the fix
correct with no issues, and one reviewer specifically confirmed the code avoids
a classic related bash gotcha: `local var="$(cmd)"` in one statement would
have masked the command's real exit status with `local`'s own (always 0);
keeping the `local` declaration and the assignment as separate statements
(as this code already did) avoids that trap.

`convert-v5.0.33C.sh` checksum: `5539030b1cfd96ef9050814abb7e1bd677c3363b95f5f708b2b02a2232264f40`.

## v5.0.33B — 2026-07-28

Full E2E code-confidence review of the entire ~13,600-line script, requested
after the v5.0.33A validation-gap fix — not scoped to any one bug, a ground-up
audit for anything else lurking. Split into 7 sections and reviewed in
parallel by independent agents, producing ~30 findings. Critically, **every
finding was independently re-verified with a direct bash reproduction before
being fixed** — this caught that several of the audit's own "confirmed"
findings were false positives (a bare `var="$(cmd)"` that's a *non-final*
component of an `&&`-chain is exempt from `set -e`, which multiple findings
misjudged; several `stat`/`file_size_bytes`-style helpers already fail closed
internally, making their "unguarded" call sites safe in practice). Only
findings that reproduced empirically were fixed — recorded here by category:

**Real `set -e` abort-risk fixes** (bare assignments that CAN legitimately
fail in normal, non-bug operation): `resolve_crf_for_encode()`'s VMAF-target
lookup, reachable via any ambiguous/undetectable profile path — the exact
same class of path as the Movies/Japanese/Animation guard, just one level
deeper in the encode pipeline; a `python3`/`pwd` lookup and an `/etc/fstab`
read in `_runtime_home()`/CIFS mount detection (narrow sudo/no-getent
scenario); an unguarded `mktemp -d` inside the NVENC tune probe, reachable
because that probe is called bare from `main()`; `convert_pipeline_ready_pending()`'s
`wc -l` against a sidecar file that could vanish mid-run, polled in the
pipeline-mode hot loop. `find_original_source_for_av1()` was also unguarded
at a call site whose very next line's log message ("no original sibling")
shows the failure it doesn't handle is an anticipated, normal outcome, not
an error.

**A real scoping bug**: `pick_av1_encoder()` was missing `local` on
`hdr_note`, silently reading/writing a global.

**Dead code removed**: a logically-impossible third disjunct in
`subtitle_matches_video()` (recomputed the same value as the first
condition) that only added an unconditional extra subprocess spawn per
subtitle-match attempt.

**An O(n²) performance fix**: `mark_folder_done_if_complete()` ran a full
recursive re-scan of an entire show's subtree (every season, every episode)
on *every single per-file completion event*, even when the immediate folder
had a file still pending — mathematically guaranteed to fail that check
every time, since the parent-subtree check necessarily re-examines the
still-pending folder too. Now gated on `still_pending = false`.

**A cross-host safety gap in the orphan reaper**: `_orphan_write_stage_host_marker()`
previously swallowed write failures with `|| true`. This marker is the
*only* thing letting one fleet host's reaper recognize "this staging dir
belongs to a still-live encode on a different host" — a silently-failed
write (NFS hiccup, ENOSPC — exactly the conditions under which reaping is
most likely to run soon after) defeats that whole protection, risking
`rm -rf` of a live encode running on another machine. Now warns loudly
instead of hiding the failure (matches the "diagnostics must never be
silently swallowed" convention from the v5.0.33A stderr-blackhole fix).

**Multi-part source merge hardening** (previously only compared video
codec/resolution/pix_fmt/fps before merging parts, and validated nothing
about the merge's own result): added an audio-track (codec+channel-count)
compatibility check with an explicit `ref_a_seen` flag (an empty reference
value is legitimate here — a silent part — unlike the video check, where
it only ever means "not yet set"; missing this distinction let a
silent-Part-1-then-audio-Part-2 mismatch slip through uncaught in an
earlier draft, caught by team review); a post-merge duration-sum sanity
check (parts' summed duration vs. merged output duration, 10% tolerance)
to catch a merge that silently drops content, the same "exit code alone
isn't proof of real work" class of gap already fixed once this session;
a part-number contiguity check requiring the sequence start at 1 with no
gaps (Part 2 + Part 3 with Part 1 missing, or Part 1 + Part 3 with Part 2
missing, no longer silently "merge" as if complete — the start-at-1 half
of this check was itself caught by team review after the first draft only
checked adjacency); using the marker word (Part vs. Disc) to keep
different naming conventions from being merged together; and a guard
against a literal `|` in a filename corrupting the pipe-delimited internal
representation used to pass parts between functions.

**Cache-invalidation efficiency fix**: the per-directory file-list cache's
mtime-staleness check was walking into and stat-ing internal staging/junk
directories (`Deferred`, `.convert-stage-*`, etc.) that are already
excluded from the real video listing — a file moving through one of those
still bumped its parent's mtime and forced a spurious full re-scan. Now
excluded from both descent and the mtime computation itself (a residual,
accepted gap remains: a staging dir being *created or removed* directly
inside an otherwise-legitimate season folder still bumps that season
folder's own mtime by ordinary POSIX directory semantics, which this fix
doesn't and can't fully eliminate without a different invalidation
mechanism entirely).

**A dead-code + real-gap fix in the orphan reaper**: a
`-name '.convert-hbprog-*'` `find` clause was searching under the
NAS-shared library root, but that staging dir (HandBrake's progress-FIFO
scratch space) is actually created under the machine's own local
`${TMPDIR:-/tmp}` — the clause could never match anything there (removed).
A new, local-only cleanup pass was added to actually clean up orphaned
local hbprog dirs (no cross-host risk since `/tmp` is inherently local,
unlike the NAS-shared staging dirs). This new function itself first
shipped with two instances of the exact `set -e`-abort bug class this
whole review exists to catch — an `&&`-chain ending in a log call that's
false on the normal "removed 0 dirs" path, and a bare `rm -rf` that can
genuinely fail (verified directly: a read-only parent directory makes it
return non-zero) — both caught by team review and fixed before deploy, a
reminder that writing new code under the same real constraints this
session spent so much time on is easy to get wrong even while explicitly
hunting for exactly that mistake elsewhere.

**Strengthened, not redesigned**, the orphan reaper's encoder-liveness
heuristic: `orphan_size_stable()`'s polling window doubled (~8s → ~16s) to
reduce (not eliminate) the chance of misjudging a still-growing output as
stable between writes — deliberately not introducing a new tool dependency
(`lsof`/`fuser`, unused anywhere else in this fleet script) for what is a
narrow edge case (requires the *script* process to have segfaulted while
its encoder child kept running).

**A performance fix**: `_orphan_source_from_flag_for_pid()` was doing its
own full recursive `find` over the (possibly library-sized, NFS-shared)
root once per staged candidate needing source resolution, on top of the
main reaper loop's own identical scan — now memoized per `$root` for the
life of one reaper run.

Team-reviewed in two full passes (a general-purpose agent and two other
reviewers for the initial ~20-fix batch; one of those reviewers again for
the follow-up fixes that batch's own review surfaced) — both passes found real, fixable issues
in the fixes themselves, not just rubber-stamped the diff.

`convert-v5.0.33B.sh` checksum: `e11f541afad898d71f982b621ec3a0c3ad5bc1f835e1fd0f5a81e04f8bf72955`.

## v5.0.33A — 2026-07-27

Fixes a real, severe validation gap found by the v5.0.32Z fleet-wide
regression test itself — not a hypothetical. During the Plex machine's
assigned test (`For Whom the Alchemist Exists (2019)`, 11.85GB anime,
chosen to exercise the new EBML-fallback ceiling path), the source turned
out to have severely corrupted/sparse PTS (timestamp) data. ffmpeg's own
encode log showed `time=` climbing toward the full ~2 hour runtime while
`frame=` stayed stuck at 1 for most of the run, ultimately encoding only
**324 real frames (~13.5 seconds)** into an AV1 output whose container
still reported the full 1:57:54 duration — inherited from the source's
broken timestamps. This 6.9MB output was accepted: `validate_mkv_output()`
passed it, `validate_mkv_decode_windows()` passed it, and the folder was
marked done.

Root cause: `validate_mkv_decode_windows()` bounds-checks the first and
last `MKV_VALIDATE_WINDOW_SECONDS` (30s) of an output by decoding each
window to `-f null -` and treating ffmpeg's exit code as the verdict. When
the last-window probe (`-sseof -30`) seeks into a region the container
falsely claims has content, ffmpeg finds nothing, exits 0 cleanly, and the
check "passes" having verified nothing — exit code alone can't distinguish
"healthy content decoded" from "found nothing here, gave up cleanly."

**Fix**: added `decoded_frame_count()`, which parses the last `frame=N`
value from ffmpeg's own progress meter (written to stderr independent of
`-loglevel`, confirmed against real captured logs) after each windowed
decode, and both decode calls now pass an explicit `-stats` flag they
previously lacked. Validation now fails with a new `zero_frames_decoded`
corrupt-reason whenever a window decodes zero real frames.

**Two bugs caught before deployment, both by testing against real fleet
files rather than trusting the design on paper:**

1. The first draft omitted `-stats`. Verified directly against both the
   known-bad quarantined file and a known-good file (Crystalight's `Safe
   Word (2022).AV1.mkv`) — *neither* produced any `frame=` output without
   `-stats`, which would have made the new check fail universally, a
   fleet-wide false-positive regression far worse than the bug it was
   meant to fix. Testing the good file first (not just the bad one) is
   what caught this before it shipped.
2. All three reviewers (a general-purpose review agent and two other
   reviewers, independently) caught that `decoded_frame_count()`'s pipeline exits
   non-zero under `pipefail` when zero `frame=` matches exist — exactly
   the corrupt-file case — and the bare `frames="$(decoded_frame_count
   ...)"` assignment at both call sites would abort the *entire script*
   under `set -e` right at that moment, rather than gracefully failing
   validation for just that one file. Fixed by having the helper absorb
   its own pipeline failure (`|| true`) and always `printf` a value
   (defaulting to `0`), so the function itself never returns non-zero.

Re-verified after both fixes against real files: known-good (Crystalight's
Safe Word, docm's Headshot) show hundreds of real frames per window and
pass; the quarantined Alchemist Exists output shows 0 and correctly fails.

Team-reviewed by a general-purpose agent and two other reviewers in parallel for
the initial design, then one of those reviewers again for final confirmation of the
`set -e` fix — all four passes converged independently on the same
findings without prompting each other.

`convert-v5.0.33A.sh` checksum: `694801308bb29d2e1d7adaa28a879199d992bc3ee7675bc7e71b649a9e65dbbf`.

## v5.0.32Z — 2026-07-27

Fixes a severe, wide-reaching stderr-blackhole bug discovered while launching
the post-v5.0.32Y regression test plan: the ambiguous-path guard test
(`Movies/Japanese/Animation/` without `--profile`) exited 1 in under a
second with none of the expected `err "...is ambiguous..."` message ever
printed, and `main()` itself appeared to never be entered. Hours of
bisection (debug markers added at every candidate line in a scratch copy)
traced the actual failure to a single top-level statement that runs before
`main()` is ever reached, inside `resolve_job_sidecar_paths()`:

```bash
exec {MASTER_LOG_FD}>>"$MASTER_LOG_FILE" 2>/dev/null || MASTER_LOG_FD=""
```

`exec` with only redirections and no command word is a shell builtin that
applies those redirections **permanently to the current shell process**,
not just to that one statement — this is documented bash behavior, not a
malfunction. So `2>/dev/null` here silently and permanently redirected the
script's own stderr (fd 2) to `/dev/null` for the rest of every run, the
instant this line succeeded. Every later `err()`/`warn()` call anywhere in
the script (both write via `>&2`), including `main()`'s ambiguous-path
error, went silently into the void from that point on — while the process
still exited with whatever nonzero status the eventual check produced,
looking exactly like a silent, causeless failure. Confirmed directly: a
scratch copy with the redirect target changed from `/dev/null` to a capture
file showed the exec itself succeeding (`rc=0`) — it was never failing, it
was successfully doing something worse than failing.

This is not cosmetic: since this line runs at the very start of every job
on every fleet machine, it means **essentially all `err`/`warn` diagnostics
emitted after this point have likely been silently lost from the terminal**
on every run since this code was introduced. The `MASTER_LOG_FD`-based log
file writes themselves were unaffected (a separate fd); only the
terminal/stderr stream was swallowed.

A codebase-wide audit (independently converged on by two independent reviewers, plus
a general-purpose review pass) found the identical pattern at **9 sites
total**: the original `MASTER_LOG_FD` open, `DONE_LOG_FD`,
`CORRUPT_FILES_LOG_FD`, `BAD_SOURCES_LOG_FD`, `RECONVERT_FILES_LOG_FD`,
`SHARD_LOG_FD` (one open, two closes), and `CONVERT_READY_FD` (one close).
All 9 fixed with the same pattern — group-scope the redirect directly onto
the real `exec` inside a `{ ...; }` command group, which (unlike bare
`exec`) scopes redirections normally to just that command:

```bash
if { exec {MASTER_LOG_FD}>>"$MASTER_LOG_FILE"; } 2>/dev/null; then
  chmod 0666 "$MASTER_LOG_FILE" 2>/dev/null || true
else
  MASTER_LOG_FD=""
fi
```

An earlier draft used a separate writability probe (`: >>file`) before the
real `exec`; one reviewer caught that this introduced a narrow regression — if the
probe succeeded but the real `exec` then failed (race, fd exhaustion,
permission change), the unguarded `exec` would trip `set -e` and abort the
whole script instead of falling back to `FD=""` like the original did. The
single-statement group-scoped form above avoids that: exactly one open
attempt, one code path, no extra race window.

Team-reviewed by a general-purpose agent and two other reviewers in parallel, all
three independently confirming the bare-exec-redirect-persistence diagnosis
against bash's own documented behavior and verifying it live. Both other reviewers
independently flagged the same 5 additional affected sites
beyond the one first found — treated as high-confidence since two
independent reviewers converged on the identical list without prompting.

Re-verified after the fix: the original ambiguous-path guard test now
prints `[error] Movies/Japanese/Animation is ambiguous; rerun with --profile
anime or --profile wanime` and exits 1, as originally intended by the
v5.0.32V fix — confirming that fix (which was itself correct all along) had
simply never been visible until now.

`convert-v5.0.32Z.sh` checksum: `35babbec90651a4bd09e2a825421b34ca941be05faf659ac8652bfe2ddff2bf7`.

## v5.0.32Y — 2026-07-27

Retunes v5.0.32X's `MKVALIDATOR_MAX_SIZE_BYTES` and validation-timeout
constants based on real data the user pushed back with: a full library scan
(16,615 real movie files across `/mnt/BigMomma/Media/Movies`) showed the
2GiB ceiling excluded **49.6% of all movies** — far too aggressive, since
real movie content routinely runs 3-10GB with a genuine tail to ~69GB (only
Stand-Up Comedy content stayed mostly under 5GB). Two ideas for a faster
alternative were considered and ruled out first: sampling via extracted
clips (doesn't validate the *original* file's actual container structure —
a freshly-muxed clip tells you nothing about whether the source is
truncated or has a corrupt Cues table, which is exactly the failure mode
this check exists to catch) and mkvalidator's own `--quick` flag (only
speeds up already-broken files, not the common healthy-file case).

Directly measured a real 20.15GiB file's healthy full mkvalidator scan at
**~114 minutes (~340s/GiB)** — worse per-GiB than the earlier 2.59GiB data
point (~260s/GiB), confirming the cost isn't flat and climbs at scale.
Using the full library's cumulative size distribution to pick a ceiling
that trades validation depth for time proportionately:

| Ceiling | Library coverage | Single-attempt budget @350s/GiB |
|---|---|---|
| 7GiB | 85.9% | ~43 min |
| **10GiB (chosen)** | **94.8%** | **~60 min** |
| 15GiB | 98.6% | ~90 min |
| 20GiB | 99.5% | ~118 min |

**Changes**: `MKVALIDATOR_MAX_SIZE_BYTES` raised 2GiB → 10GiB;
`_validation_timeout_for_args`'s `extra_per_gib` raised 300 → 350 and `cap`
raised 1800s → 3620s (~60 min — not a round number, it's exactly what a
file at the new 10GiB ceiling needs at 350s/GiB, so the formula and the cap
agree at the boundary rather than one silently overriding the other).
Files above 10GiB (the remaining 5.2%, the true long tail) still get the
fast EBML-bounds check, which catches truncation — the dominant real-world
failure mode — without a multi-hour scan.

Also confirmed for the user, in response to "if it helps to confirm a file
is good before we even start the better": `validate_source_media()` is
already called at the very top of `process_video()`, before any codec
dispatch or encode work begins — source integrity has always been checked
before a single second of encoding starts, this session's fixes only
changed how *long* that check is allowed to take.

Team-confirmed (quick pass since the underlying mechanism was
already reviewed twice this session — only the constants changed): no
functional findings; one stale doc comment fixed (a leftover note citing
old "~170KB/s, tens of hours" figures that predated the real 20GiB
measurement).

`convert-v5.0.32Y.sh` checksum: `6c63878090f0ca1aa072d4ef8ccccc1582e06bc98952a544697048b815b9df42`.

## v5.0.32X — 2026-07-27

Closes the residual gap left by v5.0.32W's size-scaled validation timeout:
even at 300s/GiB, occasional failures remained on the very largest movie/TV
files because real NFS timing variance means the SAME file can take 2x+
longer on one attempt than the next (directly measured: a file that hit
rc=124 at its full scaled timeout succeeded cleanly in under half that time
on an immediate fresh retry). No fixed timeout eliminates that variance —
retrying is the correct answer, not further inflating the ceiling.

**Two complementary fixes**, both deployed together:

1. **`_run_timeout_retry()`** — every validation wrapper (`run_ffprobe`,
   `run_mkvmerge`, `run_ffmpeg_validation`, `run_mkvalidator`) now retries
   up to `VALIDATION_TIMEOUT_RETRIES` (default 2) extra times specifically
   on `rc=124` (timeout) before giving up. A genuine structural failure
   (mkvalidator reporting the file is actually invalid, rc 1/2) is never
   retried — a bad file won't become good on a second attempt, but a slow
   NFS moment often clears. `validate_mkv_ebml_bounds`'s python3 heredoc
   call is deliberately excluded: a heredoc's stdin is consumed on first
   read, so a naive retry would feed the second attempt an empty script
   (verified directly: reproduced the empty-stdin-on-reread behavior before
   deciding to exclude it, rather than assuming).
2. **`MKVALIDATOR_MAX_SIZE_BYTES` lowered from 5GiB to 2GiB** — files in the
   2-5GB range (exactly where today's failures clustered) now skip full
   `mkvalidator` and fall back to the fast EBML-bounds check, trading some
   structural-validation depth for reliability on files this large. Other
   gates (ffprobe metadata, `mkvmerge --identify`, decode-window checks,
   audio/subtitle validation) remain active regardless.

Sent through the 3-way team review gate before deploying:
- **[3-way consensus, real, fixed]** the first draft's retry loop ran
  inside a function whose *caller* redirects stdout/stderr to a shared
  file/pipe for the entire call (e.g. `run_mkvalidator ... 2>"$errf"` in
  `validate_mkv_mkvalidator`). If attempt 1 wrote diagnostic output (even
  an `ERR` line) before timing out, that content persisted in the shared
  target; a clean, successful attempt 2 then appended nothing new, so the
  caller's post-hoc `grep ERR "$errf"` could still find attempt 1's stale
  output and misreport a successful retry as a failure. All three
  reviewers caught this independently — one reviewer named the exact three
  affected call sites (`validate_mkv_mkvalidator`,
  `validate_mkv_decode_windows`, `ffprobe_metadata_ok`). Fixed by having
  `_run_timeout_retry` isolate each attempt's stdout/stderr into its own
  fresh temp file and replay only the FINAL attempt's captured output to
  the caller — works uniformly regardless of whether the caller redirected
  to a file or a command-substitution pipe, without touching any call
  site. Verified directly: reproduced the exact stale-output scenario in
  isolation before the fix (confirmed the bug was real) and after (confirmed
  it's gone) using a synthetic mock command.
- **[one reviewer, real, fixed]** the fix's own first pass leaked a temp file if
  the first `mktemp` succeeded but the second failed. Fixed.
- **[one reviewer, real, deferred]** `VALIDATION_TIMEOUT_RETRIES` accepts any
  digit string, including one large enough to break the `-gt` comparison
  under `set -e`. User-misconfiguration-only, not a default-path issue —
  tracked in ROADMAP.md rather than fixed under time pressure.
- **[one reviewer, real, deferred]** the mkvalidator structure-cache doesn't
  distinguish an EBML-only pass (now more common with the lower 2GiB
  ceiling) from a full mkvalidator pass — only matters if
  `CONVERT_MKVALIDATOR_MAX_SIZE` is raised again later and a cached
  EBML-only result is trusted as if it were a full pass. Tracked in
  ROADMAP.md.
- **[another reviewer only, checked directly and confirmed a false positive, again]**
  That reviewer repeated (for the third time this session, across three separate
  review rounds) its claim that the `stat -c%s -- / stat -f%z --`
  portability fallback fails on macOS/BSD because `--` isn't supported.
  Already directly disproven on Crystalight (the fleet's real macOS
  machine): `stat -f%z -- <file>` works fine, exit 0. Not fixed — there is
  nothing to fix. Noted here explicitly since a claim repeating across
  multiple independent review rounds could otherwise look like mounting
  evidence; it's the same single mistaken prior each time, not
  independent confirmation.

`convert-v5.0.32X.sh` checksum: `8a9d31cd4fb83d05ca50fbeddda4c44921451440327d216490ac25f6bdcd57e3`.

## v5.0.32W — 2026-07-26/27

Fixes the real root cause behind the "possible stalled mount" validation
failures that dominated most of the v5.0.32V mixed-content test session
(see that entry below for the full, initially-wrong-twice diagnostic
journey through fleet contention and NAS scrub theories before landing
here). **The actual bug**: `VALIDATION_TIMEOUT_SECS=120` — the flat timeout
wrapping every `ffprobe`/`mkvmerge`/`mkvalidator`/`ffmpeg`-validation
subprocess call via `run_with_timeout` — was tuned for anime's typical
300-700MB episodes and is far too short for real movie/TV content. Directly
measured: a genuinely healthy `mkvalidator` structural scan of a 2.59GB
file took roughly 650-700 seconds over NFS, not the 120s the timeout
allowed — the file was fine, just larger and slower than anything this
timeout had ever been exercised against. Confirmed via 4 consecutive fleet
retries all failing on the exact same specific large files regardless of
fleet load or NAS state — the reproducibility across every environmental
condition was the actual signal (missed twice) that this was a
deterministic client-side threshold problem, not an external one.

**Fix**: new `_validation_timeout_for_args()` function, called by all 4
validation wrappers (`run_ffprobe`, `run_mkvmerge`, `run_ffmpeg_validation`,
`run_mkvalidator`) plus `validate_mkv_ebml_bounds`, replacing the flat
`${VALIDATION_TIMEOUT_SECS}` with `$(_validation_timeout_for_args "$@")`.
It finds the file(s) being validated from the wrapper's own arguments — an
`-i FILE` pair if present (ffmpeg-validation's convention), else the sum of
every plain trailing argument that currently exists as a file (naturally
handles both a single-source call, where a not-yet-created `-o` output
target contributes nothing, and a multi-part merge, where every real part
counts) — and scales the timeout at 300s per GiB, capped at 1800s, never
below the 120s base.

Sent through the 3-way independent team review gate before
deploying, since this touches a core safety timeout fleet-wide:
- **[3-way consensus, real, fixed]** the first draft's fallback file-finder
  used "last non-flag argument wins," which correctly handled every
  single-file call site but silently under-scaled a multi-part `mkvmerge`
  merge (`part1 + part2 + part3`) down to only the *last* part's size —
  all three reviewers independently caught this, the same "independent
  convergence = real bug" pattern seen repeatedly this session. Fixed by
  summing all existing real files instead of picking the last one.
- **[one reviewer, real, fixed]** the first draft's 200s/GiB scaling factor left
  ~0 safety margin against the actual measured rate (the incident's 2.59GiB
  file needed ~230-250s/GiB, not 200s/GiB) — raised to 300s/GiB and the cap
  from 1200s to 1800s to keep real headroom even for the largest files
  `mkvalidator` will still run against (5GiB, the existing
  `MKVALIDATOR_MAX_SIZE_BYTES` ceiling).
- **[another reviewer only, checked directly and found to be a false positive]**
  claimed the `stat -c%s -- / stat -f%z --` portability fallback always
  fails on macOS because BSD `stat` doesn't support the `--`
  option-terminator. Verified directly on Crystalight (the fleet's actual
  macOS machine): `stat -f%z -- <file>` works fine, exit 0. Not fixed —
  there was nothing to fix; a useful reminder that even confident,
  detailed-sounding single-reviewer findings need direct verification
  before acting on them, not just plausibility.

`convert-v5.0.32W.sh` checksum: `ba888a248298711fe7dbbfb22002c6416d9f906b546f73fcea2713297ad02611`.

## v5.0.32V — 2026-07-26

Full 8-machine v5.0.32U confidence test completed (same anime titles as
every prior round, `--no-resume`, all machines checksum-verified beforehand).
Result: no silent failures anywhere, every skip/keep/failure outcome matched
its logged tally. One genuine content-integrity finding on Crystalight
(`16bit Sensation- Another Layer S01E02`): the source failed mkvalidator,
got auto-repaired via remux (source untouched), but the re-encoded *output*
also failed mkvalidator — the script correctly rejected the bad output,
kept the original, and logged a real "Job failed" (not silent). Worth a
future look into why corruption survived the repair into the re-encode, but
the safety net itself worked as designed. Also found (and fixed) a second
instance of the same mkvalidator-parity gap PRINCE had: MacFedora's `worker`
account was also missing the binary (present only under the personal
login account, `localuser2`) — copied over, checksum-matched to the rest of the
fleet (`5db0a566ee39253bb5b65df7aa1f107cb9590bd035effc0eafcf90363be2c537`).

Ahead of the next-stage test (first real Movies/TV content this session,
not anime-only — auto-detecting the profile from the library path instead
of forcing `--profile anime`), sent the script through a fresh 3-way team
independent review focused specifically on the profile
auto-detection and movies/classic/vintage/mtv/vtv encode paths, since
those have never been exercised or scrutinized this session the way the
anime path has. Findings, triaged against the real on-disk library
structure rather than taken at face value:

- **[two reviewers, real, fixed] `process_video()` silently marked a file
  "done" on profile-detection failure.** `profile="$(profile_for_source
  "$src")" || return 0` (line 12446) meant any unmapped or ambiguous path
  (e.g. `Movies/Japanese/Animation/*` reached via a broad scan rather than
  as the exact `SEARCH_PATH`) returned success with no encode and no retry
  — permanently invisible to monitoring, same false-success bug class as
  the v5.0.32T `process_video()` fix and the v5.0.32U round-1/2 lock bugs.
  Fixed: `|| return $?`, propagating the real failure into the existing
  `process_video "$f" && CONVERT_JOB_OK=true || warn "Job failed —
  continuing queue"` handling (already proven correct this session).
  Doesn't affect this round's planned test (all chosen paths cleanly
  auto-detect), but matters for the eventual full-scale rollout where an
  unanticipated path is inevitable.
- **[two reviewers, verified NOT a real gap] `Television/*/Classic/*` is
  unmapped in `detect_profile_for_path()`.** True as read, but checked
  against the actual NAS structure: no `Television/*/Classic` folder
  exists anywhere in the library (TV only ever has Animation/Modern/
  Vintage — confirmed both on-disk and in memory's library-structure
  record). Not a missing case, just TV's real 2-era taxonomy vs Movies'
  3-era one. No fix needed; noted here so a future reviewer doesn't
  re-flag it without checking the real data first.
- **[two reviewers, real, deferred] HandBrake color-metadata/CRF paths
  don't handle HDR as correctly as the ffmpeg path.** `handbrake_append_
  color_metadata()` (~5726) tags HLG sources with PQ transfer
  characteristics, and `load_encoder_profile()`'s HandBrake branches
  (~8471, 8480) never pass `hdr=true` into `profile_fixed_crf()`, so
  HandBrake/disc-sourced HDR encodes get SDR fixed CRFs. ffmpeg's
  equivalent paths handle both correctly. Not fixed this round: the fleet
  currently only uses the HandBrake engine for disc sources, which no
  fleet machine is currently processing — deferred to ROADMAP rather than
  risk an under-tested change to a currently-inactive path under time
  pressure.
- **[one reviewer only, verified real but currently dead code] `profile_fixed_crf()`
  hardcodes numeric CRF literals instead of referencing the declared
  `FIXED_CRF_SVT_*`/`FIXED_CRF_X265_*` variables.** Checked directly: the
  literals exactly match the variables' current values, and those variables
  aren't exposed via any `--flag`/env-override today (unlike `VMAF_TARGET_*`,
  which do support `--vmaf-target`), so there's no behavioral difference
  right now — a DRY/maintainability nit, not a functional bug. Deferred to
  ROADMAP.
- **[one reviewer only, verified real but unreachable on current library] Case
  order in `detect_profile_for_path()` checks `*/Animation/*` (line 3817)
  before `*/Movies/*/Classic|Vintage/*` (3819-3820)**, so a hypothetical
  `Movies/<Lang>/Classic/Animation/...` or `.../Vintage/Animation/...`
  folder would misroute to `wanime` instead of the classic/vintage
  profile. Checked directly: no such nested structure exists on the NAS
  (Animation is always a sibling of Classic/Vintage/Modern, never nested
  under them). Deferred to ROADMAP as a robustness item, not urgent.
- **[one reviewer only, unconfirmed by the other two, not yet independently
  verified] `anime_title_year()`'s year-extraction regex could theoretically
  match a parenthesized resolution tag like `(1080)`** and misroute a title
  to the classic-anime profile. Not confirmed by either other reviewer, not
  reproduced against real data this round — flagged in ROADMAP for a
  closer look, not treated as confirmed.

**Note on the archived `Old Versions/5.x/convert-v5.0.32U.sh`**: due to
fix-then-archive ordering, that file actually contains this round's one-line
fix baked in — its checksum will NOT match the originally-recorded
deployed-v5.0.32U checksum (`b9b4fc695612ee54e157a9eaa38dd536bc204641b3191c8d0e8f9f225633b1e0`).
Purely a provenance/bookkeeping note, not a functional issue — v5.0.32V is
what's actually deployed everywhere going forward.

`convert-v5.0.32V.sh` checksum: `d10bf2ae9c2f48458d1c60a19820b50dcaf7ab4060c984809276a5833746aec9`.

## v5.0.32U — 2026-07-25/26

A full end-to-end team review (three independent reviewers, against
the complete ~13,000-line file) requested proactively as a fleet-wide health
check ahead of the next confidence test — not triggered by a known bug this
time. Went 4 rounds of fix → re-review before all three reviewers
independently converged on "genuinely clean, ship it." Full story of what
was found and fixed, in the order it surfaced:

**Round 1 (fresh findings, no prior context):**
- **[3-way independent consensus, Medium/High] `_shared_mutex_acquire`'s 10-second lock
  reclaim was based on a spin counter, not real elapsed time.** `sleep 0.1`
  isn't guaranteed to take only 0.1s under load, so the actual time before
  reclaim could be far more or less than intended — and a genuine NFS stall
  inside the critical section (a slow done-log append, a slow structure-
  cache rewrite) was entirely plausible on this fleet and well within that
  window, meaning a live holder's lock could get stolen out from under it,
  reintroducing the exact lost-update race the mutex exists to prevent.
  First-pass fix: check the lockdir's actual wall-clock mtime (new
  `_shared_mutex_dir_age_secs` helper) instead of a spin count, raise the
  threshold to 90s, only re-check age every ~2s of spinning (not every
  0.1s poll) to avoid extra NFS traffic.
- **[one reviewer] `process_video()`'s early `validate_source_media` failure was
  unconditionally folded into `return 0`, even for NFS-stall timeouts** —
  the same false-success class of bug v5.0.32T fixed one step later in the
  same function, just missed on this earlier call. A stalled-mount timeout
  during source validation silently logged as "Job complete" and, worse,
  got wrongly marked `completed` in the resume state (so a later resumed
  run would skip it forever instead of retrying once the mount recovered).
  Fixed with a new `SOURCE_VALIDATE_TIMED_OUT` flag, set at each of
  `validate_source_media`'s 7 timeout-class return sites, checked by
  `process_video` to propagate a real failure only for the timeout case
  (a durable bad-source verdict, already permanently handled via
  `flag_bad_source_for_human`/Deferred/, still correctly returns 0).
- **[another reviewer] The unlocked pre-queue quick-scan gate
  (`source_looks_processable_quick`) could call `flag_bad_source_for_human`
  (an unlocked `mv` to Deferred/) while another host was actively encoding
  that exact title** — a genuine race against a live job on a shared NFS
  library, not just wasted duplicate work.
- The third reviewer's concern that `convert_scan_producer`'s background-subshell EXIT
  trap wouldn't fire on SIGINT/TERM (risking a hang) was investigated and
  found not applicable: the main script's own signal handler
  (`resume_on_signal`) directly `kill`s and `wait`s the child PID without
  ever depending on the done-file or the child's EXIT trap.
- The second reviewer's note that `tag_preexisting_desired_format`/`tag_guardrail_exceeded`
  write tags directly to original sources was confirmed as an existing,
  explicitly-documented accepted exception, not a new bug.

**Round 2 (re-review of round 1's fixes):**
- **[two reviewers, independently converged] The round-1 fix for the
  quick-scan race acquired the REAL per-title lock, then released it — but
  had no cleanup guard.** If the process was killed (SIGTERM) mid-check
  (while holding the lock during ffprobe/EBML validation), the release
  never ran, leaking a lock other hosts would treat as live for up to 2
  hours — blocking a real encode of that title fleet-wide for the rest of
  that window. Fixed properly by never acquiring the lock at all: a
  plain read-only existence check (`[ -d "...lock" ]`) has nothing to leak
  on an abnormal exit, and is sufficient to answer "is someone else
  actively working this title right now?"
- **[another reviewer] Even with round 1's atomic-mv reclaim fix, `_shared_mutex_acquire`
  had no ownership verification on release** — if a slow original holder
  was timed out and reclaimed by a waiter, the original holder's own
  eventual `_shared_mutex_release` would blindly `rmdir` whatever lockdir
  existed by then, which could now belong to the legitimate new holder,
  letting a third waiter in concurrently and reopening the lost-update
  race. Fixed with an ownership token: acquire writes a unique token into
  the lockdir and returns it; release takes the token and refuses to
  remove the lock if the on-disk token doesn't match. All 3 call sites
  (`done_log_append`, `mkv_structure_cache_invalidate`,
  `mkv_structure_cache_store`) updated to capture and pass the token
  through both their success and early-exit release paths.

**Round 3 (re-review of round 2's fixes):**
- **[all 3 reviewers, independently converged — the strongest signal of
  this whole pass] The round-2 ownership-token fix broke the release
  happy path entirely.** `rmdir` only removes *empty* directories; writing
  the `.owner` token file into the lockdir meant every legitimate release's
  `rmdir` would now silently fail (`|| true` swallowed the error), leaking
  every single successful acquisition until the 90s stale-reclaim path —
  turning the done-log append and structure-cache updates into ~90-second
  fleet-wide stalls after the very first use. Fixed by having release
  remove the `.owner` file before the `rmdir`.
- **[one reviewer] The round-2 read-only-existence-check fix for the quick-scan
  gate (correct for avoiding the SIGTERM leak) had a side effect:** a
  genuinely abandoned/stale lock was treated the same as a live one, so
  that title would never reach `place_in_progress_flag`'s own reclaim
  logic either — silently regressing recovery to depend on the orphan
  reaper alone instead of the normal path. Fixed by also checking
  `junk_flag_is_stale` on the lock's flag file: a stale lock is treated as
  "not actually held" (proceed with the quick check; real reclaim still
  happens later, at actual encode-claim time).

**Round 4 (final verification):** all three reviewers independently
confirmed both round-3 fixes are correct and complete, found no further
issues in the mutex/lock area after 4 passes over it, and gave an explicit
"genuinely clean, ship it" signal. One Medium-severity, single-reviewer
note — NFS close-to-open cache consistency for the persistent
`DONE_LOG_FD` possibly delaying done-log visibility across hosts — was
evaluated by the other two reviewers and determined not worth acting on:
the done-log is a fast-skip/resume optimization, not the actual
correctness guarantee (per-title locks, output inspection, and tags
already provide that), and the persistent FD is itself an intentional
symlink-race hardening choice from an earlier round. Tracked as a
low-priority future hardening idea, not a blocker.

## v5.0.32T — 2026-07-25

**Real bug found during a full fleet log audit (not a hypothetical):** on
Crystalight, one episode's source needed an `mkvalidator` repair, the
repair succeeded, but the resulting re-encode's own output *also* failed
`mkvalidator` structure validation and was correctly discarded (original
preserved, no data lost) — yet the batch log showed `Job 12 of 13
complete` with no "Job failed" warning, and the run's final tally counted
it in neither `files processed` nor `files skipped`. Root cause:
`process_video()`'s AV1/HEVC-source dispatch branches called
`process_existing_av1 "$src"` / `process_existing_x265 "$src"` and then
**unconditionally `return 0`**, discarding those functions' real exit code
(1 on a genuine encode/validation failure) before it ever reached the
caller (`process_video "$f" && CONVERT_JOB_OK=true || warn "Job failed —
continuing queue: $f"`). Fixed by capturing and propagating the real
return code (`local rc=0; process_existing_av1 "$src" || rc=$?; return
"$rc"`, same for x265) — `set -e`-safe since the call sits on the left of
`||`. Confirmed via 3-way independent review that: the fix is correct, no similar bug exists on the disc-source path
(which already propagates `try_av1_convert`'s exit code naturally as the
function's last command), and — a benefit none of us had fully clocked
going in — this also restores correct **resume** behavior, since a
falsely-"successful" job was previously never eligible for retry on a
subsequent resumed run.

## Infrastructure — WSL2 NFS auto-mount self-healing service — 2026-07-25

Not a script change. Root-caused why GruntBox2's confidence-test job died
silently overnight (its WSL2 instance restarted — almost certainly the
Windows host sleeping/rebooting — and all NFS mounts simply vanished,
never coming back automatically). Confirmed via `journalctl` that
`remote-fs.target`'s boot-time NFS automount is genuinely unreliable on
this fleet's WSL2 machines (two different failure modes on PRINCE vs
GruntBox2, same end result — see `ROADMAP.md` for the full diagnostic
detail) and, critically, systemd never retries a mount unit after it
fails once per boot. Added `ves-mount-recovery.sh`/`.service` (now in the
repo root) — a small self-healing systemd unit that retries `mount -a` +
`cachefilesd` recovery up to 6 times with backoff after any restart,
independent of whatever specific race caused that boot's automount to
fail. Deployed and functionally tested on PRINCE and GruntBox2; not yet
verified across a real reboot on either (opportunistic next time one
restarts) and not yet deployed to the non-WSL2 fleet members.

## Infrastructure — PRINCE parity audit + GruntVM/AI-PROCESSOR mount fix — 2026-07-24

Not a script change. Fixed the long-tracked flat-vs-nested NFS mount
convention mismatch on GruntVM and AI-PROCESSOR (`/etc/fstab` source
changed from `.../BigPoppa/Media` to bare `.../BigPoppa`, matching the
nested convention already used everywhere else) — AI-PROCESSOR's separate
`StockLake` mount (different source IP, unrelated export) was explicitly
left untouched. One real complication handled safely: AI-PROCESSOR had a
live confidence-test VMAF comparison job with files open through the old
mount; `umount -l` cleared it without disturbing the running job. Also
ran a full feature-parity audit of PRINCE against GruntBox2/MacFedora/docm
post-rebuild — SVT-AV1 version, sshd hardening, worker-group membership,
cachefilesd config, fastfetch exclusion, and cron/timer inventory all
confirmed matching the fleet standard, with two small gaps closed
(`docm` added to PRINCE's `worker` group for parity with MacFedora's
model). Full detail in `ROADMAP.md`.

## Infrastructure — PRINCE full WSL2 rebuild — 2026-07-24

Not a script change (no version bump) — PRINCE's WSL2 root filesystem
corrupted (repeated "Catastrophic failure" restarts + a near-full C: drive),
causing `ffmpeg` to crash with a Bus error decoding *any* file, which made
the running confidence-test job silently produce zero real encodes while
reporting "successfully completed." Fixed via a full distro rebuild (not
repair) plus two real networking bugs on the fresh install: a misleading
GRO-driver dmesg warning that turned out not to be the cause, and the
actual root cause — NFS's default `resvport` (privileged source port)
being silently blocked, fixed with the `noresvport` mount option. Full
diagnostic story, exact fix commands, and the "check this first next time"
guidance are in `ROADMAP.md`'s "PRINCE full rebuild" section — kept there
rather than duplicated here since it's as much a runbook as a record.
Verified via the exact ffmpeg command that previously crashed on all 12/12
episodes of the confidence-test title, now succeeding cleanly.

## v5.0.32S — 2026-07-24

A full end-to-end team review (three independent reviewers, both halves of the file
plus a cross-cutting integration pass) ahead of the next fleet confidence test,
followed by three rounds of fix → re-review until every finding was resolved or
explicitly documented as accepted scope. Every fleet job was cleanly stopped
(SIGTERM to each script's top-level PID, confirmed via the signal trap correctly
killing its tracked ffmpeg child too) before this work began, since several
findings touched concurrency/locking correctness.

**Critical: orphan reaper could delete another fleet machine's live encode.**
`is_convert_script_process`/`kill -0` in the staging-directory cleanup path only
ever tests the *local* host's PID namespace — on the shared NFS library, a
remote host's live `.convert-stage-*` directory has no matching local PID at
all, making it look "dead" here even while it's actively being written to.
Fixed by writing a `.convert-stage-host` marker at every staging/finalize/
multipart directory's creation, checked by the reaper *before* any local-PID
judgment — a marked directory belonging to another host is now skipped
entirely (new `dirs_skipped_cross_host` stat). A directory with no marker at
all (a pre-fix leftover, or if the marker write itself failed) is now handled
more conservatively too: it can no longer be disposed via "local kill -0 says
dead," only via the existing age-gate threshold — closing the gap for
marker-less directories as well, found in a second review pass.

**High: a source could be permanently moved to `Deferred/` on a transient
NFS blip.** Both `source_looks_processable_quick` (pre-lock quick scan) and
`validate_source_media` (encode-time) treated any non-timeout ffprobe
failure as confirmed corruption on the first attempt — a brief NFS/network
hiccup often surfaces as a read error rather than a clean timeout, so it
never hit the existing "possible stalled mount" exemption. Both now retry
once (2s pause) before concluding the source is genuinely bad.

**3 NFS-shared-file race conditions**, found via full-file review:
- The mkv-structure-validation cache and the done-log are both genuinely
  meant to be one shared ledger across the whole fleet — their
  read-modify-write (cache) and append (done-log) operations had no
  cross-host locking at all, so two machines updating them concurrently
  could silently lose each other's writes. Fixed with a new mkdir-based
  cross-host mutex (`_shared_mutex_acquire`/`_shared_mutex_release` —
  `mkdir` is atomic across NFS regardless of client OS, unlike `flock`
  across this fleet's mixed Linux/WSL2/macOS clients; a ~10s stale-lock
  reclaim prevents a crashed holder from deadlocking the fleet).
- The resume-state/queue/shards files, by contrast, are NOT meant to be
  shared — each tracks a single run's own progress for restart purposes.
  These are now per-host (hostname embedded in the filename) instead of one
  shared filename fleet-wide. Deliberately not also keyed by PID: doing so
  would break resume-across-restart entirely (a restarted process gets a
  new PID and could never find its own prior state). A same-host *concurrent
  double-invocation* race is accepted as a documented residual gap rather
  than risk a run-lifetime lock conflicting with the existing `ramdisk_job_
  teardown` `EXIT` trap — see ROADMAP.md.

**Medium fixes:**
- `optimize_mkv_for_streaming`'s temp directory is now tracked in a new
  `ACTIVE_STREAMOPT_DIR` global, cleaned up by both the signal-interrupt
  handler and the `set -e` error trap — previously a local-only variable, so
  an INT/TERM mid-remux left it behind permanently (the same pattern already
  used for `ACTIVE_LOCAL_STAGE_DIR`/`ACTIVE_FINALIZE_DIR`).
- `current_tool_versions_tag_suffix` computed each tool-version string via a
  bare command substitution with no fallback — a missing/erroring `ffmpeg`
  or `mkvmerge` would abort the whole script under `set -e` mid-tag-write
  instead of falling back to "unknown" the way the string implied. Each
  piece is now computed separately with its own `|| var=""`.
- Multipart-merge finalization had two unchecked `mv` calls; a mid-sequence
  failure could abort under `set -e`, or (if only the second `mv` failed)
  leave the real merged output in place with no matching state file. The
  state `mv` now retries once after a pause, and if it still fails, the
  merge itself is reverted (`rm -f` the merged output) so the next run just
  redoes the whole merge cleanly instead of hitting an ambiguous half-done
  state.
- A misleading comment claimed x265's "already small enough" skip threshold
  sits lower than AV1's; the actual values (AV1 50MB / x265 80MB) mean the
  opposite. Comment corrected; no functional change.

**Considered but reverted:** enrolling the season-level shrink heuristic's
derived-AV1 (oversized `.AV1.mkv` recheck) sample-skips into the same
forced-retry cohort as genuinely-original skips. A second review pass found
this would have actively misbehaved rather than just missing a bonus retry —
`season_retry_pass` routes purely on the stored file's current codec, and the
resolved original sibling for this cohort is usually not AV1, so it would
get force-routed to an x265-only retry; separately, the already-existing
oversized output would make `try_av1_convert`/`try_x265_convert`'s own
existing-output shortcut return "success" immediately without re-encoding
anything, since only `FORCE_REPROCESS_TAGGED` bypasses that check, not
`SEASON_RETRY_IN_PROGRESS`. Reverted rather than ship a season-retry entry
that silently no-ops; documented as accepted scope in ROADMAP.md pending a
real fix to `season_retry_pass`'s own routing/bypass logic.

## v5.0.32R — 2026-07-24

Two changes, both from the same fleet confidence-building test (10 items/machine
across all 8 fleet machines on v5.0.32Q).

**Lowered preexisting-desired-format size gates.** Several machines (PRINCE,
Crystalight, GruntBox2) finished suspiciously fast — every assigned episode
was already-AV1 and fell under the old `PREEXISTING_SMALL_SKIP_MAX_MB=300` /
`PREEXISTING_X265_SMALL_SKIP_MAX_MB=250` caps, so the whole batch just got
tagged "preexisting desired format" without ever running the real 3-point
sample test. Lowered to 50MB/80MB respectively so anime-episode-sized files
(typically 120–290MB) actually get sample-tested. Confirmed live: relaunching
the same 3 machines' assignments under the new caps correctly switched every
file from an instant skip to "AV1 source — sample-testing whether re-encode
would shrink," with a genuine mix of real skips and real re-encodes on all
three (PRINCE: 8 real re-encodes / 5 genuine skips across 13 episodes, zero
aborts).

**New season-level shrink-vs-predicted-no-shrink heuristic.** Same-season TV
episodes are similar enough in content that sibling results are often a
better predictor than the per-file 3-point sample test alone. Within a single
batch/folder run, for each (show folder, season number) pair: if ≥60%
(`CONVERT_SEASON_RETRY_THRESHOLD_PCT`, default 60) of that season's sample-
tested episodes actually shrank, the remaining episodes the sample predicted
*wouldn't* shrink get one real forced-encode retry instead of trusting that
prediction — routed by actual source codec (`try_av1_convert` for an AV1
source, `try_x265_convert` with `force_transcode=true` for HEVC/x265, both
already judged against the normal size/VMAF guardrails). Went through 3 full
rounds of independent review before being considered
done; each round surfaced real issues that were fixed and re-verified:
- **Cross-show pollution**: the season key was originally just the season
  digits, so every unrelated show's "S01" pooled into one bucket. Fixed by
  keying on `(dirname(file), season)` together, not season number alone.
- **False-confirmed failures**: any `try_av1_convert` non-zero return was
  originally treated as "confirmed no size win" and re-tagged, even though
  non-zero can mean an encode-tool failure, a validation timeout, or a
  path-collision guard — none of which are a real size verdict. Fixed by no
  longer tagging anything on failure at all; the one case that IS a genuine
  size rejection is already tagged correctly by `try_x265_convert`'s existing
  `tag_guardrail_exceeded` call in that exact path.
- **Missing NFS lock**: retries originally called the encode functions
  directly, bypassing `begin_convert_job`/`end_convert_job`'s in-progress
  flag — a real double-encode race window on the fleet's shared NFS mounts.
  Fixed by wrapping each retry the same way the main queue does.
- **Remux-shortcut false success**: retrying an HEVC/x265-sourced file
  through `try_av1_convert` could fall back into `try_x265_convert`'s
  HEVC-MKV stream-copy remux shortcut on AV1 rejection, "succeeding" by
  repackaging the same bytes instead of actually re-encoding. Fixed by
  checking the file's actual codec first and forcing `force_transcode=true`
  for the HEVC/x265 cohort, matching the precedent already set by
  `process_existing_x265`'s own x265-decision branch.
- **Counter pollution**: the season shrink/tested counters originally
  incremented for *any* kept TV conversion (fresh first-time encodes, disc
  sources, plain remuxes), not just outcomes of the actual sample-test
  decision, which could cross the 60% threshold from unrelated work. Fixed
  with a `SEASON_SAMPLE_DECISION_CONTEXT` guard flag, set only around the
  av1/x265 case branches in `process_existing_av1`/`process_existing_x265`.
- **`S1E01` vs `S01E01`**: the season number wasn't zero-padded, so the same
  season could split across two keys. Fixed with a forced base-10 `%02d`
  normalization.

## v5.0.32Q — 2026-07-22

Two things landed together: (1) a new upfront audio/subtitle-truncation
check, prompted by Dune (2021) — its source's audio track was genuinely
short, but this wasn't caught until AFTER a full ~2-hour real AV1 encode,
because the existing truncation check only ran post-encode; (2) a
comprehensive CRITICAL production-readiness pass — a full 4-way team review
(both halves of the ~12,700-line file) ahead of turning this
loose unattended across ~200TB, followed by two more verification rounds on
the fixes. Every finding below was confirmed via direct bash testing before
being fixed, not taken on the reviewers' word alone (which also correctly
ruled out a few false positives — see below).

**Audio/subtitle upfront validation:**
- `validate_source_media()` now runs the same audio-truncation check that
  previously only ran post-encode, so a truncated source is caught and
  deferred for human review before an expensive real encode is ever
  attempted.
- New `validate_mkv_subtitle_tracks()` — NOT true dialogue-timing-accuracy
  verification (infeasible cheaply, needs OCR/speech analysis), a coverage/
  truncation check: does the primary subtitle track have any cue in the
  film's last 25% of runtime. Went through 2 redesigns after team review
  found the first version unsafe to ship: it did a full unseeked file scan
  (defeating "cheap by design" and risking timeout-during-scan
  misclassified as truncation) and used an unreliable cue-count heuristic
  that would false-positive on real forced/sign-only subtitle tracks.
  Redesigned to use the same bounded near-EOF seek as the audio check, plus
  asking ffprobe's own `disposition:forced` flag directly instead of
  guessing from cue density.

**The single biggest finding, confirmed via direct bash testing:** a bare
command (or command substitution) that fails, followed on the next line by
code reading `$?` or `${PIPESTATUS[0]}`, aborts the ENTIRE script right at
the failing line under `set -e` — the line reading the exit code never
runs. This is fundamentally different from `A && B` (where A's failure is
exempt); a bare unprotected statement has no such exemption. Fixed
everywhere by replacing the bare-then-read-next-line pattern with
`x="$(cmd)" && rc=0 || rc=$?` (or a trailing `|| true` where the code isn't
needed) — exempt from `set -e` because it's part of an `&&`/`||` list, while
still capturing the real exit code. This affected:
- All 3 of the audio/subtitle validation functions above — their careful
  timeout-vs-real-failure distinction logic was unreachable dead code.
- 4 pre-existing encoder-dispatch functions (`ffmpeg_encode_hw`,
  `handbrake_encode`, `vaapi_hevc_encode`, `remux_copy_to_mkv`) using a bare
  `cmd; local rc=$?` pattern.
- Encoder-version fingerprint parsing (`current_svtav1_major_minor`,
  `current_x265_major_minor`) — a fleet-wide single point of failure if a
  future encoder build ever changes its version-banner text.
- 12 call sites of `mkv_structure_stat_key`/`dir_subtree_max_mtime` that
  would crash if a file vanished or `stat` failed between being listed and
  being checked — routine at fleet scale.

**Other confirmed bugs fixed:**
- **Must-eliminate tie-break could mark a source done with no valid output
  anywhere** (`try_x265_convert`): an unchecked `mv` of a stashed AV1
  candidate into its canonical path could fail (NFS glitch), leaving neither
  AV1 nor x265 in place, while `record_conversion_result` unconditionally
  marks the source permanently done regardless of whether the output
  actually exists. Fixed by checking the `mv`'s success and falling back to
  the already-validated x265 output if the move fails.
- **Lock released before source mutation completes** (`tag_preexisting_
  desired_format`): `clear_in_progress_flag` ran BEFORE the `mkvpropedit`
  tag rewrite, letting a concurrent fleet machine see the source as
  unlocked and start its own work while the same NFS-shared file was still
  being rewritten. Fixed by reordering.
- **Completed encode silently discarded on a transient copy failure**
  (`finalize_staged_encode_output`): a failed `cp` to the final NFS
  destination (disk full, transient I/O error) deleted the staged file —
  potentially hours of work — unlike the sibling `mv`-failure branch, which
  already preserved it for recovery. Fixed to match.
- **One filename collision could kill an entire unattended organize pass**
  (`organize_library`): `organize_movie_entry` legitimately returns 1 on a
  destination collision, but the bare (unprotected) call in the for-loop
  meant that single failure aborted the whole script under `set -e` — not
  just that one file — confirmed via direct bash testing that a bare
  failing command inside a for-loop body kills the entire script. Fixed
  with `|| warn ...`.
- **Missing timeout on post-encode decode validation** (`validate_mkv_
  decode_windows`): unlike every other validation helper (ffprobe/mkvmerge/
  mkvalidator), its ffmpeg decode-window probes had no timeout — a `-t`
  argument bounds decoded output duration, not wall-clock time, so a
  stalled NFS read could hang a machine indefinitely. Fixed with a new
  `run_ffmpeg_validation()` wrapper, with proper timeout-vs-real-failure
  distinction added (a timeout must never be misread as confirmed decode
  corruption).

**False positives ruled out** (claimed by the initial review, disproven via
direct bash testing, left unchanged): bare `[ cond ] && simple_assignment`
patterns (e.g. `[ "$ok" = false ] && status=failed`) do NOT trigger `set -e`
when cond is false — a non-final command in an `&&`/`||` list is exempt
regardless of whether it actually executes.

**Deliberately deferred** (lower severity, noted for a future pass): no
heartbeat refresh on the in-progress lock during long HandBrake disc
encodes (only ffmpeg encodes refresh it); a must-eliminate AV1 candidate
stash can be leaked (not corrupted) if x265's own validation times out;
`run_mkvpropedit` still has no timeout; the disc AV1 encoder bake-off scores
SSIM against a clip that's never created for a HandBrake-title source
(wrong encoder choice, not data loss); done-log appends from multiple
fleet machines on NFS aren't guaranteed atomic (could produce a garbled
line, not data loss).

## v5.0.32P — 2026-07-22

Adds must-eliminate-format handling and a `Deferred/` human-review folder,
per explicit new requirements: some source formats (disc images, raw
transport streams, legacy containers) need to be eliminated regardless of
whether re-encoding actually shrinks them, and files that can't be salvaged
by a cheap fix need to stay visible to Plex/Sonarr instead of disappearing
into a log. Reviewed E2E by two independent reviewers across three rounds; the first
round caught a showstopper (below) that the initial implementation missed
entirely.

- **`is_must_eliminate_format()`** (new) — true for disc/BDMV sources and for
  `.ts`/`.m2ts`/`.vob`/`.avi`/`.ogm` containers regardless of the codec they
  hold. These formats are the actual problem (poor seekability/compatibility,
  a disc image nobody can play directly), so eliminating the format matters
  more than the normal size-keep guardrail.
- **Size-guardrail bypass + AV1/x265 tie-break for must-eliminate sources.**
  Previously, if both a fresh AV1 and fallback x265 encode came out larger
  than the size cap allows, `try_x265_convert` rejected both and left the
  original in place — for an ISO/.ts/.avi/.ogm source, that means the
  undesirable format never gets eliminated. `try_av1_convert` now stashes an
  oversized AV1 candidate (`MUST_ELIMINATE_AV1_CANDIDATE`/`_SIZE`) instead of
  deleting it when the source is a must-eliminate format; `try_x265_convert`
  tie-breaks between the two oversized candidates before falling through to
  its normal reject-and-keep-original path: within `MUST_ELIMINATE_TIE_PCT`
  (5%) of each other, AV1 wins; otherwise whichever is smaller wins. If x265
  itself fails outright (encode or validation failure) for a must-eliminate
  source, `must_eliminate_fallback_or_fail()` salvages the stashed oversized
  AV1 candidate rather than giving up. Codec-in-bad-container sources
  (e.g. HEVC inside an `.avi`) were already handled — `process_existing_av1`/
  `process_existing_x265` unconditionally remux non-mkv containers before any
  sample-testing — this only closes the gap for fresh/inefficient-codec
  sources that go through `try_av1_convert`/`try_x265_convert` directly.
- **`Deferred/` subfolder for human review.** `flag_bad_source_for_human()`
  now physically moves the flagged file into a `Deferred/` subdirectory next
  to its siblings (collision-avoided with a UTC timestamp prefix; skipped for
  dry-run and disk sources, which can't be moved) instead of leaving it in
  place and only logging it — the intent is a folder that's still visible to
  Plex/Sonarr but easy to search for files needing manual intervention. All
  directory-enumeration `find` calls (`get_scan_roots()`, twice, and
  `find_convert_videos_under_cached()`) now exclude `Deferred` by name so a
  parked file can't be rediscovered and reprocessed in a loop.
- Corruption/integrity checking already ran before any codec/format decision
  (`validate_source_media()` gates `process_video()` before the codec
  branch), including its existing remux-repair-first, flag-for-human-if-that-
  fails behavior — confirmed already correct, no change needed there.

**Bugs caught by team review, before this ever reached the fleet:**

- **Showstopper (both reviewers, independently): the stash defeated itself.**
  The oversized AV1 candidate was originally stashed at its own canonical
  `av1_output_path` — the exact path `try_x265_convert`'s own
  `skip_if_complete_canonical_output` check looks for first thing. It matched
  immediately, `try_x265_convert` returned 0 without ever running x265 or the
  tie-break, and the stash was left on disk forever, unfinalized. Fixed by
  stashing under a non-canonical `${out}.must_eliminate_stash` name instead,
  moved back to the canonical path via `mv -f` only once actually chosen as
  the winner; `try_av1_convert`'s entry does an idempotent `rm -f` of any
  orphaned stash from a prior aborted run of the same source.
- **Oversized x265 with no AV1 stash still got rejected.** If AV1 failed
  outright (not just oversized — nothing to tie-break against), a must-
  eliminate source's oversized x265 fell through to the normal reject path
  and the undesirable format was never eliminated. Added a bypass block
  right after the tie-break so a must-eliminate source keeps its oversized
  x265 unconditionally when there's no AV1 candidate to compare against.
- **Double outright failure never reached `Deferred/`.** If both AV1 and
  x265 genuinely failed to encode/validate (not merely oversized) for a
  must-eliminate source, nothing called `flag_bad_source_for_human` — the
  bad format sat in place forever with no path forward. `must_eliminate_
  fallback_or_fail()` now flags it, scoped so an ordinary source failing
  both encoders is unaffected (still just retried later, as before).
- **Division-by-zero risk in the tie-break math.** The awk percentage-delta
  calculation divided by the stashed AV1 size with no zero-guard, which
  would abort the whole script under `set -e` on mawk/BSD awk if that size
  were ever empty or zero. Added an explicit guard that discards the stash
  and keeps x265 in that case instead of crashing.
- **`Deferred/` exclusion was incomplete.** The top-level shard-root find
  calls excluded `Deferred` by name, but 5 other recursive `find` calls
  didn't: `find_convert_videos_under_cached()`'s no-subdirectory fallback
  and its per-subdirectory scan, plus `find_videos_under()`,
  `find_isos_under()`, and `find_bluray_roots_under()`. Any of these could
  have walked into a `Deferred/` folder and re-queued a parked file forever.
  Added `! -path '*/Deferred/*'` to all 5.
- **Cross-title global leak (one reviewer, second round).** The two globals used
  to pass the stashed candidate from `try_av1_convert` to `try_x265_convert`
  aren't cleared on every return path (deliberately — the validation-timeout
  "leave in place for retry" paths don't touch them). That reviewer correctly
  pointed out that an unrelated later title entering `try_x265_convert`
  directly (via `process_existing_av1`/`process_existing_x265`'s sample-
  decision path, bypassing `try_av1_convert`'s entry-reset) could delete or
  wrongly tie-break against an earlier title's still-pending stash. Fixed by
  making every consumption/deletion site verify ownership first — it only
  acts if the global's value exactly matches `$(av1_output_path "$src").
  must_eliminate_stash` for the *current* source — so a foreign candidate is
  now left completely untouched everywhere instead of merely "usually"
  untouched. Confirmed by a follow-up verification pass from that reviewer.

## v5.0.32O — 2026-07-22

Replaces HandBrake with direct ffmpeg calls in the AV1-vs-x265 shrink-prediction
sample-encode path, and fixes several real correctness bugs surfaced along the way.
Prompted by a fleet HandBrake-version-compatibility crash discovered testing
v5.0.32I: older stable HandBrakeCLI builds (1.9.0 on Plex, 1.11.0 on AI-PROCESSOR)
silently failed to open ffmpeg `-c copy`-extracted sample clips at all
(`unrecognized file type`), corrupting the sample decision into a false "test
failed" skip with zero diagnostic detail. Reviewed across two rounds by two
independent reviewers (a third reviewer failed to spawn both rounds — infra issue, not a review
finding).

- **HandBrake removed from the sample-encode path.** New `ffmpeg_sample_encode()`
  reuses the real (non-sample) encode's own `determine_hdr_mode()` /
  `build_ffmpeg_video_args()` for HDR/color-metadata handling — the same
  machinery `determine_hdr_mode`'s own comments describe being shaped by "the
  original tint bug" — so the sample can't diverge from the real encode's
  color handling. `encode_sample_av1`/`encode_sample_x265` are now thin
  wrappers around it. Sample-encode call sites never touch disc/ISO/Blu-ray
  sources (`av1_source_reencode_sample_decision` has no disc/title parameter),
  so this has zero effect on disc handling, which still goes through
  HandBrake via the separate `handbrake_encode()` function.
- **CRF alignment.** The sample now calls `resolve_crf_for_encode()` — the
  same VMAF-targeted search the real SDR encode uses — instead of a generic
  fixed CRF. The old fixed-CRF sample (true of the prior HandBrake sample too,
  not new to this change) could land several CRF points below what a real SDR
  encode's VMAF search would choose, systematically under-predicting how much
  a file would shrink and permanently VES-tagging/done-logging files that
  would have genuinely benefited from AV1 — exactly the false-negative-skip
  risk this sample test exists to avoid. HDR sources are unaffected (both
  paths already used the same fixed CRF for HDR). The VMAF search result is
  cached (`VMAF_CRF_CACHE`) and reused verbatim if a real encode of the same
  file follows, so this doesn't pay the search cost twice.
- **Stream-mapping fix.** Clip extraction previously used `-map 0`, pulling
  global attachments (cover art, embedded fonts) into the clip regardless of
  clip length, while the sample encode itself never mapped attachments —
  inflating the clip-size side of the encoded/clip ratio without a matching
  inflation on the encoded side, corrupting the extrapolated full-file size
  prediction on titles with a large attachment set. Clip extraction now maps
  video/audio/subs only; the sample encode now also copies subs, so its track
  composition matches both the clip and what a real encode actually mixes in.
- **`hdr_mode=unknown` and Dolby Vision profile 5 (no libplacebo) now fail
  closed and flag the source for human review**, matching the real encode's
  behavior, instead of silently retrying forever with no trace in either
  `bad_sources.txt` or the done-log.
- **Two real `set -e` bugs fixed in production `ffmpeg_encode()`** (the real,
  non-sample encode path): its retry-without-subtitles fallback used a bare
  `run_tracked_encoder ...; rc=$?` with no `||` guard — under this script's
  `set -e`, a real ffmpeg failure would abort the entire script immediately
  instead of triggering the intended graceful retry. Also fixed 4 occurrences
  of a related `[ "$acodec" = libopus ] && args+=(...)` pattern (bare
  compound with no trailing `||`) that had the same abort risk whenever
  `acodec` wasn't literally `libopus` (always true for x265 sample/real
  encodes, and for AV1 on any ffmpeg build without libopus).
- **Multi-point complexity sampling.** New `find_complexity_sample_points()`
  picks 3 representative points (low/median/high local bitrate, a free
  encoder-already-computed proxy for scene complexity/motion) instead of one
  arbitrary mid-file cut, which could land on a uniquely quiet or uniquely
  busy scene and skew the prediction either way. Uses `ffprobe -read_intervals`
  to sparsely probe ~15 short (10s) windows spread across the usable duration
  (excluding the first/last 3 minutes as likely credits) rather than a
  continuous full-file packet scan — measured 3+ minutes and still incomplete
  for a naive full scan on a 7GB 4K title over this fleet's NFS, vs ~8s for 32
  sparse windows across a full 2h42m movie. `av1_source_reencode_sample_decision`
  now extracts and encodes at each found point, averaging the 3 extrapolated
  full-file predictions (falls back to one mid-file sample if the complexity
  scan fails or the source is too short to usefully split).
- **Real bug found via live testing, not static review:** a `printf -v`
  variable-name collision. `ffmpeg_sample_encode()` passed the literal string
  `"crf"` as `resolve_crf_for_encode()`'s output-variable name — but
  `resolve_crf_for_encode()` has its own local variable of that exact name,
  and bash resolves `printf -v`/nameref writes to the innermost scope with a
  matching name, so the write silently landed on `resolve_crf_for_encode`'s
  own local instead of the caller's. The caller's `$crf` was left permanently
  unbound; under this script's `set -u`, the very next reference to it (the
  `build_ffmpeg_video_args` call) killed the current subshell outright — no
  graceful nonzero return, no diagnostic, nothing, which is what made this so
  hard to pin down live (initially misdiagnosed as several different `set -e`
  patterns, none of which were the actual cause; confirmed the real mechanism
  only by isolating the crash on a local ramdisk copy with fully-cleared
  sidecar state, ruling out NFS/caching artifacts, then sending the live
  reproduction — not just a code read — to team review). Fixed by using a
  distinctly-named `resolved_crf` local, mirroring how `ffmpeg_encode()`
  already avoids this correctly.

## v5.0.32I — 2026-07-22

Critical silent-data-loss bug found during a fleet-wide real-NAS re-test of
v5.0.32H: a movie folder containing exactly one subfolder (e.g. a
`Featurettes/` extras directory) alongside the main movie file caused the
main movie file to be **silently skipped entirely** — no log entry, no
skip-reason, nothing. Only the subfolder's files got processed. Confirmed
live on AI-PROCESSOR: Oppenheimer (2023)'s 11.4GB main file was never
touched (no VES tag, no `convert-v5.done` entry, no log mention) while its
`Featurettes/` files were processed normally. Reviewed by two independent
reviewers (a third reviewer failed to spawn — infra issue, not a review finding); both
independently confirmed the diagnosis and found the same broken pattern
duplicated across more call sites than the one first found.

- **Root cause.** `get_scan_roots()` returns only real subdirectories at
  `$SHARD_DEPTH` under `$SEARCH_PATH` when any exist — it never includes
  `$SEARCH_PATH` itself in that case, only falling back to
  `roots=("$SEARCH_PATH")` when zero subdirectories are found. Every
  scanning function that iterates `roots` as shards also needs a separate
  pass over `$SEARCH_PATH` itself to catch loose files sitting directly in
  it (the main movie file, sibling to the extras subfolder) — but that
  extra pass was gated on `shard_total -gt 1` everywhere it appeared.
  With exactly one real subfolder (`shard_total == 1`), the gate is false,
  so the loose top-level file is in neither the subfolder shard (it's not
  under the subfolder) nor caught by the root pass (gate closed) —
  vanishing from discovery with zero trace.
- **Fix.** New helper `roots_need_catchup_scan()` (added right after
  `get_scan_roots()`): true when `roots` holds real subdirectories rather
  than the zero-subdirectory `("$SEARCH_PATH")` fallback, regardless of
  count. Replaces the broken `[ "$NO_SHARD" = false ] && [ "$shard_total"
  -gt 1 ]` (or `${#roots[@]} -gt 1`) condition at all 7 real call sites
  that gated a root-level catch-up scan: `build_shard_snapshot`,
  `discover_disk_sources` (ISO/Blu-ray discovery), `organize_library`,
  `inspect_library`, `convert_estimate_scan_total` (batch-vs-pipeline mode
  selection), `convert_scan_producer` (pipeline mode), and
  `convert_library_batch` (the one that dropped Oppenheimer). A further
  ~12 occurrences of the same `-gt 1` text elsewhere are cosmetic
  shard-log formatting/looping guards, not this bug, and were left
  unchanged.

## v5.0.32A — 2026-07-18

Follow-on to v5.0.32, closing a gap found during fleet re-testing: an
already-encoded library file with no naming-convention marker (not one of
our own `*.AV1.mkv`/`*.x265.mkv` outputs) would repeat the same ~4-minute
sample-test on every scan forever, with no way to remember "no benefit."
x265 sources additionally had **no** re-consideration logic at all — once a
file was x265, it got a full real AV1 re-encode attempt on every scan,
protected only by the post-hoc size guardrail. Reviewed through two rounds
by three independent reviewers; both rounds caught real, independently
confirmed bugs, all fixed and verified before release.

- **Preexisting-desired-format tagging.** New tag value `VES <version>
  Processed - Preexisting Desired Format`, written via the same
  `_mkv_write_single_tag` helper as the guardrail-exceeded tag. Applied
  whenever a source is determined to already be optimal: a small AV1/x265
  source under its size gate, or a sample-test explicitly predicting no
  size win.
- **Codec-specific size gates.** AV1 sources ≤300MB and x265 sources
  ≤250MB skip the sample-test entirely and get tagged immediately
  (`PREEXISTING_SMALL_SKIP_MAX_MB`, `PREEXISTING_X265_SMALL_SKIP_MAX_MB`).
  Gated to `ext == mkv && ! is_derived_output` only — a real correctness
  bug from the first review round: applying the gate to non-MKV sources or
  derived outputs would have skipped required container-unification remuxes
  and wiped VMAF tags off derived outputs queued for a legitimate oversized
  recheck.
- **New `process_existing_x265()`.** x265 sources above their size gate are
  now sample-tested (reusing the same codec-agnostic
  `av1_source_reencode_sample_decision` primitive as the AV1-source path)
  for whether AV1 — or a fresh x265 pass — would shrink the file further,
  rather than committing straight to a full real re-encode attempt.
- **Container unification for x265 sources.** Any non-MKV x265 source
  (`.mp4`, `.ts`, etc.) is now unconditionally remuxed to `.x265.mkv`
  before any sample-testing, mirroring the AV1-source path's existing
  non-MKV handling — the project's container-unification goal (everything
  ends up `.mkv`) doesn't depend on whether re-encoding would help.
- **`force_transcode` fix for `try_x265_convert`.** A second real bug from
  the first review round: `process_existing_x265`'s `x265` sample decision
  (predicting a fresh x265 pass would shrink an already-HEVC `.mkv` source)
  called `try_x265_convert` directly, which for an ordinary HEVC `.mkv`
  input immediately took the existing stream-copy remux shortcut —
  producing a same-size remux instead of the predicted real re-encode, then
  silently marking it done. Fixed with a new `force_transcode` parameter
  that bypasses the remux shortcut only when the caller has already decided
  a real transcode is warranted; all three pre-existing call sites default
  to `false` and are unaffected.
- **NVDEC sample-encode fix (shared machinery, found on docm).** HandBrake's
  NVDEC hardware decoder can choke on a `-ss`+`-c copy`-extracted sample
  clip's irregular timestamps (a B-frame-reordering artifact at the cut
  boundary), breaking the muxer. Confirmed via direct reproduction (HandBrake
  exit 4, `av_interleaved_write_frame failed`) and fixed by adding a
  `no_hw_decode` option to `build_handbrake_args`, used only by the two
  sample-encode functions (`encode_sample_av1`/`encode_sample_x265`) — real
  full-length encodes are unaffected, and decode speed doesn't matter for a
  short sample anyway. This is pre-existing shared code (the same
  clip-extraction path the AV1-source sample-test already used); the new
  x265 feature simply exercised it for the first time on docm's NVENC setup.

## v5.0.32 — 2026-07-17

Follow-on fixes/features surfaced while fleet-testing v5.0.31F's seven-profile
system.

- **Size-tiered upscale-overshoot guardrail.** The upscale acceptance cap
  (`UPSCALE_MAX_OVERSHOOT_PCT`, default 50%) is now tiered by the *original*
  file's size, since a fixed container/audio/metadata overhead dominates a
  small file's overshoot percentage far more than a large one: ≤120MB gets up
  to 100% growth, ≤1200MB gets up to 65%, >1200MB keeps the original 50%
  (`UPSCALE_OVERSHOOT_SMALL_MAX_MB`/`_PCT`, `_MED_MAX_MB`/`_PCT`,
  `UPSCALE_MAX_OVERSHOOT_PCT`). Non-upscale thresholds (AV1 20%, x265 5%) are
  unchanged. Motivated by a live fleet test (PRINCE, VTV profile, 17.29MB
  480p source) where both AV1 and x265 candidates were correctly rejected
  after a 1080p upscale, but the fixed 50% cap left no headroom for how a
  tiny source's fixed overhead dominates its overshoot %.
- **Display/formula consistency fix.** The AV1/x265 rejection warnings
  previously computed `(new/original)*100` ("% of original") but labeled it
  as "...% larger", producing misleading numbers (e.g. a 157.8%-of-original
  result shown next to ">20% larger"). All four rejection warnings now
  consistently compute and show true overshoot `((new-original)/original)*100`;
  the "Kept" messages (which correctly say "% of original") are unchanged.
  The x265 non-upscale rejection now also shows its percentage (previously
  showed none).
- **Embedded MKV processed-tag.** Every finalized output gets a native
  Matroska Tags-element marker (`VES_PROCESSED`) — distinct from track
  properties (Name/Language/flags) and the Segment Info title, so it survives
  renames/relocations that would defeat the folder done-log or filename
  convention. `mkvpropedit --tags all: --tags global:...` clears every
  pre-existing Tags scope (global + per-track + chapters) in the same command
  before writing ours, leaving subtitle/audio track labels and playback-
  affecting properties untouched. Tag value is `VES <version> processed`,
  plus a sampled VMAF score comparing the actual output to the actual source
  (`measure_final_vmaf`/`_vmaf_compare_clips` — a handful of short matched-
  timestamp clips scored via libvmaf, not a re-encode), and — only when the
  source was upscaled — the output resolution and "upscaled" ahead of the
  VMAF number. A metadata-only re-tag of an already-AV1 file (no fresh
  transcode this run) gets just the base tag, no quality readout, since
  there's nothing new to measure. On scan, a cheap `ffprobe`-based read-check
  skips re-processing any `.mkv` already carrying a tag for the current major
  version — a second, path-independent signal alongside the done-log and
  derived-output naming convention.

## v5.0.31F — 2026-07-17

Two independent workstreams landed together: eliminating orphaned encoder
processes (the trigger was a live orphaned ffmpeg process found competing for
CPU during a fleet performance test) and replacing the fixed five-profile
encoding system with a seven-profile system matching a real library
reorganization. Reviewed throughout by multiple independent reviewers,
each round re-verified directly against the code
before being accepted — several real, confirmed bugs were caught this way and
are called out below rather than presented as a clean first pass.

**Orphan-process hardening:**

- **Kill the in-flight encoder on signal/error.** Every full encode/remux
  subprocess (ffmpeg primary + subtitle-retry, hardware ffmpeg, AMD VAAPI,
  stream-copy remux, streaming-optimization mkvmerge remux) now runs through
  a tracked background child (`run_tracked_encoder()`), so `INT`/`TERM`/`ERR`
  can terminate the in-flight process by PID instead of it becoming orphaned
  when only the parent script dies. The `.convert-v4.IN_PROGRESS` flag gains
  `encoder_pid=`, `encoder_started_utc=`, and `encoder_fingerprint=` fields —
  the previous `pid=` field is the *script's* own PID, not the encoder's, and
  was never usable for this. HandBrake's progress-piped path (which
  previously made the encoder's real PID unobservable behind an `awk` pipe)
  now runs through a private `.convert-hbprog-*` FIFO directory instead, so
  its real PID is trackable the same way.
- **Startup orphan reaper.** On every normal invocation (opt out with
  `--no-auto-reap`), the script now walks same-host `.convert-v4.IN_PROGRESS`
  flags and staging directories left behind by a prior hard crash, safely
  identifies genuine orphans (script PID confirmed dead, encoder PID
  confirmed alive and identity-verified — command name plus a start-time
  cross-check, so a reused PID is never mistaken for the original encoder),
  and terminates them. A killed orphan's generated output is validated
  through a 4-gate sequence (source/candidate provenance → stable-size check
  → tight duration match → fast Matroska structure check → a short tail
  decode) before being either salvaged through the normal finalize path (if
  it turns out to be complete) or deleted (if not) — the original source file
  is never at risk under any code path.
- **Defensive cleanup for an already-closed failure path.** `ffmpeg_encode()`
  gained a defensive cleanup branch for a direct-write failure case that a
  reachability test confirmed is unreachable in the current code (staging
  setup already fails closed) — kept as cheap insurance against a future
  change reopening that gap, not because it fixes a live bug.
- **Timeout guards on validation subprocesses.** `run_ffprobe`,
  `run_mkvmerge`, `run_mkvalidator`, and the fast EBML-bounds check now run
  through a portable timeout wrapper (`VALIDATION_TIMEOUT_SECS`, default
  120s) that works even without GNU coreutils' `timeout`/`gtimeout` (a
  background-process-plus-poll fallback bounds the call instead). A timeout
  is never treated as confirmed corruption — earlier drafts of this change
  had callers still deleting a processed output or permanently recording a
  source skip on a mere probe timeout (e.g. a stalled network mount); this
  was caught in review and fixed so a timeout now leaves the file/source in
  place for retry on the next run instead.

**Seven-profile encoding system**, replacing the previous
`movie`/`tv`/`anime`/`wanime`/`vintage` set:

- **WANIME** — western animation (2D/3D, including Chinese CG), movies and TV.
- **ANIME** — Japanese anime (`Movies/Anime/`, unambiguous).
- **MOVIES** — general-purpose live-action (`Movies/<Language>/Modern/`).
- **CLASSIC** — a real, distinct middle tier between MOVIES and VINTAGE
  (`Movies/<Language>/Classic/`), light grain synthesis rather than a naive
  average of its neighbors.
- **VINTAGE** — older films, heavier grain, possibly B&W
  (`Movies/<Language>/Vintage/`).
- **MTV** — TV's equivalent of MOVIES (`Television/<Country>/Modern/`).
- **VTV** — TV's equivalent of VINTAGE (`Television/<Country>/Vintage/`),
  deliberately *not* tuned like VINTAGE — old TV's analog videotape noise
  isn't photochemical film grain, so VTV skips x265's `tune=grain` in favor
  of a bespoke low-motion/frequent-scene-cut parameter set.

All seven are path-auto-detected from the library's existing folder
structure, with one deliberate exception: `Movies/Japanese/Animation/` is
genuinely ambiguous (some Japanese animated movies use anime style, others
western style) and requires an explicit `--profile` flag rather than a
guess. Sample-search and final-encode share each profile's complete
parameter string (preserving the v5.0.29 fix against them drifting apart).
Sub-720p sources now get a two-stage upscale decision instead of an
unconditional 1080p upscale: a cheap metadata heuristic first (display
resolution, bits-per-pixel-per-frame), falling back to a real 720p-vs-1080p
sample encode scored via VMAF only when the heuristic is genuinely
uncertain — the selected output resolution is part of the CRF-search cache
key so it can't be silently reused across a different resolution decision.
The metadata heuristic itself now fails closed to a conservative height-only
decision when the underlying `ffprobe` metadata call fails or times out
(e.g. a stalled network mount), rather than falling through into the sample
encode — that path runs several full ffmpeg subprocesses with no timeout
guard of their own, and would otherwise reintroduce exactly the kind of
indefinite hang this release's timeout-guard work exists to eliminate.

**Final-release review note**: this version's log/comment text originally
carried over a real internal IP address and a real fleet hostname from an
intermediate development copy — caught in review before release and
replaced with documentation-safe placeholders. No script logic was affected.

## Documentation — 2026-07-17

No script behavior changed in this entry — `convert-v5.0.30.sh` remains the current
release. Added a new README section, **"Optional: distributing the script across
multiple machines,"** documenting an rsync-daemon-based pattern for keeping the
script in sync and pulling logs across a multi-machine setup, plus a set of
host/OS-level environment gotchas discovered while building and testing one:
SELinux (`Enforcing` mode) blocking a confined rsync daemon from executing hook
scripts — with a **false-positive symptom worth calling out specifically**: the
push can report success while the server-side hook silently never ran at all,
since a naive check only confirms "the marker says the right version," not "the
promotion actually just happened" — WSL2 mirrored-networking's separate Hyper-V
firewall layer, hostnames resolving IPv6 before IPv4 defeating an IPv4-only ACL,
and macOS's built-in rsync lacking full daemon support. None of this is required
reading to use the script itself — it's only relevant if you build something
similar for your own multi-machine setup.

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
     surveyed (the primary workstation, WSL-LAPTOP, FEDORA-LAPTOP all already have a
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
  real end-to-end encodes on both the primary workstation (Linux, discovered
  `/tmp`) and MAC-HOST (macOS, created-and-torn-down RAM disk)
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
  workstation, WSL-LAPTOP, MAC-HOST, FEDORA-LAPTOP, Plex) surfaced two follow-on items,
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

## v5.0.30 — mkvalidator stalls indefinitely on large (20GB+) files

  Running a fleet-wide performance test (6 machines, each encoding a unique
  large ~20-27GB movie in parallel) surfaced a real bug: four of the six
  machines (workstation, MAC-HOST, FEDORA-LAPTOP, WSL-LAPTOP — every one that had
  mkvalidator installed) appeared stuck for 15+ minutes with no encode
  progress. Investigation found `mkvalidator --quiet --no-warn` in a D-state
  (uninterruptible I/O wait), reading the source file via extremely small
  sequential reads — roughly 700 bytes per syscall, ~170KB/s effective
  throughput observed via `/proc/<pid>/io`. At that rate a 20GB file would
  take on the order of 35 hours to validate, before any encoding could even
  start. Machines without mkvalidator installed (LINUX-VM-1, LINUX-VM-2, Plex
  at the time) were unaffected, since `validate_source_media()`/
  `validate_mkv_structure()` already fall back to the fast EBML/segment-bounds
  check alone when the binary is absent — the bug only bites when mkvalidator
  is present and the file is very large.

  Fixed with a new `MKVALIDATOR_MAX_SIZE_BYTES` threshold (default 5 GiB,
  `CONVERT_MKVALIDATOR_MAX_SIZE` env-overridable): above the threshold,
  mkvalidator is skipped entirely and the EBML/segment-bounds check (which
  already runs first, unconditionally, and is exactly what's relied on when
  mkvalidator isn't installed) is treated as sufficient — logged clearly
  rather than silently skipped. Applied at all three call sites that invoke
  mkvalidator: `validate_source_media()`'s source-encode-time check, the
  remux-repair verification path in `attempt_source_mkv_structure_remux()`,
  and `validate_mkv_structure()`'s output-side check. This means mkvalidator
  can stay installed fleet-wide (the user's stated preference — "mkvalidator
  should be on all computers in the fleet") without breaking on large movie
  libraries; TV episodes and anything else under the threshold get exactly
  the same full structural validation as before.

  Verified with a standalone threshold-logic test (a sparse 1GB file runs
  mkvalidator normally; a sparse 6GB file is correctly skipped and falls back
  to EBML-bounds-only) and `bash -n`.

  *(v5.0.30)*

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
