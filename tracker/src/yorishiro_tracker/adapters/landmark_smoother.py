"""MediaPipe's landmark smoothing for any normalized landmark set, before anything is fitted to it.

Same filter and settings as MediaPipe's Face Landmarker in video mode (face_landmarks_detector_graph.cc,
LandmarksSmoothingCalculator): One Euro per coordinate, velocity measured in face sizes per second (the
landmark box's mean side), min cutoff 0.05 Hz (alpha about 0.01 at rest), beta 80 (alpha about 0.94 when
moving fast), derivative cutoff 1 Hz, derivative from the previous raw value. MediaPipe's blendshapes and our
solver both read landmarks after this. Without it our still-face jitter was 2 to 25 times MediaPipe's on
brows and head pose, after the same FrameSmoother.
"""

import math

import numpy as np


def _alpha(cutoff, dt):
    tau = 1.0 / (2 * math.pi * cutoff)
    return 1.0 / (1.0 + tau / dt)


class LandmarkSmoother:
    def __init__(self, min_cutoff: float = 0.05, beta: float = 80.0, d_cutoff: float = 1.0):
        self.min_cutoff, self.beta, self.d_cutoff = min_cutoff, beta, d_cutoff
        self.reset()

    def reset(self) -> None:
        self.raw = self.x = self.dx = self.t = None

    def __call__(self, landmarks: np.ndarray, t: float) -> np.ndarray:
        """landmarks (N, 3) normalized image coordinates, t in seconds."""
        lm = landmarks.astype(np.float64)
        if self.t is None or t <= self.t:
            self.raw, self.x, self.dx, self.t = lm, lm.copy(), np.zeros_like(lm), t
            return landmarks
        dt = t - self.t
        size = np.ptp(lm[:, :2], axis=0).mean()
        scale = 1.0 / size if size > 1e-6 else 0.0
        dx = (lm - self.raw) * scale / dt
        self.dx = self.dx + _alpha(self.d_cutoff, dt) * (dx - self.dx)
        a = _alpha(self.min_cutoff + self.beta * np.abs(self.dx), dt)
        self.x = self.x + a * (lm - self.x)
        self.raw, self.t = lm, t
        return self.x.astype(landmarks.dtype)
