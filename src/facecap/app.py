import json
import time
from pathlib import Path

import cv2
import mediapipe as mp
import numpy as np

from .avatar.ict import ensure_ict_facekit
from .avatar.renderer import HeadRenderer
from .capture import Camera
from .frame import FRAME_DIM
from .models import FACE_LANDMARKER_URL
from .pose import ypr_to_rotation
from .processing import FrameSmoother, NeutralCalibration
from .registry import create_tracker
from .trackers.mediapipe_ref import MediaPipeTracker
from .viz import blendshape_panel, draw_banner, draw_hud, draw_landmarks, pose_lines

WINDOW = "facecap"
VIEW_H = 540

# (label, on-screen instruction). Directions are the subject's own left/right.
GUIDE = (
    ("neutral", "Look straight at the camera, neutral face"),
    ("head_left", "Turn your head to YOUR left"),
    ("head_right", "Turn your head to YOUR right"),
    ("head_up", "Tilt your head up"),
    ("head_down", "Tilt your head down"),
    ("roll_left", "Tilt head toward YOUR left shoulder"),
    ("roll_right", "Tilt head toward YOUR right shoulder"),
    ("eyes_left", "Head still, eyes to YOUR left"),
    ("eyes_right", "Head still, eyes to YOUR right"),
    ("eyes_up", "Head still, eyes up"),
    ("eyes_down", "Head still, eyes down"),
    ("blink", "Close both eyes"),
    ("wink_left", "Close only YOUR left eye"),
    ("wink_right", "Close only YOUR right eye"),
    ("jaw_open", "Open your mouth wide"),
    ("smile", "Big smile"),
    ("brows_up", "Raise your eyebrows"),
    ("pucker", "Pucker your lips (kiss)"),
    ("cheek_puff", "Puff your cheeks"),
)
GUIDE_SECONDS = 3.0


class Stats:
    """Per-second FPS, mean inference time and process CPU usage (100% = one core)."""

    def __init__(self):
        self._reset(time.perf_counter(), time.process_time())
        self.text = "warming up"

    def _reset(self, wall: float, cpu: float) -> None:
        self.wall0, self.cpu0, self.frames, self.infer_s = wall, cpu, 0, 0.0

    def tick(self, infer_s: float) -> None:
        self.frames += 1
        self.infer_s += infer_s
        wall, cpu = time.perf_counter(), time.process_time()
        dt = wall - self.wall0
        if dt >= 1.0:
            self.text = (
                f"{self.frames / dt:4.1f} fps  infer {1000 * self.infer_s / self.frames:5.1f} ms"
                f"  CPU {100 * (cpu - self.cpu0) / dt:5.0f}%"
            )
            self._reset(wall, cpu)


class Recorder:
    def __init__(self, out_dir: Path):
        self.out_dir = out_dir
        self.frames_dir = out_dir / "frames"
        self.frames_dir.mkdir(parents=True, exist_ok=False)
        self.timestamps: list[int] = []
        self.labels: list[str | None] = []
        self.size: tuple[int, int] | None = None

    def add(self, img: np.ndarray, timestamp_ms: int, label: str | None = None) -> None:
        cv2.imwrite(str(self.frames_dir / f"{len(self.timestamps):05d}.jpg"), img,
                    [cv2.IMWRITE_JPEG_QUALITY, 95])
        self.timestamps.append(timestamp_ms)
        self.labels.append(label)
        self.size = (img.shape[1], img.shape[0])

    def close(self) -> None:
        meta = {"count": len(self.timestamps), "size": self.size,
                "timestamps_ms": self.timestamps, "labels": self.labels}
        (self.out_dir / "meta.json").write_text(json.dumps(meta))
        print(f"recorded {len(self.timestamps)} frames to {self.out_dir}")


