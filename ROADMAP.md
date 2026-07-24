# Roadmap

Living document of planned/recommended future work on this project. Unlike
`CHANGELOG.md` (what already happened) or `SESSION-HANDOFF-*.md` (a one-off
point-in-time snapshot from a specific past session), this file is meant to
stay current — update it whenever a new future action is identified, and move
an item to `CHANGELOG.md` once it's actually done (don't leave it duplicated
in both). Written so any future session/agent can pick up this project cold
with no loss of context.

## Ultimate goal

Turn this script loose, unattended, across ~200TB of home media library
(fleet-wide, 8 machines) to re-encode the whole thing down to MKV+AV1/x265.
Everything below is in service of building enough confidence in correctness
and safety to actually do that at scale without a human needing to babysit
it or discover data loss after the fact.

## Immediate next steps

1. **Relaunch confidence-batch-test jobs on PRINCE and GruntBox2.** Both
   machines' 2026-07-24 encode jobs (PRINCE: 7Seeds; GruntBox2: 009-1) got
   killed mid-run by the repeated WSL2 restarts during the fs-cache custom-
   kernel work (see the fs-cache section below) — no process running on
   either as of the last check. All other 5 Linux machines finished their
   confidence-batch-test runs cleanly on v5.0.32R. Relaunch both once
   convenient (same titles are fine to resume, or pick fresh ones — check
   codec + any pre-existing `convert-v4.log` first, as usual).

2. **Investigate the "A Centaur's Life (2017)" corruption on Plex.** All 12
   episodes hit genuine `mkvalidator` structure errors during the 2026-07-24
   confidence batch test, and the script's own remux-repair attempt failed
   on all 12 too — all correctly deferred to that folder's `Deferred/`
   subdirectory rather than silently corrupted or skipped. This is not a
   script bug (verified via the per-folder `convert-v4.log`, not just piped
   stdout — see the Memory/nuance section below). Given ALL 12 episodes hit
   the identical failure, this smells like a bad rip/transfer of the whole
   season rather than 12 independent coincidental corruptions — worth a
   human look (re-rip? re-download? check the original source disc/file?)
   before assuming this is unrecoverable.

3. **Backfill `to-review.md`.** Per the standing "every encode test/batch
   gets a durable file-by-file review report" practice, `to-review.md`
   (`/home/docm/to-review.md`) hasn't been updated since 2026-07-20 — it's
   missing the full PRINCE/Crystalight/GruntBox2 v5.0.32Q threshold-retest
   results (2026-07-24) and the new v5.0.32R confidence-batch-test results
   (docm/PRINCE/MacFedora/Plex/GruntVM/AI-PROCESSOR/Crystalight, same date,
   GruntBox2 still pending). Needs a proper backfill pass once GruntBox2's
   run is in too, so the whole round is captured in one place rather than
   scattered across conversation history.

## Known-but-not-yet-fixed infrastructure gaps

4. **GruntVM and AI-PROCESSOR still use the old flat NFS mount convention**
   (`10.x.x.150:/mnt/BigPoppa/Media` mounted directly at `/mnt/BigPoppa`, no
   nested `/Media` segment) — confirmed still broken as of the 2026-07-24
   confidence-batch-test launch (both failed with "Path not found" on the
   nested-convention path, worked once given the flat path instead). Plex,
   docm, PRINCE, MacFedora, GruntBox2, and Crystalight (via its own
   `/Volumes/...` convention) were already standardized to the nested
   convention back on 2026-07-23. Fix: edit `/etc/fstab` on both machines
   the same way it was done for Plex (`sudo cp /etc/fstab /etc/fstab.bak-*`,
   change the NFS source from `.../BigPoppa/Media` to `.../BigPoppa`, keep
   the local mount point at `/mnt/BigPoppa`, remount). Lower risk than the
   Plex migration was — no database to rewrite, just a mount + `find`/`ls`
   verification pass afterward. **Every script invocation on these two
   machines needs to keep using the flat path (`/mnt/BigPoppa/Anime/...`,
   no `/Media/`) until this is fixed** — don't forget when picking future
   test titles for them.

