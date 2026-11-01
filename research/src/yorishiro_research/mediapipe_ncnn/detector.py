"""BlazeFace short-range detector (MediaPipe face_detector.tflite), runtime-agnostic decode."""

import math

import cv2
import numpy as np

INPUT = 128
SCORE_THRESHOLD = 0.5


def _anchors() -> np.ndarray:
    """SSD anchors for BlazeFace short range: strides 8, 16, 16, 16 with fixed size, offset 0.5."""
    out = []
    for stride, per_cell in ((8, 2), (16, 6)):
        n = INPUT // stride
        ys, xs = np.mgrid[0:n, 0:n]
        centers = np.stack([(xs + 0.5) / n, (ys + 0.5) / n], axis=-1).reshape(-1, 2)
        out.append(np.repeat(centers, per_cell, axis=0))
    return np.concatenate(out).astype(np.float32)


ANCHORS = _anchors()
assert len(ANCHORS) == 896


def letterbox(bgr: np.ndarray) -> tuple[np.ndarray, float, float, float]:
    """Fit into INPUT x INPUT keeping aspect. Returns NCHW input in [-1, 1], scale and padding."""
    h, w = bgr.shape[:2]
    s = INPUT / max(h, w)
    nw, nh = round(w * s), round(h * s)
    px, py = (INPUT - nw) / 2, (INPUT - nh) / 2
    canvas = np.zeros((INPUT, INPUT, 3), np.uint8)
    canvas[int(py):int(py) + nh, int(px):int(px) + nw] = cv2.resize(bgr, (nw, nh), interpolation=cv2.INTER_AREA)
    x = cv2.cvtColor(canvas, cv2.COLOR_BGR2RGB).astype(np.float32) / 127.5 - 1.0
    return np.ascontiguousarray(x.transpose(2, 0, 1)[None]), s, int(px), int(py)


def decode_best(regressors: np.ndarray, scores: np.ndarray, s: float, px: int, py: int):
    """Highest scoring face as (center_px, size_px, angle_rad) in image pixels, or None."""
    logits = np.clip(scores.reshape(-1), -100, 100)
    best = int(np.argmax(logits))
    if 1 / (1 + math.exp(-logits[best])) < SCORE_THRESHOLD:
        return None
    r = regressors.reshape(-1, 16)[best] / INPUT
    a = ANCHORS[best]
    cx, cy, bw, bh = r[0] + a[0], r[1] + a[1], r[2], r[3]
    kp = r[4:].reshape(6, 2) + a  # 0 right eye, 1 left eye (subject's side)
    to_img = lambda v: (v * INPUT - (px, py)) / s
    center = to_img(np.array([cx, cy]))
    eyes = to_img(kp[:2])
    angle = math.atan2(eyes[1, 1] - eyes[0, 1], eyes[1, 0] - eyes[0, 0])
    size = max(bw, bh) * INPUT / s * 1.5  # MediaPipe face landmark ROI: square_long, scale 1.5
    return center, float(size), angle
