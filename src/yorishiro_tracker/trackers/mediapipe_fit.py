"""MediaPipe 478 landmarks -> ARKit 52 through the generic ICT solver.

Landmarks come from MediaPipe's TFLite graph, expressions come from fitting ICT-FaceKit
shapes instead of MediaPipe's own blendshape model. Gaze keeps MediaPipe's own values.
"""

import numpy as np

from ..adapters.mediapipe_points import FIT_COVERAGE, MediaPipePointFitter
from ..avatar.ict import ensure_ict_facekit
from ..frame import ARKIT52
from .base import Tracker, TrackerInfo, TrackResult
from .mediapipe_ref import MediaPipeTracker

FIT_MASK = np.array([n in FIT_COVERAGE for n in ARKIT52])


class MediaPipeFitTracker(Tracker):
    info = TrackerInfo(
        name="mediapipe-fit",
        description="MediaPipe landmarks, ICT-FaceKit shape fitting for expressions",
        license="Apache-2.0 (MediaPipe) + MIT (ICT-FaceKit)",
        commercial_use=True,
        runtime="TFLite XNNPACK (CPU) + numpy solver",
        coverage=FIT_COVERAGE,
    )

    def __init__(self):
        self.mp = MediaPipeTracker()
        self.fitter = MediaPipePointFitter(ensure_ict_facekit())

    def process(self, bgr: np.ndarray, timestamp_ms: int) -> TrackResult | None:
        res = self.mp.process(bgr, timestamp_ms)
        if res is None:
            return None
        h, w = bgr.shape[:2]
        aligned, _ = self.fitter.align(res.landmarks, w, h)
        if not self.fitter.calibrated:  # first face seen is the neutral until the user recalibrates
            self.fitter.calibrate(aligned)
        bs = res.frame.blendshapes.copy()
        bs[FIT_MASK] = self.fitter.expressions(aligned)[FIT_MASK]
        res.frame.blendshapes = bs
        res.aligned = aligned
        return res

    def calibrate(self, result: TrackResult) -> None:
        self.fitter.calibrate(result.aligned)

    def close(self) -> None:
        self.mp.close()
