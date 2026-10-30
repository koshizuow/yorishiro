"""MediaPipe's own blendshape model (Blendshapes GHUM, Apache-2.0, D3) on any MediaPipe-topology landmarks.

The same small network MediaPipe's Face Landmarker runs after FaceMesh, exported to ONNX by
tools/export_mediapipe.py and run on ONNX Runtime CPU (under 1 ms). On our FaceMesh-V2 landmarks it
reproduces MediaPipe's blendshapes (r 0.91 to 0.99 on the user's recording).

It was trained across head poses, the ICT solve on landmarks was not: with a neutral face turned or tilted
the ICT mouth shapes read 0.3 to 0.6 (jawForward, mouthShrug, mouthPress, mouthStretch), this model about 0.1.
Its brows barely move and cheekSquint, noseSneer and cheekPuff stay near 0, so it supplies only MP_SHAPES.
"""

import numpy as np

from ..backends.factory import open_model
from ..frame import ARKIT52, ARKIT52_INDEX
from ..models import MODEL_DIR

MODEL = MODEL_DIR / "mediapipe" / "face_blendshapes"

# Landmarks the model reads, as x, y in image pixels (face_blendshapes_graph.cc kLandmarksSubsetIdxs).
SUBSET = np.array([
    0, 1, 4, 5, 6, 7, 8, 10, 13, 14, 17, 21, 33, 37, 39, 40, 46, 52, 53, 54, 55, 58, 61, 63, 65, 66, 67, 70, 78,
    80, 81, 82, 84, 87, 88, 91, 93, 95, 103, 105, 107, 109, 127, 132, 133, 136, 144, 145, 146, 148, 149, 150,
    152, 153, 154, 155, 157, 158, 159, 160, 161, 162, 163, 168, 172, 173, 176, 178, 181, 185, 191, 195, 197,
    234, 246, 249, 251, 263, 267, 269, 270, 276, 282, 283, 284, 285, 288, 291, 293, 295, 296, 297, 300, 308,
    310, 311, 312, 314, 317, 318, 321, 323, 324, 332, 334, 336, 338, 356, 361, 362, 365, 373, 374, 375, 377,
    378, 379, 380, 381, 382, 384, 385, 386, 387, 388, 389, 390, 397, 398, 400, 402, 405, 409, 415, 454, 466,
    468, 469, 470, 471, 472, 473, 474, 475, 476, 477,
])
# Output order (kBlendshapeNames), _neutral first.
OUTPUT_NAMES = (
    "_neutral", "browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight",
    "cheekPuff", "cheekSquintLeft", "cheekSquintRight", "eyeBlinkLeft", "eyeBlinkRight", "eyeLookDownLeft",
    "eyeLookDownRight", "eyeLookInLeft", "eyeLookInRight", "eyeLookOutLeft", "eyeLookOutRight", "eyeLookUpLeft",
    "eyeLookUpRight", "eyeSquintLeft", "eyeSquintRight", "eyeWideLeft", "eyeWideRight", "jawForward", "jawLeft",
    "jawOpen", "jawRight", "mouthClose", "mouthDimpleLeft", "mouthDimpleRight", "mouthFrownLeft",
    "mouthFrownRight", "mouthFunnel", "mouthLeft", "mouthLowerDownLeft", "mouthLowerDownRight",
    "mouthPressLeft", "mouthPressRight", "mouthPucker", "mouthRight", "mouthRollLower", "mouthRollUpper",
    "mouthShrugLower", "mouthShrugUpper", "mouthSmileLeft", "mouthSmileRight", "mouthStretchLeft",
    "mouthStretchRight", "mouthUpperUpLeft", "mouthUpperUpRight", "noseSneerLeft", "noseSneerRight",
)
# Taken from this model, the rest from the ICT solve. Costs CREMA-D's sad mouthFrown (Cohen's d 0.62 -> 0),
# which this model does not show, and gains disgust's mouthUpperUp (0.21 -> 0.75).
MP_SHAPES = tuple(n for n in ARKIT52 if n.startswith(("mouth", "jaw")))
MP_MASK = np.array([n in MP_SHAPES for n in ARKIT52])
_TO_ARKIT = np.array([ARKIT52_INDEX[n] for n in OUTPUT_NAMES[1:]])


class MediaPipeBlendshapes:
    def __init__(self):
        if not MODEL.with_suffix(".onnx").exists():
            raise SystemExit("MediaPipe blendshape model missing. Run: uv run python tools/export_mediapipe.py")
        self.backend = open_model(MODEL, "ort-cpu")

    def __call__(self, landmarks: np.ndarray, width: int, height: int) -> np.ndarray:
        """ARKit 52 from normalized image landmarks (478, 3)."""
        pts = landmarks[SUBSET, :2] * np.array([width, height], np.float32)
        out = self.backend.run({"in0": pts[None].astype(np.float32)})["out0"].reshape(-1)
        bs = np.zeros(52, dtype=np.float32)
        bs[_TO_ARKIT] = out[1:]
        return bs


def merge(ict: np.ndarray, mp: np.ndarray) -> np.ndarray:
    """MP_SHAPES from MediaPipe's model, everything else from the ICT solve."""
    return np.where(MP_MASK, mp, ict).astype(np.float32)
