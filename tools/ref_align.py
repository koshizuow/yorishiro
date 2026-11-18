#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy"]
# ///
"""A reference tracker's values per recording frame: another tracker (VTube Studio with its NVIDIA tracker, through
its plugin API) watched the recordings played into a virtual camera by the Windows player (vcam_play, frames fitted
into 1920x1080), and its values were logged with the wall clock. This puts them on each recording's frames.

    tools/ref_align.py LOG.csv PLAY.log OUT_DIR REC_DIR... [--frames FRAMES.csv] [--lag-ms N]

LOG.csv: unix_ms and the tracker's inputs (VTube Studio names) per row. PLAY.log: the player's loop starts
("<unix ms> loop <n> <dirs>"). REC_DIR...: the recordings in the order they were chained (each loop plays them one
after another, 34 ms apart). --frames: the player's log of when each frame actually went out (VCAM_PLAY_FRAMES:
unix_ms, loop, recording, frame), used instead of the planned times, so a late frame does not shift the rest. For every
frame and every full loop the log is interpolated at the frame's time plus
--lag-ms (the tracker's delay, default 0: estimate it with ref_compare.py and run again), the loops are averaged and
their spread kept. Writes OUT_DIR/<recording>.csv (frame, ms, the inputs, and <input>_spread for the eyes and mouth)
and OUT_DIR/meta.json.
"""
import argparse
import csv
import json
from pathlib import Path

import numpy as np

SPREAD = ["EyeOpenLeft", "EyeOpenRight", "MouthOpen", "MouthSmile"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log", type=Path)
    ap.add_argument("play", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("recs", type=Path, nargs="+")
    ap.add_argument("--frames", type=Path)
    ap.add_argument("--lag-ms", type=float, default=0.0)
    a = ap.parse_args()

    rows = list(csv.DictReader(open(a.log)))
    names = [k for k in rows[0] if k not in ("unix_ms", "face_found")]
    t = np.array([float(r["unix_ms"]) for r in rows])
    vals = {k: np.array([float(r[k]) for r in rows]) for k in names}
    starts = [int(l.split()[0]) for l in open(a.play) if " loop " in l]

    # each recording's frame times from the loop start, as the player chains them
    plan, offset = [], 0.0
    for rec in a.recs:
        ts = json.load(open(rec / "meta.json"))["timestamps_ms"]
        plan.append((rec.name, offset, [x - ts[0] for x in ts]))
        offset += ts[-1] - ts[0] + 34
    loop_len = offset

    sent = {}  # (loop, recording) -> array of unix ms per frame
    if a.frames:
        for row in csv.DictReader(open(a.frames)):
            sent.setdefault((int(row["loop"]), row["recording"]), {})[int(row["frame"])] = float(row["unix_ms"])
    a.out.mkdir(parents=True, exist_ok=True)
    meta = {"log": a.log.name, "frames": a.frames.name if a.frames else None, "lag_ms": a.lag_ms, "recordings": {}}
    for name, off, rel in plan:
        per_loop = []
        for li, s in enumerate(starts, 1):
            if a.frames:
                got = sent.get((li, name), {})
                if len(got) < len(rel):
                    continue  # this loop did not play all of it
                when = np.array([got[i] for i in range(len(rel))]) + a.lag_ms
            else:
                when = s + off + np.array(rel) + a.lag_ms
            if when[0] < t[0] or when[-1] > t[-1]:
                continue  # this loop is not wholly inside the log
            per_loop.append({k: np.interp(when, t, vals[k]) for k in names})
        if not per_loop:
            print(f"{name}: no full loop in the log")
            continue
        avg = {k: np.mean([p[k] for p in per_loop], axis=0) for k in names}
        frozen = [li for li, p in enumerate(per_loop) if np.std(p["FaceAngleX"]) < 0.01 and np.std(p["EyeOpenLeft"]) < 0.001]
        if frozen:
            print(f"{name}: WARNING the reference does not move in {len(frozen)} of {len(per_loop)} loops (its tracker "
                  "stopped? a camera that paused can leave it frozen: restart its tracking)")
        spread = {k: np.max([p[k] for p in per_loop], axis=0) - np.min([p[k] for p in per_loop], axis=0) for k in SPREAD}
        with open(a.out / f"{name}.csv", "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["frame", "ms"] + names + [f"{k}_spread" for k in SPREAD])
            for i, ms in enumerate(rel):
                w.writerow([i, round(ms)] + [f"{avg[k][i]:.4f}" for k in names] + [f"{spread[k][i]:.4f}" for k in SPREAD])
        meta["recordings"][name] = {"frames": len(rel), "loops": len(per_loop),
                                    "mean_spread": {k: round(float(spread[k].mean()), 4) for k in SPREAD}}
        print(f"{name}: {len(rel)} frames, {len(per_loop)} loops, mean loop-to-loop spread "
              + ", ".join(f"{k} {spread[k].mean():.3f}" for k in SPREAD))
    meta["loop_ms"] = loop_len
    meta["loop_starts"] = starts
    json.dump(meta, open(a.out / "meta.json", "w"), indent=1)


if __name__ == "__main__":
    main()
