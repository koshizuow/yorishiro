"""ARKit 52 FaceFrame to VTube Studio style tracking inputs (FaceAngleX, EyeOpenLeft, MouthSmile, ...).

These names are the de facto Live2D tracking inputs: VTube Studio, OpenVT and Yorishiro bind them to
standard Cubism parameters (ParamAngleX, ParamEyeLOpen, ParamMouthForm, ...).

Left/Right in the output are the avatar's own sides. With mirror on (the VTuber default) the avatar
behaves like a mirror image, so the user's left eye drives the avatar's right eye.
"""

import math

import numpy as np

from ..frame import ARKIT52_INDEX, FaceFrame

# Sign of each Live2D input relative to "screen right" / "up". Verified with screenshots in the app.
SIGN = {"FaceAngleX": 1.0, "FaceAngleY": 1.0, "FaceAngleZ": 1.0, "EyeX": 1.0, "EyeY": 1.0, "MouthX": 1.0}
EYE_FULL_DEG = 25.0
# MouthOpen also follows the lips: talking and laughing part the lips with little jaw, where MediaPipe's
# jawOpen stays near 0 (CREMA-D speech: half the frames with lips apart had jawOpen - mouthClose < 0.1, the
# usual Live2D dead zone). Geometric bounds, not fitted: under 1.5% of the face height is closed lips,
# about a quarter of it is a wide open mouth.
LIP_GAP_CLOSED = 0.015
LIP_GAP_OPEN = 0.22


def mouth_gap(landmarks: np.ndarray, width: int, height: int) -> float:
    """Inner lip gap over face height from MediaPipe-topology landmarks (normalized image coordinates)."""
    scale = np.array([width, height, width], np.float32)
    gap = np.linalg.norm((landmarks[13] - landmarks[14]) * scale)
    face = np.linalg.norm((landmarks[10] - landmarks[152]) * scale)
    return float(gap / face) if face > 1e-6 else 0.0


def _bs(frame: FaceFrame, name: str) -> float:
    return float(frame.blendshapes[ARKIT52_INDEX[name]])


def vts_params(frame: FaceFrame, mirror: bool = True) -> dict[str, float]:
    s = -1.0 if mirror else 1.0  # FaceFrame is unmirrored: + = subject's own left, which is screen left in a mirror
    yaw, pitch, roll = (math.degrees(float(a)) for a in frame.head_rotation)
    # avatar's right is screen left. Mirror shows the user's left on screen left, so the sides swap.
    user_l, user_r = ("Right", "Left") if mirror else ("Left", "Right")

    p = {
        "FaceAngleX": SIGN["FaceAngleX"] * s * yaw,
        "FaceAngleY": SIGN["FaceAngleY"] * pitch,
        "FaceAngleZ": SIGN["FaceAngleZ"] * s * roll,
        "FacePositionX": s * float(frame.head_translation[0]) * 100.0,
        "FacePositionY": float(frame.head_translation[1]) * 100.0,
        "FacePositionZ": float(frame.head_translation[2]) * 100.0,  # + = closer than the neutral
    }
    for side, avatar in (("Left", user_l), ("Right", user_r)):
        p[f"EyeOpen{avatar}"] = 1.0 - _bs(frame, f"eyeBlink{side}")
        eye = frame.left_eye_rotation if side == "Left" else frame.right_eye_rotation
        p[f"Eye{avatar}X"] = SIGN["EyeX"] * s * math.degrees(float(eye[0])) / EYE_FULL_DEG
        p[f"Eye{avatar}Y"] = SIGN["EyeY"] * math.degrees(float(eye[1])) / EYE_FULL_DEG
        up = _bs(frame, f"browOuterUp{side}") + 0.5 * _bs(frame, "browInnerUp")
        p[f"Brow{avatar}Y"] = up - _bs(frame, f"browDown{side}")

    smile = (_bs(frame, "mouthSmileLeft") + _bs(frame, "mouthSmileRight")) / 2
    frown = (_bs(frame, "mouthFrownLeft") + _bs(frame, "mouthFrownRight")) / 2
    p["MouthSmile"] = 0.5 + 0.5 * (smile - frown)
    p["MouthOpen"] = _bs(frame, "jawOpen") - _bs(frame, "mouthClose")
    if frame.mouth_gap is not None:
        lips = (frame.mouth_gap - LIP_GAP_CLOSED) / (LIP_GAP_OPEN - LIP_GAP_CLOSED)
        p["MouthOpen"] = max(p["MouthOpen"], lips)
    p["MouthX"] = SIGN["MouthX"] * s * (_bs(frame, "mouthLeft") - _bs(frame, "mouthRight"))
    p["Brows"] = 0.5 + 0.25 * (p["BrowLeftY"] + p["BrowRightY"])
    p["CheekPuff"] = _bs(frame, "cheekPuff")
    p["TongueOut"] = _bs(frame, "tongueOut")

    for k in ("EyeOpenLeft", "EyeOpenRight", "MouthSmile", "MouthOpen", "Brows", "CheekPuff", "TongueOut"):
        p[k] = float(np.clip(p[k], 0.0, 1.0))
    for k in ("EyeLeftX", "EyeLeftY", "EyeRightX", "EyeRightY", "MouthX", "BrowLeftY", "BrowRightY"):
        p[k] = float(np.clip(p[k], -1.0, 1.0))
    for k in ("FaceAngleX", "FaceAngleY", "FaceAngleZ"):
        p[k] = float(np.clip(p[k], -30.0, 30.0))
    # centimeters from the neutral, the app's input ranges
    for k, r in (("FacePositionX", 15.0), ("FacePositionY", 15.0), ("FacePositionZ", 10.0)):
        p[k] = float(np.clip(p[k], -r, r))
    return p
