"""MediaPipe FaceMesh-V2 on a selectable runtime (Vulkan GPU by default) + ICT solver. No TFLite."""

from dataclasses import replace

import numpy as np

from ..adapters.mediapipe_points import FIT_COVERAGE, GAZE_SHAPES, MediaPipePointFitter
from ..avatar.ict import ensure_ict_facekit
from ..frame import FaceFrame
from ..mediapipe_ncnn.facemesh import FaceMesh
from ..pose import eye_rotations_from_blendshapes, rotation_to_ypr, ypr_to_rotation
from .base import Tracker, TrackerInfo, TrackResult


class FaceMeshGpuTracker(Tracker):
    info = TrackerInfo(
        name="facemesh",
        description="FaceMesh-V2 landmarks, ICT fitting, iris gaze",
        license="Apache-2.0 (MediaPipe models, PINTO conversion) + MIT (ICT-FaceKit)",
        commercial_use=True,
        runtime="FaceMesh-V2 + numpy solver",
        coverage=FIT_COVERAGE + GAZE_SHAPES,
    )

    def __init__(self, runtime: str = "vulkan"):
        self.mesh = FaceMesh(runtime=runtime)
        self.fitter = MediaPipePointFitter(ensure_ict_facekit())
        self.info = replace(self.info, runtime=f"{self.mesh.landmarker.name} + numpy solver")

    def process(self, bgr: np.ndarray, timestamp_ms: int) -> TrackResult | None:
        landmarks = self.mesh.process(bgr)
        if landmarks is None:
            return None
        h, w = bgr.shape[:2]
        aligned, rot = self.fitter.align(landmarks, w, h)
        if not self.fitter.calibrated:  # first face seen is the neutral until the user recalibrates
            self.fitter.calibrate(aligned)
        bs = self.fitter.expressions(aligned) + self.fitter.gaze(aligned)
        left_eye, right_eye = eye_rotations_from_blendshapes(bs)
        frame = FaceFrame(
            timestamp_ms=timestamp_ms,
            blendshapes=bs,
            head_rotation=rotation_to_ypr(rot),
            head_translation=np.zeros(3, dtype=np.float32),
            left_eye_rotation=left_eye,
            right_eye_rotation=right_eye,
        )
        res = TrackResult(frame=frame, landmarks=landmarks)
        res.aligned = aligned
        return res

    def calibrate(self, result: TrackResult) -> None:
        self.fitter.calibrate(result.aligned)

    def calibrate_window(self, results: list[TrackResult]) -> list[FaceFrame]:
        self.fitter.calibrate_many([r.aligned for r in results])
        out = []
        for r in results:
            aligned, dr = self.fitter.realign(r.aligned)
            bs = self.fitter.expressions(aligned) + self.fitter.gaze(aligned)
            left_eye, right_eye = eye_rotations_from_blendshapes(bs)
            # head rotation was R.T for points aligned by R, the new alignment is dr @ R
            head = rotation_to_ypr(ypr_to_rotation(r.frame.head_rotation) @ dr.T)
            out.append(replace(r.frame, blendshapes=bs, head_rotation=head,
                               left_eye_rotation=left_eye, right_eye_rotation=right_eye))
        return out
