# Design: 6 remaining Phase 3/4 PowerShell-port features

Draft for team review (Gemini/Codex/Cursor, advisory-only) before implementation.
Companion to `ROADMAP.md`'s "Native-Windows PowerShell fork" section. The bash
script `convert-v5.0.33S.sh` remains authoritative; every item below is a
behavioral port, not a redesign, except where a Windows/SMB-specific
constraint forces a genuine deviation (called out explicitly).

Already built and NOT covered here: `VesProfileDecision`, `VesVmafCrfSearch`,
`VesTwoStageEncode`, `VesSubtitleFilter`, `VesStaging`, `VesTrackedProcess`,
`VesSharedMutex`, `VesDoneLog`, `VesDetachedExecution`, `VesTimeoutRetry`.

---

## 1. RAM disk staging — `VesRamDisk.psm1`

Bash reference: `ramdisk_discover/create/job_start/job_teardown` (job-scoped,
one RAM disk per run, sized at `CONVERT_RAMDISK_PCT`% of *available* memory).

Windows mechanism: `imdisk.exe` (confirmed installed + working on ELVIS
2026-08-03 — driver runs, format/mount/write/unmount all verified). Kernel-level
mount, not a per-session `net use`, so unlike the SMB/NFS drive-letter finding
from Phase 0, an ImDisk-mounted volume should be visible fleet-process-wide —
**must verify this empirically before relying on it**, not assumed.

