"""MediaPipe face detection + FaceMesh-V2 landmarks on any Backend, with ROI tracking."""

import math

import numpy as np

from ..backends.ncnn_backend import NcnnBackend
from ..models import MODEL_DIR
from . import detector as det
from . import landmarks as lmk

MP_DIR = MODEL_DIR / "mediapipe"
PRESENCE_LOGIT = 0.0  # sigmoid 0.5, same default as MediaPipe's min tracking confidence


class FaceMesh:
    def __init__(self, gpu: bool = True, fp16: bool = True):
        need = [MP_DIR / f"{n}.ncnn.{e}" for n in ("face_detector", "face_landmarks") for e in ("param", "bin")]
        if not all(p.exists() for p in need):
            raise SystemExit("MediaPipe ncnn models missing. Run: uv run python tools/export_mediapipe.py")
        # The detector runs rarely and is cheaper on CPU than the GPU dispatch.
        self.detector = NcnnBackend(need[0], need[1], gpu=False, fp16=False)
        self.landmarker = NcnnBackend(need[2], need[3], gpu=gpu, fp16=fp16)
        self.roi = None
        self.detections = 0

    def _detect(self, bgr: np.ndarray):
        x, s, px, py = det.letterbox(bgr)
        out = self.detector.run({"in0": x})
        self.detections += 1
        return det.decode_best(out["out0"], out["out1"], s, px, py)

    def process(self, bgr: np.ndarray) -> np.ndarray | None:
        """Normalized image landmarks (478, 3), MediaPipe convention, or None."""
        h, w = bgr.shape[:2]
        for attempt in range(2):
            if self.roi is None:
                self.roi = self._detect(bgr)
                if self.roi is None:
                    return None
            m = lmk.roi_matrix(*self.roi)
            out = self.landmarker.run({"in0": lmk.preprocess(bgr, m)})
            if out["out1"].item() > PRESENCE_LOGIT:
                landmarks = lmk.postprocess(out["out0"], m, w, h)
                self.roi = lmk.roi_from_landmarks(landmarks * (w, h, w))
                return landmarks
            self.roi = None  # lost track, re-detect once on this frame
        return None


def presence_probability(logit: float) -> float:
    return 1 / (1 + math.exp(-logit))
