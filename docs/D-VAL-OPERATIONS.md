# D-val Survey → Production Bridge — Setup & Operations Guide

Status: living document, kept current with the code. Covers the v6.0.x
fleet-orchestration system (`orchestration/regional-survey/scripts/`) that
sits in front of `convert-v6.0.4.sh` — not the standalone single-machine
`convert-v6.0.4.sh` usage, which is documented via its own `--help` and the
main [README](../README.md).

## What this system is

Two halves, one pipeline:

1. **D-val survey** (`dval_dispatch.sh` + `dval_research.sh` +
   `dval_worker_encode.sh`) — for each title, searches every shot for its
   real per-shot VMAF/QP curve, then encodes up to 8 survey variants
   (`base`, `A_pershot`, a `D_f90..D_f50` fraction sweep, `B_f80_F1`, or a
   3-variant grain-synthesis set for grain-heavy profiles) across the fleet
   in parallel, scoring each one for real. Purely diagnostic — it never
   touches the real media library, only small proxy/sample encodes under
   `$SHARED`.
2. **KB ingest + production bridge** (`dval_kb_ingest.sh` +
   `dval_finalize.sh` + `dval_finalize_worker.sh`) — once a title's survey
   is done, its result gets ingested into a fingerprint/outcome knowledge
   base, run through a quality gate (does any variant land within 2 VMAF of
   target?), and — if it passes — a real fleet host is claimed to run the
   *actual* production encode via `convert-v6.0.4.sh` against the real
   library file.

A third, optional layer (`dval_route.sh`, `dval_kb_lib.py`) does k-NN
fingerprint matching against the KB to let a confident match skip or shrink
the 8-variant survey — see `DVAL_ROUTE_ENABLE` below. Off by default.

## Fleet roles

- **RANDYJ** — coordinator. Runs `dval_dispatch.sh`, `dval_finalize.sh`,
  and the primary redis instance (`redis-ves`, port 6380). The *only* host
  `dval_dispatch_launch.sh` will start dispatch on (guarded).
- **STING** — I/O specialist + redis failover replica. Never encodes
  (`DVAL_ENCODE_NEVER_HOSTS`), search-only. Cron-driven asymmetric
  promotion (`dval_redis_failover.sh`, every minute) takes over as redis
  primary if RANDYJ's redis goes dark; never auto-fails back
  (`dval_redis_failback.sh` is manual, deliberately).
- **Encode pool** (MJACKSON, AI-PROCESSOR, JJACKSON, LAYTOYAJ, tier-gated;
  PRINCE/ELVIS Windows via PowerShell parity) — survey encodes and
  production `convert-v6.0.4.sh` runs. A node does search XOR encode, never
  both at once (`dval:encnode:<host>` mutex).
- **Search pool** — same hosts, strength-ordered opposite to encode
  (encode-strong hosts get a light search load, encode-weak hosts do more
  search) via `dval_paths.sh`'s tier/floater model.

Every fleet host runs a small deployed footprint under
`~/dval-scratch/` (search side) and `~/dval-scratch/ves-finalize/`
(production side) — never the full repo checkout.

## Prerequisites (per host)

- bash 5.x, python3, redis-cli, ffmpeg/ffprobe (with libvmaf + libsvtav1 +
  libx265), mkvmerge/mkvpropedit/mkvinfo, `mkvalidator` (Matroska
  Foundation's structure checker — install separately, not part of
  MKVToolNix).
- SSH key access from RANDYJ to every fleet host, `worker` user, matching
  the ports in `dval_research.sh`'s `HOSTS=()` array.
- A shared NFS mount (`$SHARED`, default
  `/mnt/BigMomma/Media/_dval-survey`) visible fleet-wide, plus the real
  media library mounts (`/mnt/BigMomma`, `/mnt/BabyBear`, `/mnt/BigPoppa`
  in this deployment).

## Setup

