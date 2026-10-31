"""Eye openness from a small CNN on each eye's crop, trained only on synthetic renders of the ICT-FaceKit
head (MIT) with random skin, lights, glasses and screen reflections (tools/eye_synth, assets/eye_openness.onnx,
116k parameters, ORT CPU about 0.2 ms for both eyes).

Why: the lid gap from FaceMesh points misses eyes behind glasses that reflect the screen, and FaceMesh pulls
a closed eye toward the open one on winks. Scored on the user's hand-labeled phone clips (2026-10-31), with
the open value from the calibration and closed below 0.4 of it: glasses 98.3 % right (lid gap 86.3 %), no
glasses 91.2 % (85.5 %), every one-eye frame right (lid gap missed 3 of 41).

Output per eye: 0 closed, about 1 for the eye the training called neutral, above 1 wide. The fitter divides by
the user's calibrated value like it did for the lid gap.
"""

from pathlib import Path

import cv2
import numpy as np
import onnxruntime as ort

MODEL = Path(__file__).resolve().parents[1] / "assets" / "eye_openness.onnx"
# crop: a box centered between the eye corners, rotated level, 1.8 eye widths wide and 1.1 high; the
# subject's right eye mirrored so both look like a left eye. The generator crops the same way.
CROP_W, CROP_H = 64, 40
SPAN_W, SPAN_H = 1.8, 1.1
CORNERS = {"Left": (362, 263), "Right": (133, 33)}


def crop_eye(bgr: np.ndarray, landmarks: np.ndarray, side: str) -> np.ndarray:
    h, w = bgr.shape[:2]
    inner, outer = (landmarks[list(CORNERS[side]), :2] * (w, h)).astype(np.float64)
    mirror = side == "Right"
    if mirror:  # inner corner on the left of the crop for both eyes
        inner, outer = outer, inner
    center = (inner + outer) / 2
    d = outer - inner
    width = np.linalg.norm(d)
    ux = d / max(width, 1e-6)
    uy = np.array([-ux[1], ux[0]])
    src = np.array([center - ux * width * SPAN_W / 2 - uy * width * SPAN_H / 2,
                    center + ux * width * SPAN_W / 2 - uy * width * SPAN_H / 2,
                    center - ux * width * SPAN_W / 2 + uy * width * SPAN_H / 2], np.float32)
    dst = np.array([[0, 0], [CROP_W, 0], [0, CROP_H]], np.float32)
    m = cv2.getAffineTransform(src, dst)
    out = cv2.warpAffine(bgr, m, (CROP_W, CROP_H),
                         flags=cv2.INTER_AREA if width > CROP_W / SPAN_W else cv2.INTER_LINEAR,
                         borderMode=cv2.BORDER_REPLICATE)
    if mirror:
        out = out[:, ::-1]
    return np.ascontiguousarray(out)


def crop_eyes(bgr: np.ndarray, landmarks: np.ndarray) -> np.ndarray:
    """(2, H, W, 3) BGR uint8, subject's left then right"""
    return np.stack([crop_eye(bgr, landmarks, s) for s in ("Left", "Right")])


def eye_widths(landmarks: np.ndarray, width: int, height: int) -> np.ndarray:
    """each eye's corner distance in pixels: a turned head shows the far eye short, behind the nose"""
    pts = landmarks[:, :2] * (width, height)
    return np.array([np.linalg.norm(pts[a] - pts[b]) for a, b in (CORNERS["Left"], CORNERS["Right"])])


class EyeOpenness:
    def __init__(self):
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = 1
        self.session = ort.InferenceSession(str(MODEL), opts, providers=["CPUExecutionProvider"])

    def __call__(self, bgr: np.ndarray, landmarks: np.ndarray) -> np.ndarray:
        """(left, right) openness, subject's sides"""
        crops = crop_eyes(bgr, landmarks).transpose(0, 3, 1, 2).astype(np.float32)
        return self.session.run(None, {"eye": crops})[0].astype(np.float64)
