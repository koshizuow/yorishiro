"""Headless tracking loop that feeds the Yorishiro app, plus a synthetic sender for sign checks."""

import json
import time
from pathlib import Path

import cv2
import numpy as np

from .capture import Camera
from .frame import ARKIT52_INDEX, FaceFrame
from .processing import FrameSmoother, NeutralCalibration
from .registry import create_tracker
from .sinks.link import LinkSink

# The first frame uses the detector's crop, the landmark-based ROI needs about a second to settle.
# A neutral taken before that reads normal open eyes as half closed.
SETTLE_FACES = 30


def _recording_frames(rec_dir: Path, loop: bool):
    meta = json.loads((rec_dir / "meta.json").read_text())
    while True:
        start = time.monotonic()
        t_first = meta["timestamps_ms"][0]
        for i, ts in enumerate(meta["timestamps_ms"]):
            delay = (ts - t_first) / 1000 - (time.monotonic() - start)
            if delay > 0:
                time.sleep(delay)
            yield cv2.imread(str(rec_dir / "frames" / f"{i:05d}.jpg"))
        if not loop:
            return


def _camera_frames(index: int, width: int, height: int):
    with Camera(index, width, height) as cam:
        while (img := cam.read()) is not None:
            yield img


def run_serve(tracker_name: str, runtime: str | None, sink: LinkSink, camera: int = 0,
              size: tuple[int, int] = (1280, 720), replay: Path | None = None, loop: bool = False,
              smoothing: bool = True) -> None:
    tracker = create_tracker(tracker_name, runtime)
    print(f"tracker {tracker.info.name} ({tracker.info.runtime}) -> {sink.addr[0]}:{sink.addr[1]}")
    calibration = NeutralCalibration()
    smoother = FrameSmoother()
    frames = _recording_frames(replay, loop) if replay else _camera_frames(camera, *size)
    t0 = time.monotonic()
    last_ts, sent, t_report, faces = -1, 0, t0, 0
    try:
        for img in frames:
            ts = max(int((time.monotonic() - t0) * 1000), last_ts + 1)
            last_ts = ts
            res = tracker.process(img, ts)
            frame = None
            if res is not None:
                faces += 1
                if faces == SETTLE_FACES:
                    tracker.calibrate(res)
                    last_ts = ts + 1
                    res = tracker.process(img, last_ts) or res
                    calibration.set(res.frame)
                    smoother.reset()
                    print("neutral recalibrated after tracking settled")
                elif calibration.neutral is None:  # provisional until tracking settles
                    calibration.set(res.frame)
                frame = calibration(res.frame)
                if smoothing:
                    frame = smoother(frame)
            sink.send(frame, ts)
            sent += 1
            if time.monotonic() - t_report >= 5:
                print(f"{sent / (time.monotonic() - t_report):.1f} fps")
                sent, t_report = 0, time.monotonic()
    except KeyboardInterrupt:
        pass
    finally:
        tracker.close()
        sink.close()


def synthetic_frame(yaw=0.0, pitch=0.0, roll=0.0, eye_yaw=0.0, eye_pitch=0.0,
                    blendshapes: dict[str, float] | None = None, timestamp_ms: int = 0) -> FaceFrame:
    """A frame with known values. Angles in degrees, FaceFrame conventions (unmirrored)."""
    bs = np.zeros(52, dtype=np.float32)
    for name, value in (blendshapes or {}).items():
        bs[ARKIT52_INDEX[name]] = value
    eye = np.radians([eye_yaw, eye_pitch, 0.0]).astype(np.float32)
    return FaceFrame(
        timestamp_ms=timestamp_ms, blendshapes=bs,
        head_rotation=np.radians([yaw, pitch, roll]).astype(np.float32),
        head_translation=np.zeros(3, dtype=np.float32),
        left_eye_rotation=eye, right_eye_rotation=eye.copy(),
    )


def run_send_test(sink: LinkSink, seconds: float, rate: float = 30.0, **values) -> None:
    frame = synthetic_frame(**values)
    t0 = time.monotonic()
    n = 0
    while (elapsed := time.monotonic() - t0) < seconds:
        sink.send(frame, int(elapsed * 1000))
        n += 1
        time.sleep(max(0.0, n / rate - (time.monotonic() - t0)))
    sink.close()


def parse_blendshapes(items: list[str]) -> dict[str, float]:
    out = {}
    for item in items:
        name, _, value = item.partition("=")
        if name not in ARKIT52_INDEX or not value:
            raise SystemExit(f"bad blendshape {item!r}, use name=value with an ARKit 52 name")
        out[name] = float(value)
    return out
