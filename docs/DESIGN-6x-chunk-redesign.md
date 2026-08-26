# 6.x Chunk-Based Redesign — Design Document

Status: draft, actively evolving. Captures every architecture decision made
during the 2026-08-24 design session on branch `6.x-chunk-redesign`
(forked from `main` at v5.1.2A). Nothing here is built yet unless
explicitly marked done — this is the plan the build work will follow.

## Why this is a fork, not a v5.x feature

The fleet's original model — each machine independently claims and encodes
one whole file end-to-end — is fully decentralized by design: no
coordination needed, any machine can pick up any file, atomic mkdir-based
claims prevent collisions. Chunk-parallel encoding breaks that assumption.
Multiple machines now produce *pieces* of one file that must be assembled
in the right order and validated together before anything is "done" — a
genuine coordination problem, not just a work-distribution one.

Per this project's own versioning convention, a major version bump marks
"a complete re-architecture." This qualifies. Unlike every prior version
bump (5.0.x through 5.1.2A, all new files on `main`), this uses a real git
branch — the redesign needs real design/build work before it's ready to
sit alongside the proven 5.x line. `main` (5.x) stays stable and
maintained; all chunk/orchestrator redesign work happens here until ready.
`convert-v6.0.0A.sh` is a byte-for-byte copy of `convert-v5.1.2A.sh`
(VERSION bumped only) — the entire existing codebase brought over as the
baseline, nothing pruned yet.

**Known consequence, not yet acted on**: `VES_MAJOR` (derived from
`VERSION`) gates the already-processed tag skip-check — every file
currently tagged `VES 5.x` becomes eligible for reconsideration the moment
a real 6.x build starts scanning the library. Most will still fall out
quickly (bakeoff predicts no size win, skips again), but it means a full
library sweep, not just new chunk-eligible titles, the first time 6.x
actually runs against the real library. Worth deciding deliberately when
that first real run happens, not accidentally.

## Fleet hardware inventory (verified live 2026-08-24)

| Machine | CPU | Cores | RAM | OS | Network | Arch |
|---|---|---|---|---|---|---|
| JJACKSON | AMD Ryzen 9 7940HS | 16 | 86 GB | Fedora 44 | 10.200.200.x (VPN) | x86_64 |
| TITOJ | Intel i9-9980HK | 16 | 62 GB | Fedora 44 | 10.200.200.x (VPN) | x86_64 |
| LAYTOYAJ | AMD EPYC 7313 | 24 | 60 GB | Ubuntu 26.04 | 10.200.200.x (VPN) | x86_64 |
| AI-PROCESSOR | AMD EPYC 7313 | 16 | 76 GB | Ubuntu 26.04 | 10.10.10.x (local) | x86_64 |
| Plex | AMD Ryzen 9 7945HX | 32 | 60 GB | Ubuntu 24.04 | 10.10.10.x (local) | x86_64 |
| MJACKSON | AMD Ryzen 9 7950X3D | 32 | 93 GB | Fedora 44 | local machine | x86_64 |
| MARLONJ | Apple M2 Max | 12 | 64 GB | macOS 26.6.2 | 10.200.200.x (VPN) | **arm64** |
| PRINCE | Intel i9-13900HX | 24c/32t | — | Windows | 10.200.200.x (VPN) | x86_64 |
| ELVIS | AMD Ryzen 5 4600H | 12 | 31 GB | Windows 11 | 10.200.200.x (VPN) | x86_64 |
| RANDYJ | Intel Xeon X5570 (2009) | 16 | 144 GB | Windows Server 2022 | 10.10.10.x (local) | x86_64 |
| Sting | Intel Xeon E5-2620 v3 | 8 (capped) | 188 GB (host-shared) | Ubuntu 24.04, LXC/Incus | 10.10.10.x (local) | x86_64 |

Network matters here: 10.10.10.x machines reach the primary NAS
(10.10.10.150) directly, no penalty. 10.200.200.x machines cross a VPN
link to reach it, plus the normal SMB/NFS protocol cost on top. This was
expected to matter a lot for I/O-heavy roles (VMAF scoring, chunk
concatenation) — see the ELVIS/Sting bake-off below for why that
expectation didn't fully hold up.

## Fleet role assignment

Decided 2026-08-24, per explicit user direction:

