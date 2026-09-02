# Changelog

Detailed record of every bug found and fixed during the v5.0.9 → v5.0.28 hardening
passes. The [README](README.md) version table has one line per release; this file
has the full story — what was wrong, why it mattered, and how it was fixed.

## v6.0.1I — 2026-09-02 (branch `6.x-chunk-redesign`)

**MARLONJ (macOS) rejoined the per-shot search pool.** With the header-probe
timeout fix below, MARLONJ's search worker runs clean end-to-end (verified
resolving shots 103–115 of Gun Crazy against the live fleet search). Two
macOS-specific adjustments: local source staging is forced OFF on MARLONJ
(its NFS is ~4 MB/s — copying a 4 GB source is slower than per-shot NFS
window reads), and `VES_METADATA_PROBE_TIMEOUT=60`. `dval_research.sh` gained
a `mac` host-kind: MARLONJ is now in `HOSTS`, launched via `_mac_remote_cmd`
(explicit `/opt/homebrew/bin/bash` + Homebrew PATH + `/Volumes/*` mount
remap + `nohup … & disown`, no `setsid`). Each survey title relaunches it.

**Header-only ffprobe probes were getting a file-size-scaled timeout.**
`_validation_timeout_for_args()` scales the validation timeout by the input
size (~350 s/GiB) — correct for `mkvalidator` and full-decode checks, but a
metadata probe (`ffprobe -show_entries stream=width` / `-show_streams` /
`-show_format`, no `-count_packets`/`-count_frames`/decode) reads only a few
KB of container header regardless of file size. A 4 GiB source's
`video_width`/`video_height` call was getting a ~24-minute timeout; on
macOS NFS (MARLONJ) a transient read stall inside that window then looked
exactly like a dead worker — the recurring "MARLONJ contributes ZERO,
undetected" symptom. Now header-only probes get a fixed 90 s ceiling
(`VES_METADATA_PROBE_TIMEOUT`); `-count_*` / decode probes keep the
size-scaled curve.

## v6.0.1H — 2026-09-02 (branch `6.x-chunk-redesign`)

**Per-shot search speed — Phase 1.** The regional D-validation survey's
distributed per-shot QP search was crawling on long-take content (Gun Crazy
1950: a 6-minute shot plus 46 shots over 30s; per-shot cost scales with shot
length, and the fleet re-reads a ~30s window over NFS for every QP probe of
every shot). Six additive, individually flag-gated changes — each verified as
a strict no-op with its flag off, shot metas byte-identical:

- **Per-shot complexity index** (`SHOT_COMPLEXITY_ENABLE`, default on):
  `scene_detect_boundaries()` fans its single decode to a
  `signalstats,entropy` branch; `shot_split_create_manifest()` writes
  `cx_luma / cx_motion / cx_detail / cx_sat` into each `shot-NNN.meta`. No new
  decode. Foundation for the rest and for the production content-modifier.
- **Local source staging** (`SHOT_SRC_LOCAL_STAGE`, default on):
  `worker_loop_discovery_multi.sh` copies the NFS source to local disk once
  (`_stage_source_local` — idempotent per host, disk-guarded, 24h sweep) and
  every extraction probe reads local instead of re-fetching over NFS. The
  manifest / claims / status stay on NFS.
- **Long-shot multi-window** (`PER_SHOT_MULTIWINDOW_ENABLE`, default on): a
  shot longer than `SHOT_LONG_SECS` (45) is scored as 3 × `PER_SHOT_MW_LEN`
  (8) s windows placed by content — `_shot_long_windows()` reads the per-frame
  YDIF and puts each window on its third's peak inter-frame motion (baked into
  the meta as `cx_windows=`). `_vmaf_score_shot_mw()` combines: median of the
  3 window VMAFs + rate-scaled bytes. Same `(qp,vmaf,bytes)` contract, so
  `resolve_per_shot_qp()` is agnostic.
- **VMAF frame stride** (`PER_SHOT_VMAF_STRIDE`, default 2): score every Sth
  frame in the *search* only (the final whole-file measure is never strided).
  Applied ONLY when the source is confirmed progressive —
  `shot_split_create_manifest()` records `field_mode` + `is_bw` via
  `detect_source_traits()`, threaded to the search as `SHOT_FIELD_MODE`;
  telecine / interlaced / ambiguous / unknown all force stride 1.
- **Zero-signal fast-path** (`PER_SHOT_NOSIGNAL_FASTPATH`, default on): a shot
  that is near-black, static, and flat (triple gate on the complexity fields:
  `cx_luma` < 16, `cx_motion` < 1.0, `cx_detail` < 3.0) gets `NOSIG_QP` (48)
  with no search, marked `nosignal=1`. The detail gate keeps credits text and
  grain-on-a-dark-scene out. Coverage counters count `vmaf=[0-9]` OR
  `nosignal=1`.
- **Per-profile QP bracket** (`PER_SHOT_QP_BRACKET_ENABLE`, default **off**):
  scaffolding only. `_per_shot_qp_bracket_for()` returns a per-profile search
  band; `shot_manifest_bracket_health()` + a searchwalk guard re-search a
  title wide when more than `PER_SHOT_QP_BRACKET_EDGE_FAIL_PCT` (5) % of its
  shots resolve at/past a band edge. Band values are placeholders pending a
  research pass — the survey itself is the corpus. Measured so far: vintage
  genuinely wants the QP floor (36 % of Gun Crazy shots at qp ≤ 14), so its
  band stays near-global.

**Windows fork port (2026-09-02, same version).** `VesSceneDetect.psm1` gains
`Get-VesSceneBoundaries -StatsOut` (split filter), `Get-VesShotComplexityTable`,
`Get-VesShotLongWindows`. `VesPerShotQp.psm1` gains `Get-VesStageSourceLocal`,
`Get-VesVmafScoreShotMw`, `Get-VesShotEncodeBytesOnly`, `Get-VesShotIsNosignal`,
`Get-VesPerShotQpBracketFor` / `Test-VesShotBracketEdge` /
`Test-VesShotManifestBracketHealth`, and all the Phase-1 config getters;
`New-VesShotManifest` writes `cx_*` + `cx_windows` + `field_mode` / `is_bw`
(via `Get-VesSourceTraits`); `Get-VesVmafScoreShot` reads `$env:SHOT_SRC_LOCAL`
and applies the progressive-only stride; `Resolve-VesPerShotQp` does the
bracket + multi-window dispatch + byte de-bias; `Invoke-VesShotSearchClaimed`
threads `SHOT_FIELD_MODE` / `SHOT_MW_*` and runs the nosignal single-probe;
`Invoke-VesShotSearchWorkerLoop` stages the source. Parity restored -- ELVIS
can resume dedicated scene-detect duty; PRINCE / RANDYJ reach feature parity.

## v6.0.1G — 2026-09-01 (branch `6.x-chunk-redesign`)

**The `canime` (classic anime, ≤1997) profile was dead for every modular
consumer.** `anime_profile_for_path()` picks `canime` vs `anime` by comparing
the title year to `CLASSIC_ANIME_YEAR_CUTOFF` — but that variable was only
assigned in the `convert-vX.Y.Z.sh` wrapper, *after* it sources the modules.
Anything that sources `modules/` directly and doesn't set it — the regional
D-validation survey's `dval_worker_encode.sh`, standalone module use — saw it
empty, so `[ "$year" -le "" ]` failed and every classic anime silently fell
through to the modern `anime` profile: `film-grain=6` + `film-grain-denoise`
grain synthesis applied to flat cel art. Caught on Akira (1988): base AV1
encode came out **142% of source size at VMAF 88.7**. Moved the definition
into `modules/ves-config.sh` (env-overridable via
`CONVERT_CLASSIC_ANIME_YEAR_CUTOFF`); the wrapper's own assignment is now a
harmless duplicate. Akira and Ghost in the Shell (1995) now resolve to
`canime`. The Windows fork already defined the cutoff inside
`VesProfileDecision.psm1` and was not affected.

## v6.0.1F — 2026-09-01 (branch `6.x-chunk-redesign`)

**`_source_is_uhd()` threw on a trailing-comma ffprobe probe.** The v6.0.1E
helper read width via a raw `-of csv=p=0` probe, which on some MKVs returns
`3840,` (trailing comma from an empty second field). `[ "3840," -ge 3456 ]`
is a fatal `integer expression expected`, so The Bad Guys (2022) — a
3840×1608 master — fell through to the 1080p `neg` model. Now uses
`video_width` / `video_height` (clean `nokey` format) with a digit-strip;
`Get-VesVideoWidth`/`Height` in the Windows fork hardened the same way.

## v6.0.1E — 2026-08-31 (branch `6.x-chunk-redesign`)

**UHD detection missed ultrawide 4K.** `vmaf_model_for_source` /
`vmaf_target_for_source` gated on `height > 1600`. A 2.40:1 4K master is
3840x1600 (or 3840x1608) -- height *exactly* 1600, so The Dark Tower got the
1080p `vmaf_v0.6.1neg` model + target 94 on native 3840px frames; the CRF
search could not converge (VMAF ~81 even at CRF 16, predicted 11.7 GB).
New `_source_is_uhd()` gates on `width >= 3456` (covers 3840 + DCI 4096, well
clear of 2560px 1440p) OR `height >= 1600` -> 4K model + target 95.

## v6.0.1D — 2026-08-31 (branch `6.x-chunk-redesign`)

**Windows fork — stage 1 catch-up toward v6.x parity** (bash unchanged; the
shared VERSION bumps in lockstep per fleet policy). The Windows port had been
stuck at v5.1.1T; this brings over the parts of the 6.x per-shot / scene-detect
work that are *concrete* (the allocator, still being calibrated by the live
D-validation survey, is deliberately held for stage 2).

- **New `windows/modules/VesSceneDetect.psm1`** ← `ves-scene-detect.sh` —
  `Get-VesSceneBoundaries` (ffmpeg `select=gt(scene,THRESHOLD)`+showinfo).
- **New `windows/modules/VesPerShotQp.psm1`** ← the stable half of
  `ves-per-shot-qp.sh` (v6.0.1C): manifest dir/lock helpers, `New-VesShotManifest`,
  `Enter-/Exit-VesShotClaim` (VesSharedMutex atomic-FILE claim, not `mkdir` —
  same SMB-broken-ACL reason as VesChunkCoordinator), stale-lock reclaim with
  the dual-mtime fallback, `Invoke-VesShotSearchWorkerLoop` (idle ceiling
  defaults to STALE + 3×retry, the v6.0.1B fix), `Clear-VesShotScratch`
  (dead-worker-only), `Resolve-VesPerShotQp` (the QP search — anchors, interp
  with the v6.0.1B `break`, window extension, v6.0.1C crossover split),
  `Get-VesVmafScoreShot` (v6.0.1A grain-ON). Allocator functions stubbed with
  a stage-2 note.
- **`VesVmafCrfSearch.psm1`** — stale grain-strip comments updated to the
  grain-ON policy (the PS internal search never actually stripped grain);
  added `Get-VesFinalVmaf -Sequential` with `fps=<source rate>` on both
  inputs for chunk finalization (matches bash `measure_final_vmaf_sequential`
  + the broken-DTS fps normalisation).
- **New `windows/modules/VesChunkVerify.psm1`** ← `ves-chunk-verify.sh` —
  decode verification, mkvmerge concat, structural/duration validation,
  sequential-VMAF gate, promotion, cleanup.
- **`convert.ps1`** — imports the two new modules; `-SvtAv1EncAppPath` param
  + resolution; `PER_SHOT_QP_*` / `SCENE_DETECT_*` / `SHOT_SEARCH_*` env
  defaults matching `ves-config.sh`.

Parse-verified (`Import-Module` clean on all five). **NOT yet run on a real
Windows host** — needs live SMB-ACL / SvtAv1EncApp verification on PRINCE.
Follow-ups: port `Get-VesVmafTargetForSource` (search currently takes
`-Target` from the caller); confirm PRINCE's ffmpeg has libsvtav1 + libvmaf
+ scdet; stage 2 = the allocator + fraction table after the survey locks.

## v6.0.1C — 2026-08-31 (branch `6.x-chunk-redesign`)

**Remaining Medium/Low items from the Codex + Cursor review.**

- **Crossover probe: `[ range ] && _probe_qp || true` conflated
  "out of range" with "probe failed"** — an encode failure looked like a
  skip. Split: probe only when in range, a failed probe warns (non-fatal).
- `SHOT_SEARCH_STALE_SECS` inline fallback default was `1800` in three
  places, diverging from the config default `25200`. Aligned.
- Stale comments citing "1800s" for the shot-claim staleness ceiling and
  claiming the manifest-build ceiling "matches" it — corrected to name
  `SHOT_SEARCH_STALE_SECS` and explain why the manifest build keeps 1800.
- `_vmaf_score_one` header still documented the removed grain-strip —
  updated to grain-ON (v6.0.1A).
- `pin_rounds` loop bound `<= N` documented (round 0 = initial solve, then
  N pin+re-solve passes).

## v6.0.1B — 2026-08-31 (branch `6.x-chunk-redesign`)

**Allocator / shot-search hardening from the Codex + Cursor review of
v6.0.0V–6.0.1A** (advisory gate, `feedback_multi_tool_review_gate`). Both
reviewers independently flagged the same top items.

- **Worker idle ceiling < stale-lock ceiling (undermined v6.0.0Y).**
  `SHOT_SEARCH_STALE_SECS` is 25200s (7h — legitimate for long/4K shots) but
  `shot_search_worker_loop`'s `max_idle_secs` defaulted to 2700s, so every
  worker gave up 6+ hours before a dead peer's lock could be reclaimed — the
  exact wedge v6.0.0Y fixed. Default is now `SHOT_SEARCH_STALE_SECS + 3×retry`.
- **`_shot_scratch_sweep` could delete a live sibling worker's scratch.**
  20-min quiescence window vs multi-hour legitimate shot searches on
  4-worker hosts. Now gated on the stale-lock ceiling + 60-min quiescence +
  `fuser` — only a genuinely dead worker's scratch. The 10-min system
  `fleet-scratch-reaper` (with its own busy-detection) covers the middle.
- **`yes "$qp" | head` SIGPIPE aborts under `set -o pipefail`** (production
  `convert.sh`). Replaced with an `awk` generator.
- **FRACTION-mode baseline: `$_pst_target` spliced into awk source** →
  empty/malformed value made an awk syntax error → budget 0 → min-quality
  qpfile. Now `[[ =~ ^[0-9.]+$ ]] || =94` guard + passed via `-v`.
- **Budget unreachable after floor pins was silent.** Emits
  `OVERSHOOT_PCT=` in the report and a loud `BUDGET_UNREACHABLE` log when
  >10%; qpfile is still the constrained best (not failed).
- **`search_failed` fallback shots weren't reserved in the budget** → the
  solve gave the full budget to the solvable shots and the encode overran.
  Now reserves their proportional share.
- **Non-empty-but-unparseable `samples=` → hole in the qpfile** (shot in
  `durations_flat`, no sample rows, dropped from the solve output). Now
  treated as a fixed-QP fallback shot like an empty line.
- **Refinement loop no-op:** when nothing meets target at `qp_lo` (or
  everything meets it at `qp_hi`) the loop re-probed an already-cached bound
  and burned all 3 iterations. Now breaks and lets the (B) window extension
  probe past the bound.
- **Worker loop counted a failed `shot_search_claimed` as resolved.** Now
  checks the return code.
- **`_old_enhance_score` still grain-stripped** (missed by v6.0.1A) — the
  old-title A/B gate scored on a different metric than the search/encode.
  Fixed to grain-on.

## v6.0.1A — 2026-08-31 (branch `6.x-chunk-redesign`)

**Per-shot QP / CRF search: score grain-ON, not grain-stripped.**
`_vmaf_score_shot()` and `_vmaf_score_one()` decoded the candidate AV1 with
`-export_side_data film_grain` (grain suppressed) and compared it to the
**grainy source** for the grain-synthesis profiles (`vintage` `classic`
`anime` `vtv`). That penalises a difference that does not exist in playback —
the real decoder re-synthesises grain — so VMAF hammered the "missing" grain
layer and the search picked QPs 1-3 VMAF lower than warranted. Live evidence
from the D-validation survey: Conan's per-shot ceiling came out at VMAF 91.2
while its own low-CRF `base` scored 92.6, i.e. the search targeting 94/shot
landed at 91 pooled.

Now both functions decode the AV1 normally (synthetic grain applied) and
compare grainy-output vs grainy-source — the honest playback comparison.
There is a small residual (synthetic grain ≠ source grain pixel-for-pixel,
and VMAF isn't fully grain-invariant, ~1-3 pts) but that is real signal, not
a measurement artefact of removing grain we immediately add back. The
matched extracted clips are already frame-aligned by the `-ss` extraction +
`setpts=PTS-STARTPTS`, so no fps normalisation is needed here (unlike the
whole-file `score_mkv` path, which handles broken-DTS sources).

Effect: grain-profile per-shot searches must be re-run — their samples were
biased toward over-spending. `canime` / `wanim` (no grain synthesis) and the
clean live-action / western-animation profiles are unaffected.

## v6.0.0Z — 2026-08-31 (branch `6.x-chunk-redesign`)

**Fleet scratch cleanup — stop `kill -9` orphans from filling tmpfs.** The
per-shot search and CRF/VMAF sampling write multi-GB ffv1/y4m/encode scratch
under `${RAMDISK_JOB_DIR:-${TMPDIR:-/tmp}}`. Every normal and error exit path
already `rm -rf`s it, but a `kill -9`'d worker (supervisor pkill, OOM-kill,
power loss) leaves it behind — and enough of those fill a host's tmpfs, after
which *every* extraction fails silently with "Disk quota exceeded" (the
fleet-wide `search_failed` wave, 2026-08-28).

- New `_shot_scratch_sweep()` in `ves-per-shot-qp.sh`, called by
  `shot_search_worker_loop()` on entry and after every resolved shot: removes
  `ves-shotqp-*` / `ves-crf-*` / `ves-vmaf-*` / `ves-oldenh-*` trees that are
  quiescent (nothing modified in 20 min) and hold no open handle (`fuser`).
- New **`fleet-scratch-reaper`** systemd service + timer (10-min cadence,
  `Nice=10`, `IOSchedulingClass=idle`) on every Linux fleet node — the
  system-level backstop for orphans no in-process trap can catch. Age window
  45 min normally, 120 min while VES work is running, 5 min when a watched
  filesystem (`/tmp` `/var/tmp` `/`) is already over 85 %. Deployed to
  JJACKSON/TITOJ/LAYTOYAJ/AI-PROCESSOR/Plex/MJACKSON; folded into
  `orchestration/ops/staged/_node-remediate.sh` for future provisioning.

Output finalisation (`finalize_staged_encode_output`) was already correct —
copy to a private temp on the share, size-verify, atomic `mv`, then delete
the local staged copy; on any copy/mv failure the local copy is kept for
manual recovery.

## v6.0.0Y — 2026-08-30 (branch `6.x-chunk-redesign`)

**Distributed shot-search: a dropped fleet node no longer wedges the whole
search.** Seen live during the D-validation survey — one node fell offline
mid-search holding ~10 shots; every other worker had already run out of
claimable work and exited; the search stalled at 215/225 with nothing alive
anywhere to reclaim the stranded locks. Two independent faults:

1. **Workers exited on the first empty `shot_claim_next`** while shots were
   still unresolved. The stale-lock reclaim only runs *inside*
   `shot_claim_next`, i.e. only inside a live worker — so once every worker
   quits, no reclaim can ever happen. New `shot_search_worker_loop()` retries
   on an empty claim (sleep `SHOT_SEARCH_RETRY_WAIT`, default 60s) and only
   gives up after `max_idle_secs` (default 2700s) with shots still
   outstanding — long enough to outlast the 1800s staleness ceiling and
   reclaim a dead peer's lock. `worker_loop_discovery_multi.sh` and the
   (future) production loop both call it; a fallback inline loop with the
   same retry behaviour covers older module snapshots.

2. **Lock age came only from `owner.meta`'s mtime via
   `mkv_structure_stat_key`.** If that returned nothing usable the age
   computed as 0 → never `> SHOT_SEARCH_STALE_SECS` → the lock was
   immortal. Now `_shot_path_mtime()` tries both `stat` dialects regardless
   of `$PLATFORM` (fleet workers routinely run `PLATFORM=unknown`) then a
   python3 fallback, and `shot_claim_next()` falls back to the **lockdir's
   own mtime** (set by the claiming `mkdir`, never rewritten during a search)
   when `owner.meta` is missing/unreadable. The reclaim itself no longer
   depends on `rm -rf` of the renamed orphan succeeding — on this NFS's
   root-squash idmap, `rm` of a foreign-owned `owner.meta` gets EPERM but the
   `mv` (parent-dir write only) works, and a leftover `*.stale.*` orphan no
   longer matches the `*.lock` glob.

Manual recovery for a search already wedged this way: `mv "<title>.shotNN.lock"
aside` (not `rm`), then relaunch workers.

## v6.0.0X — 2026-08-30 (branch `6.x-chunk-redesign`)

**Equal-slope allocator byte-budget calibration — fix the systematic
under-prediction of the full-file encode.**

The per-shot search encodes every shot as an **isolated clip**: a cold
keyframe, no cross-shot temporal prediction, per-clip AQ statistics. The
continuous full-file encode of the *same* qpfile therefore comes out
systematically **larger** than the sum of the search's sample bytes.
Measured `k = actual / estimated` on Discovery S01E02:

| variant | est bytes | actual bytes | k |
|---|---|---|---|
| B (std budget, floor on)   | 363,516,219 | 411,035,871 | 1.131 |
| C (b95 budget, floor on)   | 346,207,684 | 393,297,355 | 1.136 |
| D (b95 budget, floor off)  | 347,953,239 | 370,817,329 | 1.066 |
| E (b95, no pos-weight)     | 345,548,919 | 393,436,371 | 1.139 |
| pure per-shot-target (A)   | 511,179,581 | 598,106,347 | 1.170 |

Before this fix, an **absolute** byte target handed to the lambda bisection
(which only ever sees sample bytes) produced a final file ~7–14 % over
target — budgets were being allocated against a number that did not
correspond to the thing being measured.

`assemble_qpfile_via_equal_slope_budget()` now interprets its budget arg:

- **fraction** (`0 < x ≤ 4`): `budget = x · baseline`, where `baseline` is
  the sample-byte sum of the pure per-shot-target qpfile — the *same*
  estimator, so `k` cancels in the ratio and `actual(x) / actual(1.0) ≈ x`.
  This is the robust form and is what the archived budget90/95 runs meant.
- **absolute** (`> 4`): divided by `ALLOC_BYTES_CALIBRATION_K`
  (new config, default `1.13`) before the solve, so the *final encode*
  lands near the requested byte count.

New config: `ALLOC_BYTES_CALIBRATION_K` in `ves-config.sh`. No behaviour
change for callers that were already passing a fraction; absolute callers
now hit their target instead of overshooting.

## v6.0.0W — 2026-08-30 (branch `6.x-chunk-redesign`)

**`set -u` safety for the ves-hwdetect.sh lazy-probe caches.** The five
version/capability accessors (`svtav1_supports_sharpness`,
`current_svtav1_major_minor`, `current_x265_major_minor`,
`current_tools_fingerprint`, `current_tool_versions_tag_suffix`) each guard
their one-time probe with `if [ -z "$VAR" ]`, but the variable had no
top-level default anywhere (dropped in the original monolith→module split —
"pure move, no logic changes"). Production `convert.sh` doesn't run with
`nounset` so it was latent, but any harness that sources the modules under
`set -u` (e.g. the v6.0.0V Discovery allocator A/B) aborts on the first probe
with `FF_SVTAV1_SUPPORTS_SHARPNESS: unbound variable`. Added the five empty
defaults next to `NVENC_AV1_TUNE` in `ves-config.sh`. Pure default, zero
behaviour change; verified both with and without `set -u`.

## v6.0.0V — 2026-08-30 (branch `6.x-chunk-redesign`)

**Dynamic (equal-slope) allocator — B+C, and credits detection retired.**

The Phase 6.2 regional credits-detection survey (American 5 + Discovery 5 +
British/Japanese 15, ~30 titles) reached its conclusion: **there is no
reliable way to detect a "credits range" from bytes.** The library is
effectively chapterless (one chaptered file in the whole survey), and
credits that roll over live-action or animation carry no low-byte signature
— 4 of 5 J-drama titles missed with a perfectly clean per-shot search (0
failed shots on Kodoku no Gurume and Kakegurui). The right answer is to
stop special-casing and let the equal-slope allocator do what it already
does: allocate bits by scene-change/motion complexity.

- **Removed `detect_credits_range_by_complexity()`** and its call from
  `detect_credits_range()` (which keeps only the chapter-marker path —
  reliable when present, just rare here). The v6.0.0R rework, the v6.0.0T
  `search_failed`/NA-tolerance path, and the whole byte-cost heuristic
  existed to prop up this dead branch.

- **(B) content-adaptive per-shot QP window.** New `PER_SHOT_QP_MIN/MAX`
  (14/50), independent of the whole-file `VMAF_SEARCH_*_CRF` (16/46) so the
  wider per-shot range can't move production whole-file behaviour. When a
  shot's bounded search still pins to a bound, `resolve_per_shot_qp()` now
  **extends past it** — up to `PER_SHOT_QP_EXTEND_PROBES` more probes toward
  `PER_SHOT_QP_EXTEND_CEIL` (55) when a cheap shot is still ≥ target +
  `PER_SHOT_QP_EXTEND_MARGIN` at the ceiling, or toward
  `PER_SHOT_QP_EXTEND_FLOOR` (10) when nothing met target. The allocator now
  always gets a real rate-distortion curve, never one clipped at the window
  edge — which is what lets genuinely cheap shots bank bytes (size) and
  genuinely hard shots be protected (quality), with **no per-position
  logic** (the survey proved position ≠ viewer value).

- **(C) smooth position weight in `assemble_qpfile_via_equal_slope_budget()`.**
  Replaces the retired credits-deprio with a soft weight: `ALLOC_POS_WEIGHT_MIN`
  (0.85) at the very edges of the file, linearly to 1.0 by
  `ALLOC_POS_WEIGHT_HEAD_FRAC` (5%) / `ALLOC_POS_WEIGHT_TAIL_FRAC` (12%).
  The allocator objective `weight·vmaf − lambda·bytes` then makes it take
  the quality hit in the head/tail first under a tight budget — the
  statistical "recaps/intros/credits/denouement are lower viewer value"
  prior, applied as a nudge, with the allocator still choosing from real RD
  data. `ALLOC_POS_WEIGHT_MIN=1.0` disables it. An explicit `deprio_start/end`
  arg (only the archived discovery experiment passes one) still overrides.
  Allocator stderr now also reports `MIN_BODY_VMAF` (worst non-weighted
  shot) alongside `MIN_SHOT_VMAF`.

**Quality/size levers on top of B+C** (goal order: quality > size > speed):