def run_preview(camera: int, width: int, height: int, record_dir: Path | None = None,
                seconds: float | None = None, guided: bool = False, avatar: bool = True,
                tracker_name: str = "mediapipe") -> None:
    tracker = create_tracker(tracker_name)
    info = tracker.info
    covered = set(info.coverage)
    print(f"tracker {info.name}: {info.description}\n  license: {info.license}"
          f"  commercial use: {'yes' if info.commercial_use else 'NO'}  runtime: {info.runtime}")
    head = ensure_ict_facekit() if avatar else None
    renderer = HeadRenderer(head, size=VIEW_H) if head else None
    recorder = Recorder(record_dir) if record_dir else None
    stats = Stats()
    t0 = time.monotonic()
    last_ts = -1
    last_frame = None
    last_res = None
    calibration = NeutralCalibration()
    smoother = FrameSmoother()
    smoothing = True
    render_ms = 0.0
    try:
        with Camera(camera, width, height) as cam:
            while True:
                img = cam.read()
                if img is None:
                    print("camera returned no frame")
                    break
                ts = max(int((time.monotonic() - t0) * 1000), last_ts + 1)
                last_ts = ts

                t_infer = time.perf_counter()
                res = tracker.process(img, ts)
                stats.tick(time.perf_counter() - t_infer)

                step = None
                if guided:
                    i_step = int(ts / 1000 / GUIDE_SECONDS)
                    if i_step >= len(GUIDE):
                        break
                    step = GUIDE[i_step]
                if recorder:
                    recorder.add(img, ts, step[0] if step else None)
                    if seconds is not None and not guided and ts >= seconds * 1000:
                        break

                view = img.copy()
                if res:
                    draw_landmarks(view, res.landmarks)
                    last_res = res
                    last_frame = calibration(res.frame)
                    if smoothing:
                        last_frame = smoother(last_frame)
                view = cv2.flip(view, 1)
                view = cv2.resize(view, (round(view.shape[1] * VIEW_H / view.shape[0]), VIEW_H),
                                  interpolation=cv2.INTER_AREA)
                hud = [f"{info.name} ({info.runtime}){'' if info.commercial_use else '  NON-COMMERCIAL'}",
                       stats.text] + pose_lines(last_frame if res else None)
                hud.append(f"smoothing {'on' if smoothing else 'off'}   "
                           f"neutral {'set' if calibration.neutral is not None else 'not set, press c'}")
                if renderer:
                    hud.append(f"avatar {render_ms:4.1f} ms   [c] calibrate  [s] smoothing  [q] quit")
                if recorder:
                    hud.append(f"REC {len(recorder.timestamps)}")
                draw_hud(view, hud)
                if step:
                    left = GUIDE_SECONDS - (ts / 1000) % GUIDE_SECONDS
                    draw_banner(view, f"{step[1]}  ({left:.0f})")
                tiles = [view]
                if renderer:
                    t_render = time.perf_counter()
                    tiles.append(_render_avatar(renderer, head, last_frame))
                    render_ms = 0.9 * render_ms + 100 * (time.perf_counter() - t_render)
                tiles.append(blendshape_panel(last_frame.blendshapes if last_frame else None, VIEW_H,
                                              covered=covered))
                cv2.imshow(WINDOW, np.hstack(tiles))
                key = cv2.waitKey(1) & 0xFF
                if key in (27, ord("q")):
                    break
                if key == ord("c") and last_res is not None:
                    tracker.calibrate(last_res)
                    res_after = tracker.process(img, ts + 1)  # re-read so the neutral matches the new tracker state
                    last_ts = ts + 1
                    calibration.set((res_after or last_res).frame)
                    smoother.reset()
                if key == ord("s"):
                    smoothing = not smoothing
                    smoother.reset()
                if not _window_open():
                    break
    finally:
        tracker.close()
        if renderer:
            renderer.close()
        cv2.destroyAllWindows()
        if recorder:
            recorder.close()


def _window_open() -> bool:
    try:
        return cv2.getWindowProperty(WINDOW, cv2.WND_PROP_VISIBLE) >= 1
    except cv2.error:  # Qt backend raises once the window is closed
        return False


def _render_avatar(renderer: HeadRenderer, head, frame) -> np.ndarray:
    if frame is None:
        return renderer.render(np.zeros(len(head.names), np.float32), np.eye(3))
    return renderer.render(head.weights_from_arkit(frame.blendshapes), ypr_to_rotation(frame.head_rotation))


def run_golden(rec_dir: Path) -> Path:
    """Replay a recording through the reference tracker and store its outputs."""
    meta = json.loads((rec_dir / "meta.json").read_text())
    tracker = MediaPipeTracker()
    n = meta["count"]
    detected = np.zeros(n, dtype=bool)
    vectors = np.zeros((n, FRAME_DIM), dtype=np.float32)
    translations = np.zeros((n, 3), dtype=np.float32)
    landmarks = np.zeros((n, 478, 3), dtype=np.float32)
    matrices = np.zeros((n, 4, 4), dtype=np.float64)
    try:
        for i, ts in enumerate(meta["timestamps_ms"]):
            img = cv2.imread(str(rec_dir / "frames" / f"{i:05d}.jpg"))
            res = tracker.process(img, ts)
            if res is None:
                continue
            detected[i] = True
            vectors[i] = res.frame.to_vector()
            translations[i] = res.frame.head_translation
            landmarks[i] = res.landmarks
            matrices[i] = res.matrix
    finally:
        tracker.close()

    out = rec_dir / "golden_mediapipe.npz"
    labels = meta.get("labels") or [None] * n
    np.savez_compressed(
        out, timestamps_ms=np.array(meta["timestamps_ms"]), detected=detected,
        labels=np.array([label or "" for label in labels]),
        vectors=vectors, head_translation=translations, landmarks=landmarks, matrices=matrices,
    )
    (rec_dir / "golden_mediapipe.json").write_text(json.dumps({
        "mediapipe": mp.__version__, "model_url": FACE_LANDMARKER_URL, "delegate": "CPU",
    }))
    print(f"{detected.sum()}/{n} frames with a face, wrote {out}")
    return out
