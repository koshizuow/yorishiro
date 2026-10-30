"""Run trackers over a recording and store every frame's output, for tools/compare_trackers.py.

    uv run python tools/run_trackers.py data/recordings/<rec> mediapipe facemesh:tensorrt osf
    (names: any registered tracker, optionally name:runtime, and osf for OpenSeeFace)

Writes <rec>/eval/<name>.npz with names (output channels), values (frames x channels), detected, ms
(wall time of the tracker call per frame), cpu_s (process CPU time over the run) and, for our trackers,
landmarks (478 MediaPipe points, float16) so solver changes can be tried without rerunning the networks.

A recording is split into sessions, each with a fresh tracker that calibrates its neutral like serve does,
the way a user starts the app and sits still first: one session for a plain recording. For CREMA-D (clip names 1001_IEO_ANG_HI.flv) one session per
actor with their neutral clip first, so trackers that take the first face as neutral (facemesh,
mediapipe-fit) and OpenSeeFace, which learns each feature's range as it goes, start from that actor's
neutral face.

OpenSeeFace (BSD-2) is not a dependency. It runs stock, in its own pinned environment, through
tools/osf_worker.py: OSF_DIR is a checkout (default external/OpenSeeFace next to the repo), OSF_PYTHON a
Python 3.9 venv with its pyproject pins (default external/osf-venv).
"""

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import cv2
import numpy as np

from yorishiro_tracker.frame import FRAME_NAMES
from yorishiro_tracker.registry import create_tracker
from yorishiro_tracker.serve import CALIBRATE_FACES, SETTLE_FACES

ROOT = Path(__file__).resolve().parent.parent
OSF_DIR = Path(os.environ.get("OSF_DIR", ROOT.parent.parent / "external" / "OpenSeeFace"))
OSF_PYTHON = Path(os.environ.get("OSF_PYTHON", OSF_DIR.parent / "osf-venv" / "bin" / "python"))


def sessions(meta: dict) -> list[list[int]]:
    """Frame index lists, one per session, in the order they are fed."""
    clips = meta.get("clips")
    if not clips:
        return [list(range(meta["count"]))]
    by_actor: dict[str, list[dict]] = {}
    for c in clips:
        by_actor.setdefault(c["file"].split("_")[0], []).append(c)
    out = []
    for actor in sorted(by_actor):
        cs = sorted(by_actor[actor], key=lambda c: (not c["file"].split("_")[2].startswith("NEU"), c["file"]))
        out.append([i for c in cs for i in range(c["first"], c["first"] + c["count"])])
    return out


def run_osf(rec: Path, meta: dict) -> dict:
    """OpenSeeFace runs in its own pinned environment through tools/osf_worker.py."""
    with tempfile.TemporaryDirectory() as tmp:
        job = Path(tmp) / "job.json"
        out = Path(tmp) / "out.npz"
        job.write_text(json.dumps({"frames_dir": str(rec / "frames"), "width": meta["size"][0],
                                   "height": meta["size"][1], "count": meta["count"], "sessions": sessions(meta)}))
        subprocess.run([str(OSF_PYTHON), str(Path(__file__).with_name("osf_worker.py")), str(OSF_DIR), str(job),
                        str(out)], check=True)
        d = np.load(out)
        return {k: d[k] for k in ("names", "values", "detected", "ms")} | {"cpu_s": float(d["cpu_s"])}


def run(rec: Path, spec: str):
    meta = json.loads((rec / "meta.json").read_text())
    n = meta["count"]
    name, _, runtime = spec.partition(":")
    if name == "osf":
        r = run_osf(rec, meta)
        names, values, detected, ms, cpu_s = r["names"], r["values"], r["detected"], r["ms"], r["cpu_s"]
    else:
        names = FRAME_NAMES
        values = np.zeros((n, len(names)), np.float32)
        landmarks = np.zeros((n, 478, 3), np.float32)
        detected = np.zeros(n, bool)
        ms = np.zeros(n, np.float32)
        cpu0 = time.process_time()
        stamps = meta["timestamps_ms"]
        for frames in sessions(meta):
            tracker = create_tracker(name, runtime or None)
            # sessions reorder clips, MediaPipe's video mode needs increasing timestamps: keep each frame's
            # step from the one before it in the recording, 33 ms across a clip boundary
            ts = 0
            faces, window = 0, None
            try:
                for k, i in enumerate(frames):
                    if k:
                        step = stamps[i] - stamps[frames[k - 1]]
                        ts += step if 0 < step < 200 else 33
                    img = cv2.imread(str(rec / "frames" / f"{i:05d}.jpg"))
                    t0 = time.perf_counter()
                    res = tracker.process(img, ts)
                    ms[i] = (time.perf_counter() - t0) * 1000
                    if res is not None:
                        # serve's neutral: the tracker's provisional first face, then the median of
                        # CALIBRATE_FACES frames once tracking has settled
                        faces += 1
                        if faces == SETTLE_FACES:
                            window = []
                        if window is not None:
                            window.append(res)
                            if len(window) == CALIBRATE_FACES:
                                tracker.calibrate_window(window)
                                window = None
                        values[i] = res.frame.to_vector()
                        landmarks[i] = res.landmarks
                        detected[i] = True
            finally:
                tracker.close()
        cpu_s = time.process_time() - cpu0
    out_dir = rec / "eval"
    out_dir.mkdir(exist_ok=True)
    tag = spec.replace(":", "-")
    extra = {} if name == "osf" else {"landmarks": landmarks.astype(np.float16)}
    np.savez_compressed(out_dir / f"{tag}.npz", names=np.array(names), values=values, detected=detected,
                        ms=ms, cpu_s=cpu_s, labels=np.array(meta.get("labels") or [""] * n), **extra)
    print(f"{tag}: {detected.sum()}/{n} faces, median {np.median(ms):.2f} ms, CPU {cpu_s:.1f} s")


def main():
    rec = Path(sys.argv[1])
    for spec in sys.argv[2:]:
        run(rec, spec)


if __name__ == "__main__":
    main()
