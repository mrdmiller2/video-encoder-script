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

## Native-Windows PowerShell fork — scoped, not started (2026-08-02)

**Goal**: a PowerShell 7+ port that runs natively on Windows with no WSL
layer at all — eliminates the whole class of WSL-specific pain this
project has already hit repeatedly (PRINCE's full WSL2 rebuild after
filesystem corruption; GruntBox2's NAT-mode networking/portproxy/
firewall dance; WSL2 auto-suspend killing SSH access; the
`\\wsl.localhost\` UNC-path interop permission bug that forced the
disc-extraction scratch dir to `chmod 1777`). **Fork relationship**: the
bash/zsh script on Linux/macOS/WSL remains the single authoritative
source of truth for behavior and design decisions. The PowerShell fork
derives its functionality from the primary version and is tested for
behavioral parity against it (same real test files, same expected
outcomes) — it does not make independent design calls. New features and
bugfixes land in the primary script first; the PowerShell fork stays in
sync afterward, not the other way around.

**Scope explicitly includes** (per user direction): binary
strategy (native Windows builds vs. compiling from source where needed),
a genuine RAM-disk-equivalent staging mechanism, and both NFS and SMB
mount support (the NAS serves both protocols).

**Machine scope — corrected (2026-08-02): this affects exactly three
machines, not the whole 8-machine fleet.** Crystalight is macOS,
MacFedora/GruntVM/AI-PROCESSOR/Plex/docm are Linux — none of those are
touched by this port at all. The actual targets:
- **PRINCE** — currently Windows 11 (host) + WSL2 Ubuntu (where the
  script actually runs today). Native port removes the WSL2 layer
  entirely on this machine.
- **GruntBox2** — currently **Windows Server 2022** (host) + WSL2
  Ubuntu, NAT-mode networking. **Server SKU, not desktop** — some
  Windows features this port might lean on (e.g. certain "Services for
  NFS" client components, or desktop-oriented GPU driver packaging) may
  behave differently or be unavailable on Server 2022 vs. Windows 11.
  This needs to be verified per-feature during Phase 0, not assumed to
  match PRINCE/the HPE laptop's desktop-OS behavior. Likely candidate
  for the "first machine migrated off WSL2" question below, given it's
  also the fleet's slowest member and has the most WSL2-specific pain
  already (NAT/portproxy, auto-suspend, the one unattended-restart mount
  recovery gap).
- **A new, not-yet-onboarded machine — an "HPE" gaming laptop, Windows
  11, believed to have an AMD GPU (exact model/generation not yet
  confirmed).** Not currently in [[reference_video_encoder_fleet_inventory]]
  at all; needs proper onboarding (specs, connection method) whenever
  it's actually added as a fleet member. Its GPU generation matters a
  lot for the AMF research above — if it turns out to be RDNA3 or newer,
  it would be the fleet's first real AV1-hardware-encode-capable AMD
  card (MacFedora's RDNA1 RX5500 has none at all, see section 7) and a
  much better test target for AMF parity-tuning than MacFedora is.
  Confirm the exact GPU model before relying on this.

### 1. External tool binaries — mostly solved, needs confirmation

- **ffmpeg/ffprobe**: BtbN's ffmpeg-builds project already ships
  full-featured static Windows builds (libsvtav1, libx265, libvmaf,
  libplacebo included) — same source PRINCE already uses today via its
  WSL-side ffmpeg. No compilation needed; just point at the Windows
  `.exe` instead of the Linux binary. **Version parity is a hard
  requirement, not a nice-to-have**: the fleet has a standing constant
  pinning SVT-AV1 to a specific version (v4.1.0, see
  [[feedback_svtav1_version_constant]]) specifically so encode behavior
  stays consistent across every machine. Whatever Windows ffmpeg build
  gets used must have its bundled SVT-AV1/x265 version (and SIMD build
  flags — AVX2/AVX-512 support) checked against that pin before use, not
  just whatever BtbN's latest build happens to include — otherwise the
  Windows fork could silently diverge in encode output from day one,
  which directly undermines "Windows follows the primary, doesn't make
  independent decisions."
- **HandBrakeCLI**: official Windows builds already exist and are
  already in active use today (PRINCE's WSL-hybrid setup calls
  `/mnt/c/Program Files/HandBrake/HandBrakeCLI.exe` directly). Directly
  reusable, zero porting work.
- **mkvmerge / mkvpropedit**: MKVToolNix ships official Windows
  installers — should be a straight binary swap.
  **mkvalidator**: unconfirmed whether a prebuilt Windows binary exists
  (on Linux/macOS fleet members it was hand-copied as a binary between
  machines rather than installed from a package manager, per
  [[feedback_fleet_tool_parity_optional_tools]]) — may need building
  from source with MSVC/MinGW, or the PowerShell fork may need to
  degrade gracefully without it (mkvalidator is already optional/
  degrades-gracefully in the primary script, per that same memory's
  caution against treating "optional" as a reason to skip parity
  checks — the degrade path itself still needs to actually work, not
  just be assumed to).
- **ab-av1**: Rust binary, has official Windows release builds on its
  GitHub releases page — should be a straight download, no compile step.

### 2. RAM-disk-equivalent staging — needs a real decision, no Windows-native tmpfs

Linux/WSL2 fleet members stage encode output on `/dev/shm` or `/tmp`
(tmpfs, RAM-backed, no disk I/O during the two-stage encode's temp-file
window). Windows has no built-in equivalent. Candidates to evaluate:
- **ImDisk Toolkit** (free, open-source, scriptable via `imdisk.exe`) —
  creates a RAM-backed virtual disk with a drive letter; most likely
  candidate given it's free and scriptable from PowerShell.
- **OSFMount** (free for personal/eval use) — similar capability,
  different licensing terms worth checking for this use case.
- Fallback: stage on real (fast, local SSD) disk instead of RAM if no
  RAM-disk solution proves reliable — slower but not a correctness
  blocker; the two-stage encode's temp-file disk-space-pressure gap
  (see the v5.0.33R team-review deferred items above) applies here too
  and would need the same "estimate for two staged outputs" fix.

### 3. NFS vs. SMB mounts — NAS supports both, need a decision + both paths tested

- **SMB is the more natively-Windows-idiomatic choice** — `New-SmbMapping`/
  `net use` needs no optional Windows feature enabled, works on every
  Windows SKU including Home, and is what a typical Windows user would
  expect. Likely the primary/default path.
- **Windows NFS client** ("Services for NFS") is a genuine alternative —
  built into Windows but only on Pro/Enterprise/Server SKUs (not Home),
  enabled via `Enable-WindowsOptionalFeature`. Worth supporting since the
  NAS already serves NFS to the rest of the fleet and the user
  explicitly wants both covered, but can't be the only path given the
  SKU restriction.
- Either way, this needs the same category of fix already hit
  repeatedly on the Linux/WSL2 side of the fleet (PRINCE's
  `noresvport` NFS mount requirement, GruntBox2's WSL2-NAT mount-
  recovery gap, the NFS root_squash owner-mismatch issue hit multiple
  times this session during test cleanup) — Windows SMB/NFS have their
  own analogous permission/credential quirks (SMB credential caching,
  UNC path length limits, NFS UID mapping without a domain controller)
  that need discovering empirically on real hardware, not assumed away.

### 4. Process/execution model — genuine redesign, not a mechanical translation

- **Detached/survives-session execution** (this session's `systemd-run
  --unit=... --uid=worker` pattern, used constantly for real fleet
  tests): Windows equivalent is most likely a Scheduled Task
  (`Register-ScheduledTask`) for one-shot detached runs, or a proper
  Windows Service for the always-on fleet-agent role GruntBox2 already
  approximates today via its `VES-WSL-Keepalive` Scheduled Task +
  `.wslconfig` idle-timeout workaround (a workaround this whole port
  would eliminate the NEED for, ironically).
- **Signal handling / cleanup traps** (`trap ... EXIT`,
  `ramdisk_job_teardown`, `resume_on_signal`, `ACTIVE_FFMPEG_STAGE1_FILE`
  cleanup): PowerShell's nearest equivalents are `try/finally`,
  `Register-EngineEvent -SourceIdentifier PowerShell.Exiting`, and
  `[Console]::CancelKeyPress` — different enough from bash trap
  semantics that this needs a genuine redesign of the cleanup-
  composition pattern (the primary script composes stage-1-temp-file
  cleanup into 3 existing cleanup functions rather than adding a new
  raw trap, per [[project_truncation_bug_resolved_2026_08_02]] — the
  PowerShell fork needs its own equivalent single source of truth for
  "what must always run on exit," not three independently-maintained
  copies).
- **`pipefail`-dependent idioms**: a meaningful fraction of the
  subtitle-content-filter and validation code added this session
  (`subtitle_stream_has_real_content()`'s ambiguous-vs-confirmed-empty
  logic, `validate_mkv_subtitle_tracks()`) depends on bash's
  `set -o pipefail` semantics to distinguish "the probe genuinely found
  nothing" from "the probe failed/timed out." PowerShell's pipeline
  error semantics are different enough that this logic needs to be
  reasoned through fresh per case, not transliterated line-by-line — get
  this wrong and it reintroduces exactly the ambiguous-failure-treated-
  as-confirmed-empty data-loss bug the 2026-08-02 team review just
  fixed in the primary script.

### 5. Windows Defender exclusions — required, not optional

Real-time scanning adds meaningful I/O overhead on the exact pattern
this script hammers hardest: repeated large multi-GB reads/writes for
encode temp files and staged output. **Both** the RAM-disk-equivalent
staging area (item 2 above) **and** any on-disk staging/fallback
directory need to be added as Defender exclusion paths
(`Add-MpPreference -ExclusionPath`) as a required part of setup, not an
optional tuning step — this should be baked into whatever install/setup
script accompanies the Windows fork, not left as a manual step a user
might skip and then silently eat the performance loss without knowing
why. Applies to the source/library mount paths too if scan-on-read is
enabled for network shares, not just the local staging dirs.

### 6. Other concerns surfaced in scoping discussion (2026-08-02), needs Phase 0 data

- **Whether WSL2's GPU virtualization is actually the cause of hardware-
  encoder flakiness already observed on the existing fleet** (PRINCE's
  "NVENC AV1 tune probe encode failed rc=2", AI-PROCESSOR's rc=3 failure
  that silently fell back to software) is currently an assumption, not a
  finding. Native Windows only fixes this if WSL2's virtualization layer
  is the actual cause — if it's a driver version issue, VRAM contention
  (AI-PROCESSOR's `stockanalyzer-vllm` service already holds ~13.9GB of
  its Tesla T4's VRAM), or something else entirely, native Windows
  changes nothing and the "full hardware access" premise for THAT
  specific problem doesn't hold. Needs direct comparison testing (same
  GPU, same driver, WSL2 vs. native) before claiming this as a benefit.
- **Losing `fscache`/`cachefilesd` is a plausible performance
  *regression*, not just a missing nice-to-have.** PRINCE and GruntBox2
  both run custom-built WSL2 kernels specifically for `CONFIG_CACHEFILES`
  persistent NFS caching. Windows has no built-in equivalent. Unless a
  replacement caching strategy is found (a third-party caching proxy, or
  accepting slower cold-cache network reads), network-mount-heavy
  workloads on native Windows could end up slower than they are today on
  the same hardware, on the exact machines that invested the most
  engineering effort into fscache. This needs to be measured, not
  assumed away, before the port is called a performance win.
- **AMD hardware encode is a genuine platform break, not a port** — see
  the dedicated AMF section below for the full researched picture.
- **Windows Server 2022 (GruntBox2) vs. Windows 11 (PRINCE, the HPE
  laptop) feature parity is unverified.** GruntBox2 is the only Server-
  SKU target; Server editions sometimes package or expose Windows
  features differently than desktop editions (GPU driver packaging,
  optional-feature availability for things like "Services for NFS").
  Don't assume anything verified on PRINCE/the HPE laptop's Windows 11
  automatically holds on GruntBox2's Server 2022 — check each
  Windows-specific mechanism (RAM-disk tool, NFS client, Defender
  exclusion cmdlets, scheduled-task/service model) on both editions
  during Phase 0.
- **Smaller items worth tracking but not blocking**: NVENC's
  driver-enforced concurrent-session cap (historically 2-3 on consumer
  GeForce cards) is silicon/driver-level and follows to native Windows
  unchanged, not something WSL was ever the cause of; GPU driver TDR (a
  ~2-second watchdog timeout with no Linux equivalent) is a Windows-only
  failure mode worth knowing about for hardware troubleshooting
  specifically, since it manifests as a driver-reset event rather than a
  clean process error.

### 7. AMD's NVENC/CUDA equivalent (AMF) — researched, aim for as close to parity as possible

Per explicit user direction: investigate AMD's actual hardware-encode
and GPU-compute stack in the same depth as NVIDIA's, rather than
treating it as an afterthought. Researched findings (2026-08-02):

- **SDK/library**: Advanced Media Framework (**AMF**), currently
  **v1.5.2**. No separate SDK install needed for end users — the AMF
  runtime (`amfrt64.dll`/`amfrt32.dll`) ships inside standard AMD Radeon
  GPU drivers already. The public SDK on GitHub/GPUOpen is only needed
  for compiling against it directly, not for running ffmpeg's
  AMF-backed encoders.
- **AV1 hardware support by GPU generation** (directly answers whether
  MacFedora's hardware could ever get AV1 hw encode): **RDNA1 (RX 5000
  series, including MacFedora's RX5500) has NO AV1 support at all,
  encode or decode — permanently HEVC/H.264-only via VCN 2.0.** This
  matches its current VAAPI ceiling on Linux exactly; the Windows port
  doesn't change or improve this, it's a real silicon limit. RDNA2 (RX
  6000) adds AV1 *decode* only (except the lowest-end Navi 24 SKUs,
  which have none at all). RDNA3 (RX 7000, VCN 4.0) adds AV1
  *encode+decode* but the AV1 encoder lacks B-frame support. RDNA4 (RX
  9000, VCN 5.0) is the first generation with full AV1 encode+decode
  including B-frames. Relevant if the fleet ever adds a newer AMD card.
- **ffmpeg `hevc_amf`/`av1_amf` vs. NVENC — genuinely comparable core
  feature set, not a crippled alternative**: rate control offers `cqp`
  (constant QP), `vbr_peak`, `cbr`, and `qvbr` (quality-based VBR) — no
  direct `-crf` equivalent, unlike libx265/libsvtav1. Quality presets
  are simpler than NVENC's `p1`-`p7` scale, mapping to `quality`/
  `balanced`/`speed`. `-vbaq true` (Variance-Based AQ) is AMF's
  equivalent to NVENC's spatial-AQ; `-preanalysis true` gives
  lookahead-style optimization comparable to NVENC's multipass. Close
  enough in capability that a real parity-tuning pass (analogous to the
  VAAPI tuning MacFedora already has) is worthwhile, not a lost cause.
- **GPU-compute equivalent to CUDA**: AMD's real equivalent is **HIP**
  (part of ROCm), but ffmpeg has **no native `scale_hip` filter
  upstream** — so there's no direct AMD equivalent to `scale_cuda` via
  that path. The actual working equivalent for hardware-accelerated
  scaling/color-conversion is **`vpp_amf`** (AMF's own scaling filter),
  plus `sr_amf` for FidelityFX Super Resolution upscaling specifically.
  `scale_vulkan` and `scale_opencl` are also available as cross-vendor
  options on Windows if AMF-specific filters prove insufficient.
- **Reliability/compatibility notes for Windows specifically**: AMD's
  "Minimal"/"Driver Only" installer is recommended over the full
  Adrenalin suite (avoids background overlays/telemetry contributing to
  driver resets). A real known failure mode: Windows Update can silently
  overwrite a manually-installed driver with an older certified version,
  breaking `amfrt64.dll` integration — Group Policy should disable
  Windows-managed driver updates on any machine running this. Older
  architectures (Polaris/Vega, pre-dating MacFedora's RDNA1 card) are
  prone to regressions on newer driver branches; pinning to an older
  stable Adrenalin branch is the documented workaround if that hardware
  is ever in the fleet.

### 8. Suggested phasing (avoid a monolithic 14,000-line rewrite attempt)

1. **Phase 0 — tooling spike**: confirm every binary dependency above
   actually works standalone on a real Windows box (GruntBox2's Windows
   host is already fleet hardware and a natural test target once its
   WSL2 layer is no longer the point) before writing any port logic.
   Must also produce real data on item 6's open questions (WSL2-vs-native
   hardware-encoder reliability comparison, fscache-loss performance
   impact) — Phase 1 shouldn't start until those are answered with
   measurements, not assumptions.
2. **Phase 1 — core encode/VMAF/subtitle-filter logic**: the parts with
   the most real test coverage right now (two-stage encode+remux, VMAF
   CRF search, `subtitle_stream_has_real_content()`/
   `build_real_subtitle_map_args()`, the mov_text fix) — mostly portable
   reasoning, least Windows-specific redesign needed.
3. **Phase 2 — mount/staging infrastructure**: RAM-disk equivalent, SMB
   +NFS mount handling, credential management.
4. **Phase 3 — fleet infrastructure**: resume state, orphan reaper,
   sharded directory scanning, detached/scheduled execution model.
5. **Phase 4 — parity test suite**: run the same synthetic test files
   already built for the primary script's subtitle-filter/two-stage
   verification (real+empty SRT/ASS/mov_text tracks, legacy-container
   sources) through the PowerShell fork and confirm identical
   strip/keep/manifest outcomes, not just "it runs without erroring."

**Repo structure — decided (2026-08-02): same repo, not a separate one.**
The PowerShell fork lives in a `windows/` subdirectory of this repo, not
a standalone project. Rationale (explicit user direction): the Linux/
macOS version drives essentially all feature and roadmap decisions
going forward — the Windows fork only pulls in features already proven
on the primary version, plus fixes that are genuinely Windows-specific.
A separate repo would let the two drift into independent roadmaps by
default; keeping them in one repo makes "the primary decides, Windows
follows" the structurally obvious default rather than something that
has to be manually maintained by convention across two places. Version
tags continue to track the primary script's version numbers
(`v5.0.33x`-style); the Windows fork does not get its own independent
version-number track.

**Not yet decided**: minimum supported Windows version/PowerShell
version; whether GruntBox2 specifically becomes the first machine
migrated off WSL2 once this exists (its dual 2009 Xeons/no-AVX2
hardware is already the fleet's slowest member on movie-length content
regardless of OS layer, so migrating it first would isolate the
WSL-removal benefit from any hardware-driven change).

## Deferred from the v5.0.33O/P/Q truncation-bug + subtitle-filter work (2026-08-02)

1. **PRINCE and GruntBox2 are missing the `convert-current.sh` wrapper.**
   Found while launching the fleet subtitle-filter test: both machines'
   deploy directories only have `convert-current.target` (the marker file)
   and the versioned script itself, but not the stable
   `convert-current.sh` wrapper the other 6 machines have (which reads the
   marker and `exec`s the target script, so callers never need to know the
   current version filename). PRINCE lost it in the 2026-07-24/25 WSL2
   rebuild; GruntBox2 apparently never got it during its 2026-07-30
   rsync-post-xfer onboarding despite the onboarding note claiming full
   parity. Worked around by invoking the versioned script directly for
   this test; the wrapper should be recreated on both (copy GruntVM's or
   AI-PROCESSOR's `convert-current.sh` verbatim, it's host-agnostic) so
   future scripted/detached launches don't need the version-specific
   workaround.

2. **Orphan reaper aborts the entire script on an unrelated permission
   error instead of warning and continuing.** Found on GruntVM: a stray
   pre-existing `.convert-stage-*` directory under an unrelated title
   ("Timestalker (2024)") that the reaper lacked permission to remove
   caused the *whole run* to exit before ever reaching the actual convert
   queue — 10 minutes wasted on a full-library scan, zero files
   processed. The reaper's `rm` failure should warn and skip that one
   orphan rather than letting the failure propagate to a full script
   abort. Not yet fixed — needs the reaper's cleanup loop reviewed for
   unguarded failing commands under `set -e`, same class of issue as the
   `rc=0; cmd || rc=$?` pattern already applied elsewhere in the script.

3. **Library-wide audit for existing outputs with flagged-but-empty
   subtitle tracks — deferred, not started.** v5.0.33O/P/Q's
   `subtitle_stream_has_real_content()` filter only applies going forward
   (new encodes); it does not retroactively fix already-produced outputs
   in the library that may carry the same "flagged but empty" subtitle
   tracks the user originally reported ("a number of movies (sources and
   output) that have subtitles 'defined' but there is no actual content").
   No scope/priority decision made yet on whether/when to run a dedicated
   scan-and-remux pass across existing library outputs.

## Deferred from the v5.0.33R team review (2026-08-02)

1. **Cache subtitle-content-check results per run.** `build_real_subtitle_
   map_args()` re-runs the full per-stream ffprobe/ffmpeg checks on every
   call, and it's called once per final-output-producing attempt (the
   two-stage remux, plus a repeat on the x265 fallback if AV1 fails) --
   on a source with many subtitle tracks (up to 38 seen on real library
   files) this means dozens of ffprobe/ffmpeg passes run twice per title.
   Not a correctness bug (results are stable across attempts on the same
   unmodified source), just wasted work -- a per-run cache keyed on
   source path + stream index would remove the duplication.
2. **`record_stripped_subtitle()`'s dedup key is weak.** Keyed only on
   source path + subtitle stream index; safe for the normal repeated-
   encoder-attempt case this was built for, but not robust if the same
   pathname is reused with a different file underneath during a long run
   (unlikely but not impossible). Worst case is a stale-suppressed
   manifest line, not output corruption. A stronger key (source
   size/mtime, or an ffprobe stream signature) would close this.

## Deferred from the v5.0.33G E2E team review (2026-07-30)

Full team E2E review of the v5.0.33G release (7-way parallel section review
plus a consolidated independent-review pass) found and fixed several real bugs
(bare `mktemp -d`/`rm -rf`/`rm -f` abort risks, a `compare_shard_snapshots`
resume-bookkeeping bug, a subtitle-probe ambiguity gap, and an orphan
staged-name recognition gap for the new remux path — see CHANGELOG.md's
v5.0.33G entry for the full fixed list). Three items were deferred as
real-but-architectural, not spot-fixes:

- **`remux_copy_to_mkv()` is unbounded (uses `run_tracked_encoder`, not the
  timeout-wrapped `run_ffmpeg_remux`).** This is the SAME class of "silent
  hang" bug already fixed for CRF-search sample encodes in v5.0.33E, just
  in a different function. `remux_copy_to_mkv` is used by 3+ call sites
  (the pre-existing HEVC-in-MKV remux shortcut, the must-eliminate-format
  container-elimination shortcut, and the new v5.0.33G remux-floor
  fallback) — not something introduced by the v5.0.33G work, a pre-existing
  gap surfaced by reviewing it fresh. Fixing it isn't a simple swap:
  `run_tracked_encoder` provides heartbeat-based in-progress-flag touching
  (so other fleet hosts don't think a legitimately-long remux was
  abandoned), which `run_ffmpeg_remux`'s timeout-and-retry model doesn't
  have. Needs either a heartbeat-aware timeout wrapper, or accepting the
  loss of heartbeat protection for this specific operation (stream-copy
  remuxes are usually much faster than a real encode, so orphan-flag
  staleness may be less of a real risk here — needs judgment, not a rushed
  fix).
- **A finalized plain-`.mkv` remux (must_eliminate_remux_path output)
  relies on a non-fatal `VES_PROCESSED` tag write to avoid being rescanned
  as a fresh source on a future run.** If tagging fails (rare, but
  `write_ves_processed_tag` only warns, doesn't fail the job) or if
  validation timed out before `finalize_mkv_output` ran, the file could be
  requeued as an ordinary source next scan. Would need `is_derived_output`/
  `find_videos_under`'s exclusion logic extended to recognize a bare
  `.mkv` sitting next to a must-eliminate-format source as already-derived,
  not just `.AV1.mkv`/`.x265.mkv` suffixes.
- **Quick-scan validation (`inspect_existing_outputs_for_queue`'s
  `quick=true` mode) skips subtitle/audio/decode checks**, which is
  correct/intentional for the common case, but means a remux output whose
  full validation previously timed out specifically during subtitle
  checking could get permanently quick-accepted on a later scan without
  ever re-running the check that timed out. Same risk profile as the
  pre-existing AV1/x265 quick-scan path (not unique to the new remux
  floor), just newly surfaced by extending quick-scan to cover it too.

## Deferred from the v5.0.33E timeout-hardening fix (2026-07-29)

- **`ffmpeg_sample_encode()`'s sample encode is still unbound.** v5.0.33E
  fixed every short-sample-clip call site that used bare `run_ffmpeg`
  directly, but `ffmpeg_sample_encode()` goes through a different
  mechanism entirely (`run_tracked_encoder`: launches the command in the
  background, then a plain `wait` with no timeout at all), shared with the
  real multi-hour full-file encode path (which legitimately needs to stay
  unbound). This function encodes a short, already-locally-extracted
  sample clip — the same encoder class (SVT-AV1/x265) that caused the
  GruntBox2 crash this session — so it carries the same theoretical hang
  risk if an encoder worker thread dies uncleanly mid-sample-encode.
  Deliberately not fixed under time pressure: adding a timeout here needs
  a way to distinguish "this caller is doing a short sample" from "this
  caller is doing the real encode" inside a primitive shared by both,
  without risking a regression to the real-encode path (which several
  fleet machines legitimately run for 3-7+ hours). Worth a dedicated
  design pass — e.g. a `run_tracked_encoder_bounded` variant that accepts
  an optional timeout, defaulting to none (today's behavior) unless a
  caller opts in.

## Deferred from the v5.0.32X retry-on-timeout review (2026-07-27)

Two low-severity, real findings from independent review of `_run_timeout_retry()`
and the lowered `MKVALIDATOR_MAX_SIZE_BYTES`, deferred rather than fixed
under time pressure since neither affects the default path:

- **`VALIDATION_TIMEOUT_RETRIES` isn't bounds-checked against integer
  overflow.** The current validation rejects unset/non-numeric values
  (falls back to 2) but not an absurdly large digit string, which could
  make the `-gt` comparison in `_run_timeout_retry` emit an `integer
  expected` error under `set -e`. Only reachable via deliberate
  misconfiguration (`VALIDATION_TIMEOUT_RETRIES` is an env override, not
  user-facing). Worth capping to a sane max (e.g. reject anything over
  some reasonable ceiling like 20) next time this function is touched.
- **The mkvalidator structure-cache doesn't distinguish an EBML-only pass
  from a full mkvalidator pass.** Since `MKVALIDATOR_MAX_SIZE_BYTES` was
  lowered to 2GiB, files in the 2-5GB range now commonly get EBML-only
  validation, but the cache entry looks identical to a file that got the
  full mkvalidator treatment (cache key is just `size|mtime` + path). Only
  matters if `CONVERT_MKVALIDATOR_MAX_SIZE` is ever raised again and an
  operator expects previously-EBML-only-validated files to get re-checked
  with full mkvalidator — they won't, since the cache will report them as
  already validated. Fix would be encoding which validation level was used
  into the cache entry itself.

## NFS contention pattern refined — first Movies/TV test (2026-07-26)

The 51-file mixed-content test (first non-anime round this session) hit
`mkvalidator`/audio-track "possible stalled mount" timeouts on 4 of 8
machines (docm, PRINCE, MacFedora, GruntVM) shortly after simultaneous
launch. Initially assumed to be the same benign pattern already documented
below (GruntVM's earlier confirmed-benign contention) — the user correctly
pushed back ("this was not happening before") and a deeper investigation
found a real, more specific cause worth recording:

- Manually reproducing one failure (`Sex Explained S01E01.mkv` on docm)
  with the real 120s timeout hung the **full** timeout **twice in a row**
  — a materially different signature than the earlier GruntVM case, which
  completed (just slowly, ~96s) every time it was manually reproduced.
- Isolating further: `stat`, a 1MB `head` read, and `ffprobe` all completed
  on the *exact same file* in under 0.1s while `mkvalidator` was hanging.
  Checking the hung process directly (`ps -o wchan`, `/proc/pid/fdinfo`)
  showed it genuinely in `D` state (`folio_wait_bit_common`, real
  uninterruptible I/O wait) with its read position slowly advancing — not
  an infinite loop or parser bug, but a real, severe, per-request NFS
  stall specific to `mkvalidator`'s seek-heavy whole-file structural walk
  (it reads near-EOF for Cues/Tags, unlike a quick header-only ffprobe
  call).
- A third manual attempt on the same file, no timeout, completed cleanly
  in 20 seconds and confirmed the file valid. So the underlying cause is
  genuinely intermittent/bursty NFS latency, not a corrupt file or a
  mkvalidator bug.
- Best-understood root cause: this is the **first time this session** all
  8 machines launched simultaneously against **fresh, large (1-5GB)
  movie/TV files** — every prior round was anime-only with much smaller
  (~300-700MB) episodes, often already cache-warmed from repeated re-runs
  across the day. The simultaneous multi-GB cold-read burst against the
  shared NAS is a heavier concurrent load than anything tested before,
  and appears to produce sharper, more volatile stalls than the steadier
  "somewhat slow under load" pattern documented for GruntVM below.

**Update — the first retry attempt also failed, and it wasn't contention
easing that was needed (2026-07-26, same day):** after the 4 affected
machines (docm, PRINCE, MacFedora, GruntVM) finished their original runs,
they were retried on the assumption that "most of the fleet is done now,
load has eased." All 4 failed again, on different files than the first
round, at the same ~120s timeout signature. Investigating why revealed the
real, more precise cause: **Crystalight and GruntBox2 were still actively
mid-encode the entire time**, each pulling sustained multi-hour sequential
reads directly off the same shared NAS (Crystalight's `REC² (2009)` x265
encode ran 2+ continuous hours; GruntBox2's `Cunk on Earth` episodes each
take a similarly long time on its weak hardware). So "most machines
finished" was never the same thing as "the NAS is actually idle" — two
long-running heavy jobs are enough on their own to starve another
machine's seek-heavy `mkvalidator` validation, regardless of whether a
launch was staggered or simultaneous. The "simultaneous launch burst"
framing above was real but incomplete; **sustained overlapping heavy I/O
from even just 1-2 machines is the actual trigger**, not launch timing
specifically.

**Update — the real root cause, found by checking the NAS itself
(2026-07-26, same day):** a third retry against a genuinely idle fleet
(Crystalight fully idle, GruntBox2 down to negligible NFS footprint)
**still failed**, disproving the fleet-contention theory entirely. Checked
whether it was specific to the BigMomma/BabyBear shares (both new to this
session) vs BigPoppa (used all session without incident) — but a
similarly-large file on BigPoppa timed out at the same moment, ruling that
out too. The real cause, found by SSH'ing directly into the NAS
(`admin@10.0.1.103`, TrueNAS SCALE, credentials from the user):
`zpool status` showed **BigMomma's scrub finished at 16:17 PDT and
BigPoppa's finished at 18:55 PDT — both during this test's window**. A ZFS
scrub reads every block on every disk and is extremely I/O-intensive,
producing exactly the widespread, unpredictable, large-file-biased latency
spikes seen all day, completely independent of anything the fleet clients
were doing. Once both scrubs were confirmed complete (`zpool iostat`
showing the pools quiet), the retry succeeded. Full diagnostic writeup in
memory (`project_nas_scrub_validation_timeout_root_cause`).

**Correction — the scrub theory was also wrong (2026-07-26, same day,
same investigation):** a FOURTH retry, launched only after directly
confirming via `zpool status`/`iostat` that both scrubs had completed and
the pools were quiet, **still failed on the exact same specific files as
every prior retry** (Titane always fails; Newtopia always fails on
S01E02/S01E07/S01E03; The Trunk always fails on S01E02/S01E04/S01E01 —
identical files, identical order, across all 4 attempts). That
reproducibility across every environmental condition tried (busy fleet,
idle fleet, mid-scrub, post-scrub) is the tell: this was never a transient
event at all.

Ran `mkvalidator` unconstrained (no timeout) directly against one of the
chronically-failing files (`The Trunk - S01E01 - Episode 1.mkv`, 2.59GB, on
GruntVM) and let it run to genuine completion: it took **roughly 10+
minutes** and correctly reported the file valid. Confirmed via `/proc/pid/
fdinfo` across multiple checks that it was continuously making real (if
slow, ~1.6MB/s) read progress the whole time — not stuck, just
fundamentally slow for this file size over this NFS path.

**The real root cause**: `VALIDATION_TIMEOUT_SECS=120` was sized for
anime's typical 300-700MB episodes and is simply insufficient for the
multi-GB movie/TV files this test introduced for the first time this
session. The NAS scrubs and fleet-load investigations above were real
observations but coincidental, not causal — they happened to overlap with
some of the failures in time without actually being why the same specific
large files failed every single retry regardless of environmental state.

**How to apply**: `VALIDATION_TIMEOUT_SECS` (and the equivalent audio-track-
check timeout) need to scale with source file size rather than stay a flat
120s, similar to the existing size-tiered pattern already used for
`effective_upscale_overshoot_pct()`. A fixed bump (e.g. to 300s) would
still fail on files like this one that need 10+ minutes; a fixed bump large
enough to cover the worst case (15+ minutes) risks masking a genuinely
stuck/hung validator on smaller files that should fail fast. Scaling by
file size is the right shape of fix.

**Done — v5.0.32W (size scaling) and v5.0.32X (retry-on-timeout + lowered
mkvalidator ceiling)**, see CHANGELOG.md for both. Even the size-scaled
timeout alone left occasional residual failures on the largest files, since
real NFS timing variance means the same file can take 2x+ longer on one
attempt than the next — no fixed formula eliminates that. v5.0.32X's retry-
on-timeout (specifically on rc=124, never on genuine structural failure)
plus lowering `MKVALIDATOR_MAX_SIZE_BYTES` to 2GiB (so the files in the
2-5GB range where this variance showed up most just skip the slow full
scan) together close the gap.

**Diagnostic lesson for next time**: don't trust "the same specific files
keep failing" as evidence of a stable *external* cause (scrub, contention,
a bad NFS mount) without first checking whether those same files are just
disproportionately large — reproducibility across changing environmental
conditions is actually the signature of a deterministic client-side
threshold problem, not an environmental one. This cost two extra retry
cycles (and an unnecessary NAS deep-dive) before landing on the real
answer.

## Crystalight's RAM disk is too small for movie-scale content (2026-07-26)

While investigating why the fleet-wide retry kept failing (see the NFS
contention section above), found a second, distinct, real contributor:
Crystalight's `/Volumes/ConvertRAMDisk` is only **2.4GB total**. During the
mixed-content test's `REC² (2009)` job, the AV1 candidate encode staged
successfully on the ramdisk, but the subsequent x265 fallback attempt
(likely triggered because the AV1 candidate didn't beat the size/quality
target on this grain-heavy found-footage source) staged directly on the
NFS-mounted destination path instead — confirmed by checking the ramdisk
was completely empty (nothing occupying it) at the time, meaning the
script's capacity check correctly predicted the candidate output (approaching
or exceeding 2GB) wouldn't fit and safely fell back rather than overflowing
the ramdisk. This is the intended fallback behavior, not a bug — but it has
a real cost: writing a multi-GB output continuously over NFS instead of to
local RAM is both much slower for that individual job (this encode ran
3.5+ hours for what should be a much shorter x265 pass) and keeps the
shared NAS under sustained write load the whole time, contributing directly
to the mkvalidator-timeout contention seen on other machines during this
test.

This never surfaced during any of this session's anime-only testing because
anime episodes are typically 300-700MB — comfortably under the 2.4GB
ceiling. Movies routinely produce 1-3GB+ candidate outputs, so this is a
**real capacity gap that will recur** on every movie encode on Crystalight
going forward, not a one-off.

**How to apply**: resize Crystalight's RAM disk to comfortably exceed the
largest realistic movie candidate size (headroom for both an AV1 and an
x265 candidate to coexist if a bake-off or fallback needs both, plus normal
working overhead — 8-16GB would be a reasonable target, subject to how much
RAM Crystalight can spare from encoding itself on an M2 Max). This is a
system-level change (recreating the APFS RAM-backed volume) — deferred to
the user's judgment on sizing and timing rather than done unilaterally
during this test.

**Done 2026-07-26**: resized from 2.4GB to 12GB (`hdiutil attach -nomount
ram://25165824` + `diskutil eraseVolume APFS ConvertRAMDisk`). Verified
nothing but Spotlight's `mds` had the old volume open before ejecting it
(no active job was using it at the time) — no data lost. **Found in the
process: this ramdisk has no persistence mechanism** (no LaunchDaemon/
LaunchAgent recreates it) — it was originally created manually at some
point and would silently vanish on Crystalight's next reboot, at which
point the script would presumably fall back to non-ramdisk staging with no
obvious alert. Worth adding a login/boot LaunchDaemon that recreates the
12GB ramdisk automatically, matching the self-healing pattern already used
for PRINCE/GruntBox2's WSL2 mount recovery — not yet done.

## Deferred findings from the pre-Movies/TV-test team review (2026-07-26)

A 3-way independent review ahead of the first non-anime
(Movies/TV) confidence test this session found several real issues in the
movies/classic/vintage/mtv/vtv profile paths. One (the `process_video()`
silent-success bug on profile-detection failure) was fixed immediately in
v5.0.32V since it's a general safety-net gap. These four were checked
against the real library/code and deliberately deferred rather than fixed
under time pressure — full triage detail in `CHANGELOG.md`'s v5.0.32V entry:

- **HandBrake HDR handling is weaker than the ffmpeg path**: `handbrake_
  append_color_metadata()` tags HLG sources with PQ transfer characteristics,
  and `load_encoder_profile()`'s HandBrake branches never pass `hdr=true`
  into `profile_fixed_crf()` (SDR fixed CRFs get used for HDR discs). Real
  bugs, but the fleet currently only uses HandBrake for disc sources and no
  machine is processing any — fix before disc ingestion is ever turned on.
- **`profile_fixed_crf()` hardcodes numeric CRF literals** instead of
  referencing the declared `FIXED_CRF_SVT_*`/`FIXED_CRF_X265_*` variables.
  Currently a DRY nit with zero behavioral effect (values match, and those
  variables aren't exposed via any override flag today) — worth cleaning up
  next time that function is touched for another reason.
- **Case order in `detect_profile_for_path()`** checks `*/Animation/*`
  before `*/Movies/*/Classic|Vintage/*`, so a hypothetical `Movies/<Lang>/
  Classic/Animation/...` folder would misroute to `wanime`. No such nested
  structure exists on the NAS today (confirmed directly) — a robustness
  fix for if the library structure ever changes, not urgent.
- **`anime_title_year()`'s year regex could theoretically match a
  parenthesized resolution tag** like `(1080)` and misroute a title to the
  classic-anime profile. Only one of three reviewers flagged this;
  not reproduced against real data. Worth a closer look (grep the anime
  library for any `(1080)`/`(2160)`-style tags in a folder/file name) next
  time anime-profile work is being done, but not confirmed as live.

## Accepted scope gaps (from the 2026-07-24 crash-safety review loop)

A full end-to-end team review plus two follow-up
verification passes found and fixed a critical cross-host orphan-reaper bug,
3 NFS-shared-file races, and several other real issues (see CHANGELOG.md for
the full list once committed). Three items were deliberately left unfixed
rather than risk shipping something worse than the original gap:

1. **Same-host concurrent double-invocation can still race on the per-host
   resume-state file.** The per-host filename fix (embedding hostname in
   `convert-v4.<host>.state`/`.queue`/`.shards`) closes the *cross-host*
   race, which is what actually happens in normal fleet operation. Two
   *separate* script invocations on the *same* host against the *same*
   `JOB_ROOT` at the same time (a user/cron double-launch mistake, not a
   fleet-standard pattern) would still silently overwrite each other's
   resume state. A proper fix needs a run-lifetime lock, which would have to
   chain into the existing `EXIT` trap set (`ramdisk_job_teardown` already
   registers its own `trap ... EXIT`, which a second one would silently
   clobber rather than compose with) -- a real but riskier change, deferred
   rather than rushed.

2. **The season-level shrink heuristic is process-local**, not fleet-shared.
   If one TV season were ever split across multiple fleet hosts scanning
   concurrently, no single host would see the complete shrink/skip ratio
   for that season. Not applicable to the current per-show-per-machine test
   assignment strategy; would need a shared, locked, cross-host season-state
   file (similar to the done-log/mkv-structure-cache fix) to address for a
   true full-library unattended run.

3. **Derived-AV1 (oversized `.AV1.mkv` re-check) sample-skips are
   deliberately excluded from the season-retry cohort.** A first attempt to
   enroll them was reverted after review found it would silently no-op
   (the existing-output shortcut in `try_av1_convert`/`try_x265_convert`
   only checks `FORCE_REPROCESS_TAGGED`, not `SEASON_RETRY_IN_PROGRESS`) and
   mis-route to an x265-only forced retry (`season_retry_pass` routes
   purely on the stored file's current codec, and the original pre-
   conversion sibling stored for this cohort is often not AV1). Fixing this
   properly needs changes to `season_retry_pass`'s own routing/bypass
   logic, not just the enrollment call site -- left as documented accepted
   scope rather than a broken "fix."

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

4. ~~GruntVM and AI-PROCESSOR still use the old flat NFS mount convention~~
   **Fixed 2026-07-24.** Both machines' `/etc/fstab` changed from
   `10.0.1.103:/mnt/<Share>/Media` (flat, mounted directly at
   `/mnt/<Share>`) to bare `10.0.1.103:/mnt/<Share>` — matching the
   nested convention every other Linux/WSL2 fleet machine already uses
   (`/mnt/<Share>/Media/...` resolves via NFSv4's unified pseudo-filesystem,
   same mechanism PRINCE/GruntBox2 rely on). Old fstab backed up first
   (`/etc/fstab.bak-20260724`). AI-PROCESSOR's separate `StockLake` mount
   (different source IP, `10.0.2.101`, unrelated export) was deliberately
   left untouched per explicit instruction. Verified on both via `ls
   /mnt/BigPoppa/Media` showing real content post-remount. One real
   complication on AI-PROCESSOR: the old flat mount wouldn't `umount` —
   `fuser -vm` showed it was genuinely busy, not just mount-stacking: a
   live confidence-test job (VMAF comparison, `ffmpeg ... libvmaf`, PID
   1319172, ~1.5hr in) had files open through it. Fixed with `umount -l`
   (lazy unmount) — detaches the stale mount from the namespace
   immediately without disturbing already-open file handles, confirmed
   the live job kept running normally (`ps -p` before/after, same PID,
   uninterrupted). **Every script invocation on these two machines can
   now use the same nested path convention as the rest of the fleet** —
   the flat-path exception above no longer applies.

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

## WSL2 NFS auto-mount unreliable across restarts (2026-07-25 — root-caused and fixed)

Discovered when GruntBox2's WSL2 instance restarted unattended (~7h45m
gap in its journal, abrupt stop with no shutdown sequence, no OOM/panic —
almost certainly the Windows host itself sleeping or rebooting, not
anything wrong with the script or WSL2/the custom kernel). Its confidence-
test job died silently and all three NFS mounts were gone (`df` showed
nothing) — the folder path simply stopped existing until manually
remounted.

**Root cause, confirmed via `journalctl` on both WSL2 machines — two
distinct failure modes, same end result:**
- **PRINCE**: `remote-fs.target` genuinely attempts to start at boot but
  fails via a real race — WSL2's own very-early `/etc/fstab` pass runs
  *before* `systemd-modules-load` finishes loading the `nfs`/`nfsv4`
  kernel modules (fails immediately, "No such device"), then systemd's
  own generated mount units retry afterward (modules now loaded) but
  **time out after 90s** — which lines up with the `resvport` block found
  and fixed earlier that same session (this particular boot predated that
  fstab fix).
- **GruntBox2**: nothing attempted the mount at all — no fstab processing,
  no mount-unit activity in the boot journal whatsoever. `remote-fs.target`
  never got pulled in. A `network-online.target` timestamp claiming
  "active since" a time *before* this boot even started is a strong clue
  this was a host **sleep** (not a full power cycle) leaving WSL2's systemd
  dependency graph confused rather than doing a clean cold boot.

**The critical shared behavior: once a mount unit fails once, systemd
does not retry it for the rest of that boot** — so regardless of which
specific race fires, the practical result is identical: every WSL2
restart (sleep, host reboot, crash, or a manual `wsl --shutdown`)
currently requires a manual `mount -a` (and often a `cachefilesd
reset-failed`, matching the known cosmetic LSB-exit-code quirk) before
the machine can see its media library again.

**Fix: a small self-healing systemd unit**, `ves-mount-recovery.service`
(`ExecStart=/usr/local/sbin/ves-mount-recovery.sh`, `WantedBy=multi-
user.target`, `After=network-online.target cachefilesd.service`) —
unconditionally retries `systemctl reset-failed cachefilesd` + `mount -a`
up to 6 times with a 5s backoff, checking all three mountpoints via
`mountpoint -q`, logging the outcome via `logger -t ves-mount-recovery`
(check with `journalctl -t ves-mount-recovery`). Deployed and functionally
tested (manual `systemctl start`, confirmed active) on both PRINCE and
GruntBox2 — **not yet verified across a real reboot/sleep cycle on either
machine**, which should be done opportunistically next time either
restarts. Not yet deployed to docm/MacFedora/Plex/GruntVM/AI-PROCESSOR/
Crystalight — those aren't WSL2 and haven't shown this failure mode, but
the fix is cheap/idempotent insurance worth considering for the rest of
the fleet too.

## PRINCE full rebuild (2026-07-24 — post-fs-cache filesystem corruption)

PRINCE's WSL2 root filesystem became corrupted after this session's repeated
"Catastrophic failure" WSL restarts (compounded by the Windows C: drive
being nearly full — 13GB free — at the time), surfaced when the
2026-07-24 confidence-test job reported "successfully completed" 12/12
episodes but every single one had actually hit "SKIP: x265 sample test
failed" — zero real encodes happened. Root-caused via direct reproduction:
`ffmpeg` crashed with a **Bus error (SIGBUS, exit 135)** decoding *any* MKV,
including a synthetic file it had just encoded itself seconds earlier —
ruling out a content-specific issue. Filesystem-level `Input/output error`
reading unrelated binaries (`ffmpeg`, `lscpu`, `dmesg`, `mount`, `sudo`
itself) confirmed real ext4 corruption inside the `.vhdx`, not a
CPU/SIMD/content bug (a GruntBox2 same-kernel-version comparison ruled that
out first).

**Fix: full rebuild, not repair.** Given the disk was disposable (20G used,
no media — all media is NFS, not local) and C: was nearly full anyway,
`wsl --unregister Ubuntu` + fresh install directly on D: (500GB free)
was faster and safer than fsck-ing a nearly-full disk. The custom kernel
survived untouched (it's a global `.wslconfig` setting, not part of the
distro). Full re-provisioning from that fresh distro:

- `openssh-server`, `nfs-common`, `cachefilesd`, `curl`, `xz-utils`,
  `ca-certificates`, `mkvtoolnix` via apt; `ffmpeg`/`ffprobe` via a fresh
  BtbN static build (`ffmpeg-master-latest-linux64-gpl.tar.xz`); `ab-av1`
  v0.11.4 via its GitHub release (correct asset is `.tar.zst`/`musl`, not
  `.tar.gz`/`gnu` — the obvious guessed URL 404s); `handbrake-cli` via apt.
- `/etc/modules-load.d/cachefiles.conf` (`cachefiles`, `nfs`, `nfsv4`) and
  `RUN=yes` in `/etc/default/cachefilesd` — **but the custom kernel's
  `/lib/modules/<version>/` tree does NOT survive a distro rebuild** (it
  lives in the distro's own root filesystem, not the shared `.wslconfig`
  kernel image) — re-transferred fresh from GruntBox2 (881MB tarball,
  checksum-verified at every hop: GruntBox2 → sandbox → PRINCE, all three
  matched). `/lib/modules` itself didn't even exist yet on the fresh distro
  (no distro kernel package ever installed inside WSL) — had to `mkdir -p`
  it before extracting.
- `~/VES/PRINCE/script/convert-v5.0.32S.sh` redeployed from the canonical
  copy (checksum-verified match), following the same `~/VES/<host>/script/`
  + `~/VES/<host>/logs/` + `convert-current.target` convention already in
  use on GruntBox2.
- `nvidia-smi` (RTX 4070 Laptop GPU, NVENC AV1 confirmed working) lives at
  `/usr/lib/wsl/lib/nvidia-smi` on a fresh WSL2 GPU-passthrough install but
  isn't on `PATH` by default — added via `/etc/profile.d/wsl-nvidia-path.sh`.
- sshd: `MaxSessions 50`, `MaxStartups 50:30:100`, `ClientAliveInterval 60`,
  `ClientAliveCountMax 120` reapplied (no prior record of the original
  values existed in CHANGELOG/ROADMAP/memory — a discipline gap now closed
  by this entry existing). `Port 2022` already present in the base
  `/etc/ssh/sshd_config` (this was mis-read as `Port 22` mid-session by
  comparing against the wrong host's config — always double check which
  machine's file is on screen).

**Two real networking bugs found and fixed on the fresh install, in this
order:**

1. **A misleading GRO red herring.** `dmesg` showed "Driver has suspect GRO
   implementation, TCP performance may be compromised" on `eth0` — looked
   like the obvious explanation for the session's earlier intermittent
   SSH connectivity (TCP handshakes randomly stalling in `SYN-SENT` despite
   ICMP/ARP working fine, across dozens of retries). Disabling
   `gro`/`gso`/`tso` via `ethtool -K eth0` did **not** fix the actual NFS
   mount hang tested afterward — this was a genuine kernel warning, but not
   the cause of either symptom. Don't chase this again if it recurs; it
   didn't correlate with either bug below.
2. **The real cause: NFS's default `resvport` (privileged source port
   <1024) gets silently blocked** on this fresh install, while normal
   high-port connections (SSH, a plain `/dev/tcp` bash test) work fine —
   this is almost certainly also what caused the earlier SSH connectivity
   saga (intermittent success was likely luck of ephemeral port selection
   landing above/below some threshold, not genuine flakiness). Confirmed
   by testing `mount -t nfs4 ... 10.0.1.103:/mnt/BigMomma/Media
   /mnt/testmount` directly: hung indefinitely with default options,
   `-o noresvport` mounted instantly with real data visible. Fixed
   permanently by adding `noresvport` to all three NFS lines in
   `/etc/fstab` (`fsc,noresvport` — order matters only cosmetically).
   **If PRINCE (or any future fresh WSL2 install on this fleet) ever shows
   NFS mounts hanging while `showmount -e`/`rpcinfo -p`/ICMP all work fine
   against the server, check `noresvport` first before anything else.**

Final verification: `ffmpeg` decode of a synthetic file (exit 0, no Bus
error) **and** the exact real-fleet sample-clip-extraction command against
`A Certain Scientific Accelerator S01E06` that previously crashed all
12/12 episodes (exit 0, real 2MB clip produced). PRINCE is confirmed fully
working end to end as of this entry; the 2026-07-24 confidence-test job on
PRINCE needs to be relaunched from scratch (the earlier "successful"
12/12 result was entirely false — zero real encodes occurred).

**Also restored: PRINCE's rsync-daemon fleet-distribution setup**, which
the rebuild wiped along with everything else. Fleet-wide rollout status
turned out to be much further along than this conversation initially
assumed — `docm`, Plex, MacFedora, GruntVM, AI-PROCESSOR, and Crystalight
all already run the Phase 0 `rsyncd` daemon (`ves-deploy` write module +
`ves-logs` read-only module, per `orchestration/tasks/phase0-rsync-setup.md`);
only GruntBox2 and PRINCE were missing it (GruntBox2's absence is a
pre-existing, separately-tracked gap, not something this session touched).
Redeployed on PRINCE from the pre-generated
`orchestration/results/phase0-fleet-PRINCE/` config, substituting the real
control-host CIDR (`10.0.0.100/32`) for the `__DOCM_CONTROL_IP_CIDR__`
placeholder. One real gap found and fixed along the way: **PRINCE never had
the fleet's unified `worker` system account** (used by every other Linux/
WSL2 machine — including personal-login machines like MacFedora — to own
the `/home/worker/VES/<host>/` tree, distinct from whatever account SSH
login actually uses). Created it (`useradd -m -s /usr/sbin/nologin worker`),
relocated the already-deployed script from `/home/docm/VES/PRINCE/` to
`/home/worker/VES/PRINCE/`, and re-owned it — the pre-generated `rsyncd.conf`
already correctly pointed at the `worker`-owned path, it just didn't exist
yet under that user. Verified end to end: both modules list correctly via
`rsync --password-file=... --list-only rsync://<user>@10.0.0.101:873/
ves-<module>/` from the control host. Generated `vesdeploy`/`veslogs`
credentials were shared out-of-band (not committed) and stored client-side
at `~/.config/ves-secrets/PRINCE-{vesdeploy,veslogs}.pw` on the control
host, matching the `CLIENT_DEPLOY_PASSWORD_FILE`/`CLIENT_LOGS_PASSWORD_FILE`
convention `generate-rsync-secrets.sh` already anticipated.

