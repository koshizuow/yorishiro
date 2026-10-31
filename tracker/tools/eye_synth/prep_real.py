"""Eye crops from a recording (frames/*.jpg + meta.json), the same way gen.py crops synthetic frames (adapters/eye_openness.py).
    <tracker venv python> prep_real.py <recording dir> <out.npz>
Writes crops (N x 2 x H x W x 3), lid (FaceMesh lid gap per eye), lens_glare, labels, valid.
"""
import glob
import json
import sys
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))
from yorishiro_tracker.adapters import mediapipe_points as mpp  # noqa: E402
from yorishiro_tracker.adapters.lens_glare import lens_glare  # noqa: E402
from yorishiro_tracker.mediapipe_ncnn.facemesh import FaceMesh  # noqa: E402

from yorishiro_tracker.adapters.eye_openness import CROP_H as H, CROP_W as W, crop_eyes  # noqa: E402

rec, out = Path(sys.argv[1]), sys.argv[2]
meta = json.load(open(rec / "meta.json"))
files = sorted(glob.glob(str(rec / "frames" / "*.jpg")))
mesh = FaceMesh(runtime="vulkan", flip_average=False)
crops = np.zeros((len(files), 2, H, W, 3), np.uint8)
lid = np.full((len(files), 2), np.nan)
glare = np.full((len(files), 2), np.nan)
valid = np.zeros(len(files), bool)
for i, f in enumerate(files):
    bgr = cv2.imread(f)
    lm = mesh.process(bgr)
    if lm is None:
        continue
    h, w = bgr.shape[:2]
    crops[i] = crop_eyes(bgr, lm)
    pts = mpp.landmarks_to_points(lm, w, h)
    lid[i] = [mpp._lid_gap(pts, s) for s in ("Left", "Right")]
    glare[i] = lens_glare(bgr, lm)
    valid[i] = True
labels = meta.get("labels") or [""] * len(files)
np.savez_compressed(out, crops=crops, lid=lid, lens_glare=glare, valid=valid, labels=np.array(labels),
                    timestamps_ms=np.array(meta["timestamps_ms"]))
print(f"{out}: {valid.sum()}/{len(files)} frames with a face")