- **Encoder tier (7 machines, x86_64 only), in a defined SLOT order**:
  JJACKSON (slot 1), MJACKSON (slot 2), TITOJ (slot 3), PRINCE (slot 4),
  LAYTOYAJ (slot 5), Plex (slot 6), AI-PROCESSOR (slot 7). GPUs are
  irrelevant here — software encoding (SVT-AV1/x265) is used fleet-wide,
  no hardware encode path is in use currently, so machines without a real
  GPU aren't disadvantaged.

  **Revised 2026-08-24**: Plex and AI-PROCESSOR moved to the last two
  slots (were slots 5-6). Both have other earmarked tasks competing for
  their time, so they're still available to pull into chunk-parallel work
  when needed, but the lowest-numbered-slots-first rule (below) means
  they're only actually used once a title needs more than 5 machines'
  worth of chunks — favoring the five fully-dedicated machines first.

  **The slot order is not just a roster — it's a real design requirement,
  per explicit user direction**: when a title needs fewer than 7 machines'
  worth of chunks, use the lowest-numbered slots first (4 chunks needed →
  slots 1-4 only); when it needs all 7, use all in order. This makes chunk-
  to-machine assignment **deterministic**, not the fully self-organizing
  atomic-claim free-for-all the current (Layer 1, pre-redesign)
  `chunk_claim_next()` uses — chunk N maps to a specific slot/machine by
  design, not by whichever machine happens to poll first. The reason: pure
  self-organizing claims make a specific chunk's *origin* untraceable after
  the fact (any of N idle machines could have grabbed it) — if a
  concatenated output shows a defect isolated to one chunk, deterministic
  slot assignment means that chunk's encoding machine is known from its
  index alone, so a real problem can be traced to "this is an encoder-N
  issue" vs. "this is a codebase issue every machine would hit" without
  needing to have logged which machine claimed what at the time. **Not yet
  implemented** — `chunk_claim_next()` (still the pre-redesign Layer 1
  logic, unchanged since the fork) is pure atomic self-claim with no slot
  concept; a deterministic slot-based assignment scheme is real new
  orchestrator-adjacent logic, to be designed alongside RANDYJ's
  orchestrator role rather than bolted onto the existing claim primitive
  in isolation.
- **MARLONJ (arm64) deliberately excluded from the encoder tier.** Real,
  already-documented precedent: MARLONJ needed a dedicated SVT-AV1 parity
  fix (rebuilt from source at the exact fleet commit, swapped into the
  Homebrew dylib slot) because its build didn't match the rest of the
  fleet's encoder output closely enough — see
  `project_marlonj_svtav1_parity_fix_2026_08_22` memory. Keeping the
  encoder tier architecturally homogeneous removes an ongoing maintenance
  burden and a source of subtle cross-machine output variance, which
  matters more now that multiple machines' chunk outputs get concatenated
  into one file.
- **MARLONJ's new role: scene-detection engine** (Phase 5 of the original
  chunk-parallel plan — shot-cut-based chunk boundaries instead of fixed
  time intervals). **Not yet built.** This assignment reserves MARLONJ for
  that work; there is no code for it on either branch yet.
- **ELVIS and Sting: VMAF generation** ("before" baseline scores and
  "after" final-encode scores), intended to run continuously against the
  queue rather than inline with each encode as today. See bake-off results
  below — both are viable, ELVIS is the current lean.
- **Sting: concatenator + final validation**, its already-established role
  from the earlier verifier bake-off (`project_chunk_parallel_verifier_bakeoff_2026_08_22`
  memory) — "runs free alongside encoding" beat raw speed there. Also the
  general home for I/O-bound-not-CPU-bound tasks.
- **RANDYJ: orchestrator / log evaluator.** Explicitly not an encoder
  (weakest CPU in the fleet, 2009 Xeon) — well-suited to log-aggregation
  and coordination work that isn't compute-heavy. See "Orchestrator
  design" below for the specific shape this takes.

## VMAF service: ELVIS vs. Sting bake-off

**Goal**: a system that runs continuously, generating "before" (source
baseline self-VMAF) scores across the queue uninterrupted, so there's
always a basis to compare a finished encode against. Today this
measurement (`measure_source_baseline_vmaf`/`Get-VesSourceBaselineVmaf`)
runs inline, once per file, on whichever machine happens to encode it —
the goal here is decoupling it into its own continuously-running service.

**Test**: identical operation (`measure_final_vmaf(src, src, 0)` — the
source-vs-itself self-comparison baseline check) against the same real
file (Transference (2020), 604.51 MB, ~85.6 min, already-AV1 source), one
run each on ELVIS and Sting, wall-clock timed.

| Machine | VMAF | Elapsed | Network path |
|---|---|---|---|
| Sting | 98.6 | 525.3s (~8.75 min) | 10.10.10.x, local, zero VPN/network penalty |
| ELVIS | 98.6 | 318.5s (~5.31 min) | 10.200.200.x, VPN + SMB penalty expected |

Identical VMAF score confirms measurement consistency between the two.
**ELVIS finished ~40% faster despite the VPN/SMB handicap** — the network-
topology theory (10.200.200.x machines should lose to 10.10.10.x machines
on I/O-heavy work) did not hold here. Leading theories, neither confirmed:
ELVIS's raw compute/ffmpeg-libvmaf build is strong enough to absorb the
network cost and still win; or Sting's 8-core cap (from an earlier,
unrelated CPU-contention fix) is a bigger bottleneck for this workload than
network path. **Not yet tested**: a network-isolated version of this same
comparison (pre-stage the file to local disk on both machines first, time
only the compute) — queued as a follow-up if the ELVIS-vs-Sting question
needs to be revisited with the network variable actually controlled for.

**Current lean**: ELVIS as primary VMAF-generation service, Sting stays
focused on its concat/validation role. Not yet finalized as a committed
decision — no code changes made based on this yet.

## Staging server (10.200.200.151, OS2) for the encoder tier — OS1 (.150) built in parity as fallback

**Problem**: encoder-tier machines on 10.200.200.x cross a VPN link to
read source files from the primary NAS (10.10.10.150) — a real, if not
yet precisely measured, I/O tax for every encode job on 6 of the 7
encoder-tier machines.

