# Video Encoder script

Portable Bash library organizer and batch transcoder for large home-media trees. Targets **MKV + AV1** (kept when not more than **20% larger** than the source) with **x265** fallback, optional **ISO/Blu-ray** disc handling, and **sharded** directory scans for multi-thousand-file libraries.

**Current release:** `convert-v4.0.6.sh` (v4.0.6)

## Version progression

Each release is a **new file** — prior scripts stay in the repo for reference:

| File | Version | Notes |
|------|---------|--------|
| `convert-v4.0.5.sh` | 4.0.5 | Initial v4 release; 8 GB AV1 oversized threshold |
| `convert-v4.0.6.sh` | 4.0.6 | **Current** — 20% vs-original AV1 policy; `SCRIPT_NAME` check |

When bumping version: copy the latest script to `convert-v{NEW}.sh`, update `VERSION` and `SCRIPT_NAME`, keep all older files. Do not rename or overwrite.

## Genesis

This project evolved from three small batch encoders in [`genesis/`](genesis/):

- **`convert-v1.sh`** — original Linux/nvdec AV1 encoder (`.avi`, `.mp4`, `.mkv`, `.ts` in cwd)
- **`convert-anime.sh`** — macOS HandBrakeCLI + VideoToolbox, SVT-AV1 anime profile, Opus audio
- **`convert-anime-flatpak.sh`** — same pipeline via Flatpak HandBrake + nvdec

Those scripts scanned the current directory and wrote `{title}-av1.mkv`. v4 keeps the anime encoder profile and GPU paths, and adds organization rules, TV detection, disc title selection, NVENC bake-off, validation, and sharded finds. See [`genesis/README.md`](genesis/README.md) for the full lineage table.

## Requirements

- **bash 4+** (Linux, WSL, Cygwin) or **zsh** (macOS — re-exec’d automatically)
- **ffmpeg**, **ffprobe**, **HandBrakeCLI**, **mkvpropedit**, **mkvmerge**
- Optional: NVIDIA GPUs for nvenc/nvdec; Flatpak HandBrake on Linux (`fr.handbrake.ghb`)

Install example (Fedora):

```bash
sudo dnf install ffmpeg mkvtoolnix HandBrake-cli
```

## Quick start

```bash
chmod +x convert-v4.0.6.sh

# Dry-run on a large movies root (sharded by language folder)
./convert-v4.0.6.sh -p /mnt/BigMomma/Media/Movies --dry-run

# Transcode only — one English letter shelf
./convert-v4.0.6.sh -p /mnt/BigMomma/Media/Movies/English/D --convert-only --no-shard

# Television — preview one region first
./convert-v4.0.6.sh -p /mnt/BabyBear/Media/Television/Thai --dry-run
```

## What it does

### Phase 1 — Organize (optional, default on)

- **All movie languages:** loose videos → `Title (YYYY)/Title (YYYY).ext` (years parenthesized)
- **English (large libraries):** A–Z + `0` (digit-led titles) shelves; loose files in any shelf → matching subfolder
- **Articles:** `The` / `A` ignored for shelf *placement* convention only
- **TV:** episodes and show folders under `Television/`, `Anime/`, etc. are **not** reorganized

### Phase 2 — Convert (default on)

- Queue sorted **largest first**
- **AV1** (svt_av1_10bit or nvenc_av1) kept when output is not more than **20% larger** than the source; else **x265** / nvenc_h265
- Oversized AV1 (>20% vs original): 60s mid-file sample test before x265 retry
- **ISO** and **BDMV** discs: auto-pick dominant title (>40% longer than all others); ambiguous discs skipped and logged
- Originals are **never** deleted; outputs are `{Title}.AV1.mkv` or `{Title}.x265.mkv`
- Session log: `{search-path}/convert-v4.log`

## Large paths and sharding

Default `--shard-depth 1` discovers top-level subdirectories under `--path` and runs `find` per shard (e.g. `English`, `Chinese`, `Japanese` under `Movies`, or `American`, `Thai` under `Television`).

```bash
# Movies — shard by language (default)
./convert-v4.0.6.sh -p /mnt/BigMomma/Media/Movies

# English only — shard by letter bucket (A, B, C, …)
./convert-v4.0.6.sh -p /mnt/BigMomma/Media/Movies/English --shard-depth 2

# Small tree — single find
./convert-v4.0.6.sh -p /mnt/BigMomma/Media/Movies/English/D --no-shard
```

## Common options

| Flag | Purpose |
|------|---------|
| `-p`, `--path DIR` | Root to scan (required) |
| `--dry-run` | Log actions only |
| `--organize-only` | Phase 1 only |
| `--convert-only` | Phase 2 only |
| `--shard-depth N` | Shard find at depth N (default: 1) |
| `--no-shard` | Monolithic find |
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

## License

MIT — see [LICENSE](LICENSE).
