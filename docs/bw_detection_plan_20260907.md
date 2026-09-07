# B&W detection — full-runtime, fraction-based (2026-09-07)

## Problem

The old `is_bw` (`detect_source_traits`) took the **mean SATAVG of 15 probe
windows** and flagged `is_bw=1` if `mean <= 4.0`. Two failure modes:

1. **Modern content with large B&W swaths** — flashbacks, historical sequences,
   B&W episodes (WandaVision E1-E2, Watchmen, Mad Men flashbacks). A mean can be
   dragged down enough to false-positive; and 15 sparse windows can land
   disproportionately in a B&W stretch.
2. **No distribution info** — a uniformly low-saturation title (faded print,
   sepia grade, heavy teal-orange) looks identical by mean to a bimodal one
   (pure-B&W reels + pure-colour reels). Only the second is "B&W" for encode
   purposes.

The question the encoder actually needs answered: **is the overwhelming majority
of the runtime greyscale?** — a fraction, not a mean.

## Design

**Per-sample greyscale test:** signalstats `SATAVG <= SOURCE_TRAITS_BW_SATAVG_MAX`
(4.0; true greyscale sits ~0-2, faded/graded colour ~5-15, so keep 4.0 — maybe
tighten to 3.0 after calibration).

**Title-level:** `is_bw = 1` iff the **duration-weighted greyscale fraction** of
the runtime `>= SOURCE_TRAITS_BW_FRACTION_MIN` (0.90).

Also emit the raw `bw_frac` so downstream can act on the middle ground
(e.g. a 0.30-0.70 title → candidate for per-scene chroma handling, or a filing
flag: "this Classic/Modern title is 45% B&W").

### Source A — per-shot manifest  (DONE, v6.0.1V)

Every shot in the manifest already has `cx_sat` (mean SATAVG). Aggregate:

    bw_frac = Σ shot_duration[ cx_sat <= SATAVG_MAX ] / Σ shot_duration

Written to `manifest.meta` as `bw_frac=` alongside `is_bw=`. This is the whole
runtime, shot by shot, at zero extra cost. When a manifest exists it **overrides**
the sparse source-traits probe. Verified: Gun Crazy (1950) → 1.0000,
Akira (1988) → 0.0574.

### Source B — standalone probe  (TODO)

For the non-survey / no-manifest path, rework `detect_source_traits`:

- Bump probe count 15 → `SOURCE_TRAITS_BW_PROBE_WINDOWS` (30), still 10s wide,
  still spread across the runtime (`find_complexity_sample_points`, 180s
  head/tail exclusion).
- Per window: greyscale iff its SATAVG `<= SATAVG_MAX`.
- `bw_frac = greyscale_windows / total_windows`; `is_bw = bw_frac >= FRACTION_MIN`.
- Emit `is_bw=…;bw_frac=…` from `detect_source_traits`; callers read both.
- Optional cheaper alternative for a definitive answer: one
  `ffmpeg -vf fps=1/6,signalstats,metadata=print` full pass (a 2 h film = ~1200
  samples, signalstats on 1200 frames is a few seconds) — use when the 30-window
  `bw_frac` lands in an ambiguous band (0.75-0.95).

## Test / calibration harness  (TODO)

`source_traits_bw_audit <list-file>` — `<label>\t<expected 0|1>\t<path>` rows;
runs the detector, prints predicted `is_bw` + `bw_frac` vs expected, and a
confusion summary. Seed cases from the library:

| Expect | Titles |
|---|---|
| **B&W (1)** | Perry Mason (1957), Twilight Zone (1959), The Outer Limits (1963), 12 Angry Men, Dr. Strangelove, Manhattan (1979), Schindler's List (1993 — colour bookends + red coat, ~96% B&W, edge) |
| **not B&W (0)** | Akira, any teal-orange blockbuster, The Matrix (green grade), a faded 70s colour print, The Wizard of Oz (sepia Kansas ≈ 18 min + colour Oz — sepia has chroma, should read colour) |
| **modern + B&W swath (0 at file level)** | WandaVision E3+ (colour), a Mad Men episode with flashback, any war film with a B&W archival insert |
| **B&W episode (1 at file level)** | WandaVision E1 / E2 (fully B&W) — confirms per-FILE, not per-series |

Tune `SATAVG_MAX` and `FRACTION_MIN` until no false positives on the "modern +
swath" row and no false negatives on Schindler's List.

## Encoder use

`is_bw=1` → the B&W path (chroma-aware QP, no colour grain synthesis, mono-ish
chroma handling — already wired where `is_bw` is consumed). `is_bw` is per-FILE
and folder-independent, so a mis-filed B&W title in `Classic (1966-2003)` still
encodes correctly — the era folder is a human-filing hint, `is_bw` is the truth.
