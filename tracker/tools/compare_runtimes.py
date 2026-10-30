"""Compare FaceMesh-V2 runtimes against the ORT CPU FP32 reference (D2) on real crops of a recording.

    uv run python tools/compare_runtimes.py data/recordings/<ts> [runtime ...] [--step 5]

Crops come from tracking the recording with ort-cpu, so every runtime sees exactly the same input.
Three layers, as in skills/face-tracker-validation: landmark error in crop pixels per region, the worst
crops, and the ICT-fitted blendshape difference (each runtime calibrated on its own landmarks of the same
neutral crop). Also the median time per landmark run.
"""

import argparse
import sys
import time
from pathlib import Path

import cv2
import numpy as np
from mediapipe.tasks.python.vision import FaceLandmarksConnections as C

from yorishiro_tracker.adapters.mediapipe_points import MediaPipePointFitter
from yorishiro_tracker.avatar.ict import ensure_ict_facekit
from yorishiro_tracker.backends.factory import open_model
from yorishiro_tracker.frame import ARKIT52
from yorishiro_tracker.mediapipe_ncnn import landmarks as lmk
from yorishiro_tracker.mediapipe_ncnn.facemesh import MP_DIR, FaceMesh


def _idx(*sets):
    return sorted({i for s in sets for c in s for i in (c.start, c.end)})


REGIONS = {
    "lips": _idx(C.FACE_LANDMARKS_LIPS),
    "eyes": _idx(C.FACE_LANDMARKS_LEFT_EYE, C.FACE_LANDMARKS_RIGHT_EYE),
    "brows": _idx(C.FACE_LANDMARKS_LEFT_EYEBROW, C.FACE_LANDMARKS_RIGHT_EYEBROW),
    "iris": list(range(468, 478)),
    "oval": _idx(C.FACE_LANDMARKS_FACE_OVAL),
}
NEUTRAL = 30  # crop index used as the neutral, after the ROI has settled (D13)


def crops_from(rec: Path, step: int):
    mesh = FaceMesh("ort-cpu")
    out = []
    frames = sorted((rec / "frames").glob("*.jpg"))
    for i, f in enumerate(frames):
        bgr = cv2.imread(str(f))
        roi = mesh.roi
        if mesh.process(bgr) is None or roi is None or i % step:
            continue
        m = lmk.roi_matrix(*roi)
        out.append((lmk.preprocess(bgr, m), m, bgr.shape[1], bgr.shape[0], i))
    return out


def run(runtime: str, crops):
    model = open_model(MP_DIR / "face_landmarks", runtime)
    model.run({"in0": crops[0][0]})  # warm up (engine build, shader compile)
    pts, times = [], []
    for x, *_ in crops:
        t = time.perf_counter()
        out = model.run({"in0": x})
        times.append((time.perf_counter() - t) * 1000)
        pts.append(np.asarray(out["out0"], np.float64).reshape(478, 3))
    return model.name, np.stack(pts), float(np.median(times))


def blendshapes(pts, crops, fitter):
    aligned = []
    for p, (_, m, w, h, _) in zip(pts, crops):
        a, _ = fitter.align(lmk.postprocess(p.reshape(-1), m, w, h), w, h)
        aligned.append(a)
    fitter.calibrate(aligned[NEUTRAL])
    return np.stack([fitter.expressions(a) + fitter.gaze(a) for a in aligned])  # as FaceMeshGpuTracker


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("recording", type=Path)
    ap.add_argument("runtimes", nargs="*", default=["vulkan", "vulkan-fp32", "ncnn-cpu", "cuda", "tensorrt"])
    ap.add_argument("--step", type=int, default=5)
    a = ap.parse_args()
    crops = crops_from(a.recording, a.step)
    print(f"{len(crops)} crops from {a.recording}", file=sys.stderr)
    head = ensure_ict_facekit()
    ref_name, ref, ref_ms = run("ort-cpu", crops)
    ref_bs = blendshapes(ref, crops, MediaPipePointFitter(head))
    print(f"reference {ref_name}: {ref_ms:.2f} ms per run")
    print(f"{'runtime':24} {'ms':>6} {'mean px':>8} {'p95':>6} {'max':>6}  " + " ".join(f"{r:>6}" for r in REGIONS)
          + f"  {'BS p95':>7} {'BS max':>7}  worst shapes / crops")
    for rt in a.runtimes:
        try:
            name, pts, ms = run(rt, crops)
        except SystemExit as e:
            print(f"{rt:24} skipped: {e}")
            continue
        err = np.linalg.norm(pts[:, :, :2] - ref[:, :, :2], axis=2)  # crop pixels (256 px crop)
        regions = " ".join(f"{err[:, idx].mean():6.3f}" for idx in REGIONS.values())
        d = np.abs(blendshapes(pts, crops, MediaPipePointFitter(head)) - ref_bs)
        worst = np.argsort(d.max(0))[::-1][:3]
        shapes = ", ".join(f"{ARKIT52[k]} {d[:, k].max():.3f}" for k in worst)
        frames = ", ".join(str(crops[k][4]) for k in np.argsort(err.mean(1))[::-1][:3])
        print(f"{name:24} {ms:6.2f} {err.mean():8.3f} {np.percentile(err, 95):6.3f} {err.max():6.2f}  {regions}"
              f"  {np.percentile(d, 95):7.4f} {d.max():7.4f}  {shapes} / frames {frames}")


if __name__ == "__main__":
    main()