## PRINCE feature-parity audit — 2026-07-24 (post-rebuild)

Full comparison against GruntBox2 (same WSL2 platform), MacFedora (same
personal-account-plus-service-`worker`-account model), and docm (control
host / fleet standard reference), to confirm PRINCE is a genuine full
member of the fleet after its rebuild, not just "ffmpeg works again":

- **SVT-AV1 encoder version matches exactly** across docm, PRINCE, and
  GruntBox2 — `v4.1.0-279-gd3c4cb394` on all three, despite the wrapping
  ffmpeg nightly builds having different build dates (BtbN pins the same
  SVT-AV1 source commit across nightlies). Satisfies the fleet-wide
  SVT-AV1 version constant with no action needed.
- **sshd session-concurrency settings match the actual fleet standard**
  (confirmed via docm's own `/etc/ssh/sshd_config`: `Port 2022`,
  `MaxSessions 50`, `MaxStartups 50:30:100`) — PRINCE's settings, applied
  earlier this session, are correct. GruntBox2, by contrast, is still on
  stock defaults (`Port 22`, no `MaxSessions`/`MaxStartups` override) —
  a **pre-existing GruntBox2 gap**, not something this audit was scoped to
  fix, but worth closing in a future pass for real fleet-wide consistency.
- **`worker` group membership**: added `docm` as a supplementary member of
  PRINCE's `worker` group (`sudo usermod -aG worker docm`), matching the
  cross-membership pattern MacFedora already uses (`worker`'s groups
  include `localuser2`) — lets the interactive account browse/manage the
  `worker`-owned `~/VES/PRINCE/` tree without needing `sudo` for routine
  read access.
