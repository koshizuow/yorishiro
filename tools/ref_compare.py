#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy"]
# ///
"""How close Yorishiro's inputs are to a reference tracker's on the same recordings, frame by frame.

    tools/ref_compare.py REF_DIR OURS_DIR [recording ...]

REF_DIR: tools/ref_align.py's output (<recording>.csv). OURS_DIR: track_camera's TRACK_CSV of each recording
replayed with FIT=1920x1080 (<recording>.csv). Not a pass/fail test: the two trackers scale and smooth their values
differently, so per input it prints the correlation at the best shift (and the shift: positive = ours later), the
linear map from the reference to ours (ours ~ a * ref + b), and both ranges; and for each eye the blinks: a closing is
a dip below 40 % of that signal's own open level (its 90th percentile) for at least two frames, matched when the two
closings overlap (within 2 frames), as recall (the reference's blinks we also see) and precision (ours that the reference also sees).
"""
import csv
import sys
from pathlib import Path

import numpy as np

INPUTS = ["FaceAngleX", "FaceAngleY", "FaceAngleZ", "EyeOpenLeft", "EyeOpenRight", "MouthOpen", "MouthSmile",
          "BrowLeftY", "BrowRightY", "EyeLeftX", "EyeLeftY"]
MAX_SHIFT = 10


def load(path: Path) -> dict:
    rows = list(csv.DictReader(open(path)))
    out = {"frame": np.array([int(r["frame"]) for r in rows])}
    found = np.array([r.get("found", "1") == "1" for r in rows])
    for k in INPUTS:
        out[k] = np.array([float(r[k]) if r.get(k) not in (None, "") else np.nan for r in rows])
    out["found"] = found
    return out


def best_shift(ref, ours):
    best = (np.nan, 0)
    for s in range(-MAX_SHIFT, MAX_SHIFT + 1):
        a, b = (ref[:len(ref) - s], ours[s:]) if s >= 0 else (ref[-s:], ours[:len(ours) + s])
        m = ~(np.isnan(a) | np.isnan(b))
        if m.sum() < 30 or a[m].std() < 1e-6 or b[m].std() < 1e-6:
            continue
        r = np.corrcoef(a[m], b[m])[0, 1]
        if np.isnan(best[0]) or r > best[0]:
            best = (r, s)
    return best


def closings(x):
    """(start, end) frame spans of the closings""" 
    ok = ~np.isnan(x)
    if ok.sum() < 30:
        return []
    level = np.percentile(x[ok], 90)
    shut = np.where(ok, x < 0.4 * level, False)
    starts = []
    i = 0
    while i < len(shut):
        if shut[i]:
            j = i
            while j < len(shut) and shut[j]:
                j += 1
            if j - i >= 2:
                starts.append((i, j))
            i = j
        else:
            i += 1
    return starts


def match(ref, ours, tol=2):
    """closings that overlap, give or take tol frames (the trackers close for different lengths)"""
    near = lambda a, b: a[0] - tol < b[1] and b[0] - tol < a[1]
    hit = sum(1 for r in ref if any(near(r, o) for o in ours))
    good = sum(1 for o in ours if any(near(r, o) for r in ref))
    return hit, good


def main():
    ref_dir, ours_dir = Path(sys.argv[1]), Path(sys.argv[2])
    names = sys.argv[3:] or sorted(p.stem for p in ref_dir.glob("*.csv") if (ours_dir / p.name).exists())
    totals = {k: [] for k in INPUTS}
    blink_tot = {"ref": 0, "ours": 0, "hit": 0, "good": 0}
    for name in names:
        ref, ours = load(ref_dir / f"{name}.csv"), load(ours_dir / f"{name}.csv")
        n = min(len(ref["frame"]), len(ours["frame"]))
        print(f"== {name}: {n} frames, ours found a face in {ours['found'][:n].mean() * 100:.0f} %")
        print(f"  {'input':<13} {'r':>5} {'shift':>5}  {'ours ~ a*ref+b':<16} {'ref p5..p95':<17} {'ours p5..p95':<17}")
        for k in INPUTS:
            a, b = ref[k][:n], ours[k][:n]
            r, s = best_shift(a, b)
            m = ~(np.isnan(a) | np.isnan(b))
            fit = np.polyfit(a[m], b[m], 1) if m.sum() > 30 and a[m].std() > 1e-6 else (np.nan, np.nan)
            pa, pb = np.nanpercentile(a, [5, 95]), np.nanpercentile(b, [5, 95])
            totals[k].append((r, m.sum()))
            print(f"  {k:<13} {r:5.2f} {s:+5d}  {fit[0]:6.2f}*ref{fit[1]:+6.2f}  {pa[0]:7.2f}..{pa[1]:<7.2f}  {pb[0]:7.2f}..{pb[1]:<7.2f}")
        for eye in ("EyeOpenLeft", "EyeOpenRight"):
            cr, co = closings(ref[eye][:n]), closings(ours[eye][:n])
            hit, good = match(cr, co)
            blink_tot["ref"] += len(cr); blink_tot["ours"] += len(co); blink_tot["hit"] += hit; blink_tot["good"] += good
            rec = f"{hit}/{len(cr)}" if cr else "-"
            prec = f"{good}/{len(co)}" if co else "-"
            print(f"  blinks {eye:<13} reference {len(cr):3d}, ours {len(co):3d}, recall {rec}, precision {prec}")
    print("== all recordings (frame-weighted correlation)")
    for k in INPUTS:
        v = [(r, w) for r, w in totals[k] if not np.isnan(r)]
        if v:
            print(f"  {k:<13} r {sum(r * w for r, w in v) / sum(w for _, w in v):.3f}")
    b = blink_tot
    print(f"  blinks: recall {b['hit']}/{b['ref']} ({b['hit'] / max(b['ref'], 1) * 100:.0f} %), "
          f"precision {b['good']}/{b['ours']} ({b['good'] / max(b['ours'], 1) * 100:.0f} %)")


if __name__ == "__main__":
    main()
