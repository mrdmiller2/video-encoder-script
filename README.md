# Video Encoder script

I started this project back in 2024 because my video libraries were getting too large (can't keep buying drives) an I wanted uniformity with the file formats.. (over 10 years in collecting).. so I wanted a way to convert and let it run. HandbrakeCLI does a great job at the conversion but it takes too long to put things in batches.. And I like my data organized where possible.. 

Hence the start of this little project.  It converts, organizes, strips out the old junk metadata (we get things frm "places" and don't want plex or other things to show that, so at the end, you have a nice clean AV1 file or a x265 file.. whichever works best and provides the best size amount. Its been my experience that not every conversion will yield results.. so I put in some logic that if the file is larger, then try as a x265 (if doing AV1). 

This script is portable (because I often have my windows laptop, mac, and linux machines running on this, and had to create like 3 or 6 versions (some for anime, some for flatpack versions of handbrake, some for regular movies and tv shows).. so this script tries to unify them all into an uber script. (the original sources are in the genesis folder to cover the use case specific ones). 

Bash library organizer and batch transcoder for large home-media trees. Targets **MKV + AV1** (kept when not more than **20% larger** than the source) with **x265** fallback, optional **ISO/Blu-ray** disc handling, and **sharded** directory scans for multi-thousand-file libraries.

**Current release:** `convert-v5.0.19.sh` (v5.0.19) — see [What's new in v5](#whats-new-in-v5)

## Logic flow

How a single library folder moves through the pipeline — finding, evaluation, encoding, organization:

![convert-v5 signal flow: find, evaluate, encode, organize](docs/convert-v5-signal-flow.png)

## About this project

I started this project back in 2024 because my video libraries were getting too large — I can't keep buying drives — and I wanted uniformity in file formats. After more than ten years of collecting, I needed a way to convert and let it run. HandBrakeCLI does a great job at conversion, but it takes too long to batch things by hand. And I like my data organized where possible.

Hence this little project. It converts, organizes, and strips out old junk metadata. We get things from "places" and don't want Plex or other apps surfacing that, so at the end you have a nice clean AV1 file or an x265 file — whichever works best and gives the best size. It has been my experience that not every conversion yields good results, so I added logic: if the AV1 output is larger than the source, try x265 instead.

The script is portable because I often have my Windows laptop, Mac, and Linux machines working on the same libraries. Over time that meant three or six separate scripts — some for anime, some for Flatpak HandBrake, some for regular movies and TV shows. This script tries to unify them into one uber-script. The original use-case-specific sources live in the [`genesis/`](genesis/) folder.

## What's new in v5

v5 replaces fixed-quality encoding with a **per-title quality floor**: instead of encoding
everything at one CQ and keeping whatever comes out, each title is sampled, and the encoder
searches for the **highest CRF that still meets a VMAF target** — so easy content (sitcoms,
clean digital sources) gets far smaller files, and hard content (grain, action) gets *more*
bits than v4 gave it. Measured against v4's fixed CQ 26, that setting scored roughly
VMAF-NEG 92.6 on typical sources; v5's default floor is **94.0** — higher quality *and*
smaller average size across a library.

- **ffmpeg encode engine** (libsvtav1 / libx265) for files; HandBrake remains for ISO/BDMV
  disc sources and via `--engine handbrake`.
- **VMAF-targeted CRF search**, three-tier by machine capability:
  1. [`ab-av1`](https://github.com/alexheretic/ab-av1) if installed (fastest search)
  2. internal sample-based search using ffmpeg's `libvmaf`
  3. fixed CRFs (v4-equivalent) when the ffmpeg build lacks libvmaf
- **Models per content class**: NEG model (resistant to sharpening/enhancement gaming) for
  SDR movies/TV and anime; the 4K model for UHD sources (`--vmaf-target-4k`, default 95).
- **HDR handled conservatively**: VMAF is unreliable on PQ/HLG, so HDR titles use a fixed
  conservative CRF, and HDR10 static metadata (mastering display, MaxCLL/FALL) is carried
  into the output.
- **Dolby Vision is stripped to plain HDR10** (Plex-first compatibility, VLC second):
  profiles 7/8 keep their HDR10 base layer + static metadata (RPU/EL dropped);
  profile 5 (no HDR10 base) is converted via `libplacebo`; if libplacebo is missing the
  file is flagged for human review instead of producing broken colors.
- **Functional hardware detection**: every candidate encoder (NVENC, QSV, VAAPI, AMF,
  VideoToolbox) is verified with a 1-second test encode — per-codec, per-GPU. A box with
  mixed GPUs (e.g. an Ada/Blackwell card plus an older Ampere card) gets AV1 NVENC only
  where it actually works. `--prefer-hw` opts into hardware encoding (speed over size,
  fixed quality — no VMAF search).
- **Mount audit**: at startup the library path's NFS/CIFS mount options are checked and
  suboptimal settings (e.g. `soft`, small `rsize/wsize`, missing `nconnect`) produce
  advisory recommendations.
- Everything else — organize, sharding, resume, validation, track labeling, size-reject
  safety gates, x265 fallback — carries over from v4.0.52.

New flags: `--engine auto|ffmpeg|handbrake`, `--vmaf-target N`, `--vmaf-target-4k N`,
`--vmaf-samples N`, `--no-vmaf`, `--prefer-hw`, `--svt-preset N`.

**v5 requirements:** ffmpeg built with `libsvtav1`, `libx265`, and (for VMAF targeting)
`libvmaf` — Fedora/RPM Fusion and Homebrew builds qualify; Ubuntu/Debian distro ffmpeg
lacks libvmaf, use a [BtbN static build](https://github.com/BtbN/FFmpeg-Builds/releases).
`libplacebo` (in the same builds) enables DoVi profile-5 conversion. `ab-av1` is optional.

## Version progression

For the full story behind the security and source-file-safety hardening passes
(v5.0.9 → v5.0.19) — what was wrong, why it mattered, how it was found and fixed —
see [CHANGELOG.md](CHANGELOG.md). The table below is the one-line-per-release index.

Each release is a **new file** — prior scripts stay in the repo for reference.
The repo root holds the **current release** (`convert-v5.0.19.sh`) and the **last v4
release** (`convert-v4.0.52.sh`); all earlier versions live in [`Old Versions/`](Old%20Versions/):

| File | Version | Notes |
|------|---------|--------|
| `convert-v4.0.5.sh` | 4.0.5 | Initial v4 release; 8 GB AV1 oversized threshold |
| `convert-v4.0.6.sh` | 4.0.6 | 20% vs-original AV1 policy; `SCRIPT_NAME` check |
| `convert-v4.0.7.sh` | 4.0.7 | Dry-run media inspection (name, format, length, resolution) |
| `convert-v4.0.8.sh` | 4.0.8 | `--skip-av1` / `--skip-x265`; dry-run skips encoder bake-off |
| `convert-v4.0.9.sh` | 4.0.9 | Sequential jobs with live encode progress |
| `convert-v4.0.10.sh` | 4.0.10 | Auto-resume + shard change detection |
| `convert-v4.0.11.sh` | 4.0.11 | Bake-off failures no longer abort the queue |
| `convert-v4.0.12.sh` | 4.0.12 | NVENC AV1 uses `nvenc_av1_10bit` + `slowest` + HQ encopts |
| `convert-v4.0.13.sh` | 4.0.13 | Per-encoder CQ, Dolby Vision/HDR color metadata |
| `convert-v4.0.14.sh` | 4.0.14 | Bake-off per profile class (movie/anime × SDR/HDR) |
| `convert-v4.0.15.sh` | 4.0.15 | Auto-detect NVENC `tune=uhq` vs `tune=hq` |
| `convert-v4.0.16.sh` | 4.0.16 | Validate existing outputs on restart before skip |
| `convert-v4.0.17.sh` | 4.0.17 | First/last 30s decode validation (faster, catches aborts) |
| `convert-v4.0.18.sh` | 4.0.18 | Master log at `--path`; shard logs merged/cleaned at end |
| `convert-v4.0.19.sh` | 4.0.19 | WSL/HandBrake NVENC fallback when nvidia-smi missing |
| `convert-v4.0.20.sh` | 4.0.20 | WSL auto-picks Windows HandBrake (NVENC) + Linux ffmpeg/mkv |
| `convert-v4.0.21.sh` | 4.0.21 | Skip NVENC probe on `--dry-run`/WSL `.exe`; safer logging |
| `convert-v4.0.22.sh` | 4.0.22 | `sudo` + NFS: root writes mount, HandBrake as `$SUDO_USER` |
| `convert-v4.0.23.sh` | 4.0.23 | Read-only NFS: log/resume in `~/.cache/convert-v4/` |
| `convert-v4.0.24.sh` | 4.0.24 | `grep` required (not `rg`); fixes WSL without ripgrep |
| `convert-v4.0.25.sh` | 4.0.25 | Prefers `rg`, falls back to `grep` |
| `convert-v4.0.26.sh` | 4.0.26 | 5-way HW matrix: NVIDIA / QSV / AMD VCE / VideoToolbox / software |
| `convert-v4.0.27.sh` | 4.0.27 | `sudo` sidecar logs use invoking user's home (`$SUDO_USER`), not `/root` |
| `convert-v4.0.28.sh` | 4.0.28 | Auto pipeline: inspect waves of 5 while encoding; `--largest-first` / `--pipeline` / `--encode-batch` |
| `convert-v4.0.29.sh` | 4.0.29 | CIFS/SMB mount helper (`file_mode=0777`); `--mount-share` / credentials env |
| `convert-v4.0.30.sh` | 4.0.30 | `--skip-bakeoff`; auto-skip bake-off on CIFS + software encode |
| `convert-v4.0.31.sh` | 4.0.31 | NVENC AV1 `tune=uhq` probe on WSL; `--nvenc-av1-tune` / `CONVERT_NVENC_AV1_TUNE` |
| `convert-v4.0.32.sh` | 4.0.32 | macOS re-exec under Homebrew bash 4+ (not zsh); VideoToolbox only if `vt_h265` present |
| `convert-v4.0.33.sh` | 4.0.33 | Skip bake-off in software-only mode; AV1 sources sample-tested vs x265 before re-encode |
| `convert-v4.0.34.sh` | 4.0.34 | macOS BSD-awk-safe HandBrake progress parser (fixes false encode failures); numeric job totals |
| `convert-v4.0.35.sh` | 4.0.35 | Ignore benign ffmpeg DTS “invalid” warnings during output validation |
| `convert-v4.0.36.sh` | 4.0.36 | Per-title `{Title}.convert-v4.IN_PROGRESS` flag for interrupted/partial outputs |
| `convert-v4.0.37.sh` | 4.0.37 | Fix resume offset capture (`log_err`); require numeric resume skip |
| `convert-v4.0.38.sh` | 4.0.38 | Probe HandBrake `--keep-subname`; treat empty success outputs as failure |
| `convert-v4.0.39.sh` | 4.0.39 | Matroska EBML/segment bounds + optional `mkvalidator`; `corrupt_files.txt` |
| `convert-v4.0.40.sh` | 4.0.40 | Stricter output metadata gate (duration + video stream) before structure/decode |
| `convert-v4.0.41.sh` | 4.0.41 | `--check-tools` + OS install help; bad processed delete+reconvert; `bad_sources.txt` |
| `convert-v4.0.42.sh` | 4.0.42 | Clearer mkvalidator install guidance (optional; EBML still runs) |
| `convert-v4.0.43.sh` | 4.0.43 | Fix QSV encode probe (check output size before deleting temp dir) |
| `convert-v4.0.44.sh` | 4.0.44 | Discover tools in `$HOME/.local/bin` (macOS/Linux user installs) |
| `convert-v4.0.45.sh` | 4.0.45 | AMD VCN via ffmpeg `hevc_vaapi` when HandBrake lacks vce/vcn (Fedora/mesa) |
| `convert-v4.0.46.sh` | 4.0.46 | Legacy containers (`m2ts`/`mpg`/`wmv`/…); stream-duration fallback |
| `convert-v4.0.47.sh` | 4.0.47 | Fix AV1 sample “unknown decision” (sample logs on stderr) |
| `convert-v4.0.48.sh` | 4.0.48 | Remux-repair source MKV structure errors before encode; else `bad_sources.txt` |
| `convert-v4.0.49.sh` | 4.0.49 | Waive unlimited size-reject on 1080p upscale path |
| `convert-v4.0.50.sh` | 4.0.50 | Upscale keeps only if ≤50% larger than source; else revert to original |
| `convert-v4.0.51.sh` | 4.0.51 | Fix mkvpropedit off-by-one that mangled audio/subtitle language tags |
| `convert-v4.0.52.sh` | 4.0.52 | `--name-glob` / path trailing glob to filter large shelves (e.g. `American/A*`) |
| `convert-v5.0.0.sh` | 5.0.0 | ffmpeg engine, per-title VMAF-targeted CRF, DoVi→HDR10, functional HW probes, mount audit |
| `convert-v5.0.1.sh` | 5.0.1 | set-based resume (`convert-v5.done`): restarts fast-skip unchanged finished sources instead of positional queue anchor |
| `convert-v5.0.2.sh` | 5.0.2 | `-p` accepts a single file directly (in addition to a directory or directory+trailing-glob) |
| `convert-v5.0.3.sh` | 5.0.3 | multi-part source merge (Part1/Part2/CD1/CD2/Disc1/Disc2); `.ogm` source support |
| `convert-v5.0.4.sh` | 5.0.4 | fixes softness (dropped a stray SVT-AV1 tune=0) and restores v4's dialogue-clarity audio boost (dynaudnorm+gain) in the ffmpeg engine |
| `convert-v5.0.5.sh` | 5.0.5 | `--prefer-hw` NVENC AV1 now uses the probed `uhq` tune (matching v4) instead of a hardcoded `hq` |
| `convert-v5.0.6.sh` | 5.0.6 | fixes a Dolby Vision source silently keeping its DoVi tagging when falling back to x265 via the HEVC remux shortcut |
| `convert-v5.0.7.sh` | 5.0.7 | streaming-optimized MKV output, `--clean-junk`, per-directory file-list cache, per-folder done/in-progress semaphores (fixes multi-hour restart enumeration on large TV libraries) |
| `convert-v5.0.8.sh` | 5.0.8 | fixes 1080p-upscale trigger catching near-720p (letterboxed/cropped) sources it shouldn't; new threshold 700 |
| `convert-v5.0.9.sh` | 5.0.9 | `discover_binary()` now prefers a user-built `~/.local/bin` copy (e.g. a libvmaf-enabled ffmpeg) over the system PATH binary; fixes non-interactive SSH runs silently falling back to a libvmaf-less ffmpeg and losing VMAF targeting |
| `convert-v5.0.10.sh` | 5.0.10 | external review fixes: portable awk `match()` (macOS/BSD awk), portable disc-size (no `du -b`), silent `mv -n` organize collisions now warn instead of losing files, O(n²) pipeline queue reads (persistent fd), pipeline job-count never propagating out of its background scan process, file-list cache/folder-done flags now key on max mtime across the whole subtree (fixes permanently-stale TV libraries — new episodes in a Season folder were invisible forever), multipart merging now excludes TV show/season directories entirely (was merging two-part episodes into one file), merge detection no longer runs during the fast pre-scan count, and `--clean-junk-apply` no longer deletes a `.merged.mkv` just because its raw parts were cleaned up (data-loss fix) |
| `convert-v5.0.11.sh` | 5.0.11 | high-effort cross-platform audit (a full independent review pass, verified before applying): done-log fast-resume was silently dead from a call-order bug (init order swapped); file-list cache writes are now atomic (temp+rename, was corruptible mid-write); WSL_INTEROP now forwarded through `sudo` so Windows HandBrakeCLI.exe/nvidia-smi.exe probes don't break when running as root; macOS mount audit no longer breaks on mount points containing spaces; `dir_subtree_max_mtime` now one `python3` call instead of one per subdirectory; external subtitle paths are translated before comma-joining instead of after (was corrupting filenames containing literal commas, e.g. "Movie, The"); replaced non-essential `seq` dependency; and fleet machines sharing the same NFS/SMB library now atomically claim a title before encoding it, instead of racing to write the same output file (also fixed a real staleness-detection bug this surfaced: a confirmed-dead same-host process was still treated as "not stale" for 2 hours) |
| `convert-v5.0.12.sh` | 5.0.12 | round-3 security + source-safety audit (a full independent review pass, all findings independently verified against the code before fixing; one review pass was also invoked but returned no usable output). Source-safety hardening: a source MKV needing container repair is now remuxed into an isolated throwaway temp dir and the true original is NEVER overwritten in place (previously replaced in place after passing validation); `finalize_mkv_output` no longer remuxes/relabels a genuinely-original AV1 file in place just because it happens to already be AV1; a new codec-vs-filename consistency check (a file named `*.AV1.mkv` must actually BE AV1, `*.x265.mkv` must actually be HEVC) plus an mtime-provenance check now guard every deletion of a "processed output" -- an unrelated real file that coincidentally matches our naming convention is flagged for human review instead of deleted; `try_av1_convert`/`try_x265_convert` now refuse outright if the computed output path is identical to the source path under any combination of naming/codec mismatch (would otherwise have `ffmpeg -y` truncate the source before it could even be read); the in-progress flag write refuses to follow a symlink at its predictable path instead of writing through it into whatever it points to. Security: fixed a second eval-based injection path, SMB credentials file now created with a restrictive umask (closes a TOCTOU permission-race window) and cleaned up via an exit/interrupt trap instead of only on the normal-completion path; a leading `-` in `--path` no longer gets misread as a command flag by `find`/`realpath`. |
| `convert-v5.0.13.sh` | 5.0.13 | round-4 security + source-safety audit (a full independent review pass, all findings independently verified; another review pass was invoked again but returned no usable output both times). A prior fix (`~"$SUDO_USER"` replacing eval) turned out to be safe but silently non-functional -- bash tilde expansion never substitutes a variable's value regardless of quoting, confirmed by direct testing; replaced with `getent`/`dscl`/python3 `pwd.getpwnam` lookups (still no eval) that actually work. `try_av1_convert`/`try_x265_convert` now also refuse if the computed output path is a symlink to anything, not just to the source itself (an unrelated real file could otherwise be truncated through it). A general symlink-neutralization guard now covers every other predictable sidecar path (resume state/queue/shards files, the master log, per-folder done/in-progress flags) beyond the per-title flag fixed last round. `chown` no longer follows a symlink when re-owning outputs/sidecar files under sudo. The SMB-credentials cleanup trap now saves and restores whatever EXIT/INT/TERM handler was already registered instead of permanently clobbering it (was silently breaking the interrupt-triggered resume-state save for the rest of the run). Two cache-file temp-write paths (`mkv_structure_cache_invalidate`/`_store`, `filecache_put`) upgraded from a static or PID-based temp suffix to a real randomized `mktemp` name. Fixed a portability bug where a custom mkvmerge/mkvpropedit path containing a space (e.g. a macOS `.app` bundle) silently broke track labeling. |
| `convert-v5.0.14.sh` | 5.0.14 | round-5 audit (a full independent review pass, all findings independently verified; one reviewer finally returned usable output on this attempt after two prior empty runs). Closed three more unguarded write paths of the same class as previous rounds: `process_existing_av1`'s non-MKV AV1-remux branch now gets the same symlink refusal AND an existing-output provenance check (mtime + codec-claim) that `try_av1_convert`/`try_x265_convert` already had; the per-shard scan log and the shard-snapshot `.prev` diff file (both predictable, symlink-writable) are now neutralized like every other sidecar path; the multipart-merge target now refuses to overwrite a pre-existing regular file with no provenance record of this script having created it. Fixed a bug in the *previous* round's own fix: `optimize_mkv_for_streaming`'s new `mktemp` template had a suffix after the `X`s, which BSD/macOS `mktemp` (unlike GNU) does not accept -- would have silently reintroduced the exact predictable-name race it was meant to close, specifically on the fleet's one real macOS machine. Extended `file_size_bytes`'s portable fallback (python3 `os.stat`) to cover non-macOS/non-Linux platforms, matching the pattern already used elsewhere. Confirmed the `eval` in the trap-restoration path added two rounds ago is safe by construction (operates only on bash's own `trap -p` output, never on user/environment data) -- reviewed and left as-is rather than "fixed" for its own sake. |
| `convert-v5.0.15.sh` | 5.0.15 | fixes a real, visually-confirmed Dolby Vision Profile 5 color bug (green/red tint), found via user report on a live Godzilla (2014) encode. Two compounding causes: (1) the `hdr` flag that gates all Dolby-Vision handling in `build_ffmpeg_video_args` was only ever set from a source's standard `color_transfer` tag — but a genuine Profile 5 source has no PQ/HLG tag at the container level by design (its tone curve lives entirely in the proprietary RPU), so the entire DoVi-detection/libplacebo-conversion branch was silently skipped and the raw base layer got encoded with no RPU-based reconstruction; (2) the libplacebo filter string itself used `color_trc=pq`, which isn't a valid value in this ffmpeg build (the correct name is `smpte2084`) — meaning the P5→HDR10 conversion path had never actually worked since it was introduced, just masked by bug (1). Verified with a real before/after frame extraction from the actual affected file: the buggy output is visibly green-tinted throughout, the fixed output shows correct natural greys/whites. |
| `convert-v5.0.16.sh` | 5.0.16 | full Dolby Vision/HDR classification hardening, following a direct three-way independent consultation on whether v5.0.15's fix was the complete permanent solution. All three independently converged on the same four gaps: (1) HLG content (plain, or DoVi profile 8.4) was being unconditionally tagged as PQ (`smpte2084`/`hdr10=1`) by every `hdr=true` path — wrong transfer curve, crushed shadows/blown highlights on real playback; (2) DoVi profile 8 was treated as one case, but `dv_profile=8` alone can't distinguish 8.1 (HDR10 base, safe as handled) from 8.2 (SDR base, was being wrongly forced into HDR/PQ) or 8.4 (HLG base); (3) a source with Dolby Vision side-data but an unparseable profile number fell through to blind PQ tagging with zero reconstruction — the exact shape of source that caused the original Profile 5 bug, just on a different trigger; (4) `--prefer-hw` and the AMD VAAPI encode paths had no Dolby Vision handling at all — a Profile 5 source encoded that way would hit the original tint bug today. Added a single `determine_hdr_mode()` classifier (pq / pq_reconstruct / hlg / sdr / unknown) used consistently everywhere HDR-related decisions are made; unknown DoVi now fails safe (flagged for human review) instead of guessing; `--prefer-hw`/AMD VAAPI now gracefully fall back to software for profile-5/unknown sources instead of silently producing wrong colors, and apply correct PQ-vs-HLG output tagging when they do proceed. Verified with 13 classification test cases covering every profile/transfer-tag combination raised by the reviewers, plus re-confirmation against the actual Godzilla (Profile 5) and Clueless (Profile 8.1-style) files. |
| `convert-v5.0.17.sh` | 5.0.17 | fixes final output/cache files silently ending up `0600` on NFS shares instead of a normal umask-derived mode (e.g. `0644`), reported directly by the user after noticing it on a just-finished encode. Root cause: `mktemp` intentionally creates its temp file at `0600` regardless of umask (closes a symlink-race window — the same rationale as the CIFS credentials file), but the script's atomic "write to a mktemp'd temp file, then `mv -f` it over the real path" pattern never restored a normal mode afterward, so `mv` carried the `0600` straight through onto the real output. Affected `optimize_mkv_for_streaming` (the final `.mkv` itself, confirmed on the actual Clueless (1995) output), `mkv_structure_cache_invalidate`/`mkv_structure_cache_store`, and `filecache_put`. Added `_restore_default_file_mode()` (chmod to `0666 & ~umask` right after each successful `mv`) and applied it at all four sites. |
| `convert-v5.0.18.sh` | 5.0.18 | RAM-backed output staging. The active encode now writes to a tmpfs/ramdisk instead of the real (often NFS) destination, then moves the finished file into place as one sequential transfer — reads tolerate network blips fine via retry, but a stalled/interrupted write on a `hard` NFS mount can block the whole encode, so moving the write off that path removes the risk entirely and also frees the NFS server from sustained write traffic for the whole encode duration. Discovery-first: an already-mounted suitable tmpfs (`/tmp`, `/dev/shm`, `/mnt/ramdisk`, or a `CONVERT_RAMDISK_DIR` override) is used if found; otherwise one is created sized at `CONVERT_RAMDISK_PCT`% (default 40) of *available* (not total) memory, deliberately leaving headroom for the encoder process's own footprint (observed ~6GB RSS on a real Dolby Vision libplacebo encode). macOS has no built-in tmpfs, so creation there uses a real `hdiutil`/`diskutil` RAM disk instead. A pre-flight size-fit check (source file size + 10% margin, since the encoded output is almost always smaller but occasionally isn't) compares the estimate against actual free space on the candidate and falls back to direct-write, unchanged from prior versions, if it doesn't comfortably fit — never a live mid-encode rescue, which would require unsafe partial-file surgery on a still-growing MKV. The `.IN_PROGRESS` semaphore and per-folder logs stay on the source path throughout, so other fleet machines scanning the same library still see accurate in-progress state. Verified with 17 unit tests (discovery, size-fit math, staging decision, finalize-move, and the platform-specific tmpfs/RAM-disk detection) plus a real end-to-end encode confirming the full stage-encode-finalize path inside the actual script, not just the isolated helpers. |
| `convert-v5.0.19.sh` | 5.0.19 | **Current** — hardens v5.0.18's ramdisk staging after a three-way independent external review explicitly requested to re-audit the new feature against the hard source-file-safety invariant. Two reviewers independently converged on the same two blocking issues: (1) the per-file staged path was a predictable string (`$RAMDISK_JOB_DIR/.convert-stage.$$.basename`) built directly in a shared, world-writable location (`/tmp`, `/dev/shm`) — another local user/process could pre-plant a symlink at that exact name pointing at an arbitrary file (including a source), which `ffmpeg -y` would then follow and write through; (2) `finalize_staged_encode_output`'s `mktemp` created a temp file, but then `cp` reopened that path *by name* to write into it — a TOCTOU window where the path could be swapped for a symlink between the two steps. Fixed by switching to a private, `mktemp -d`-created, mode-700 staging directory (unpredictable name, owner-only access) for every per-file write, both during the encode itself and during the final copy-into-place step — eliminating the predictable-name and reopen-by-pathname classes entirely rather than trying to patch around them. Also fixed, per the same review: `CONVERT_RAMDISK_DIR` now must actually be tmpfs-backed (verified the same way as every other candidate) instead of being trusted blindly; macOS's stale-ramdisk detection no longer has a loose "any mount at this path" fallback that could eject an unrelated volume; Linux's owned-resource detection now checks the path is genuinely its own mountpoint, not just that it lives somewhere under a tmpfs (`/run` itself is tmpfs on Fedora, which could misclassify a stale plain directory); `finalize_staged_encode_output` now explicitly checks `mv`'s exit status and preserves the staged copy for manual recovery instead of silently discarding a successful encode if the final move fails; `ramdisk_job_start` now skips entirely during `--dry-run` (a reviewer-suggested optimization, since dry-run never actually encodes). Verified with 20 unit tests including direct regression tests replicating the exact symlink pre-plant and TOCTOU scenarios both reviewers described, plus real end-to-end encodes on both the primary workstation (discovered `/tmp`) and a macOS machine (created + torn-down macOS RAM disk) confirming the hardened path end to end. |



When bumping version: copy the latest script to `convert-v{NEW}.sh`, update `VERSION` and `SCRIPT_NAME`, keep all older files (moving the superseded one into `Old Versions/`). Do not overwrite.

## Genesis

This project evolved from three small batch encoders in [`genesis/`](genesis/):

- **`convert-v1.sh`** — original Linux/nvdec AV1 encoder (`.avi`, `.mp4`, `.mkv`, `.ts` in cwd)
- **`convert-anime.sh`** — macOS HandBrakeCLI + VideoToolbox, SVT-AV1 anime profile, Opus audio
- **`convert-anime-flatpak.sh`** — same pipeline via Flatpak HandBrake + nvdec

Those scripts scanned the current directory and wrote `{title}-av1.mkv`. v4 keeps the anime encoder profile and GPU paths, and adds organization rules, TV detection, disc title selection, NVENC bake-off, validation, and sharded finds. See [`genesis/README.md`](genesis/README.md) for the full lineage table.

## Environment requirements

The script runs on **Linux**, **WSL2**, **Cygwin/MSYS2/Git Bash**, and **macOS**. It does **not** run in plain Windows PowerShell or CMD.

### Prerequisites (install separately)

These are **not** part of a default Linux, Windows, or macOS install. You must install them (or point the script at them with `CONVERT_*` / `--ffmpeg`, `--handbrake`, …).

| Tool | Required? | Used for |
|------|-----------|----------|
| **ffmpeg** / **ffprobe** | Yes | Probing, remux, validation decode windows, NVENC tune probe |
| **HandBrakeCLI** | Yes | Transcode (AV1, HEVC, disc scan), hardware decode when available |
| **mkvmerge** / **mkvpropedit** (MKVToolNix) | Yes | Subtitle merge, track labels, metadata, output validation |
| **python3** | Yes | Post-encode MKV track labeling (`label_mkv_tracks`; uses stdlib only) |
| **grep** | Yes* | Dolby Vision / HDR detection, encoder probes (*normally preinstalled; required if `rg` is absent) |

On startup the script prints the binaries it picked — that line is the source of truth for your machine.

**Install examples (all required tools):**

```bash
# Fedora / RHEL
sudo dnf install ffmpeg mkvtoolnix HandBrake-cli python3 grep

# Debian / Ubuntu / WSL
sudo apt install ffmpeg mkvtoolnix handbrake-cli python3 grep

# macOS
brew install ffmpeg mkvtoolnix handbrake python3
# grep and python3 are usually present; install python3 if `python3 --version` fails
```

### Optional tools (not required, but improve the workflow)

**Hardware encoding:** For any large library, treat a GPU or Quick Sync / VCE encoder as a practical requirement — see **Hardware-accelerated encoding** below.

| Tool | Platform | Used for |
|------|----------|----------|
| **ripgrep (`rg`)** | All | Faster text search on large ffprobe/HandBrake output (v4.0.25+ prefers `rg`, falls back to `grep`) |
| **NVIDIA driver + `nvidia-smi`** | Linux / WSL / Cygwin | GPU encode detection; script can fall back to HandBrake's NVENC probe |
| **Windows HandBrake** (`HandBrakeCLI.exe`) | WSL2 | NVENC on gaming laptops while ffmpeg/mkv tools stay in Linux WSL |
| **Flatpak + HandBrake** (`fr.handbrake.ghb`) | Linux / WSL | Alternative HandBrake install when distro packages are missing |
| **GNU `timeout`** | Linux / WSL | Caps NVENC tune probe at 120s; script runs the probe without a cap if absent |
| **Homebrew** | macOS | Convenient way to install ffmpeg, MKVToolNix, HandBrake, and python3 |

```bash
# Optional — faster text search (v4.0.25+ logs search=rg when installed):
sudo dnf install ripgrep    # Fedora
sudo apt install ripgrep    # Debian/Ubuntu/WSL
```

**Text search:** v4.0.25+ uses **ripgrep (`rg`) when installed**, otherwise **GNU `grep`**. At least one must be on `PATH`. Startup logs `search=rg` or `search=grep`.

### Baseline OS utilities (no separate install on full distros)

The script also expects standard Unix tools that ship with Linux, macOS, WSL, and Cygwin/Git Bash: `bash` 4+ (macOS: Homebrew bash via auto re-exec), `find`, `sort`, `awk`, `sed`, `stat`, `date`, `mktemp`, `mkdir`, `mv`, `rm`, `basename`, `dirname`, `cut`, `tr`, and on WSL **`wslpath`** (for Windows HandBrake path translation). Minimal container or embedded images may need `coreutils`, `findutils`, and `grep` in addition to the prerequisites above.

Override tool paths with `CONVERT_FFMPEG`, `CONVERT_HANDBRAKE`, etc., or `--ffmpeg`, `--handbrake`, …

### Minimum versions (feature support)

| Component | Minimum | Enables |
|-----------|---------|---------|
| **bash** | 4.0+ | Script runs (Linux, WSL, Cygwin) |
| **zsh** | any recent | macOS — script re-execs under zsh automatically (system bash 3.2 is too old) |
| **HandBrake** | **1.7.0+** | `nvenc_av1_10bit` (GPU AV1 encode) |
| **HandBrake** | **1.6.0+** | `nvenc_h265`, `svt_av1_10bit`, disc/ISO scan |
| **ffmpeg** | **4.4+** | Basic probe/remux; **5.0+** recommended for AV1/HDR validation paths |
| **MKVToolNix** | **60+** | Reliable merge/propedit on modern MKV/HDR outputs |
| **NVIDIA driver** | **525+** (Linux/WSL) / current Studio or Game Ready (Windows host) | NVENC/NVDEC via HandBrake |
| **NVIDIA GPU + NVENC 13+** | RTX 40-series or newer (Ada+) for AV1 encode; most GTX 10-series+ for HEVC NVENC | GPU AV1 (`nvenc_av1_10bit`); script auto-falls back to `tune=hq` if `tune=uhq` is unsupported |

Verify HandBrake encoders:

```bash
HandBrakeCLI --help 2>&1 | grep -E 'nvenc_av1|nvenc_h265|svt_av1'
```

Without a supported GPU, the script uses **software** encoders (`svt_av1_10bit`, `x265`) — correct but much slower.

### Hardware-accelerated encoding (strongly recommended)

For home-media libraries with thousands of files, **hardware-assisted encoding is not optional in practice** — software AV1/x265 on CPU can take many hours per title and will leave a large tree running for weeks. A GPU or integrated graphics encoder is the difference between an overnight batch and a multi-month backlog.

| Vendor | Technology | HandBrake encoders (examples) | In this script |
|--------|------------|-------------------------------|----------------|
| **NVIDIA** | NVENC / NVDEC | `nvenc_av1_10bit`, `nvenc_h265` | **Auto-detected** on Linux, WSL2, and Cygwin — used for AV1 and HEVC |
| **Intel** | Quick Sync Video (QSV) | `qsv_h265`, `qsv_h264` (`qsv_av1` on newer Arc) | **Auto-detected in v4.0.26+** — default priority **below NVIDIA**, above software; `qsv_h265` for HEVC |
| **AMD** | VCE / VCN | `vce_h265`, `vce_h264` | **Auto-detected in v4.0.26+** — default below NVIDIA/QSV; needs amdgpu-pro/AMF on Linux for many distros |
| **Apple** | VideoToolbox | `vt_h265`, `vt_h264` (encode); `videotoolbox` (decode) | **macOS only** — `vt_h265` for HEVC; AV1 via `svt_av1_10bit` with VideoToolbox decode. No NVIDIA/QSV path on Mac |

**What to install for hardware encode:**

- **NVIDIA (Linux / WSL / Windows host):** Proprietary drivers so `nvidia-smi` works (or HandBrake reports NVENC). No CUDA Toolkit required. RTX 40-series+ for GPU AV1; most GTX 10-series+ for HEVC NVENC.
- **Intel:** CPU/iGPU with Quick Sync — ensure your distro HandBrake build includes QSV (`HandBrakeCLI --help | grep -i qsv`). You still need working drivers (`intel-media-driver`, `i915`, etc. on Linux).
- **AMD:** Discrete or APU with VCE/AMF — ensure HandBrake was built with AMF/VCE support and Mesa/AMD drivers are current.

Verify what HandBrake sees on your machine:

```bash
HandBrakeCLI --help 2>&1 | grep -iE 'nvenc|qsv|vce|amf|videotoolbox'
```

**Bottom line:** Run large jobs on a machine with **hardware encode** when possible. **NVIDIA NVENC** is the fastest path (GPU AV1 + HEVC). **Intel Quick Sync** (v4.0.26+) speeds up the HEVC/x265 fallback path substantially on laptops without a discrete GPU. **AMD CPUs** without NVIDIA still use software encoders in this script — fine for small batches, slow for whole regions.

### Hardware combinations (v4.0.26+)

The script probes **all** encoders HandBrake reports, then picks one **active** path. AV1 is always `svt_av1_10bit` (CPU) except when NVIDIA is active (`nvenc_av1_10bit` bake-off).

| # | Hardware | Default active encoder | Override flag | If override HW missing |
|---|----------|------------------------|---------------|-------------------------|
| **1** | AMD CPU + NVIDIA GPU | NVIDIA NVENC | `--prefer-amd-vce` | Software (not NVIDIA) |
| **2** | AMD CPU, no NVIDIA | AMD VCE/VCN → software | — | — |
| **3** | Intel CPU + NVIDIA GPU | NVIDIA NVENC | `--prefer-intel-qsv` | Software (not NVIDIA) |
| **4** | Intel CPU, no dGPU | Intel Quick Sync → software | — | — |
| **5** | macOS | VideoToolbox (`vt_h265`) → software | — | — |

**Default chain (Linux/WSL/Windows, no override):** NVIDIA → Intel QSV → AMD VCE → software

```bash
# Combo 1: AMD CPU + NVIDIA — prefer AMD iGPU/APU encode over discrete GPU
./convert-v4.0.26.sh -p /mnt/Media/... --prefer-amd-vce

# Combo 3: Intel CPU + NVIDIA — prefer Quick Sync over discrete GPU
./convert-v4.0.26.sh -p /mnt/Media/... --prefer-intel-qsv

# Force when HandBrake shows an encoder but auto-detect misses it
export CONVERT_FORCE_AMD_VCE=1
export CONVERT_FORCE_INTEL_QSV=1
export CONVERT_FORCE_NVIDIA=1
```

`CONVERT_FORCE_*` takes precedence over `--prefer-*`. macOS ignores NVIDIA/QSV/AMD flags — VideoToolbox only.

Startup logs: `nvidia=` `intel_qsv=` `amd_vce=` `active_encode=nvenc|qsv|amd_vce|videotoolbox|software`

### Two-machine example (AMD desktop + Intel WSL2 laptop)

| Machine | Typical hardware | What the script does |
|---------|------------------|----------------------|
| **AMD Linux desktop** | No NVIDIA; VCE if amdgpu-pro + HandBrake built with VCE | `amd_vce` or `software` — your AMD box likely lands on **software** unless VCE is in `HandBrakeCLI --help` |
| **Intel WSL2 laptop** | iGPU with Quick Sync | **Use this for big TV/movie jobs.** Install **HandBrake for Windows** on the host; v4.0.26+ auto-picks `HandBrakeCLI.exe` when it reports QSV |

**Intel WSL2 laptop (recommended workflow):**

```bash
# Verify Windows HandBrake sees Quick Sync (run in WSL):
'/mnt/c/Program Files/HandBrake/HandBrakeCLI.exe' --help 2>&1 | grep -i qsv

# Convert a large TV region — Linux ffmpeg/mkv, Windows HandBrake for QSV
sudo ./convert-v4.0.26.sh -p /mnt/BabyBear/Media/Television/American \
  --convert-only --no-shard \
  --handbrake '/mnt/c/Program Files/HandBrake/HandBrakeCLI.exe'
```

Startup should log `WSL hybrid: Windows HandBrake (Intel Quick Sync)` and `HandBrake reports Intel Quick Sync — qsv_h265 for HEVC`. AV1 encodes still use CPU (`svt_av1_10bit`), but when a file falls back to x265 you get Quick Sync hardware speed.

If QSV is present but not detected: `export CONVERT_FORCE_INTEL_QSV=1` or set `--handbrake` to the Windows `.exe` explicitly.

**Note:** Intel QSV inside **Linux WSL** (distro `handbrake-cli`) usually does **not** work — the iGPU is not exposed the same way. The Windows HandBrake hybrid path is the reliable fix, same pattern as NVIDIA gaming laptops.

---

### Linux (native)

**Shell:** bash 4+

**Install:** see **Prerequisites** above (`ffmpeg`, `mkvtoolnix`, `HandBrake-cli`, `python3`, `grep`).

**Optional:** Flatpak HandBrake (`fr.handbrake.ghb`) — auto-detected if distro packages are missing.

**NVIDIA GPU:** Install proprietary drivers so `nvidia-smi` works. No separate CUDA Toolkit is required for NVENC.

On **WSL2 laptops**, GPU detection tries, in order: `nvidia-smi` (including `/mnt/c/Windows/System32/nvidia-smi.exe`), then **HandBrake's NVENC/NVDEC probe**. Override with `CONVERT_FORCE_NVIDIA=1` if needed.

**WSL hybrid toolchain (gaming laptops & Intel iGPU):** Install **ffmpeg + mkvtoolnix + handbrake-cli** inside WSL (Linux packages). Install **HandBrake for Windows** on the host for NVENC (NVIDIA) or Quick Sync (Intel). v4.0.26+ auto-detects `HandBrakeCLI.exe` under `/mnt/c/Program Files/HandBrake/` when it reports NVENC or QSV, while ffmpeg/ffprobe/mkvmerge stay on Linux PATH. File paths passed to the Windows `.exe` are translated via `wslpath -w`. Override only HandBrake if needed:

```bash
export CONVERT_HANDBRAKE='/mnt/c/Program Files/HandBrake/HandBrakeCLI.exe'
# or
export CONVERT_HANDBRAKE_WIN='/mnt/c/Program Files/HandBrake/HandBrakeCLI.exe'
```

**Typical `--path`:** local mount (`/mnt/BigMomma/...`, `/media/...`) or NFS mount configured in `/etc/fstab`.

---

### Windows (WSL2 — recommended)

**Shell:** bash 4+ inside a WSL2 distro (Ubuntu, Fedora, etc.). The script sets `PLATFORM=wsl`.

**NFS / read-only mounts:** If the library mount is read-only for your WSL user (NFS `root_squash`, or SMB mounted without `file_mode`/`noperm`), v4.0.23+ puts **logs and resume state** under `~/.cache/convert-v4/jobs/<path-slug>/` so dry-runs still work. Fix SMB permissions with the mount options under **Mounting media in WSL** when possible so organize/convert can run **without `sudo`**. Use `sudo` only when the share truly requires root for writes; v4.0.22+ runs Windows HandBrake as `$SUDO_USER` in that case.

```bash
# Dry-run / inspect (no sudo needed — log goes to ~/.cache/convert-v4/...)
./convert-v4.0.23.sh -p /mnt/BabyBear/Media/Television/American \
  --handbrake '/mnt/c/Program Files/HandBrake/HandBrakeCLI.exe' --dry-run

# Organize / convert (sudo for NFS writes; HandBrake runs as your user)
sudo ./convert-v4.0.23.sh -p /mnt/BabyBear/Media/Television/American \
  --handbrake '/mnt/c/Program Files/HandBrake/HandBrakeCLI.exe'
```

Use quotes around the HandBrake path. Invoke as `sudo ./script.sh` (not `sudo bash script.sh`) so `$SUDO_USER` is set.

**GPU:** Install current NVIDIA drivers on the **Windows host**. `nvidia-smi` must work **inside WSL**. WSL1 is not supported for this workflow.

**Linux vs Windows binaries:** ffmpeg, ffprobe, mkvmerge, and mkvpropedit are resolved from **Linux WSL PATH** only. HandBrake is special on WSL2 laptops — discovery order:

1. `CONVERT_HANDBRAKE` / `--handbrake` override  
2. Linux `HandBrakeCLI` on PATH (if it reports NVENC or QSV)  
3. **Windows** `HandBrakeCLI.exe` at `/mnt/c/Program Files/HandBrake/` (or `CONVERT_HANDBRAKE_WIN`) when it reports NVENC or QSV  
4. Linux HandBrake on PATH (software encoders)  
5. Flatpak HandBrake (Linux/WSL only)

When the Windows `.exe` is selected, input/output paths are translated with `wslpath -w` so Linux media paths still work.

```bash
# Only needed if HandBrake is not in the default Program Files location:
export CONVERT_HANDBRAKE='/mnt/c/Program Files/HandBrake/HandBrakeCLI.exe'
```

**Recommendation:** **Linux packages inside WSL** for ffmpeg + mkvtoolnix; let v4.0.26+ auto-pick Windows HandBrake for NVENC (NVIDIA laptop) or QSV (Intel laptop).

**Mounting media in WSL:**

| How you access library | WSL `--path` example | Notes |
|------------------------|----------------------|-------|
| NFS (mounted in WSL) | `/mnt/BigMomma/Media/Movies` | Best remote option when the NFS server and network are fast |
| SMB share mounted in WSL (`cifs`) | `/mnt/BabyBear/Media/...` | Mount inside WSL with permissive modes (see below); tune `vers=3.1.1`, large `rsize`/`wsize` |
| Windows drive letter | `/mnt/c/Users/...` | Fine for local NTFS; **slow** for huge trees (drvfs metadata) |
| `\\server\share` only on Windows | Mount into WSL first — avoid encoding through `/mnt/c/...` to a redirected network drive |

**SMB/CIFS in WSL (recommended mount options):** Default SMB mounts often appear read-only to your WSL user (permission mapping / `root_squash`-like behavior). Mount with explicit modes so the script can write logs and outputs **without `sudo`**:

```bash
sudo mkdir -p /mnt/BabyBear
sudo mount -t cifs -o rw,username=YOUR_SMB_USER,password=YOUR_PASSWORD,file_mode=0777,dir_mode=0777,noperm \
  //SERVER_IP/SHARE_NAME /mnt/BabyBear
```

- `file_mode=0777,dir_mode=0777` — WSL user can read/write on the share  
- `noperm` — do not enforce remote ACLs locally (common fix for “Permission denied” in WSL)  
- Optional performance tuning: add `vers=3.1.1,rsize=1048576,wsize=1048576,cache=strict`

**Safer credentials (avoid password on the command line):**

```bash
# /etc/samba/babybear.credentials  (chmod 600, root-owned)
#   username=YOUR_SMB_USER
#   password=YOUR_PASSWORD

sudo mount -t cifs -o rw,credentials=/etc/samba/babybear.credentials,file_mode=0777,dir_mode=0777,noperm \
  //SERVER_IP/SHARE_NAME /mnt/BabyBear
```

**Persistent mount (`/etc/fstab`):**

```
//SERVER_IP/SHARE_NAME  /mnt/BabyBear  cifs  credentials=/etc/samba/babybear.credentials,rw,file_mode=0777,dir_mode=0777,noperm,vers=3.1.1,_netdev,nofail,x-systemd.automount  0  0
```

Then: `sudo mount /mnt/BabyBear` (or reboot). Point the script at e.g. `-p /mnt/BabyBear/Media/Television/American`.

If the share is still read-only, v4.0.23+ falls back to `~/.cache/convert-v4/` for logs/resume; use `sudo` only when you must write MKVs on a root-only NFS mount.

---

### Windows (Cygwin / MSYS2 / Git Bash)

**Shell:** bash 4+; script sets `PLATFORM=windows`.

**Tools:** Install Windows builds of ffmpeg, MKVToolNix, and HandBrakeCLI, or point `CONVERT_*` at `C:\Program Files\...` (script also checks `/cygdrive/c/Program Files/...`).

**GPU:** `nvidia-smi.exe` must be on `PATH` (typically `C:\Windows\System32`).

Less tested than WSL2; prefer WSL2 for large library jobs.

---

### macOS

**Shell:** Homebrew **bash 4+** (v4.0.32+ auto re-execs from system bash 3.2). Install with `brew install bash`. Do **not** run the script via shebang directly from an SMB share (`/Volumes/...`) — macOS blocks that; copy the script to `~/` or invoke `/usr/local/bin/bash /path/to/convert-v4.0.36.sh ...`.

**Install:** see **Prerequisites** above (`brew install bash ffmpeg mkvtoolnix handbrake python3`).

HandBrake is also searched under `/Applications/HandBrake.app/Contents/MacOS/HandBrakeCLI`.

**GPU / hardware encode:** macOS uses **VideoToolbox** only when HandBrake reports **`vt_h265`** (v4.0.32+). Builds that only expose `vt_h264` fall back to software (`svt_av1_10bit`, `x265`). AV1 always uses CPU (`svt_av1_10bit`).

```bash
# Verify VideoToolbox HEVC encoder (required for HW path)
HandBrakeCLI --help 2>&1 | grep -iE 'vt_h265|videotoolbox'
```

**Mounting media:**

| How you access library | Typical `--path` | Notes |
|------------------------|------------------|-------|
| Local APFS volume | `/Volumes/Media/Movies` | Fastest |
| NFS (`mount -t nfs`) | `/Volumes/nfs-media/...` or mount point you chose | Good on gigabit LAN; same latency caveats as Linux NFS |
| SMB (`mount_smbfs`) | `/Volumes/share-name/...` | Very common on Mac; fine for reads, watch write speed during encode. Keep the **script** on local disk. |
| External USB | `/Volumes/MyDrive/...` | USB 3.x+ recommended; USB 2.0 can stall fast encodes waiting on disk |

---

## Storage, mounts, and performance

The script is **I/O-heavy**: sharded `find` over thousands of folders, ffprobe per file, full source read during encode, and **simultaneous write** of a new `.AV1.mkv` / `.x265.mkv` beside the original. Storage choice affects **wall-clock time** and stability more than it changes compression quality.

### What is affected by slow storage

| Phase | Sensitive to slow/latency-heavy storage? | Why |
|-------|------------------------------------------|-----|
| **Dry-run / inspect** | **High** | Many small metadata reads and ffprobe opens |
| **Organize** | **Medium** | Renames/moves across directories; painful on high-latency mounts |
| **Sharded find** | **High** | Thousands of directory walks |
| **Encode (GPU)** | **Medium–High** | GPU is fast; slow **read** or **write** can leave the GPU idle between buffers |
| **Encode (CPU / Mac)** | **Lower** | CPU encode is slower; storage is less often the bottleneck |
| **Resume / validation** | **Medium** | Extra read passes on outputs |

### Mount types (rough guidance)

| Storage | Typical throughput | Latency | Impact on encoding |
|---------|-------------------|---------|-------------------|
| **Local NVMe / SATA SSD** | Excellent | Low | **Best** — use when possible |
| **Local HDD** | Good sequential, weaker random | Low | Fine for overnight batch jobs; sharded finds take longer |
| **NFS (gigabit+ LAN)** | Good sequential if server is strong | Medium | **Works well** for large libraries (author uses NFS). Ensure stable mount, enough server RAM/disk, and `soft` vs `hard` mount timeout policy you are comfortable with |
| **SMB/CIFS** | Variable | Often higher than NFS | **Usable**; in WSL use `file_mode=0777,dir_mode=0777,noperm` on mount; tune `vers=3.1.1`, `rsize`/`wsize`; avoid Wi‑Fi for multi‑TB writes |
| **USB 3.x external** | Moderate | Low–medium | OK for small batches; large 4K outputs may **throttle** GPU encodes |
| **USB 2.0** | Poor | Medium | **Not recommended** for transcode output |
| **WSL `/mnt/c/` on network redirector** | Poor for metadata | High | **Avoid** for `--path` on huge trees — copy or NFS-mount into WSL instead |

### Practical recommendations

1. **Point `--path` at the fastest mount that holds the library** — same path you would use for Plex/Jellyfin (e.g. `/mnt/BigMomma/Media/Movies/Chinese` on NFS).
2. **Outputs are written next to sources** — you need **free space on that same mount** and enough write bandwidth for files often **larger than the source** during encode.
3. **Do not delete originals** — plan capacity for source + output concurrently.
4. **Remote jobs:** Run the script on the machine with the **GPU**, reading media over NFS/SMB from a NAS, only if the link sustains **hundreds of Mb/s** sustained; otherwise copy a shard locally first.
5. **Wi‑Fi:** Fine for dry-run; risky for long GPU encode sessions writing tens of gigabytes.

### Quick storage sanity check

```bash
# Latency + metadata (matters for huge libraries)
time find "$YOUR_PATH" -maxdepth 2 -type f | head -100

# Sequential read (rough proxy for source throughput)
dd if="$YOUR_PATH/some-large-file.mkv" of=/dev/null bs=1M count=1024 status=progress

# Confirm what the script will use
./convert-v4.0.18.sh -p "$YOUR_PATH" --dry-run 2>&1 | head -8
```

## Quick start

```bash
chmod +x convert-v4.0.18.sh

# Dry-run on a large movies root (sharded by language folder)
./convert-v4.0.18.sh -p /mnt/BigMomma/Media/Movies --dry-run

# Transcode only — one English letter shelf
./convert-v4.0.18.sh -p /mnt/BigMomma/Media/Movies/English/D --convert-only --no-shard

# Skip files already in AV1 or HEVC (e.g. only process h264 sources)
./convert-v4.0.18.sh -p /mnt/BigMomma/Media/Movies --skip-av1 --skip-x265

# Television — preview one region first
./convert-v4.0.18.sh -p /mnt/BabyBear/Media/Television/Thai --dry-run
```

## What it does

### Dry-run inspection (`--dry-run`)

Before organize/convert phases, the script probes each video and disc source with ffprobe/HandBrake scan (no transcoding). Each entry in `convert-v4.log` includes **name**, **video format (codec)**, **length**, and **resolution**.

### Phase 1 — Organize (optional, default on)

- **All movie languages:** loose videos → `Title (YYYY)/Title (YYYY).ext` (years parenthesized)
- **English (large libraries):** A–Z + `0` (digit-led titles) shelves; loose files in any shelf → matching subfolder
- **Articles:** `The` / `A` ignored for shelf *placement* convention only
- **TV:** episodes and show folders under `Television/`, `Anime/`, etc. are **not** reorganized

### Phase 2 — Convert (default on)

- Queue sorted **largest first**, processed **one file at a time** with live HandBrake progress (`Job 3 of 47`, percent complete, ETA)
- **Auto-resume:** interrupted runs continue from the last incomplete file, or the next file after a completed one (`convert-v4.state` in the search path; `--no-resume` to start fresh)
- **Shard tracking:** compares `convert-v4.shards` between runs and logs added/removed/changed shards and new files
- **AV1** (svt_av1_10bit or nvenc_av1_10bit) kept when output is not more than **20% larger** than the source; else **x265** / nvenc_h265
- Oversized AV1 (>20% vs original): 60s mid-file sample test before x265 retry
- **ISO** and **BDMV** discs: auto-pick dominant title (>40% longer than all others); ambiguous discs skipped and logged
- Originals are **never** deleted; outputs are `{Title}.AV1.mkv` or `{Title}.x265.mkv`
- Session log: `{--path}/convert-v4.log` — single master log for the whole job (`tail -f` here). Runtime `[convert]` lines and stats both land here; never written to movie subfolders.
- Per-shard scan logs (`convert-v4.shard.log`) may appear briefly under shard directories during sharded finds; they are merged into the master log and deleted when the session ends. Orphan `convert-v4.log` files under subfolders (e.g. from older per-movie runs) are merged and removed on startup/finalize.

## Large paths and sharding

Default `--shard-depth 1` discovers top-level subdirectories under `--path` and runs `find` per shard.

- **Movies** under `Movies/English/` → shards are letter buckets (`A`, `B`, …) — sharding helps
- **TV region** under `Television/American/` → shards are **show folders** (~1,000+) — use `--no-shard` instead
- **TV root** under `Television/` → shards are regions (`American`, `Thai`, …) — default is fine

```bash
# Movies — shard by language (default)
./convert-v4.0.18.sh -p /mnt/BigMomma/Media/Movies

# English only — shard by letter bucket (A, B, C, …)
./convert-v4.0.18.sh -p /mnt/BigMomma/Media/Movies/English --shard-depth 2

# Small tree — single find
./convert-v4.0.18.sh -p /mnt/BigMomma/Media/Movies/English/D --no-shard

# TV region with ~1,000 show folders — single find (do not use default sharding)
./convert-v4.0.23.sh -p /mnt/BabyBear/Media/Television/American --convert-only --no-shard
```

## Common options

| Flag | Purpose |
|------|---------|
| `-p`, `--path DIR` | Root to scan (required) |
| `--dry-run` | Log actions only; inspect each file (name, codec, length, resolution) without converting |
| `--skip-av1` | Skip sources whose video codec is AV1 (inspection still runs) |
| `--skip-x265` | Skip sources whose video codec is HEVC/x265 (inspection still runs) |
| `--organize-only` | Phase 1 only |
| `--convert-only` | Phase 2 only |
| `--shard-depth N` | Shard find at depth N (default: 1) |
| `--no-shard` | Single `find` over entire `--path` (recommended for `Television/American`-scale trees) |
| `--no-resume` | Ignore saved resume state and process the full pending queue |
| `--ffmpeg`, `--handbrake`, … | Tool path overrides |
| `--help` | Full usage |

Environment overrides: `CONVERT_FFMPEG`, `CONVERT_HANDBRAKE`, etc.

## Television behavior

Under paths like `/mnt/BabyBear/Media/Television`:

- **Organize:** skipped for normal `Show Name/S01E01 …` layouts (episodes stay in show folders)
- **Convert:** every episode without a canonical `.AV1.mkv` / `.x265.mkv` output is transcoded (same rules as movies)
- **Sharding:** depends on what you pass as `--path` (see below)

### Sharding and large TV regions

| `--path` | Default `--shard-depth 1` means | ~shards on BabyBear |
|----------|----------------------------------|---------------------|
| `/mnt/.../Television` | One shard per **region** (`American`, `Thai`, …) | Few (good default) |
| `/mnt/.../Television/American` | One shard per **show** (`30 Rock`, `Abbott Elementary`, …) | **~1,000+** (slow startup) |

`American` has on the order of **1,000 show folders** and **40k+ episode files**. Default sharding at that path runs **one `find` per show** (plus per-shard logging and shard snapshot work) before the first encode — often slower than a single tree walk on SMB/NFS.

**Fastest ways to start on a big TV region:**

```bash
# 1) Full region — one find, skip organize (TV doesn't need it), start encoding
./convert-v4.0.23.sh -p /mnt/BabyBear/Media/Television/American \
  --convert-only --no-shard \
  --handbrake '/mnt/c/Program Files/HandBrake/HandBrakeCLI.exe'

# 2) One show — quick dry-run or convert (~100–200 episodes, seconds to enumerate)
./convert-v4.0.23.sh -p "/mnt/BabyBear/Media/Television/American/30 Rock" \
  --convert-only --no-shard --dry-run

# 3) Work region-by-region from Television/ (few shards — default depth 1 is fine)
./convert-v4.0.23.sh -p /mnt/BabyBear/Media/Television/American \
  --convert-only --no-shard   # still use --no-shard when path IS American
```

**Avoid full-tree `--dry-run` on `American`** unless you want to wait a long time: Phase 0 runs **ffprobe on every file** (~40k probes). Use dry-run on a single show, or skip dry-run and let convert skip episodes that already have complete outputs.

**Other tips:**

- `--skip-av1` / `--skip-x265` — skip sources already in those codecs (still scans the tree; inspection still ffprobes when `--dry-run` is set)
- Resume (`convert-v4.state` in the job sidecar dir) continues the queue after interrupt; the tree is still rescanned on each launch
- First encode per profile runs a short bake-off sample; after that, encoding proceeds one file at a time

Run dry-run on **one show** before converting an entire region.

## Discs (ISO / Blu-ray)

HandBrake treats `.iso` files and folders containing `BDMV/` as disc sources. The script scans titles and converts the longest only when it is more than **40% longer** than every other title; otherwise it logs:

> Unable to Determine which title you wish to convert, process this manually

## Contributors

- **Minnie** (Yorkie) — watches a lot of this with me
- **Di-Di** (Maltese) — watches a lot of this with me

## License

MIT — see [LICENSE](LICENSE).