- **`cachefilesd` cache directory**: confirmed default (`/var/cache/fscache`),
  matching docm/GruntBox2's convention (not a custom location like
  MacFedora's `/mnt/DATA/fscache` — that was a deliberate choice specific
  to MacFedora's small OS disk, doesn't apply to PRINCE's WSL2 virtual
  disk which has ample room).
- **No fastfetch/neofetch banner risk** — confirmed absent from PRINCE's
  `/etc/bashrc`/`~/.bashrc`/profile.d entirely, and moot regardless since
  the `worker` account has `/usr/sbin/nologin` as its shell (can never get
  an interactive session that could trigger one).
- **No cron/automation timers beyond stock Ubuntu system timers** (12
  standard timers — `apt-daily`, `logrotate`, `man-db`, etc.) — matches
  GruntBox2 and the rest of the fleet; the script is still invoked
  manually everywhere, no machine has cron-driven automation yet.
- Tool inventory (ffmpeg/mkvmerge/HandBrakeCLI/ab-av1/nvidia-smi/
  cachefilesd/NFS mounts/rsyncd/`~/VES/PRINCE/` script deployment) — all
  covered in the "PRINCE full rebuild" section above, all verified present
  and working.

**Conclusion: PRINCE is a fully verified, feature-complete fleet member**
as of this audit — no remaining gaps found specific to PRINCE. The two
items surfaced (GruntBox2's sshd hardening gap, and GruntBox2/PRINCE both
lacking `rsyncd` before this session) are pre-existing gaps on *other*
machines, tracked here for a future pass rather than blocking this audit's
conclusion.

