"""MediaPipe hand tracking (palm_detection_full + hand_landmark_full, Apache-2.0) on ONNX Runtime CPU.

Like MediaPipe's hand landmarker: the palm detector runs only while fewer hands are tracked than wanted,
each tracked hand's next crop comes from its own landmarks. Models converted by tools/export_hands.py.
Landmarks are the 21 MediaPipe hand points in image pixels (z in the same scale, relative to the wrist).
"""

import math
from dataclasses import dataclass, field

import cv2
import numpy as np

from ..models import MODEL_DIR

PALM_INPUT = 192
LANDMARK_INPUT = 224
PALM_SCORE = 0.5
PRESENCE_SCORE = 0.5
NMS_IOU = 0.3
# MediaPipe hand landmarker crops: around the palm box, and around the previous landmarks
PALM_SCALE, PALM_SHIFT_Y = 2.6, -0.5
TRACK_SCALE, TRACK_SHIFT_Y = 2.0, -0.1
# landmarks the tracking crop is fitted to: wrist, thumb base, finger bases
CROP_POINTS = [0, 1, 2, 5, 9, 13, 17]

WRIST, MIDDLE_MCP = 0, 9
FINGERS = {  # base to tip
    "Thumb": (1, 2, 3, 4),
    "Index": (5, 6, 7, 8),
    "Middle": (9, 10, 11, 12),
    "Ring": (13, 14, 15, 16),
    "Pinky": (17, 18, 19, 20),
}


def _anchors() -> np.ndarray:
    """SSD anchors of palm_detection_full: strides 8, 16, 16, 16 at 192, fixed size, offset 0.5."""
    out = []
    for stride, per_cell in ((8, 2), (16, 6)):
        n = PALM_INPUT // stride
        ys, xs = np.mgrid[0:n, 0:n]
        centers = np.stack([(xs + 0.5) / n, (ys + 0.5) / n], axis=-1).reshape(-1, 2)
        out.append(np.repeat(centers, per_cell, axis=0))
    return np.concatenate(out).astype(np.float32)


ANCHORS = _anchors()
assert len(ANCHORS) == 2016


@dataclass
class Hand:
    landmarks: np.ndarray  # (21, 3) image pixels
    world: np.ndarray  # (21, 3) metres, around the hand's center
    right: bool  # the person's right hand
    score: float
    roi: tuple = field(default=None)  # (center, size, angle) the landmarks came from


def _sigmoid(x):
    return 1.0 / (1.0 + np.exp(-np.clip(x, -100, 100)))


def _iou(a, b):
    x0, y0 = max(a[0], b[0]), max(a[1], b[1])
    x1, y1 = min(a[2], b[2]), min(a[3], b[3])
    inter = max(0.0, x1 - x0) * max(0.0, y1 - y0)
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


