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

- **Encoder tier (7 machines, x86_64 only)**: JJACKSON, MJACKSON, TITOJ,
  PRINCE, AI-PROCESSOR, Plex, LAYTOYAJ. Same claim-based model as today,
  just the roster. GPUs are irrelevant here — software encoding
  (SVT-AV1/x265) is used fleet-wide, no hardware encode path is in use
  currently, so machines without a real GPU aren't disadvantaged.
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

## Staging server (10.200.200.151) for the encoder tier

**Problem**: encoder-tier machines on 10.200.200.x cross a VPN link to
read source files from the primary NAS (10.10.10.150) — a real, if not
yet precisely measured, I/O tax for every encode job on 6 of the 7
encoder-tier machines.

**Proposal**: a same-subnet staging replica on 10.200.200.151 (confirmed
live 2026-08-24: SSH+HTTPS reachable, sub-ms ping from that subnet,
currently unused — a second TrueNAS box, distinct from both the primary
NAS at 10.10.10.150 and 10.200.200.150). Encoder-tier machines on
10.200.200.x would read their source file from .151 instead of crossing
the VPN to .150. TrueNAS's native rsync task feature (not a custom
VES-script-driven copy) handles the actual transfer + checksum validation
(`--checksum`), rather than reinventing that logic.

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

**Not yet built**: none of this exists as code on either branch yet. Test
target is 10.200.200.151 specifically (currently unused, per explicit user
direction, to avoid touching anything already relying on .150).

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
   logic) — designed above, not implemented.
3. Real rsync task setup between 10.10.10.150 and 10.200.200.151 — not
   yet configured; TrueNAS-native rsync task vs. something VES-script-
   driven still to be decided operationally (likely TrueNAS-native, per
   the reasoning above, but not confirmed).
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
7. A live re-encode test of Transference (2020) on JJACKSON (v5.1.2A,
   testing the new sample-prediction-accuracy tracking from that release)
   was started before this design-consolidation pass and is still running
   in the background as of this writing — the AV1-vs-x265 bakeoff sample-
   test has taken far longer than expected (multiple hours, still no
   decision as of the last check) and has not yet produced a real chunk-
   parallel run to validate. Left running (harmless), not yet resolved.
