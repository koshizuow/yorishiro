import cv2
import mediapipe as mp
import numpy as np
from mediapipe.tasks.python import BaseOptions, vision

from ..adapters.vts_params import mouth_gap
from ..frame import ARKIT52, ARKIT52_INDEX, FaceFrame
from ..models import ensure_face_landmarker
from ..pose import eye_rotations_from_blendshapes, rotation_to_ypr
from .base import Tracker, TrackerInfo, TrackResult


class MediaPipeTracker(Tracker):
    """Reference tracker: MediaPipe Face Landmarker on CPU, VIDEO mode."""

    info = TrackerInfo(
        name="mediapipe",
        description="MediaPipe Face Landmarker, native 52 blendshapes",
        license="Apache-2.0",
        commercial_use=True,
        runtime="TFLite XNNPACK (CPU)",
        coverage=tuple(n for n in ARKIT52 if n != "tongueOut"),
    )

    def __init__(self, model_path=None):
        options = vision.FaceLandmarkerOptions(
            base_options=BaseOptions(
                model_asset_path=str(model_path or ensure_face_landmarker()),
                delegate=BaseOptions.Delegate.CPU,
            ),
            running_mode=vision.RunningMode.VIDEO,
            num_faces=1,
            output_face_blendshapes=True,
            output_facial_transformation_matrixes=True,
        )
        self._landmarker = vision.FaceLandmarker.create_from_options(options)

    def process(self, bgr: np.ndarray, timestamp_ms: int) -> TrackResult | None:
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        result = self._landmarker.detect_for_video(image, timestamp_ms)
        if not result.face_landmarks:
            return None

        landmarks = np.array(
            [(p.x, p.y, p.z) for p in result.face_landmarks[0]], dtype=np.float32
        )
        bs = np.zeros(52, dtype=np.float32)
        for c in result.face_blendshapes[0]:
            idx = ARKIT52_INDEX.get(c.category_name)
            if idx is not None:  # skips MediaPipe's "_neutral"
                bs[idx] = c.score

        matrix = np.asarray(result.facial_transformation_matrixes[0], dtype=np.float64)
        left_eye, right_eye = eye_rotations_from_blendshapes(bs)
        frame = FaceFrame(
            timestamp_ms=timestamp_ms,
            blendshapes=bs,
            head_rotation=rotation_to_ypr(matrix[:3, :3]),
            head_translation=(matrix[:3, 3] / 100.0).astype(np.float32),
            left_eye_rotation=left_eye,
            right_eye_rotation=right_eye,
            mouth_gap=mouth_gap(landmarks, image.width, image.height),
        )
        return TrackResult(frame=frame, landmarks=landmarks, matrix=matrix)

    def close(self) -> None:
        self._landmarker.close()