5. **Crystalight path uniformity via symlinks — not yet executed.**
   Proposed approach (from 2026-07-23): create `/mnt/BigMomma`,
   `/mnt/BigPoppa`, `/mnt/BabyBear` directories on Crystalight, each
   containing a `Media` symlink pointing at the corresponding existing
   `/Volumes/...` mount (`/Volumes/Media` → BigMomma/Media,
   `/Volumes/BigPoppaMedia` → BigPoppa/Media, `/Volumes/BabyBearMedia` →
   BabyBear/Media), so `/mnt/BigMomma/Media/Movies/...` resolves identically
   to the Linux convention fleet-wide. Currently Crystalight still needs its
   own `/Volumes/...`-style paths passed explicitly to every invocation.

6. **Crystalight has no `timeout`/`gtimeout` binary** (confirmed missing,
   coreutils never installed via Homebrew) — the script's own fallback
   (background+poll+TERM/KILL) covers this, but it was the root cause of at
   least one real false "stalled mount" skip previously (Top Gun - Maverick,
   before its correct re-encode). Installing Homebrew coreutils would give
   Crystalight a real `gtimeout` and remove this whole class of risk. Raised
   but never actioned — no explicit user go-ahead yet.

7. **Crystalight (macOS) fs-cache equivalent — not yet investigated.** See
   the fs-cache section below for the full 7-machine Linux/WSL2 fix; macOS's
   NFS client has no direct equivalent to Linux's persistent disk-backed
   fscache/cachefilesd (only in-RAM buffer caching, not persistent across
   reboots). Whether a userspace caching layer (e.g. a FUSE-based cache proxy)
   is worth the complexity for Crystalight specifically has not been
   researched yet.

## fs-cache (FS-Cache/cachefilesd) — fleet status: 7/8 done (2026-07-24)

Goal: leverage each machine's local disk to cache NFS reads, reducing
redundant network trips to the NAS and load on the server. Final state:

| Machine | Status |
|---|---|
| docm | Was already working correctly (reference config for all fixes below) |
| Plex | Fixed — cache dir was pointed at `/tmp` (wiped on reboot) and the daemon was disabled; moved to `/var/cache/fscache`, enabled |
| MacFedora | Fixed — `cachefilesd` wasn't installed; installed, cache dir set to `/mnt/DATA/fscache` (larger local partition, doesn't contend with the small OS disk) per user request; required fixing a real SELinux issue too — the whole `/mnt/DATA` mount was completely unlabeled (`unlabeled_t`), blocking `cachefilesd_t` from traversing into it at all; `restorecon -R /mnt/DATA` fixed it |
| GruntVM | Fixed — `cachefilesd` wasn't installed, and the `cachefiles` kernel module wasn't loaded even after install (`/dev/cachefiles` didn't exist); installed, added `cachefiles` to `/etc/modules-load.d/`, and — separately — `/etc/default/cachefilesd` had no `RUN=yes` line at all (absence defaults to disabled, not enabled) |
| AI-PROCESSOR | Same fixes as GruntVM (identical base image) |
| **PRINCE** (WSL2) | Fixed via a **custom WSL2 kernel** — see below |
| **GruntBox2** (WSL2) | Fixed via the same custom WSL2 kernel approach |
| Crystalight (macOS) | Not yet addressed — see gap #7 above |

**Why PRINCE and GruntBox2 needed a custom kernel:** Microsoft's stock WSL2
kernel has `CONFIG_FSCACHE=y` built in but `CONFIG_CACHEFILES` is **not set**
— the actual disk-cache backend driver is simply absent, no package can work
around a kernel option that isn't compiled in. No prebuilt community WSL2
kernel enables it either (checked several popular ones). Built one from
`microsoft/WSL2-Linux-Kernel` at the exact matching tag
(`linux-msft-wsl-6.18.33.2`), enabling `CONFIG_CACHEFILES=y` via
`./scripts/config --enable CONFIG_CACHEFILES` + `make olddefconfig`,
starting from `Microsoft/config-wsl` as the base.

**The build was built once (on GruntBox2) and reused on both machines** —
same kernel version, same WSL2 virtualized hardware regardless of physical
host, so one `bzImage` + matching `/lib/modules/<version>/` tree works on
both. PRINCE's own from-scratch build attempt OOM'd during BTF generation
(`CONFIG_DEBUG_INFO_BTF`, a memory-hungry step, unnecessary for our purposes)
under its original 24GB WSL2 memory cap; rather than keep fighting that,
GruntBox2's build (144GB host RAM, no memory pressure, `CONFIG_DEBUG_INFO_BTF`
left enabled and fine) was copied over instead. PRINCE's `.wslconfig` memory
was also bumped 24GB→28GB per user's direction as a side benefit.