**2026-08-23/24 incident, why both boxes are built out**: OS2
(10.200.200.151) went unreachable overnight 8/22→8/23 and needed a
physical cold-boot. Post-mortem via `journalctl -b -1` on OS2 found no
USB-specific kernel error (contrary to the initial "USB failures"
suspicion) — instead the previous boot's log simply stops dead at
08:07:06 PDT with no shutdown target reached, no panic/oops, consistent
with a hard hang rather than a logged software fault. Root cause not
pinned down (candidate: the onboard NIC flapped twice earlier that night —
an OS-level link down/up at ~20:20 on 8/22, and an independent BMC-level
"all links down" fault in the iLO IML at 03:18:21 on 8/23 — neither alone
fatal, final hang ~5h after the second one). **Decision: use OS2 as the
primary staging target (nearly 3.5x the free space of OS1 — 27.2TB vs
8TB), but build the identical dataset/share structure on OS1 as a live
fallback**, so a repeat OS2 hang doesn't block staging entirely — just
requires re-pointing `CONVERT_STAGING_MEDIA_ROOT` (below) at OS1 instead.

**Also fixed 2026-08-24**: SSH password login to OS2 was blocked by a
per-user flag (`truenas_admin`'s `ssh_password_enabled: false`), which
silently overrides the SSH *service's* global `passwordauth: true` — a
TrueNAS SCALE gotcha (per-account gate is separate from the service-level
toggle and from `password_disabled`, which only covers the web UI).
Fixed via `PUT /api/v2.0/user/id/<id>` `{"ssh_password_enabled": true}`.
OS1's `admin` account already had this set correctly. Worth checking this
flag on any TrueNAS box that inexplicably rejects password SSH despite
correct credentials.

**Built 2026-08-24, both boxes, identical structure**:
- Dataset `<pool>/Shares/VESStaging` (`Minnie/Shares/VESStaging` on OS1,
  `MeiMei/Shares/VESStaging` on OS2) — POSIX ACL, DISCARD aclmode,
  SENSITIVE casesensitivity, LZ4 compression, 128K recordsize, `0777
  root:root` on-disk permissions.
- SMB share `VESStaging` and NFS share, both pointed at that dataset,
  both enabled, comment `"video-encoder-script chunk-parallel staging
  cache"`.
- End-to-end verified on OS2 (OS1 was verified 2026-08-22): mounted the
  primary NAS's `BigMomma/Media` NFS export read-only, `rsync
  --checksum`'d a real ~246MB file into `VESStaging`, confirmed identical
  size + SHA-256 on both sides, cleaned up the test file and the temp
  mount.

**Mechanism**: encoder-tier machines on 10.200.200.x read their source
file from OS2 instead of crossing the VPN to the primary NAS at .150.
TrueNAS's native rsync task feature (not a custom VES-script-driven copy)
should handle the actual transfer + checksum validation (`--checksum`) in
production, once the queue/orchestrator exists to trigger it — the manual
rsync above only proves the mechanism, it isn't the on-demand production
path yet (see Open Items).

**Fleet-wide reachability confirmed 2026-08-24** — every 10.200.200.x
fleet machine can reach both `VESStaging` shares (`\\10.200.200.150` and
`\\10.200.200.151`), verified with a real write+read+cleanup on each:

- **Linux (NFS)**: MJACKSON, TITOJ (both pre-existing), JJACKSON, LAYTOYAJ
  (new) — `/mnt/MinnieS` and `/mnt/MeiMeiS`, `noauto,x-systemd.automount`
  fstab entries (the same fix that solved JJACKSON's earlier NFS
  boot-race bug).
- **macOS (NFS)**: MARLONJ — manual `mount -t nfs` at `/Volumes/MinnieS`/
  `/Volumes/MeiMeiS`, matching how its existing primary-NAS mounts are
  done (no fstab-equivalent persistence exists on this box). Also found
  and removed a stray broken symlink at `/Volumes/Minnie -> /`, unrelated
  leftover, harmless but confusing.
- **Windows (SMB)**: PRINCE, ELVIS — **not** a persistent drive mapping;
  the working pattern is a plain inline-credential `net use
  \\<host>\VESStaging <password> /user:MCE\worker` issued at the top of
  whatever script needs the share, run from the *local* `worker` account
  each machine's automation already runs as. No domain-account switch,
  scheduled task, or elevated rights needed for this — see the debugging
  trail below for what those turned out to be red herrings for.

**Windows debugging trail (2026-08-24), kept for the next time this class
of bug shows up**: getting here took much longer than it should have,
because the *actual* root cause (TrueNAS-side: `admin`/`truenas_admin`
had `smb: false` at the account level, so SMB auth failed regardless of
password — separate from the SSH `ssh_password_enabled` gotcha above) was
masked by several real-but-irrelevant Windows issues investigated along
the way:
- `MCE\worker@10.200.200.104` SSH login hung — domain-qualified SSH login
  syntax doesn't work against this OpenSSH-Windows setup.
- Renaming the local `worker` account to force SSH's bare-username
  resolution onto the domain account was inconclusive (the renamed local
  account's SID kept authenticating) and was reverted rather than pursued
  further.
- `Register-ScheduledTask -LogonType S4U` reliably fails with "Access is
  denied" over SSH even for a domain account in local Administrators with
  non-filtered privileges confirmed (`whoami /priv` showing
  Backup/Restore enabled) — looks like a hardened WMI/TaskScheduler
  namespace ACL on this domain image, not a rights gap. Root cause not
  fully pinned down; legacy `schtasks.exe` was used as a workaround
  instead (see below), since it doesn't touch that CIM provider.
- `schtasks /create /ru MCE\worker` **without** an explicit password only
  ever produces `Logon Mode: Interactive only` (won't run
  non-interactively) — true S4U/password logon types aren't reachable via
  `schtasks.exe`'s classic syntax without `/rp`.
- With `/rp` supplied, the task registered correctly (`Logon Mode:
  Interactive/Background`, matching the fleet's other working `VES*`
  tasks) but then failed at run time (`Last Result: 1`,
  `ERROR_INVALID_FUNCTION`) until `MCE\worker` was temporarily added to
  local Administrators — **removed again once the simpler `net use`
  fix above was found to not need it at all.**
- `nltest /user:worker` unexpectedly dumped raw NT/LM password hash
  material into command output — flagged to the user, that account's
  password should be treated as exposed/rotated; `nltest /user:` should
  not be run this way again.

**Net takeaway**: the TrueNAS-side `smb` flag was the only real blocker.
Once fixed, the correct Windows-side pattern is the simple inline-
credential `net use` above — no domain-account migration, no scheduled
task, no elevated rights required. All local-admin-group and
batch-logon-right grants made to `MCE\worker` on PRINCE during this
investigation were reverted back to the pre-investigation state.

**Trigger model, per explicit user direction**: cached on-demand, but
*overlapped* — not "encoder waits for the file to arrive." Once a title
enters the queue, the staging transfer to .151 and the VMAF baseline
generation (ELVIS/Sting) both kick off in the background, concurrently,
ahead of any encoder claiming that title. By the time an encoder is ready
to start, both should already be done, so all encoders can start
essentially simultaneously against their respective (already-local)
sources rather than serializing on a transfer.

**This is not a standalone piece** — the trigger ("title entered the
queue") only exists once the orchestrator/queue system below is real.
Staging and the orchestrator converge into one system, not two things to
keep in sync.

**Path portability**: real precedent already exists in this codebase for
per-machine-configurable paths — `CONVERT_CIFS_MOUNT_SRC`/
`CONVERT_CIFS_MOUNT_DST`/`CONVERT_CIFS_CREDENTIALS` in `ves-config.sh`.
Proposed extension: a new `CONVERT_STAGING_MEDIA_ROOT` env var, empty by
default everywhere except the 10.200.200.x encoder-tier machines, each set
to that machine's own correct local path into the .151 share (accounting
for the same per-OS path-convention differences already seen this session
— Linux `/mnt/...`, macOS `/Volumes/...`, Windows `\\...` UNC). Logic: for
a given title, if `CONVERT_STAGING_MEDIA_ROOT` is set *and* a hash-
verified staged copy exists there, read from it for the actual encode I/O;
otherwise fall through to reading the origin path directly, exactly as
today. **Logs and writes always target the origin path** regardless of
staging — staging only ever substitutes the read side, never becomes the
source of truth.

**Hash-verify timing**: verify once, right after the staged copy is
written (rsync's own `--checksum`, or a dedicated verify pass if not using
rsync's built-in), then trust the copy from then on. Re-hashing a
multi-GB file on every read would eat most of the benefit staging is
meant to provide, and conflicts with nothing in this project's existing
"verify before trust" discipline — the verification just happens once,
at write time, like every other staging mechanism already in this
codebase (RAM-disk staging, disc-extraction staging).

**Not yet built**: the `CONVERT_STAGING_MEDIA_ROOT` lookup+fallback logic
itself doesn't exist as code on either branch yet — the underlying
dataset/share infrastructure on OS1 and OS2, the manual rsync-mechanism
proof, and now fleet-wide reachability from every 10.200.200.x machine
(NFS on Linux/macOS, `net use` on Windows — see above) are all done.
Primary target is OS2 (10.200.200.151), with OS1 (10.200.200.150) built
identically as a fallback target given OS2's 8/22-8/23 unplanned outage.

## Orchestrator design (RANDYJ)

**Why centralize now, when the fleet was deliberately decentralized
before**: whole-file encoding needed no coordinator — each machine's claim
was self-contained. Chunk-parallel breaks that: multiple machines now
produce pieces of one file that must be assembled in order and validated
together. That's inherently a coordination problem.

**Key design constraint, to avoid trading a resilient architecture for a
fragile one**: the chunk-manifest system already provides a shared,
durable *data* model — the manifest file on the NAS, atomic per-chunk
claims, status fields. That's already centralized in the sense that
matters (one source of truth), just without an active process deciding
things. RANDYJ's job is to be a live process that watches and enforces
consistency over that *existing* shared state — confirming
chunk/verify/concat success or failure, aggregating logs, driving the
queue forward, triggering the staging+VMAF-baseline overlap described
above, and handling cleanup tasks that fall through the cracks of
individual encoder tasks — **not** to become a dispatcher that other
machines must ask permission from before acting. If RANDYJ is down,
encoders should still be able to self-organize via the existing atomic
claims (degraded — no live confirmation, no queue-driven staging overlap —
but not stalled).

**Not yet built**: no orchestration protocol, queue format, or RANDYJ-side
code exists yet on either branch. This section is scope, not
implementation.

## Open items, explicitly not yet resolved

1. Orchestrator protocol/queue format — how RANDYJ actually watches the
   manifest state and what "the queue" concretely is (a new shared file?
   a lightweight service RANDYJ runs?).
2. Staging-cache module (`CONVERT_STAGING_MEDIA_ROOT` lookup + fallback
   logic, including OS2→OS1 fallback target switching) — designed above,
   not implemented.
3. Real *on-demand/automated* rsync task setup between 10.10.10.150 and
   10.200.200.151 — the manual mechanism is proven (2026-08-24, real file,
   checksum-verified) but not yet wired to run automatically; TrueNAS-
   native rsync task vs. something VES-script-driven still to be decided
   operationally (likely TrueNAS-native, per the reasoning above, but not
   confirmed).
4. Network-isolated ELVIS-vs-Sting re-test (pre-staged local file, compute-
   only timing) — queued, not run. Current bake-off result stands as the
   real-world/as-deployed number in the meantime.
5. Scene-detection engine on MARLONJ (Phase 5) — no code on either branch.
6. The original chunk-parallel VMAF false-positive investigation
   (`project_chunk_parallel_vmaf_false_positive_2026_08_24` memory) is
   independent of this redesign — v5.1.1Z/Z's `measure_final_vmaf_sequential`
   fix already shipped on `main`/5.x and should be brought over to 6.x
   as part of the full-codebase fork (it already is, since 6.0.0A is a
   direct copy of 5.1.2A which includes it) — no further action needed
   here, just noting it's already inherited correctly.
7. **Resolved.** A live re-encode test of Transference (2020) on JJACKSON,
   started to validate v5.1.2A's sample-prediction-accuracy tracking, ran
   for 80+ minutes without reaching a decision (the AV1-vs-x265 bakeoff's
   iterative per-point VMAF-targeted CRF search is far slower than
   expected) and was superseded by the content-variance-gate investigation
   below, which needed the same fleet machines. Killed across JJACKSON/
   LAYTOYAJ/Plex; no chunk-parallel data was ever produced by this run.
8. `main`/5.x has since been surgically cleaned of all chunk-parallel code
   (v5.1.2B) — see that release's CHANGELOG entry. This design doc's home
   is now exclusively this branch; `main` carries no chunk-related code or
   documentation going forward.

## Content-complexity-variance gate: tried, real-world tested, reverted

2026-08-24, per explicit user direction, following a "does it make sense
to gate on more than just duration" question: `chunk_should_split()` was
extended with a second gate on top of the existing duration threshold —
`chunk_content_variance_ratio()`, a cheap probe (reusing
`find_complexity_sample_points()`'s `ffprobe -read_intervals` packet-size-
only sampling — no decode, no encode, sub-second per file) computing a
high/median compressed-packet-size ratio across ~15 sample windows. The
premise: chunk-parallel's real value is per-scene bit reallocation (the
"Netflix chunk model" reasoning this whole initiative started from), so a
long but content-consistent source has little real opportunity for it to
exploit and is better served by a single-machine whole-file encode even
past the duration bar.

**Real validation, not just the premise, was tested** — first two titles,
then a 17-title sample deliberately spanning known reference points
(extreme action: John Wick, Mad Max Fury Road, Mad Heidi; slow/
contemplative: The Tree of Life, Barry Lyndon, There Will Be Blood, The
Master; anime across several types; a static single-camera opera; a short
anime TV episode):

| Title | Category | Ratio |
|---|---|---|
| John Wick (2014) | extreme action | **10.04** |
| 5cm Per Second (2007) | slow anime | 6.82 |
| The Tree of Life (2011) | slow/contemplative | 4.91 |
| Transference (2020) | thriller | 5.29 |
| Your Name (2016) | mixed anime | 3.75 |
| The Master (2012) | slow | 3.68 |
| Barry Lyndon (1975) | slow/static-long-takes | 2.89 |
| Mad Heidi (2022) | action | 2.82 |
| 07-Ghost S01E01 | short anime TV | 2.27 |
| Mad Max Fury Road (2015) | extreme action | **2.21** |
| Ghost in the Shell (1995) | moody anime | 2.13 |
| The Matrix (1999) | action | 1.94 |
| La Boheme (1988) | static opera | 1.78 |
| There Will Be Blood (2007) | slow-burn | 1.65 |
| Spirited Away (2001) | whimsical anime | 1.48 |
| Perfect Blue (1997) | psychological anime | 1.41 |
| Akira (1988) | action anime | 1.39 |

**No coherent genre/pacing correlation.** John Wick scored highest of all
17; Mad Max Fury Road — arguably the most kinetically-edited action film
in the sample — scored near the bottom, alongside Mad Heidi. "Slow" films
spanned 1.65-4.91 with no consistent direction. Action anime clustered at
the bottom. A smaller earlier round (2 titles) additionally cross-checked
the metric against real sample-clip encoded-size spread at the same low/
median/high points (fixed-CRF, no VMAF search) and found the two
real-encode statistics (high/low vs. high/median) disagreed with each
other on title ranking, let alone with the packet-size proxy.

**Leading explanation, per explicit user direction, not further
investigated**: every test source is an already-encoded release file, not
raw/lossless content. The metric reflects whatever rate-control decisions
*that prior encoder* made — one step removed from the source's true
underlying content complexity, and plausibly smoothed over or distorted
by it in ways a genre label can't predict or correct for.

**Outcome**: reverted. `chunk_should_split()` is duration-only again,
matching the original design. `chunk_content_variance_ratio()` itself is
left in the codebase (`ves-chunk-coordinator.sh`), unused by any caller,
as scaffolding for a future attempt with a better-grounded signal (real
scene-cut detection via `ffmpeg`'s `scdet` filter was the leading
alternative raised but not pursued; or access to true pre-encode source
material, which this fleet generally doesn't have). This section, not
deletion, is the record — so a future session doesn't re-attempt the same
packet-size-variance approach blindly without knowing it was already
tried and why it didn't hold up.

## Phase 6.1 (scoping, not yet built) — equal-slope global bit allocation

Prompted by a real, still-unexplained gap found live 2026-08-25: the
per-shot search (`resolve_per_shot_qp()`, `modules/ves-per-shot-qp.sh`)
targets a fixed VMAF (94.0 for the anime test episode,
`vmaf_target_for_source()`) independently per shot, but a real 199-shot
run's assembled qpfile measured 89.41 whole-file VMAF — a ~4.6 point gap
between what every shot's own isolated search believed it achieved and
what the single continuous encode actually delivers.

**Correction, same day**: v6.0.0G initially shipped an Av1an-style
tolerance-band early exit (stop probing the instant any sample lands in
`[target,target+0.5]`) on the belief it fixed a real quality-floor
violation in the old bisection search. That belief was wrong — verified
directly against the old search's real backed-up result for the same
shot (`shot-016.status` in the `.v1-old-bisection-backup` manifest): its
final answer was `qp=30 vmaf=94.17`, identical to the new search, not the
below-target `qp=32 vmaf=93.97` an intermediate probe line was mistakenly
read as. The old search's extra probes were real, deliberate thoroughness
(confirming no more bit-efficient QP existed between the accepted answer
and the next-worse anchor), not wasted work. Per real user pushback
(2026-08-25: "make sure we have enough potential 'points' so we're not
allocating more bits... because a closer number wasn't possible to find"),
the tolerance-band exit was reverted the same day it shipped — it traded
guaranteed bit-optimality for speed, the wrong tradeoff given this
project's own priority order (quality > size > speed last). Interpolation
for probe *placement* was kept (a pure speed win with no such tradeoff:
it still searches all the way to the same gap<=1 guaranteed-optimal
answer, just reaches it in fewer probes). See `modules/ves-per-shot-qp.sh`
for the current, corrected implementation.

This leaves the ~4.6-point gap's cause still genuinely open: isolated
per-shot VMAF measurement (short re-decoded clip, no cross-shot
reference-frame context) may systematically diverge from the same
footage's VMAF inside one continuous encode — not yet confirmed.

This section scopes a third, more fundamental question raised by the
user: is "every shot independently hits the same fixed VMAF" even the
right objective, or is Netflix's actual published approach (per-shot
rate-distortion convex hulls + a single global equal-slope operating
point, see
[Dynamic Optimizer](https://netflixtechblog.com/dynamic-optimizer-a-perceptual-video-encoding-optimization-framework-e19f1e3a277f))
a better fit — allocating bits so every shot's *marginal* quality-per-bit
is equalized, rather than chasing an identical absolute quality number
everywhere regardless of how cheaply or expensively each shot can reach
it.

### Why this doesn't require new encode/VMAF compute

The expensive part of Phase 6 — real sample encodes + VMAF measurement
per shot — is unchanged. `resolve_per_shot_qp()` already produces 2-6 real
`(QP, VMAF, bytes)` samples per shot as a side effect of its own search;
today it keeps only the winner and discards the rest
(`shot_search_claimed()` currently writes a single `qp=`/`vmaf=` pair to
each shot's `.status` file). The equal-slope allocator is a **pure
post-processing pass over data we're already generating** — no new
ffmpeg/VMAF calls, just math over retained sample points. The real cost
is a data-model change (retain the full sample set, not just the winner)
and a new allocation stage between "all shots searched" and "assemble
qpfile."

### Concrete algorithm (standard Lagrangian/water-filling, adapted to a quality floor instead of a bit budget)

Netflix's own formulation targets a fixed bit *budget* (their per-title
ladder use case: given B total bits, maximize quality). Ours is the dual
problem — given a quality *floor* (the existing VMAF target), minimize
total bits while never dropping below it, which is the same Lagrangian
machinery solved by walking λ (the "shadow price" of one more bit) in the
other direction:

1. **Per-shot hull construction.** For each shot, filter its retained
   `(QP, VMAF, bytes)` samples down to the Pareto-optimal subset (drop any
   point convex-dominated by a combination of its neighbors — standard
   upper-hull-in-quality/lower-hull-in-bits check). With only 2-6 samples
   per shot this is a small, cheap computation, not a real "convex hull
   library" problem.
2. **Per-shot local slope.** Between adjacent hull points, the local slope
   is `Δvmaf / Δbytes` — how much quality one more byte buys *at that
   point on that shot's curve*. Flatter/easier shots (e.g. static scenes)
   have some hull segments with very high slope (cheap quality); harder
   shots (motion, grain, detail) have uniformly lower slope everywhere.
3. **Global λ search.** For a candidate shadow price λ, walk every shot's
   hull and pick whichever point's local slope is closest to λ (or,
   equivalently, the highest-VMAF point whose *marginal* slope to the next
   point exceeds λ — standard water-filling stopping rule). Sum the
   resulting whole-title bits and duration-weighted mean VMAF. Bisect on λ
   until the duration-weighted mean VMAF lands at the target (94.0) —
   mirrors `vmaf_crf_search_internal()`'s own bisection shape, just over λ
   instead of CRF/QP, and entirely in-memory (no new encodes per λ trial).
4. **Result:** a per-shot QP assignment where every shot sits at
   (approximately) the same marginal bits-per-quality point instead of the
   same absolute VMAF — cheap shots end up higher quality than target,
   expensive shots end up allowed to sit slightly under the flat per-shot
   target *as long as the duration-weighted whole-title average still
   clears it* (a materially different guarantee than today's "every shot
   individually clears target," worth flagging as a real policy change,
   not just an implementation detail — needs explicit user sign-off before
   shipping, since "no quality regression" today is enforced per-shot and
   this would relax that to per-title on average).

### Real costs / open questions, not yet resolved

- **Status-file format change.** `shot-NNN.status` currently stores one
  `qp=`/`vmaf=` pair. Needs to become a small list of `(qp,vmaf,bytes)`
  triples (the full retained sample set) — a breaking format change for
  `assemble_qpfile_from_shot_manifest()` and any debug tooling that reads
  today's format. `_write_shot_qps_to_qpfile()`'s contract (one QP per
  shot) stays the same downstream of the allocator; only what's stored
  *before* the allocator runs changes.
- **Minimum samples per shot: resolved by the tolerance-band revert
  above**, not a separate concern anymore. With the early exit reverted,
  the search always runs to gap<=1 (true integer precision), so every
  shot naturally retains 3-6 real samples -- already enough points for a
  meaningful local-slope estimate. Still worth layering the dynamic-crf-
  style blended bisection/interpolation refinement (queued this session)
  on top for better-placed samples near the sigmoid's flat extremes, but
  it's no longer a blocker for this design.
- **Per-shot VMAF measurement gap (cause 2 above) is still unresolved**
  and affects this design too: if isolated per-shot VMAF systematically
  diverges from in-context VMAF, the allocator's hull points are built on
  the same potentially-biased measurements as today's search, and the
  bisection-on-λ step would converge to a whole-title *predicted* average
  that still doesn't match the real measured `measure_final_vmaf_
  sequential()` result. Worth validating with a real before/after
  comparison (predicted duration-weighted mean vs. actual whole-file
  measurement) before trusting the allocator's own quality guarantee.
- **Not yet built.** This section is scope only, per explicit user
  direction to design in parallel with the in-flight gap-closure test
  rather than block on its result. That test's search algorithm changed
  mid-flight (tolerance-band exit shipped then reverted same day, see
  above) -- its real numbers are still a useful data point on interpolation
  alone (no tolerance shortcut), just not the "does tolerance close the
  gap" test originally intended. Implementation of this allocator should
  wait for that run's real numbers before deciding how much is still
  needed.

**Update 2026-08-25/26 -- built, and the target-VMAF framing above was
wrong.** `assemble_qpfile_via_equal_slope()` (bisect λ against a target
duration-weighted mean VMAF, as designed above) was implemented and
tested for real on anime and Reacher. Real finding, driven by direct user
pushback ("why do we need max quality everywhere... the point of the
dynamic cp is that scenes that do not benefit from higher bits are
reduced.. and those that need higher bits get them"): a target-VMAF
bisection is fundamentally the wrong lever. Isolated per-shot data's own
naive ceiling is often unreachable OR already exceeded by the real
standard encode, and either case collapses the bisection to its floor
(λ->0, "max quality everywhere") -- a trivial, non-differentiated result
that never exercises real redistribution.

**Fix, shipped same window**: `assemble_qpfile_via_equal_slope_budget()`
bisects λ against a total **byte budget** instead (Netflix's own actual
published formulation, not the quality-floor adaptation this doc
originally proposed) -- a budget within [min-bytes-everywhere,
max-bytes-everywhere] is always achievable, so the bisection can never
degenerate to a floor/ceiling no-op. Real results, both real full
encodes measured via `measure_final_vmaf_sequential()` (not estimates):

| Title | Budget | Real VMAF | vs. standard | Size vs. standard |
|---|---|---|---|---|
| Reacher S01E01 | 100% | 94.25 | +0.05 | -0.95% |
| Reacher S01E01 | 95% | 93.92 | -0.28 | **-7.4%** |
| Reacher S01E01 | 90% | 93.31 | -0.89 | -14.9% |
| ST Discovery S01E02 | 100% | 90.56 | -0.30 | -3.2% |
| ST Discovery S01E02 | 95% | 90.11 | -0.75 | -9.8% |

User's own visual review (2026-08-26) confirmed 95% looks good on
Reacher; 90% showed "notable distortion" -- matching the VMAF delta
being real, not just a measurement artifact. **95% budget is the
validated sweet spot for live-action**, not 100% or 90%.

Note Discovery's 100%-budget result is a real quality *cost* (-0.30
VMAF), unlike Reacher's 100%-budget result (+0.05, a wash-to-slight-win)
-- the allocator is not a guaranteed win at parity for every title; it
depends on the shape of that title's own per-shot marginal-value curves.
Discovery is loaded with VMAF-hostile flashy/VFX content (one shot's own
best-achievable isolated VMAF was 9.41 even at max quality -- a
shimmering energy-effect texture VMAF scores harshly regardless of
encode quality, confirmed via direct visual spot-check, not a bug), and
on this content mix the redistribution net cost slightly more than it
saved even at equal spend.

**Real bug found and fixed the same session (v6.0.0M)**: shot-clip
extraction in `_vmaf_score_shot()` used `-ss/-to` as *input* options
combined with `-c copy` -- confirmed to overshoot the intended shot end
by 1.5-3x (28->74 frames and 212->296 frames on two real repro shots,
Star Trek Discovery), because stream-copy cannot cut mid-GOP and rounds
the end boundary up to the next keyframe it can safely stop at,
regardless of whether `-to` or `-t` is used or where it's placed. This
silently fed extra trailing (often unrelated) content into every shot's
VMAF probe and inflated its recorded byte cost -- the exact number the
budget allocator's own λ bisection depends on. Fixed via accurate seek
*after* `-i` into a lossless `ffv1` re-encode (same "don't trust `-c
copy` for boundary-precise clips" lesson as the earlier windowed-VMAF
false-positive fix) -- verified frame-exact against ground truth.
Deployed fleet-wide 2026-08-26; all per-shot search data collected
*before* this fix (Reacher, the anime titles, and Discovery's first
pass) was built on inflated per-shot byte figures and should be treated
as approximate, not authoritative, until re-run.

## Phase 6.2 (scoping, not yet built) -- deprioritize low-value segments (intros/credits)

Explicit user direction 2026-08-26: the equal-slope budget allocator
already redistributes bits by marginal VMAF value, but has no concept of
*viewer* importance -- a shot's byte cost/VMAF curve says nothing about
whether anyone actually watches it closely. Opening titles and end
credits are the obvious case: viewers skip or half-watch them, so
spending bits there at the same rate as main content is real waste that
could instead widen the effective budget for everything else -- "we
could potentially move to 90% and keep the quality high for the primary
content" if low-value segments are deliberately starved first.

**Detection, checked against real files 2026-08-26**: chapter markers on
this library's files (Discovery, Reacher, one anime title) carry no
semantic labels ("Chapter 01", not "Intro"/"Credits") but the boundaries
themselves are real structural cut points (Reacher's chapter 2 starts at
0:56 -- a plausible cold-open/titles cut; its last chapter starts at
50:59 in a ~55min episode -- a plausible credits-length remainder).
Two-pronged plan:
- **Credits**: last chapter, gated by a plausible duration range (30s-5
  min) plus a cheap low-motion/low-detail confirmation check (scrolling
  text over a static/simple background has a distinct visual signature)
  so a short final scene doesn't get misclassified.
- **Opening titles**: chapter boundaries alone aren't reliable here
  (cold-open length varies episode to episode -- explicit user example,
  2026-08-26: Star Trek Lower Decks often runs ~2-3min of real story,
  THEN the intro, THEN back to story, so any fixed-position or
  fixed-duration heuristic misclassifies real content). Per explicit
  user direction, don't reinvent this: use cross-episode audio
  fingerprinting, the same core technique Jellyfin's "Intro Skipper"
  plugin and Plex's built-in intro detection are both built on
  (Chromaprint/AcoustID) -- comparing audio across a handful of episodes
  of the same show finds the repeated segment regardless of where it
  falls in any single episode, which is exactly what handles the
  Lower Decks case correctly (fixed-position heuristics can't).
  Confirmed available on this machine already: `/usr/bin/fpcalc`
  (Chromaprint CLI) and a Python `chromaprint` binding, both present
  without needing to install anything new. More work than the credits
  heuristic; can ship after it as a separate increment.

**Mechanism**: composes with the existing byte-budget allocator without
touching its bisection core. Flagged shots get an importance weight
`w < 1` (tunable, not yet chosen) applied inside the per-shot selection:
`argmax(w * vmaf - λ*bytes)` instead of `argmax(vmaf - λ*bytes)` for
those shots only. This systematically biases the allocator to accept
lower quality on low-value shots for the same marginal byte cost,
freeing bytes for `w=1.0` main content within the *same* total budget --
directly enabling a lower overall budget target (e.g. 90% instead of
95%) without the quality cost seen in the real 90% test above, since
that cost was concentrated on main content the viewer actually watches,
not on intros/credits.

**Open questions, not yet resolved**: how `w` should be chosen (fixed
constant vs. tunable per-profile); whether misdetection risk (a real
scene wrongly flagged as credits) warrants a visual confirmation gate
before trusting the heuristic in production; whether this should be
default-on or opt-in given it's a real policy change (some viewers watch
intros/credits and would notice). Not yet built -- scope only.
