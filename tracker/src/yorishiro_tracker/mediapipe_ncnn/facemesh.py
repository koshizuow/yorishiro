"""MediaPipe face detection + FaceMesh-V2 landmarks on any Backend, with ROI tracking."""

import math

import numpy as np

from ..backends.factory import open_model
from ..models import MODEL_DIR
from . import detector as det
from . import landmarks as lmk

MP_DIR = MODEL_DIR / "mediapipe"
PRESENCE_LOGIT = 0.0  # sigmoid 0.5, same default as MediaPipe's min tracking confidence
# Flip averaging: the landmark model also runs on the mirrored crop and the two estimates of each point are
# averaged. Spends GPU time on what MediaPipe, built for phones, does not: still-face jitter of mouth open
# 0.39 -> 0.29 (MediaPipe 0.42), cheekSquint ~ |yaw| 0.57 -> 0.38, CREMA-D emotion accuracy 62 -> 66 %.
# A wink stays one-sided (synthetic winks on CREMA-D: closed eye at 59 % of its open gap, the other at 87 %,
# same as without). Costs one more landmark pass: TensorRT 4.2 -> 5.5 ms, ncnn Vulkan on the RTX 2060 SUPER
# 14 -> 21 ms, which an integrated GPU may not fit in a 33 ms frame. On by default on NVIDIA runtimes only.
FLIP_RUNTIMES = ("cuda", "tensorrt")


class FaceMesh:
    def __init__(self, runtime: str = "vulkan", flip_average: bool | None = None):
        need = [MP_DIR / f"{n}.{e}" for n in ("face_detector", "face_landmarks") for e in ("onnx", "ncnn.bin")]
        if not all(p.exists() for p in need):
            raise SystemExit("MediaPipe models missing. Run: uv run python tools/export_mediapipe.py")
        # The detector runs rarely and is cheaper on CPU than a GPU or NPU dispatch.
        self.detector = open_model(MP_DIR / "face_detector", "ncnn-cpu")
        self.landmarker = open_model(MP_DIR / "face_landmarks", runtime)
        self.roi = None
        self.detections = 0
        self.flip_average = runtime in FLIP_RUNTIMES if flip_average is None else flip_average
        if self.flip_average:
            from ..adapters.mediapipe_points import load_canonical
            self.mirror = lmk.mirror_index(load_canonical())

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
            x = lmk.preprocess(bgr, m)
            out = self.landmarker.run({"in0": x})
            if out["out1"].item() > PRESENCE_LOGIT:
                raw = out["out0"]
                if self.flip_average:
                    flipped = self.landmarker.run({"in0": lmk.flip_input(x)})["out0"]
                    raw = (raw.reshape(478, 3) + lmk.unflip(flipped, self.mirror)) / 2
                landmarks = lmk.postprocess(raw, m, w, h)
                self.roi = lmk.roi_from_landmarks(landmarks * (w, h, w))
                return landmarks
            self.roi = None  # lost track, re-detect once on this frame
        return None


def presence_probability(logit: float) -> float:
    return 1 / (1 + math.exp(-logit))