## Full fleet log audit — 2026-07-25 (all 8 machines, post-confidence-test)

Requested explicitly: review every machine's `convert-v4.log` in full (not
just the tail) for silent failures, not just "did it finish." Results:

- **docm, MacFedora, AI-PROCESSOR, PRINCE (2nd run)**: completely clean.
  docm's high "Job failed" count (33 of 48) is 100% legitimate size-
  guardrail rejections on already-efficient h264 content — verified by
  reading the actual log lines, each properly tagged and original
  preserved, not a bug.
- **Plex**: matches the already-known "A Centaur's Life (2017)" corruption
  (6 episodes, genuinely bad source, correctly deferred) — not new.
- **GruntVM — real diagnostic finding, not a bug.** 12 of 23 files hit
  `mkvalidator timed out (possible stalled mount)` and were safely skipped
  (not flagged bad, no data touched) but never actually evaluated.
  Root-caused by manually reproducing the exact `mkvalidator` invocation
  against one of the affected files with the script's real
  `VALIDATION_TIMEOUT_SECS` (120s, not the 15s I first tried by mistake):
  it completed successfully in ~96s, with only ~1.2s of actual CPU time —
  i.e., genuinely valid, just slow, almost entirely I/O wait. This strongly
  suggests real NFS contention from the 4-5 other fleet machines hammering
  the same NAS concurrently during that run, not a GruntVM-specific issue
  or file corruption. Confirmed by relaunching once most other machines had
  finished: all 12 files succeeded cleanly with real VMAF-tagged results on
  the very next attempt (well, the attempt after that — the immediate retry
  still hit 4/12 timeouts before contention fully cleared; a second retry
  got all 4 remaining ones clean). **Takeaway for future confidence tests:**
  if `mkvalidator`/ffprobe/EBML timeouts cluster heavily on one machine
  during a fleet-wide simultaneous launch, suspect NFS server contention
  from the other 7 machines before suspecting that machine's mount/hardware
  specifically — a manual reproduction with the script's actual configured
  timeout (not a shorter one for convenience) is the fastest way to tell
  "genuinely too slow under current load" from "actually broken."
- **Crystalight — led directly to the v5.0.32T fix.** One episode (S01E02)
  had both a corrupted source (repaired successfully via the existing
  remux-repair path) and a corrupted re-encoded output (correctly
  discarded, original preserved) — but the batch summary counted it in
  neither "processed" nor "skipped," because `process_video()` was
  discarding the real failure return code. See the v5.0.32T changelog
  entry for the full fix; this log audit is what surfaced it.

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
