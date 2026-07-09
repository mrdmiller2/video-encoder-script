# Video Encoder script

I started this project back in 2024 because my video libraries were getting too large (can't keep buying drives) an I wanted uniformity with the file formats.. (over 10 years in collecting).. so I wanted a way to convert and let it run. HandbrakeCLI does a great job at the conversion but it takes too long to put things in batches.. And I like my data organized where possible.. 

Hence the start of this little project.  It converts, organizes, strips out the old junk metadata (we get things frm "places" and don't want plex or other things to show that, so at the end, you have a nice clean AV1 file or a x265 file.. whichever works best and provides the best size amount. Its been my experience that not every conversion will yield results.. so I put in some logic that if the file is larger, then try as a x265 (if doing AV1). 

This script is portable (because I often have my windows laptop, mac, and linux machines running on this, and had to create like 3 or 6 versions (some for anime, some for flatpack versions of handbrake, some for regular movies and tv shows).. so this script tries to unify them all into an uber script. (the original sources are in the genesis folder to cover the use case specific ones). 

Bash library organizer and batch transcoder for large home-media trees. Targets **MKV + AV1** (kept when not more than **20% larger** than the source) with **x265** fallback, optional **ISO/Blu-ray** disc handling, and **sharded** directory scans for multi-thousand-file libraries.

**Current release:** `convert-v4.0.18.sh` (v4.0.18)

## About this project

I started this project back in 2024 because my video libraries were getting too large — I can't keep buying drives — and I wanted uniformity in file formats. After more than ten years of collecting, I needed a way to convert and let it run. HandBrakeCLI does a great job at conversion, but it takes too long to batch things by hand. And I like my data organized where possible.

Hence this little project. It converts, organizes, and strips out old junk metadata. We get things from "places" and don't want Plex or other apps surfacing that, so at the end you have a nice clean AV1 file or an x265 file — whichever works best and gives the best size. It has been my experience that not every conversion yields good results, so I added logic: if the AV1 output is larger than the source, try x265 instead.

The script is portable because I often have my Windows laptop, Mac, and Linux machines working on the same libraries. Over time that meant three or six separate scripts — some for anime, some for Flatpak HandBrake, some for regular movies and TV shows. This script tries to unify them into one uber-script. The original use-case-specific sources live in the [`genesis/`](genesis/) folder.

## Version progression

Each release is a **new file** — prior scripts stay in the repo for reference:

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
| `convert-v4.0.18.sh` | 4.0.18 | **Current** — master log at `--path`; shard logs merged/cleaned at end |

When bumping version: copy the latest script to `convert-v{NEW}.sh`, update `VERSION` and `SCRIPT_NAME`, keep all older files. Do not rename or overwrite.

## Genesis

This project evolved from three small batch encoders in [`genesis/`](genesis/):

- **`convert-v1.sh`** — original Linux/nvdec AV1 encoder (`.avi`, `.mp4`, `.mkv`, `.ts` in cwd)
- **`convert-anime.sh`** — macOS HandBrakeCLI + VideoToolbox, SVT-AV1 anime profile, Opus audio
- **`convert-anime-flatpak.sh`** — same pipeline via Flatpak HandBrake + nvdec

Those scripts scanned the current directory and wrote `{title}-av1.mkv`. v4 keeps the anime encoder profile and GPU paths, and adds organization rules, TV detection, disc title selection, NVENC bake-off, validation, and sharded finds. See [`genesis/README.md`](genesis/README.md) for the full lineage table.

## Environment requirements

The script runs on **Linux**, **WSL2**, **Cygwin/MSYS2/Git Bash**, and **macOS**. It does **not** run in plain Windows PowerShell or CMD.

### Tools (all platforms)

| Tool | Used for |
|------|----------|
| **ffmpeg** / **ffprobe** | Probing, remux, validation decode windows, NVENC tune probe |
| **HandBrakeCLI** | Transcode (AV1, HEVC, disc scan), hardware decode when available |
| **mkvmerge** / **mkvpropedit** | Subtitles, metadata, output validation |

Override paths with `CONVERT_FFMPEG`, `CONVERT_HANDBRAKE`, etc., or `--ffmpeg`, `--handbrake`, …

On startup the script prints the binaries it picked — that line is the source of truth for your machine.

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

---

### Linux (native)

**Shell:** bash 4+

**Install example (Fedora):**

```bash
sudo dnf install ffmpeg mkvtoolnix HandBrake-cli
```

**Install example (Debian/Ubuntu):**

```bash
sudo apt install ffmpeg mkvtoolnix handbrake-cli
```

**Optional:** Flatpak HandBrake (`fr.handbrake.ghb`) — auto-detected if distro packages are missing.

**NVIDIA GPU:** Install proprietary drivers so `nvidia-smi` works. No separate CUDA Toolkit is required for NVENC.

**Typical `--path`:** local mount (`/mnt/BigMomma/...`, `/media/...`) or NFS mount configured in `/etc/fstab`.

---

### Windows (WSL2 — recommended)

**Shell:** bash 4+ inside a WSL2 distro (Ubuntu, Fedora, etc.). The script sets `PLATFORM=wsl`.

**GPU:** Install current NVIDIA drivers on the **Windows host**. `nvidia-smi` must work **inside WSL**. WSL1 is not supported for this workflow.

**Linux vs Windows binaries:** The script does **not** prefer one or the other. It uses, in order:

1. `CONVERT_*` / CLI overrides  
2. First match on WSL `PATH` (`which ffmpeg`, etc.)  
3. Linux paths (`/usr/bin`, `/usr/local/bin`, `~/.local/bin`)  
4. Flatpak HandBrake (Linux/WSL only)

It does **not** auto-search `C:\Program Files\...` on WSL. To use Windows HandBrake or ffmpeg, set paths explicitly:

```bash
export CONVERT_HANDBRAKE='/mnt/c/Program Files/HandBrake/HandBrakeCLI.exe'
```

**Recommendation:** Use one consistent toolchain — usually **Linux packages inside WSL** (`apt`/`dnf` ffmpeg + mkvtoolnix + handbrake-cli). Mixing Linux ffmpeg with Windows HandBrake works if you set `CONVERT_*` deliberately.

**Mounting media in WSL:**

| How you access library | WSL `--path` example | Notes |
|------------------------|----------------------|-------|
| NFS (mounted in WSL) | `/mnt/BigMomma/Media/Movies` | Best remote option when the NFS server and network are fast |
| SMB share mounted in WSL (`cifs`) | `/mnt/movies` | Common; tune `vers=3.1.1`, large `rsize`/`wsize`; latency-sensitive |
| Windows drive letter | `/mnt/c/Users/...` | Fine for local NTFS; **slow** for huge trees (drvfs metadata) |
| `\\server\share` only on Windows | Mount into WSL first — avoid encoding through `/mnt/c/...` to a redirected network drive |

---

### Windows (Cygwin / MSYS2 / Git Bash)

**Shell:** bash 4+; script sets `PLATFORM=windows`.

**Tools:** Install Windows builds of ffmpeg, MKVToolNix, and HandBrakeCLI, or point `CONVERT_*` at `C:\Program Files\...` (script also checks `/cygdrive/c/Program Files/...`).

**GPU:** `nvidia-smi.exe` must be on `PATH` (typically `C:\Windows\System32`).

Less tested than WSL2; prefer WSL2 for large library jobs.

---

### macOS

**Shell:** zsh (automatic re-exec from bash 3.2).

**Tools:**

```bash
brew install ffmpeg mkvtoolnix handbrake
```

HandBrake is also searched under `/Applications/HandBrake.app/Contents/MacOS/HandBrakeCLI`.

**GPU:** No NVIDIA NVENC path on Apple Silicon / Intel Macs in this script. Hardware **decode** uses **VideoToolbox** when HandBrake supports it; **encode** is **software** (`svt_av1_10bit`, `x265`). Expect longer runtimes than a Linux/WSL NVIDIA box.

**Mounting media:**

| How you access library | Typical `--path` | Notes |
|------------------------|------------------|-------|
| Local APFS volume | `/Volumes/Media/Movies` | Fastest |
| NFS (`mount -t nfs`) | `/Volumes/nfs-media/...` or mount point you chose | Good on gigabit LAN; same latency caveats as Linux NFS |
| SMB (`mount_smbfs`) | `/Volumes/share-name/...` | Very common on Mac; fine for reads, watch write speed during encode |
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
| **SMB/CIFS** | Variable | Often higher than NFS | **Usable**; tune mount options; avoid Wi‑Fi or congested links for multi‑TB writes |
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

Default `--shard-depth 1` discovers top-level subdirectories under `--path` and runs `find` per shard (e.g. `English`, `Chinese`, `Japanese` under `Movies`, or `American`, `Thai` under `Television`).

```bash
# Movies — shard by language (default)
./convert-v4.0.18.sh -p /mnt/BigMomma/Media/Movies

# English only — shard by letter bucket (A, B, C, …)
./convert-v4.0.18.sh -p /mnt/BigMomma/Media/Movies/English --shard-depth 2

# Small tree — single find
./convert-v4.0.18.sh -p /mnt/BigMomma/Media/Movies/English/D --no-shard
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
| `--no-resume` | Ignore saved resume state and process the full pending queue |
| `--ffmpeg`, `--handbrake`, … | Tool path overrides |
| `--help` | Full usage |

Environment overrides: `CONVERT_FFMPEG`, `CONVERT_HANDBRAKE`, etc.

## Television behavior

Under paths like `/mnt/BabyBear/Media/Television`:

- **Organize:** skipped for normal `Show Name/S01E01 …` layouts
- **Convert:** every episode without a canonical output is transcoded (same AV1/x265 rules as movies)
- **Sharding:** depth 1 → one shard per region (`American`, `Thai`, …)

Run dry-run per region before converting an entire Television tree.

## Discs (ISO / Blu-ray)

HandBrake treats `.iso` files and folders containing `BDMV/` as disc sources. The script scans titles and converts the longest only when it is more than **40% longer** than every other title; otherwise it logs:

> Unable to Determine which title you wish to convert, process this manually

## Contributors

- **Minnie** (Yorkie) — watches a lot of this with me
- **Di-Di** (Maltese) — watches a lot of this with me

## License

MIT — see [LICENSE](LICENSE).