1. **Redis HA**: install redis matching RANDYJ's exact version (RDB format
   compatibility — a stock-repo version mismatch breaks replication) on
   STING, deploy `/etc/redis/redis-ves.conf` + its systemd unit, wire
   `dval_redis_failover.sh` into STING's crontab (`* * * * *`) and
   `dval_redis_failover_sync.sh` into RANDYJ's. Credentials
   (`.dval_telegram.env`) are deliberately the *only* thing that ever gets
   deployed to STING beyond the coordinator — every worker host stays
   credential-free by design (see Telegram, below).
2. **Deploy the fleet**: `dval_finalize_sync_fleet.sh` (production side —
   `convert-v6.0.4.sh` + `modules/*.sh` + `dval_finalize_worker.sh`, cron
   `* * * * *` on each encode-pool host) and the equivalent search-side
   deploy (worker scripts + `ves-dval-claim-lib.sh`, pushed live by
   `dval_research.sh`/`dval_dispatch.sh` per launch, not a separate cron).
   **Re-run `dval_finalize_sync_fleet.sh` after every `convert-v6.0.4.sh` or
   `modules/ves-*.sh` change** — the fleet only ever runs its last-deployed
   copy, not the repo checkout.
3. **systemd units**: `dval-dispatch.service` / `dval-finalize.service`
   (RANDYJ only) exist and are enabled but, as of this writing, the fleet
   still runs both via manual `tmux`/`setsid nohup` launches for scoping
   flexibility during validation — see [Known gaps](#known-gaps-not-yet-closed).

## Running it

**Manual launch** (current normal path), from RANDYJ, inside the
`ves-ctl` tmux session (`tmux attach -t ves-ctl` — windows `dispatch` and
`finalize`):

```bash
# scope to one title while validating a change -- always start scoped,
# widen only after a clean pass
tmux new-window -t ves-ctl -n dispatch \
  "exec env DVAL_ONLY_TITLE_MATCH=<slug-substring> bash dval_dispatch.sh"
tmux new-window -t ves-ctl -n finalize \
  "exec env DVAL_FINALIZE_ONLY_SLUG=<exact-slug> bash dval_finalize.sh"
```

Drop both env vars for full fleet-wide scope. `dval_dispatch.sh` single-
instance-guards itself via `flock` — a second launch just refuses to start,
never double-runs.

**Key environment variables**:

| Variable | Default | Purpose |
|---|---|---|
| `DVAL_SHARED_DIR` | `/mnt/BigMomma/Media/_dval-survey` | The whole system's shared state root |
| `DVAL_ONLY_TITLE_MATCH` | unset | Scope `dval_dispatch.sh` (search+survey) to titles matching this substring |
| `DVAL_FINALIZE_ONLY_SLUG` | unset | Scope `dval_finalize.sh` (production) to one exact slug |
| `DVAL_VARIANT_PARALLELISM` | `3` | Max hosts one title's survey variants fan out across; `1` = classic single-host sequential |
| `DVAL_ROUTE_ENABLE` | `0` | Turn on the fingerprint router (skip/shrink the survey on a confident KB match) |
| `DVAL_SWAPIO_MAX` | `500` | Hard-excludes a host from new encode work above this swap pages/sec rate |
| `DVAL_MAX_STRIKES` | `3` | Production retry attempts before a title is quarantined |
| `DVAL_WATCHDOG_AUTO_ARM` | — | Set in crontab to let `dval_watchdog.sh` self-arm; currently off during validation |

Production-side `convert-v6.0.4.sh` itself takes its own flags
(`--profile`, `--vmaf-target`, `--force-reprocess`, etc.) — `dval_finalize_worker.sh`
constructs the call automatically from the redis job it's given; you only
touch these directly for manual/debug runs (see
[Manual production test](#manual-production-test-bypassing-the-queue)).

## Monitoring

- **`$SHARED/HEALTH.txt`** — one-shot fleet health snapshot, regenerated
  every pass by `dval_watchdog.sh`: search/dispatch liveness, titles
  searched/quarantined/encoded, finalize backlog, redis-failover state,
  worker-crash bundle count.
- **`$SHARED/ALERT.*`** — one file per active alert condition
  (`ALERT.dispatch-dead`, `ALERT.search-dead`, `ALERT.quarantined`, …);
  absence of a file means that condition is clear. Read these before
  trusting anything else.
- **Telegram** — passive status channel only, never a control mechanism.
  One-shot messages on real transitions (`ENCODE START`, `SEARCH DONE`,
  `KB INGEST`, `PRODUCTION START`, `QUARANTINE`, `ROUTE`/`ROUTE CONFIRMED`/
  `ROUTE DISPROVEN`). Sent only from the coordinator (`dval_dispatch.sh`,
  `dval_finalize.sh`) — worker hosts never hold bot credentials, so a
  worker-side event always reaches Telegram via the coordinator relaying
  state the worker only wrote to shared storage, never a direct send.
  Delivery is logged locally per-host (`TELEGRAM_SEND_LOG`, default
  `/tmp/ves-telegram-send.log`) since the send itself is fire-and-forget.
- **`redis-cli` keys worth checking directly**: `dval:encnode:<host>`
  (search/encode mutex), `dval:variant:<slug>:<variant>` (per-variant
  claim), `dval:result:<slug>` (live survey scores), `dval:hb:node:<host>`
  / `dval:hb:work:<host>` (heartbeats), `dval:finalize:job:<host>` /
  `dval:finalize:hb:<host>` (production job + liveness).

## Troubleshooting / known gotchas

Real bugs found and fixed live, kept here because they'll look like new
problems again if someone hits the same underlying pattern in code this
guide doesn't cover yet:

- **A title's filename contains an apostrophe (or other shell-special
  character) and search/production silently never progresses.** Every
  remote-command site that embeds a path must use `printf '%q'` (bash
  sites) or quote-doubling (PowerShell `-SrcPath`), never a bare `'$var'`
  wrap — that breaks the instant the value itself contains a quote. Check
  the *actual remote host's own log* (not just the coordinator's belief
  about it) via `stat`/mtime when something looks "stuck with zero
  errors" — that's usually this.
- **A title gets quarantined 3 times in a row with `production attempt N/3
  ended without a finished output`, but you can see it briefly running
  each time.** Check the worker's own log
  (`~/dval-scratch/ves-finalize/logs/finalize_<slug>.log` on whichever
  host claimed it) directly — `dval_finalize.sh`'s own summary line
  doesn't carry the real reason. Two known causes: (a) `convert-v6.0.4.sh`
  already VES-tagged the file from an earlier attempt and is now silently
  skipping it (`--force-reprocess` clears this, but nothing in the
  automated retry path passes it automatically — a real gap, see
  [Known gaps](#known-gaps-not-yet-closed)); (b) a genuine mkvalidator
  structure complaint or size-guardrail rejection — read the actual
  `[warn]`/`[convert]` lines, don't assume either without checking.
- **`mkvalidator` reports `ERR*` on a file that plays fine in every real
  player.** Two confirmed false-positive classes are already allowlisted
  in `modules/ves-validation.sh`'s `validate_mkv_mkvalidator()`: `ERR0E3`
  (aspect-ratio-mode `DisplayWidth`/`DisplayHeight`, e.g. a stored `4`/`3`
  instead of pixel dimensions) and `ERR201` on `FlagEnabled`/
  `CodecDecodeAll`/`FlagInterlaced` under a strict "matroska v1" profile
  read. Before allowlisting a *new* code, verify independently — `mkvinfo`
  for the raw element values, `mkvmerge -J` (a different tool from the
  same project) for a second opinion, `ffprobe` for stream sanity, and
  real playback — the same standard both existing entries were held to.
  Never blanket-disable the check.
- **A genuine SD source (≤480p) upscaled to 1080p gets rejected by the
  size-growth guardrail even though the encode is healthy.** The guardrail
  is byte-size-tiered (`UPSCALE_OVERSHOOT_SMALL/MED/MAX_PCT`, modeling
  fixed container overhead) but that's orthogonal to how much *bigger* the
  upscale target is than the source — a genuinely SD source upscaled to
  1080p is ~5x more pixel area, not ~2.25x like a 720p→1080p upscale, and
  needs proportionally more bytes at the same VMAF target regardless of
  the original file's byte size. `UPSCALE_OVERSHOOT_SD_SOURCE_MAX_HEIGHT`/
  `_PCT` (`modules/ves-config.sh`) widen the allowance for that specific
  case as a `max()` against the byte-size tier — never tightens it.
- **A title with `chunk_parallel=true` in the log "fails" identically to
  the `chunk_parallel=false` retry that follows it.** Chunking only
  activates above `CONVERT_CHUNK_MIN_DURATION_SECS` (default 3600s/1h) —
  `dval_finalize.sh` tries `chunk_parallel=true` first on *every* title as
  a generic default, whether or not that title is even long enough for it
  to matter. Below the threshold both attempts silently run the identical
  non-chunked path; don't go looking for a chunk-coordinator bug on a
  short title.
- **Two `convert-v6.0.4.sh` processes running concurrently for the same
  title.** Fixed in `dval_finalize_worker.sh` — a retry (new job nonce)
  now kills a still-alive previous attempt (matched by pid+lstart, so a
  reused PID is never touched) before launching fresh. If you see this
  again, the deployed copy on that host is stale — re-run
  `dval_finalize_sync_fleet.sh`.
- **Mass file scans (mkvalidator sweeps, corpus audits, anything touching
  many NFS paths) should run from STING**, not RANDYJ — avoids the
  NFS/VPN tax on the coordinator's own cross-subnet path. Copy the tool
  (e.g. `scp` a local `mkvalidator` binary) rather than assuming it's
  already there.

## Known gaps (not yet closed)

- `dval_finalize_worker.sh` never passes `--force-reprocess` automatically.
  Once a title is VES-tagged (success *or* guardrail-rejection both tag
  it), the automated retry path can never touch it again even after a real
  policy fix lands — every future attempt just silently skips. Currently
  worked around by hand per-title; needs a real fix (likely: only skip-tag
  on genuine success, or have `dval_finalize.sh` pass `--force-reprocess`
  on a fresh policy-driven retry).
- Windows PS parity (`VesChunkCoordinator` wiring, `VES_PROCESSED`
  tag-stamping, `dval_finalize_worker.ps1`) is behind the bash line.
- `dval-dispatch.service`/`dval-finalize.service` are built and verified
  but not yet the normal launch path — see Setup, step 3.
- The chunk-coordinator path (`ves-chunk-coordinator.sh`) has its own
  independent `resolve_upscale_target` call and has not been exercised
  against the SD-source overshoot-tier fix above — only relevant for
  genuinely long (1h+) SD-upscale titles, untested as of this writing.

## Manual production test (bypassing the queue)

For validating a `convert-v6.0.4.sh`/`modules/ves-*.sh` change against a
real file without waiting on the full survey→KB→quality-gate chain:

```bash
ssh -p <port> worker@<host>
cd ~/dval-scratch/ves-finalize
bash ./convert-v6.0.4.sh --path "<absolute source path>" --profile <profile> [--force-reprocess]
```

Always redeploy (`dval_finalize_sync_fleet.sh`) before this, and quote/escape
the path carefully if it contains an apostrophe or other shell-special
character (`printf '%q'` into a small wrapper script, scp'd over, is
safer than inlining into an SSH command string — the exact bug class in
[Troubleshooting](#troubleshooting--known-gotchas) above bites this just
as easily by hand).
