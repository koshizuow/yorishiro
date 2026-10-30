"""MediaPipe 478-point landmarks as a point-set source for the ICT solver.

Shared by any tracker that produces MediaPipe-topology landmarks (TFLite or ncnn).
"""

import numpy as np

from ..avatar.ict import ICT_SHAPES, IctHead, ict_to_arkit
from ..frame import ARKIT52, ARKIT52_INDEX
from ..models import ensure_canonical_face_model
from .ict_fit import IctSolver, apply, build_correspondence, similarity_transform

# MediaPipe mesh indices for the Multi-PIE 68 layout (0 = subject's right jaw).
MP_68 = np.array([
    127, 234, 132, 58, 172, 150, 176, 148, 152, 377, 400, 379, 397, 288, 361, 454, 356,
    70, 63, 105, 66, 107, 336, 296, 334, 293, 300,
    168, 197, 5, 4, 75, 97, 2, 326, 305,
    33, 160, 158, 133, 153, 144, 362, 385, 387, 263, 373, 380,
    61, 39, 37, 0, 267, 269, 291, 405, 314, 17, 84, 181, 78, 82, 13, 312, 308, 317, 14, 87,
])
# Points that barely move with expressions: nose bridge and tip, inner eye corners, sides of the head.
# Forehead points are excluded because they follow the brows.
MP_RIGID = np.array([168, 6, 197, 195, 5, 4, 1, 133, 362, 127, 356, 234, 454])

GAZE_SHAPES = tuple(n for n in ARKIT52 if n.startswith("eyeLook"))
FIT_COVERAGE = tuple(n for n in ARKIT52 if n != "tongueOut" and n not in GAZE_SHAPES)

# Iris centers and eye corners, subject's side. Iris offset in eye widths that reads as a full look.
LEFT_EYE = dict(iris=473, inner=362, outer=263)
RIGHT_EYE = dict(iris=468, inner=133, outer=33)
# Vertical is noisier (lids cover the iris), so it needs a larger offset for a full look.
GAZE_FULL_X, GAZE_FULL_Y = 0.18, 0.14


def load_canonical() -> np.ndarray:
    text = ensure_canonical_face_model().read_text()
    rows = [line.split()[1:4] for line in text.splitlines() if line.startswith("v ")]
    return np.asarray(rows, dtype=np.float64)


def landmarks_to_points(landmarks: np.ndarray, width: int, height: int) -> np.ndarray:
    """Normalized image landmarks to a y-up, z-toward-camera point set (pixel units)."""
    x, y, z = landmarks[:, 0], landmarks[:, 1], landmarks[:, 2]
    return np.stack([x * width, -y * height, -z * width], axis=1).astype(np.float64)


class MediaPipePointFitter:
    def __init__(self, head: IctHead):
        corr = build_correspondence(head, load_canonical(), MP_68)
        self.src_idx, self.ict_idx = corr.src_idx, corr.ict_idx
        self.reference = corr.src_neutral_in_ict  # 468 points in ICT space
        self.fit_rms_68 = corr.rms_68
        active = np.array([not n.startswith("eyeLook") for n in ICT_SHAPES])
        self.solver = IctSolver(head, self.ict_idx, active)
        self.arkit_of_shape = [ARKIT52_INDEX[ict_to_arkit(n)] for n in ICT_SHAPES]
        self.calibrated = False
        self.gaze_neutral = np.zeros(4)

    def align(self, landmarks: np.ndarray, width: int, height: int) -> tuple[np.ndarray, np.ndarray]:
        """All 478 points rigidly aligned onto the reference, and the head rotation (face -> camera)."""
        pts = landmarks_to_points(landmarks, width, height)
        s, r, t = similarity_transform(pts[MP_RIGID], self.reference[MP_RIGID])
        return apply(s, r, t, pts), r.T

    def calibrate(self, aligned: np.ndarray) -> None:
        self.reference = aligned[:468].copy()
        self.gaze_neutral = _iris_offsets(aligned)
        self.solver.w[:] = 0
        self.calibrated = True

    def expressions(self, aligned: np.ndarray) -> np.ndarray:
        """ARKit 52 values for FIT_COVERAGE, zeros elsewhere."""
        disp = aligned[self.src_idx] - self.reference[self.src_idx]
        w = self.solver.solve(disp)
        bs = np.zeros(52, dtype=np.float32)
        for k, v in zip(self.arkit_of_shape, w):
            bs[k] = max(bs[k], v)  # browInnerUp and cheekPuff come from two ICT shapes
        return bs

    def gaze(self, aligned: np.ndarray) -> np.ndarray:
        """eyeLook* values from iris landmarks, relative to the calibrated neutral."""
        lx, ly, rx, ry = _iris_offsets(aligned) - self.gaze_neutral
        bs = np.zeros(52, dtype=np.float32)
        def put(name, v):
            bs[ARKIT52_INDEX[name]] = np.clip(v, 0.0, 1.0)
        # +x is the subject's left: left eye looks out, right eye looks in.
        put("eyeLookOutLeft", lx / GAZE_FULL_X)
        put("eyeLookInLeft", -lx / GAZE_FULL_X)
        put("eyeLookInRight", rx / GAZE_FULL_X)
        put("eyeLookOutRight", -rx / GAZE_FULL_X)
        put("eyeLookUpLeft", ly / GAZE_FULL_Y)
        put("eyeLookDownLeft", -ly / GAZE_FULL_Y)
        put("eyeLookUpRight", ry / GAZE_FULL_Y)
        put("eyeLookDownRight", -ry / GAZE_FULL_Y)
        return bs


def _iris_offsets(aligned: np.ndarray) -> np.ndarray:
    out = []
    for eye in (LEFT_EYE, RIGHT_EYE):
        a, b = aligned[eye["inner"]], aligned[eye["outer"]]
        width = np.linalg.norm(b - a)
        d = aligned[eye["iris"]] - (a + b) / 2
        out += [d[0] / width, d[1] / width]
    return np.array(out)
