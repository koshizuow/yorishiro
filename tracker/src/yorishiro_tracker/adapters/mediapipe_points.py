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

# Eyelids, subject's side: three upper and three lower lid points, eye corners. Blink and wide eyes come
# from the lid gap over the eye width, measured in 3D so turning the head does not shorten the eye. The ICT
# solve gets them wrong: lid motion is a few points moving millimetres, and fitting all shapes at once lets
# head pose and the brows and cheeks around the eyes decide them (r 0.09 with the lid gap on the user's
# recording, 0.69 for MediaPipe's own blendshapes, 0.82 to 0.92 for this ratio).
LIDS = {"Left": ([386, 385, 387], [374, 380, 373], 362, 263),
        "Right": ([159, 158, 160], [145, 153, 144], 133, 33)}
# Gap relative to the neutral one: CREMA-D's closed eyes measure about 0.16, wide eyes reach 1.3.
LID_CLOSED, LID_WIDE, LID_DEADBAND = 0.2, 1.35, 0.05


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
        self.lid_neutral = {side: 1.0 for side in LIDS}

    def align(self, landmarks: np.ndarray, width: int, height: int) -> tuple[np.ndarray, np.ndarray]:
        """All 478 points rigidly aligned onto the reference, and the head rotation (face -> camera)."""
        pts = landmarks_to_points(landmarks, width, height)
        s, r, t = similarity_transform(pts[MP_RIGID], self.reference[MP_RIGID])
        return apply(s, r, t, pts), r.T

    def calibrate(self, aligned: np.ndarray) -> None:
        self.reference = aligned[:468].copy()
        self.gaze_neutral = _iris_offsets(aligned)
        self.lid_neutral = {side: _lid_gap(aligned, side) for side in LIDS}
        self.solver.w[:] = 0
        self.calibrated = True

    def calibrate_many(self, aligned: list[np.ndarray]) -> None:
        """Neutral = per-point median over a window of aligned frames."""
        self.calibrate(np.median(np.stack(aligned), axis=0))

    def realign(self, aligned: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """Re-align points that were aligned to an older reference, and the rotation that took them there."""
        s, r, t = similarity_transform(aligned[MP_RIGID], self.reference[MP_RIGID])
        return apply(s, r, t, aligned), r

    def expressions(self, aligned: np.ndarray) -> np.ndarray:
        """ARKit 52 values for FIT_COVERAGE, zeros elsewhere."""
        disp = aligned[self.src_idx] - self.reference[self.src_idx]
        w = self.solver.solve(disp)
        bs = np.zeros(52, dtype=np.float32)
        for k, v in zip(self.arkit_of_shape, w):
            bs[k] = max(bs[k], v)  # browInnerUp and cheekPuff come from two ICT shapes
        for side in LIDS:
            rel = _lid_gap(aligned, side) / max(self.lid_neutral[side], 1e-6)
            bs[ARKIT52_INDEX[f"eyeBlink{side}"]] = np.clip(
                (1 - LID_DEADBAND - rel) / (1 - LID_DEADBAND - LID_CLOSED), 0.0, 1.0)
            bs[ARKIT52_INDEX[f"eyeWide{side}"]] = np.clip(
                (rel - 1 - LID_DEADBAND) / (LID_WIDE - 1 - LID_DEADBAND), 0.0, 1.0)
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


def _lid_gap(points: np.ndarray, side: str) -> float:
    upper, lower, inner, outer = LIDS[side]
    gap = np.linalg.norm(points[upper].mean(0) - points[lower].mean(0))
    return float(gap / np.linalg.norm(points[inner] - points[outer]))


def _iris_offsets(aligned: np.ndarray) -> np.ndarray:
    out = []
    for eye in (LEFT_EYE, RIGHT_EYE):
        a, b = aligned[eye["inner"]], aligned[eye["outer"]]
        width = np.linalg.norm(b - a)
        d = aligned[eye["iris"]] - (a + b) / 2
        out += [d[0] / width, d[1] / width]
    return np.array(out)
