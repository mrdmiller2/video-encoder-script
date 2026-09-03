# Task 2 Findings - PRINCE Per-Shot Numerical Parity

Authoritative source: bash modules on branch `6.x-chunk-redesign`.
Audit target: Windows PowerShell port in `windows/modules`.

## VesSceneDetect.psm1

### Get-VesSceneBoundaries vs scene_detect_boundaries

- Matches: default threshold resolves to `SCENE_DETECT_THRESHOLD` else `0.3`; ffmpeg stays `-v info`; no-stats/no-stdin are present; non-stats path uses `select='gt(scene,thr)',showinfo` and parses `pts_time`.
- Matches: `-StatsOut` path uses a `split=2` graph with `[sc]select=gt(scene,thr),showinfo[cuts]` and `[st]fps=N,signalstats,entropy=mode=normal,metadata=print:file=...,nullsink`; `SHOT_COMPLEXITY_FPS` default is `4`.
- Intentional platform difference: PowerShell sets ffmpeg working directory and passes a bare metadata filename so Windows drive-letter colons do not corrupt filter-option parsing. This preserves bash output behavior.
- Fix: none.

### Get-VesShotComplexityTable vs _shot_complexity_table

- Matches: parses metadata as frame blocks; captures `pts_time`, `signalstats.YAVG`, `signalstats.YDIF`, `entropy.entropy.normal.Y`, and `signalstats.SATAVG`.
- Matches: attributes each completed frame to the first shot whose next boundary is greater than `t` using `while s < nb && t >= B[s]`.
- Matches: outputs no entry for shots with fewer than 2 samples; returned object fields are rounded to bash formats (`luma`/`sat` 2 decimals, `motion`/`detail` 4 decimals).
- Divergence: PowerShell returns a hashtable keyed by shot index rather than printing text rows. This is an API-shape difference only; `New-VesShotManifest` consumes it into the same `cx_*` lines as bash.
- Fix: none.

### Get-VesShotLongWindows vs _shot_long_windows

- Matches: reads YDIF samples in `[start,end)`; requires at least 6 samples and duration greater than `1.5 * win_len`; defaults `win_len` to 8.
- Matches: splits into 3 equal thirds, computes the same sample-count window span (`int(L/step + 0.5)` equivalent), picks the highest mean YDIF window in each third, centers flat thirds when peak is within 8% of mean, clamps offsets to `[0, dur-L]`, and emits `o1,o2,o3` with two decimals.
- Fix: none.

## VesPerShotQp.psm1

### Phase-1 Config Getters

- Matches before fix: numeric defaults for `SHOT_LONG_SECS=45`, `PER_SHOT_MW_LEN=8`, `PER_SHOT_VMAF_STRIDE=2`, `NOSIG_BLACK_LUMA=16`, `NOSIG_STATIC_MOTION=1.0`, `NOSIG_FLAT_DETAIL=3.0`, `NOSIG_QP=48`, `NOSIG_MIN_SECS=0.5`, `PER_SHOT_QP_BRACKET_EDGE_FAIL_PCT=5`, and per-shot extension/crossover defaults.
- Diverged: boolean helpers accepted any value except `false` as enabled, while bash gates some flags with exact defaulted equality to `true`: `PER_SHOT_MULTIWINDOW_ENABLE`, `SHOT_SRC_LOCAL_STAGE`, and `PER_SHOT_NOSIGNAL_FASTPATH`.
- Diverged: `SHOT_MW_DEBIAS` used "anything except 0" while bash requires defaulted value exactly `1`.
- Diverged: `SHOT_SRC_LOCAL_STAGE_DIR` defaulted to the platform temp directory plus `ves-srcstage`; bash default is `/var/tmp/ves-srcstage`.
- Fix: boolean/default handling now mirrors each bash `${VAR:-default}` use, and `SHOT_SRC_LOCAL_STAGE_DIR` defaults to `/var/tmp/ves-srcstage`.

### Get-VesShotIsNosignal vs _shot_is_nosignal

- Matches: honors `PER_SHOT_NOSIGNAL_FASTPATH`, requires all three complexity fields, and fires only when `cx_luma < 16`, `cx_motion < 1.0`, and `cx_detail < 3.0` with strict numeric `<`.
- Diverged: fastpath getter was broader than bash (`value != false` instead of defaulted exact `true`).
- Fix: `Get-VesNosignalFastpath` now uses bash-equivalent defaulted exact `true`.

### Get-VesInterpQp vs _interp_qp

- Matches after fix: returns `above_qp` when `below_qp - above_qp <= 1`; equal scores choose midpoint with round half up; normal path computes linear interpolation and clamps strictly inside `(above_qp, below_qp)`.
- Diverged: PowerShell used `[math]::Round()`, which is banker's rounding, while bash uses `int(q+0.5)`.
- Fix: interpolation now uses `Floor(x + 0.5)` to match bash.

### Get-VesPerShotQpBracketFor vs _per_shot_qp_bracket_for

- Matches before fix: flag default off returns global `PER_SHOT_QP_MIN`/`PER_SHOT_QP_MAX`; enabled profile-specific bands fall back to global when absent.
- Diverged: profile env key normalization replaced every non-alphanumeric with `_`; bash only maps lowercase to uppercase and hyphen to underscore (`tr '[:lower:]-' '[:upper:]_'`).
- Diverged: band regex accepted leading/trailing whitespace; bash requires exactly `^[0-9]+ +[0-9]+$`.
- Fix: profile key transform and regex now match bash.

