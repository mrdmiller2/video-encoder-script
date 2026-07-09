# Genesis scripts

These are the earlier single-purpose encoders that `convert-v4.0.5.sh` grew from.

## `convert-anime.sh`

- **Era:** macOS / VideoToolbox
- **Scope:** Current directory only; finds `.avi`, `.mp4`, `.mkv`
- **Behavior:** AV1 transcode via HandBrake `svt_av1_10bit` with anime-tuned encopts (film grain, lapsharp, Opus 100 kbps), or metadata-only pass when already AV1
- **Output:** `{filename}-av1.mkv` beside the original

## `convert-anime-flatpak.sh`

- Same logic as `convert-anime.sh`, but HandBrake runs through Flatpak (`fr.handbrake.ghb`) with **nvdec** hardware decode instead of VideoToolbox.

## What carried forward into v4

| Genesis idea | v4 implementation |
|--------------|-------------------|
| AV1-first with metadata fix-up | `process_existing_av1`, `finalize_mkv_output` |
| Anime SVT encopts + lapsharp | `load_encoder_profile` anime branch |
| HandBrake + ffmpeg + mkvtoolnix | Portable tool discovery, Flatpak fallback |
| Flatpak + nvdec | NVIDIA path with `CUDA_VISIBLE_DEVICES` |
| Simple find loop | Sharded find, largest-first queue, TV/movie/disk rules |

The monolithic `convert-v4.0.5.sh` adds library organization, x265 fallback, size policy, ISO/BDMV discs, sharding, and multi-platform support (Linux, WSL, Cygwin, macOS).
