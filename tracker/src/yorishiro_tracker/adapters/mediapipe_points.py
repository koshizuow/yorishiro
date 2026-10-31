"""MediaPipe 478-point landmarks as a point-set source for the ICT solver.

Shared by any tracker that produces MediaPipe-topology landmarks (TFLite or ncnn).
"""

import math

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


# Brow contours, upper and lower edge, both sides. Brow raises are solved on these alone: in the full solve
# brow shapes followed the rest of the face (browDown r -0.23 with the brow height on CREMA-D's neutral
# clips, jitter 3 times the brow points' own). Regional: agreement with MediaPipe brows up 0.31 -> 0.48,
# inner brows up 0.47 -> 0.71, CREMA-D still-face jitter halved. browDown stays on the full solve, the
# regional one was worse (anger read as a raise).
BROWS = np.array([336, 296, 334, 293, 300, 285, 295, 282, 283, 276,
                  107, 66, 105, 63, 70, 55, 65, 52, 53, 46])
BROW_SHAPES = tuple(n for n in ICT_SHAPES if n.startswith("brow"))
BROW_UP_SHAPES = tuple(n for n in BROW_SHAPES if not n.startswith("browDown"))
# cheekSquint is solved on the cheeks alone (points from cheekPoints, between the lower lids and the mouth
# corners, outside the nose wings): in the full solve smiles barely moved it (CREMA-D happy d 0.20, the
# user's smile 0.05), regional 1.94 and 0.55. Head turns still add up to 0.19 on a neutral face (0.10
# before), now a third of a smile. A regional noseSneer changed nothing and is not used.
CHEEK_SHAPES = tuple(n for n in ICT_SHAPES if n.startswith("cheekSquint"))
REGIONAL = True


def cheek_points(canonical: np.ndarray) -> np.ndarray:
    x, y = canonical[:, 0], canonical[:, 1]
    lid_y = canonical[[374, 145], 1].mean()
    mouth_y = canonical[[61, 291], 1].mean()
    wing_x = np.abs(canonical[[64, 294], 0]).mean()
    eye_outer_x = np.abs(canonical[[33, 263], 0]).mean()
    return np.nonzero((y < lid_y + 0.3) & (y > mouth_y) & (np.abs(x) > wing_x) & (np.abs(x) < eye_outer_x * 1.15))[0]
# Experiment, off until a recording with frowns and looking down settles it. browDown from the brow height,
# like the lids: the regional solve still traded it against browInnerUp
# (jitter up on the user's recording, CREMA-D anger read as a brow raise). Height is measured from a point
# at the brows' own depth, a blend of the eye corners (behind the brows) and the lower forehead (in front):
# from the eye corners alone, looking down read as browDown (0.11 eye widths per radian of pitch on the
# user's recording, the forehead -0.07). The blend weight comes from the reference's depths (0.40 eye
# corners), close to the 0.385 where the two cancel on that recording. A full browDown is the height drop
# ICT's browDown shape makes. Eye corners only (weight 1): CREMA-D anger d -0.30 -> 0.80, disgust 0.68 ->
# 1.59, but neutral faces looking down read up to 0.7. Depth blend: no pitch leak, anger 0.07, noisier.
BROW_HEIGHT = {"Left": ([336, 296, 334, 293, 300], [362, 263], [151, 337, 299]),
               "Right": ([107, 66, 105, 63, 70], [133, 33], [151, 108, 69])}
BROW_DOWN_GEOMETRIC = False


def load_canonical() -> np.ndarray:
    text = ensure_canonical_face_model().read_text()
    rows = [line.split()[1:4] for line in text.splitlines() if line.startswith("v ")]
    return np.asarray(rows, dtype=np.float64)


def landmarks_to_points(landmarks: np.ndarray, width: int, height: int) -> np.ndarray:
    """Normalized image landmarks to a y-up, z-toward-camera point set (pixel units)."""
    x, y, z = landmarks[:, 0], landmarks[:, 1], landmarks[:, 2]
    return np.stack([x * width, -y * height, -z * width], axis=1).astype(np.float64)


