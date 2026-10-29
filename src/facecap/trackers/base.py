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


class Tracker:
    """A face model plugin: image in, FaceFrame (ARKit 52 + pose + eyes) out."""

    info: TrackerInfo

    def process(self, bgr: np.ndarray, timestamp_ms: int) -> TrackResult | None:
        raise NotImplementedError

    def calibrate(self, result: TrackResult) -> None:
        """Capture the current frame as the neutral face. Optional."""

    def close(self) -> None:
        pass