Functions:
- `Get-VesAvailableMemoryBytes` — `(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB`.
- `New-VesRamDiskJob -SizeBytes -DriveLetter` — picks a free drive letter (`Get-PSDrive` scan, avoid hardcoding one letter since a stale disk from a crashed prior run could still hold it), runs `imdisk -a -s <N>M -m <Letter>: -p "/fs:ntfs /q /y"`, waits for `Get-Volume` to confirm ready (poll, timeout via `VesTimeoutRetry`), creates a private stage subdir. Returns an object `{DriveLetter, StagePath, Owned=$true}`.
- `Remove-VesRamDiskJob -DriveLetter` — `imdisk -D -m <Letter>:` (matches the tested teardown). Must tolerate "already gone" (idempotent) since teardown can be called from both normal-exit and orphan-reaper paths.
- `Test-VesRamDiskLeftover` — startup check for a leftover mounted disk from a crashed prior run (bash's "crash recovery" branch in `ramdisk_job_start`) — enumerate `imdisk -l` output, match against this job's convention, tear down before creating a new one.
- Resolve per-file stage path: reuse `VesStaging.psm1`'s existing `Resolve-VesEncodeStagePath` — just pass the RAM disk path as the preferred local-fallback dir instead of `D:\VES-*\staging` when available; **no new staging-selection logic**, this module only owns disk lifecycle.

**Cleanup guarantee problem (Windows-specific deviation from bash's EXIT trap):**
Bash uses `trap ... EXIT`, guaranteed on normal exit and most signals. PowerShell
has no exact equivalent that survives every termination path, and this project's
jobs run via `VesDetachedExecution` (Scheduled Task) — a hard kill or crash
leaves the RAM disk mounted with nothing to run a trap. Proposed handling:
register the disk's drive letter + owning job ID in a small marker file
(`D:\VES-<host>\ramdisk-active.json`), and have the **orphan reaper** (item 2)
check for a mounted ImDisk volume whose owning process is dead and tear it down
— i.e., RAM disk cleanup on crash is the orphan reaper's job, not a trap
substitute. Flag this explicitly for team review: is there a better native
primitive (`Register-EngineEvent PowerShell.Exiting`, a wrapping try/finally in
the outermost script) worth layering on top as a first line of defense even
though it's not crash-proof?

---

## 2. Orphan reaper — `VesOrphanReaper.psm1`

Bash reference: `reap_orphaned_encoders`, 4-gate salvage/delete
(`orphan_gate0_provenance` → `orphan_gate3_tail_decode`), cross-host guard via
`host=` field, stale-dir age via `ORPHAN_STALE_DIR_AGE_SECS`.

Functions:
- `Get-VesOrphanCandidates -Root` — enumerate `*.convert-v4.IN_PROGRESS`-equivalent
  flag files (need a Windows-safe flag filename — dot-prefixed files are hidden
  over SMB per the Phase 3 NAS-quirks finding, so flag files must use
  `Get-ChildItem -Force` everywhere, already the established convention).
- `Test-VesOrphanIsLive -Flag` — parse `pid=`/`host=`/`encoder_pid=` fields;
  `host` mismatch → skip (cross-host); `Get-Process -Id $pid -ErrorAction SilentlyContinue`
  as the `kill -0` equivalent; PID-reuse guard needed on Windows too — check
  `(Get-Process -Id $pid).StartTime` against the flag's recorded start time,
  same skew-tolerance idea as bash's `encoder_identity_matches`.
- `Invoke-VesKillOrphanedProcess -Pid` — `Stop-Process -Id $pid` (graceful) →
  poll → `Stop-Process -Id $pid -Force`, mirroring TERM→poll→KILL. Note from
  the E2E test's own cleanup work this session: always exclude the *current*
  session's own PID from any bulk kill.
- 4-gate validation reused conceptually: `Test-VesOrphanDurationMatch` (ffprobe),
  `Test-VesOrphanStructure` (mkvalidator/mkvmerge --identify), `Test-VesOrphanTailDecode`
  (short decode probe near EOF) — these can mostly call existing probes already
  written for `VesTwoStageEncode`'s own validation step rather than duplicating
  ffprobe/mkvalidator invocation code; propose extracting those into a small
  shared `VesValidation.psm1` if the team review agrees it's worth it (open
  question, not a firm design decision yet).
- `Complete-VesOrphanDisposition` — orchestrates gates in order, salvages via
  `VesStaging`'s existing finalize function on full pass, else deletes only the
  generated candidate (never touches source) — matching the bash "never delete
  based on returncode alone" invariant already established as a hard constant
  for this whole project.
- Also owns: RAM disk leftover cleanup (item 1's crash-recovery case) and
  stale Scheduled Task cleanup (`VesDetachedExecution` jobs whose task shows
  finished/failed but left files behind).

Runs as Phase B before new work is claimed, same as bash — invoked once at
batch start, not continuously polled.

---

## 3. Resume-state persistence — `VesResumeState.psm1`

Bash reference: per-hostname `*.state`/`*.queue`/`*.shards` sidecar files,
atomic `mktemp`+`mv` write, `resume_state_matches_current` invalidation,
done-log already ported separately (`VesDoneLog.psm1`, unaffected by this item).

Functions:
- `Save-VesResumeState -Path -State` — serialize to JSON (`ConvertTo-Json`),
  write to a temp file, then move into place. **Deviation from bash**:
  `Move-Item`/`Rename-Item` are on this project's confirmed-unreliable list for
  this NAS; use `[System.IO.File]::Replace()` or `[System.IO.File]::Move($tmp, $dest, $true)`
  (the direct .NET API, matching the pattern already adopted in `VesStaging.psm1`
  for the same reason) — not the PowerShell cmdlet.
- `Test-VesResumeStateMatchesCurrent -State -CurrentArgs` — same field-by-field
  comparison as bash (path, shard depth, no-shard, name-glob, skip flags);
  mismatch invalidates fast-resume, forcing full re-scan.
- `Get-VesResumeSidecarPath -JobRoot -Hostname -Kind` (`state`/`queue`/`shards`) —
  mirrors `resolve_job_sidecar_paths`'s fallback chain (job root if writable →
  local cache dir → temp dir), same per-hostname naming so a fleet run under a
  shared job root only resumes its own machine's progress, matching the bash
  comment's stated invariant.
- No new heartbeat mechanism needed here — `VesDoneLog`'s existing per-entry
  design plus the orphan reaper's flag-file staleness check together cover
  what bash's background-heartbeat `touch` was protecting against (a live job
  being mistaken for abandoned); flagging this equivalence explicitly for the
  team to confirm rather than asserting it as certain.

