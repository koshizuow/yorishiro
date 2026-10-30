"""Independent judges from Intel's Open Model Zoo (Apache-2.0, not MediaPipe), for evaluation only.

    <ov python> omz_worker.py OMZ_DIR REC_DIR SRC OUT.npz

Runs in its own environment (external/ov-venv: openvino, numpy, opencv-python-headless). Crops come from the
landmarks a tracker run saved (REC_DIR/eval/SRC.npz), coarse boxes only, so the judges see pixels, not
landmark geometry:
- open-closed-eye-0001: P(closed) per eye, 32x32 eye crop (trained on MRL Eye, infrared eye crops). Its README
  says the output is [open, closed], on CREMA-D it is the other way round (class 1 sits near 1 on open eyes and
  falls in blinks, r -0.58 with our blink). Glasses with screen reflections defeat it (the user's recording).
- head-pose-estimation-adas-0001: yaw, pitch, roll in degrees, 60x60 face crop.
- gaze-estimation-adas-0002: gaze vector from 60x60 eye crops and that head pose.
Eyes are the subject's own (left = 362/263, on the image's right in an unmirrored frame).
"""

import json
import sys
from pathlib import Path

import cv2
import numpy as np
import openvino as ov

EYES = {"left": (362, 263), "right": (133, 33)}
NAMES = ("closed_left", "closed_right", "yaw", "pitch", "roll", "gaze_x", "gaze_y", "gaze_z")
EYE_SCALE = 1.4  # crop side over eye-corner distance
FACE_SCALE = 1.2  # crop side over landmark box side


def crop(img, cx, cy, side, size):
    """Square crop around a center, padded with edge pixels, resized to size x size."""
    h, w = img.shape[:2]
    half = side / 2
    m = np.float32([[size / side, 0, -(cx - half) * size / side], [0, size / side, -(cy - half) * size / side]])
    return cv2.warpAffine(img, m, (size, size), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)


def chw(img):
    return img.transpose(2, 0, 1)[None].astype(np.float32)


def main():
    omz, rec, src, out = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4]
    core = ov.Core()
    eye_net = core.compile_model(str(omz / "open_closed_eye.onnx"), "CPU")
    pose_net = core.compile_model(str(omz / "head-pose-estimation-adas-0001.xml"), "CPU")
    gaze_net = core.compile_model(str(omz / "gaze-estimation-adas-0002.xml"), "CPU")
    meta = json.loads((rec / "meta.json").read_text())
    w, h = meta["size"]
    d = np.load(rec / "eval" / f"{src}.npz")
    lms, det = d["landmarks"].astype(np.float32), d["detected"]
    values = np.zeros((len(lms), len(NAMES)), np.float32)
    for i in np.nonzero(det)[0]:
        img = cv2.imread(str(rec / "frames" / f"{i:05d}.jpg"))
        p = lms[i][:, :2] * np.array([w, h], np.float32)
        lo, hi = p[:468].min(0), p[:468].max(0)
        face = crop(img, *(lo + hi) / 2, (hi - lo).max() * FACE_SCALE, 60)
        r = pose_net(chw(face))
        yaw, pitch, roll = (float(r[pose_net.output(k)].reshape(-1)[0]) for k in ("fc_y", "fc_p", "fc_r"))
        eyes60, closed = {}, {}
        for side, (a, b) in EYES.items():
            c = (p[a] + p[b]) / 2
            side_px = np.linalg.norm(p[a] - p[b]) * EYE_SCALE
            e32 = crop(img, *c, side_px, 32)
            prob = eye_net((chw(e32) - 127.0) / 255.0)[eye_net.output(0)].reshape(-1)
            closed[side] = float(prob[0])
            eyes60[side] = crop(img, *c, side_px, 60)
        # the demo's "left eye" is the one on the image's left, the subject's right
        g = gaze_net({"left_eye_image": chw(eyes60["right"]), "right_eye_image": chw(eyes60["left"]),
                      "head_pose_angles": np.array([[yaw, pitch, roll]], np.float32)})
        gx, gy, gz = g[gaze_net.output(0)].reshape(-1)
        values[i] = [closed["left"], closed["right"], yaw, pitch, roll, gx, gy, gz]
    np.savez_compressed(out, names=np.array(NAMES), values=values, detected=det,
                        labels=d["labels"] if "labels" in d.files else np.array([""] * len(lms)))
    print(f"{out}: {det.sum()} faces")


if __name__ == "__main__":
    main()
