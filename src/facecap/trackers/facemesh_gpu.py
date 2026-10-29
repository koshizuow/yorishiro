"""MediaPipe FaceMesh-V2 on ncnn Vulkan + ICT solver. No TFLite, landmarks run on the GPU."""

import numpy as np

from ..adapters.mediapipe_points import FIT_COVERAGE, GAZE_SHAPES, MediaPipePointFitter
from ..avatar.ict import ensure_ict_facekit
from ..frame import FaceFrame
from ..mediapipe_ncnn.facemesh import FaceMesh
from ..pose import eye_rotations_from_blendshapes, rotation_to_ypr
from .base import Tracker, TrackerInfo, TrackResult


class FaceMeshGpuTracker(Tracker):
    info = TrackerInfo(
        name="facemesh-gpu",
        description="FaceMesh-V2 landmarks on ncnn Vulkan, ICT fitting, iris gaze",
        license="Apache-2.0 (MediaPipe models, PINTO conversion) + MIT (ICT-FaceKit)",
        commercial_use=True,
        runtime="ncnn Vulkan FP16 + numpy solver",
        coverage=FIT_COVERAGE + GAZE_SHAPES,
    )

    def __init__(self, gpu: bool = True, fp16: bool = True):
        self.mesh = FaceMesh(gpu=gpu, fp16=fp16)
        self.fitter = MediaPipePointFitter(ensure_ict_facekit())

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