---

## 4. Sharded directory scanning — `VesShardedScan.psm1`

Bash reference: `get_scan_roots` (per-directory chunking at `SHARD_DEPTH`,
default 1 — **not** a machine/hash partition scheme, confirmed via the
research pass), `roots_need_catchup_scan`, `shard_for_path`.

Functions:
- `Get-VesScanRoots -SearchPath -ShardDepth -NoShard -NameGlob` —
  `Get-ChildItem -Directory -Force` at the given depth (recurse manually to
  `ShardDepth` levels since PowerShell's `-Depth` on `Get-ChildItem` counts
  differently from `find -mindepth/-maxdepth`; verify exact semantics against
  a real nested fixture before trusting depth=1 behaves like bash's depth=1),
  filtered by `NameGlob` if set, sorted ordinal (`[StringComparer]::Ordinal`,
  the Windows equivalent of bash's `LC_ALL=C sort`); falls back to the search
  path itself as a single root if zero subdirectories exist, same as bash.
- `Test-VesRootsNeedCatchupScan` — extra pass over loose files directly under
  `SearchPath` not captured by any shard (the Oppenheimer bug bash already
  fixed for) — port the same check rather than re-discovering it.
- `Get-VesShardForPath -Source -Roots` — reverse-lookup used for resume-state
  logging (`RESUME_LAST_SHARD`-equivalent), simple longest-prefix-match against
  the resolved root list.
- Per-shard counts (`count_videos_under_shard`, `count_disks_under_shard`) —
  port only if item 3's resume-state design ends up needing shard-snapshot
  comparison for its own resume logic; otherwise defer as unused until a real
  need appears (avoid building unused abstraction per this project's own
  no-speculative-code convention).

---

## 5. HandBrake / hardware-encode paths — `VesHandBrake.psm1` + `VesHwDetect.psm1`

Bash reference: `detect_hw_environment` (NVIDIA > Intel QSV > AMD VCE >
software priority), `run_handbrake_with_progress`, `build_handbrake_args`.
ROADMAP already notes HandBrakeCLI's official Windows builds need "zero
porting work" for the binary itself — this item is about driving it and
detecting hardware, not building/porting the tool.

Functions:
- `Get-VesHandBrakeCli` — locate `HandBrakeCLI.exe` (fixed known install path
  or PATH lookup), no WSL-path-translation logic needed at all (that whole
  bash code path — `_wsl_windows_handbrake_candidates`,
  `_handbrake_translate_argv` — is WSL-specific and doesn't apply here; this
  module is simpler than its bash counterpart for a real reason, not an
  oversight).
- `Test-VesNvencAvailable` / `Test-VesQsvAvailable` / `Test-VesVceAvailable` —
  short real probe encodes via ffmpeg (mirrors bash's `_probe_qsv_encode_available`
  actually-encode-not-just-list approach, since HandBrake/ffmpeg can list an
  encoder that fails at runtime init). ELVIS is hybrid AMD iGPU + NVIDIA GTX
  1650 (Turing — confirmed no AV1 NVENC, but HEVC NVENC works) — this is the
  first real mixed-hardware Windows test case, useful for verifying the
  priority-fallback logic actually chooses correctly rather than just always
  landing on software (which is all the earlier real encode test exercised).
- `Resolve-VesHwEncodePriority` — same fixed precedence NVIDIA > Intel QSV >
  AMD VCE > software, override params matching bash's `--prefer-intel-qsv`/
  `CONVERT_PREFER_AMD_VCE` flags for parity.
- `Build-VesHandBrakeArgs -Source -Destination -Profile -Encoder ...` — port
  `build_handbrake_args`'s argv construction faithfully (`-f mkv -m -O -e ...
  --all-subtitles --subtitle-burned=none ...`), reusing `VesSubtitleFilter`'s
  already-ported tri-state logic for subtitle decisions rather than
  reimplementing it inside this module.
- `Invoke-VesHandBrakeWithProgress` — JSON progress parsing (`Progress: {...}`
  lines) via `Invoke-VesTrackedProcess` (already handles PID tracking for
  orphan-reaper identification) — no fifo/mkfifo equivalent needed, just
  parse stdout lines as they arrive, same approach `VesTwoStageEncode` already
  uses for ffmpeg progress.
- NVENC AV1 CQ constants: port the same per-profile table (`NVENC_AV1_CQ_MOVIE`
  etc.) verbatim as a hashtable — these are tuning constants, not logic, no
  design decision needed.

Scope check for this pass: build the detection + arg-building + invocation
plumbing and prove it against ELVIS's real mixed hardware (HEVC NVENC path at
minimum, since AV1 NVENC is a hardware ceiling on this GPU); a disc-source
(ISO/BDMV) end-to-end HandBrake test is out of scope unless the team flags it
as required for this pass — no disc test fixture currently available for
ELVIS. **Open question for review: acceptable to defer disc-source testing?**

---

## 6. Multi-machine coordination — `VesTitleLock.psm1`

Bash reference: `place_in_progress_flag`'s `.lock` **directory** claim (atomic
`mkdir`, distinct from the shared mutex used for the done-log append lock) —
confirmed via research this is opportunistic per-title locking, not a
pre-planned shard/machine partition. No central job-claim server exists in
bash to port.

Windows deviation (deliberate, not an oversight): `mkdir` is not the right
atomic primitive here — this project's own Phase 3 NAS-quirks findings showed
newly-created **directories** get a broken ACL on this NAS's SMB share
(`Everyone: RX` instead of inheriting `Modify`), which is exactly why
`VesSharedMutex.psm1` was redesigned around `FileMode.CreateNew` on a **file**
instead of a directory. Proposal: `VesTitleLock.psm1` reuses that same
already-proven file-based atomic-create primitive from `VesSharedMutex`
rather than inventing a second locking mechanism — a title lock is really
"one more thing to atomically claim," just keyed per-title instead of per
shared-resource. Concretely:
- `Enter-VesTitleLock -Source` — wraps `Enter-VesSharedMutex` with a
  lock-path convention derived from the source file path (e.g.
  `<sourcedir>\<basename>.convert.lock`), no new ownership-token logic needed
  since `VesSharedMutex` already has it.
- `Exit-VesTitleLock -Source` — wraps `Exit-VesSharedMutex`.
- Cross-host liveness: same `host=`/PID fields as the orphan reaper (item 2)
  need to be written into the lock's content at claim time so the reaper can
  later tell a stale lock (owner process dead) from a live one — this is the
  one piece of genuinely new logic, everything else is composition of
  already-built/being-built pieces.

**Open question for review**: is collapsing "title lock" and "shared mutex"
into one primitive with two calling conventions the right call, or does the
team see a reason they should stay genuinely separate modules (e.g. different
staleness timeout needs — a title lock should probably be stale-reclaimable
much sooner than a short-lived append-lock, since an abandoned title claim
could otherwise block that title fleet-wide for the mutex's full timeout)?

---

## Revisions after team review (2026-08-03, Gemini/Codex/Cursor)

All three reviewers independently flagged the same top issue; verified against
`VesSharedMutex.psm1`'s actual code before accepting any finding, per this
project's "verify before trusting a review finding" convention.

**Item 6 (title lock) — confirmed real, fixed:**
- `Exit-VesSharedMutex` does an *exact string match* between the caller's
  token and the lock file's raw content (`$current -ne $Token`). Writing
  `host=`/`pid=` metadata into that same file, as originally proposed, breaks
  release entirely. **Fix**: metadata goes in a separate companion file
  (`<lockpath>.meta`, plain content, written after the lock itself is held —
  never touched by `Exit-VesSharedMutex`), not inside the token file.
- `Enter-VesSharedMutex` already takes a `-StaleSeconds` parameter (default
  90, tuned for the short done-log append case) — no new mechanism needed.
  `VesTitleLock` calls it with a long value matching bash's analogous
  `ORPHAN_STALE_DIR_AGE_SECS` (7200s) as the safety-net ceiling, not a new
  short timeout. Prompt reclaim of a genuinely dead holder's lock (before that
  2-hour ceiling) is the orphan reaper's job, not the mutex's: the reaper reads
  the `.meta` companion file, confirms the owning PID is dead via the same
  liveness check used for encoder orphans, and only then force-deletes the
  lock file directly (it is not the original holder, so it cannot use the
  normal token-matched `Exit-VesSharedMutex` path — this is a distinct,
  independently-verified-deadness deletion, not a bypass of the safety
  invariant).

**Item 1 (RAM disk) — "always safe to tear down" was too strong, fixed:**
- ImDisk volumes carry no intrinsic ownership info. Fix: write an owner
  marker *onto the RAM disk itself* (e.g. `<Drive>:\.ves-owner.json`:
  `{JobPid, Host, StagePath, StartedUtc}`) at creation time — the orphan
  reaper reads this, confirms the PID is dead, and only then proceeds.
- Ordering gap fixed: the reaper must attempt salvage of any completed,
  gate-verified candidate in the stage dir *before* unmounting — tearing the
  disk down first would destroy the only copy of a finished-but-not-yet-moved
  output. Salvage-then-unmount, matching the same order as the on-disk
  staging orphan path in item 2.
- Same-host drive-letter-selection race (two concurrent jobs picking the same
  free letter) fixed with a local (not NAS-based — this is single-host
  coordination, a plain `[System.Threading.Mutex]` is correct and simpler
  than reusing the NAS file-based primitive for a problem that isn't
  network-shared).
- Empirically re-tested (2026-08-03, real ELVIS): confirmed via a genuine
  split-session test — RAM disk created over one SSH connection (which lands
  in Session 0) was directly confirmed visible in File Explorer on ELVIS's
  physical console (Session 1) by the user. ImDisk volumes are **not**
  session-scoped the way SMB/NFS drive-letter mappings are (that Phase 0
  finding does not apply here) — this was checked empirically rather than
  trusted from either the design doc's open question or a reviewer's general
  claim to the contrary.

**Item 2 (orphan reaper) — three real delete-safety gaps, fixed:**
- Added: immediate Gate-0 provenance re-check right before any delete (not
  just once earlier in the pipeline) — closes a race where the candidate
  could be swapped after gating but before deletion.
- Added: probe timeout/error is treated as *ambiguous, leave in place*, never
  as proof of corruption — matches this project's standing "never delete
  based on subprocess returncode alone" constant, which the original draft
  didn't restate strongly enough for this specific path.
- Added: refuse to touch (salvage or delete) anything that is a Windows
  reparse point/junction, mirroring bash's symlink refusal.
- All deletes route through `VesStaging.psm1`'s existing `Remove-VesFileRobust`,
  never a raw `Remove-Item`, for the same NAS-reliability reason already
  established project-wide.

**Item 4 (sharded scan) — depth semantics and exclusions, fixed:**
- Confirmed (Cursor, empirically-grounded claim, matches known PowerShell
  behavior): `Get-ChildItem -Recurse -Depth N` returns directories at *every*
  level up to N, not only exactly depth N — does not match bash's
  `find -mindepth N -maxdepth N`. Fixed with an explicit level-by-level walk:
  ```powershell
  $cur = @($SearchPath)
  1..$ShardDepth | ForEach-Object {
      $cur = @(foreach ($d in $cur) {
          Get-ChildItem -LiteralPath $d -Directory -Force -ErrorAction SilentlyContinue
      } | ForEach-Object FullName)
  }
  # $cur is now exactly depth $ShardDepth, matching bash
  ```
  (`SHARD_DEPTH=1`, the default, degenerates to a single non-recursive
  `Get-ChildItem -Directory -Force` call — no walk needed in the common case.)
- Added bash's hard directory exclusions (`ffmpeg-logs`, `Deferred`,
  dot-prefixed) to the walk — missing them was a real gap, not a style
  choice; without them those dirs become false shards and real video
  directories get skipped.
- `Get-VesShardForPath`'s prefix match must be path-boundary-aware
  (`C:\A\B` must not match as a prefix of `C:\A\B2`) and case-normalized.

**Item 5 (HandBrake/hardware) — probe-tool mismatch and verification gap, fixed:**
- Probes must exercise whichever tool will actually run the real job.
  Original draft said "probe via ffmpeg" for all three paths; since bash
  probes QSV specifically through an actual HandBrake invocation (because
  ffmpeg and HandBrake's QSV/NVENC init can disagree), this port does the
  same — probe through HandBrakeCLI when HandBrake is the selected engine,
  through ffmpeg only for the ffmpeg-engine paths.
- Success is exit-0 **and** non-empty valid output (mirrors bash's
  `[ -s "$probe_out" ]`), never exit code alone.
- HandBrake's own encode-success path needs the same independent
  verification (duration/structure check via the existing validation used in
  `VesTwoStageEncode`) before calling a HandBrake job "done" — the original
  draft didn't say this explicitly enough for this specific path.
- Session-0/Scheduled-Task GPU initialization is flagged as a real unknown:
  hardware probes must be tested under the actual `VesDetachedExecution`
  launch path, not just an interactive session, before trusting the result
  fleet-wide.

**Item 3 (resume-state) — minor fixes:**
- `[System.IO.File]::Move($tmp, $dest, $true)`'s 3-argument overwrite overload
  requires .NET Core/.NET 5+ (PowerShell 7+) — not an issue, this fork already
  targets PowerShell 7+ per ROADMAP, but noting it so nobody backports this
  onto Windows PowerShell 5.1 later.
- Sidecar writes need the same refuse-if-destination-is-a-reparse-point guard
  as item 2's delete path, so a planted link can't redirect a truncating
  write onto something it shouldn't touch.

**Deferred, accepted as-is:** disc-source (ISO/BDMV) HandBrake end-to-end
testing stays out of scope for this pass (no fixture available on ELVIS);
tracked as an explicit follow-up, not silently dropped.

## Real bug found building item 3 (resume-state, 2026-08-03), fixed and verified

`VesResumeState.psm1` built and tested with 10 real tests on ELVIS,
including a real round-trip against the production NAS
(`\\10.10.10.150\Media\holding\...`). One real bug: `[System.IO.File]::Replace($tmp, $Path, $null)`
threw `"The path is empty"` for the required (but supposed to be
nullable) backup-filename argument -- PowerShell's method-overload
binding doesn't pass a bare `$null` through to that parameter the way
plain C# would. Fixed by switching to the simpler 3-arg
`[System.IO.File]::Move($tmp, $Path, $true)` overload (.NET Core
3.0+/PS7+, fine since this fork targets PS7+), which handles both
create and atomic-overwrite without a backup-filename parameter at
all. Also verified: refuses to write through a reparse point (same
guard as the orphan reaper), the sidecar-path fallback chain correctly
falls through to `%LOCALAPPDATA%` when the job root can't be used as a
directory, and `Get-VesResumeState` returns `$null` (not a thrown
error) for a missing/corrupt sidecar file.

## Real bug found building item 6 (2026-08-03), fixed and verified

`VesTitleLock.psm1`'s first working draft had a genuine race, caught by an
actual two-process test on ELVIS, not by review alone: it did a separate
`Test-Path`+age pre-flight check, then called the blocking `Enter-VesSharedMutex`
if that check looked clear. Window between the two calls let a second racing
process fall into `Enter-VesSharedMutex`'s internal retry loop instead of
being told "claimed by another" -- it then **queued and won the lock several
seconds later** once the first process released, instead of skipping the
title immediately. This is the opposite of bash's non-blocking `mkdir`-based
claim semantics (loser skips right away, never queues).

Fix: added `Enter-VesSharedMutexOnce` to `VesSharedMutex.psm1` -- a genuine
single-attempt variant (one `CreateNew`, one reclaim-if-stale attempt, then
give up) that never loops waiting for another holder. `VesTitleLock.psm1`
now calls this instead of the blocking primitive, with no separate pre-flight
check needed (removed -- it was the source of the race, not a safeguard).
Re-verified with the same two-process test: exactly one process wins, the
other returns `$null` immediately rather than eventually acquiring.

An earlier draft of the same function also briefly used `Start-Job` to fake
a bounded wait -- caught before deployment by rereading `VesSharedMutex.psm1`'s
own header, which already documents that `Start-Job`-spawned children hit a
persistent Access-Denied against this NAS. Removed in favor of a direct
in-process call, consistent with why the module warns against that pattern
in the first place.

## Real bugs found building item 2 (orphan reaper, 2026-08-03), fixed and verified

`VesOrphanReaper.psm1` + `VesValidation.psm1` built and tested (13 real
tests on ELVIS: real live/dead process detection, self-kill refusal, a
real target process killed, flag-file parsing across all 5 disposition
outcomes including a real live encoder process and a real dead one, a real
Windows junction refused via the reparse-point guard, confirmed
duration-mismatch deletion, confirmed matching-duration salvage, RAM-disk
crash-recovery with correct salvage-before-teardown ordering, and title-lock
crash-recovery that reclaims only the confirmed-dead holder while leaving a
live holder's lock untouched). Three real bugs found during testing, not
just review:

1. `Test-VesProcessIsAlive`'s `-RecordedStartTimeUtc` parameter was
   non-nullable `[datetime]`, but a legitimate flag file can omit
   `encoder_started_utc` entirely (the legacy/manual-review case) --
   PowerShell threw a parameter-binding error rather than treating it as
   "no start time recorded." Fixed with `[Nullable[datetime]]`.
2. `Invoke-VesRamDiskOrphanRecovery`'s first draft used the SAME resolved
   path for both the duration-match gate's "source" and the salvage
   target's "final destination" -- these are genuinely different paths
   (the true original library file vs. where a salvaged output should
   land). This made the duration gate compare a candidate against its own
   not-yet-existent destination, which also tripped the reparse-point
   refusal for the wrong reason (path didn't exist, not that it was a
   reparse point). Fixed by replacing the single `-ResolveFinalDestination`
   parameter with `-ResolveSourceAndDestination`, returning both values
   explicitly; `Test-VesOrphanCandidateSafeToDispose` also gained an
   explicit "source doesn't exist" check with its own accurate warning
   message, separate from the reparse-point check.
3. (Test-harness-only, not a module bug, confirmed by manually running
   `mkvalidator` against the same fixture): a synthetic 2-second
   `color`+`anullsrc` lavfi test clip is itself genuinely flagged invalid
   by mkvalidator (likely missing proper Cues for such a short
   single-keyframe clip) -- the module's structure gate was working
   correctly by rejecting it. The real-movie encode test earlier this
   project (Twelve in a Box (2007)) already proved a genuinely
   valid-structure file salvages cleanly through the equivalent finalize
   path, so this test isolates the duration gate instead of asserting a
   flawed fixture should pass structure validation.

## Real bugs found building item 4 (sharded scan, 2026-08-03), fixed and verified -- including a self-correction

`VesShardedScan.psm1` built with Cursor's reviewed exact-depth walk
pattern and bash's directory exclusions (`ffmpeg-logs`, `Deferred`,
dot-prefixed), tested with 7 real tests on ELVIS against a real nested
fixture tree.

**First bug (real):** a plain `return @($SearchPath)` silently
collapsed to a **bare string** instead of a 1-element array whenever
the result had exactly one shard -- PowerShell unrolls arrays emitted
to a function's output stream, so a 1-element array becomes
indistinguishable from a scalar to a caller that captures it via direct
assignment (`$result.Count` still read `1`, but `$result[0]` returned a
single CHARACTER of the string, since string indexing was silently
substituted for array indexing).

**First fix attempt (wrong, self-corrected):** added a unary-comma
guard (`return , @(...)`) at every array-returning site across
`VesShardedScan.psm1`, `VesRamDisk.psm1`'s `Get-VesRamDiskLeftovers`,
and `VesOrphanReaper.psm1`'s `Get-VesOrphanFlagCandidates`/`$disposed`/
`$reclaimed` (an earlier version of this doc incorrectly claimed the
latter two were "safe by construction" -- that claim was never actually
verified and turned out to be wrong; a direct test proved the identical
collapse happens for a bare `return $arrayVariable` too, not just
`return @(expr)`). This comma-wrap DID fix direct-assignment capture,
but a full regression pass across all three modules' existing test
suites caught that it broke **direct piping**
(`Get-VesOrphanFlagCandidates ... | Where-Object {...}`) for the
2+-element case instead: a comma-wrapped multi-element array flows
through the pipe as a SINGLE object rather than one element at a time,
and PowerShell's array-member-access-plus-`-eq`-as-element-wise-filter
semantics on that single object made `Where-Object`'s condition
evaluate as truthy regardless of which element was intended --
silently returning the WRONG candidate (three previously-passing
orphan-reaper tests started reporting `cross_host` for same-host
flags). This is why re-running each affected module's full existing
test suite after any change -- not just the new module's own tests --
caught a regression the new tests alone would have missed.

**Actual fix:** reverted all five sites back to plain `return $x` /
`return @($x)` (no comma). The correct, standard PowerShell convention
is to guarantee array-ness at the **call site** instead --
`$vars = @(Get-VesXxx ...)` when capturing into a variable for
indexing/`.Count`, with no wrapping needed when piping directly for
per-element enumeration. Updated the affected test-script call sites
(`Get-VesScanRoots -NoShard`/zero-subdirectory-fallback assignments in
`test-shardedscan.ps1`, `Get-VesOrphanFlagCandidates` in
`test-orphanreaper.ps1`'s Test 5) to wrap accordingly. All three
modules' full test suites (RAM disk: 8, orphan reaper: 13, sharded
scan: 7) pass cleanly with this fix. This convention -- comma-wrapping
inside a function is the WRONG fix for the single-element collapse
problem; `@(...)` at the call site is the right one -- is now the
standing rule for every module in this port.

---

## Cross-cutting notes for reviewers

- All six modules must follow established conventions already hardened by
  the earlier team review: guarded `Import-Module` (no unconditional nested
  `-Force` re-imports), `Invoke-VesWithTimeoutRetry` around every external
  subprocess call, `.NET` file APIs instead of `Move-Item`/`Copy-Item`/`Remove-Item`
  for anything touching the NAS, `Get-ChildItem -Force` for dot-prefixed/hidden
  files, `VesDetachedExecution` for anything launched over SSH.
- None of these six items have been tested yet — plan is real functional
  tests on ELVIS for each (RAM disk lifecycle test, a genuine crash-simulated
  orphan-reap test, a resume-after-kill test, a real nested-library shard
  test, a real HEVC-NVENC hardware encode, and a two-simulated-node title-lock
  race test), not just unit-style module tests, matching how Phase 0-3 were
  validated.
