"""MediaPipe 478 landmarks -> ARKit 52 through the generic ICT solver.

Shows the point-set adapter path: landmarks come from MediaPipe, expressions come
from fitting ICT-FaceKit shapes instead of MediaPipe's own blendshape model.
"""

import numpy as np

from ..adapters.ict_fit import IctSolver, build_correspondence, similarity_transform, apply
from ..avatar.ict import ICT_SHAPES, ensure_ict_facekit, ict_to_arkit
from ..frame import ARKIT52
from ..models import ensure_canonical_face_model
from .base import Tracker, TrackerInfo, TrackResult
from .mediapipe_ref import MediaPipeTracker

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
# No iris points in the 468 canonical set, so gaze shapes keep MediaPipe's own values.
FROM_MEDIAPIPE = {n for n in ARKIT52 if n.startswith("eyeLook")}


def load_canonical() -> np.ndarray:
    text = ensure_canonical_face_model().read_text()
    rows = [line.split()[1:4] for line in text.splitlines() if line.startswith("v ")]
    return np.asarray(rows, dtype=np.float64)


def landmarks_to_points(landmarks: np.ndarray, width: int, height: int) -> np.ndarray:
    """Normalized image landmarks to a y-up, z-toward-camera point set (pixel units)."""
    x, y, z = landmarks[:468, 0], landmarks[:468, 1], landmarks[:468, 2]
    return np.stack([x * width, -y * height, -z * width], axis=1).astype(np.float64)


class MediaPipeFitTracker(Tracker):
    info = TrackerInfo(
        name="mediapipe-fit",
        description="MediaPipe landmarks, ICT-FaceKit shape fitting for expressions",
        license="Apache-2.0 (MediaPipe) + MIT (ICT-FaceKit)",
        commercial_use=True,
        runtime="TFLite XNNPACK (CPU) + numpy solver",
        coverage=tuple(n for n in ARKIT52 if n != "tongueOut" and n not in FROM_MEDIAPIPE),
    )

    def __init__(self):
        self.mp = MediaPipeTracker()
        self.head = ensure_ict_facekit()
        corr = build_correspondence(self.head, load_canonical(), MP_68)
        self.src_idx, self.ict_idx = corr.src_idx, corr.ict_idx
        self.reference = corr.src_neutral_in_ict
        self.fit_rms_68 = corr.rms_68
        active = np.array([not n.startswith("eyeLook") for n in ICT_SHAPES])
        self.solver = IctSolver(self.head, self.ict_idx, active)
        self._calibrated = False

    def _to_reference(self, res: TrackResult, width: int, height: int) -> np.ndarray:
        pts = landmarks_to_points(res.landmarks, width, height)
        s, r, t = similarity_transform(pts[MP_RIGID], self.reference[MP_RIGID])
        return apply(s, r, t, pts)

    def process(self, bgr: np.ndarray, timestamp_ms: int) -> TrackResult | None:
        res = self.mp.process(bgr, timestamp_ms)
        if res is None:
            return None
        h, w = bgr.shape[:2]
        aligned = self._to_reference(res, w, h)
        if not self._calibrated:  # first face seen becomes the neutral until the user recalibrates
            self.reference, self._calibrated = aligned, True
        disp = aligned[self.src_idx] - self.reference[self.src_idx]
        ict_w = self.solver.solve(disp)

        bs = res.frame.blendshapes.copy()
        fitted = np.zeros(52, dtype=np.float32)
        for name, v in zip(ICT_SHAPES, ict_w):
            arkit = ict_to_arkit(name)
            if arkit not in FROM_MEDIAPIPE:
                idx = ARKIT52.index(arkit)
                fitted[idx] = max(fitted[idx], v)  # browInnerUp and cheekPuff come from two ICT shapes
        for i, name in enumerate(ARKIT52):
            if name in self.info.coverage:
                bs[i] = fitted[i]
        res.frame.blendshapes = bs
        self._last_size = (w, h)
        return res

    def calibrate(self, result: TrackResult) -> None:
        self.reference = self._to_reference(result, *self._last_size)
        self.solver.w[:] = 0

    def close(self) -> None:
        self.mp.close()