# Head position from the image alone: the camera's field of view is unknown, so assume MediaPipe's own
# (63 degrees vertical) and a face of average size. RMS radius of the rigid points in meters, fitted on
# MediaPipe's face transform over the 2026-10-29 recording (spread 0.9 mm). Absolute values are rough,
# the app uses the change from the neutral.
CAMERA_FOV_Y_DEG = 63.0
RIGID_RADIUS_M = 0.0617
# The position is taken this far behind the face, near the neck's pivot, so turning the head does not move
# it. Over the head turns of the same recording: 3.5 cm sideways spread on the face, 0.6 cm here.
PIVOT_BEHIND_FACE_M = 0.09


def head_position(landmarks: np.ndarray, width: int, height: int, rotation: np.ndarray | None = None) -> np.ndarray:
    """Camera-space head position in meters (x right, y up, -z forward) from normalized image landmarks.
    rotation: head rotation (face -> camera, y up, z toward the camera), moves the point behind the face."""
    pts = np.stack([landmarks[MP_RIGID, 0] * width, landmarks[MP_RIGID, 1] * height,
                    landmarks[MP_RIGID, 2] * width], axis=1).astype(np.float64)
    center = pts.mean(axis=0)
    radius = np.sqrt(((pts - center) ** 2).sum(axis=1).mean())
    focal = (height / 2) / math.tan(math.radians(CAMERA_FOV_Y_DEG / 2))
    dist = focal * RIGID_RADIUS_M / max(radius, 1e-6)
    pos = np.array([(center[0] - width / 2) * dist / focal, -(center[1] - height / 2) * dist / focal, -dist])
    if rotation is not None:
        pos -= PIVOT_BEHIND_FACE_M * rotation[:, 2]
    return pos.astype(np.float32)


