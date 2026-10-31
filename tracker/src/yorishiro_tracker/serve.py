"""Headless tracking loop that feeds the Yorishiro app, plus a synthetic sender for sign checks."""

import json
import os
import sys
import time
from pathlib import Path

import cv2
import numpy as np

from .capture import Camera
from .frame import ARKIT52_INDEX, FaceFrame
from .processing import FrameSmoother, NeutralCalibration
from .registry import create_tracker
from .sinks.link import LinkControl, LinkSink
from .viz import draw_landmarks

# The first frame uses the detector's crop, the landmark-based ROI needs about a second to settle.
# A neutral taken before that reads normal open eyes as half closed.
SETTLE_FACES = 30
# the neutral is the median over this many faces (about 1.5 s at 16 fps, 0.8 s at 30), started once tracking
# has settled and again on the app's calibrate command
CALIBRATE_FACES = 24


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
              smoothing: bool = True, control: LinkControl | None = None, parent_pid: int | None = None,
              extra_sinks: list | None = None, hands: bool = False) -> int:
    """Returns a process exit code. Every failure is also reported to the app as a status message."""
    source = f"recording {replay.name}" if replay else f"camera {camera}"
    sink.status("starting", f"loading tracker {tracker_name}", source=source)
    try:
        tracker = create_tracker(tracker_name, runtime)
    except (Exception, SystemExit) as e:
        return _fail(sink, f"tracker {tracker_name!r} failed to start: {e}")
    info = {"tracker": tracker.info.name, "runtime": tracker.info.runtime, "source": source,
            "commercial_use": tracker.info.commercial_use}
    print(f"tracker {tracker.info.name} ({tracker.info.runtime}) -> {sink.addr[0]}:{sink.addr[1]}")
    hand_worker = None
    if hands:
        try:
            from .mediapipe_ncnn.hands import HandWorker
            hand_worker = HandWorker(runtime=runtime or "vulkan")
            info["hands"] = hand_worker.tracker.runtime
        except Exception as e:  # the face keeps working without hands
            print(f"hand tracking unavailable: {e}")
            sink.status("starting", f"hand tracking unavailable: {e}", source=source)
    calibration = NeutralCalibration()
    smoother = FrameSmoother()
    frames = _recording_frames(replay, loop) if replay else _camera_frames(camera, *size)
    # camera pictures only go out when asked (the app shows a 3D head instead), see "preview" below
    preview_on, last_preview = False, 0.0
    t0 = time.monotonic()
    last_ts, sent, t_report, faces, infer_ms, fps = -1, 0, t0, 0, 0.0, 0.0
    recalibrate = False
    window: list | None = None  # results collected for a calibration in progress
    calibrated = False
    try:
        for img in frames:
            for cmd in control.poll() if control else []:
                if cmd.get("cmd") == "calibrate":
                    recalibrate = True
                elif cmd.get("cmd") == "preview":
                    preview_on = bool(cmd.get("on", True))
                elif cmd.get("cmd") == "quit":
                    return 0
            if hand_worker:
                hand_worker.submit(img)
            ts = max(int((time.monotonic() - t0) * 1000), last_ts + 1)
            last_ts = ts
            t_infer = time.perf_counter()
            res = tracker.process(img, ts)
            infer_ms = 0.9 * infer_ms + 100 * (time.perf_counter() - t_infer)
            frame = None
            if res is not None:
                faces += 1
                if faces == SETTLE_FACES or recalibrate:
                    window = []
                    print("collecting the neutral" + (" for the app" if recalibrate else " after tracking settled"))
                    recalibrate = False
                if window is not None:
                    window.append(res)
                    if len(window) == CALIBRATE_FACES:
                        calibration.set_many(tracker.calibrate_window(window))
                        smoother.reset()
                        window, calibrated = None, True
                        print(f"neutral set from {CALIBRATE_FACES} frames")
                elif calibration.neutral is None:  # provisional until tracking settles
                    calibration.set(res.frame)
                frame = calibration(res.frame)
                if smoothing:
                    frame = smoother(frame)
            sink.send(frame, ts, hand_worker.latest() if hand_worker else None,
                      hand_worker.latest_points() if hand_worker else None)
            for extra in extra_sinks or []:
                extra.send(frame, ts)
            sent += 1
            now = time.monotonic()
            if preview_on and now - last_preview >= 0.1:
                last_preview = now
                view = img.copy()
                if res is not None:
                    draw_landmarks(view, res.landmarks)
                sink.preview(view)
            if now - t_report >= 1:
                if parent_pid and not _alive(parent_pid):
                    print("app is gone, stopping")
                    return 0
                fps = sent / (now - t_report)
                sent, t_report = 0, now
                sink.status("running", "tracking" if res is not None else "no face in view", fps=round(fps, 1),
                            infer_ms=round(infer_ms, 1), face=res is not None, calibrated=calibrated,
                            **({"hands_ms": round(hand_worker.infer_ms, 1)} if hand_worker else {}), **info)
        if not replay:
            return _fail(sink, f"camera {camera} stopped delivering frames (unplugged or used by another app?)")
        return 0
    except RuntimeError as e:  # Camera() raises on open failure
        return _fail(sink, f"{e}. Check that no other app uses it, or pick another camera.")
    except KeyboardInterrupt:
        return 0
    finally:
        tracker.close()
        if hand_worker:
            hand_worker.close()
        if control:
            control.close()
        for extra in extra_sinks or []:
            extra.close()
        sink.close()


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _fail(sink: LinkSink, message: str) -> int:
    print(f"error: {message}", file=sys.stderr)
    for _ in range(3):  # repeat so an app that starts listening a moment later still sees it
        sink.status("error", message)
        time.sleep(0.3)
    return 2


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


def run_send_test(sink: LinkSink, seconds: float, rate: float = 30.0, extra_sinks: list | None = None,
                  **values) -> None:
    frame = synthetic_frame(**values)
    t0 = time.monotonic()
    n = 0
    while (elapsed := time.monotonic() - t0) < seconds:
        for s in [sink] + (extra_sinks or []):
            s.send(frame, int(elapsed * 1000))
        n += 1
        time.sleep(max(0.0, n / rate - (time.monotonic() - t0)))
    for s in [sink] + (extra_sinks or []):
        s.close()


def parse_blendshapes(items: list[str]) -> dict[str, float]:
    out = {}
    for item in items:
        name, _, value = item.partition("=")
        if name not in ARKIT52_INDEX or not value:
            raise SystemExit(f"bad blendshape {item!r}, use name=value with an ARKit 52 name")
        out[name] = float(value)
    return out
