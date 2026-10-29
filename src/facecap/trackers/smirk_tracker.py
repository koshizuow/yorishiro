"""SMIRK research model as a tracker plugin (dev stand-in, non-commercial).

MediaPipe provides landmarks for the crop and head pose. SMIRK's expression encoder runs on
ncnn (Vulkan when available). Until the FLAME decoder is wired in, only the outputs that map
directly to ARKit are used. The rest falls back to MediaPipe.
"""

import numpy as np

from ..backends.ncnn_backend import NcnnBackend
from ..frame import ARKIT52_INDEX
from ..research.smirk import SMIRK_DIR, postprocess, preprocess
from .base import Tracker, TrackerInfo, TrackResult
from .mediapipe_ref import MediaPipeTracker

JAW_OPEN_FULL_RAD = 0.2  # FLAME jaw rotation treated as jawOpen = 1.0, wide-open mouth on the golden set is about 0.17
# FLAME eyelid order checked against MediaPipe blinks on the golden set (eyelid[0] tracks the left eye).
EYELID_TO_ARKIT = ("eyeBlinkLeft", "eyeBlinkRight")


class SmirkTracker(Tracker):
    info = TrackerInfo(
        name="smirk",
        description="SMIRK expression encoder (FLAME). Direct outputs only until FLAME is installed",
        license="MIT code, needs FLAME (non-commercial, user download)",
        commercial_use=False,
        runtime="ncnn Vulkan FP16",
        coverage=("jawOpen", "eyeBlinkLeft", "eyeBlinkRight"),
    )

    def __init__(self, gpu: bool = True, fp16: bool = True):
        param, model = SMIRK_DIR / "smirk_expression.ncnn.param", SMIRK_DIR / "smirk_expression.ncnn.bin"
        if not param.exists():
            raise SystemExit("SMIRK ncnn model missing. Run: uv run python tools/export_smirk.py")
        self.mp = MediaPipeTracker()
        self.backend = NcnnBackend(param, model, gpu=gpu, fp16=fp16)

    def process(self, bgr: np.ndarray, timestamp_ms: int) -> TrackResult | None:
        res = self.mp.process(bgr, timestamp_ms)
        if res is None:
            return None
        raw = self.backend.run({"in0": preprocess(bgr, res.landmarks)})["out0"]
        expr = postprocess(raw)
        bs = res.frame.blendshapes
        bs[ARKIT52_INDEX["jawOpen"]] = min(expr.jaw[0] / JAW_OPEN_FULL_RAD, 1.0)
        for name, v in zip(EYELID_TO_ARKIT, expr.eyelid):
            bs[ARKIT52_INDEX[name]] = v
        res.smirk = expr
        return res

    def close(self) -> None:
        self.mp.close()