- **(#1) per-shot VMAF FLOOR in the equal-slope allocator.** The equal-slope
  objective maximises the *weighted mean* VMAF for the budget and will let an
  expensive (steep-RD) shot fall far below target if the bytes raise the mean
  more elsewhere — the Discovery S01E02 baseline hit `MIN_SHOT_VMAF=66.9` at a
  ~90 mean. The viewer notices the worst shot, not the mean. Any shot the
  bisection puts below `target − ALLOC_MIN_SHOT_VMAF_DROP` (default 6) is
  **pinned** to its highest-VMAF sample and the budget is re-solved over the
  rest, up to `ALLOC_MIN_SHOT_PIN_ROUNDS` (4) times. Position-weighted head/tail
  shots are exempt (they're meant to absorb loss). Pure allocator change, no
  extra encodes. New stderr fields: `MIN_BODY_VMAF`, `FLOOR_PINNED`. 0 disables.

- **(#3) crossover refinement in `resolve_per_shot_qp()`.** VMAF-vs-QP is not
  monotone-smooth (GOP/RC give ±0.3–0.5 wiggle), so the bounded search's winner
  is occasionally beaten by an adjacent QP that is *both* higher-VMAF and
  fewer-bytes. After the search converges, probe ±`PER_SHOT_QP_CROSSOVER_PROBES`
  (default 1) QP around the winner — ≤2 short encodes that catch the inversion
  and hand the allocator a denser curve where its lambda lands.

- **(#2, GATED OFF) content-adaptive per-shot VMAF target.**
  `PER_SHOT_ADAPTIVE_TARGET=true` → one cheap ffmpeg read of the shot (mean luma
  via `signalstats`, motion via `tblend=difference,signalstats`) shifts the
  per-shot target by up to ±`PER_SHOT_ADAPTIVE_TARGET_SPAN` (2): busy motion →
  lower (the eye can't resolve it, and it's cheaper); dark + static → higher
  (banding shows at 94 on smooth gradients). Clamped to base ±3. Off — turn on
  for the Discovery A/B.

- **(#4/#5, GATED OFF, vintage/classic/vtv only) per-title enhancement check.**
  New module `ves-old-enhance.sh`. `PER_TITLE_OLD_ENHANCE_CHECK=true` →
  `decide_old_title_enhancement()` runs a ~45 s sample A/B (default profile
  params vs an *enhanced* variant: film-grain `+4` / add synthesis, +1
  variance-boost-strength, wider variance-octile, force `enable-tf=1`) and only
  adopts the enhanced params **for that one title** if the sample is smaller at
  VMAF within `PER_TITLE_OLD_ENHANCE_VMAF_TOL` (0.5) of default — because "old"
  is not one thing: a scanned 16/35 mm print gains a lot from grain synthesis,
  a clean telecined studio print gains nothing and can be softened by it.
  Adopted params flow via a new `SVT_PARAMS_OVERRIDE` hook in
  `profile_svt_params()` (shared by CRF/QP search and final encode), reset per
  title. Wired into `ffmpeg_encode()` for `codec=av1` only.

Goal order unchanged: (1) don't drastically drop output quality, (2) reduce
size, (3) speed last. #1/#3 active by default; #2/#4/#5 gated off pending the
Discovery S01E02 A/B. NOT yet fleet-deployed.

## v6.0.0U — 2026-08-28 (branch `6.x-chunk-redesign`)

**Real bug fix: a scene-detection failure silently produced a bogus
one-shot manifest.** `shot_split_create_manifest()` reads
`scene_detect_boundaries()` via `done < <(scene_detect_boundaries "$src")`.
If that function is unavailable — found live 2026-08-28 on a fleet host
(TITOJ) whose `modules/` was missing `ves-scene-detect.sh`, so it was
literally `command not found` — the process substitution yields nothing,
the loop body never runs, and the function goes straight to writing the
single "final shot" (0 → duration), `manifest.meta`, and `.complete`,
then returns 0. Every downstream consumer (the QP-search fleet, the
allocator, credits detection) then trusts a manifest that says the whole
episode is one shot.

Guards added before `.complete` is written:
- `scene_detect_boundaries` must be a defined function / available
  command, else refuse.
- its invocation must succeed (`|| return 1`), and its output is captured
  once and counted.
- **zero cuts found in a file longer than 180 s is treated as a detection
  failure** (missing decoder, wrong ffmpeg, unreadable input) — refuse
  rather than emit a 1-shot manifest. A genuinely uncut short clip under
  3 minutes still passes.

Also this session: fleet `modules/` sets re-synced from the repo with
`rsync --delete` — every host now carries the identical full 36-file
module set (several were drifted; TITOJ was missing a file).

## v6.0.0T — 2026-08-28 (branch `6.x-chunk-redesign`)

**Real bug fix: a per-shot search failure was recorded as a normal
result and then made credits detection silently miss the credits.** When
`resolve_per_shot_qp()` returns nothing, `shot_search_claimed()` blind-
falls-back to a fixed QP and writes `status=resolved` with empty
`vmaf=`/`samples=`. Nothing downstream could tell that apart from a real
result. `detect_credits_range_by_complexity()` filters shots on
`[ -n "$samples" ]`, so a failed-search shot simply vanished from its
input — and a *gap* in the shot sequence breaks the contiguous
trailing-run walk.

Found live 2026-08-28 closing out the Raised by Wolves S01E01 regional
survey: the episode has a textbook ~100 s black-background end-credits
crawl (verified by frame grab), but `detect_credits_range` returned
nothing. Shot 454 — the single 90 s credits block — had failed its QP
search on AI-PROCESSOR (a 90 s clip's ~13 GB uncompressed y4m overflowed
that host's RAMDISK), so it carried `qp=26 vmaf= samples=`. The tail-run
walk hit the gap where 454 should be and bailed, leaving only ~16 s of
trailing logo shots — under the 30 s floor. Re-resolving 454 on MJACKSON
(63 GB tmpfs) gave `qp=25 vmaf=94.01`, byte ratio 0.19 — obviously
credits.

Fixes:
- `shot_search_claimed()` now writes `search_failed=1` in the status when
  it blind-fell-back, so the allocator and detection can tell a real
  result from a placeholder. Still `status=resolved` (a failed shot must
  not permanently block `shot_manifest_all_resolved`).
- `detect_credits_range_by_complexity()` now feeds sample-less shots into
  its analysis as `NA` byte markers instead of dropping them. In the
  backward run-walk a **long** `NA` shot (≥ 45 s — no scene cut that long
  is almost always the crawl itself) is folded into the run; a **short**
  one is a bridgeable unknown on the same budget as an expensive blip.
  Body-median calc skips `NA` rows.

Known non-fix: the underlying per-shot search still fails on long shots
on RAM-constrained hosts. Detection now tolerates it and the
`search_failed=1` marker makes it visible; a proper fix (score a
representative sub-window for shots over ~60 s, or requeue to a beefier
host) is deferred until a leg actually shows widespread failures.

## v6.0.0S — 2026-08-28 (branch `6.x-chunk-redesign`)

**Performance fix: per-shot clip extraction decoded the whole file up to
the shot every probe.** The v6.0.0M overshoot fix switched shot
extraction in `_vmaf_score_shot()` to an accurate post-input seek
(`ffmpeg -i "$src" -ss "$start" -to "$end" -c:v ffv1`). Correct, but with
no pre-input seek ffmpeg demuxes from frame 0 to `$start` on every call —
for a shot 20+ minutes into an episode that is ~1200 s of throwaway
lossless decode, several times per shot. Found live as the dominant cost
of the Raised by Wolves regional-survey search: ffmpeg pinned at 5+
minutes on a single 2-second shot, fleet load average ~3× core count,
the search barely advancing.

Fixed with a **two-stage seek**: a fast pre-input `-ss` to the keyframe
30 s (comfortably longer than any real GOP) before the target, then an
accurate post-input `-ss` for exactly that 30 s, then `-t` for the exact
duration. ffmpeg's post-input `-ss` is frame-accurate no matter where the
preceding fast seek landed, as long as it landed at or before the target
frame — which a nearest-preceding-keyframe seek guarantees — so the
output is byte-identical to the v6.0.0M single-stage seek.

Verified frame-exact against the old method on three real Raised by
Wolves shots at increasing depth (21 s / 740 s / 2061 s into the file):
identical frame counts, `psnr_avg=inf` (bit-identical), identical
per-frame MD5s. Speedup scales with shot depth: **1× / 23× / 92×**
respectively. Byte costs and VMAF scores are unchanged, so search data
collected before and after this fix is directly comparable — no re-run
needed (unlike v6.0.0M).

## v6.0.0R — 2026-08-28 (branch `6.x-chunk-redesign`)

**Real bug fix: the chapterless credits-detection fallback
(`detect_credits_range_by_complexity()` in `modules/ves-per-shot-qp.sh`)
under-detected multi-shot credits sequences and could miss them
entirely.** The old logic scanned the last quarter of the file for the
single shot with the lowest bytes-per-second ratio vs. the all-shots
median, required it to clear a hard `< 0.25×` bar, and returned *only
that one shot's own start/end*. Two real failures found in the American
regional survey (2026-08-28):

- **Under-detection — WandaVision S01E05.** The real end-credits crawl
  runs shots 324–336 (2086.3 s → 2238.5 s / true EOF). Only shot 324
  (a 59 s block at 0.037× median) matched; the reported range stopped at
  2145.5 s, leaving ~93 s of real trailing credits at full budget
  priority. Verified by frame-grab: scrolling crew crawl still on screen
  well past the old reported end.
- **Full miss — Wild Cards S01E10.** No single trailing shot ever dropped
  below the `0.25×` bar, so the function returned "not detected" despite
  real end credits / guild logos in the last ~65 s.

Reworked to anchor on a **contiguous trailing run** of cheap-to-compress
shots instead of one outlier:

1. Baseline median is now taken over the file **body only** (shots
   starting before the last quarter), so a long credits tail can't drag
   the median down and mask itself.
2. Detection walks backward from the shot whose end is closest to EOF
   (skipping a trailing bumper/preview up to ~90 s), accumulating a
   contiguous run of shots under the ratio bar, tolerating a brief
   expensive blip inside the crawl (≤ 10 s / ≤ 2 shots — e.g. a
   mid-credits logo card). A strict `0.25×` pass is tried first, then a
   looser `0.40×` pass.
3. The reported **end is extended to true EOF**, mirroring the chapter
   path — a short post-credits bumper is low-viewer-value too, so
   including it in the deprioritized range is safe.

Results after the fix, against real resolved manifests: WandaVision
S01E05 → `2086.3 2238.5` (correct, full crawl to EOF); Normal People
S01E01 → `1673.2 1722.3` (unchanged, still correct); Discovery
S01E01/S03E03/S05E02 unchanged. **Wild Cards S01E10 still returns "not
detected"** — its credits sit inside expensive 20–120 s mega-shots (shot
detection found no cuts, and the crawl is over textured/live-action
footage, not a flat background), so the byte-cost signal genuinely isn't
there. This is a known limitation of the byte-cost fallback, not a
regression; it fails safe (nothing gets deprioritized). Catching that
class needs a pixel-level text-crawl / black-frame signal — separate
future work, same bucket as the Chromaprint intro-detection increment.

## v6.0.0Q — 2026-08-27 (branch `6.x-chunk-redesign`)

**Real bug fix: an interrupted shot-manifest build permanently blocked
all future attempts for that title.** `shot_split_create_manifest()` in
`modules/ves-per-shot-qp.sh` uses `mkdir` on the `.shots` directory as
its atomic single-builder claim, then only ever clears the claim by
writing a `.complete` marker at the very end. If the builder is killed
mid-build — this function runs a full-file scene-detect decode pass,
confirmed to take well over 10 minutes on a real ~29-minute episode —
the `.shots` directory is left behind empty with no `.complete` marker,
and every subsequent call hits `mkdir` `EEXIST` and silently `return`s 1
forever. Found live 2026-08-27 during the American regional
credits-detection survey: a foreground manifest-build for Normal People
S01E01 was killed by a 10-minute command timeout, then the very next
(backgrounded) attempt for the same file failed instantly with no error
output. Fixed by adding the same staleness-reclaim shape
`shot_claim_next()` already uses for per-shot locks: on `mkdir` failure,
if the directory has no `.complete` marker and its mtime is more than
1800s old, remove it and retry the claim once.

## v6.0.0M — 2026-08-26 (branch `6.x-chunk-redesign`)

**Real bug fix: shot-clip extraction overshot its intended boundary by
1.5–3x.** `_vmaf_score_shot()` in `modules/ves-per-shot-qp.sh` extracted
each shot's isolated clip via `-ss "$start" -to "$end" -i "$src" -c copy`
— pre-input seek combined with stream copy. Confirmed via two real
repro shots (Star Trek Discovery S01E02) that this cannot cut mid-GOP
and silently rounds the *end* boundary up to the next keyframe it can
safely stop at, regardless of whether `-to` or `-t` is used or which
side of `-i` it's placed on: a 1.176s/28-frame shot came back as
74 frames, an 8.9s/212-frame shot came back as 296 frames. Every per-shot
VMAF probe this affected was scored against a clip padded with extra,
often unrelated trailing content, and — more consequentially — every
shot's recorded byte cost (the direct input to the Phase 6.1 equal-slope
budget allocator's λ bisection) was inflated by those extra frames.

Fixed by seeking accurately *after* `-i` into a lossless `ffv1`
re-encode instead of a stream copy — verified frame-exact against
ground truth on both repro shots. Same lesson as the earlier windowed-
VMAF false-positive fix: `-c copy` cannot be trusted for boundary-precise
clip extraction. Deployed fleet-wide (Sting, TITOJ, LAYTOYAJ,
AI-PROCESSOR, Plex, MJACKSON) with checksum verification. All per-shot
search data collected before this fix — Reacher, the anime titles, and
Discovery's first pass — was built on inflated per-shot byte figures and
should be treated as approximate, not authoritative, until re-run.

See `docs/DESIGN-6x-chunk-redesign.md` for the full Phase 6.1 real-world
validation results (Reacher/Discovery byte-budget tests) and the new
Phase 6.2 scoping (deprioritizing intro/credits segments to widen the
effective budget for main content).

## v6.0.0A — 2026-08-24 (branch `6.x-chunk-redesign`)

**Fork point for the chunk-based redesign.** Per explicit user direction:
the shift to chunk-parallel encoding (splitting one file into pieces
encoded independently across the fleet, then concatenated) is a real
architectural pivot away from the fleet's original model (each machine
independently owns and encodes one whole file end-to-end, fully
decentralized, no coordination needed). Per this project's own versioning
convention, a major version bump marks "a complete re-architecture" --
this qualifies, so rather than keep layering chunk/orchestrator work onto
the 5.x line, it forks here.

Unlike every prior version bump (5.0.x through 5.1.2A, all new files on
`main`), this fork uses a real git branch (`6.x-chunk-redesign`) --
explicit user direction, since this redesign is expected to take real
design/build work before it's ready to sit alongside the proven 5.x line.
`main` (5.x) stays the stable, maintained line; all chunk/orchestrator
redesign work happens on this branch until it's ready.

`convert-v6.0.0A.sh` is a byte-for-byte copy of `convert-v5.1.2A.sh` (only
`VERSION` bumped) -- explicit user direction to bring the entire existing
codebase over as the starting baseline rather than curate/prune modules
upfront. Nothing is being left behind or judged obsolete yet; pruning
happens deliberately as the redesign takes shape, not by guessing now
what won't be needed.

Known open design questions for this branch, not yet resolved:
- A live orchestrator role (tentatively RANDYJ) that watches the existing
  chunk-manifest shared state, confirms chunk/verify/concat success or
  failure, and drives the queue forward -- intentionally designed to
  enforce/aggregate over the manifest's already-durable shared state
  rather than become a dispatcher other machines must ask permission
  from, so encoders can still self-organize via the existing atomic
  claims if the orchestrator itself is down.
- A dedicated VMAF-generation role, decoupled from the per-encode inline
  CRF-search/quality-tag flow that exists today -- candidate machines
  (ELVIS, Sting) are being timed/bake-off-tested for this before either
  is trusted with it.
- A dedicated scene-detection role (MARLONJ) for shot-cut-based chunk
  boundaries -- this is Phase 5 from the original chunk-parallel plan,
  not yet built on either line.
- Fleet role reassignment: encoder tier narrowed to x86_64-only machines
  (JJACKSON/MJACKSON/TITOJ/PRINCE/AI-PROCESSOR/Plex/LAYTOYAJ), keeping
  MARLONJ (the fleet's only arm64 machine, Apple M2 Max) off the encoder
  tier to avoid cross-architecture encoder-output parity concerns (a real
  prior issue -- see `project_marlonj_svtav1_parity_fix_2026_08_22`
  memory).

## v6.0.0C — 2026-08-24 (branch `6.x-chunk-redesign`)

**Stuck-script reaper** (`reap_stuck_script_processes()`,
`modules/ves-orphan-reaper.sh`): found live on JJACKSON -- three nested
`convert-v5.1.2A.sh` processes sitting at 0.0% CPU for up to ~3 hours,
referencing a script file a routine version-deploy had already deleted
days earlier. The existing orphan reaper (`reap_orphaned_encoders()`)
explicitly skips any script PID that's still alive ("Live script job on
this host — never touch"), so it never caught this class of bug. The new
function is the complement: reaps a live top-level script process only
when it has *no* live encoder-tool descendant (ffmpeg/HandBrakeCLI/
mkvmerge, checked across its full descendant tree, not just direct
children) *and* has been running for at least `STUCK_SCRIPT_GRACE_SECS`
(default 900s, matching the chunk-splitter's own stale-reclaim
threshold). Both conditions together, not either alone -- a script
legitimately between steps (keyframe scan, staging copy, VMAF setup)
shows no encoder-tool child for well under 900s. Wired into the same
Phase B startup pass as the existing reaper, gated by the same
`AUTO_REAP`/`--no-auto-reap` flag. New config: `STUCK_SCRIPT_GRACE_SECS`,
`STUCK_SCRIPT_KILL_GRACE_SECS` (`modules/ves-config.sh`).

Also: `ves-config.sh`/`ves-orphan-reaper.sh` are shared with `main`, so
this ships there too as part of `main`'s own next version.

## v6.0.0B — 2026-08-24 (branch `6.x-chunk-redesign`)

Version bump for accumulated module changes since the fork (v6.0.0A):
content-complexity-variance probe generalized into passive cross-branch
tracking (`log_source_content_variance()`, now also recording source
codec), deterministic SLOT-order documentation for the encoder tier, and
the `chunk_should_split()` variance-gate experiment (added, validated
against 17 real titles, then reverted per the negative-result findings --
see `docs/DESIGN-6x-chunk-redesign.md`).

## v5.1.2A — 2026-08-24

**New: sample-prediction accuracy tracking.** Per explicit user direction —
prompted by a question about whether `VMAF_SAMPLES=3` sample points are
enough to reliably decide AV1-vs-x265-vs-skip before committing to a real
full encode, or whether more sampling would pay for itself by avoiding
wasted full-encode cycles on files that end up larger than predicted. No
such tracking existed before; there was no empirical answer, only the
qualitative reasoning already documented next to the offset-search logic
(misalignment can only ever drag a score down, never inflate it).

`av1_source_reencode_sample_decision()` (`ves-vmaf-crf-search.sh`) now
emits a `PRED_DATA:` line alongside its existing decision token, carrying
the predicted AV1/x265 sizes, original size, and how many of the requested
sample points actually succeeded. Since this function runs inside a
`$(...)` subshell at every call site, it can't set caller-visible globals
directly — a new `_set_sample_pred_from_output()` helper parses that line
in the *caller's* shell (both call sites in `process_existing_av1`/
`process_existing_x265`) and populates new `SAMPLE_PRED_*` globals
(`ves-config.sh`), only when the decision is `av1` or `x265` (a `skip`
never leads to a real encode, so there's nothing to compare later).

`record_conversion_result()` (`ves-stats-log.sh`) — the single choke point
every finished real encode already passes through — now calls a new
`log_sample_prediction_outcome()` right after computing the actual output
size, which appends one line to `sample-prediction-log.tsv` (same
`${JOB_SIDECAR_DIR:-.}` location convention as `bad_sources.txt`/
`corrupt_files.txt`) recording predicted vs. actual size and whether the
sample correctly predicted the DIRECTION (shrink vs. grow relative to the
original) — that's the question that actually matters for wasted-cycle
avoidance, not exact size accuracy. Clears the sticky `SAMPLE_PRED_*`
state immediately after, so it can never leak into an unrelated later
title's own result.

No behavior change to the actual av1/x265/skip decision logic itself —
this is observability only. Needs a real batch of conversions to
accumulate before the original question (is 3 samples enough, should it
be 5+) has real data behind it instead of a guess.

## v5.1.1Z — 2026-08-24

**Chunk-parallel VMAF false-positive found and worked around — the
"seek-index corruption" reported in v5.1.1Y was itself a false positive
of the verification tooling, not a real defect.** Full details: memory
`project_chunk_parallel_vmaf_false_positive_2026_08_24`.

Direct empirical testing (keyframe-flag dump, remux, alternate concat
tool, isolated pre-concat chunk file, plain source self-compare,
byte-identical single-frame MD5 check, and a duration sweep) systematically
disproved every "real file corruption" theory from the v5.1.1Y
investigation, including the "broken mkvmerge seek index" hypothesis a
4-source consultation panel had converged on. The actual trigger: the
pipeline's own windowed VMAF construction (`_vmaf_compare_window_once` in
`ves-vmaf-crf-search.sh` — two independent `-ss` seeks, each rewritten via
`setpts=PTS-STARTPTS`, merged through `libvmaf` into a `-f null -` muxer)
reproducibly manufactures a catastrophic false score (seen: mean 18.5, min
0.0 on a file later proven undamaged) specifically when reading
multi-segment-concatenated content, regardless of concat tool. The exact
ffmpeg-internal mechanism was not root-caused — three synthetic
reproducers at increasing scale (up to 150s / 11 real-GOP-length
segments) all failed to trigger it cheaply, so whatever the trigger is
needs real full-length body chunks (~1000s), not a cheap stand-in.

Fix: new `measure_final_vmaf_sequential()` (`ves-vmaf-crf-search.sh`) —
decodes both streams fully sequentially, no `-ss` and no `setpts` rewrite
anywhere, sidestepping the buggy construction entirely. Wired into
`chunk_finalize_manifest` (`ves-chunk-verify.sh`) in place of the windowed
`measure_final_vmaf`, since that's the path the false positive was found
on. New dedicated timeout curve (`_sequential_vmaf_timeout_for_args`,
`ves-timeout-retry.sh`) since a full-file decode+VMAF pass is a
genuinely slower regime than the short bounded windows the existing
validation timeout curve was tuned for. Validated against small
already-encoded reproducer files (not a full movie re-run): a clean
self-compare scored 98.8 as expected, and a real 3-segment splice test
produced a sane score with no catastrophic collapse, matching earlier
manual verification.

Scope: this change is chunk-parallel-specific (`chunk_finalize_manifest`
only) — the windowed sampling `measure_final_vmaf` uses elsewhere in the
pipeline has run reliably for months on normal whole-file encodes and was
not touched.

## v5.1.1Y — 2026-08-23

**Chunk-parallel DTS/concatenation defect: seam-based fix implemented,
but a NEW real issue found — do not consider this resolved.** Full
details: memory `project_chunk_parallel_phase4_2026_08_23` and
`reference_chunk_parallel_pts_fix_consultation_2026_08_23`.

Extensive investigation (8 external consultations across 4 sources —
Gemini, an independent Claude instance, DeepSeek, Kimi — converging
unanimously) established: concatenating independently-encoded AV1 chunks
with SVT-AV1's default hierarchical B-frame ("random access") prediction
structure produces genuine packet decode-order corruption at splice
points. This is a packet-storage-order defect, not a timestamp-value
defect — three separate timestamp-relabeling strategies were tried and
empirically falsified (global rank-based; global rank with a
pre-computed absolute offset, falsified because mkvmerge's `+` ignores
pre-set absolute timestamps and always recomputes its own continuation
offset; per-chunk local rank-based, falsified by a proper full-decode
re-test after an EARLIER "clean" result turned out to be a false
positive from an insufficient 90s verification timeout on content that
needed many minutes to fully decode).

The consulted-and-implemented fix: small independently-encoded SEAM
segments now inserted between body chunks at each internal boundary
(`ves-chunk-coordinator.sh`, `chunk_split_create_manifest`) — body
chunks trimmed to stop/start short of the boundary, the gap covered by
its own small encode, so no two directly-hierarchical-B-GOP-encoded body
chunks are ever spliced against each other. `chunk_finalize_manifest`
(`ves-chunk-verify.sh`) simplified back to plain `mkvmerge +`
concatenation in manifest order — no timestamp manipulation needed with
this design. Verified via a real automated pipeline run (6 encoder-tier
machines + Sting verifier, no manual orchestration): all 11 units
(6 body + 5 seam) encoded and structurally verified correctly, and a
full sequential decode of the concatenated result was completely clean
(zero DTS errors) — the sequential-decode-order defect this session
spent most of its time on does appear to be genuinely fixed by this
design.

**However**: a live VMAF gate failure on this same file (56.9 vs 94.0
target) led to a deeper check that found something new — **windowed
random-access seeks (`ffmpeg -ss ...`) into the concatenated file
produce catastrophic corruption** (VMAF collapsing to near-zero,
including a fresh DTS violation at one seek point) even though a plain
sequential top-to-bottom decode of the exact same file is clean. Since
`measure_final_vmaf` (and this project's whole VMAF-gate architecture)
samples via `-ss`, this may mean the TRUE root cause was never fully
addressed — possibly a broken/imprecise seek index (cues) in the
mkvmerge-appended multi-segment file, not (or not only) the
sequential-decode-order issue this session focused on. **Not yet
investigated further** — flagged for the next session rather than rushed
given how many prior "fixes" in this same investigation turned out to be
false positives from insufficient verification.

**Status: Layer 1 chunk-parallel remains NOT safe for production
default-on** (unchanged from v5.1.1X). `CONVERT_CHUNK_PARALLEL_ENABLED`
stays `false` by default. The seam-based body/seam chunk-splitting design
is a real, meaningful step forward (confirmed fixes the sequential-decode
DTS defect) but is not sufficient on its own until the seek-index issue
is understood and resolved.

## v5.1.1X — 2026-08-23

**Phase 4 live end-to-end test: 4 real bugs found and fixed; one critical
defect found and NOT yet fixed.** First real automated (not manually
orchestrated) run of the chunk-parallel pipeline across 6 encoder-tier
machines + Sting as verifier, against two real files (Mad Heidi, The
Immaculate Room). Full details: memory
`project_chunk_parallel_phase4_2026_08_23` in the operator's notes.

Fixed:
- `chunk_parallel_process_video()`: claim lock was only released on
  encode failure, not success — harmless normally (status already blocks
  re-claim) but blocked prompt reclaim of a later `needs-requeue` chunk
  for the full 7200s stale-lock ceiling instead of immediately. Now
  released on both outcomes.
- `chunk_split_create_manifest()`: an interrupted splitter left a bare
  incomplete manifest dir with no staleness/reclaim logic at all —
  `mkdir` always fails against an existing dir, so one interrupted split
  permanently broke that title's chunk-parallel path. Added a 900s
  staleness reclaim (much shorter than the per-chunk 7200s ceiling, since
  splitting is just a keyframe scan).
- `chunk_encode_claimed()`: never pinned an explicit audio codec, letting
  ffmpeg's own per-invocation default vary across chunks (Vorbis on some,
  AC-3 on others, same source) — `mkvmerge` correctly hard-failed
  concatenation ("the formats do not match"). Fixed by mirroring the
  whole-file path's own audio-codec resolution exactly.
- `chunk_finalize_manifest()`: mkvmerge failures were logged with no
  error detail (`>/dev/null 2>&1`); now captures and logs real stderr.
- `_chunk_output_decodes_clean()`: added a retry (2 attempts, 20s apart)
  before condemning a chunk — found live that a perfectly good chunk can
  get a transient decode error under real concurrent fleet load on a
  shared, contended host.

**NOT fixed — critical, open**: the concatenated output failed the
whole-file VMAF quality gate (84.4 vs 95.0 target; per-window breakdown
99.8 / 45.9 / 39.3 mean, getting worse later in the file) despite every
individual chunk having an exactly correct frame count (verified via
packet count against `duration × 24fps`, 9/10 chunks exact, across
multiple different machines). The safety gate correctly refused to
promote the bad file — nothing shipped — but the underlying defect
(likely a timestamp/PTS drift during mkvmerge's stream-append, possibly
connected to the source's own coarse `1/1000` container timebase not
evenly dividing `24fps`) is unresolved. Investigation paused after
hitting repeated tool-syntax obstacles in the low-level PTS forensics;
reproducible failing case preserved on Sting for the next session.
**Layer 1 chunk-parallel is NOT yet safe for production default-on.**

## v5.1.1W — 2026-08-22

**Phase 3 wiring: real automated verifier + finalizer, and the encoder-tier
claim/encode driver, for the chunk-parallel pipeline.** Everything before
this version required manually SSHing into each machine to drive the
split/claim/encode/verify/concatenate steps by hand — the mechanism was
proven correct (Mad Heidi test, 98.17 mean VMAF) but none of it ran on its
own. This version wires it into the pipeline for real, still gated off by
default (`CONVERT_CHUNK_PARALLEL_ENABLED=false`), per the plan's Phase 4
requirement that it not go fleet-default until a real live end-to-end
validation pass:

- New `chunk_parallel_process_video()` (`ves-chunk-coordinator.sh`): the
  entry point `try_av1_convert` now calls instead of a whole-file encode
  whenever `chunk_should_split` is true. Splits (idempotent), claims one
  chunk, encodes it, returns — same one-job-per-call contract every other
  entry point in this loop already follows; the scan loop's own repeated
  iteration drives a title's remaining chunks forward across passes.
- New module `modules/ves-chunk-verify.sh` (intended for Sting, matching
  the bake-off decision in `project_chunk_parallel_verifier_bakeoff_2026_08_22`,
  but not host-specific code): `chunk_verify_pending()` does a cheap
  structural decode check per newly-encoded chunk (not a VMAF judgment —
  see the module header for why); `chunk_finalize_manifest()` concatenates
  via `mkvmerge` once every chunk is verified, then runs the *same*
  whole-file `measure_final_vmaf`/`vmaf_target_for_source` gate a normal
  whole-file encode is held to, before promoting the result to the
  canonical output path. Deliberately does NOT touch the original source,
  write the done-log, or write anything the existing scan-time path
  (`inspect_existing_outputs_for_queue` → `validate_mkv_output` →
  `done_log_append`) doesn't already handle correctly for any valid file
  sitting at `av1_output_path` — avoids a second, harder-to-keep-in-sync
  copy of safety-critical completion logic.
- `chunk_verifier_scan_once()`: one pass over every `*.chunks` manifest
  under the scan roots, driving verify+finalize for whichever ones are
  ready. No daemon/sleep-loop wrapper yet — that, and a real live
  end-to-end validation run, are the explicit next steps (Phase 4) before
  this is trusted unattended against production data.

## v5.1.1V — 2026-08-22

**Real bug found live during the first Mad Heidi chunk-parallel fleet test**:
`chunk_claim_next()` only skipped chunks already marked `verified`, not
`encoded`. Since Phase 3's automated verifier isn't wired in yet, every
encoder-tier machine finished its chunk, released the claim, and
immediately re-claimed (and re-encoded) that same still-`encoded`
chunk — all 4 active machines got stuck looping on their own first
chunk, never advancing to the remaining unclaimed ones. Fixed by
skipping both `verified` and `encoded` statuses.

## v5.1.1U — 2026-08-22

**Real bug found live during the same test**: `chunk_encode_claimed()`
never checked the return code of its final output `mv` or its
`chunk_mark_status` write, so a permission failure was silently reported
as success while producing no durable output. Root cause: fleet worker
accounts are not UID/GID-aligned across machines (LAYTOYAJ=1000,
Plex=1001, MJACKSON=1002, Sting=3000) — a shared manifest directory
created with a restrictive default mode left every other host's writes
failing outright. LAYTOYAJ's log showed "chunk 1 encoded OK" four times
in a row with no status file or output ever produced. Fixed two ways:
`chunk_encode_claimed` now checks both write operations and reports
failure on either; `chunk_split_create_manifest` now `chmod 0777`s the
manifest directory it creates, matching this project's existing file-
permissions convention (see [[feedback_never_delete_live_lock]] and
[[feedback_chunk_parallel_tool_parity]] in project memory for the full
incident writeup, including the tool-version-parity issue found in the
same session).

## v5.1.1T — 2026-08-21/22

**Windows port of `modules/ves-chunk-coordinator.sh`**: new
`windows/modules/VesChunkCoordinator.psm1` (manifest creation with the
same real keyframe-snapped boundaries and shared CRF/profile caching,
per-chunk claim via `Enter-VesSharedMutexOnce`/`Exit-VesSharedMutex` —
the same Windows-safe file-claim primitive `VesTitleLock.psm1` already
uses, not `mkdir`, per this NAS's documented broken-ACL-on-fresh-
directories behavior), wired into `windows/convert.ps1`'s
`Import-Module` array (required on Windows — unlike bash, nothing
auto-discovers new modules by glob). Validated on RANDYJ against a real
file up through the manifest-creation and claim/status lifecycle before
today's NAS incident interrupted further testing; the CRF-caching
extension itself is not yet live-validated on Windows (documented as an
open item) since real-file testing was blocked by the incident for the
rest of this session.

**Real bug found and fixed via live bash testing** (not assumed
correct): `chunk_split_create_manifest()`'s CRF resolution called
`resolve_crf_for_encode()` inside a `crf="$(...)"` capture without first
calling `resolve_upscale_target()` as its own statement — the first-ever
call to `resolve_upscale_target()` for a source logs a one-time
"Upscale decision: ..." line via `log()` (stdout, this codebase's
convention), and since `resolve_crf_for_encode()` calls it internally
too, that log line was leaking into the captured CRF value
(`crf=[convert] Upscale decision: ...\n26` instead of `crf=26`). Found
by actually reading the stored `manifest.meta` after a live test, not by
inspection. Fixed by resolving upscale target as its own statement
first (populating the same cache `resolve_crf_for_encode` then hits
silently), matching the call-order discipline the whole-file path
(`ffmpeg_encode()`) already follows. Reverified end-to-end after the fix
— `manifest.meta` now correctly shows `crf=26` for a real file, matching
that title's known-correct CRF from every earlier whole-file test this
session. Windows was never affected (`Write-Host`, this port's own
logging primitive, isn't captured by PowerShell variable assignment the
way bash's `log()`-to-stdout is by `$(...)`).

Also fleet-wide this session (not a code change): root-caused and fixed
a real NAS incident where attaching a pre-existing, actively-shared ZFS
dataset (`BigMomma/Media`, `BigPoppa/Media`, `BabyBear/Media`) as an
Incus disk-device source via the TrueNAS Virt API caused those datasets
to become unmounted, breaking Media access fleet-wide — fixed via `zfs
mount` + `exportfs -ra` (both real, safe, non-destructive administrative
commands, no data was ever at risk). Documented in
`~/.claude/plans/how-can-we-chaneg-cheeky-goose.md` (the distributed
chunk-parallel encoding plan this release is part of) as a real
constraint on that plan's Sting NAS instance.

## v5.1.1S — 2026-08-21

**New `modules/ves-chunk-coordinator.sh`** (bash only so far; Windows port
pending), Phase 2 of the distributed chunk-parallel encoding initiative
(see `~/.claude/plans/how-can-we-chaneg-cheeky-goose.md`): the manifest
creation and per-chunk atomic claim primitives that let multiple specific
fleet machines cooperate on one file, something no existing code path
supports (`ves-sharded-scan.sh`/`ves-pipeline-scan.sh` are pull-based,
single-machine-per-file throughout). Not yet wired into the main scan
loop — this release only adds the new module as a self-contained,
independently-tested unit, following this project's own precedent for
introducing new subsystems incrementally.

- Chunk boundaries are real, **keyframe-snapped source timestamps** (an
  `ffprobe -skip_frame nokey` scan), not assumed at a fixed interval —
  necessary for a clean later stream-copy concat, since a time-based cut
  alone doesn't guarantee landing on a decodable boundary.
- Per-chunk claiming reuses `ves-title-lock.sh`'s exact proven mkdir-lock
  + mv-based-stale-reclaim primitive (atomic on NFS/CIFS, same 7200s
  staleness ceiling), just keyed by `<title>.chunk<N>` instead of
  `<title>` alone — no new locking mechanism, only a new key convention.
- Manifest storage is one-file-per-chunk, not a single shared file
  multiple machines append to — deliberately, per this project's own
  prior finding that shared-file append is unreliable on this NAS (see
  the ELVIS Phase 3 done-log precedent).
- **Real bug found and fixed via live testing** (not assumed correct):
  `ffprobe`'s `-of csv=print_section=0` still emits a trailing comma
  after a single-field row, which was silently leaking into every stored
  `start_ts`/`end_ts` value (`611.110000,` instead of `611.110000`) —
  would have broken every downstream `ffmpeg -ss`/`-to` call. Found by
  actually running the splitter against a real 6674-second movie and
  reading the stored chunk files, not by inspection alone. Fixed, then
  reverified end-to-end (11 real chunks, correct manifest structure,
  claim → status write → release lifecycle all confirmed) on the same
  file after the fix.

## v5.1.1R — 2026-08-21

**New per-machine SVT-AV1 parallelism override plumbing** (spec'd out,
not yet calibrated), explicit user direction: found while investigating
PRINCE's post-update RAM-disk retest that a genuinely strong machine
(13th Gen i9-13900HX, 24 cores/32 threads) was sitting at ~51-56% CPU
utilization during encode, with no OS-level explanation found —
`PROCTHROTTLEMAX`/`PROCTHROTTLEMIN` both unrestricted, CPU affinity
unrestricted, no thread-count override anywhere in this pipeline's own
code. Most likely explanation: SVT-AV1's tile-based parallelism model
doesn't always scale to fully saturate very high core counts on its
own, especially at a fast preset with less parallel work to distribute.

User's framing, carried through into the design: core count alone isn't
sufficient to decide this — a machine needs strong *per-core* throughput
too, or added tiles just cost compression efficiency (real, if usually
small, from lost cross-tile prediction) without a real speed payoff.
RANDYJ (many logical processors via old-generation HT, weak per-thread
IPC/clock) and PRINCE (many logical processors, genuinely strong modern
cores) are the natural opposite-ends test pair.

**Added on both platforms**: three new per-machine overrides —
`CONVERT_SVTAV1_TILE_COLUMNS`/`CONVERT_SVTAV1_TILE_ROWS`/
`CONVERT_SVTAV1_LP` (bash, env-var-driven) /
`$env:CONVERT_SVTAV1_TILE_COLUMNS`/`TILE_ROWS`/`LP` (Windows, same
names) — unset by default everywhere, zero behavior change until a
machine is explicitly calibrated. Applied inside
`profile_svt_params()`/`Get-VesProfileSvtParams`, shared by both the
VMAF CRF search and the final encode, so CRF search always stays
calibrated against the exact tile/thread config the final encode uses
(matching this function's existing sharpness-support-detection pattern).
Real per-machine values are meant to come from actual VMAF-at-matching-
CRF benchmarks on that specific machine — see the planned rollout in
this session's notes: benchmark PRINCE and RANDYJ first (opposite ends
of the "many logical processors" spectrum), then decide real values,
then multi-tool review before any machine actually gets a non-empty
default. Syntax-verified only — no benchmarking done yet, no machine's
behavior has actually changed.

## v5.1.1Q — 2026-08-21

**Windows-only parity fix**: `convert.ps1`'s RAM-disk opt-out threshold
(`$RamDiskMinAvailBytes`, v5.1.1P) was a hardcoded `59GB` literal with no
override, unlike bash's `CONVERT_RAMDISK_MIN_AVAIL_GB` which was already
env-var-driven (`${CONVERT_RAMDISK_MIN_AVAIL_GB:-59}`) from the same
release. Needed live, mid-session: after updating and rebooting PRINCE
(31.69GB total, well under the 59GB-free default), forcing a genuine
RAM-disk-enabled retest required a real override mechanism, not a
one-off hand-edit of the deployed script. Now reads
`$env:CONVERT_RAMDISK_MIN_AVAIL_GB` if set (same variable name as bash,
same override semantics — set to 0 to force ramdisk staging on a
below-threshold machine), falling back to the 59GB default otherwise.
No bash changes — bash already had this. Syntax-verified.

## v5.1.1P — 2026-08-21

**Recalibrated the v5.1.1O RAM-disk opt-out gate**, explicit user
direction: switched from a 64GB *total installed* RAM threshold to a
59GB *currently available (free)* RAM threshold. Renamed
`CONVERT_RAMDISK_MIN_TOTAL_GB` → `CONVERT_RAMDISK_MIN_AVAIL_GB` (bash,
default 59) / `$RamDiskMinTotalBytes` → `$RamDiskMinAvailBytes`
(Windows, `59GB`), both now keyed off the same available-memory basis
`_mem_available_bytes()`/`Get-VesAvailableMemoryBytes` already uses for
the two-tier sizing formula, instead of a separate total-installed-RAM
figure. Removed the now-unused `_mem_total_bytes()`/
`Get-VesTotalMemoryBytes` helpers added in v5.1.1O, since nothing else
needed them once the gate switched basis. The gate's actual effect (skip
ramdisk staging by default, fall through to the existing local-disk
staging fallback) is unchanged — only what it measures and the exact
number changed. Syntax-verified.

## v5.1.1O — 2026-08-21

**RAM-disk staging is now opt-out by hardware class, not universal**,
explicit user direction following this session's multi-hour PRINCE crash
investigation. That investigation conclusively isolated a reproducible
`ffmpeg.exe` access-violation crash to RAM-disk staging itself on one
real fleet machine (PRINCE, 31.7GB total RAM): the identical file, same
machine, same encode settings, completed cleanly with zero issues when
RAM-disk staging was disabled (`-NoRamDisk`), after crashing 5/5 times
with it enabled. Combined with the separate real ENOSPC failure found on
ELVIS this same session (v5.1.1N) and the fact that video encoding is
CPU-bound (a RAM disk's write-latency advantage over a real local SSD is
marginal for this workload's actual I/O pattern — mostly large,
sequential writes well within any modern SSD's sustained throughput),
the risk/benefit tradeoff no longer favors RAM disk as a blanket default.

**Changed on both platforms**: machines with less than 64GB of *total
installed* RAM (a fixed hardware characteristic, deliberately distinct
from the *available*-memory figure the existing two-tier sizing formula
uses) now skip RAM-disk staging entirely by default and fall straight
through to the already-existing local-disk staging fallback — same
write-back-to-NAS-on-completion behavior, same local-only logs, nothing
new to build there. New config constant `CONVERT_RAMDISK_MIN_TOTAL_GB`
(bash, default 64, set to 0 to override) / `$RamDiskMinTotalBytes`
(Windows, in `convert.ps1`). The existing two-tier *sizing* formula
(`CONVERT_RAMDISK_PCT_LARGE`/`CONVERT_RAMDISK_CAP_SMALL_GB`) is
unchanged for machines that still qualify (64GB+ total RAM) — this only
gates whether a RAM disk is used at all, not how it's sized when it is.
New `_mem_total_bytes()`/`Get-VesTotalMemoryBytes` helpers added
alongside the existing available-memory ones. On this fleet, this takes
PRINCE (31.7GB total) off RAM-disk staging by default going forward —
directly addressing the machine the crash was isolated to. Syntax-verified.

## v5.1.1N — 2026-08-21

**Fixed a real remux-stage RAM-disk-exhaustion gap**, found by a fleet
health-check audit independent of the PRINCE crash investigation:
ELVIS's "Mad Heidi (2022)" AV1 attempt failed at the *remux* stage (not
the encode stage) with `rc=-28`, `"There is not enough space on the
disk"`, despite the v5.1.1J two-tier RAM-disk sizing fix already being
deployed. Root cause: `resolve_encode_stage_path()`/
`Resolve-VesEncodeStagePath` only ever sizes the RAM disk against the
*source* file's size, once, before stage 1 even starts — it never
accounted for stage 1's own output (the just-finished video+audio-only
file) and the final remuxed output needing to coexist on the RAM disk
*simultaneously* during the remux stage, roughly 2x a single file's
worth of space. v5.1.1J's fix was for a different resource entirely (the
encoder's own internal working memory), so it didn't cover this.

**Fixed on both platforms**: right after stage 1 succeeds (so stage 1's
real on-disk size is known exactly, not estimated), a new check compares
it against actual current free space on the RAM disk. If there isn't
room for a second same-size file, only the final remux *output*
retargets to local disk — stage 1 itself stays put on the RAM disk
untouched (ffmpeg reads it fine across filesystems), so nothing
already-written needs to move, and the existing move-into-place logic
(already agnostic to RAM-disk-vs-local-fallback paths) picks it up with
no further changes needed. Syntax-verified on both platforms; not yet
exercised against a real remux-stage-headroom-shortfall reproduction.

## v5.1.1M — 2026-08-20

**Temporary diagnostic instrumentation**, added while root-causing the
"Happiness for Beginners (2023)" `ffmpeg.exe` access-violation crash on
PRINCE: after both the v5.1.1K live-capture fix and the v5.1.1L
never-silently-delete fix, a 4th crash-reproduction attempt *still*
produced no stderr sidecar file at all — no file, not even an empty one,
and no warning from either fix path. To isolate exactly where the
capture is failing (file never created vs. created-then-lost
vs. genuinely zero bytes written by SVT-AV1 before the crash),
`Invoke-VesTrackedProcess` (`windows/modules/VesTrackedProcess.psm1`) now
writes an immediate `[capture started ...]` marker line right after
opening the sidecar log (before the child process even starts) and a
`[capture ended, exitcode=...]` marker right before returning — so the
file's mere presence/absence, and which markers it contains, definitively
answers the question on the next crash. Also hardened the stdout/stderr
`.Result` reads against a faulted `Task` (accessing `.Result` on a
faulted async read re-throws synchronously) so a broken pipe on a hard
crash can't silently escape the capture loop uncaught. Intended to be
removed once the real crash is root-caused — this is instrumentation, not
a fix. Syntax-verified; deployed fleet-wide for version parity, no bash
changes.

## v5.1.1L — 2026-08-20

**Fixed a second, more severe logging bug found immediately while verifying
the v5.1.1K fix live**: relaunching "Happiness for Beginners (2023)" on
PRINCE a third time reproduced the identical `ffmpeg.exe` access violation
(same fault offset again), but the new v5.1.1K live-capture stderr log was
*still* missing entirely afterward — not a v5.1.1K regression, but a
second, independent bug in the RAM-disk stale-attempt-file sweep added in
v5.1.1I (`ramdisk_sweep_stale_attempt_files()` / bash,
`Clear-VesRamDiskStaleAttemptFiles` / Windows), which runs automatically
right before the x265 fallback starts. Its own doc comment says it "moves
anything found to a local holding directory rather than deleting it
outright, in case it's ever worth a human glance" — but the actual code
did the opposite whenever the move failed: silently `rm -f`/`Remove-Item`
the file with zero warning, on both platforms. A file a just-crashed
process wrote is plausibly still transiently locked (OS/AV scanner) right
when the sweep runs, which is exactly the scenario that kept destroying
this investigation's evidence.

**Fixed on both platforms**: the sweep now retries the move once after a
brief pause (covers a transient post-crash lock), and if the move still
fails, falls back to copy-then-delete instead of straight-to-delete — the
content survives even when an atomic rename doesn't. Only if both a move
and a copy fail does it now log an explicit warning naming the lost file,
instead of staying silent. Syntax-verified on both platforms; a further
PRINCE re-test is what will actually confirm the AV1 crash's stderr
survives this time.

## v5.1.1K — 2026-08-20

**Fixed a Windows-only diagnostic-logging gap discovered while retesting the
v5.1.1J fix**: relaunching "Happiness for Beginners (2023)" on PRINCE after
the v5.1.1J two-tier RAM-disk sizing fix reproduced the exact same crash
(`ffmpeg.exe` access violation, `0xc0000005`, identical fault offset both
times), but with 16.6GB of 31.7GB RAM still free at the moment of the
crash — ruling out RAM-disk/memory-pressure as this crash's cause and
pointing at a genuine, deterministic native crash inside `ffmpeg.exe`
itself (confirmed via Windows Event Log's Application Error record, not
guessed). Investigating it further was blocked by a real gap:
`Invoke-VesTrackedProcess` (`windows/modules/VesTrackedProcess.psm1`)
captured stderr via `.NET`'s `ReadToEndAsync()`, buffered entirely in
memory and only written to the sidecar log file after `WaitForExit()`
returned — so a hard access-violation crash, which tears down the
process's stdio pipes without a clean exit, left the sidecar log
completely empty both times, with no way to tell whether the encoder ever
printed anything before it died.

**Fixed**: rewrote the capture as a synchronous polling read loop —
`ReadLineAsync()` against the child's stdout/stderr, waited on with a
bounded timeout so the loop can also poll `$proc.HasExited`, with every
stderr line appended and flushed to the sidecar log file as it arrives.
Whatever the crashed process managed to write before dying is now durably
on disk immediately, not sitting in an in-memory buffer that only
persists on a clean exit. This intentionally does *not* use
`Register-ObjectEvent` (already proven to silently drop output in this
runtime, see `VesTimeoutRetry.psm1`) — it's the dedicated polling loop
that file's own comment called for if live capture ever became a real
requirement. Bash's stderr capture already streamed live via `tee` on a
process-substitution fd (see `ves-twostage-encode.sh`), so this is a
Windows-only fix; the bash version bump is for fleet version-parity only,
no bash code changed. Callers only consume `.ExitCode` from this
function's return value, never the in-memory `.StdErr`/`.StdOut` strings
programmatically, so this is a safe internal rework with no call-site
changes needed. Syntax-verified (`pwsh -Command
[System.Management.Automation.Language.Parser]::ParseFile`); a live
crash-reproduction re-test on PRINCE is the real verification, in
progress.

## v5.1.1J — 2026-08-20

**Root-caused why the RAM-disk-exhaustion failures kept happening**,
investigating a real PRINCE crash mid-session: `SvtMalloc[fatal]: allocate
memory failed` on "Happiness for Beginners (2023)" (true 4K, 3840x2160,
10-bit) turned out to be a genuinely distinct issue from the earlier
`ENOSPC` RAM-disk-full failures (v5.1.1H/I) — not the RAM disk running out
of file-write space, but the *encoder process itself* failing to allocate
its own working memory (SVT-AV1's internal picture-buffer pool: `Number of
PPCS 305` at this resolution/GOP config is ~7.6GB just for picture buffers
alone, before any other internal structures). Confirmed via direct
investigation: PRINCE has 31.7GB total RAM: the RAM disk's flat
60%-of-available formula was claiming the majority of free memory *before*
the encoder even started, leaving a demanding 4K encode's own multi-GB
memory need squeezed into whatever was left.

**Fixed on both platforms, per explicit user direction**: RAM-disk sizing
is now two-tier instead of a flat percentage. Below 64GB of available
memory (most of the fleet's non-workstation machines), the RAM disk is
capped at a flat 12GB regardless of how much more is technically free —
leaving generous, predictable headroom for the encoder (a ~32GB machine
now keeps ~20GB free instead of ~13GB under the old 60% formula). At or
above 64GB available, 45% of available is used instead (down from 60%),
since a large-RAM machine has enough headroom either way and a flat cap
there would waste real staging capacity for no benefit. All three
thresholds are named, overridable config constants on both platforms
(`CONVERT_RAMDISK_TIER_THRESHOLD_GB`/`CONVERT_RAMDISK_PCT_LARGE`/`CONVERT_RAMDISK_CAP_SMALL_GB`
in `ves-config.sh`; `-TierThresholdBytes`/`-PercentOfAvailable`/`-CapSmallBytes`
on `New-VesRamDiskJob`), not hard-coded — verified against 5 realistic
scenarios (28GB/60GB/64GB/90GB/8GB available) confirming correct behavior
at both tiers and the boundary, including the safety clamp for a machine
with less than the flat cap actually free.

Does not eliminate the possibility of a genuinely oversized encode still
exceeding available memory on a real machine (that's an inherent limit,
not a bug) — but removes the RAM disk itself as a major, avoidable
contributor to that pressure. This is a distinct fix from v5.1.1H/I's
ENOSPC-focused work; both failure classes are now addressed.

Verified via `bash -n` and the PowerShell language parser, plus a
standalone arithmetic test of the sizing formula against 5 real-world
scenarios — not yet exercised by a real fleet encode.

## v5.1.1I — 2026-08-20

**Explicit user hypothesis, confirmed and fixed**: when the pipeline falls
back from a failed/discarded AV1 attempt to a real x265 encode, anything
the AV1 attempt left behind in the RAM disk was competing with the x265
attempt for the same limited space — directly contributing to (if not
solely responsible for) the RAM-disk-exhaustion failure v5.1.1H already
root-caused on PRINCE. `RAMDISK_JOB_STAGE_DIR` (bash) / `$ramDiskJob.StagePath`
(Windows) is a single directory reused across a whole job's lifetime —
both codec attempts stage into it, and it's only ever torn down at job
end, not between attempts — so a crashed AV1 encode whose own cleanup
path didn't run (a genuine access-violation crash can bypass normal
control flow) would leave partial data sitting there indefinitely while
x265 started fresh alongside it.

**Fixed on both platforms**: before any x265 fallback attempt begins, the
RAM disk staging area is now explicitly swept — anything found gets moved
to a local-disk holding directory (not deleted outright, in case it's
ever worth a look for debugging a repeat crash), guaranteeing the RAM
disk is genuinely clear for the active attempt regardless of whether the
prior attempt's own cleanup worked. `ramdisk_sweep_stale_attempt_files()`
(bash, `modules/ves-ramdisk.sh`) is called once at `try_x265_convert()`'s
single shared entry point — all three of `try_av1_convert()`'s fallback
call sites (encode failure, validation failure, size-overshoot) funnel
through it, so one call site covers all three triggers. `Clear-VesRamDiskStaleAttemptFiles`
(Windows, `windows/modules/VesRamDisk.psm1`) is called from
`Invoke-VesCodecEncodeAttempt` gated on `-Codec hevc`, mirroring the same
"sweep at the x265 entry point" choice. Both are harmless no-ops when
nothing was left behind — the common case, when the prior attempt's own
cleanup already worked correctly.

Also confirmed via this session's regression-test audit: **PRINCE's own
"A Clockwork Orange" retry (under v5.1.1H, before this fix) has not yet
reached this file in its queue** — the RAM-disk-exhaustion root cause
itself hasn't been re-tested against the original failure case yet. Also
found during the same audit: **ELVIS's "Mad Heidi" run, previously
misreported as a clean success earlier this session, was actually a
`last_status:"failed"`** — the misreport traced to a stale
`convert-v4.log` entry from an unrelated 2026-08-14 run being read
instead of the current session's real resume-state; the actual failure
hit the identical RAM-disk `ENOSPC` signature as A Clockwork Orange. Needs
a re-run under v5.1.1I. Not fixed this release (separate, already-flagged
follow-up): a systemic Windows-only gap where the "only copy the
diagnostic stderr log back to the NAS if non-empty" policy (v5.1.1E/H)
doesn't actually filter anything on Windows, because
`Invoke-VesTrackedProcess`'s `ReadToEndAsync`-based capture always
returns a full blob at process exit, unlike bash where a clean run's
piped `-stats` output was empirically found to produce nothing.

Verified via `bash -n` and the PowerShell language parser only — not yet
exercised by a real fleet encode.

## v5.1.1H — 2026-08-20

**Two real bugs found root-causing a genuine PRINCE production failure**
during the full-history regression test: "A Clockwork Orange (1971)" (a
large HDR10 source with many PGS subtitle streams) failed after ~13 hours.
Investigation traced it to RAM-disk space exhaustion on PRINCE corrupting
an in-progress x265 stage-1 encode (it silently stopped at ~72 of 137
minutes but still exited with a clean success marker — caught correctly
by the existing post-encode duration-mismatch validation, so no bad
output was kept, but real compute was wasted). While root-causing it, a
second, independent bug surfaced: the AV1 attempt's own crash diagnostics
(the access-violation crash that triggered the x265 fallback in the first
place) were unrecoverable, because both the AV1 and x265 attempts reused
the identical PID-only-based log filename — the x265 fallback's own log
silently overwrote the AV1 crash's evidence before anyone could read it.

**Fixed both, on both platforms, per explicit user direction**:

1. **Diagnostic stderr logs now write to genuine local disk, never the
   RAM disk.** The RAM disk is reserved exclusively for encode DATA (the
   thing that actually benefits from RAM speed) — sharing it with
   diagnostic text logs made it a scarce resource two unrelated concerns
   competed for, and this session's real failure is a direct consequence.
   Bash: routes to `$_CONVERT_V4_SCRIPT_DIR/logs/ffmpeg-tmp` (the script's
   own deployment directory — guaranteed real disk, unlike `/tmp`, which
   is tmpfs/RAM-backed on this fleet's Linux machines). Windows: routes to
   `$LocalFallbackDir` (already threaded through as `-LocalStagingDir` at
   every call site, previously only used for the encode-output fallback
   path, now also used for logs unconditionally). Same NAS-sidecar
   copy-back-if-non-empty policy from v5.1.1E/v5.1.1G is unchanged, only
   the *live* local location moved.
2. **Codec is now part of every diagnostic log filename**, not just PID —
   `<title>.<codec>.<pid>.stderr.log` instead of `<title>.<pid>.stderr.log`.
   A codec-fallback retry (AV1 fails, caller retries with x265) can no
   longer silently clobber the failed attempt's own crash evidence, since
   both attempts share the same PID within one job but now write to
   distinct files. Windows required a new `-Codec` parameter on
   `Invoke-VesTwoStageEncode`, threaded from the one real call site in
   `convert.ps1`.

Verified via `bash -n` and the PowerShell language parser only — **not
yet exercised by a real fleet encode**, per explicit user direction to
hold off on relaunching any jobs while investigating the PRINCE failure
(a NAS-hosted VM is being set up separately). The RAM-disk-exhaustion
root cause itself (why PRINCE's RAM disk ran out of space on this
specific title) is not fixed by this release — this release only stops
diagnostic logs from competing for that same scarce space; a genuine
undersized-RAM-disk-for-large-multi-track-sources fix, if still needed
once logs are out of the way, is separate future work.

## v5.1.1G — 2026-08-19

**Closed a real Windows/bash feature-parity gap, user-flagged as high
severity**: the proactive per-source VFR/CFR detection + baseline
self-VMAF check (`detect_frame_rate_mode()` / `measure_source_baseline_vmaf()`,
bash's `modules/ves-source-traits.sh`, shipped v5.1.0W) had **no Windows
port at all** — confirmed via an exhaustive grep of every `.psm1` module
on a live fleet machine, zero hits for `frame_rate_mode`/`avg_cv`/`VFR_CV`.
Found while running a VFR-source hunt on Windows: every single one of 8
real dry-run scans came back "no result" — not because those files were
CFR/VFR either way, but because the check the scan was looking for simply
didn't exist on that platform.

**Not a quality-safety hole in the comparison math itself** — the
VMAF-VFR false-positive fix (v5.1.0S/T's measure-both-ways-take-max
frame-rate normalization) was already correctly ported and present in
`Get-VesFinalVmaf` (`windows/modules/VesVmafCrfSearch.psm1`). What was
missing was the *proactive detection/logging/ambiguous-flagging* layer
that runs before CRF search, giving early visibility into a source's
frame-timing characteristics rather than only reacting after a VMAF
score comes back suspicious.

**Fixed**, reusing already-ported helpers rather than duplicating logic:
- `Get-VesSourceFrameRateMode` (port of `detect_frame_rate_mode()`) —
  reuses the already-ported `Get-VesComplexitySamplePoints` (3-point
  low/median/high sampling, same one used for the AV1-vs-x265 bake-off)
  and `Get-VesDtsDeltaCv` (already existed, used for the separate
  output-side duplicate-frame check). New code needed was genuinely
  small: the CV-threshold classification and caching.
- `Get-VesSourceBaselineVmaf` (port of `measure_source_baseline_vmaf()`)
  — thin cached wrapper around the already-verified `Get-VesFinalVmaf`,
  self-vs-self comparison.
- `Write-VesSourceTraitsAmbiguousFlag` (port of
  `flag_source_traits_ambiguous()`, `windows/modules/VesValidation.psm1`)
  — same one-file-per-entry pattern as the existing
  `Write-VesLowQualityFlag`/`Write-VesBadSourceFlag` (a shared-file
  append is unreliable on this NAS from Windows clients, confirmed in
  production 2026-08-06).
- Wired into `convert.ps1` at the exact point bash's `ffmpeg_encode()`
  calls the equivalent pair — after HDR-mode resolution, before CRF
  search, on `$videoSrc` (the actual pixels the encode uses, not the
  possibly-QTGMC-substituted `$EncodeSource`).

**Verified live against real production data on RANDYJ**: `Get-VesSourceFrameRateMode`
against Highwaymen (2004) returned `cfr (avg_cv=0.0109 windows=3)` —
numerically identical to bash's result on the same file.

**Related, smaller finding, not fixed this release**: Windows's `-DryRun`
bails out at `Invoke-VesFileJob` (before any profile/HDR/CRF/traits work
runs at all), while bash's `--dry-run` reaches much deeper into the
per-file pipeline. This meant testing the new functions required a
direct function call rather than `-DryRun` end-to-end — flagged as a
separate, smaller parity item for a future pass, not addressed here.

No bash changes this release (Windows-only fix) — version bumped anyway
to keep bash/Windows on one shared version number, per standing
convention.

## v5.1.1F — 2026-08-19

**Second pass of the same NAS-load/RAM-disk audit** (a full sweep of every
live-encode write path, not just the one already fixed in v5.1.1E), per
explicit user direction to triage "even small ones" before restarting the
weighted stress test.

1. **Real bug, multi-GB impact**: `qtgmc_deinterlace_to_intermediate()`
   (`modules/ves-qtgmc.sh`) staged its lossless deinterlaced intermediate
   via `${CONVERT_RAMDISK_DIR:-${TMPDIR:-/tmp}}` — `CONVERT_RAMDISK_DIR`
   is a rarely-set *user override* (empty by default), not
   `RAMDISK_JOB_DIR`, the actual runtime-resolved/created per-job ramdisk
   from `ramdisk_init`. Every real run fell through to plain
   `${TMPDIR:-/tmp}`: harmless on Linux (tmpfs), but on macOS that's real
   local disk, not the `/Volumes/ConvertRAMDisk` the job already created —
   and either way it shared neither that ramdisk's disk-budget accounting
   nor its single-teardown lifecycle. Fixed to use `RAMDISK_JOB_DIR`
   directly.
2. **Minor, consistency-only**: every `mktemp`/`mktemp -d` in
   `modules/ves-vmaf-crf-search.sh` (upscale-decision clips, CRF-search
   sample encodes, encoder-bakeoff samples) now prefers `RAMDISK_JOB_DIR`
   the same way — these were already RAM-backed via plain `/tmp` on Linux
   (tmpfs), so this closes the same macOS gap rather than fixing a real
   NAS-load problem; done anyway per explicit "even small ones" direction.

Everything else checked in the audit (VMAF comparison's direct `-ss`
seeks, the title-lock heartbeat's tiny 300s `touch`, HandBrake's temp
clips, all Windows `.psm1` temp-file usage) was already correctly local
or intentionally NAS-resident — no further changes. Windows QTGMC isn't
wired into the encode path at all yet (matches the standing QTGMC
fleet-deployment plan's Phase E, still future work, not a bug here).
Verified via `bash -n` only; not yet exercised by a real fleet encode.

## v5.1.1E — 2026-08-19

**Routed live ffmpeg diagnostic stderr off the NAS onto local/RAM-disk
staging (both platforms)**, found while investigating a user report that
RAM-disk utilization looked low during a 9-machine weighted stress test
even though it's meant to be the primary "write path" of encoding.

Direct empirical test (`-v warning -stats` piped through the same
`tee`/process-substitution pattern the pipeline uses) confirmed
`_run_capturing_stderr`'s per-title stderr log grows continuously
throughout an encode — roughly one write every ~0.5s, for however long the
real encode runs (hours, on this fleet's slower machines). `errbase`
resolved through `${JOB_SIDECAR_DIR:-/tmp}/ffmpeg-logs`, which for a plain
NFS-mounted source defaults to `JOB_ROOT` — the NAS folder next to the
source — so every one of those periodic writes was a real, avoidable NFS
write for a diagnostic stream nobody reads while the job is healthy. Same
gap existed on Windows: `VesTwoStageEncode.psm1`'s stderr log shared
`$ErrorLogDir` (also NAS) with the `-progress` file.

Fixed by routing the live stderr tee to the same local/ramdisk directory
the encode's own binary output already stages to (`dirname "$dst"` in
bash, `Split-Path -Parent $writeDst` in PowerShell) — no new staging
machinery needed, it's the exact directory `resolve_encode_stage_path`/
`Resolve-VesEncodeStagePath` already resolved for this job. The finished
log is copied back to the real NAS sidecar only if it's non-empty (a real
warning, worth a human look) — matching the pre-existing "empty logs get
discarded" policy on both platforms, just now decided locally instead of
on every live append.

**Explicit scope, per user direction (2026-08-19)**: only files that
block multi-connections (title-lock directories), track progress
(resume-state/done-log, the Windows `-progress` file), or exist for human
inspection (`bad_sources.txt`, `corrupt_files.txt`, etc.) belong on the
NAS. Everything else "live" during the encode — this diagnostic stderr
stream — now stays local. The `-progress` file and all resume-state/
lock/audit-trail files are unchanged by this fix; only the stderr log
moved. Verified via `bash -n` / the PowerShell language parser on both
modified files; not yet exercised by a real fleet encode (the concurrent
9-machine weighted stress test was already running v5.1.1D when this
landed and was left alone — this fix ships in v5.1.1E for the next round
of jobs).

## v5.1.1D — 2026-08-18

**Fixed a real validation-retry bug found during a 20-file movie-length
fleet stress test**: `_run_timeout_retry` (bash) / `Invoke-VesWithTimeoutRetry`
(Windows) -- the shared timeout-wrapped-retry helper behind `mkvalidator`,
`ffprobe`, `mkvmerge`, and bounded validation `ffmpeg` calls -- retried a
timed-out call up to `VALIDATION_TIMEOUT_RETRIES` times using the exact
same timeout budget on every attempt. Found live: a 7.76GB movie source's
`mkvalidator` structural check hit its size-scaled timeout (~47 minutes,
per `_validation_timeout_for_args`) and timed out identically on all 3
attempts (1 initial + 2 retries), permanently skipping a perfectly valid
source file with "possible stalled mount" -- even though the file was
never actually stalled, it just needed more time than a single identical
retry could ever provide. The per-GiB timeout formula has already been
tuned twice against real library-wide size data (2026-07-26/27) and stays
well-justified for the size distribution it targets; per-file throughput
still varies beyond what any single size-based estimate can promise
(content structure, transient NFS load), so retrying with an *identical*
budget can structurally never help when the budget itself was the
problem. **The fix**: each retry now doubles the timeout instead of
reusing it, self-correcting for that variance without needing to keep
re-guessing a static formula. Same fix applied on both platforms.

Also investigated during the same stress test and found to be a
pre-existing, separate gap (not caused by this fix, not fixed this
release): Windows-side encodes never get an embedded `VES_PROCESSED`
quality tag the way bash's `write_ves_processed_tag` always writes one --
turns out no MKVToolNix (`mkvmerge.exe`/`mkvpropedit.exe`) is provisioned
on any Windows fleet machine, so there's no tool available to perform the
tag write with at all, not just missing code. The safety-critical behavior
(flagging genuinely below-floor encodes for human review via
`Write-VesLowQualityFlag`) is unaffected and confirmed still working
correctly. Deploying MKVToolNix to the Windows fleet is a real scoped task
of its own if full tag parity is wanted later.

## v5.1.1C — 2026-08-17

**Fixed the real-encode VMAF muxer-timestamp measurement bug (task #172)**,
found at scale while investigating why nearly every episode of Falling
Skies (2011) — an entire 52-episode series turned up by a fleet-wide
library re-scan, unrelated to the original 38-file backlog — was landing
well below the VMAF 85 floor despite CRF-search predicting healthy
quality.

**Root cause**: `measure_final_vmaf()`/`_vmaf_compare_window_once()`
(`modules/ves-vmaf-crf-search.sh`, and the PowerShell port `Get-VesFinalVmaf`
in `windows/modules/VesVmafCrfSearch.psm1`) seek into source and output
independently at the same nominal `-ss` timestamp, then zero each stream's
own PTS (`setpts=PTS-STARTPTS`). ffmpeg's MKV muxer relabels the output's
PTS with an offset vs the source (observed 20-43ms), so "the same nominal
timestamp" can land on genuinely different real-content frames between the
two files — invisible on static content, severe on fast motion.

**Two design iterations were tried and disproven by real tests before
landing on the fix that shipped**:
1. Measuring the src/out first-frame PTS delta once per file and
   compensating the output-side seek by it unconditionally. A real test on
   PRINCE showed this made one file's measurement dramatically *worse*
   (72.6 → 26.9 for the same sample window).
2. `max(uncompensated, measured-offset)` — extending the existing
   VFR/fps_filter "take the higher of two measurements" safety pattern to
   the offset axis. This fixed the one case tested, but a follow-up
   13-point offset sweep on the same window revealed the true best
   alignment is a sharp single peak (collapsing ~50 VMAF points within one
   frame either side) that can sit anywhere nearby — not something a single
   guessed offset can reliably predict, because the real misalignment isn't
   a fixed property of the file, it varies window to window (frame jitter,
   B-frame reordering, scene cuts).

**The fix that shipped**: don't guess the offset at all — for each sample
window, SEARCH every whole-frame offset from `-VMAF_ALIGN_SEARCH_FRAMES` to
`+VMAF_ALIGN_SEARCH_FRAMES` (new config, default 3; `-AlignSearchFrames` on
the Windows side) crossed with the existing plain/fps-filter axis, and keep
whichever scores highest. Misalignment can only ever drag a score
spuriously low, never inflate it, so taking the max across every candidate
in the search is safe in every direction. Verified against 4 real cases:
a genuinely-bad pre-v5.1.1B output correctly stayed low (73.9, still
flagged for review), a genuinely-good fresh output scored 94.7, the PRINCE
regression case recovered to 94.5, and an unrelated known-good file stayed
a healthy, non-inflated 93.6 (regression check).

A separate hypothesis — whether the existing `measure_source_baseline_vmaf()`
self-vs-self sanity check could predict which files would hit this bug —
was tested and disproven (Falling Skies and an unaffected control file
scored nearly identically, ~99 and ~98.5): comparing a file against itself
is trivially perfectly aligned by construction, so it structurally cannot
surface a cross-file muxer offset. Kept for its own real purpose (single-file
VFR/timing irregularity detection); not applicable to this bug.

**Cost**: real and accepted deliberately — up to 7 offsets × 2 fps-filter
variants × 3 sample windows = 42 ffmpeg passes, ~5-8 minutes per
`measure_final_vmaf()` call on modest hardware. This runs once per
completed file as a diagnostic tag, not on any hot path.

**Not yet done**: files already flagged `NEEDS REVIEW`/low-quality before
this fix landed were measured with the old broken comparator and were never
automatically re-evaluated — re-running the fixed measurement against that
backlog to clear likely-false-positive flags is an open decision, not yet
actioned.

## v5.1.1B — 2026-08-16

**Root cause found and fixed for the v5.1.1A frame-duplication defect** —
reopens and supersedes that entry's "not conclusively pinned down"
conclusion. While triaging what looked like isolated ELVIS job failures
during the 38-file requeue, the new v5.1.1A diagnostic tag surfaced that
the defect reproduces **100% deterministically** on a fresh re-encode:
checked across 6 fleet machines (bash/Linux and PowerShell/Windows, 3
different ffmpeg builds), every single Stargate Universe S01 and Marvel's
Runaways S02 episode re-encoded during the requeue came back tagged
"LIKELY FRAME DUPLICATION" — not the isolated, unproven, NAS-contention-
window theory the original entry described.

Isolated via direct reproduction testing against a real source file
(Stargate Universe S01E17 - Pain), bypassing the full pipeline to run the
exact stage-1 ffmpeg command by hand against short extracted clips:
- The full-length encode reproduces (`cv=0.77` uniformly from frame 1 to
  the end of a 43-minute job); a 5-minute clip of the *same* content
  starting 20 minutes in is completely clean.
- Narrowed to *start position*, not duration: a 5-minute clip starting at
  t=0 is broken; the identical 5-minute duration starting at t=30s is
  clean. The trigger is specific content in the opening ~30 seconds
  (recap/title-card/network-bumper, typical of broadcast TV cold-opens)
  that corrupts frame pacing for the *entire remainder* of the job once
  triggered.
- Ruled out as factors: `scd=0` (scene-change detection off) — still
  broken, identical duplicate count. `-preset 8` instead of `-preset 5` —
  still broken, identical duplicate count. This ruled out SVT-AV1-internal
  rate-control/lookahead state as the mechanism (a real encoder bug would
  be expected to vary by preset).
- The exact, reproducible fix: `-fps_mode cfr` instead of `-fps_mode
  passthrough` on the stage-1 encode. Verified clean (matches the known-
  good baseline CV of ~0.01 exactly, both on the 5-minute reproduction
  clip and the full 43-minute source) with every other variable held
  constant. `passthrough` blindly propagates whatever PTS sequence the
  HEVC decoder emits for a given input; for this specific content the
  decoder's PTS output has a subtle irregularity in the opening segment
  that is **invisible at the container/packet level** (a from-scratch,
  whole-file ffprobe packet-DTS scan of the source measured perfectly
  regular timing throughout, zero anomalies) but present after decode —
  `cfr` properly retimes to the nominal frame rate instead of passing that
  through unmodified.

`-fps_mode passthrough` was originally added 2026-07-31 (v5.0.33J) as an
explicitly *unconfirmed* "low-risk, no downside" mitigation for a
different bug (KanColle Movie stalling before EOF on subtitle-heavy
content) — that entry's own text says the mechanism was "not fully
proven." The KanColle bug's real, confirmed fix was the two-stage
encode/remux restructure shipped shortly after (2026-08-02), which
already keeps subtitles/attachments out of the stage-1 encode entirely —
`passthrough` was never actually load-bearing for that fix. It turned out
to have a real, serious downside instead. Changed on stage 1 only (both
`modules/ves-twostage-encode.sh` and `windows/modules/VesTwoStageEncode.psm1`)
— the stage-2 remux stays on `passthrough`, since it's a `-c:v copy`
stream copy where `-fps_mode` is a no-op either way; left unchanged to
minimize the diff.

**Not yet done, follow-up needed**: re-encode the full backlog (all 38
original files plus everything reprocessed during the requeue that came
back tagged) with the fix; audit whether any other, non-flagged content in
the library shares this trigger (opening-segment content type, not codec
or show) and could be silently affected without ever crossing the VMAF
floor to get flagged.

## v5.1.1A — 2026-08-16

**Diagnostic-only safeguard: `detect_output_frame_duplication()` / `Get-VesOutputFrameDuplication`**,
added while root-causing a 38-file fleet-wide below-VMAF-floor backlog
found auditing `low_quality_review.txt`. All 38 files (6 Battlestar
Galactica, 12 Marvel's Runaways, 19 Stargate Universe, 1 Godfather of
Harlem) re-measured to the *exact same* VMAF score against current code
— zero false positives, all genuine defects. Deep investigation of one
file (Marvel's Runaways S02E08) found a real, literal duplicate-packet
defect baked into the AV1 output itself: identical PTS twice in a row,
then a compensating double-length gap, at a regular ~1-in-3-packet
cadence — invisible to a still-frame/SSIM comparison (individual frames
decode fine) but catastrophic to VMAF (42-49 measured on files that
SSIM'd at 0.96-0.997), because the duplication/gap judder is exactly
what VMAF's motion-aware scoring is built to penalize.

Root cause not conclusively pinned down: ffmpeg (dated 2026-07-20) and
the SVT-AV1 library (dated 2026-01-29) are both unchanged since before
the defective batch, and the two-stage encode command in
`ves-twostage-encode.sh` is essentially identical to what ran the bad
batch (only an unrelated dead `enable-hdr` flag differs). A fresh,
isolated re-encode of the same content with identical current tooling
does not reproduce the defect. All 38 files trace to one narrow
2026-08-13 06:57-07:19 UTC window, across 4 machines spanning 2 OSes and
both physical and virtual hardware (LAYTOYAJ/AI-PROCESSOR VMs,
TITOJ/MARLONJ physical) — that cross-platform consistency in one narrow
window, documented (CHANGELOG v5.1.0W) as part of a coordinated
fleet-wide batch run, points to a shared external factor (working
theory: multiple machines reading the same NAS simultaneously caused
transient stalls ffmpeg's demuxer bridged by duplicating a frame) rather
than a persistent per-machine defect — but this can't be fully proven
since the original run's logs were already overwritten by the time this
was investigated.

Since the exact trigger can't be confirmed fixed, this ships a
detection safeguard instead of relying on that theory: reuses the
existing `_dts_delta_cv()`/`Get-VesDtsDeltaCv` packet-timing-variance
primitive (already used by `detect_frame_rate_mode()` for VFR detection
on the *source*) against the finished *output*, called only when a
final VMAF measurement has already come back below
`LOW_QUALITY_VMAF_THRESHOLD` — diagnostic, not an independent gate,
since the VMAF floor already catches these files regardless of cause.
Turns a generic "NEEDS REVIEW" tag into "LIKELY FRAME DUPLICATION,
RE-ENCODE RECOMMENDED" (bash: embedded MKV tag; Windows: new 5th field
on the existing `.quality-flag` sidecar file) so a human doesn't have to
re-derive this investigation from scratch if it recurs. New config
constant `OUTPUT_DUPLICATE_FRAME_CV_MAX=0.15`, set with wide margin
rather than a tuned boundary — clean encodes measured avg_cv 0.01-0.05
(same ballpark as a clean source), the confirmed-defective files all
measured 0.5-0.8+ on the identical technique. Verified against one real
confirmed-defective file (correctly flagged "duplicated") and one real
clean file (correctly flagged "ok").

Ported to Windows in full this release — `detect_frame_rate_mode()` and
`_dts_delta_cv()` themselves were never ported (a gap the original
v5.1.0W CHANGELOG entry flagged as bash-only with Windows as a
follow-up that never happened); this release adds `Get-VesDtsDeltaCv`
and `Get-VesOutputFrameDuplication` to `VesSourceTraits.psm1` from
scratch, following the same `Invoke-VesWithTimeoutRetry` pattern used
throughout the port. Code-complete and syntax-validated
(`[System.Management.Automation.Language.Parser]::ParseFile`), but live
functional verification on a real Windows machine is still pending — all
3 Windows machines were mid-job when this shipped, and PowerShell holds
an open handle on an imported `.psm1` file for the life of the process,
which silently blocked an `scp` overwrite attempt against ELVIS's
running job (a real, previously-undocumented deployment gotcha:
`convert.ps1` itself updated fine since it's just read once at
invocation, but the two loaded modules didn't — unlike bash, where
overwriting a script/sourced-module file mid-run is safe).

Also requeued all 38 confirmed-defective files for re-encoding across
the 8 then-idle fleet machines (PRINCE and RANDYJ excluded, both mid-job),
ordered heaviest/vintage-first to fastest hardware. Found and fixed a
real, unrelated deployment bug while doing this: the v5.1.0Z RAM-disk
fix's `scp` had copied `ves-config.sh` to the script root instead of
`modules/` on 5 of 6 Linux/macOS machines, so the real config file never
actually updated there despite no error at the time (only the one
machine deployed by hand, earlier in the same session, was correct) —
fixed with exact-path verification this time, not just a filename-glob
check.

## v5.1.0Z — 2026-08-15

**Raised default RAM-disk sizing (`CONVERT_RAMDISK_PCT`/`PercentOfAvailable`)
from 50% to 60% of available memory** after a real `ENOSPC` failure on
PRINCE: a 4K movie (Congo, 1995) ran its full AV1 encode successfully
(~4h20m) but died at the final remux stage with "No space left on
device" — confirmed via the ffmpeg stderr log, on both the
subtitles-included and subtitles-stripped retry. Root cause: the
two-stage pipeline's stage-1 intermediate (video+audio only) and
stage-2 final remux output briefly coexist on the same RAM disk, so
peak usage approaches ~2x the final file size — for a large 4K title
that easily exceeded the ~9.5GB a 50%-of-available RAM disk provided on
a 31.7GB-RAM machine. All 4+ hours of AV1 compute were lost; the job
fell back to x265 and re-ran the entire encode from scratch under the
same constraint. Fixed by widening the default headroom on both
platforms (`modules/ves-config.sh`'s `CONVERT_RAMDISK_PCT`,
`windows/modules/VesRamDisk.psm1`'s `PercentOfAvailable` param default)
— still leaves 40% of available memory for the encoder's own working
set, per the sizing comment's original intent. No caller on either
platform overrides the default, so this single-line change applies
fleet-wide. The currently-running job on PRINCE was not interrupted
(its RAM disk was already created under the old 50% for its lifetime,
and killing it would have lost real progress) — the fix applies to the
next job launched on any machine.

## v5.1.0Y — 2026-08-14/15

**Root-caused and fixed a real VMAF false-positive bug** found while
running a larger fleet-wide validation batch (2-3 real movies per
machine) to confirm v5.1.0X's fixes held up under sustained load. Three
files across two machines got flagged "BELOW FLOOR, NEEDS REVIEW" with
catastrophically low scores (44.3, 66.2, 75.8) despite being genuinely
fine — visually confirmed via extracted same-timestamp frame comparison
(near-identical to the eye), objective SSIM (~0.96, not catastrophic),
and matching duration/codec/color metadata between source and output.

**Root cause found via direct packet-timestamp inspection** (`ffprobe
-show_entries packet=pts_time`): ffmpeg's MKV muxer relabels frame PTS
values with a small, constant, non-frame-boundary-aligned offset
relative to the source's own timestamps (~43ms on a 23.976fps file,
confirmed identical near both the start and 40+ minutes into the same
file — ruling out an earlier "cumulative drift" theory suggested by the
uneven VMAF-vs-position pattern, which actually just reflects motion-
sensitivity: the same small misalignment barely dents a low-motion scene
but tanks the score on a high-motion one). `_vmaf_compare_window`'s
independent `-ss` seek on each input lands on the SAME nominal timestamp
but a DIFFERENT actual frame in src vs. a freshly-muxed MKV output,
comparing near-adjacent-but-different frames and scoring them near-
randomly. Confirmed and ruled out two other hypotheses first: seek-
precision (a true frame-accurate decode-from-start comparison gave the
identical bad score) and color/pixel-format mismatch (all metadata
matches exactly). A manually-compensated seek offset recovered most of
the lost score (52.3 -> 82.6 on the same window), confirming the
diagnosis, though the exact sub-frame alignment needed for a fully
precise general-purpose fix isn't nailed down yet (see below).

**Fixed for the provably-safe case (2 of 3 real occurrences): skip VMAF
measurement entirely for lossless stream-copy remuxes.** New `$lossless`
parameter threaded through `finalize_mkv_output()` ->
`write_ves_processed_tag()`, set `true` at all three
`remux_copy_to_mkv()` call sites (AV1-source remux-to-MKV, HEVC-in-MKV
stream-copy shortcut, x265-source non-MKV-container remux) -- `-c:v copy
-c:a copy` cannot possibly change quality by construction, so there was
never anything meaningful to measure at these call sites regardless of
what the underlying muxer-timestamp bug turns out to be. This is
strictly more correct than reporting a number already proven wrong in
two independent real-world reproductions (MARLONJ: "A Midsummer Night's
Dream" VMAF 66.2, "Time Loop" VMAF 44.3, both pure remuxes) and
completely sidesteps the bug without touching the shared VMAF comparator
that every real (non-lossless) encode fleet-wide still depends on.

**Left open (1 of 3 real occurrences, genuinely harder): a real AV1
transcode's final-quality measurement** (ELVIS: "I Put a Hit On You",
CRF search predicted ~90, final measured 75.8) hit the same underlying
muxer-timestamp-offset bug, but this call site can't just skip
measurement -- a real re-encode's quality genuinely needs checking. A
manually-tuned compensating seek offset improved but didn't fully
resolve the score (79-82 vs. an expected ~100 for a byte-identical
comparison scenario), and patching the shared `_vmaf_compare_window`
comparator used by every real encode fleet-wide on an unproven precise
offset carries real regression risk (could newly UNDER-flag a genuinely
bad encode) that isn't worth taking without more validation time.
Cleared the specific false-positive flag by hand this session (both the
bash per-title `low_quality_review.txt` entries on MARLONJ and the
Windows one-file-per-entry `.quality-flag` on ELVIS); the general fix
for real-encode final-VMAF timestamp alignment remains a documented,
scoped follow-up. Bash only this release -- the Windows port has no
lossless-remux-with-VMAF-tagging code path yet (the AV1/x265 bake-off
those call sites live in isn't ported), so there was nothing to change
there for the safe fix; the harder real-encode case affects both
platforms equally and is unresolved on both.

## v5.1.0X — 2026-08-13

**Fleet-wide validation test triage.** After the SMB `icacls` fix
(v5.1.0W's follow-up, above), ran a real one-movie-per-machine test
across all 10 fleet machines to confirm no regressions. Found and fixed
four more real bugs, none of them regressions from the ACL work itself
but all either newly exposed or newly discovered by it.

**(1) Windows orphan reaper hang, both PRINCE/ELVIS/RANDYJ.** After the
ACL fix, all three single-file test jobs hung indefinitely at "Orphan
reaper: scanning for crashed-job leftovers" (RANDYJ: 20+ min before this
was traced; confirmed not deadlocked, just slow). Root cause:
`Get-VesOrphanFlagCandidates` calls `Get-ChildItem -LiteralPath $Root
-Recurse -Force -File -Filter "*.$FlagSuffix"`, and PowerShell silently
**ignores `-Filter`/`-Recurse` entirely** when `-LiteralPath` points at a
single file (the single-file `-SearchPath` invocation mode) rather than a
directory — it just returns that one file as-is, filter unapplied. The
function then fed the multi-GB source video itself to `Get-Content`,
which tried to read it as newline-delimited text over SMB. This bug has
presumably existed since the single-file mode shipped, but was invisible
until today: the pre-fix broken ACLs made that `Get-Content` call fail
instantly with Access Denied, so it never got far enough to actually
attempt the read. Fixed by special-casing the non-container case: a
single-file `$Root` can only ever have one possible sibling flag
(`"$Root.$FlagSuffix"`, exactly what `New-VesInProgressFlag` writes), so
check that directly via `Get-Item` instead of recursing at all — verified
live, 20+ minutes → 0.2 seconds. Bash was never affected (its own
`find`-based equivalent doesn't have this quirk).

**(2) Root-caused the fleet's shared "Permission denied"/`icacls`
ACL-widen failures on `ffmpeg-logs/` sidecar directories** (previously
seen on JJACKSON/Plex/LAYTOYAJ/AI-PROCESSOR via bash's `tee`, and just
reproduced live on PRINCE via `icacls exit code 5`). Direct inspection on
the NAS console: a freshly Samba-created `ffmpeg-logs/` directory came
out `drwxrwsr-x` (0775) — SGID correctly inherited the parent's `media`
group, but "other" was only `r-x`, not the library's full `rwx`
convention. Both platforms' existing after-the-fact self-heal
(`ensure_shared_sidecar_dir`'s `chmod`+`sudo` escalation on bash,
`Set-VesEveryoneReadWrite`'s `icacls /grant` on Windows) require owning
the object or explicit rights to re-grant it, which a guest/different-
identity writer doesn't have — same fundamental limitation as the
session's earlier `icacls` investigation, just for a different operation.
Fixed at the true root instead: none of the 3 Media shares had a Samba
`create mask`/`directory mask` set, so Samba fell back to its own default
(0775-ish) rather than the library's 0777 convention. Added
`create mask = 0777`, `force create mode = 0777`, `directory mask = 0777`,
`force directory mode = 0777` to all three shares' `auxsmbconf` (TrueNAS
API, same "always send the full `options` object" convention as the
earlier ACL work) — a single, stock, GUI-exposed, update-surviving
server-side change that makes every SMB-created file/dir correctly
world-writable at creation time, closing the gap for every current and
future writer regardless of identity. Verified live: a fresh directory +
file created via SMB now come out `drwxrwsrwx`/`-rwxrwxrwx` automatically,
no self-heal needed. Both platforms' existing self-heal code is left in
place as defense-in-depth (harmless, now redundant for SMB-side writes).

**(3) `enable-hdr=1` removed from both platforms' `svtav1-params`.**
MARLONJ hit `Error parsing option enable-hdr: 1` from libsvtav1 on every
sample point and the real encode of an HDR concert file (non-fatal —
SVT-AV1 logs and ignores it, encode continues) — first noticed loudly
because MARLONJ runs SVT-AV1 **4.2.0**, drifted from the fleet-pinned
v4.1.0 standard. Investigation found `enable-hdr` is not a real SVT-AV1
option on any version checked: absent from `SvtAv1EncApp --help`
(including its dedicated Color Description Options section) and absent
from the compiled library's own string table. It was silently
logged-and-ignored on **every HDR encode this project has ever run**,
just quietly enough that nobody noticed until a newer SVT-AV1 build
happened to process real HDR content. No functional loss from removing
it — real HDR color signaling (`bt2020`/PQ or HLG) was always set
correctly via ffmpeg's own `-color_primaries`/`-color_trc`/`-colorspace`
args, entirely independent of this dead parameter; `mastering-display=`/
`content-light=` (the real, valid HDR10 static-metadata svtav1-params)
are untouched.

**(4) Windows local-disk staging leak, all 3 Windows machines** (found
while investigating (1) above: ELVIS alone had 55 orphaned
`convert-stage-*` directories, some over a week old). `New-VesLocalStageDir`
(the local-disk fallback used whenever RAM-disk staging is unavailable or
too small) had no cleanup path at all for a crashed job's stage dir --
unlike the RAM-disk staging path, it never wrote an ownership marker, so
nothing could ever safely determine whether a leftover directory's owning
process was dead and reclaim it. Fixed by giving it the same
`.ves-owner.json` marker convention `VesRamDisk.psm1` already uses (PID,
host, start time), a new `Get-VesLocalStageLeftovers` enumerator
mirroring `Get-VesRamDiskLeftovers`, and a sweep in `convert.ps1`'s
orphan-reap phase that purges any leftover whose recorded owner PID is
confirmed dead on this host -- these are in-flight scratch files, not
completed candidates, so they're purged wholesale rather than routed
through the salvage-or-delete gates used for RAM-disk leftovers. Verified
live: marker written on creation, correctly detected as a live-owner
leftover while its process is still running. Bash was never affected --
its own staging convention differs and already gets swept.

## v5.1.0W — 2026-08-13

**New: proactive per-source VFR/CFR detection + baseline self-VMAF**
(`modules/ves-source-traits.sh`), added after finding the v5.1.0S/T
VMAF-VFR false-positive bug had left ~130 files fleet-wide mistagged
"NEEDS REVIEW" (root-caused and mostly auto-corrected this session, see
below). That bug was only ever caught reactively, after the fact, by
noticing a suspiciously low encode-vs-source score. These two checks run
proactively, once per source (cached), before CRF search — unconditional,
every profile, not just vintage (the bug hit modern-profile titles:
Godfather of Harlem, Snowpiercer, Jessica Jones, Westworld).

- `detect_frame_rate_mode(src)` — classifies `cfr`/`vfr`/`unknown` via
  packet-level DTS-delta coefficient of variation, not the unreliable
  `r_frame_rate==avg_frame_rate` container-metadata heuristic (Battlestar
  Galactica slipped through that check entirely last session — its
  `avg_frame_rate` matches `r_frame_rate` despite real per-packet timing
  irregularities). Hit a real bug building this: ffprobe prints the
  literal string `"N/A"` for a packet's `dts_time` near a `-ss` seek
  boundary (before the B-frame reordering buffer fills), which silently
  corrupted the numeric sort/delta math and made every probe window fail
  — fixed by filtering non-numeric lines before the awk pass. Verified
  live: Godfather of Harlem → `cfr` (avg_cv=low); Battlestar Galactica →
  `cfr` too (avg_cv=0.0109) — confirming BSG's real quality problems are
  genuine low-bitrate broadcast-master content, not a frame-timing
  measurement artifact (consistent with the re-verification results
  below, where most BSG episodes stayed correctly flagged after
  re-measurement).
- `measure_source_baseline_vmaf(src)` — measures VMAF of `$src` against
  itself, reusing `measure_final_vmaf` unchanged (same measure-both-ways-
  take-max fps handling already hardened in v5.1.0T) rather than
  duplicating comparison logic. A pure measurement-methodology sanity
  check, not a real quality assessment — identical content should score
  ~100. A source that fails this baseline gets flagged for human review
  immediately via the existing `flag_source_traits_ambiguous` path,
  instead of silently producing a misleading low "quality" number after a
  real encode.
- New `_source_traits_cache_set(src, key, value)` helper merges a field
  into `SOURCE_TRAITS_CACHE[$src]`'s existing string rather than
  overwriting it, so the new universal checks and the existing
  vintage-only telecine/B&W detection can populate the same cache entry
  independently of call order.
- New config constants (both explicitly untuned, same caveat as the
  existing field-mode thresholds — calibrate against real confirmed-CFR
  and confirmed-VFR sources before relying on them beyond logging):
  `SOURCE_TRAITS_VFR_CV_MAX=0.05`, `SOURCE_BASELINE_VMAF_MIN=97.0`.
- **Bash only this release** — Windows PowerShell port (`VesQtgmc.psm1`-
  style module) is a follow-up, per plan (verify on the harder platform
  against real known-tricky files first, then port).

**Fleet-wide VMAF-VFR false-positive re-verification and auto-fix.**
Grepping every fleet machine's logs for "BELOW FLOOR, NEEDS REVIEW" found
~130 flagged files across 9 shows (Jessica Jones, Battlestar Galactica,
Marvel's Runaways, Stargate Universe, Godfather of Harlem, Snowpiercer, V
(1983), Penny Dreadful, Westworld), all tagged under versions predating
the v5.1.0S/T VMAF-VFR fix. Built a re-verify+auto-retag tool
(`write_ves_processed_tag` already does exactly the right thing — measure
with the current fixed code, rewrite the tag — so this was a thin driver
script, not new pipeline logic) and ran it fleet-wide. Confirmed
overwhelmingly false-positive: e.g. Snowpiercer 53.0→92.2, Westworld
61.2→91.3, Jessica Jones 52.3→98.9, Godfather of Harlem S03E08 66.9→99.4.
Two real bugs found and fixed in the driver script itself along the way
(neither is pipeline code, both self-caught before any real file was
touched incorrectly): an unquoted `$MKVLIST` variable that word-split
every filename containing spaces, silently no-op'ing the whole run; and a
stripped `PATH` in non-interactive macOS SSH sessions that made
`discover_tools` never find `mkvpropedit`, so `write_ves_processed_tag`
silently failed every tag write on MARLONJ specifically. Battlestar
Galactica was deliberately given extra scrutiny (real prior regression
history) — confirmed the fix correctly leaves genuinely-low-quality
episodes flagged rather than blindly clearing everything.

**NAS root-squash + SMB ACL findings (TrueNAS API, `10.10.10.150`).**
Root-caused the session's earlier "Permission denied" writing ffmpeg-log
sidecars: TrueNAS's default root-squash mapped every fleet worker
account's root/sudo writes to `nobody` on the three Media NFS shares
(`BabyBear/Media`, `BigMomma/Media`, `BigPoppa/Media`) — fixed via
`maproot_user=root`/`maproot_group=wheel` on all three shares. A first
NFSv4 ACL fix (`WRITE_OWNER` grant to `group@`/`everyone@`) looked
plausible but was a red herring for the actual chown failures (POSIX
blocks unprivileged/non-root-mapped chown regardless of ACL grants) —
kept anyway for consistency, then discovered it also needed to be
**recursive**, not just at the dataset root: the original non-recursive
apply only benefits brand-new folders created after the change, since
already-existing subdirectories (every real show/movie folder) never
inherited it. Reapplied recursively across all three datasets.

Separately investigated the Windows-side `icacls`/"Could not widen ACL"
failures (SMB, not NFS — a different share/protocol the NFS fix never
touched). Traced through three layers: (1) the NFSv4 ACL was missing
`WRITE_ACL` (Windows' "change permissions" right) on `group@`/`everyone@`
— granted, recursively, same as the `WRITE_OWNER` fix above; (2) even
with a correct ACL, `icacls` still failed — traced to the connecting
Windows identity (`PRINCE\worker`, a purely local Windows account with no
matching TrueNAS credential) silently falling through to Samba's guest
account under `guestok: true`; created a real TrueNAS SMB user (`worker`,
uid 3000, group `media`/gid 8080 — that gid existed on-disk with no actual
TrueNAS group object until created here) with SMB auth enabled, verified
via a real authenticated connection that the identity and file ownership
are now correct (no longer guest); (3) **`icacls` still fails even with
correct ACL and correct real authentication** — the remaining gap is in
Samba's own NFSv4-ACL-to-Windows-security-descriptor translation for this
share, not fixable via more ACL/user changes. Left open, documented
precisely rather than guessed at further; needs a Samba `vfs_objects`/
share-reconfiguration-level investigation.

**Follow-up, same day: SMB `icacls` root cause found and fixed.** Direct
NAS console access (previously unavailable) made the real evidence
visible: `/var/log/samba4/log.smbd` showed `ixnas_process_smbacl: ...
failed to set acl: Operation not permitted` for every single `icacls`
attempt this whole investigation ran — a raw kernel/ZFS-level `EPERM`
inside TrueNAS's own custom `ixnas` Samba VFS module, unrelated to
Windows-side authentication or session type (which explains why every
credential-persistence theory chased above turned out to be a dead end).
Fix: switched the affected datasets' `acltype` from `nfsv4` to `posix`
(`aclmode=DISCARD`, API-enforced pairing) via `pool.dataset.update` —
this removes `ixnas` from the share's auto-generated `vfs objects`
entirely and is a first-class, GUI-exposed, native TrueNAS/ZFS property
that survives updates/reboots (explicit user requirement — no smb.conf
hand-editing). Applied and verified via real authenticated `icacls`
exit-code-0 tests on all three Media datasets: `BigMomma/Media` (clean
first try), `BigPoppa/Media` (first attempt broke the share outright —
`SMB_VFS_CONNECT ... failed: No data available` — reverted, retried with
pauses between disable/switch/enable steps, succeeded cleanly the second
time; root cause of the first failure not conclusively pinned down, filed
as a transient/race risk to watch for on any future acltype switch on a
live share), and `BabyBear/Media` (blocked on the production share
because it's rooted at the *parent* `/mnt/BabyBear`, shared with the
unrelated Nextcloud dataset, and TrueNAS refuses an acltype switch when
it would create an ACL-type mismatch under a currently-*enabled* share's
root — resolved by creating a new dataset-scoped share, `BabyBearMedia`,
disabled first so the mismatch check doesn't fire, switching underneath
it, then enabling; the original `BabyBear` share and Nextcloud were
never touched). Also fixed the POSIX-mode group-inheritance gap this
introduces (new files get the creating process's primary group instead
of the parent directory's, since POSIX ACLs don't have NFSv4's automatic
inheritance) via the standard SGID bit, applied recursively on all three
datasets. Windows fleet paths updated to the new share names
(`\\<nas>\BigMommaMedia\`, `\\<nas>\BigPoppaMedia\`,
`\\<nas>\BabyBearMedia\`) on PRINCE/ELVIS/RANDYJ. Verified clean under
real production traffic: a fleet-wide one-file-per-machine validation
test produced zero `icacls` failures on all three Windows machines.

**Fleet-wide validation test findings (2026-08-13), unrelated to the ACL
fix itself.** Running one real movie/concert-length job per machine
surfaced two more real bugs, both self-contained to the Windows test
harness rather than the shipped pipeline code: (1) a stale/zombie
`convert.ps1` process on one Windows machine that Task Scheduler kept
reporting as `Running` for 80+ minutes past the point it had actually gone
idle — `Get-ScheduledTask` state cannot be trusted alone to mean "still
doing work" on this platform, matching the already-known unreliable-
`ExitCode` gotcha; (2) confirmed the already-documented library-path
auto-detection limitation (non-standard paths like `Concerts/` or
`Stand-Up Comedy/` need an explicit profile override) applies identically
on the Windows port's `-ForceProfile` parameter, not just bash's
`--profile`. Also found and cleared real staging-directory leak debris
unrelated to this session's work: dozens of orphaned `.convert-stage-*`
RAM-disk staging folders (one Windows machine had 55, dating back over a
week) that normal job completion never cleans up after a crash — worth a
proper fix (a startup-time sweep, not just the existing orphan-reaper's
narrower leftover-flag logic) in a future session.

## v5.1.0V — 2026-08-12

**Generalized v5.1.0U's permission fix, per explicit direction: every file
this pipeline writes should match its source path's own permissions and
ownership, not a hard-coded guess.** New `match_source_permissions(target,
reference)` reads `$reference`'s mode/owner/group and applies them to
`$target`, replacing the hard-coded `chmod 0777` in `ensure_shared_sidecar_dir`
(now derives from the target's own parent directory) and newly wired into
`finalize_mkv_output` (every finished output file goes through this one
function fleet-wide, confirmed by grep — one call site covers all of them)
using the file's own `$src` as the reference.

Found needed for more than the sidecar-directory case v5.1.0U fixed: a
real finished output was sitting at mode 666 owned by `worker:8080` right
next to its own source at mode 777 owned by `950:8080` — same group, so it
never actually broke access (pure luck: 666's "other" bits are already
rw), but not actually matching, which is the real ask.

**Important limitation, confirmed live and worth understanding**: the
`chmod` half of this reliably works (including the same passwordless-sudo
escalation v5.1.0U introduced) — verified 666→777 on a real file. The
`chown` half does not: `sudo chown` fails ("Operation not permitted")
against this NAS export for *any* target UID, including ones already
valid locally, while the identical `sudo chown` against a local
(non-NAS) file succeeds instantly. That rules out a client-side privilege
problem entirely — this NAS export hard-blocks ownership changes
server-side, for every client, root included. No client-side script
change can work around it; it would need the NAS's own export/dataset
configuration changed, if the platform even supports that. The chown
attempt is kept as pure best-effort (never fatal) in case a different
export does allow it, but on this NAS, matching MODE is the whole
practical win — a 777-mode file already grants full read/write to every
account regardless of nominal ownership, so the leftover owner-UID
mismatch is cosmetic, not a functional access problem.

## v5.1.0U — 2026-08-12

**Fixed real "Permission denied" failures writing shared NAS sidecar
directories (bash only)**, found while running small verification batches
across the fleet: AI-PROCESSOR and LAYTOYAJ both hit genuine
`Permission denied` errors writing their own `ffmpeg-logs/*.stderr.log`
files (jobs still completed -- these writes are non-fatal diagnostics --
but the logs themselves were silently lost).

Root cause, confirmed live: every media path in this library is
maintained at `777`/`admin:8080`, but that convention only covers
directories that already exist -- a *freshly created* directory doesn't
automatically inherit it. Whichever machine's `mkdir` first creates a
shared sidecar directory (`ffmpeg-logs/`, `.convert-v5-validation-failures/`,
`Deferred/`) gets whatever this NFS export's own default new-directory ACL
happens to be, which resolves to mode `0775` owned by an unmapped
`nobody:8080` rather than `0777`. The `worker` account on every fleet
machine is a member of its own `worker` group only (gid 1000) -- neither
`nobody` nor group `8080` -- so `0775`'s "other" bits (`r-x`, no write)
locked out every subsequent writer, including the very machine that
created the directory on its next run.

This is the exact same bug class already fixed on the Windows port via
`Set-VesEveryoneReadWrite` (see `VesTwoStageEncode.psm1`) -- bash never
had the equivalent self-heal. Fixed via a new `ensure_shared_sidecar_dir()`
helper (`modules/ves-validation.sh`), used at all three shared-directory
creation sites (`ffmpeg-logs/`, the validation-failure evidence dir,
`Deferred/`). A plain `chmod` from a non-owner account fails outright
(confirmed: `Operation not permitted` -- world-writable mode alone doesn't
grant permission to re-`chmod` a directory you don't own), so it falls
back to a non-interactive `sudo -n chmod` -- this fleet's worker accounts
have passwordless sudo by established convention, confirmed live this
actually fixes the real directory (root is not squashed on this NAS
export). Every step is best-effort and silently falls through if
unavailable, never treated as fatal. Verified end-to-end against the real
broken directory on AI-PROCESSOR: mode corrected to `0777`, a real file
write that previously failed now succeeds.

## v5.1.0T — 2026-08-12

Two fixes found while re-verifying v5.1.0S's own fix against the real
flagged-file list, plus one severe unrelated bug found investigating why
RANDYJ had an unexpected ffmpeg process running.

1. **v5.1.0S's VMAF frame-rate normalization corrected — it was NOT safe to
   apply unconditionally.** Re-running `measure_final_vmaf`/`Get-VesFinalVmaf`
   against every file flagged under the old (pre-S) measurement confirmed
   39 straight false positives across Snowpiercer/Jessica Jones/Man in the
   High Castle/Westworld — but Battlestar Galactica (1978) showed mixed
   results, including two files that got WORSE after the v5.1.0S fix
   (81.7→69.3, 70.9→61.3). Root cause: these episodes sit at an unusual
   native rate (500/21) where `avg_frame_rate` exactly equals
   `r_frame_rate` despite real, subtle frame-timing irregularities
   (confirmed via ffmpeg's own "non monotonically increasing dts"
   warnings) — forcing `fps=500/21` onto an already-matching stream
   introduced its own resampling artifacts. Fixed by measuring each sample
   window BOTH ways (with and without the fps filter) and keeping whichever
   score is higher: misalignment can only ever drag a score spuriously low,
   and unnecessary resampling can only ever drag it low too, so taking the
   max is safe in both directions — a genuinely bad encode still scores low
   either way. Verified: the regressed Battlestar Galactica file's score
   went from 61.3 (broken v5.1.0S) to 75.9 (still below floor, but no
   longer artificially suppressed, and better than even the original 70.9).
2. **A real uncaught-exception bug destroyed 100% of a 36-episode overnight
   batch on RANDYJ (ex-GruntBox2).** `Invoke-VesTrackedProcess`'s stderr
   sidecar-log write (`Set-Content`) had no error handling; when the
   diagnostic log's NAS-share ACL-widen also failed (a separate, still-open
   NAS-permission issue), every `Set-Content` threw, and since it ran last
   in the function, the exception propagated all the way out through the
   caller's try/finally (finally doesn't suppress it) to the job loop's own
   try/catch, discarding an already-fully-completed real encode over
   nothing but a failed diagnostic write. Every one of 36 jobs in an
   Orville batch (~40+ hours of real encoding) hit this and produced zero
   output — source files were never touched (this write is output-side
   only), so no data was lost, but the compute was a total loss. Fixed by
   wrapping the write in try/catch that degrades to a warning, matching
   what the surrounding code already documented as the intended contract
   ("these stderr logs are non-fatal diagnostics"). The identical bug
   existed in the HandBrake disc-source path (`VesHandBrake.psm1`) and was
   fixed the same way. The underlying NAS ACL-widen failure itself (why
   `icacls`/`Set-VesEveryoneReadWrite` can't fix this particular share's
   permissions) remains open, unrelated to this fix.

## v5.1.0S — 2026-08-11

**Fixed a false-positive "below VMAF floor" bug affecting VFR sources on
both platforms** -- found while sweeping fleet logs for issues: dozens of
episodes across five different shows (Snowpiercer, Marvel's Jessica Jones,
The Man in the High Castle, Westworld, Battlestar Galactica 1978) on five
different machines (AI-PROCESSOR, Plex, MJACKSON, JJACKSON, MARLONJ) had
their finished AV1/x265 output flagged as "Kept output below VMAF 85.00
floor" with scores as low as 50-84, despite the CRF search that picked
their encode settings having predicted ~94. Root cause: `measure_final_vmaf()`
(bash) / `Get-VesFinalVmaf` (Windows) independently `-ss`-seeks into the
original source and the finished output to grab a matching same-timestamp
window for libvmaf comparison -- fine for a constant-frame-rate source, but
a VFR source (duplicate/dropped frames scattered through the file, a common
web-rip artifact -- its `avg_frame_rate` differing from `r_frame_rate` is
the fingerprint) plays back at a genuinely different per-frame wall-clock
timing than the CFR output the encoder produces. The two independent seeks
then land on different underlying frames every few frames as the two
timings drift apart, and libvmaf silently scores each misaligned pair near
0. Confirmed via a real reproduction (Snowpiercer S01E01): a still-frame
grab at the flagged timestamp showed the two frames were visually
near-identical, but the per-frame VMAF log showed a literal ~3-frame-period
pattern of 90-100 alternating with 0.0. **The encoded output quality itself
was fine all along** -- this was purely a measurement bug. Fixed by
normalizing both streams to the source's nominal `r_frame_rate` via an
`fps=` filter before the libvmaf comparison on both platforms; verified
end-to-end through the real `measure_final_vmaf()` function against the
same file: pooled score went from 53.0 (flagged) to 92.2 (correctly above
floor), no other change. A failed/garbage frame-rate probe falls back to
the old unnormalized comparison rather than failing the whole measurement.
Every file already flagged under the old measurement should be considered
a false positive pending re-verification, not a confirmed quality problem.

## v5.1.0R — 2026-08-11

Two fixes found monitoring PRINCE and JJACKSON's live batches.

1. **Subtitle text-decode probe now short-circuits on confirmed real
   content, both platforms.** `subtitle_stream_has_real_content()` (bash)
   /`Test-VesSubtitleStreamHasRealContent` (Windows) already had a
   `head -1`-style early exit for the packet-presence probe, but the
   text-decode probe (the one that actually decodes to SRT to check for
   real dialogue) always ran to full completion regardless of platform --
   found via real fleet monitoring that PRINCE was repeatedly burning its
   full 3x60s retry budget on this probe across many Sabrina episodes
   (safe fallback each time, no data loss, but wasted minutes per file).
   Fixed on both platforms by piping the filter directly onto the
   decode's own stdout (bash: `| head -1`, letting `pipefail` capture
   ffmpeg's real exit code including 141/SIGPIPE the same way the packet
   probe already does; Windows: a new `Invoke-VesFfmpegSrtEarlyExit`
   using incremental `ReadLineAsync` + kill-on-first-real-line instead of
   the shared `Invoke-VesWithTimeoutRetry`'s `ReadToEndAsync`) -- only
   short-circuits the CONFIRMED-non-empty case, so the never-treat-
   ambiguous-as-empty invariant this probe exists for is unchanged.
   Verified against a real file (`The Man in the High Castle` S01E03):
   old approach still running past 2 minutes, new approach found real
   content and returned in 43.5s.
2. **`season_retry_pass()` now self-verifies it processed every promised
   retry candidate.** Found on JJACKSON: a season-shrink-heuristic retry
   logged "retrying 3 episode(s)" but only "Job 1 of 3" ever appeared
   before the run reported "Done" -- 2 candidates silently skipped with
   zero trace. Root cause not pinned down despite an isolated repro of
   the exact loop (with a mocked always-rejecting encode call) behaving
   correctly through all 3 iterations on real data, and every
   `begin_convert_job` failure path already warning on skip (none of
   those warnings appeared in the real log either). Added a defensive
   check: if the loop's actual processed count doesn't match the
   promised total, it now warns loudly instead of silently reporting
   success -- doesn't change behavior in the normal case, but turns any
   future recurrence from invisible into immediately diagnosable.

## v5.1.0Q — 2026-08-09

Real fleet-monitoring session turned up a genuine gap in the remux-shortcut
path (existing-desired-codec sources that only need a container change, no
re-encode) — found on 5 "Marvel's Jessica Jones" S03 mp4 sources on Plex.

1. **`remux_copy_to_mkv()` had no subtitle-failure fallback at all.** The
   main two-stage encode path (`ffmpeg_encode()`) already retries its final
   remux without subtitle/attachment streams if the first attempt fails —
   but this separate remux-shortcut function (shared by the must-eliminate-
   format floor, the HEVC-in-MKV lossless-remux shortcut, and the legacy-
   container "x265 remux to MKV" path) had no such fallback, so a single
   malformed subtitle track failed the *entire* remux (0 bytes written,
   video and audio lost too) instead of just dropping the bad subtitle.
   Reproduced on Jessica Jones S03E09-E13: each source's `mov_text` track
   threw `Task finished with error code: -22 (Invalid argument)` at mux
   time even though `build_real_subtitle_map_args` had already filtered it
   as "real" (non-empty) content — the track passes the emptiness check but
   is still internally malformed. Fixed by adding the same retry-without-
   subtitles fallback `ffmpeg_encode()` already has. Verified against a
   real failing file (S03E09): first attempt fails identically, fallback
   produces a full-length (52:05), `mkvalidator`-clean MKV with video+audio
   intact.

## v5.1.0P — 2026-08-08

Fourth confidence-review round on v5.1.0O's own timeout fix, requested as
an iterative "review + real encode test, fix, repeat until clean" loop.
The prior round's timeout fix turned out to not actually work either --
plus a real, live gap on the fleet's one macOS machine.

1. **The `--foreground` process-group bug — v5.1.0O's own timeout fix
   didn't actually protect against a hung QTGMC transcode.** The shared
   `run_with_timeout` wrapper (`modules/ves-timeout-retry.sh`) uses
   `timeout --foreground` whenever available -- GNU timeout's own docs
   say `--foreground` does NOT put the command in a new process group
   ("children of COMMAND will not be timed out"), confirmed directly:
   `timeout --foreground --kill-after=3 2 bash -c 'yes | sleep 30'` left
   both processes running as orphans after the wrapper was killed. That's
   the exact bug v5.1.0O's timeout fix was supposed to close, and it
   didn't, because `run_with_timeout` was the wrong tool for this
   specific call (`--foreground` exists there for a different, legitimate
   reason -- so a timeout signal can't kill an enclosing bash function's
   own redirected stdout/stderr). Fixed in `modules/ves-qtgmc.sh` by
   resolving the timeout/gtimeout binary directly (via the same
   `_timeout_cmd()` resolution `run_with_timeout` uses internally) and
   invoking it WITHOUT `--foreground` -- confirmed directly that plain
   `timeout --kill-after` DOES create a new process group and kills the
   whole group (including pipe-subshell children) on timeout.
2. **`set -e` bare-command risk** in the new timeout-invocation code,
   fixed by wrapping both the primary and fallback exit-status reads in
   explicit `if`/`then` (a bare command's nonzero exit under `set -e`
   aborts the whole script immediately -- this exact module has hit this
   bug class before).
3. **`QTGMC_FINAL_VMAF_*` entry-clear regression.** v5.1.0O added a
   cache-clear at the top of every `ffmpeg_encode()` call, reasoning it
   would prevent a stale cached VMAF from a discarded attempt (e.g. AV1,
   rejected by the size guard) leaking onto a different attempt's kept
   output (e.g. x265) for the same source. That reasoning was already
   fully covered by `QTGMC_FINAL_VMAF_DST`'s own match against the
   destination path in `write_ves_processed_tag`
   (`modules/ves-validation.sh`) -- a stale entry for a different
   destination simply never matches. The entry-clear itself introduced a
   real regression: a must-eliminate-format source whose AV1 attempt
   succeeds with QTGMC and gets STASHED (not finalized immediately, see
   `MUST_ELIMINATE_AV1_CANDIDATE`/`must_eliminate_fallback_or_fail()` in
   `modules/ves-twostage-encode.sh`) could have its correctly-cached VMAF
   wiped by a later x265 fallback attempt's own `ffmpeg_encode()` call,
   even when that x265 attempt failed before ever reaching its own
   success-path cache write -- so when the stashed AV1 was later salvaged
   and finalized, the correct cached value was already gone. Removed the
   entry-clear; the SRC+DST match alone is sufficient and correct.
4. **Real, live gap on MARLONJ (the fleet's one macOS machine): no
   `timeout`, `gtimeout`, or `setsid` at all**, confirmed directly via
   SSH -- meaning the new timeout code's own fallback path would have
   silently degraded every QTGMC run there to `bwdif` (`setsid: command
   not found`, exit 127, silently swallowed by the fallback's own error
   handling). Fixed two ways: installed `gtimeout` via `brew install
   coreutils` on MARLONJ directly (a real, permanent infrastructure fix,
   verified working via its full path), and hardened
   `modules/ves-timeout-retry.sh`'s `_timeout_cmd()` to also check fixed
   Homebrew paths (`/opt/homebrew/bin/gtimeout`, `/usr/local/bin/gtimeout`)
   as a last resort -- necessary because the `worker` service account on
   MARLONJ has no `.bash_profile`/`.zshrc`/`.zprofile` at all, so its PATH
   is bash's bare compiled-in default even after the binary was installed
   (`command -v gtimeout` alone never would have found it). Also hardened
   `modules/ves-qtgmc.sh`'s no-timeout-binary fallback to probe for
   `--kill-after` support before using it (not every resolved "timeout"
   binary is guaranteed GNU coreutils) and to check `setsid` availability
   before using it, falling back to a plain positive-PID kill (no
   process-group isolation, but no crash) if `setsid` is also absent.

All four findings verified across four consecutive real production
single-file encodes (Cosmos 1980 S01E10, a clip segment confirmed via
direct `idet` probing to be ~94-100% genuinely interlaced) during this
same review loop -- every run clean: QTGMC succeeded, AV1 encode
completed, plausible tagged VMAF each time, staging directory confirmed
gone after "Done." A fourth and final Gemini+Codex review round found
nothing further.

## v5.1.0O — 2026-08-08

Multi-tool review (Gemini + Codex + a third independent reviewer) of
v5.1.0N's own fixes, requested as a confidence pass before considering the
QTGMC feature done. Found real problems in that fix set itself -- most
seriously, one of the four v5.1.0N fixes was silently a complete no-op on
Windows the whole time.

1. **CRITICAL, Windows only — the v5.1.0N final-VMAF-reference and
   staging-leak fixes never actually worked.** `$videoSrc`/
   `$qtgmcIntermediate` were set inside `Invoke-VesCodecEncodeAttempt`, but
   the fix code reading them lived in the *caller*,
   `Invoke-VesEncodeAndValidate` -- a separate function. PowerShell doesn't
   share locals across function boundaries, so both were always `$null`
   there: `Get-VesFinalVmaf` received a null/empty source on every
   Windows title (QTGMC or not) and threw, caught by the job-level
   handler and logged as an ordinary failure -- every successful Windows
   encode was being silently re-queued forever, a regression already
   deployed to the Windows fleet. And the staging-dir cleanup check was
   always false, so the leak fix #3 was equally a no-op. Fixed by moving
   the same-representation VMAF computation and the cleanup inside
   `Invoke-VesCodecEncodeAttempt` itself (wrapped in `try`/`finally`, the
   PowerShell equivalent of bash's `trap ... RETURN`), and threading the
   computed VMAF back to the caller through the result object instead of
   relying on cross-function variable scope.
2. **Bash — hardcoded `target_height=0` broke the QTGMC final-VMAF fix for
   any upscaled title.** Genuine interlaced vintage content is SD
   (480i/576i), which this script's own upscale logic routinely scales to
   720p/1080p during the real encode -- the output is then a different
   resolution than QTGMC's SD intermediate, and libvmaf rejects the
   dimension mismatch outright on every sample. Missed in the original
   fix because the real test title happened to be tall enough to skip
   upscaling. Fixed by passing `$UPSCALE_TARGET_HEIGHT` (already computed
   earlier in the same function) instead of a bare `0`.
3. **Bash — an unguarded `rm -rf` inside the new `trap ... RETURN` could
   abort the whole script.** Under this script's `set -e`, a failing
   delete (NAS/SMB permission hiccup, busy file) inside the trap body
   would silently kill the entire run immediately after a fully
   successful encode. Fixed with `|| true`.
4. **Bash — `QTGMC_FINAL_VMAF_SRC` cross-attempt staleness.** The cache
   was keyed on source path alone, so a value computed for a discarded
   attempt (e.g. an oversized AV1 output rejected by the size guard)
   could in principle be wrongly applied to a different attempt's kept
   output for the same source (an x265 fallback, or the must-eliminate
   remux floor). Fixed by also keying on the destination path, and by
   clearing the cache at the top of every `ffmpeg_encode()` call so each
   new attempt starts clean.
5. **Bash — the v5.1.0N timeout fix left the QTGMC transcode pipe
   completely unbounded and untracked.** `run_tracked_encoder` on the
   right-hand side of a shell pipe runs in a subshell (no `lastpipe` in
   this codebase), so its PID/heartbeat tracking never reaches the
   parent -- a hung `vspipe`/`ffmpeg` had no timeout and no interrupt
   path at all. Fixed with a real, source-duration-scaled timeout via the
   codebase's existing `run_with_timeout` wrapper (already handles the
   macOS/no-`gtimeout`-available cases everywhere else); verified
   directly that it kills the whole process group, not just the
   immediate child.

All five re-verified together via a second real, clean, uninterrupted
production run: no crash, QTGMC succeeded, AV1 encode completed, tagged
VMAF 89.3, staging directory gone after "Done."

## v5.1.0N — 2026-08-08

Four real bugs found and fixed in v5.1.0M's QTGMC feature, all caught only
by running a genuine, unmocked, real-content single-file encode through
the actual production script -- every prior test in v5.1.0M either used
artificially short manual clips or bypassed real path-based profile
detection, and none of these four would have surfaced any other way.

1. **Validation-timeout bug (bash only) — QTGMC's real transcode had never
   actually succeeded on real production-length content.**
   `qtgmc_deinterlace_to_intermediate()` used `run_ffmpeg_validation` (a
   bounded wrapper that scales its timeout off a real file found via
   `-i <file>` or a bare filename argument) for the real vspipe-to-ffmpeg
   transcode -- but that call passes `-i -` (a pipe) and its output file
   doesn't exist yet when the timeout is calculated, so the scaling logic
   always fell back to the short validation-probe-sized base timeout.
   `_run_timeout_retry` killed the real transcode mid-write on any content
   longer than that short window. Fixed by switching to
   `run_tracked_encoder` (the same unbounded wrapper the real encode
   itself uses) in `modules/ves-qtgmc.sh`.
2. **Final-VMAF wrong-reference bug (both platforms) — every successful
   QTGMC job would have been falsely flagged for human review.** The
   quality-gate VMAF measurement (`measure_final_vmaf`/`Get-VesFinalVmaf`)
   compared the encoded output against the raw interlaced/telecined
   original, not QTGMC's deinterlaced intermediate. A clean deinterlaced
   frame and a raw combed frame at the same timestamp are structurally
   different images by design -- this isn't a temporal-alignment glitch,
   it's an inherently meaningless comparison, and it measured VMAF 4.9 for
   a genuinely correct encode. Fixed via a same-representation VMAF
   computed while the intermediate still exists (`QTGMC_FINAL_VMAF_SRC`/
   `QTGMC_FINAL_VMAF_VALUE` side-channel in bash, `$vmafRefSource` in
   Windows).
3. **Staging-directory leak (both platforms) — every successful QTGMC job
   permanently leaked its multi-GB lossless intermediate.** Only the
   failure branch of `qtgmc_deinterlace_to_intermediate`/
   `Invoke-VesQtgmcDeinterlace` ever removed the staging directory;
   nothing on the success path did. Confirmed via a real run leaving a
   9GB `.convert-stage-qtgmc-*` directory behind after "Done." Fixed with
   a `trap ... RETURN` in `ffmpeg_encode()` (bash) and an explicit
   `Remove-Item` after the final VMAF measurement in `convert.ps1`
   (Windows).
4. **Trap double-fire crash (bash only, introduced by this session's own
   fix for #3) — a real bash gotcha.** `ffmpeg_encode()` is called as the
   tail statement of `encode_dispatch()` (no `return` after it); a
   `trap ... RETURN` set inside `ffmpeg_encode()` fired correctly once for
   its own return, then fired again for `encode_dispatch()`'s return --
   where the trap's variable was never in scope -- crashing the whole job
   with "unbound variable" immediately after a fully successful encode.
   Reproduced in isolation before fixing. Fixed by making the trap body
   self-clearing (`trap - RETURN` as its own first action).

All four verified via a real production run through the actual deployed
`convert-v5.1.0N.sh` (not a custom test harness): QTGMC succeeded (no
bwdif fallback), the AV1 encode completed, tagged VMAF 92.2 (plausible,
not a false below-floor flag), and the staging directory was gone after
the job finished. This is the first real end-to-end QTGMC success this
whole effort has produced on genuine production-length content.

## v5.1.0M — 2026-08-07

Real field-based deinterlace for the `vintage` profile, both platforms.
Previously there was no auto-deinterlace filter at all -- genuinely
interlaced vintage TV content encoded with visible combing baked in.

**New: source-traits detector.** `modules/ves-source-traits.sh` (bash) /
`VesSourceTraits.psm1` (Windows, built from scratch -- nothing like this
existed on Windows before this release) classify a source's field mode
(progressive/telecine/interlaced/ambiguous) via ffmpeg's `idet` filter at
3 complexity-representative sample points (reusing the same low/median/
high sampling already used for the AV1-vs-x265 bake-off decision), plus
black-and-white detection via `signalstats` SATAVG. Ambiguous or
window-disagreeing reads never trigger an auto-filter -- this module only
ever says "confidently interlaced" or stays silent.

**New: QTGMC real deinterlace.** `modules/ves-qtgmc.sh` (bash/macOS,
shared) / `VesQtgmc.psm1` (Windows) run QTGMC (VapourSynth, classic
havsfunc.py, `InputType=0` genuine bob+weave motion-compensated
deinterlace) as a pipeline pre-process stage when `profile=vintage` and
field mode is confidently `interlaced` -- never for telecine/progressive/
ambiguous. `FPSDivisor=1` (explicit): full bob output, every real field
kept as its own distinct temporal sample, no data blended/discarded,
consistent with this project's #1 priority (no data loss) outranking #3
(size) -- confirmed with the user this doubles the delivered frame rate
(e.g. 25i -> 50p) and that this is intended. A real `bwdif` ffmpeg-filter
fallback (also new) engages when the QTGMC toolchain is unavailable or
fails -- e.g. RANDYJ, whose 2009-era Xeons lack AVX2 and can't run the
prebuilt `mvtools.dll` (confirmed, documented, deliberately deferred
hardware gap, not something this release fixes).

**Fleet-wide QTGMC toolchain deployment**, verified on 9 of 10 machines
across all 4 platform families (Fedora, Ubuntu, macOS, Windows) via real
QTGMC frame renders, not just "the plugin loaded":
`fleet-tools/install-qtgmc-{fedora,ubuntu,macos,windows}.ps1` (new files).
Ubuntu needed a from-source VapourSynth core build (no package exists);
Windows turned out the easiest platform (every plugin is a real
`vsrepo`/pip-wheel package with a prebuilt binary).

**Critical bug found and fixed (bash), via multi-tool review (Gemini +
Cursor independently converged, Codex found it too):** under this
script's `set -euo pipefail`, `qtgmc_intermediate="$(qtgmc_deinterlace_to_intermediate
"$src")"` as a bare assignment triggered errexit on ANY QTGMC failure,
aborting the whole encode before the bwdif-fallback flag could ever be
set. Every QTGMC failure mode (missing toolchain, vspipe issue, bad
script, empty output) silently killed the encode instead of degrading
gracefully. Reproduced directly (a minimal repro script under `set -e`)
before and after the fix; the fix moves the assignment into an `if`
condition, which bash exempts from errexit.

**Independently found and fixed during this same effort (not from the
formal review, from the author's own pixel-level verification), also
critical:** `ChromaEdi='none'` in the QTGMC call was corrupting every
processed frame's chroma into visible green noise -- confirmed by dumping
raw chroma-plane pixel values (wild noise instead of the correct
near-flat ~127-128 for real content) and rendering actual frames. This
had been present since the very first "working" QTGMC test of this whole
effort and stayed invisible through multiple rounds of "verified working"
because every check up to that point only inspected ffprobe metadata
(duration/frame count/codec), never an actual rendered frame. Fixed by
leaving `ChromaEdi` unset (QTGMC then mirrors `EdiMode`, i.e. NNEDI3 for
chroma too). New standing project rule as a result: any pixel-transform
change must be visually verified on a real rendered frame, not just
metadata -- see `feedback_visual_verify_pixel_transforms` in the AI
assistant's memory.

**Other real bugs found by multi-tool review and fixed (bash):**
a filename containing a single quote crashed the generated Python script
(shell-interpolated into a `r'...'` literal) -- fixed by passing the
source path via a process environment variable instead; VMAF-targeted
CRF search was silently degrading to a fixed CRF for every QTGMC-processed
title, because the internal VMAF-target lookup re-derives profile by
parsing the source path, and QTGMC's temp intermediate path doesn't match
any real library layout -- fixed with a `PROFILE_CONTEXT` save/restore
around the CRF-search call (an existing override mechanism, already used
elsewhere in this codebase for the same purpose); `build_ffmpeg_video_args`
was reading HDR/DoVi metadata from QTGMC's metadata-stripped intermediate
instead of the original file -- fixed (zero-cost fix, since QTGMC never
changes frame dimensions); `--no-auto-detelecine` was silently not
honored by the new wiring -- fixed with an early gate; global container
metadata (title/tags) was at risk of being lost on the two-input ffmpeg
command -- fixed with an explicit `-map_metadata`; a genuinely anamorphic
source's SAR/DAR was at risk of silently resetting to square pixels in
QTGMC's intermediate -- fixed by reading the real SAR via ffprobe and
stamping it onto the intermediate; `qtgmc_available()`'s Python probe only
ever tried loading `mvtools.so`, so a fully-working macOS install
(`mvtools.dylib`) could cache "unavailable" forever -- fixed. One reviewer
claim (a supposedly too-narrow `vspipe` path-search list) was checked
against this session's own real successful runs and rejected as a false
positive -- documented in the assistant's memory with the reasoning.

**Windows port bug found during its own end-to-end verification:** .NET's
`Process.WaitForExit(int)` and `Task.WaitAll(..., int)` both return a
`bool` that PowerShell puts on the pipeline unless explicitly suppressed
-- unsuppressed, these leaked into `Invoke-VesQtgmcDeinterlace`'s own
return value, so a caller doing `$intermediate = Invoke-VesQtgmcDeinterlace
...` received `"True True True <path>"` as a single joined string instead
of just the path. Fixed with explicit `[void]` casts. Found and fixed via
a real end-to-end test on ELVIS (not a mock) before this shipped.

Windows source-traits detection and QTGMC wiring verified end-to-end on
real hardware (ELVIS): real `idet`-based field-mode detection matched the
bash side's results almost exactly on the same real interlaced source
(Cosmos (1980) S01E10, a genuine 1980 video-broadcast documentary used as
this project's positive-control interlaced title -- Batman (1943), used
earlier in this effort, turned out to be an already-progressive digital
transfer and only ever validated the negative-control path); real QTGMC
deinterlace produced correct colors and a real, combing-free frame,
visually verified; the full two-stage-encode pipeline (QTGMC intermediate
for video, original file for audio/metadata) and the forced-failure
bwdif-fallback path were both verified with real ffmpeg output, not a
mock.

**Second, final review round (Gemini + Codex + Cursor again) found four
more real bugs, all fixed and re-verified before fleet deploy:**
1. **`-aspect` sets display aspect ratio (DAR), not sample aspect ratio
   (SAR)** -- the anamorphic-SAR fix from the first review round was
   itself wrong, on both bash and Windows. Confirmed by a direct empirical
   test: `-aspect 8:9` on a 720x480 frame produced
   `sample_aspect_ratio=16:27` (wrong) and `display_aspect_ratio=8:9`,
   while `-vf setsar=8/9` correctly produced `sample_aspect_ratio=8:9`
   and the correctly-derived `display_aspect_ratio=4:3`. Same class of
   bug as `ChromaEdi` -- a plausible-looking fix that no duration/codec/
   frame-count check would ever catch. Fixed on both platforms by
   switching to a `setsar` video filter.
2. **Windows: `Invoke-VesQtgmcDeinterlace` never checked `vspipe`'s own
   exit code**, only ffmpeg's -- if vspipe crashed partway through
   rendering, ffmpeg would see the resulting partial y4m stream as a
   normal EOF, exit 0, and write a real but truncated intermediate, which
   would have been accepted as a successful QTGMC run instead of falling
   back to bwdif. Fixed by requiring both processes' exit codes, plus
   checking the byte-copy task didn't fault/cancel.
3. **Windows: a hung ffmpeg process after the byte-copy completed was
   never killed** -- the timeout was only enforced while the copy itself
   was in progress; if ffmpeg then hung while flushing/muxing, the
   `WaitForExit` call could return `false` (still running) and the code
   would silently discard that signal and read `.ExitCode` from a process
   that might still be alive. Fixed by explicitly killing either process
   if its post-copy `WaitForExit` doesn't report a real exit.
4. **Windows: `[double]::TryParse`/string-formatting without
   `InvariantCulture`** in the source-traits detector -- confirmed by
   direct testing under a comma-decimal locale (de-DE): the default
   `TryParse` overload doesn't fail on `"180.123"`, it silently
   *mis-parses* it as `180123` (period read as a thousands separator),
   and the `-f` format operator renders `180.123` as `"180,123"`,
   producing an invalid ffprobe `-read_intervals` spec. Either would
   silently break complexity sampling and B&W detection on any
   non-US-locale Windows machine. Fixed with explicit
   `CultureInfo.InvariantCulture` throughout. (Two other claims from this
   same finding -- a supposed `$null`-crash in the SAR helper and a
   supposed culture-sensitivity bug in plain string interpolation of a
   double -- were checked by direct test and found to be false positives;
   not changed.)

All four fixes re-verified end-to-end on real ELVIS hardware (real QTGMC
success path, correct dimensions/frame rate, real audio/video output)
before redeploying to every already-deployed fleet machine.

## v5.1.0L — 2026-08-07

Two real bugs found in a live 15-episode PRINCE batch (Batman, 1943) that
finished "12 ok, 3 failed" -- both windows-only, both in
`Invoke-VesEncodeAndValidate` and its supporting error-log-directory
handling.

**Bug 1 -- silent, unexplained job failure, real encode work discarded
with zero trace.** `Invoke-VesEncodeAndValidate`'s size-guard/x265-
fallback flow (AV1 tried first; if it's more than `Av1MaxOvershootPct`
over the source size, x265 is tried; x265 must be no larger than the
source at all to be kept) had three silent-fallthrough exit points when
neither codec produced a keepable result and the source wasn't a "must-
eliminate" legacy container: no `Write-VesLog` call, no
`NeedsHumanReview`/`Reason` set, `$ok` just stayed `$false`. The
function's own log line (`Staging: moved finished output to
...X265-WIN.mkv`, an internal staging-completion message printed
regardless of whether the outer size check will ultimately keep or
discard the result) looked exactly like success right up until the point
nothing was left on disk but the original source. Confirmed via direct
`Get-ChildItem` on the real NAS path: only the source `.mp4`/`.srt`
remained for all 3 "failed" titles -- two real, multi-minute encode
attempts each, silently thrown away.

Fixed: a new `$humanReviewReason` variable, set with a specific message
at each of the three sites, feeding into the function's return object
(`NeedsHumanReview`/`Reason` fields, additive -- both existing call sites
already had `if ($r.NeedsHumanReview) { ... }` handling in place from
earlier this session's work on a different failure class, so this wires
into an already-proven mechanism rather than adding a new one).

**Regression caught by team review before it shipped.** All three
reviewers (Gemini, Codex, Cursor -- independent parallel review)
converged on the same finding: the first version of this fix set
`NeedsHumanReview` unconditionally on every one of the three
fallthrough sites, which meant an *ordinary, transient, retriable*
dual-encode failure (network blip, NAS hiccup, ffmpeg crash -- not a
size-guard rejection) now got durably blacklisted forever
(`Write-VesBadSourceFlag` + done-log `skip`) instead of just failing and
retrying on the next scan like this port's behavior before the size
guard existed at all -- a real regression in the fix meant to close a
different bug. Cursor caught a second, related defect: the `Reason`
string for a dual-*failure* case computed a nonsensical
`(-100% over)` (dividing by a `SizeBytes` of `0`, since neither encode
actually produced a valid result to measure). Fixed: the size-guard
`NeedsHumanReview` path now only fires when `$av1Result.Ok -and
$x265Result.Ok` are both genuinely true (both codecs produced a valid,
merely-oversized result -- the real Batman production case); a dual
*outright failure* now logs clearly but leaves `$ok = $false` with no
human-review flag, exactly matching this port's pre-size-guard retry
behavior. Also fixed along the way: the must-eliminate-format AV1-retry
path wasn't checking `$av1Retry.NeedsHumanReview` (a real but
low-probability gap, same class as the other two call sites which
already did), and the must-eliminate remux-floor-failure message
previously claimed "size guard" even on a path only reachable when AV1
never produced a valid oversized result to reject in the first place.

**Bug 2 -- `ffmpeg-logs` directory hits the NAS's broken-ACL-on-new-
directory bug (also confirmed in production).** Every single job in the
same 15-episode batch (not just the 3 failures) logged `Set-Content:
Access to the path '...\ffmpeg-logs\...stderr.log' is denied` for both
the main encode and remux stderr captures. Root cause: `New-Item
-ItemType Directory -Path $ErrorLogDir` creates this directory fresh on
first use, and this NAS gives freshly-created directories the same
broken default ACL already fixed for files via `Set-VesEveryoneReadWrite`
earlier this session (v5.1.0J) -- a gap a reviewer had explicitly flagged
as worth a separate follow-up at the time, now confirmed happening in
production and fixed. `VesTwoStageEncode.psm1` and
`VesLegacyFallback.psm1`'s must-eliminate remux floor both now call
`Set-VesEveryoneReadWrite` on `$ErrorLogDir` right after creating it,
**unconditionally on every call** (not gated on "did this call just
create it") -- deliberately, so a directory a *past* run already created
with the broken ACL self-heals too, not just ones created fresh this
run; team review confirmed this tradeoff (one cheap `icacls` spawn per
encode attempt vs. real encode runtime) is the right one. Non-fatal on
its own (12/15 jobs still succeeded despite every stderr write failing),
but meant stderr diagnostic logs were silently never captured on this
NAS -- a real gap if an encode ever fails with a genuine ffmpeg error
needing that log to diagnose.

**Bug found and fixed by team review, not in the original diff:**
`VesLegacyFallback.psm1` called the newly-added `Set-VesEveryoneReadWrite`
without importing `VesDoneLog.psm1` (the module it's defined in) --
masked by `convert.ps1`'s own top-level import order already loading
`VesDoneLog` first, but a real `CommandNotFoundException` (hard abort of
the remux floor, worse than the missing stderr log it was fixing) if this
module is ever loaded standalone or that import order changes. Codex
empirically reproduced the failure standalone before the fix, and
reproduced success after. Fixed with an explicit import, matching
`VesTwoStageEncode.psm1`'s own pattern.

Team-reviewed twice (Gemini/Codex/Cursor, independent parallel review):
once against the initial fix (all three independently found the same
regression), once more after the corrected version (not run again in
full -- the fix was narrow, targeted, and independently traced/verified
via logic walkthrough of both the original production scenario and the
regression scenario before shipping).

## v5.1.0K — 2026-08-06

RAM disk staging audit and fixes, prompted directly by user request now
that PRINCE/GruntBox2 no longer run WSL2 (removing the constraint that
originally motivated conservative sizing): "make use of as much memory
as possible to offset network/disk latency issues."

**Biggest finding**: none of the 3 live Windows fleet machines (PRINCE,
ELVIS, RANDYJ) had ever actually been using RAM-backed staging.
`convert.ps1`'s `-UseRamDisk` is an opt-in switch, and no launch
invocation across the whole session -- including every batch-test
Scheduled Task built this week -- ever passed it. All three had been
taking the full NAS network-write-path hit on every single output file
since Phase 5 onboarding. Fixed structurally, not just for this one
launch: `-UseRamDisk` is now on by default (mirrors bash's own
`CONVERT_NO_RAMDISK=false` default-on posture), with a new `-NoRamDisk`
opt-out following the same convention as the existing `-Pipeline`/
`-NoPipeline` pair. Verified via a real end-to-end test on PRINCE
(`New-VesRamDiskJob` create → write → `Remove-VesRamDiskJob` teardown,
all confirmed working) before trusting this dormant-until-now code path
in production.

**Sizing raised, both platforms**: `CONVERT_RAMDISK_PCT` (bash) and
`PercentOfAvailable` (`VesRamDisk.psm1`) both 40% → 50% of currently-
available memory. Windows' `MaxSizeBytes` hard cap also raised from
32GB to 256GB -- bash has no equivalent absolute cap, and 32GB was
silently clamping high-RAM machines (RANDYJ alone has 144GB, 133GB free
at time of writing) to well under half of what 50%-of-available would
otherwise allow.

**Real bug fixed, macOS-specific**: `_mem_available_bytes()`'s macOS
branch used only `vm_stat`'s "Pages free" count. macOS deliberately
keeps this near zero -- unlike Linux, which exposes a proper
`MemAvailable` figure (free + reclaimable cache/buffers), macOS favors
holding spare RAM as reclaimable "inactive"/"speculative" cache rather
than reporting it free. Confirmed in production: this starved
Crystalight/MARLONJ's RAM disk down to 1.5GB on a 64GB machine. Fixed
to include inactive + speculative pages (the same pages Activity
Monitor folds into its own "Available" figure, still excluding "active"
pages genuinely in use) -- verified against Crystalight's real `vm_stat`
output, giving ~40GB available (~20GB at the new 50%) instead of 1.5GB.

Linux fleet machines were not touched code-wise -- audited and found
already effectively RAM-backed via each distro's own `/tmp` or
`/dev/shm` tmpfs (discovered and used as-is by `ramdisk_discover()`
before `ramdisk_create()` would ever run), sized generously by the OS
default in every case checked (32-64GB tmpfs against 60-93GB total RAM
per machine) -- the `CONVERT_RAMDISK_PCT` bump still applies on any
machine where discovery finds nothing and falls through to creating one
itself.

## v5.1.0J — 2026-08-06

Real production failure on PRINCE mid-batch: `Superman S01E17`'s
low-quality flag write threw `UnauthorizedAccessException` while an
earlier episode's flag write (moments before, same run) succeeded --
traced to a NAS/SMB-specific bug already on record for this project:
freshly-created files on this NAS get a broken default ACL over SMB
(`Everyone: R`-only, not inheriting the parent folder's write grant), so
a *second* open (reopening an already-created file to append) is
unreliable, persistently not transiently. This is exactly what already
forced the done-log's 2026-08-02 redesign away from shared-file append
to one-file-per-entry -- `Write-VesLowQualityFlag`/`Write-VesBadSourceFlag`
(`windows/modules/VesValidation.psm1`) never got that same fix.

**Windows port, fixed:**
- `Write-VesLowQualityFlag`/`Write-VesBadSourceFlag`: ported to the same
  one-file-per-entry atomic-create pattern as `Add-VesDoneLogEntry` --
  each event is its own uniquely-named file (`.quality-flag`/
  `.bad-source-flag` extensions, chosen so `Import-VesDoneLog`'s `*.tsv`
  glob never picks them up) written directly into the show/title folder,
  never a fresh subdirectory (creating a *new* directory on this NAS has
  its own broken-ACL bug, already on record). This trades a single
  flat human-readable `bad_sources.txt`/`low_quality_review.txt` for
  scattered per-entry files -- reliability over the old format-parity
  convenience; `cat *.quality-flag`/`Get-Content *.quality-flag` recovers
  the same view either platform.
- New shared helper `Set-VesEveryoneReadWrite` (`VesDoneLog.psm1`): widens
  every newly-created sidecar file's ACL immediately after creation
  (`icacls ... /grant '*S-1-1-0:(M)'` -- the well-known SID for Everyone,
  not the literal localized name, which would silently no-op on non-English
  Windows) rather than trusting this NAS's default. Wired into all three
  one-file-per-entry writers (done-log, low-quality flag, bad-source flag).
- **Pre-existing bug, found via team review**: `convert.ps1` passed
  `$JobRoot` (the whole scan root) instead of each title's own folder to
  both flag writers at all 3 call sites -- in a real library-wide scan,
  every flagged episode across every show would land in one shared
  top-level directory instead of next to its title. Only looked correct
  during the PRINCE incident because that batch's `-SearchPath` happened
  to already be a single show folder. Fixed at all 3 call sites.
- **Same bug class, bigger blast radius**: pipeline mode's
  `pipeline-ready.txt` (`VesPipelineScan.psm1`) does the identical
  create-then-reopen-append for *every* discovered file (not just the
  rare flagged-episode case) and silently dropped items after 5 failed
  retries with zero logging -- and pipeline mode auto-activates for any
  UNC path, making this a real fleet-wide risk. Fixed the root cause
  (ACL-widen right after creation) and made exhausted retries loud.
  Redesigning the whole subsystem to one-file-per-entry would also
  require rewriting the consumer's byte-offset incremental reader --
  deferred as a larger follow-up, consistent with this module's own
  documented priority (throughput optimization, not correctness).
- `VesSubtitleFilter.psm1`'s `Write-VesStrippedSubtitleRecord`: same
  hardening applied ahead of need -- nothing currently wires
  `-StrippedSubtitlesLogPath` to a NAS path, but it would hit the exact
  same failure the moment it did.
- `FileStream` handle-leak fix (`try`/`finally`) in all one-file-per-entry
  writers: if `Write()` threw after `Open()` succeeded, the handle was
  never closed, leaving a partially-created sidecar locked until process
  exit.

**Bash, hardened:** the human-review logs
(`bad_sources.txt`/`low_quality_review.txt`/`corrupt_files.txt`/
`reconvert_files.txt`/`stripped_subtitles.txt`/`multipart_mismatch.txt`)
already avoid within-process reopen (a held FD opened once at job start),
but writes were never serialized against *other* fleet machines the way
`done_log_append` already is via the shared mutex -- two hosts flagging an
entry in the same show folder at the same moment could interleave or lose
an update on NFS (a different failure mode than Windows' SMB ACL bug: NFS
lacks atomic cross-client append, not a broken-ACL-on-create issue).
Low-probability (rare human-review events), but real -- all six writers
now acquire the existing `_shared_mutex_acquire`/`_shared_mutex_release`
lockdir around their write, matching `done_log_append`'s own convention.

Team-reviewed twice (Gemini/Codex/Cursor, independent parallel review):
once to find the above (all three converged independently on the JobRoot
bug and the pipeline-ready.txt gap), once more after implementing every
fix to confirm nothing new was introduced. The second pass earned its
keep: all three reviewers independently found a real bug in the first
fix for the JobRoot issue -- the disc-source branch used `$EncodeSource`
(the temporary extracted scratch file, deleted moments later) instead of
`$ProfileSource` (the logical disc path on the NAS), which would have
silently failed to write any low-quality flag for a disc source at all.
Fixed. Also fixed from that second pass: two more `FileStream`
handle-leak sites (`pipeline-ready.txt`'s append path; pre-existing ones
in `VesResumeState.psm1` and `VesSharedMutex.psm1`, unrelated to this
week's work but the same easy fix), the pipeline scan producer's
"queue exhausted" warning being emitted inside a background runspace
where `Stop-VesScanProducer` never actually surfaced it to the caller,
and a bash mutex-release-safety gap in the new `multipart_mismatch.txt`
locking (a failed write inside the critical section could exit under
`set -e` before the lock was released).

## v5.1.0I — 2026-08-06

Real bug found resuming the 27-file fleet production test: `-p` targeting
a real, existing file whose name contains literal `[`, `]`, `*`, or `?`
characters (e.g. a common release-group tag like
`Law.&.Order.5x06...[tvu.org.ru].avi`) was silently reinterpreted as
"directory + trailing name-glob" instead of a literal single-file target.
`split_path_trailing_glob()`'s glob-metacharacter heuristic (`case "$path"
in *[\*\?\[]*)`) can't distinguish an actual unexpanded shell glob from a
real filename that just happens to contain those characters. Fixed by
checking `[ -f "$path" ]` first -- a literal existing file always wins
over the heuristic now, matching the same "does it literally exist"
precedence `SINGLE_FILE_MODE` detection already uses a few lines later.
Verified both directions: the real production file that surfaced this now
correctly resolves as a single-file target with no name-glob; a genuine
`-p .../A*` glob-pattern invocation (which never exists as a literal path)
is unaffected.

## v5.1.0H — 2026-08-06

E2E confidence review (Gemini, Codex, Cursor, run independently in
parallel) of v5.1.0G found two critical bugs in the new size-guard/x265
fallback and derived-output recognition, both confirmed independently by
multiple reviewers, plus several smaller real issues.

- **Critical, data-loss: `-InPlace` + oversized/failed AV1 could delete
  the only remaining copy of a title.** `-InPlace` makes `$Destination`
  literally equal `$EncodeSource` for a source already named `*.mkv`. By
  the time a successful AV1 attempt returns from
  `Invoke-VesCodecEncodeAttempt`, the staging finalize has already
  atomically replaced the source with the new encode (the whole point of
  `-InPlace`). The v5.1.0G size-guard fallback then unconditionally
  deleted `$Destination` before trying x265 -- if x265 also failed, the
  title was gone permanently. Fixed by detecting the InPlace-collision
  case up front and skipping the size-guard/x265-fallback dance entirely
  for it, exactly matching this port's pre-v5.1.0G `-InPlace` behavior
  (no size guard existed then either -- no new risk, just none of the
  new benefit for this one mode). Empirically verified on PRINCE: a
  254%-oversized AV1 result is now kept without ever reaching the
  fallback/deletion code path.
- **Critical: the new x265 fallback's `Title.X265-WIN.mkv` naming wasn't
  recognized as a derived output anywhere.** Same cascade-risk class as
  the v5.1.0F `.AV1-WIN.mkv` bug, for the newer x265 fallback path this
  same release introduced. Fixed in all five places that needed it:
  bash's `is_derived_output` and a new `windows_x265_output_path` wired
  into `inspect_existing_outputs_for_queue`; Windows's
  `Test-VesIsDerivedOutput`, `Find-VesExistingValidOutput`, and the
  pipeline-mode `ShouldQueue` scriptblock. Empirically verified on
  PRINCE.
- Hardened `derived_output_codec_claim_matches` (bash) to recognize
  `.AV1-WIN.mkv`/`.X265-WIN.mkv` explicitly instead of falling through to
  the permissive bare-`.mkv` case -- closes a real (if narrow) gap where
  a cross-platform output candidate had no codec-claim proof at all
  before a deletion decision.
- `Find-VesExistingValidOutput`: candidate-vs-source comparison now
  normalizes full paths instead of a raw string `-eq` -- a user-typed
  `-SearchPath` with forward slashes could otherwise make a candidate
  resolve to the source itself, and the function would ffprobe the
  source against itself and return it as an "existing valid output,"
  silently skipping the encode.
- Must-eliminate AV1 retry: now cleans up an invalid retry output instead
  of leaving a canonical-looking but unvalidated `Title.AV1-WIN.mkv` for
  a future scan to mistake for a finished title.
- Dolby Vision Profile 5 on the disc-source path: `Invoke-VesProcessDiskSource`'s
  `EncodeFunction` contract only returns a bool, so `NeedsHumanReview`
  was silently dropped for disc sources -- a DoVi P5 disc extraction
  without libplacebo failed every scan forever instead of being durably
  parked like the non-disc path already was. Fixed via a script-scoped
  variable smuggled out of the closure (chosen over changing the shared
  `EncodeFunction` contract, which every other caller also depends on).

**Reviewed and confirmed not real issues:** a reviewer claimed
`[Nullable[double]]` isn't valid PowerShell type-accelerator syntax --
already empirically verified working correctly via direct testing
earlier this same review cycle, both in isolation and through the actual
shipped code path; not changed.

**Logged as real but lower-priority, not fixed this pass:** a
theoretical race where `inspect_existing_outputs_for_queue`'s pipeline
scan could observe a mid-write cross-platform output over a slow SMB
link (largely mitigated already by the existing atomic-rename staging
pattern on both platforms, but not independently re-verified for this
specific interaction); `Find-VesExistingValidOutput` running before
`Enter-VesTitleLock` in `Invoke-VesFileJob` (same mitigation reasoning);
a pre-existing (not introduced by this release) partial-line read risk
in `VesPipelineScan.psm1`'s ready-queue consumer over a slow/interrupted
SMB write.

## v5.1.0G — 2026-08-06

Remediation of the four remaining gaps flagged by the v5.1.0D/E team
review (cross-OS lock/done-log non-interop, no Windows size-guard/x265
fallback, Dolby Vision Profile 5 not parked for review on Windows,
`Write-VesLowQualityFlag` lacking bash's symlink-hardened log pattern),
per explicit direction that bash is this project's master feature set
and Windows should close the gap toward it wherever practical.

**Cross-platform title-lock claim peek** (`modules/ves-title-lock.sh`,
`windows/modules/VesTitleLock.psm1`): bash and Windows use different
lock primitives for the same purpose (bash: an atomically-`mkdir`'d
directory; Windows: an atomically-`CreateNew`'d file — chosen there
specifically because this NAS gives freshly-Windows-created directories
a broken ACL). Neither recognized the other's lock at all before this,
so a bash and a Windows machine sharing a library could both claim and
encode the same title simultaneously. Fixed with a read-only
existence+age peek on both sides — each platform computes the other's
expected lock path for the same source (verified byte-identical against
real filenames, including the `.AV1.mkv`/`.AV1-WIN.mkv` derived-output
case) and skips if a fresh one is found. Never touches or reclaims the
other platform's lock, so a bug here can only cause an over-cautious
skip, never lock corruption.

**Cross-platform existing-output recognition**: the lock peek only
prevents a *simultaneous* collision — bash's own done-log had no record
of a Windows-only completion (or vice versa), so sequential duplicate
work across platforms was still unbounded. `inspect_existing_outputs_for_queue`
(`modules/ves-profile-decision.sh`) now also checks for a valid
`Title.AV1-WIN.mkv` before queuing a re-encode, reusing the exact same
validate-then-trust-or-reject pattern already used for its own AV1/x265
outputs. Windows gained an equivalent pre-check it never had at all
(`Find-VesExistingValidOutput`, `windows/modules/VesValidation.psm1`) —
deliberately safer than bash's version: it never deletes a candidate
that fails validation, only skips silently and proceeds to a normal
encode, since this port has no VES-tag-reading ownership proof the way
bash's layered mtime/codec-claim guards do.

**Dolby Vision Profile 5 handling on Windows**: two real, connected bugs.
(1) `windows/convert.ps1` never probed for libplacebo at all — every DoVi
P5 source was routed to "needs human review" even on ffmpeg builds
(confirmed on PRINCE) that actually support the conversion. Fixed with a
new `Test-VesFfmpegHasLibPlacebo` capability probe (`VesHwDetect.psm1`),
mirroring bash's own `FF_HAS_LIBPLACEBO` detection. (2) The one existing
caller of `Build-VesFfmpegVideoArgs` never checked its documented `$null`
return contract at all -- a DoVi P5 source without libplacebo (or,
discovered via direct testing, an unrecognized `-ForceProfile` value)
silently fell through into the encode pipeline with null video args.
Fixed by checking the return value, and by verifying the actual DoVi
condition independently rather than assuming every `$null` means DoVi P5
(a real second bug caught via testing: `Build-VesFfmpegVideoArgs` returns
`$null` for two other unrelated reasons too, and the first draft of this
fix mis-attributed all of them). A genuine DoVi P5-without-libplacebo
source is now durably parked via a new `Write-VesBadSourceFlag`
(`windows/modules/VesValidation.psm1`) -- same `bad_sources.txt` name and
3-field TSV shape as bash's `flag_bad_source_for_human`, reusing the
existing done-log `'skip'` status so future scans stop retrying a job
that will always fail identically.

**Windows size-guard + x265 fallback**: this port previously kept ANY
duration/structure-valid AV1 regardless of size -- a real, silent policy
divergence from bash on a shared library. `Invoke-VesEncodeAndValidate`
was refactored into a per-codec `Invoke-VesCodecEncodeAttempt` helper
(`Build-VesFfmpegVideoArgs` was already fully codec-parameterized before
this -- only the orchestration layer needed a second codepath, not the
encode pipeline itself) plus a new size-guard check mirroring bash's
`size_keep_policy_av1` (`AV1_MAX_OVERSHOOT_PCT=20` there too, now a new
`-Av1MaxOvershootPct` param here). An oversized or failed AV1 now falls
back to a real software x265 encode (`Title.X265-WIN.mkv`), keeping
whichever valid candidate is actually smaller. Deliberately scoped
narrower than bash's full behavior: no upscale-tiered overshoot limit and
no must-eliminate stash/tie-break bookkeeping -- the must-eliminate case
is handled by simply re-trying AV1 if x265 doesn't beat it, rather than
bash's stash-and-compare mechanism. No GPU bake-off either (NVENC/QSV/
VideoToolbox/AMD VCE) -- this port's AV1 path is software-only today too,
so a software-only x265 fallback matches its current scope. Empirically
verified end-to-end on PRINCE across all three outcomes (AV1 kept
normally; AV1 rejected → x265 fallback triggers and gets kept; both
rejected → guardrail correctly leaves the original untouched) -- caught
and fixed two more real bugs in the process: a PowerShell `-replace`
operator-precedence bug that silently no-op'd the x265 output-filename
construction, and the DoVi-null-misattribution bug described above (first
surfaced by this testing, not the DoVi work itself).

**`Write-VesLowQualityFlag` log hardening**: now refuses to append
through a symlink at the log path, mirroring bash's
`_neutralize_symlink_sidecar_path`. Not a full match for bash's
hardening (bash opens its FD once at job start and holds it for the
run's lifetime; this re-checks on every call since there's no long-lived
handle plumbed through here yet) but a real improvement over no check at
all.

## v5.1.0F — 2026-08-05

Follow-up triage of the remaining gaps Cursor surfaced during the v5.1.0D/E
team review that hadn't yet been addressed. Two real, severe bugs fixed;
one gap reviewed and confirmed safe as-is; the rest assessed as genuine
but out of scope for a quick fix (see "Known gaps" below).

- **`windows/convert.ps1` — main convert-mode scan (both batch and
  pipeline) never filtered out this port's own prior outputs.**
  `Test-VesIsDerivedOutput` existed but was only ever called from the
  organize phase — the actual file-collection loops that feed the
  encode queue had zero derived-output filtering. Every full-library
  rescan was re-queuing "Title.AV1-WIN.mkv" as if it were a fresh
  unprocessed source, encoding it into "Title.AV1-WIN.AV1-WIN.mkv", and
  so on indefinitely on every subsequent run — real, ongoing data/compute
  waste with no bound. Fixed by filtering both the batch-mode
  `Get-ChildItem` loop and the pipeline-mode background scan producer
  (the latter needed a self-contained scriptblock, since the producer
  runs in an isolated runspace with no access to imported modules).
  `Test-VesIsDerivedOutput` itself also gained a `-OutputSuffix`
  parameter (defaulting to '.AV1-WIN', matching `convert.ps1`'s own
  default) — neither of its two historical bash-style patterns ever
  matched this port's actual default output filename.
- **`modules/ves-profile-decision.sh` — bash's `is_derived_output` had
  no knowledge of the Windows port's `.AV1-WIN.mkv` convention either.**
  Fleet machines share the same NAS-mounted library trees, so a bash
  machine rescanning a folder a Windows machine already processed would
  treat that output as an unprocessed source too. Fixed by adding the
  `.AV1-WIN.mkv` pattern to bash's own check.
- **`windows/modules/VesValidation.psm1` — `Test-VesDurationsMatch`'s
  null-ambiguity guard was dead code.** A plain `[double]` parameter
  coerces a `$null` argument to `0.0` during PowerShell's own parameter
  binding, before the function body's `$null -eq $DurationA` check ever
  runs — confirmed via direct testing. Two real callers (`convert.ps1`,
  `VesLegacyFallback.psm1`) pass both durations straight through with no
  null-check of their own first, so if both ffprobe duration probes
  failed (e.g. a stalled NAS), this was scoring "0.0 vs 0.0, matched"
  instead of "can't confirm" — risking a done-logged file that was never
  actually duration-verified. Fixed by changing both parameters to
  `[Nullable[double]]`, which preserves `$null` through binding; the
  existing body logic was already correct once given a real `$null`.
  (`VesOrphanReaper.psm1`'s own caller already null-checked before
  calling this function, so it was unaffected either way.)

**Reviewed and confirmed safe as-is** (not changed): Windows leaving a
confirmed-invalid output in place instead of deleting it (bash's
`remove_output_only` deletes on confirmed failure) — traced through and
confirmed this does NOT block retries, since Windows keys "already done"
off the done-log, not output-file-existence, and every ffmpeg encode
invocation already uses `-y` to cleanly overwrite a stale file on the
next attempt. A real gap from bash's behavior, but cosmetic (a bad file
visible in the library between runs), not a correctness or retry-blocking
issue — matches this project's "ambiguous is not proof of anything" fail-open
philosophy already used everywhere else in the port. Also confirmed the
mkvalidator-timeout-as-"structure OK" behavior Cursor flagged is the same
deliberate design, not a bug (`Test-VesMkvStructureValid` returning `$null`
on ambiguity, and callers only failing on a confirmed `$false`, mirrors
`Get-VesMediaDurationSeconds`'s own documented contract).

**Known gaps, not addressed this pass** (real, but each is a bigger design
question rather than a quick fix — flagged for a future dedicated pass):
cross-OS title-lock/done-log non-interop (bash and Windows use different
lock-file and done-log conventions with no shared state, so the two
platform families can't see each other's in-progress or completed claims
on a shared library); Windows has no size-guard/x265 bake-off fallback
(keeps any duration/structure-valid AV1 regardless of size, where bash
can reject an oversized AV1 and fall back to x265); Dolby Vision Profile 5
without libplacebo isn't parked for human review on Windows the way bash's
`flag_bad_source_for_human` does (the job just fails and retries forever
instead); `Write-VesLowQualityFlag` uses plain `Add-Content` without the
symlink-neutralize/open-FD hardening bash's sidecar logs have.

## v5.1.0E — 2026-08-05

Team review (Gemini, Codex, Cursor, run independently in parallel) of
v5.1.0D found the Windows side of the new low-quality-VMAF feature was
completely inert in production, plus two smaller real bugs:

- **`windows/modules/VesVmafCrfSearch.psm1` — `Get-VesFinalVmaf` never
  actually measured anything on Windows.** All three reviewers
  independently caught it: ffmpeg's filter-option parser splits on `:`,
  so a raw Windows temp path (`C:\Users\...\file.json`) passed as
  `log_path=` broke at the drive letter, every sample silently failed,
  and the function always returned `$null` — the entire feature was a
  no-op on all 3 Windows fleet machines since the moment it shipped.
  Colon-escaping (`C\:/...`) was tried first and *also* failed against a
  real ffmpeg N-125907 build (confirmed via a live test on PRINCE, not
  just inferred from docs). Fixed by passing a bare relative filename
  with the ffmpeg process's working directory set to the temp folder —
  sidesteps the escaping question entirely, verified end-to-end on
  PRINCE with a real encode/re-encode pair before redeploying fleet-wide.
- **`windows/convert.ps1` — missing `-TargetHeight` passthrough.** The
  already-resolved `$upscaleTarget` wasn't being passed to
  `Get-VesFinalVmaf`, so an upscaled output would've been compared
  against its source at mismatched resolutions once the above fix
  landed. Fixed by threading `$upscaleTarget` through.
- **`windows/modules/VesVmafCrfSearch.psm1` — duration-probe subprocess
  hygiene.** The new duration probe in `Get-VesFinalVmaf` didn't drain
  stderr or dispose the process, unlike the sibling
  `Invoke-VesProbeFfmpegRun` it should have matched — a chatty/stalling
  ffprobe could fill the stderr pipe and sit until the 30s timeout.
  Fixed to match the hardened pattern.
- **`modules/ves-validation.sh` — numeric-format guard on bash's
  threshold check.** `awk`'s `v + 0` coerces any non-numeric string
  (e.g. a stray `"nan"`) to `0`, which would misread as "far below
  floor" instead of "VMAF unavailable." Low severity — `measure_final_vmaf`
  normally only ever prints a plain `%.1f` or fails empty — but cheap to
  close, so a numeric-format check was added before the comparison.

## v5.1.0D — 2026-08-05

New feature, both platforms: a kept output whose final measured VMAF lands
below a 85.00 floor (`LOW_QUALITY_VMAF_THRESHOLD`) is now flagged for human
review instead of silently treated as a normal successful pass — matters
most for must-eliminate legacy sources (avi/ogm/mpg/rmvb/etc.) where the
existing format-elimination override already keeps a lower-quality AV1/x265
output rather than leaving the undesirable container in place.

Bash (`ves-validation.sh`): `write_ves_processed_tag()` checks the already-
measured final VMAF and, below the floor, stamps a visible marker into the
file's own tag and calls the new `flag_low_quality_output_for_human()`,
which appends to a new `low_quality_review.txt` sidecar log
(`ves-resume-state.sh`/`ves-config.sh` wire up its FD same as
`bad_sources.txt`). Deliberately log-only, unlike `flag_bad_source_for_human`
— the output stays at its canonical derived path; moving it would make
`inspect_existing_outputs_for_queue`'s "done" detection blind to it and
cause an endless re-encode-to-the-same-VMAF loop on every future scan.

Windows (`convert.ps1`): new `Get-VesFinalVmaf` (`VesVmafCrfSearch.psm1`,
libvmaf sampled comparison, same 3×20s sampling as bash's
`measure_final_vmaf` but parses the JSON via PowerShell's built-in
`ConvertFrom-Json` instead of shelling out to python3 — no new dependency
needed) and `Write-VesLowQualityFlag` (`VesValidation.psm1`, same TSV shape
as bash's log so both platforms produce one comparable record), wired into
`Invoke-VesEncodeAndValidate` for both the real-encode and must-eliminate
remux-floor success paths. This is new infrastructure on the Windows side,
not a port — the port had no post-encode quality measurement, tag, or
Deferred/-style human-review mechanism at all before this.

## v5.1.0C — 2026-08-04

Fixes a real, pre-existing bug found during a broader post-modularization
functionality/regression pass: `run_tracked_encoder()`'s periodic
in-progress-flag heartbeat subshell (keeps a long encode's lock from being
wrongly reclaimed as abandoned after 2h by another fleet machine sharing
the same NAS) was leaking on SIGINT/SIGTERM. Confirmed byte-identical to
the pre-modularization code — not introduced by the refactor.

Root cause: on normal completion, `run_tracked_encoder` explicitly kills
the heartbeat right after its own `wait` returns, but on an interrupt the
trap handler (`resume_on_signal` → `kill_active_encoder`) unwinds the whole
script via `exit 130` before `run_tracked_encoder` ever resumes past its
`wait` line — so the heartbeat was never being cleaned up, and was observed
via real-content testing to survive for up to 300 real seconds after the
parent script had already exited.

Took three iterations to actually fix, each verified empirically (not by
inspection alone) before moving to the next:
- **Draft 1** (thread the heartbeat's PID through a new global,
  `ACTIVE_ENCODER_HEARTBEAT_PID`, so `kill_active_encoder` can also kill
  it): failed a real interrupt test. A plain `kill` only terminates the
  bash subshell wrapper, not the `sleep 300` grandchild it's currently
  blocked in — background jobs in a non-interactive script share the
  script's own process group rather than getting their own, so the dying
  subshell doesn't take its foreground child down with it; the sleep is
  simply orphaned and keeps running out its own timer.
- **Draft 2** (add `pkill -P` to also kill the child): also failed, for a
  subtly different reason — by the time `pkill -P` ran, the parent was
  already dead and the kernel had already reparented the child, so `-P`
  no longer matched anything. A genuine race, confirmed via a manual
  isolated repro.
- **Draft 3** (snapshot the child PID with `pgrep -P` *before* killing the
  parent, then kill both): verified across 5 repeated real interrupt
  trials with 1-second-granularity process-tree monitoring — heartbeat
  present at the moment of interrupt, gone within 1 second, every time.

Team review of Draft 3 caught something worse than the leak it fixed: a
bare `hb_children="$(pgrep -P "$hb_pid" 2>/dev/null)"` assignment
propagates `pgrep`'s exit status, and under this script's global
`set -euo pipefail`, `pgrep` finding zero children (the ordinary case) would
abort the *entire* SIGINT/SIGTERM trap handler right there — skipping every
cleanup step after it, a genuinely worse failure mode than the original
bug. Confirmed via direct empirical repro. Fixed by guarding every
command in the new `_kill_encoder_heartbeat()` helper with `|| true`
(including a `command -v pgrep` existence check, so the function degrades
to the original bounded-leak behavior rather than crashing outright on a
platform lacking `pgrep`), then re-verified: the `set -e` abort scenario
now survives, and all 5 real interrupt trials still pass with the trap
handler's own final cleanup log line printing every time (confirming it
runs to completion, not cut short).

Two rounds of team review total. Final version: no blocking findings from
any of the three tools. A few narrow, already-bounded residual risks
(a tiny window where a brand-new heartbeat sleep could start between the
`pgrep` snapshot and the parent kill; the same PID-assignment race pattern
this codebase already accepts elsewhere for `ACTIVE_ENCODER_PID` itself)
were assessed and left as documented, not engineered away — consistent
with existing patterns in this codebase and proportionate to the actual
risk (worst case still bounded to the original leak's own self-healing
window, not unbounded).

## v5.1.0B — 2026-08-04

Fixes a real, pre-existing bug found during a full functionality/regression
pass on the newly-modularized v5.1.0A: multi-part movies named
"Title - Part 1.mkv" / "Part 2.mkv" (or Pt/CD/Disc N, in any separator
form) were never being merged by the multipart-merge feature, despite it
existing specifically for this case. Confirmed byte-identical to the
pre-modularization code — not introduced by that refactor, just surfaced by
testing it against real content for the first time with this exact naming
pattern.

Two-part root cause: (1) `is_tv_episode()`'s generic trailing-number
catch-all rules (meant for sequentially-numbered TV libraries, e.g.
"Show - 05") also matched the trailing part number in "Title - Part 1",
misclassifying the movie as a TV episode — which made
`is_tv_show_directory()` flag the whole containing folder as a TV show
directory from a single false-positive file, which made
`detect_multipart_groups()` skip it entirely; (2) separately, even after
fixing (1), the organize phase was still splitting the two parts into two
different per-title folders before the convert phase's multipart detection
ever got a chance to see them as siblings, since `canonical_organize_title()`
doesn't strip the part marker.

Fixed in `ves-season-retry.sh` (`is_tv_episode()`) and `ves-organize.sh`
(`needs_flat_organize()`): both now exempt filenames matching a new
`MULTIPART_PART_REGEX` global (`ves-config.sh`) from being treated as TV
content. Two existing protections keep genuine multi-part TV episodes safe
from this change: an explicit season/episode marker anywhere in the name is
still caught by the more specific rules checked first, and
`is_tv_show_directory()`'s separate `is_tv_library_path()` fallback still
flags any 2+-video folder under a real `Television/` path regardless of
individual filenames — this project has a documented past incident from
the *opposite* direction ("Multipart merge ate two-part TV episodes"), and
this fix is deliberately scoped not to reopen it.

First-round team review caught a real gap in the first draft of this fix
(missed hyphen-joined forms like "Title-Part-1"/"Title CD-1", which hit an
earlier, differently-guarded generic rule than the space-separated form)
and a minor efficiency issue (forking a subshell per file for a static
regex string in what can be a hot loop over large libraries). Both fixed
in a follow-up pass: the regex now lives as a real global
(`MULTIPART_PART_REGEX`) rather than a function call, and a single upfront
exemption check guards both risky rules together. Re-reviewed clean by all
three tools.

Verified end-to-end on real content: two real movie clips named with every
supported separator form (space, hyphen, dot, underscore, glued) now
genuinely merge and encode correctly (confirmed: correct summed duration,
mkvalidator clean, full clean decode); a real 2-part TV episode with an
explicit S01E05 marker and a real markerless 2-part TV episode under a
`Television/` path both confirmed to still NOT trigger multipart merge,
via both a full pipeline run and direct unit-level calls. 18 unit-level
classification cases (7 multipart-movie forms, 4 genuine-TV forms, plus
`needs_flat_organize` cases) all pass.

## v5.1.0A — 2026-08-04

Structural rewrite of the bash/macOS fleet script: the 15,136-line monolith
(447 functions, zero module boundaries) is now `convert-v5.1.0A.sh` (2,396
lines — orchestration glue, `main()`, and 7 core logging primitives only)
sourcing 30 files under `modules/ves-*.sh`, mirroring the module boundaries
the Windows PowerShell port already proved out in production (ELVIS/PRINCE/
GruntBox2). Zero intended behavior change — this is a relocation, not a
rewrite, per this project's own "don't combine the file-move with logic
cleanup" convention. Mid version component bumped (not just Minor/phase)
to mark the new architecture line, per this project's versioning scheme.

Extraction ran in 3 risk-ordered phases (low-coupling utilities first,
then medium-coupling feature modules, then the highest-coupling
state-entangled modules: CIFS mounting, resume-state, done-log, orphan
reaper, stats-log, staging, pipeline-scan), each gated on a real functional
encode test plus a Gemini/Codex/Cursor team review before the next phase
started, per the approved plan.

First extraction attempt used a naive brace counter
(`line.count('{') - line.count('}')`) and it silently corrupted the file —
mis-detecting function boundaries on constructs like `${#arr[@]}`,
`[0-9]{1,2}` regex quantifiers inside `[[ =~ ]]`, and `10#${VAR}`
forced-base arithmetic (where the naive counter treated `#` as a comment
start). Caught before it reached any module content: rebuilt the extractor
as a real stack-based lexer (tracks squote/dquote/`$()`/subshell-parens/
`${}`-parameter-expansion/`[[ ]]`-conditionals as distinct nesting
contexts) and re-verified it against all 447 functions in the file before
trusting it again — zero span overlaps, and a byte-for-byte body diff
against git HEAD for every single function showed zero mismatches.

Extended the fleet's existing single-file rsync-daemon deploy mechanism
(Phase 0, prerequisite to any extraction) to push a directory tree
(orchestrator + `modules/*.sh`) atomically: client stages + checksums every
`ves-*.sh` file alongside the orchestrator, server validates the complete
set (filename pattern, sha256, `bash -n`) before publishing anything, then
atomically swaps a `modules` symlink to a version-stamped directory — never
a per-file overwrite, so a fleet machine can never be caught sourcing an
orchestrator from version N against modules from version N-1 mid-deploy.
Found and fixed two real cross-platform bugs during Phase 0 testing (not
by review — by direct SSH testing on Crystalight): `mv -T` doesn't exist on
macOS's BSD `mv` at all, and even bare `mv -f` onto an existing
symlink-to-directory follows the symlink and moves the source INTO it
rather than replacing the link (fixed with `ln -sfn`, `-n` for
no-dereference); and `local -n` bash namerefs require bash 4.3+, breaking
on macOS's stock bash 3.2 (client-side deploy script hardened to avoid
them).

Team review across all three phases found one real production-risk bug
(not a relocation bug — a design gap in the new scaffolding itself): the
module-sourcing block silently continued if `modules/` was missing,
meaning a bad/partial deploy would look healthy on `--help`/`--check-tools`
and only crash confusingly deep into a real run. Now hard-fails at startup
with a clear diagnostic if `modules/ves-config.sh` isn't found. Also fixed:
a duplicated `set -euo pipefail`/script-path scaffolding artifact from the
config-block extraction script (behavior-neutral, but sloppy), several
now-orphaned section-banner comments left behind when their functions
moved out from under them, and one stale cross-module comment reference.

One pre-existing fragility surfaced (not introduced by this refactor —
confirmed byte-identical to HEAD, already documented in its own code
comment): `try_fast_stream_copy_disc_extraction`'s cleanup trap
(`trap ... RETURN`) can fire earlier than the function's own return if a
helper it calls returns first, since bash's RETURN trap is a single global
table, not function-scoped. Traced through and confirmed benign in the
current code (the local raw disc copy it cleans up isn't referenced again
after the point it actually fires) but is a landmine for future edits.
Deliberately NOT fixed in this pass — fixing it means a real logic change,
out of scope for a "pure move, zero behavior change" phase. Flagged as a
follow-up hardening item.

Also deliberately deferred, per the same scoping discipline: `ves-detached-
exec.sh`, a planned DRY-up of `convert_scan_producer` and
`run_tracked_encoder`/`kill_active_encoder`'s near-duplicate ad hoc
background-job implementations — a real logic change, not a pure move.

Verified after every phase: `bash -n` on the orchestrator and every
module; a full function-inventory diff against git HEAD (all 447 functions
present exactly once, zero missing/duplicated); a byte-for-byte function-
body diff against HEAD (zero mismatches, all 3 phases); and a real encode
through the full pipeline compared against the pre-refactor monolith on
the same synthetic source — byte-identical output file, matching
ffprobe-reported codec/resolution/duration, matching done-log entries,
with only expected non-determinism (random tmpdir suffix, PIDs, encode
timing) in the logs.

## v5.0.33U — 2026-08-04

Found and fixed a real performance regression in v5.0.33T's fast stream-copy
disc extraction within hours of that version reaching the fleet: the fast
path worked exactly as designed and measured (~45s) when validated against a
locally-staged copy of a disc, but real fleet usage always sources discs from
the NAS over the network -- and ffmpeg's libbluray-based `bluray:` protocol
does many small seeky reads for BD navigation structures, which is
catastrophically slow over network latency (~0.27MB/s observed against a
real NAS-hosted ISO -- 16+ hours for a typical disc, actually slower than
the x264 method this feature exists to replace). A plain sequential file
copy of the exact same network ISO ran at normal throughput, confirming the
bottleneck is libbluray's own read pattern, not the network link.

Fix: `stage_disc_source_local()` (bash) / `Copy-VesDiscSourceLocal`
(PowerShell) copies the disc source (`.iso` file or BDMV directory tree) to
local scratch first via a plain bulk copy (`cp -a` / `robocopy.exe`), THEN
the already-proven-fast libbluray stream-copy runs against the local copy.
Total wall time for a real disc is now a few minutes (staging copy + ~45s
local stream-copy) rather than 45 seconds flat, but still a dramatic win
over the original 12+ hour x264 path -- not unsafe as shipped in 33T (the
fast path's own timeout still falls back correctly), just wasteful (~10
minutes burned before falling back on every real disc job).

Caught a genuine bug of my own while implementing this, not by the delta
review: bash's `trap ... RETURN` is a single GLOBAL trap table, not
function-scoped, despite reading like it should be -- confirmed empirically
after two independent AI reviewers gave contradictory answers on this exact
question. Left unguarded, the cleanup trap for the local raw disc copy would
also have fired on the NEXT function return anywhere in the script,
evaluating whatever `$local_src` happened to be in scope at that later
point. Fixed by having the trap unset itself (`trap - RETURN`) as its own
last action.

Also fixed from the delta review (Gemini/Codex/Cursor): the local-staging
copy's timeout was bumped from 3600s to 10800s on both platforms (all three
reviewers independently flagged 3600s as tight enough to false-fail a
genuinely healthy but slower network link, silently defeating the whole
fix by falling back to the 12+ hour path); Windows' robocopy exit-code
check now also rejects negative exit codes explicitly, not just `>= 8`;
the local raw copy's cleanup on Windows now retries briefly rather than a
single silent-failure `Remove-Item`, since a disc-sized (tens of GB) leak
from one missed delete is a real cost; and the local source path is
defensively trimmed of a trailing backslash before being interpolated into
ffmpeg/ffprobe's `bluray:` argument (a known Windows command-line escaping
hazard, not confirmed reachable in practice but cheap to close off).

`bash -n` passes; the PowerShell module parses and imports cleanly. Verified
end-to-end against the real Blu-ray title used throughout this investigation
(`The Lazarus Effect (2015)`, 83.5 minutes) via ELVIS's actual `convert.ps1`
pipeline, sourced from the real NAS path this time (not a local copy, which
is what let 33T's regression slip through validation in the first place):
"Fast stream-copy extraction OK", pipeline proceeded cleanly into VMAF/AV1
encoding. Scan + local staging copy of the 21.5GB source + local stream-copy
completed in ~16.5 minutes total -- still a dramatic win over the original
12+ hour x264 path, now genuinely proven against real network-hosted
content rather than a local copy.

## v5.0.33T — 2026-08-04

Replaced disc-title extraction's expensive lossless workaround with a genuine
zero-recompression stream-copy, on both bash and the Windows PowerShell port.
`handbrake_extract_disc_title_lossless()` previously used HandBrakeCLI's
`-e x264 -q 0` (near-lossless re-encode, since HandBrake has no true video
passthrough) as its only extraction path -- discovered during a live ELVIS
disc-source test to take 12+ hours and produce output LARGER than the source
disc for an 83.5-minute movie. ffmpeg (built with `--enable-libbluray`) can
open a disc source directly via the `bluray:` protocol -- no OS-level mount
needed, works against a raw `.iso` or a BDMV directory -- and do a genuine
`-c copy` stream-copy: byte-identical video, full DTS-HD MA audio preserved
(verified via `profile=` on the copied streams, not just the backward-
compatible core), in ~45 seconds against the same real title.

New `try_fast_stream_copy_disc_extraction()` (bash) /
`Invoke-VesFastStreamCopyDiscExtraction` (PowerShell) is tried first;
`handbrake_extract_disc_title_lossless()` falls back to the original x264
-q 0 path unconditionally whenever the fast path can't confidently identify
the correct title. Safety gates, hardened through a 3-way independent
review (Gemini/Codex/Cursor, all three converged on the same core issues):

- **Duration-uniqueness, not just duration-match.** A duration match alone
  can't distinguish two full-length playlists of near-identical runtime on
  playlist-obfuscated/multi-angle discs. `select_dominant_disk_title()` /
  `Select-VesDominantDiskTitle` now checks every title on the disc and
  refuses the fast path outright if another title's duration falls within
  tolerance of the selected one. This merged what used to be two separate
  HandBrake scans (`--main-feature` then a full scan) into one, since a
  full scan's own text already carries the "+ Main Feature" flag when one
  exists -- also fixes a real performance redundancy the review caught.
- **Fail closed on unprobeable output, not fail open.** The original draft
  of the post-copy duration re-check treated "ffprobe couldn't determine
  the output's duration" as "trust it" instead of "reject it" -- exactly
  backwards. All three reviewers independently flagged this; fixed on both
  platforms to discard and fall back whenever the output duration can't be
  positively confirmed.
- PowerShell-specific fixes found in the same review: the disc-extraction-
  target collision check used `-PathType Leaf`, silently letting a same-
  named directory through; the free-space check on a UNC/network scratch
  path read `$null.Free`, which PowerShell coerces to 0 in a numeric
  comparison, so the check silently failed closed on every disc whenever
  the scratch dir lived on a network share.
- A genuine subshell-scoping bug caught during implementation, not by the
  external review: bash's `$(...)` forks a subshell, so an early draft that
  tried to communicate the duration-uniqueness result via a plain global
  variable set inside `select_dominant_disk_title()` would never have
  reached the caller (every call site invokes it via command substitution).
  Fixed by encoding the flag into the function's own colon-delimited return
  value instead.

Verified end-to-end against a real Blu-ray title (`The Lazarus Effect
(2015)`, 83.5 minutes) via ELVIS's actual `convert.ps1` pipeline, not a
standalone script. `bash -n` passes; the PowerShell module parses and
imports cleanly.

## v5.0.33S — 2026-08-02

Added optional Telegram job-completion notifications, requested after a
comparison against Tdarr surfaced remote-visibility as the one genuinely
useful gap in this project's design (everything else Tdarr does
differently is either already covered by this project's per-title VMAF
targeting and safety-first architecture, or would require the kind of
UI/plugin-runtime re-engineering explicitly not wanted).

`notify_telegram()` sends one message per job (success or failure),
tagged with the sending machine's hostname so a single shared bot/chat
works across the whole fleet. Opt-in only via `CONVERT_TELEGRAM_BOT_TOKEN`/
`CONVERT_TELEGRAM_CHAT_ID` environment variables -- deliberately never a
CLI flag, since a flag's value is visible to any local user via `ps aux`
while an env var isn't (same reasoning as the existing `CONVERT_SMB_USER`/
`CONVERT_SMB_PASSWORD` pattern). Silently disabled (instant no-op) if
either variable is unset. Fires in the background with a short timeout
and never blocks or fails the actual encode job even if Telegram is
unreachable -- notification delivery is best-effort, not load-bearing,
same principle as every other auxiliary path in this script. Uses
`--data-urlencode` rather than string-concatenating into the URL so a
title containing spaces/parens/unicode can't produce a malformed
request. Hooked into `end_convert_job()`, the single existing function
that already handles both success and failure uniformly, rather than
adding separate notification calls scattered across the codebase.

Verified in isolation: no-op path returns in ~0ms when unset; the
firing path also returns in ~1ms (correctly backgrounded/disowned, not
blocking) when sending a message containing spaces, parens, and
unicode. `bash -n` passes.

## v5.0.33R — 2026-08-02

Fixes from a full independent E2E confidence/code review of the
33O-33Q subtitle-filter and two-stage-encode bundle (both reviewed the
diff independently and converged on the same core bug class):

1. **Ambiguous ffprobe/ffmpeg probe failures were silently treated as
   "confirmed empty subtitle", a real data-loss risk.**
   `subtitle_stream_has_real_content()`'s packet-presence check, its
   text-decode check, and `build_real_subtitle_map_args()`'s stream-
   enumeration check all previously collapsed "the probe failed/timed
   out" into the same result as "genuinely no content" -- on a flaky NAS
   read or a transient timeout, a perfectly real subtitle track could get
   silently stripped. Now tri-state: confirmed-empty (strip),
   confirmed-real (keep), or ambiguous/probe-error (keep, with a warning)
   -- never treat a subprocess failure as proof of absence, same
   principle as [[feedback_verify_before_delete]]. The packet-presence
   check also switched from `| grep -c .` (scans every packet in the
   whole file) to `| head -1` (stops at the first packet, same idiom
   `validate_mkv_subtitle_tracks` already used) -- on a dense
   multi-subtitle-track file over NAS this avoids dozens of near-full-file
   ffprobe passes per title.
2. **Aggressive bitmap-subtitle stripping removed.** The non-text-codec
   branch (dvd_subtitle, hdmv_pgs_subtitle) used to strip a track if
   ffmpeg's stderr contained the words "error" or "invalid" anywhere --
   PGS/DVD tracks pulled from physical media routinely produce benign,
   non-fatal decode warnings containing those exact words, which was
   silently discarding perfectly viewable subtitle tracks. Packet
   presence (already confirmed) is now the only signal for these codecs.
3. **Both AMD VAAPI hardware-encode paths** (`ffmpeg_encode_hw()`,
   `vaapi_hevc_encode()`) **hardcoded `-c:s copy` for subtitles**, missing
   the mp4/m4v/mov -> srt exception every other final-output path already
   has -- any MP4 source with subtitles taking a hardware-encode path
   would fail outright ("Could not write header"). Fixed to match.
4. **`av1_source_reencode_sample_decision()`'s clip-extraction step** had
   the same mp4 mov_text gap -- a blanket `-c copy` into a Matroska clip
   would fail the whole sample-clip extraction on an MP4 source with
   subtitles, silently falling back to a less-accurate size prediction
   instead of a real tested sample. Same mp4/m4v/mov -> srt fix applied.
5. **`remux_copy_to_mkv()`'s `-map 0:v` (no `?`) would fail outright on
   an audio-only source** (no video stream at all) instead of losslessly
   remuxing the audio -- changed to `-map "0:v?"`. Also made
   `-map_chapters 0 -map_metadata 0` explicit rather than relying on
   ffmpeg's default behavior, now that every other map in that command is
   explicit too.

All fixes re-verified: the tri-state logic was directly unit-tested
against a real ffprobe failure (nonexistent file -> correctly kept
rather than stripped) plus the existing real/empty ASS and mov_text test
files (unchanged correct results), and a full end-to-end single-file run
through the real script confirmed the same correct strip/keep/manifest
behavior as before the fix.

Deferred to ROADMAP.md as lower-priority hardening (not correctness
bugs): per-run caching of subtitle-content-check results to reduce
redundant ffprobe/ffmpeg calls across the AV1-then-x265 fallback
sequence, and strengthening `record_stripped_subtitle()`'s dedup key
beyond source-path + stream-index.

## v5.0.33Q — 2026-08-02

Added a durable per-folder manifest, `stripped_subtitles.txt` (same
append-log convention as `corrupt_files.txt`/`bad_sources.txt`), recording
every subtitle stream `build_real_subtitle_map_args()` strips for having
no renderable content: timestamp, source path, stream index, language
tag, and track title. Without this, the only record of a stripped track
was a transient warn() line in the console/log -- there was no durable
list of which titles lost which language tracks to go source replacement
subtitles for. Deduplicated per source+stream-index within a run (the
same check re-fires once per encoder attempt -- AV1, then an x265
fallback -- which would otherwise double-log every stripped track).
Verified end-to-end on a real single-file test run: the manifest was
created with exactly one correctly-deduplicated line, correctly carrying
the stream's `title` tag through from the source.

Full fleet subtitle-filter test (5 idle machines: PRINCE, GruntVM,
AI-PROCESSOR, Plex, GruntBox2) completed clean on 33P/33Q: every run
across both codec attempts (AV1, x265 fallback) correctly stripped the
synthetic empty subtitle track and kept the real one; the two-stage
encode/remux pipeline completed without crashes or truncation on every
machine. ("Job failed" results in that test were expected and correct --
the synthetic test video is incompressible noise, so both encode attempts
came out larger than the tiny original and were correctly rejected by
the existing size-check logic, keeping the original.)

Also found (not yet fixed, see ROADMAP.md): PRINCE and GruntBox2 are
both missing the `convert-current.sh` wrapper other fleet machines have;
the orphan reaper aborts the entire script run on an unrelated
permission error instead of warning and continuing (cost ~10 wasted
minutes on GruntVM during this test, no files processed).

## v5.0.33P — 2026-08-02

Bug found while building a small synthetic test to validate 33O's new
`subtitle_stream_has_real_content()` fleet-wide: an ASS subtitle cue
containing only an override block (e.g. `{\an5}`, a position tag with no
dialogue) survived the original cue-number/timing-only markup strip,
because ffmpeg's SRT muxer wraps styled ASS text in `<font ...>...</font>`
-- the leftover `<font size="20">{\an5}</font>` line passed the "is this
non-empty" check as if it were real text, a false negative that would
have kept a functionally-empty track. Fixed by stripping ASS override
blocks (`{\...}`) and any `<tag>`/`</tag>` wrapper before the emptiness
check. Verified directly against a constructed ASS-track test file
(override-only cue correctly now strips; a track with genuine dialogue
text still correctly survives).

## v5.0.33O — 2026-08-02

Four changes bundled into this version, in order of dependency:

1. **`remux_copy_to_mkv()` mov_text fix**: this shared remux-shortcut
   function (must-eliminate-format floor, HEVC-in-MKV shortcut, legacy-
   container "x265 remux to MKV" path) used a blanket `-map 0 -c copy`,
   which fails outright when the source is MP4 carrying `mov_text`
   subtitles -- Matroska cannot hold that codec, so the WHOLE remux
   failed with "Could not write header", not just the subtitle track.
   Found on "Under the Microscope (2023) S01E11.mp4". Fixed by splitting
   to `-c:v copy -c:a copy -c:s "$sub_codec"` with the same mp4/m4v/mov
   -> srt exception the full encode path already applies. Verified
   directly against the real failing file (rc=0 after fix, rc=234
   before).

2. **Two-stage encode + remux** (`ffmpeg_encode()`): the recurring "zero
   frames decoded" truncation bug (KanColle, Last Bullet, Dont Make Me
   Go) was root-caused via packet-level evidence captured by 33N's
   diagnostic function to be genuine mid-encode video-stream starvation
   at a non-fixed point, NOT a near-the-end issue as the validation
   failure name implied. One reviewer's minimal mitigation
   (`-max_interleave_delta 1000000 -flush_packets 1` alone) was
   implemented and live-tested against the real KanColle file -- it
   FAILED, truncating identically at frame=324. Replaced with a two-stage
   restructure: stage 1 encodes video+audio only (no subtitle/attachment
   mapping, so the sparse-stream interleaving that likely triggers the
   starvation never happens during the expensive encode); stage 2 does a
   cheap stream-copy remux adding the source's subtitles/attachments back
   in. The old "retry without subtitles" logic is now a stage-2-only
   fallback. Implemented. **Live-tested against the real
   KanColle file end-to-end (2026-08-02) and confirmed fixed**: output
   duration (5585.596s) matches the source (5585.590s) exactly, a full
   `-count_frames` decode reached the genuine end of the file (133920
   frames, time=01:33:05.58) instead of stopping at frame=324, VMAF 95.3,
   kept AV1 at 12.1% of original size, encode ran at 1.16x realtime.

3. **Subtitle content filtering** (new `subtitle_stream_has_real_content()`
   / `build_real_subtitle_map_args()`): a source can flag a subtitle
   stream (present in the container, selectable in a player) while
   carrying zero actual renderable content -- no packets, or packets
   whose text is empty once cue-timing markup is stripped. Every place
   that produces final output was mapping subtitles blanket (`"?:s?"` /
   `-map 0`), carrying these meaningless tracks straight through. Added
   a per-stream check (packet count, then for text codecs an actual
   decode-and-strip-markup check, then for bitmap/other codecs a
   packet-count + decode-error-grep proxy) and wired an explicit,
   filtered `-map` list into every final-output-producing path: the
   two-stage remux (stage 2), both AMD VAAPI hardware-encode paths
   (`ffmpeg_encode_hw`, the `hevc_vaapi` remux path), and
   `remux_copy_to_mkv()`. Transient VMAF-sample-clip test encodes were
   deliberately left on blanket subtitle mapping since they're discarded
   test artifacts, not player-facing output.

4. **Upscale sample-test clip extraction fix**: `upscale_sample_decision()`'s
   clip-extraction step (`-ss <point> -t 10 -i "$src" -map 0:v:0 -c copy`)
   failed with "Can't write packet with unknown timestamp" on legacy AVI
   sources with irregular timestamps at the seek point, silently falling
   back to the conservative default instead of a real tested upscale
   decision -- likely why "Divorce American Style (1967)" upscaled only
   to 720p instead of the expected 1080p. Fixed by adding
   `-fflags +genpts -avoid_negative_ts make_zero` to the extraction
   command. Verified directly against the real file (rc=234 before,
   rc=0 after).

**Status**: all four items implemented and live-verified against real
files (KanColle for item 2, "Under the Microscope" for item 1, "Divorce
American Style" for item 4). Item 3 (subtitle content filtering) verified
via the KanColle live test -- its one real subtitle track and 4
attachments survived the filter untouched, confirming the filter doesn't
false-positive on genuine content.

## v5.0.33N — 2026-08-01

The recurring "zero frames decoded near end" validation failure (KanColle,
Last Bullet, and now a third independent hit -- "Dont Make Me Go (2022)"
on AI-PROCESSOR) got a fresh team investigation after confirming a much
stronger pattern: the two most recent hits have 34 and 38 subtitle tracks
respectively (streaming-release, one-per-language style), vs KanColle's
1 track + 4 attachments -- all three are long (93-113 min). A fresh 5-minute
clip repro test using the FULL 34-track subtitle set from "Dont Make Me Go"
still did not reproduce the stall, confirming this needs sustained long
duration to manifest, not just a high subtitle-track count in isolation.

Two independent reviewers disagreed on the mechanism: one theorized
`-max_muxing_queue_size` exhaustion from sparse subtitle-stream
interleaving; the other was skeptical (queue exhaustion is documented as a
hard error, not a silent stall) and pointed instead at
`ffmpeg-formats.html`'s own `max_interleave_delta` documentation, which
explicitly calls out sparse streams causing excessive buffering -- a
different, more specific mechanism. Neither is confirmed; a real repro
would need an actual 60-90+ minute encode, too expensive to iterate on
blindly.

Rather than guess at a fix, added `capture_validation_failure_evidence()`:
fires only for `video_truncated`/`zero_frames_decoded` validation
failures (the two reasons behind this exact bug class), preserving the
rejected output plus ffprobe/mkvmerge metadata and a packet-level trace
of the final 2 minutes of both source and output -- into a
`.convert-v5-validation-failures/` sidecar dir -- BEFORE the existing
code deletes the evidence, so the next real occurrence leaves an actual
artifact to inspect instead of forcing another blind live-reproduction
attempt. Purely diagnostic: no change to encode/validation logic or
success-path behavior. Implemented and reviewed.

## v5.0.33M — 2026-07-31

Team E2E confidence review of the full script (requested by the user
after v5.0.33L shipped) found one real bug: `orphan_gate1_duration()`
always failed for disc-derived (ISO/BDMV) orphan candidates, since ffprobe
can't derive a duration from a raw disc path -- meaning after a crash
mid-job, the orphan reaper would delete a possibly hours-of-work AV1/x265
candidate instead of salvaging or deferring it for review, every time,
for every disc source. Fixed by skipping Gate 1 outright for disc sources
(`is_disk_source "$source" && return 0`), relying on Gates 2/3 (structure
+ tail decode) as the safety net instead. Team-reviewed: correct
fix for the deletion bug, though noted as a "salvage-over-delete
tradeoff" rather than a fully equivalent duration check, since there's no
recorded expected-title-duration to compare against without a full
HandBrake re-scan (too expensive for the orphan reaper's per-pass cost
budget) -- worth a proper disc-specific duration check as a future
improvement if this proves insufficient in practice. Another reviewer's independent
pass hit repeated external API errors and did not complete.

## v5.0.33L — 2026-07-31

Follow-up user direction after v5.0.33K's HandBrake main-feature fix:
"Ideally ISO's and other disk-based sources are 'extracted' by HandBrake
into some cheap lossless format so that the normal processing can then
take place... this would unify the encoding process because all files are
encoded the same way." Previously, disc sources (ISO/BDMV) had HandBrake do
the entire final AV1/x265 encode itself via a separate special-cased path
(`bakeoff_encoder_for_src`/`handbrake_encode`), never going through the
same VMAF-CRF-search ffmpeg pipeline every other library file uses.

Redesigned `process_disk()`: HandBrake now only extracts the selected
title into a private, local-disk-only scratch file (explicitly NOT the
RAM-disk/tmpfs staging path -- a losslessly re-encoded Blu-ray can be tens
of GB), which is then symlinked into the real media directory under the
disc's own name and run through the *exact same* `try_av1_convert`
pipeline as any other file. The symlink is what makes this work with zero
changes needed to `canonical_title_from_source`/`media_content_dir`/
`av1_output_path`/`profile_for_source`/ffprobe-based codec detection --
they all just see an ordinary `.mkv` (ffmpeg/ffprobe/HandBrake all follow
read-side symlinks transparently).

Extraction encoder is x264 at `-q 0` (true lossless), not FFV1 --
empirically tested FFV1 first (the more obvious "true lossless" choice)
but HandBrakeCLI 1.11.0 segfaults immediately inside `encavcodecInit` for
the FFV1 encoder on real hardware, reproduced independent of
source/quality/subtitles. x264 `-q 0` is genuinely lossless (QP 0) and
was verified working end-to-end.

New `logical_source` parameter threaded through `try_av1_convert`/
`try_x265_convert`/`must_eliminate_fallback_or_fail`/
`record_conversion_result`/`done_log_append` (design + implementation
reviewed, two real bugs caught before shipping: the override
needed to cover `is_must_eliminate_format` checks and `flag_bad_source_for_human`
targeting, not just size accounting; and `JOB_LOGICAL_SOURCE` needed an
explicit reset at both per-file entry points to prevent it leaking a
disc job's identity into the next unrelated file's accounting) -- keeps
size-guardrail/must-eliminate-format/done-log accounting anchored on the
TRUE original disc, not the temporary symlink, while output naming stays
derived from the symlink (so it lands with the disc's real title). A disc
job with no salvageable AV1/x265 candidate has no valid cheap remux floor
(unlike avi/mpg, ffmpeg can't stream-copy a raw disc structure -- that's
exactly why the lossless extraction step exists) -- `must_eliminate_fallback_or_fail`
now skips that floor specifically for disc sources and flags for manual
review instead.

`ramdisk_job_teardown`'s EXIT trap (already relied on by every run) now
also owns disc-extraction scratch-file/symlink cleanup, composed into the
same trap rather than installing a second one (which would silently
clobber it) -- and is now registered unconditionally at the top of
`ramdisk_job_start` rather than only on its ramdisk-found success path,
so the cleanup fires even on machines with no ramdisk at all.

Verified end-to-end on real infrastructure (PRINCE, a WSL-hybrid machine
running HandBrake via its Windows .exe) against the actual "Zu Warriors
(2001).iso" from the v5.0.33K investigation: title selection, lossless
extraction, symlink handoff, the real VMAF-CRF-search AV1 encode, correct
final output naming/placement, correct guardrail-size accounting against
the true 7.25GB disc, and clean cleanup all confirmed working. One real
bug found only through this live test: the scratch directory's `chmod 700`
caused the Windows-side HandBrake process to fail with
`avio_open2 failed, errno -13` (EACCES) when writing via
`\\wsl.localhost\` interop, since that process reaches WSL paths under a
different UID mapping than the Linux-side owner -- fixed to `chmod 1777`
(team review: sticky bit over plain 777, since this scratch dir is
local-machine-only, never NFS/network-shared).

## v5.0.33K — 2026-07-31

User feedback during fleet triage: "ISO's (and other disk structures) should
be handled by HandBrake" — found on PRINCE, "Zu Warriors (2001).iso" got
skipped ("Unable to Determine which title you wish to convert, process this
manually") because its two feature-length titles (1:44:01 and 1:20:21) were
only ~29% apart, under the existing `DISK_TITLE_DOMINANCE_PCT` (40%)
duration-ratio threshold used to auto-pick a disc's main title. Rather than
tune that threshold (which would just move the ambiguity boundary, not
resolve it), added `handbrake_scan_main_feature_title()`: runs
`HandBrakeCLI --main-feature --scan` and reads which title HandBrake itself
marks `+ Main Feature` — its detection uses real disc-structure signals
(VTS/angle layout), not just a duration comparison. Wired into
`select_dominant_disk_title()` as the first thing tried; falls through to
the existing duration-dominance heuristic unchanged if HandBrake doesn't
mark anything. Empirically verified against the real ISO: HandBrake
correctly and immediately identified title 1 (1:44:01) as the main feature.
Team-reviewed: PASS — POSIX-portable awk, correct fallthrough,
`set -euo pipefail` safe.

## v5.0.33J — 2026-07-31

Found during the fleet-wide final production-readiness test (resumed after a
session interruption on docm): "KanColle The Movie (2016)" (93min anime movie,
1080p h264 source, ASS subtitle + 4 font attachments) had BOTH its AV1 and its
x265 fallback attempts independently fail post-encode validation with "zero
frames decoded in last 30s" — a real, previously-undiscovered failure class,
not the same false-positive bug already fixed in `audio_track_reaches_near_eof`
earlier this project. Confirmed the source itself decodes cleanly (719 real
frames in its own last 30s via direct ffprobe/ffmpeg); the defect is in the
OUTPUT only, on both codec paths independently. Root-caused as far as a 5-minute
clip reproduction could take it: extracting the source's last 5 minutes and
running the exact same final-encode command construction (video+audio+subs+
attachments mapped, libsvtav1, max_muxing_queue_size 8192) reproduced NO stall
— completed cleanly with matching frame counts whether or not subtitles/
attachments were mapped. So the defect is specific to sustained long-duration
(~90+ min) real encodes, not simply an artifact of subtitle/attachment mapping
in isolation. Consulted the team: one reviewer proposed a demuxer-lookahead/
muxing-queue-overflow theory (silently dropping video packets during long
sparse-subtitle seeks); another reviewer was skeptical of that specific mechanism
(`-max_muxing_queue_size` normally fails loudly rather than silently dropping)
and, after reading the actual validation code, pointed out a real *gap*
regardless of root cause: the existing tail-decode check (`validate_mkv_decode_windows`)
seeks from the OUTPUT's own reported EOF, which only caught this case because
the output's container duration happened to still match the source's — a
future case where the output's own duration also shrinks (following the
truncated video) could pass this check falsely. Root mechanism for why the
video stream itself stalls is **not fully proven** — this is a defense-in-depth
fix, not a confirmed root-cause fix:

- **New `validate_mkv_video_reaches_source_eof()`** (called from
  `validate_mkv_output` after the existing duration-drift check): seeks from
  the SOURCE's duration (not the destination's) and verifies real video frames
  decode near where the file OUGHT to end regardless of what the destination
  container claims about itself. Complements, doesn't replace, the existing
  decode-window checks.
- **`-fps_mode passthrough`** added to both the primary encode and the
  subtitle-stripped retry, as a low-risk mitigation in case ffmpeg's default
  frame-duplication/drop timestamp resync logic is implicated — not confirmed,
  but no downside to passing source frame timing straight through.
- Both changes verified: unit-tested the new validation function standalone
  against a real encoded clip (legitimate full-duration file passes; a
  simulated-truncation case correctly fails and records `video_truncated`).
  Team-reviewed: PASS, with one documented caveat — an unusual source
  where audio/container duration legitimately extends past the last real video
  frame by more than the validation window could false-fail this new check;
  not observed in practice, worth revisiting if it ever surfaces.

Also fixed the same session: Plex was the only fleet machine where `worker`
(the actual job-running account) lacked `loginctl` linger — a gap in the
2026-07-29 fix, which enabled linger for the legacy `plex` account instead.
With `RemoveIPC` defaulting to `yes`, this let systemd-logind silently wipe
`worker`'s `/dev/shm` RAM-disk staging directory whenever the launching SSH
session ended, mid-encode — ffmpeg's detached process kept running and
"succeeded" writing into a directory that no longer existed. Fixed via
`loginctl enable-linger worker` on Plex (no code change; config-only, verified
fleet-wide that no other machine has this gap).

## v5.0.33I — 2026-07-30

Found during the final production-readiness test (all 8 fleet machines
running a mixed-format regression pass on v5.0.33H): asked "are we actually
using the RAMDISK staging path fleet-wide?" and checked directly rather
than assuming — 7 of 8 machines confirmed genuine RAM-backed staging
(`/tmp`/`/dev/shm` tmpfs), but **Crystalight (macOS) was silently falling
back to writing straight to the NFS destination**, despite having a
correctly-provisioned 12GB RAM disk mounted at `/Volumes/ConvertRAMDisk`.

**Root cause**: `_is_tmpfs_dir()`'s macOS branch grepped `diskutil info`
for `"Virtual Interface.*Yes"` or `"Device Node.*disk.*Virtual"` — neither
pattern exists in real `diskutil` output, so the check has silently never
worked since RAMDISK support was added. The real signal
(`Virtual: Yes`) only appears on the disk's *parent whole-disk* record, not
the mounted partition the old code queried, and even that alone isn't
sufficient — every APFS volume (including the real boot disk) reports
`VirtualOrPhysical=Virtual` at the container layer.

**Fix**: rewrote the macOS detection to scan `hdiutil info`'s own
attached-image list for the block whose `system-entities` mount our target
directory, and only trust it if that same block's `image-path` is
genuinely `ram://` (not a file path) — this is the same signal macOS
itself uses to distinguish a real RAM disk from an ordinary mounted `.dmg`.
Team review caught that an earlier draft of this fix — walking
APFS container → physical store → `BusProtocol=Disk Image` — would have
misclassified any file-backed disk image mounted from real SSD storage as
RAM-backed too; the `hdiutil info` / `ram://` check is the more precise
signal that reviewer suggested. Empirically verified on Crystalight: RAM disk →
detected true, real boot volume → false, home directory → false,
nonexistent directory → false.

**Deploy scope**: this fix is deployed to Crystalight only for now. The
other 7 fleet machines are mid-run on the final production-readiness test
and were deliberately left undisturbed on v5.0.33H — full fleet sync to
v5.0.33I happens once that test completes.

## v5.0.33H — 2026-07-30

Full end-to-end team review of the entire v5.0.33G file (not just the new
code): 7 parallel section-review agents covering the whole 14,000+ line
script, plus two other reviewers reviewing all of this session's changed
functions together as a consolidated set (to catch interaction bugs a
piecemeal review would miss). One reviewer reported "100% stable, zero bugs";
the other reviewer and one section agent independently found real issues, so — per this
project's established practice — the empirically-verified findings were
trusted over that clean bill of health.

Nine real bugs fixed, all `bash -n`-verified and empirically reasoned
through rather than pattern-matched:

- **`resume_check_shard_changes`**: a bare `cp -f` and a bare
  `changes="$(compare_shard_snapshots ...)"` could abort the entire script
  under `set -e` on a transient NFS hiccup during ordinary resume
  bookkeeping. Guarded both (`|| true` / `|| changes=""`).
- **`optimize_mkv_for_streaming`**: a bare trailing `rm -rf` cleanup could
  abort mid-finalize on a permission/NFS race. Added `|| true`.
- **`upscale_sample_decision`, `pick_av1_encoder`, the multi-point encoder
  comparison function, `vmaf_crf_search_internal`**: each had a bare
  `mktemp -d` that didn't match the rest of its own function's established
  `|| return 1` convention on every other failure path — one failed
  `mktemp` (e.g. full /tmp) would have aborted the whole script instead of
  falling back gracefully. Fixed all four; also added `|| true` to
  `upscale_sample_decision`'s trailing cleanup.
- **`_orphan_clear_flag`**: a bare `rm -f` reachable unprotected from
  `main()` via `reap_orphaned_encoders()` — a stale flag the reaper
  couldn't remove would have aborted the entire fleet run instead of being
  retried next pass. Added `|| true`.
- **`_orphan_source_from_staged_basename`**: didn't recognize the new
  bare `Title.mkv` staged output name (no codec suffix) from v5.0.33G's
  remux floor at all — added a third reverse-lookup pattern, gated so it's
  only trusted when the resolved source is genuinely a must-eliminate
  format (never ambiguous with a real pre-existing `.mkv` source, since
  `.mkv` sources are never must-eliminate).
  - **Follow-up gap, found on the final verification pass**: the fix above
    was dead code as first written — `_orphan_staged_candidates_in_dir()`,
    the directory enumerator that feeds it, only matched
    `<pid>.Title.AV1.mkv` / `<pid>.Title.x265.mkv` basenames and never
    listed the bare `<pid>.Title.mkv` file at all. A dead-owner staging
    directory containing only a bare-mkv candidate would have had its
    whole directory `rm -rf`'d as unresolvable debris instead of being
    salvaged. Fixed by adding a third regex alternative to the enumerator.
    Also widened the reverse-lookup's extension-reconstruction loop, which
    only tried `mkv mp4 avi ts m4v` — far short of the full
    `is_must_eliminate_format()` list (m2ts, vob, ogm, mpg, mpeg, m2v, rm,
    rmvb, divx, wmv, flv, asf) — so a source like `Title.mpg` still
    couldn't reverse-resolve by basename. Traced every downstream consumer
    (`_orphan_dispose_stage_dir_candidates`, `orphan_canonical_dst_for_candidate`,
    `derived_output_codec_claim_matches`) to confirm each already handles a
    bare-mkv candidate correctly now that it's actually reachable.
- **`validate_mkv_subtitle_tracks`**: the top-level subtitle-probe
  ambiguity check only treated `rc -eq 124` (timeout) as ambiguous; a
  genuine non-timeout ffprobe error was silently treated the same as
  "confirmed no subtitle tracks", which could pass a file that actually
  needed a retry. Widened to `rc -ne 0` (any probe failure).

**Deferred, not fixed** (documented in ROADMAP.md as architectural, not
spot-fixable): `remux_copy_to_mkv()` itself is still unbounded (uses
`run_tracked_encoder`, not the timeout-wrapped `run_ffmpeg_remux`) across
3+ call sites, sharing the same "silent hang" bug class already fixed
elsewhere in v5.0.33E — needs a heartbeat-aware timeout wrapper, not a
one-line fix; a finalized bare-`.mkv` remux depends on a non-fatal
`VES_PROCESSED` tag write to avoid being rescanned as a fresh source; and
quick-scan validation mode skips the subtitle check entirely, so an output
whose full validation previously timed out during subtitle checking could
get permanently quick-accepted later without ever re-running that check.

## v5.0.33G — 2026-07-30

Fixes a real gap found during the final production-readiness test: legacy
container formats (avi, ogm, ts, m2ts, vob, disc images -- and now also
mpg/mpeg/m2v, rm/rmvb, divx, wmv, flv, asf, which were missing from the
`is_must_eliminate_format()` list) could get permanently stuck in their
original container if both AV1 and x265 transcode attempts failed, since
the only prior fallback (`must_eliminate_fallback_or_fail()`) just deferred
the file for human review with nothing else attempted.

**Trigger**: investigating a genuine dual-codec validation failure on
Crystalight during the final test ("Four Sisters And A Wedding (2013)", an
`.mp4` with a variable frame rate — `avg_frame_rate` an unreduced
non-standard fraction rather than a clean ratio) led to confirming the
existing safety net (reject both bad outputs, keep the original, log to
`corrupt_files.txt`) worked correctly there. But the user flagged the
broader requirement directly: legacy containers specifically must never be
left as-is when re-encoding is skipped — they should at least get a plain
container change to MKV.

**Fix**: `must_eliminate_fallback_or_fail()` now falls back to a lossless
stream-copy remux (reusing the existing `remux_copy_to_mkv` +
`validate_mkv_output` primitives) before giving up, scoped strictly to
must-eliminate-format sources — an ordinary file that simply doesn't
compress well or fails validation for unrelated reasons is untouched by
this change and behaves exactly as before.

This required real depth, not just the fallback itself. Three rounds of
independent team review, each catching real issues:
- **Round 1**: a timeout-handling bug (a validation timeout on the new
  remux would have deleted it instead of preserving it for retry, unlike
  every other validation path in the file) and missing collision/symlink
  guards on the new output path.
- **Round 2**: the codebase's resume/skip-detection logic
  (`find_complete_canonical_output`, `clear_incomplete_canonical_outputs`,
  `inspect_existing_outputs_for_queue`) had no awareness of the new plain
  `.mkv` remux output at all — a successfully-remuxed source would never
  be recognized as "done" and would silently retry the entire (doomed)
  AV1/x265 pipeline on every future scan, forever. Fixed via a new
  `must_eliminate_remux_path()` helper wired into all three functions,
  plus the orphaned-staging-file crash-recovery detection
  (`orphan_gate0_provenance`, `orphan_canonical_dst_for_candidate`).
- **Round 3**: `find_complete_canonical_output`'s early-return still
  short-circuited before the new check; `_orphan_collect_candidates_for_flag`
  (a *different* function from the two fixed in round 2) still didn't
  collect the remux path for orphan recovery; two folder-completion
  checks (`_dir_subtree_all_video_files_done`, `mark_folder_done_if_complete`)
  still keyed only on AV1/x265 outputs, which would have kept re-scanning
  a folder containing only successful remuxes forever. All fixed. This
  round also caught a real bug in my own first-draft fix: an attempt to
  inject a `find` predicate via `%q`-quoted command substitution, which
  doesn't word-split the way `eval` would — replaced with a proper bash
  array (`local -a name_preds=(...)`).

**Accepted residual risk, documented rather than fixed**: `flag_bad_processed_output`'s
ownership check for a bare `Title.mkv` (no codec suffix to verify, unlike
`.AV1.mkv`/`.x265.mkv`) relies only on the existing mtime-newer-than-source
guard, not a positive ownership proof. Closing this fully would mean adding
`mkvextract` as a new fleet-wide dependency just to read the
`VES_PROCESSED` tag for this one narrow case (a same-titled, newer,
structurally-valid-but-unrelated file coexisting with a legacy-format
source) — judged not worth it for a low-probability edge case; documented
in a code comment for future reference instead.

## v5.0.33F — 2026-07-29

Fixes a fleet-wide, long-standing x265 quality bug found while doing a
deep-dive log review of all 8 fleet machines' output after the v5.0.33E
restart (user request: "do a deepdive into the logs... to ensure no
failures, premature endings, aborts, or other issues"). The audit itself
found no failures on any machine — but investigating one specific
non-fatal warning ("Unknown option: tune.", seen on MacFedora and
GruntBox2's animation-profiled content) surfaced a real, previously
unknown bug.

**Root cause**: `X265_PARAMS_WANIME`, `_ANIME`, `_CANIME`, and `_VINTAGE`
all embedded `tune=animation` or `tune=grain` directly inside the
colon-separated `-x265-params` string. x265's own parameter parser
(`x265_param_parse()` — what ffmpeg's `-x265-params`, HandBrake's
`--encopts`, and ab-av1's `--enc x265-params=` all call under the hood)
does **not** accept `tune` as an individually settable key — tune is a
whole-preset convenience applied by a completely different function
(`x265_param_default_preset()`) that none of these interfaces invoke.
Every encode using one of these four profiles has been silently printing
`Unknown option: tune.` to stderr and getting **no tuning applied at
all** — for as long as this script has existed. Confirmed this is not a
fleet-version-divergence issue: reproduced identically via direct manual
testing on docm's own build, which never even exercised this code path in
the test batch, ruling out "some machines have an older/different x265."

Directly verified the fix by comparing x265's own reported internal
config with and without a correctly-applied `-tune animation`: `psy-rd`
shifted from the untuned default of `2.00` down to animation-tune's
`0.40`, and deblock parameters changed too — proof the tuning is now
genuinely reaching the encoder, which it silently never did before.

**Fix**: extracted tune into a new `profile_x265_tune()` helper
(`wanime`/`anime`/`canime` → `animation`, `vintage` → `grain`, everything
else → none), removed `tune=...` from all four `X265_PARAMS_*` constants,
and updated every call site to pass it through the correct native
mechanism instead of folding it into the params string:
- `ffmpeg_encode()`'s real hevc encode — `-tune "$x265_tune"` added to
  `FF_VIDEO_ARGS`.
- `_vmaf_score_one()`'s CRF-search sample encode (the scorer used to pick
  a CRF) — `${x265_tune:+-tune "$x265_tune"}` inline, empirically verified
  this parameter expansion produces exactly two argv words when set and
  zero when empty.
- HandBrake's real encode path — new `EP_ENCODER_TUNE` variable, passed
  via `--encoder-tune` in `build_handbrake_args()`; also fixed the
  `--dry-run` log line, which one reviewer caught was still missing this flag in
  its printed preview even though the real invocation was already correct.
- `vmaf_crf_search_abav1()`'s ab-av1 invocation — a **separate** `--enc
  "tune=$x265_tune"` entry (confirmed via ab-av1's own docs that `--enc
  key=value` passes straight through as ffmpeg's own `-key value` option,
  not folded into the existing `x265-params=` value).

Team-reviewed by two independent reviewers in parallel; both independently
confirmed `profile_x265_tune()`'s case coverage is complete across all 8
content profiles and found no `set -e` issues in the
`x265_tune="$(profile_x265_tune ...)" || x265_tune=""` pattern used at
every call site. One reviewer additionally caught the dry-run logging gap noted
above.

**Note on past encodes**: this bug means every wanime/anime/canime/vintage
x265 encode this script has ever produced was missing its intended
animation/grain tuning. This is a real quality-improvement question (worth
considering whether past x265 encodes under these profiles should be
flagged for re-encoding) but is a policy decision, not something addressed
automatically by this fix — the fix only changes behavior going forward.

## v5.0.33E — 2026-07-29

Fixes a silent-hang class of bug that killed 3 of 8 fleet machines' jobs
during the same large-scale production-readiness test, discovered by
investigating why aiprocessor, gruntbox2, and plex all stopped producing
log output partway through their batches, hours before anyone noticed.

Root-cause investigation (three genuinely different mechanisms, not one
shared trigger):

- **GruntBox2**: kernel logs show two separate SVT-AV1 encoder worker
  threads (`svt-md12`, `svt-md14`) segfaulting 5 seconds apart during a
  CRF-search sample encode, on this machine's 2009-era dual Xeon X5570
  (no AVX/AVX2 at all). A genuine encoder crash — but the reason it took
  down the *entire batch* rather than just failing that one file: the
  call site (`_vmaf_score_one`, part of the CRF-search sampling path) used
  bare `run_ffmpeg` with **no timeout**. When SVT-AV1's worker threads died
  uncleanly, ffmpeg's main thread most likely deadlocked waiting on them
  instead of exiting, and with no timeout to catch a hung/deadlocked
  process, the whole script blocked on that one call indefinitely.
- **Plex**: systemd logs show the SSH login session that had been holding
  this job open for **1 week 3 days 9h54m of CPU time** was closed, and
  because the `plex` account has `Linger=no`, systemd tore down that
  session's cgroup scope ~4 minutes later, killing every process still in
  it — including the week-plus-running encode job. Unrelated to the
  GruntBox2 mechanism; this will recur on any long-running job whenever its
  originating SSH session ends, for any reason.
- **aiprocessor**: died the same way (silently, mid-CRF-search, zero
  diagnostic trace) but the SSH session that held it stayed alive 7+ hours
  after the process died, ruling out Plex's session-teardown mechanism.
  Consistent with the same unguarded-`run_ffmpeg` hang risk as GruntBox2,
  though not independently confirmed with the same certainty (no
  kernel-visible crash trigger was found).

The codebase already had a hardened, timeout-and-retry-wrapped `ffmpeg`
path (`run_ffmpeg_validation`, added 2026-07-22 specifically because "a
stalled NFS read... could hang the whole machine indefinitely") — but an
existing code comment already flagged, undone, that other call sites still
used "several un-timeout-guarded run_ffmpeg calls" and could suffer the
same fate. This fix extends that same protection to every short/bounded
sample-clip `run_ffmpeg` call found in a full sweep of the script:
`vmaf_crf_search_internal`'s clip extraction, `_vmaf_score_one`'s sample
encode + VMAF scoring (the confirmed GruntBox2 crash site),
`vmaf_crf_search_abav1`'s ab-av1 invocation, `upscale_sample_decision`'s 5
calls (found by one reviewer on the first review pass — the same class of gap,
missed in the initial fix), `_vmaf_compare_window`, `encoder_ssim_score`,
the bake-off sample clip extraction, and the AV1-source-sample-point clip
extraction. The real full-file encode path (which legitimately runs for
hours on this fleet's slower machines) is deliberately left unbound, same
as before.

A separate timeout curve (`_remux_timeout_for_args` / `run_ffmpeg_remux`,
base 300s + 700s/GiB, capped at 36000s/10h) was added specifically for
`attempt_source_mkv_structure_remux`'s ffmpeg fallback — a full-file stream
copy, not a short sample. Both independent reviewers caught, on
the second review round, that reusing the short-probe timeout curve
(`_validation_timeout_for_args`, capped at 3620s) there would require
~14 MiB/s sustained throughput just to avoid a false timeout on a 50GiB
file, which could wrongly flag a perfectly healthy but slow-to-copy source
as corrupt. The new curve requires only ~1.5 MiB/s up to ~51GiB.

Deliberately left unfixed: `ffmpeg_sample_encode()`, which uses a
different execution mechanism (`run_tracked_encoder`: background + plain
`wait`, no timeout at all) shared with the real multi-hour full-file
encode path. Adding sample-specific timeout handling there requires
distinguishing sample-callers from real-encode-callers inside a heavily
shared primitive — judged too risky to rush in this pass; tracked as a
follow-up in ROADMAP.md rather than fixed under time pressure.

Team-reviewed by two independent reviewers across two full rounds: the first round
caught one additional unfixed call site (`upscale_sample_decision`) beyond
the original CRF-search-only fix; the second round (after that expansion)
caught the remux-repair timeout-curve mismatch above. Both rounds
confirmed no `set -e`/quoting issues in the new code.

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
the follow-up fixes the follow-up fixes that batch's own review surfaced) — both passes found real, fixable issues
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
