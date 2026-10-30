import math

import cv2
import numpy as np

from .frame import ARKIT52, FaceFrame

FONT = cv2.FONT_HERSHEY_SIMPLEX
IRIS_START = 468


def draw_landmarks(img: np.ndarray, landmarks: np.ndarray) -> None:
    h, w = img.shape[:2]
    pts = (landmarks[:, :2] * (w, h)).astype(np.int32)
    for i, (x, y) in enumerate(pts):
        color = (0, 200, 255) if i >= IRIS_START else (80, 255, 80)
        cv2.circle(img, (int(x), int(y)), 1, color, -1, cv2.LINE_AA)


def blendshape_panel(bs: np.ndarray | None, height: int, width: int = 460,
                     covered: set[str] | None = None) -> np.ndarray:
    """Bars in orange come from the active model, grey ones are fallbacks or not estimated."""
    panel = np.full((height, width, 3), 24, dtype=np.uint8)
    rows = math.ceil(len(ARKIT52) / 2)
    row_h = height / (rows + 1)
    col_w = width // 2
    name_w, bar_w = 120, col_w - 130
    for i, name in enumerate(ARKIT52):
        col, row = divmod(i, rows)
        x0 = col * col_w + 4
        y = int((row + 1) * row_h)
        v = 0.0 if bs is None else float(bs[i])
        own = covered is None or name in covered
        cv2.putText(panel, name, (x0, y), FONT, 0.33, (200, 200, 200) if own else (110, 110, 110), 1, cv2.LINE_AA)
        bx = x0 + name_w
        cv2.rectangle(panel, (bx, y - 8), (bx + bar_w, y), (60, 60, 60), -1)
        cv2.rectangle(panel, (bx, y - 8), (bx + int(bar_w * v), y), (80, 200, 255) if own else (150, 150, 150), -1)
    return panel


def draw_hud(img: np.ndarray, lines: list[str]) -> None:
    for i, text in enumerate(lines):
        y = 24 + i * 22
        cv2.putText(img, text, (10, y), FONT, 0.6, (0, 0, 0), 3, cv2.LINE_AA)
        cv2.putText(img, text, (10, y), FONT, 0.6, (255, 255, 255), 1, cv2.LINE_AA)


def draw_banner(img: np.ndarray, text: str) -> None:
    h, w = img.shape[:2]
    (tw, th), _ = cv2.getTextSize(text, FONT, 1.0, 2)
    x, y = (w - tw) // 2, h - 30
    cv2.rectangle(img, (x - 12, y - th - 12), (x + tw + 12, y + 12), (0, 0, 0), -1)
    cv2.putText(img, text, (x, y), FONT, 1.0, (0, 230, 255), 2, cv2.LINE_AA)


def pose_lines(frame: FaceFrame | None) -> list[str]:
    if frame is None:
        return ["no face"]
    y, p, r = np.degrees(frame.head_rotation)
    t = frame.head_translation * 100.0
    ly, lp, _ = np.degrees(frame.left_eye_rotation)
    ry, rp, _ = np.degrees(frame.right_eye_rotation)
    return [
        f"head yaw {y:+6.1f}  pitch {p:+6.1f}  roll {r:+6.1f} deg",
        f"head pos x {t[0]:+5.1f}  y {t[1]:+5.1f}  z {t[2]:+6.1f} cm",
        f"eyeL yaw {ly:+5.1f} pitch {lp:+5.1f}  eyeR yaw {ry:+5.1f} pitch {rp:+5.1f}",
    ]
