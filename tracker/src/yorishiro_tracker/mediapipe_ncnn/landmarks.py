"""FaceMesh-V2 landmark model with MediaPipe-equivalent ROI handling, runtime-agnostic."""

import math

import cv2
import numpy as np

INPUT = 256
ROI_SCALE = 1.5
# Eye corners used for in-plane rotation, as in MediaPipe's face landmark ROI from landmarks.
RIGHT_EYE_OUTER, LEFT_EYE_OUTER = 33, 263


def roi_from_landmarks(lm_px: np.ndarray) -> tuple[np.ndarray, float, float]:
    """Rotated square ROI (center, size, angle rad) around 2D landmark pixels."""
    d = lm_px[LEFT_EYE_OUTER, :2] - lm_px[RIGHT_EYE_OUTER, :2]
    angle = math.atan2(d[1], d[0])
    c, s = math.cos(-angle), math.sin(-angle)
    rot = np.array([[c, -s], [s, c]])
    center0 = (lm_px[:, :2].min(0) + lm_px[:, :2].max(0)) / 2
    local = (lm_px[:, :2] - center0) @ rot.T
    lo, hi = local.min(0), local.max(0)
    center = center0 + ((lo + hi) / 2) @ np.linalg.inv(rot).T
    size = float((hi - lo).max() * ROI_SCALE)
    return center, size, angle


def roi_matrix(center: np.ndarray, size: float, angle: float) -> np.ndarray:
    """2x3 affine mapping image pixels into the INPUT x INPUT crop."""
    k = INPUT / size
    c, s = math.cos(-angle) * k, math.sin(-angle) * k
    m = np.array([[c, -s, 0.0], [s, c, 0.0]])
    m[:, 2] = INPUT / 2 - m[:, :2] @ center
    return m


def preprocess(bgr: np.ndarray, m: np.ndarray) -> np.ndarray:
    crop = cv2.warpAffine(bgr, m, (INPUT, INPUT), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)
    rgb = cv2.cvtColor(crop, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
    return np.ascontiguousarray(rgb.transpose(2, 0, 1)[None])


def postprocess(raw: np.ndarray, m: np.ndarray, width: int, height: int) -> np.ndarray:
    """Model output (1434,) in crop pixels to MediaPipe-style normalized image landmarks (478, 3)."""
    pts = raw.reshape(478, 3).astype(np.float64)
    inv = cv2.invertAffineTransform(m)
    xy = pts[:, :2] @ inv[:, :2].T + inv[:, 2]
    scale = math.hypot(inv[0, 0], inv[1, 0])  # crop pixel -> image pixel
    z = pts[:, 2] * scale / width  # MediaPipe normalizes z by image width
    return np.stack([xy[:, 0] / width, xy[:, 1] / height, z], axis=1).astype(np.float32)
