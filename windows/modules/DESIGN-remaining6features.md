# Design: 6 remaining bash features not yet ported to Windows

Draft for team review (Gemini/Codex/Cursor, advisory-only) before
implementation. Companion to `DESIGN-phase3-6features.md` (the prior
6-feature batch: RAM disk, orphan reaper, resume-state, sharded scan,
HandBrake/hw-detect, title-lock coordination — all shipped and verified).
This batch: organize phase, pipeline-vs-batch dual mode, season-retry
heuristic, Telegram notifications, disc-source (ISO/BDMV) handling, live
HandBrake progress. Bash reference throughout is `convert-v5.0.33S.sh`,
researched via a dedicated survey pass (function names/line numbers below
are accurate as of that survey, 2026-08-03).

Scoping decisions made with the user before drafting:
- **Season-retry**: build the tracking/retry logic only. It hooks into
  the same "sample-test predicts no size win" skip reason bash uses, but
  that predictive sample-test mechanism itself isn't ported to Windows
  yet (`convert.ps1` always goes straight to VMAF search + full encode).
  This module stays structurally correct but inert until that dependency
  exists — not a 7th feature in this pass.
- **Disc-source**: a real test fixture exists on the NAS (ISOs are
  present in the media library) — real end-to-end testing is in scope,
  not logic-only. (Locating a specific real file is in progress as of
  this draft; see the item's own section.)

## Two empirical spikes run before this draft, per this project's
## verify-before-designing convention

**Spike 1 — new-folder-then-write timing on the real NAS** (blocks
organize phase, which must create new movie folders). Prior Phase 2/3
work found freshly-created directories get a broken ACL (`Everyone: RX`
only) that even the creating session can't write into. Re-tested
directly against the real path organize phase would use
(`\\10.10.10.150\Media\Movies\English\Modern\...`): **immediate write
succeeded**, and `icacls` showed `MCE\docm:(F)` (explicit Full Control)
alongside the same `Everyone:(RX)` seen before. This is a genuine
discrepancy from the earlier finding, not a rerun of the same test —
flagged here rather than silently overwritten, and worth another look
if organize-phase testing hits the old failure mode on a different
path/share. Design proceeds treating direct create+write as workable
but wraps it in a retry-with-backoff (cheap insurance, matches the
defensive pattern used everywhere else in this port) rather than
assuming the discrepancy is fully understood.

**Spike 2 — synchronous incremental stdout read for live HandBrake
progress.** This project already found (`VesTrackedProcess.psm1`'s own
header) that `Register-ObjectEvent`-based async stream reading is
unreliable here — output silently reads back empty because it depends
on PowerShell's event queue being pumped, which a synchronous
`WaitForExit()` doesn't do. Tested whether a plain blocking
`$reader.ReadLine()` loop (no events at all) delivers lines
incrementally instead of only at process exit: **yes** — in a real
HandBrake run, early lines appeared at t≈680ms while the first
`Progress:` line appeared at t≈1500ms, spread across the full ~1.6s
runtime, not clustered at the end. Confirms the simple approach works;
no need for runspaces or named-pipe tricks for this specific problem.
(Stderr was drained concurrently via `ReadToEndAsync()` during this
spike — reading stdout synchronously without also draining stderr risks
the classic .NET Process deadlock if stderr's pipe buffer fills.)

---

## 1. Organize phase — `VesOrganize.psm1`

Bash reference: `organize_library()` (7201), `needs_flat_organize()`
(7114), `canonical_organize_title()` (3928), `organize_movie_entry()`
(7146), `is_movie_organize_parent()` (3951). TV content is entirely
excluded — organize only ever touches movies.

Functions:
- `Get-VesCanonicalOrganizeTitle -Title` — port of the sed year-
  parenthesize regex (`Title 1992` → `Title (1992)`; already-correct
  `Title (1992)` left untouched). Straightforward `-replace` with the
  equivalent .NET regex.
- `Test-VesIsTvEpisode -Path` / `Test-VesIsTvShowDirectory -Path` —
  needed as an explicit exclusion gate; check whether equivalent logic
  already exists anywhere in the ported modules (bash's
  `is_tv_episode`/season-number regex is also needed independently by
  item 3 below — share one implementation, don't duplicate).
- `Test-VesIsMovieOrganizeParent -Path` — shelf/letter-bucket dirs,
  language dirs, or the search root itself.
- `Test-VesNeedsFlatOrganize -Path` — port of the bash decision tree
  verbatim (already-correct check, year-parenthesize-only check,
  needs-subfolder check), same early-exclusion order as bash.
- `Invoke-VesOrganizeMovieEntry -Path` — the actual move: compute
  `$destDir`/`$destVideo`, create `$destDir` if needed (see Spike 1 —
  retry-with-backoff wrapper around create+move), refuse (warn, don't
  fail the whole run) on a destination collision, `[System.IO.File]::Move`
  the video (not `Move-Item`, matching this port's established .NET-API
  preference), then walk siblings in the original parent for subtitle
  files matching the same title and move those too (same collision-warn
  behavior, not a hard failure).
- `Invoke-VesOrganizeLibrary -SearchPath` — top-level loop: resolve scan
  roots (reuse `VesShardedScan.psm1`), enumerate videos, sort largest-
  first (matches bash's stated rationale — front-load the slowest/
  biggest moves first so a partial run still made the most impactful
  progress), skip derived outputs (already-organized/output files —
  needs a `Test-VesIsDerivedOutput` equivalent, likely just checking
  against this port's own `$OutputSuffix` convention), call
  `Invoke-VesOrganizeMovieEntry` per matching file, catching and logging
  (not aborting the run on) any single-file failure — matches bash's own
  inline comment about exactly this failure-isolation requirement.

**Open question for review**: should organize-phase failures feed into
the same per-run summary counters `convert.ps1` already prints at the
end (found/processed/ok/failed), or track separately since it's a
different kind of operation (move, not encode)? Leaning toward separate
counters since "failed to move" and "failed to encode" aren't
comparable outcomes.

---

## 2. Pipeline-vs-batch dual mode — `VesPipelineScan.psm1`

Bash reference: `convert_library_use_pipeline()` (14207),
`convert_library_pipeline()` (14605), `convert_scan_producer()` (14365),
`convert_run_pipeline_jobs()` (14533), `convert_pipeline_should_start_batch()`
(14509). This is a **large-library throughput optimization**, not a
behavioral difference — per the user's own framing, lower priority than
correctness-affecting features, but still real work.

Bash's mechanism: a background OS process continuously inspects/queues
files while the foreground encodes strictly one at a time in waves,
synchronized via plain files (a ready-queue file, a scan-done flag file,
a final-count file) — not shared memory, not a true message queue,
specifically because bash's process model makes files the natural IPC
primitive.

**Windows deviation, deliberate, not a mechanical translation**: bash's
background scanner is a separate OS process (`&`). The equivalent
Windows primitive is NOT `Start-Job` — this port's own
`VesSharedMutex.psm1` already documents that `Start-Job`-spawned children
hit a persistent Access-Denied writing to this NAS even under the same
Windows identity as the parent. Two real alternatives:
1. **PowerShell runspace** (`[runspacefactory]::CreateRunspace()`) — a
   background thread within the SAME process, not a separate child
   process, so it should not hit the Start-Job-specific NAS-access
   quirk (same process/session identity, no new process boundary) —
   but this is an assumption, not yet verified, and must be tested
   empirically before trusting it in production, per this project's own
   standing convention.
2. **A fully separate detached process** via the already-proven
   `VesDetachedExecution.psm1` (Scheduled Task-based) — heavier weight,
   but sidesteps the question entirely since it's the same mechanism
   already relied on for real remote job launches.

Proposed: build with a runspace first (simpler, matches bash's "same
machine, lightweight producer" spirit most closely) and include a real
empirical test that specifically writes to the NAS from inside the
runspace before this is trusted — exactly the kind of test that caught
the Start-Job problem in the first place. Fall back to option 2 if that
test fails.

Functions:
- `Start-VesScanProducer -SearchPath -ReadyQueuePath -ScanDonePath` —
  creates and opens a runspace running a scan loop that appends
  eligible file paths to the ready-queue file as it finds them (same
  atomic-append concerns as everywhere else on this NAS — likely reuse
  `VesSharedMutex.psm1`'s primitives rather than inventing new
  file-append logic).
- `Get-VesPipelineShouldStartBatch -PendingCount -ScanDone -BatchSize` —
  direct port of the bash gating logic (wait for a full batch, or flush
  a partial one once scanning is done).
- `Invoke-VesConvertLibraryPipeline` — orchestrates producer start,
  wave-pull-and-encode loop (reusing `convert.ps1`'s existing per-file
  job logic, not duplicating it), and producer teardown.
- Mode selection mirroring `convert_library_use_pipeline()`: forced
  pipeline flag, forced batch/largest-first flag, "is the search path a
  network share" check (Windows equivalent of `_path_on_cifs` — UNC
  path prefix check, or checked via `Get-PSDrive`/`Get-SmbMapping` if a
  mapped drive letter is used instead of a raw UNC path), else a fast
  pre-count against `PIPELINE_FILE_THRESHOLD`.

---

## 3. Season-retry shrink heuristic — `VesSeasonRetry.psm1`

Bash reference: `season_retry_pass()` (14766), `season_retry_key()`
(4231), `season_number_from_filename()` (4212), config
`SEASON_RETRY_THRESHOLD_PCT` (default 60).

**Scoped per user decision: tracking/retry logic only, inert until the
sample-test-prediction skip mechanism is ported.** Build now so it's
ready to wire in later, but be explicit in code comments that it
currently has no live trigger path in `convert.ps1`.

Functions:
- `Get-VesSeasonNumberFromFilename -Path` — regex port
  (`S(\d{1,2})[\s_.-]*E\d{1,3}`), returns `_unknown` on no match. Shares
  the TV-episode-detection regex with item 1's `Test-VesIsTvEpisode` —
  implement once, reference from both.
- `Get-VesSeasonRetryKey -Path` — `"<parent-dir>|<season-number>"` (a
  literal `|` separator is fine on Windows paths since `|` is an
  invalid filename character and can never appear inside a real
  directory name, so it's an unambiguous delimiter — bash needed the
  unit-separator trick specifically because `|` IS a valid Unix
  filename character).
- `$script:SeasonSampleTestedCount` / `$script:SeasonShrinkCount` /
  `$script:SeasonNoShrinkFiles` — hashtables, module-scoped state
  matching bash's associative arrays, reset per run.
- `Add-VesSeasonSampleResult -Path -Shrank` — called from wherever a
  sample-test-driven result is recorded (does not exist yet — this is
  the inert part); increments tested/shrink counts.
- `Add-VesSeasonNoShrinkPrediction -Path` — called from wherever a
  "sample predicts no size win" skip happens (also does not exist yet).
- `Invoke-VesSeasonRetryPass -FfmpegPath -FfprobePath ...` — the actual
  retry loop: for each key where `tested > 0` and at least one
  no-shrink-predicted file exists, compute `shrink/tested*100`, and if
  ≥ threshold, force-retry every such file through the real encode path
  (codec-routed: AV1 source → AV1 retry, else x265 retry with
  force-transcode), never re-tagging on failure (a non-zero result can
  be transient, not a confirmed size loss — matches bash's own stated
  reasoning and this project's "ambiguous is not confirmed" invariant).

---

## 4. Telegram notifications — `VesTelegram.psm1`

Bash reference: `notify_telegram()` (1024), call sites in
`end_convert_job()` (3085-3118) only. Config: `TELEGRAM_BOT_TOKEN`/
`TELEGRAM_CHAT_ID` — bash deliberately has **no CLI flag** for these
(a flag value is visible to any local user via `ps aux`; an env var
isn't) — same reasoning applies unchanged on Windows (env vars, not
parameters, and never logged).

**Windows simplification, not a shortcut**: bash backgrounds the curl
call in a subshell + `disown` specifically because bash has no other
lightweight "fire and forget with a timeout" primitive. This narrow use
case (a single small HTTPS POST, no NAS access at all) doesn't hit the
Start-Job NAS-access problem, since it never touches the NAS — but
there's an even simpler option than backgrounding it at all: `curl`/
`Invoke-RestMethod` calls in this port's real single-file-at-a-time
loop are already bounded by a short timeout, so a synchronous call with
a hard timeout achieves the same "never blocks encoding for more than a
few seconds" guarantee bash's `timeout 10` wrapper provides, with less
mechanism. Proposed: synchronous, not backgrounded — flag for review in
case there's a reason to prefer fire-and-forget beyond what bash's
process model forced it into.

Functions:
- `Send-VesTelegramNotification -Message` — reads
  `$env:VES_TELEGRAM_BOT_TOKEN`/`$env:VES_TELEGRAM_CHAT_ID`, no-ops
  silently if either is unset (matching bash), prefixes the message with
  `[$env:COMPUTERNAME]`, POSTs to the plain Bot API `sendMessage`
  endpoint via `Invoke-RestMethod -Method Post -Body @{...}` (a hashtable
  body, not string concatenation, for the same injection-safety reason
  bash uses `--data-urlencode`), wrapped in try/catch with a short
  `-TimeoutSec` so a notification failure never breaks the caller.
- Call sites: same 3 as bash, added to `convert.ps1`'s per-job success/
  failure paths (with/without a usable elapsed-time-vs-source-duration
  speed figure), matching the exact message wording bash uses so a
  shared bot/chat reads consistently across the whole fleet.

---

## 5. Disc-source (ISO/BDMV) handling — `VesDiscSource.psm1`

Bash reference: `is_disk_source()`/`is_iso_file()`/`is_bluray_root()`
(3820-3830), `media_content_dir()` (3851), `discover_disk_sources()`
(5670), `select_dominant_disk_title()` (5763) +
`handbrake_scan_main_feature_title()` (5717) +
`handbrake_scan_title_durations()` (5738),
`handbrake_extract_disc_title_lossless()` (5854), `process_disk()`
(13882). Config: `DISK_TITLE_DOMINANCE_PCT=40`,
`DISC_EXTRACT_SCRATCH_DIR`, `DISC_EXTRACT_SPACE_MULTIPLIER=3`.

**Confirmed via the bash research pass: bash never mounts ISO files
itself.** `HandBrakeCLI -i <path> -t <title>` reads ISO/BDMV structures
directly — no `mount`/loop-device code anywhere. This means the Windows
port needs **no ISO-mounting logic either** (`Mount-DiskImage` is not
needed) — HandBrakeCLI on Windows reads ISO/BDMV directly the same way,
a genuine like-for-like port, not a new mechanism.

**Windows simplification, not a shortcut**: bash symlinks the extracted
lossless intermediate into the disc's own content dir under a synthetic
name specifically so the "logical source" (for guardrail/accounting
purposes) can be threaded through its more process/subshell-fragmented
execution model. This port's orchestration is a single in-process
PowerShell loop already — the extracted intermediate's path and the
"logical source" (real disc path, for accounting) can just be two
separate variables passed directly to the encode functions, no symlink
needed at all. Windows symlink creation also often needs elevated
privileges or Developer Mode, so avoiding it entirely sidesteps a real
potential permissions problem, not just extra code.

Functions:
- **Reuse, don't duplicate**: `VesProfileDecision.psm1` already exports
  `Test-VesIsDiskSource -Source` (line 362), doing exactly what bash's
  `is_disk_source()` does (`.iso` extension OR a `BDMV` subfolder) —
  confirmed by reading it directly. `VesDiscSource.psm1` imports and
  calls this existing function (with its existing `-Source` parameter
  name, not a new `-Path` name, to avoid a needless inconsistency)
  rather than adding a second, divergent implementation.
- `Get-VesDiscMediaContentDir -Path` — BDMV root itself for Blu-ray,
  parent dir for ISO.
- `Find-VesDiskSources -SearchPath` — enumerate `*.iso` files and
  BDMV-containing directories under the scan roots.
- `Get-VesHandbrakeMainFeatureTitle` / `Get-VesHandbrakeTitleDurations`
  — parse HandBrake's `--scan` text output (main-feature flag first,
  falling back to duration-dominance).
- `Select-VesDominantDiskTitle -Path` — port of the selection logic
  including the 40%-dominance gate and the `SELECT:`/`SKIP:` outcomes
  (returned here as a structured object, not a colon-delimited string —
  no reason to keep bash's string-encoding convention in PowerShell).
- `Invoke-VesLosslessDiscExtraction -Path -TitleIndex -ScratchDir` —
  `HandBrakeCLI -e x264 -q 0 --aencoder copy --all-audio --all-subtitles`
  into a private scratch file, space-checked against
  `DISC_EXTRACT_SPACE_MULTIPLIER` × disc size first (reuse
  `Get-VesAvailableMemoryBytes`-style free-space check, but against disk
  free space, not RAM).
- `Invoke-VesProcessDiskSource -Path` — orchestrates scan → select →
  extract → hands the extracted intermediate + the real disc path
  (as two explicit parameters, no symlink) to the normal encode pipeline
  → cleans up the scratch extraction.

**Real test fixture**: the user confirmed real ISOs exist somewhere in
the media library; locating a specific one for end-to-end testing is
in progress (a full recursive scan of the library over SMB is slow,
per this project's own established pattern — a targeted/bounded search
is preferred over a blind full-tree scan). Once found: build and test
detection/selection logic against it first (cheap, fast), then the real
lossless-extraction + full encode path (expensive, matches how every
other feature in this port has been proven against real content before
being called done).

---

## 6. Live (streaming) HandBrake progress — extend `VesHandBrake.psm1`

Bash reference: `run_handbrake_with_progress()` (2622), FIFO + awk
reader (2666-2710). Confirmed via Spike 2 (above): a plain synchronous
`ReadLine()` loop delivers HandBrake's `--json` `Progress: {...}` lines
incrementally, not just at exit — no FIFO, no separate reader
process/thread needed at all on Windows.

Functions (replacing `Invoke-VesHandBrakeWithProgress`'s current
buffered-until-exit implementation in `VesHandBrake.psm1`):
- `Invoke-VesHandBrakeWithProgress -HandBrakeCliPath -ArgumentList
  -ErrorLogPath -OnProgress` — drives the process directly (not through
  `Invoke-VesTrackedProcess`, since that wrapper's `ReadToEndAsync`-based
  design is specifically NOT what's needed here): starts the process
  with `--json` always appended (matching bash), drains stderr
  concurrently via `ReadToEndAsync()` (required — see Spike 2's deadlock
  note), and loops `$stdout.ReadLine()` while the process hasn't exited,
  parsing each `Progress: {...}` line's `Progress`/`ETASeconds`/`State`/
  `Error` fields (same fields bash's awk extracts) and invoking the
  optional `-OnProgress` scriptblock with a structured object (percent,
  ETA, state) per update — letting the caller decide how to display it
  (a `Write-Host` carriage-return line, matching bash's behavior, is
  the obvious default caller but not hardcoded into this function).
- On `"State": "WORKDONE"`, checks the `Error` field the same way bash
  does, returning a result object with `ExitCode`/`Success`/`ErrorCode`.
- PID tracking for orphan-reaper identification is preserved (this
  function still needs to expose the real HandBrake PID the same way
  `Invoke-VesTrackedProcess` does today).

**Open question for review**: bash's awk reader is a genuinely separate
process reading the FIFO, so a hung/zombied HandBrake process doesn't
block bash's own script logic from continuing to check other state.
This port's synchronous `ReadLine()` loop blocks the calling thread
until HandBrake produces a line or exits — is that an acceptable
difference given this port's orchestration is already fundamentally
single-file-at-a-time and blocking on the active encode anyway (i.e.
`convert.ps1` isn't doing anything else useful while an encode runs,
so blocking here isn't a new constraint), or does a future pipeline-mode
caller (item 2) need this to be non-blocking?

## Revisions after team review (2026-08-03, Gemini/Codex/Cursor)

**Item 2 (pipeline mode) — real gap confirmed, fixed:** PowerShell
mapped drive letters are runspace-scoped and are NOT automatically
inherited by a new runspace's initial session state — a background scan
producer given a drive-letter path (e.g. `X:\Media\...`) would fail to
resolve it. Fixed: the scan producer requires a UNC path
(`\\host\share\...`), never a mapped drive letter — `convert.ps1`
already accepts `-SearchPath` as whatever the caller passes, so this is
a documented constraint on that parameter for pipeline mode specifically,
not a new mechanism. The proposed file-based IPC (ready-queue file,
scan-done flag) avoids the separate "shared in-memory state needs
locking across runspaces" hazard entirely, since nothing is actually
shared in memory between the runspace and the main thread — worth
stating explicitly as a design constraint (don't add an in-memory
shortcut later without re-deriving this).

**Item 6 (live HandBrake progress) — one real bug in the reviewed
design, fixed; two real tradeoffs accepted explicitly:**
- **Bug, confirmed against Spike 2's own actual test script**: the
  design described a `while (-not $proc.HasExited) { ReadLine }` loop,
  but that pattern can drop trailing buffered stdout emitted right
  before exit (including a final `WORKDONE` line arriving in the same
  moment the process exits). Fixed: loop on `ReadLine()`'s own return
  value instead — `while ($null -ne ($line = $reader.ReadLine())) {...}`
  — which naturally drains everything up to real EOF regardless of
  process-exit timing, no separate post-loop "drain remaining" step
  needed (Spike 2's script had exactly this awkwardness, worth fixing
  in the real implementation even though the spike still produced valid
  data).
- **Rule made explicit, not just implied**: the stderr `ReadToEndAsync()`
  task must never be awaited (`.Result`, `.Wait()`, etc.) until AFTER the
  stdout `ReadLine()` loop has fully finished — awaiting it mid-loop
  would block on stderr completing (i.e. process exit) before stdout is
  ever read again, recreating the exact deadlock this design is meant to
  avoid. Spike 2's script happened to get this right implicitly; stating
  it as a rule prevents a future edit from getting it wrong.
- **Accepted tradeoff, not fixed**: buffering all of stderr into one
  string via `ReadToEndAsync()` doesn't bound memory for hour-scale
  HandBrake runs. Same tradeoff `VesTrackedProcess.psm1` already accepts
  for real multi-hour ffmpeg encodes without issue in this project — kept
  consistent rather than solving it uniquely for HandBrake.

**Item 5 (disc source) — real architectural gap, fixed:** the "two
explicit variables instead of a symlink" simplification was underspecified
in a way that risked real breakage: bash's symlink isn't just cosmetic
accounting — the extracted lossless intermediate is symlinked to live
*inside* `media_content_dir()` specifically so downstream helpers
(destination-path computation, done-log/title-lock keying, sidecar
placement) resolve against the real library location while the actual
encode reads from scratch. Fixed by making the role of each path
explicit rather than passing "two paths" ambiguously:
- The extracted lossless intermediate (real path, under
  `DISC_EXTRACT_SCRATCH_DIR`) is the only thing ever passed as `-Source`
  to the actual encode/VMAF-search functions.
- The real disc path (ISO file or BDMV root) is what drives
  `Get-VesDiscMediaContentDir`, done-log keying, title-lock claiming, and
  final destination-path computation — i.e. every function in this port
  that currently takes a single `-Source` parameter for a normal file
  must, for a disc source, be called with the *disc's* logical path for
  those specific purposes even though the encoder reads bytes from the
  scratch intermediate.
- Kept bash's collision guard even without a symlink: before encoding,
  explicitly check whether a real output already exists at the
  synthetic name the disc's logical source would produce, and refuse
  (warn, don't overwrite) exactly like bash's symlink-name collision
  check did.

**Item 4 (Telegram) — real PowerShell-version nuance, addressed:**
`-TimeoutSec` on `Invoke-RestMethod` in PowerShell 7.4+ maps to
`ConnectionTimeoutSeconds` (covers connecting + receiving headers only)
— a connected-but-stalled response body is NOT bounded by it alone.
Fixed: set `-OperationTimeoutSeconds` alongside `-TimeoutSec` when
running on 7.4+ (version-checked, since the parameter doesn't exist on
earlier PS7 releases) so the "never blocks more than a few seconds"
guarantee actually holds end-to-end. Accepted, not fixed: a synchronous
call still pays the timeout cost per notification if Telegram is
genuinely unreachable, unlike bash's backgrounded+disowned call which
never delays the next job at all — for a low-stakes fire-and-forget
notification this is judged an acceptable, explicit tradeoff (worst
case: a large batch with Telegram down runs slightly slower, it doesn't
fail), not something worth re-introducing Start-Job risk to avoid.

**Item 1 (organize) — two notes, no design change:**
- Spike 1's "immediate write succeeded" result was only tested from an
  interactive SSH session — a real production run launches via
  `VesDetachedExecution` (Scheduled Task, Session 0), a different
  credential/token context that could plausibly behave differently
  (double-hop/credential-delegation issues are a real, distinct class of
  Windows quirk from simple ACL-inheritance timing). Flagged as a
  required follow-up test before trusting organize-phase folder creation
  in a real detached production run — not blocking this design, but
  tracked so it isn't silently assumed.
- Bash's subtitle-to-title matching uses prefix/contains logic that can
  misassociate an ambiguously-named subtitle file in a flat folder with
  the wrong movie. This is existing, accepted bash behavior being
  faithfully replicated, not a new Windows-specific risk — the port
  should match bash's exact matching semantics rather than being either
  more or less permissive.

**Item 3 (season-retry) — bit-rot mitigation added:** since this module
is intentionally unreachable from any real code path in this pass, it
gets its own narrow unit tests (synthetic direct calls to
`Add-VesSeasonSampleResult`/`Add-VesSeasonNoShrinkPrediction`/
`Invoke-VesSeasonRetryPass`, not integration-tested through a real
encode run) plus an explicit `# TODO(season-retry-integration):` comment
at the future call site once the sample-test-prediction mechanism is
ported, so the dependency is discoverable in code, not just in this
document.

## All 6 features built and tested (2026-08-03)

1. **Telegram** (`VesTelegram.psm1`) -- 4 real tests including an
   actual network round trip to Telegram's real API with intentionally
   invalid credentials.
2. **Organize phase** (`VesOrganize.psm1`) -- 6 real tests including
   real folder creation, file+subtitle moves, a real collision refusal,
   and a full library pass with correct largest-first ordering.
3. **Live HandBrake progress** (`VesHandBrake.psm1`, rewritten) -- a
   real bug found via actual output capture: HandBrake's JSON spans
   multiple lines per block, not one line as first assumed. Fixed with
   brace-depth accumulation; verified with 12 real incremental progress
   callbacks across a real encode.
4. **Season-retry** (`VesSeasonRetry.psm1`) -- 6 real tests, tracking/
   retry logic only per scope decision, not wired into any real
   `convert.ps1` path yet (marked with explicit TODO comments).
5. **Pipeline-vs-batch mode** (`VesPipelineScan.psm1`) -- 4 real tests,
   including the make-or-break claim (a PowerShell runspace, not
   Start-Job, can write to the real NAS without the documented
   Access-Denied failure) verified directly: 12/12 real files found via
   a real runspace scan against a real NAS fixture tree.
6. **Disc-source handling** (`VesDiscSource.psm1`) -- detection/scan/
   title-selection verified against a REAL 22GB Blu-ray ISO on the NAS
   (`The Lazarus Effect (2015).ISO`): a real 24.5-second HandBrake scan
   correctly selected the main feature (title 6, 83.6 min -- a plausible
   runtime for this real film). Full lossless-extraction + VMAF-search +
   AV1-encode end-to-end proof is a genuinely long-running job (tracked
   separately, results to follow once complete -- extracting and
   re-encoding an 84-minute Blu-ray title takes real hours, not minutes).