### Test-VesShotBracketEdge vs _shot_status_bracket_edge

- Matches: returns edge when `q <= lo || q >= hi`.
- Diverged: PowerShell parameters had no bash empty-argument defaults (`q=30`, `lo=0`, `hi=63`).
- Fix: defaults added to match bash degenerate input behavior.

### Get-VesVmafScoreShot vs _vmaf_score_shot

- Matches: two-stage seek extraction (`start-30` pre-input clamped at zero, accurate post-input seek, duration via `-t`), lossless `ffv1 -level 3` clip, y4m conversion to `yuv420p10le -strict -1`, frame count via `ffprobe -count_packets nb_read_packets`, uniform QP file for the SvtAv1EncApp path, grain-on VMAF, pooled mean VMAF rounded to 2 decimals, and output byte count from the encoded artifact.
- Matches: VMAF stride is applied only when `SHOT_FIELD_MODE=progressive`; `select=not(mod(n,S))` is prepended to both distorted and reference chains before `setpts=PTS-STARTPTS,format=yuv420p10le`.
- Diverged: ffmpeg/libsvtav1 fallback encoded directly to MKV and therefore reported MKV bytes, while bash/SvtAv1EncApp reports IVF bytes before MKV remux.
- Fix: ffmpeg fallback now writes IVF, remuxes that IVF to MKV only for VMAF measurement, and reports IVF bytes.
- Flagged: PRINCE has no `SvtAv1EncApp.exe`; this task cannot prove the ffmpeg/libsvtav1 fallback lands within +/-0.5 VMAF and ~3% bytes of the authoritative `SvtAv1EncApp --qpfile` path. That remains a Phase-2 blocker requiring a host with both encoders.

### Get-VesShotEncodeBytesOnly vs _shot_encode_bytes_only

- Matches: same extraction/y4m/frame-count flow as VMAF scoring; emits encoded byte count only.
- Diverged: ffmpeg/libsvtav1 fallback wrote a non-IVF container (`shot.mkv.out`) and measured that, while bash measures IVF bytes.
- Fix: ffmpeg fallback now writes and measures `shot.ivf`.
- Flagged: same PRINCE fallback parity blocker as above.

### Get-VesVmafScoreShotMw vs _vmaf_score_shot_mw

- Matches: reads `SHOT_MW_OFFSETS` CSV, otherwise computes three even 1/6, 3/6, 5/6-centered offsets; each window scores `[start+o, min(start+o+L,end)]`; fewer than 2 usable windows falls back to full-shot scoring; combines median VMAF and integer `mean(bytes/sec) * shot_secs`.
- Diverged: window length was read only from `SHOT_MW_LEN`, but `Invoke-VesShotSearchClaimed` correctly sets `SHOT_MW_LEN` from `PER_SHOT_MW_LEN`, matching bash runtime behavior.
- Fix: none needed.

### Resolve-VesPerShotQp vs resolve_per_shot_qp

- Matches: anchor probes at low/mid/high, uses `30` as middle anchor when bracket spans it, otherwise midpoint; interpolation loop stops on no bracket or gap <= 1; extension probes past cheap/hard bounds; crossover probes are non-fatal; samples accumulate as `qp:vmaf:bytes`; no-target case returns the highest measured VMAF sample; multi-window dispatch and byte de-bias are implemented.
- Diverged: multi-window enable and de-bias getters were broader than bash.
- Fix: getters now match bash default/equality semantics.

### Invoke-VesShotSearchClaimed vs shot_search_claimed

- Matches: re-checks resolved status after claim; reads `codec`, `profile`, `target`, and full `model` value from `manifest.meta`; exports `SHOT_FIELD_MODE`; sets `SHOT_MW_ACTIVE`, `SHOT_MW_OFFSETS`, and `SHOT_MW_LEN` for shots longer than `SHOT_LONG_SECS`; applies nosignal min-duration gate and single real probe; falls back to fixed QP on empty result; writes bash-order status keys.
- Diverged: multi-window and nosignal enable getters were broader than bash.
- Fix: getters now match bash default/equality semantics.

## VesSourceTraits.psm1

### Get-VesSourceTraits vs detect_source_traits

- Matches: sample points come from the same complexity probe fallback shape; idet parses multi-frame progressive/TFF/BFF and repeated fields; saturation probe averages `SATAVG`; no usable windows returns ambiguous, `is_bw=0`, `field_order=tff`.
- Matches: classifier thresholds match bash/config: progressive ratio `>=0.95`, telecine repeated-field ratio `0.12..0.30` with progressive-window spread `<=0.25`, interlace ratio `>=0.10` with spread `<=0.25`, B&W saturation average `<=4.0`; field order is `bff` only when BFF count exceeds TFF.
- Divergence: bash prints/cache-strings `field_mode=...;is_bw=...;field_order=...`; PowerShell returns an object. This is an API-shape difference and callers persist identical manifest fields.
- Divergence: bash flags ambiguous source traits via sidecar logging; PowerShell currently only warns/caches in this path because the Windows flagging helper is not part of the requested parity surface.
- Fix: none for numerical search parity.
