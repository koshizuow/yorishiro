import math

import numpy as np

from .frame import ARKIT52_INDEX

MAX_EYE_YAW = math.radians(30.0)
MAX_EYE_PITCH = math.radians(25.0)


def _rot_x(a: float) -> np.ndarray:
    c, s = math.cos(a), math.sin(a)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])


def _rot_y(a: float) -> np.ndarray:
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])


def _rot_z(a: float) -> np.ndarray:
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])


def ypr_to_rotation(ypr: np.ndarray) -> np.ndarray:
    """Inverse of rotation_to_ypr."""
    yaw, pitch, roll = (float(a) for a in ypr)
    return _rot_y(yaw) @ _rot_x(-pitch) @ _rot_z(-roll)


def rotation_to_ypr(r: np.ndarray) -> np.ndarray:
    """Face-model rotation (x = subject's left, y up, z out of the face) to yaw/pitch/roll."""
    f = r[:, 2]
    yaw = math.atan2(f[0], f[2])
    pitch = math.asin(float(np.clip(f[1], -1.0, 1.0)))
    # Remove yaw and pitch, what is left is a pure rotation about the face's z axis.
    r_roll = (_rot_y(yaw) @ _rot_x(-pitch)).T @ r
    up = r_roll[:, 1]
    roll = math.atan2(up[0], up[1])
    return np.array([yaw, pitch, roll], dtype=np.float32)


def eye_rotations_from_blendshapes(bs: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Approximate eye yaw/pitch from eyeLook* blendshapes. Same sign convention as the head."""
    g = lambda name: float(bs[ARKIT52_INDEX[name]])
    left = np.array([
        (g("eyeLookOutLeft") - g("eyeLookInLeft")) * MAX_EYE_YAW,
        (g("eyeLookUpLeft") - g("eyeLookDownLeft")) * MAX_EYE_PITCH,
        0.0,
    ], dtype=np.float32)
    right = np.array([
        (g("eyeLookInRight") - g("eyeLookOutRight")) * MAX_EYE_YAW,
        (g("eyeLookUpRight") - g("eyeLookDownRight")) * MAX_EYE_PITCH,
        0.0,
    ], dtype=np.float32)
    return left, right
