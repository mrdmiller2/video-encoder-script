#!/usr/bin/env python3
"""Repair convert-v4 label_mkv_tracks off-by-one language mangling.

Detects converted *.AV1.mkv / *.x265.mkv whose video track name is a channel
layout (Stereo/…) and/or whose audio+subtitle language sequence differs from
the sibling original. Restores languages/names from the original by type index
using mkvpropedit track:=UID.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

CHANNEL_LAYOUT_NAMES = {
    "mono", "stereo", "joint stereo", "dual channel", "surround",
    "2.0", "2.1", "3.0", "3.1", "4.0", "4.1", "5.0", "5.1", "6.1", "7.1",
    "atmos", "dolby atmos", "dts", "truehd", "flac", "aac", "opus", "ac3", "eac3",
}
LANG_NAMES = {
    "eng": "English", "chi": "Chinese", "jpn": "Japanese", "kor": "Korean",
    "fre": "French", "ger": "German", "spa": "Spanish", "ita": "Italian",
    "por": "Portuguese", "rus": "Russian", "tur": "Turkish",
}
ALIASES = {
    "en": "eng", "zh": "chi", "zho": "chi", "chi": "chi", "chs": "chi", "cht": "chi",
    "ja": "jpn", "jpn": "jpn", "ko": "kor", "kor": "kor", "fr": "fre", "fre": "fre",
    "de": "ger", "ger": "ger", "es": "spa", "spa": "spa", "it": "ita", "ita": "ita",
    "pt": "por", "por": "por", "ru": "rus", "rus": "rus", "tr": "tur", "tur": "tur",
}


def norm(code: str | None) -> str:
    if not code:
        return ""
    c = code.lower().strip()
    return ALIASES.get(c, c if len(c) == 3 else "")


def mkv_tracks(path: Path) -> list[dict]:
    out = subprocess.check_output(["mkvmerge", "-J", str(path)], text=True, stderr=subprocess.DEVNULL)
    return json.loads(out).get("tracks") or []


def typed(tracks: list[dict], typ: str) -> list[dict]:
    return [t for t in tracks if t.get("type") == typ]


def lang_of(t: dict) -> str:
    p = t.get("properties") or {}
    return norm(p.get("language_ietf") or p.get("language") or "")


def name_of(t: dict) -> str:
    return ((t.get("properties") or {}).get("track_name") or "").strip()


def find_original(converted: Path) -> Path | None:
    name = converted.name
    for suffix in (".AV1.mkv", ".av1.mkv", ".x265.mkv", ".X265.mkv"):
        if name.endswith(suffix):
            stem = name[: -len(suffix)]
            break
    else:
        return None
    parent = converted.parent
    candidates = [
        parent / f"{stem}.mkv",
        parent / f"{stem}.mp4",
        parent / f"{stem}.m4v",
        parent / f"{stem}.avi",
        parent / f"{stem}.ts",
        parent / f"{stem}.m2ts",
    ]
    for c in candidates:
        if c.is_file():
            return c
    # fallback: any non-converted video with same stem prefix
    for c in sorted(parent.iterdir()):
        if not c.is_file():
            continue
        if c.name == converted.name:
            continue
        if ".AV1." in c.name or ".x265." in c.name.lower():
            continue
        if c.stem == stem or c.name.startswith(stem + "."):
            if c.suffix.lower() in {".mkv", ".mp4", ".m4v", ".avi", ".ts", ".m2ts", ".mov"}:
                return c
    return None


def is_mangled(conv_tracks: list[dict], orig_tracks: list[dict] | None) -> tuple[bool, str]:
    for v in typed(conv_tracks, "video"):
        n = name_of(v).lower()
        if n in CHANNEL_LAYOUT_NAMES:
            return True, f"video_named_{name_of(v)!r}"
    if orig_tracks is None:
        return False, "no_original"
    for typ in ("audio", "subtitles"):
        o, c = typed(orig_tracks, typ), typed(conv_tracks, typ)
        if not o or not c:
            continue
        n = min(len(o), len(c))
        o_langs = [lang_of(t) for t in o[:n]]
        c_langs = [lang_of(t) for t in c[:n]]
        if o_langs != c_langs and any(o_langs) and any(c_langs):
            return True, f"{typ}_lang_mismatch {o_langs} -> {c_langs}"
    return False, "ok"


def repair(converted: Path, original: Path, dry_run: bool) -> str:
    ot, ct = mkv_tracks(original), mkv_tracks(converted)
    args = ["mkvpropedit", str(converted)]
    edits = 0
    for t in typed(ct, "video"):
        uid = (t.get("properties") or {}).get("uid")
        if uid is None:
            continue
        if name_of(t):
            args += ["--edit", f"track:={uid}", "--set", "name="]
            edits += 1
    for typ in ("audio", "subtitles"):
        o_list, c_list = typed(ot, typ), typed(ct, typ)
        for i, ct_track in enumerate(c_list):
            props_c = ct_track.get("properties") or {}
            uid = props_c.get("uid")
            if uid is None:
                continue
            props_o = (o_list[i].get("properties") or {}) if i < len(o_list) else {}
            lang = norm(props_o.get("language_ietf") or props_o.get("language") or "")
            name = (props_o.get("track_name") or "").strip()
            if not name or name.lower() in CHANNEL_LAYOUT_NAMES:
                name = LANG_NAMES.get(lang, lang.upper() if lang else "Unknown")
            args += ["--edit", f"track:={uid}", "--set", f"name={name}"]
            if lang:
                args += ["--set", f"language={lang}"]
            edits += 1
    if dry_run:
        return f"DRY_RUN edits={edits}"
    if edits == 0:
        return "no_edits"
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    return f"repaired edits={edits}"


def iter_converted(roots: list[Path]):
    for root in roots:
        if not root.exists():
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            # skip junk
            dirnames[:] = [d for d in dirnames if d not in {".Trash", "#recycle", "@eaDir"}]
            for fn in filenames:
                low = fn.lower()
                if low.endswith(".av1.mkv") or low.endswith(".x265.mkv"):
                    yield Path(dirpath) / fn


def process_one(path: Path, dry_run: bool, force: bool) -> tuple[str, str, str]:
    try:
        original = find_original(path)
        ct = mkv_tracks(path)
        ot = mkv_tracks(original) if original else None
        mangled, reason = is_mangled(ct, ot)
        if not mangled and not force:
            return (str(path), "skip", reason)
        if original is None:
            return (str(path), "need_original", reason)
        msg = repair(path, original, dry_run=dry_run)
        return (str(path), "repaired" if not dry_run else "would_repair", f"{reason}; {msg}")
    except subprocess.CalledProcessError as e:
        err = (e.stderr or str(e))[:200]
        return (str(path), "error", err)
    except Exception as e:
        return (str(path), "error", str(e)[:200])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("roots", nargs="+", type=Path)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true", help="Repair all converted files with an original present")
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--report", type=Path, default=None)
    args = ap.parse_args()

    files = list(iter_converted(args.roots))
    print(f"found_converted={len(files)} roots={args.roots}", flush=True)
    counts = {"skip": 0, "repaired": 0, "would_repair": 0, "need_original": 0, "error": 0}
    rows = []
    with ThreadPoolExecutor(max_workers=max(1, args.workers)) as ex:
        futs = {ex.submit(process_one, p, args.dry_run, args.force): p for p in files}
        for i, fut in enumerate(as_completed(futs), 1):
            path, status, detail = fut.result()
            counts[status] = counts.get(status, 0) + 1
            rows.append({"path": path, "status": status, "detail": detail})
            if status != "skip" or i % 50 == 0:
                print(f"[{i}/{len(files)}] {status}: {path} ({detail})", flush=True)
    print("SUMMARY", json.dumps(counts), flush=True)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps({"counts": counts, "rows": rows}, indent=2) + "\n")
        print(f"report={args.report}", flush=True)
    return 0 if counts.get("error", 0) == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
