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

1. **Deploy v5.0.32R to GruntBox2 and launch its confidence-batch-test
   title.** As of 2026-07-24, GruntBox2 is the only fleet machine still on
   v5.0.32Q (still finishing its prior test job, "Harmony of Mille-Feuille").
   Once idle: deploy the same way the other 7 machines were done (see
   `orchestration/results/phase0-fleet-GruntBox2/` if a rsync-post-xfer
   package exists for it, otherwise scp directly to
   `/home/worker/VES/GruntBox2/script/` as done previously), then pick a
   fresh, previously-untouched, genuinely legacy-codec (h264/hevc) anime
   title for it the same way the other 5 replacement picks were done this
   session (check codec via `ffprobe` on episode 1 AND check for a
   pre-existing `convert-v4.log` in the folder before assigning — several
   titles this session turned out to be already mostly/fully processed).

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
