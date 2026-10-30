"""SMIRK research model as a tracker plugin (dev stand-in, non-commercial).

MediaPipe-topology landmarks from FaceMesh-V2 on ncnn provide the crop, head pose and fallback
values. SMIRK's expression encoder runs on ncnn (Vulkan when available). Until the FLAME decoder
is wired in, only the outputs that map directly to ARKit come from SMIRK.
"""

from dataclasses import replace

import numpy as np

from ..backends.factory import open_model
from ..frame import ARKIT52_INDEX, FaceFrame
from ..research.smirk import SMIRK_DIR, postprocess, preprocess
from .base import Tracker, TrackerInfo, TrackResult
from .facemesh_gpu import FaceMeshGpuTracker

JAW_OPEN_FULL_RAD = 0.2  # FLAME jaw rotation treated as jawOpen = 1.0, wide-open mouth on the golden set is about 0.17
# FLAME eyelid order checked against MediaPipe blinks on the golden set (eyelid[0] tracks the left eye).
EYELID_TO_ARKIT = ("eyeBlinkLeft", "eyeBlinkRight")


class SmirkTracker(Tracker):
    info = TrackerInfo(
        name="smirk",
        description="SMIRK expression encoder (FLAME). Direct outputs only until FLAME is installed",
        license="MIT code, needs FLAME (non-commercial, user download)",
        commercial_use=False,
        runtime="FaceMesh-V2 + SMIRK",
        coverage=("jawOpen", "eyeBlinkLeft", "eyeBlinkRight"),
    )

    def __init__(self, runtime: str = "vulkan"):
        stem = SMIRK_DIR / "smirk_expression"
        if not stem.with_suffix(".onnx").exists():
            raise SystemExit("SMIRK model missing. Run: uv run python tools/export_smirk.py")
        self.base = FaceMeshGpuTracker(runtime=runtime)
        self.backend = open_model(stem, runtime)
        self.info = replace(self.info, runtime=f"{self.backend.name} (FaceMesh-V2 + SMIRK)")

    def process(self, bgr: np.ndarray, timestamp_ms: int) -> TrackResult | None:
        res = self.base.process(bgr, timestamp_ms)
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

    def calibrate(self, result: TrackResult) -> None:
        self.base.calibrate(result)

    def calibrate_window(self, results: list[TrackResult]) -> list[FaceFrame]:
        keep = [ARKIT52_INDEX["jawOpen"]] + [ARKIT52_INDEX[n] for n in EYELID_TO_ARKIT]
        out = []
        for r, f in zip(results, self.base.calibrate_window(results)):
            bs = f.blendshapes.copy()
            bs[keep] = r.frame.blendshapes[keep]
            out.append(replace(f, blendshapes=bs))
        return out

    def close(self) -> None:
        self.base.close()
