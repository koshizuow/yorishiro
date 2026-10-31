from dataclasses import dataclass

import numpy as np

# Same order as Live Link Face CSV and Apple's ARFaceAnchor.BlendShapeLocation.
ARKIT52 = (
    "eyeBlinkLeft", "eyeLookDownLeft", "eyeLookInLeft", "eyeLookOutLeft",
    "eyeLookUpLeft", "eyeSquintLeft", "eyeWideLeft",
    "eyeBlinkRight", "eyeLookDownRight", "eyeLookInRight", "eyeLookOutRight",
    "eyeLookUpRight", "eyeSquintRight", "eyeWideRight",
    "jawForward", "jawRight", "jawLeft", "jawOpen",
    "mouthClose", "mouthFunnel", "mouthPucker", "mouthRight", "mouthLeft",
    "mouthSmileLeft", "mouthSmileRight", "mouthFrownLeft", "mouthFrownRight",
    "mouthDimpleLeft", "mouthDimpleRight", "mouthStretchLeft", "mouthStretchRight",
    "mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper",
    "mouthPressLeft", "mouthPressRight", "mouthLowerDownLeft", "mouthLowerDownRight",
    "mouthUpperUpLeft", "mouthUpperUpRight",
    "browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight",
    "cheekPuff", "cheekSquintLeft", "cheekSquintRight",
    "noseSneerLeft", "noseSneerRight",
    "tongueOut",
)
assert len(ARKIT52) == 52
ARKIT52_INDEX = {name: i for i, name in enumerate(ARKIT52)}

POSE_NAMES = (
    "headYaw", "headPitch", "headRoll",
    "leftEyeYaw", "leftEyePitch", "leftEyeRoll",
    "rightEyeYaw", "rightEyePitch", "rightEyeRoll",
)
FRAME_NAMES = ARKIT52 + POSE_NAMES
FRAME_DIM = len(FRAME_NAMES)


@dataclass
class FaceFrame:
    """One tracked face. Angles in radians, translation in meters (camera space, y up, -z forward).

    Sign convention: yaw + = subject turns to their own left, pitch + = up,
    roll + = top of head tilts toward the subject's own left shoulder.
    """

    timestamp_ms: int
    blendshapes: np.ndarray
    head_rotation: np.ndarray
    head_translation: np.ndarray
    left_eye_rotation: np.ndarray
    right_eye_rotation: np.ndarray
    # inner lip gap over face height (landmarks 13-14 over 10-152), None when the tracker has no landmarks
    mouth_gap: float | None = None

    def to_vector(self) -> np.ndarray:
        return np.concatenate([
            self.blendshapes, self.head_rotation,
            self.left_eye_rotation, self.right_eye_rotation,
        ]).astype(np.float32)