**Real mistake made and fixed, worth remembering:** the first attempt to copy
GruntBox2's ~2GB `/lib/modules/<version>/` tree to PRINCE via an 881MB tarball
used a command wrapped in a short client-side SSH `timeout`, which silently
truncated the extraction — 270 of 961 `.ko` files ended up 0 bytes, with no
visible error at the time. This caused a cascade of confusing symptoms
(`modinfo`/`depmod` "Invalid argument" on some modules, `mount.nfs: No such
device`) that looked like a kernel/module version mismatch but was actually
just corrupted files. **Lesson: after any large background file transfer or
extraction, verify actual content (checksum, or at minimum a zero-byte-file
count) before trusting it succeeded — a clean exit code is not proof of
completeness if a wrapping timeout could have killed the underlying process.**
Redoing the transfer+extraction in the background (no client-side timeout)
and checking `find ... -size 0 | wc -l` was 0 before proceeding fixed it.

**Ongoing maintenance cost accepted by user:** future Microsoft WSL2 kernel
updates will not apply automatically to PRINCE or GruntBox2 anymore — each
update requires manually re-cloning the new tag, re-enabling
`CONFIG_CACHEFILES`, rebuilding, running `modules_install`, and redeploying
to both machines. Not automated; revisit if this becomes a recurring burden.

**Also needed on both WSL2 machines** (neither persisted across the fresh
kernel by default): `nfs` and `nfsv4` modules added to
`/etc/modules-load.d/cachefiles.conf` for boot-time auto-load (the mount
otherwise fails at boot with "No such device" until `modprobe nfs nfsv4` is
run manually), and `fsc` added to each NFS entry in `/etc/fstab`.

All 7 fixed machines were verified with a real double-read `dd` timing test
(not just checking service status) — e.g., PRINCE went from 9.3 MB/s on a
first read to 13 GB/s on the immediate re-read (~1,400x).

## Housekeeping

7. **README.md version table has a gap.** Rows exist for versions up through
   5.0.32A, then jump straight to 5.0.32Q and 5.0.32R (both added
   2026-07-24) — versions 5.0.32B through 5.0.32P were never backfilled
   into the table (their detail does exist in `CHANGELOG.md` and git
   history, just not summarized as README table rows). Not urgent — CHANGELOG
   is the source of truth — but worth a cleanup pass if the table's
   continuity starts to matter to someone reading it top-to-bottom.

## Process notes for future sessions (see also Memory/nuance below)

- Multi-reviewer review gate (advisory only) is
  mandatory before any non-trivial script logic change gets deployed —
  see `[[feedback_multi_tool_review_gate]]` in the memory system. The
  season-shrink-heuristic feature (v5.0.32R) went through 3 full rounds
  before being considered done; don't skip this for future logic changes
  of similar scope.
- Never trust a piped stdout capture alone when a result looks anomalous
  (e.g. suspiciously fast completion with no expected log line) — always
  check the per-folder `convert-v4.log` inside the actual media directory,
  which is the authoritative, complete record. This caught the real
  "A Centaur's Life" corruption finding above; the piped capture alone
  would have looked like an unexplained silent no-op.
- CHANGELOG.md gets a new version-lettered entry (`5.0.32<next-letter>`)
  for every bundled batch of changes, per the established Major.Mid.Minor +
  phase-letter versioning scheme — never squash multiple distinct changes
  into an existing entry after the fact once it's been deployed.