class MediaPipePointFitter:
    def __init__(self, head: IctHead):
        corr = build_correspondence(head, load_canonical(), MP_68)
        self.src_idx, self.ict_idx = corr.src_idx, corr.ict_idx
        self.reference = corr.src_neutral_in_ict  # 468 points in ICT space
        self.fit_rms_68 = corr.rms_68
        active = np.array([not n.startswith("eyeLook") for n in ICT_SHAPES])
        self.solver = IctSolver(head, self.ict_idx, active)
        # regional solves: (rows of src_idx, shapes taken from it, solver over the region's shapes)
        self.regions = []
        for points, shapes, taken in ((BROWS, BROW_SHAPES, BROW_UP_SHAPES),
                                      (cheek_points(load_canonical()), CHEEK_SHAPES, CHEEK_SHAPES)):
            rows = np.nonzero(np.isin(self.src_idx, points))[0]
            solver = IctSolver(head, self.ict_idx[rows], np.array([n in shapes for n in ICT_SHAPES]))
            self.regions.append((rows, np.array([n in taken for n in ICT_SHAPES]), solver))
        # brow height drop at browDown = 1, measured on the reference with ICT's shape added
        to_ict = dict(zip(self.src_idx, self.ict_idx))
        self.brow_eye_weight, self.brow_down_full = {}, {}
        for side, (brow, eye, forehead) in BROW_HEIGHT.items():
            z = lambda idx: self.reference[idx, 2].mean()
            self.brow_eye_weight[side] = (z(brow) - z(forehead)) / (z(eye) - z(forehead))
            delta = head.deltas[ICT_SHAPES.index(f"browDown_{side[0]}")]
            moved = self.reference.copy()
            for m in brow + eye + forehead:
                moved[m] = moved[m] + delta[to_ict[m]]
            self.brow_down_full[side] = self._brow_height(self.reference, side) - self._brow_height(moved, side)
        self.brow_neutral = {side: self._brow_height(self.reference, side) for side in BROW_HEIGHT}
        self.arkit_of_shape = [ARKIT52_INDEX[ict_to_arkit(n)] for n in ICT_SHAPES]
        self.calibrated = False
        self.gaze_neutral = np.zeros(4)
        self.lid_neutral = {side: 1.0 for side in LIDS}
        self.eye_neutral = {side: 1.0 for side in LIDS}  # eye model openness at the neutral

    def align(self, landmarks: np.ndarray, width: int, height: int) -> tuple[np.ndarray, np.ndarray]:
        """All 478 points rigidly aligned onto the reference, and the head rotation (face -> camera)."""
        pts = landmarks_to_points(landmarks, width, height)
        s, r, t = similarity_transform(pts[MP_RIGID], self.reference[MP_RIGID])
        return apply(s, r, t, pts), r.T

    def calibrate(self, aligned: np.ndarray, eye_open: np.ndarray | None = None) -> None:
        self.reference = aligned[:468].copy()
        self.gaze_neutral = _iris_offsets(aligned)
        self.lid_neutral = {side: _lid_gap(aligned, side) for side in LIDS}
        if eye_open is not None:
            self.eye_neutral = {side: max(float(v), 0.2) for side, v in zip(LIDS, eye_open)}
        self.brow_neutral = {side: self._brow_height(aligned, side) for side in BROW_HEIGHT}
        self.solver.w[:] = 0
        for _, _, solver in self.regions:
            solver.w[:] = 0
        self.calibrated = True

    def calibrate_many(self, aligned: list[np.ndarray], eye_open: list[np.ndarray] | None = None) -> None:
        """Neutral = per-point median over a window of aligned frames."""
        self.calibrate(np.median(np.stack(aligned), axis=0),
                       np.median(np.stack(eye_open), axis=0) if eye_open else None)

    def realign(self, aligned: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """Re-align points that were aligned to an older reference, and the rotation that took them there."""
        s, r, t = similarity_transform(aligned[MP_RIGID], self.reference[MP_RIGID])
        return apply(s, r, t, aligned), r

    def expressions(self, aligned: np.ndarray, eye_open: np.ndarray | None = None) -> np.ndarray:
        """ARKit 52 values for FIT_COVERAGE, zeros elsewhere. Blink and wide come from the eye model's
        openness when given (eye_openness.py), otherwise from the lid gap."""
        disp = aligned[self.src_idx] - self.reference[self.src_idx]
        w = self.solver.solve(disp)
        if REGIONAL:
            # the full solve keeps these shapes too, so a region's motion is not explained by other shapes
            for rows, taken, solver in self.regions:
                w = np.where(taken, solver.solve(disp[rows]), w)
        bs = np.zeros(52, dtype=np.float32)
        for k, v in zip(self.arkit_of_shape, w):
            bs[k] = max(bs[k], v)  # browInnerUp and cheekPuff come from two ICT shapes
        if BROW_DOWN_GEOMETRIC:
            for side in BROW_HEIGHT:
                drop = self.brow_neutral[side] - self._brow_height(aligned, side)
                bs[ARKIT52_INDEX[f"browDown{side}"]] = np.clip(drop / self.brow_down_full[side], 0.0, 1.0)
        for i, side in enumerate(LIDS):
            if eye_open is not None:
                rel = float(eye_open[i]) / self.eye_neutral[side]
            else:
                rel = _lid_gap(aligned, side) / max(self.lid_neutral[side], 1e-6)
            bs[ARKIT52_INDEX[f"eyeBlink{side}"]] = np.clip(
                (1 - LID_DEADBAND - rel) / (1 - LID_DEADBAND - LID_CLOSED), 0.0, 1.0)
            bs[ARKIT52_INDEX[f"eyeWide{side}"]] = np.clip(
                (rel - 1 - LID_DEADBAND) / (LID_WIDE - 1 - LID_DEADBAND), 0.0, 1.0)
        return bs

    def _brow_height(self, points: np.ndarray, side: str) -> float:
        """Upper brow edge above a point at the brows' depth, in eye widths (aligned space, y up)."""
        brow, eye, forehead = BROW_HEIGHT[side]
        a = self.brow_eye_weight[side]
        base = a * points[eye, 1].mean() + (1 - a) * points[forehead, 1].mean()
        return float((points[brow, 1].mean() - base) / np.linalg.norm(points[eye[0]] - points[eye[1]]))

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
