"""Backend- and model-independent FaceFrame processing: neutral calibration and smoothing."""

import math
from dataclasses import replace

import numpy as np

from .frame import FaceFrame
from .pose import rotation_to_ypr, ypr_to_rotation


class NeutralCalibration:
    """Removes the per-session neutral: camera placement for pose, resting values for blendshapes."""

    def __init__(self):
        self.neutral: FaceFrame | None = None
        self._rot = np.eye(3)

    def set(self, frame: FaceFrame) -> None:
        self.neutral = frame
        self._rot = ypr_to_rotation(frame.head_rotation)

    def __call__(self, frame: FaceFrame) -> FaceFrame:
        if self.neutral is None:
            return frame
        n = self.neutral
        bs = np.clip((frame.blendshapes - n.blendshapes) / np.maximum(1.0 - n.blendshapes, 1e-3), 0.0, 1.0)
        # Left-multiply: the offset comes from camera placement, so remove it in camera space.
        head = rotation_to_ypr(self._rot.T @ ypr_to_rotation(frame.head_rotation))
        return replace(
            frame,
            blendshapes=bs.astype(np.float32),
            head_rotation=head,
            head_translation=frame.head_translation - n.head_translation,
            left_eye_rotation=frame.left_eye_rotation - n.left_eye_rotation,
            right_eye_rotation=frame.right_eye_rotation - n.right_eye_rotation,
        )


class OneEuro:
    """One Euro filter (Casiez et al. 2012) over a vector, driven by timestamps in seconds."""

    def __init__(self, min_cutoff: float, beta: float, d_cutoff: float = 1.0):
        self.min_cutoff, self.beta, self.d_cutoff = min_cutoff, beta, d_cutoff
        self.reset()

    def reset(self) -> None:
        self.x = self.dx = self.t = None

    @staticmethod
    def _alpha(cutoff, dt):
        tau = 1.0 / (2 * math.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)

    def __call__(self, x: np.ndarray, t: float) -> np.ndarray:
        if self.t is None or t <= self.t:
            self.x, self.dx, self.t = x.copy(), np.zeros_like(x), t
            return x
        dt = t - self.t
        dx = (x - self.x) / dt
        a_d = self._alpha(self.d_cutoff, dt)
        self.dx = a_d * dx + (1 - a_d) * self.dx
        cutoff = self.min_cutoff + self.beta * np.abs(self.dx)
        a = self._alpha(cutoff, dt)
        self.x = a * x + (1 - a) * self.x
        self.t = t
        return self.x.copy()


class FrameSmoother:
    """Per-group One Euro settings. Units: blendshapes 0..1, angles in radians, translation in meters."""

    def __init__(self, blendshapes=(1.5, 4.0), head=(1.0, 0.6), eyes=(2.0, 1.5), translation=(1.0, 2.0)):
        self.bs, self.head = OneEuro(*blendshapes), OneEuro(*head)
        self.eyes, self.trans = OneEuro(*eyes), OneEuro(*translation)

    def reset(self) -> None:
        for f in (self.bs, self.head, self.eyes, self.trans):
            f.reset()

    def __call__(self, frame: FaceFrame) -> FaceFrame:
        t = frame.timestamp_ms / 1000.0
        eyes = self.eyes(np.concatenate([frame.left_eye_rotation, frame.right_eye_rotation]), t)
        return replace(
            frame,
            blendshapes=np.clip(self.bs(frame.blendshapes, t), 0.0, 1.0).astype(np.float32),
            head_rotation=self.head(frame.head_rotation, t).astype(np.float32),
            head_translation=self.trans(frame.head_translation, t).astype(np.float32),
            left_eye_rotation=eyes[:3].astype(np.float32),
            right_eye_rotation=eyes[3:].astype(np.float32),
        )
