"""SMIRK expression encoder (research model, dev stand-in).

Preprocessing and output layout follow https://github.com/georgeretsi/smirk (MIT,
Copyright (c) 2024 George Retsinas). Weights need FLAME for geometry, which is
non-commercial and must be downloaded by the user.
"""

from dataclasses import dataclass

import cv2
import numpy as np

from ..models import MODEL_DIR

SMIRK_DIR = MODEL_DIR / "research" / "smirk"
INPUT_SIZE = 224
CROP_SCALE = 1.4
N_EXP = 50


@dataclass
class SmirkExpression:
    expression: np.ndarray  # (50,) FLAME expression PCA coefficients
    eyelid: np.ndarray  # (2,) FLAME eyelid closure in [0, 1]
    jaw: np.ndarray  # (3,) jaw open (>= 0) and two lateral terms in [-0.2, 0.2]


def crop_matrix(landmarks_px: np.ndarray) -> np.ndarray:
    """Axis-aligned square around the 2D landmark bbox, same as SMIRK's demo crop_face."""
    left, top = landmarks_px[:, :2].min(axis=0)
    right, bottom = landmarks_px[:, :2].max(axis=0)
    size = int((right - left + bottom - top) / 2 * CROP_SCALE)
    cx, cy = (left + right) / 2, (top + bottom) / 2
    k = (INPUT_SIZE - 1) / size
    return np.array([[k, 0, -k * (cx - size / 2)], [0, k, -k * (cy - size / 2)]], dtype=np.float64)


def preprocess(bgr: np.ndarray, landmarks_norm: np.ndarray) -> np.ndarray:
    h, w = bgr.shape[:2]
    m = crop_matrix(landmarks_norm[:, :2] * (w, h))
    crop = cv2.warpAffine(bgr, m, (INPUT_SIZE, INPUT_SIZE), flags=cv2.INTER_LINEAR)
    rgb = cv2.cvtColor(crop, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
    return np.ascontiguousarray(rgb.transpose(2, 0, 1)[None])


def postprocess(raw: np.ndarray) -> SmirkExpression:
    raw = raw.reshape(-1)
    jaw = np.concatenate([[max(raw[N_EXP + 2], 0.0)], np.clip(raw[N_EXP + 3:N_EXP + 5], -0.2, 0.2)])
    return SmirkExpression(
        expression=raw[:N_EXP].astype(np.float32),
        eyelid=np.clip(raw[N_EXP:N_EXP + 2], 0.0, 1.0).astype(np.float32),
        jaw=jaw.astype(np.float32),
    )
