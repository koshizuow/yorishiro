"""Screen reflections on glasses: how much of each eye's area is light and tinted unlike the user's skin.

Glasses mirror the monitor, and the reflection covers the eyelids, so blink and wink readings get weak (on the
2026-10-29 recording the lid gap only fell to 0.6 of the neutral on winks). The app uses this to tell the user
and to show glasses on its preview head.

Per eye: the cheek below gives the skin color (CIELAB median and spread). In a box around the eye, pixels count
as reflection when their chroma is more than 2.5 spreads from the skin and they are not dark (iris, lashes and
brows are dark). Measured: 2026-10-29 recording (thin metal glasses, monitor glare) median 0.008, 95th
percentile 0.12, above 0.02 in 44% of frames; CREMA-D's 10 actors without glasses never above 0.002.
"""

import cv2
import numpy as np

# subject's side: inner and outer eye corner, a cheek point below the eye
EYES = {"Left": (362, 263, 425), "Right": (133, 33, 205)}


def lens_glare(bgr: np.ndarray, landmarks: np.ndarray) -> tuple[float, float]:
    """(left, right) share of the eye box that looks like a reflection, subject's sides"""
    h, w = bgr.shape[:2]
    pts = landmarks[:, :2] * (w, h)
    out = []
    for side in ("Left", "Right"):
        inner, outer, cheek = EYES[side]
        eye_w = float(np.linalg.norm(pts[inner] - pts[outer]))
        skin = _box(bgr, pts[cheek], 0.25 * eye_w, 0.25 * eye_w)
        eye = _box(bgr, (pts[inner] + pts[outer]) / 2, 0.75 * eye_w, 0.45 * eye_w)
        if len(skin) < 4 or len(eye) < 4:
            out.append(0.0)
            continue
        s_med = np.median(skin, axis=0)
        spread = np.percentile(np.linalg.norm(skin - s_med, axis=1), 90) + 4.0
        chroma = np.linalg.norm(eye[:, 1:] - s_med[1:], axis=1)
        light = eye[:, 0] > s_med[0] - 10
        out.append(float(np.mean((chroma > 2.5 * spread) & light)))
    return out[0], out[1]


def _box(bgr: np.ndarray, center, half_w: float, half_h: float) -> np.ndarray:
    """CIELAB pixels of a box, as rows"""
    x, y = int(center[0]), int(center[1])
    a, b = max(1, int(half_w)), max(1, int(half_h))
    crop = bgr[max(0, y - b):y + b, max(0, x - a):x + a]
    if crop.size == 0:
        return np.zeros((0, 3), np.float32)
    return cv2.cvtColor(crop, cv2.COLOR_BGR2LAB).reshape(-1, 3).astype(np.float32)
