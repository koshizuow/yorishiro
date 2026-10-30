from dataclasses import dataclass

import numpy as np

from ..frame import FaceFrame


@dataclass(frozen=True)
class TrackerInfo:
    name: str
    description: str
    license: str
    commercial_use: bool
    runtime: str
    coverage: tuple[str, ...]  # ARKit names this model actually estimates


@dataclass
class TrackResult:
    frame: FaceFrame
    landmarks: np.ndarray  # (478, 3) MediaPipe-normalized image coords, used for overlay
    matrix: np.ndarray | None = None  # optional (4, 4) model -> camera transform
    aligned: np.ndarray | None = None  # optional tracker-internal points kept for calibration


class Tracker:
    """A face model plugin: image in, FaceFrame (ARKit 52 + pose + eyes) out."""

    info: TrackerInfo

    def process(self, bgr: np.ndarray, timestamp_ms: int) -> TrackResult | None:
        raise NotImplementedError

    def calibrate(self, result: TrackResult) -> None:
        """Capture the current frame as the neutral face. Optional."""

    def calibrate_window(self, results: list[TrackResult]) -> list[FaceFrame]:
        """Take the neutral from a stretch of frames instead of one, so a blink, a word or raised brows in
        a single frame do not shift the whole session. Returns the window's frames expressed against the
        new neutral (the app-side NeutralCalibration takes its resting values from them).

        Default, for trackers whose output does not depend on the neutral: calibrate on the most typical
        frame (closest to the per-channel median) and return the frames unchanged."""
        vecs = np.array([r.frame.blendshapes for r in results])
        self.calibrate(results[int(np.argmin(np.abs(vecs - np.median(vecs, axis=0)).sum(axis=1)))])
        return [r.frame for r in results]

    def close(self) -> None:
        pass