def _crop(bgr, center, size, angle, out):
    """Rotated square crop (angle radians, counter-clockwise in the image) to out x out RGB in [0, 1],
    and the matrix from crop pixels back to image pixels."""
    c, s = math.cos(angle), math.sin(angle)
    half = size / 2
    # image points of the crop corners: top-left, top-right, bottom-left
    ux, uy = np.array([c, s]) * half, np.array([-s, c]) * half
    src = np.float32([center - ux - uy, center + ux - uy, center - ux + uy])
    dst = np.float32([[0, 0], [out, 0], [0, out]])
    m = cv2.getAffineTransform(src, dst)
    img = cv2.warpAffine(bgr, m, (out, out), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)
    back = cv2.getAffineTransform(dst, src)
    return cv2.cvtColor(img, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0, back


def _shift(center, size, angle, shift_y):
    """Move a crop along its own vertical axis (negative: towards the fingers), MediaPipe's RectTransformation."""
    return np.asarray(center) + np.array([-shift_y * size * math.sin(angle), shift_y * size * math.cos(angle)])


def _roi(points, scale, shift_y, rotation_from=(WRIST, MIDDLE_MCP)):
    """Square crop around points (pixels), rotated so the wrist-to-middle-finger line points up."""
    a, b = points[rotation_from[0]], points[rotation_from[1]]
    angle = math.atan2(b[1] - a[1], b[0] - a[0]) + math.pi / 2  # 0 when the hand points up
    c, s = math.cos(-angle), math.sin(-angle)
    rot = np.array([[c, -s], [s, c]])
    local = points[CROP_POINTS, :2] @ rot.T  # into the hand's upright frame
    lo, hi = local.min(0), local.max(0)
    size = float(max(hi - lo))
    center = ((lo + hi) / 2) @ np.linalg.inv(rot).T
    return _shift(center, size, angle, shift_y), size * scale, angle


class HandTracker:
    def __init__(self, max_hands: int = 2, model_dir=None):
        import onnxruntime as ort

        d = model_dir or MODEL_DIR / "mediapipe" / "hands"
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = 2
        self.palm = ort.InferenceSession(str(d / "palm_detection_full.onnx"), opts, providers=["CPUExecutionProvider"])
        self.landmark = ort.InferenceSession(str(d / "hand_landmark_full.onnx"), opts, providers=["CPUExecutionProvider"])
        self.palm_input = self.palm.get_inputs()[0].name
        self.landmark_input = self.landmark.get_inputs()[0].name
        self.max_hands = max_hands
        self.tracked: list[Hand] = []

    def reset(self):
        self.tracked = []

    def detect_palms(self, bgr):
        """[(center, size, angle)] crops for the hand landmark model, from the palm detector."""
        h, w = bgr.shape[:2]
        s = PALM_INPUT / max(h, w)
        nw, nh = round(w * s), round(h * s)
        px, py = (PALM_INPUT - nw) // 2, (PALM_INPUT - nh) // 2
        canvas = np.zeros((PALM_INPUT, PALM_INPUT, 3), np.uint8)
        canvas[py:py + nh, px:px + nw] = cv2.resize(bgr, (nw, nh), interpolation=cv2.INTER_AREA)
        x = cv2.cvtColor(canvas, cv2.COLOR_BGR2RGB).astype(np.float32)[None] / 255.0
        boxes, scores = self.palm.run(None, {self.palm_input: x})
        scores = _sigmoid(scores.reshape(-1))
        keep = np.nonzero(scores >= PALM_SCORE)[0]
        found = []
        for i in keep[np.argsort(-scores[keep])]:
            r = boxes.reshape(-1, 18)[i] / PALM_INPUT
            a = ANCHORS[i]
            cx, cy, bw, bh = r[0] + a[0], r[1] + a[1], r[2], r[3]
            box = (cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2)
            if any(_iou(box, f[0]) > NMS_IOU for f in found):
                continue
            kp = r[4:].reshape(7, 2) + a
            to_img = lambda v: (v * PALM_INPUT - (px, py)) / s
            found.append((box, to_img(np.array([cx, cy])), max(bw, bh) * PALM_INPUT / s, to_img(kp)))
        out = []
        for _, center, size, kp in found[: self.max_hands]:
            # rotation: wrist (0) to middle finger base (2) points up
            angle = math.atan2(kp[2][1] - kp[0][1], kp[2][0] - kp[0][0]) + math.pi / 2
            out.append((_shift(center, size, angle, PALM_SHIFT_Y), size * PALM_SCALE, angle))
        return out

    def landmarks(self, bgr, roi) -> Hand | None:
        center, size, angle = roi
        img, back = _crop(bgr, np.asarray(center, np.float64), size, angle, LANDMARK_INPUT)
        x = np.ascontiguousarray(img.transpose(2, 0, 1)[None])
        pts, presence, handedness, world = self.landmark.run(None, {self.landmark_input: x})
        score = float(presence.reshape(-1)[0])
        if score > 1.0 or score < 0.0:
            score = float(_sigmoid(score))
        if score < PRESENCE_SCORE:
            return None
        p = pts.reshape(21, 3)
        xy = np.c_[p[:, :2], np.ones(21)] @ back.T
        z = p[:, 2] * size / LANDMARK_INPUT
        right = float(handedness.reshape(-1)[0])
        if right > 1.0 or right < 0.0:
            right = float(_sigmoid(right))
        # checked on HaGRID palms against thumb geometry (tools/eval_hands.py): above 0.5 is the person's right hand
        return Hand(np.c_[xy, z], world.reshape(21, 3), right >= 0.5, score, roi)

    def process(self, bgr) -> list[Hand]:
        hands = []
        for prev in self.tracked:
            roi = _roi(prev.landmarks, TRACK_SCALE, TRACK_SHIFT_Y)
            hand = self.landmarks(bgr, roi)
            if hand is not None:
                hands.append(hand)
        if len(hands) < self.max_hands:
            for roi in self.detect_palms(bgr):
                # a palm where a tracked hand already is is that hand
                if any(np.linalg.norm(np.asarray(roi[0]) - h.landmarks[MIDDLE_MCP, :2]) < roi[1] * 0.25 for h in hands):
                    continue
                hand = self.landmarks(bgr, roi)
                if hand is not None:
                    hands.append(hand)
                if len(hands) >= self.max_hands:
                    break
        self.tracked = hands
        return hands


def finger_curl(hand: Hand) -> dict[str, float]:
    """0 straight to 1 fully bent per finger, from the angles between its bones (world coordinates)."""
    w = hand.world
    out = {}
    for name, (a, b, c, d) in FINGERS.items():
        base = w[WRIST] if name != "Thumb" else w[a]
        chain = [base, w[a], w[b], w[c], w[d]] if name != "Thumb" else [w[a], w[b], w[c], w[d]]
        bend = 0.0
        for i in range(len(chain) - 2):
            u, v = chain[i + 1] - chain[i], chain[i + 2] - chain[i + 1]
            cos = float(np.dot(u, v) / (np.linalg.norm(u) * np.linalg.norm(v) + 1e-9))
            bend += math.acos(max(-1.0, min(1.0, cos)))
        # straight is 0; a fist bends the three joints of a finger by about 250 degrees, a thumb about 120
        full = math.radians(120 if name == "Thumb" else 250)
        out[name] = max(0.0, min(1.0, bend / full))
    return out
