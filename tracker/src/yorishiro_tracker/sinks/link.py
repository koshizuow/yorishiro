"""Yorishiro link: datagrams between yorishiro-tracker and the Yorishiro app on localhost.

Tracker to app (port 39570), one JSON object per datagram:
  frame:   {"v": 1, "t": ms, "found": bool, "head": [yaw, pitch, roll] deg, "pos": [x, y, z] m,
            "eyes": {"left": [yaw, pitch], "right": [...]} deg, "arkit": {name: 0..1}, "vts": {input: value}}
  status:  {"v": 1, "type": "status", "state": "starting" | "running" | "error", "message": str, ...}
  preview: {"v": 1, "type": "preview", "jpeg": base64}
App to tracker (port 39571): {"cmd": "calibrate" | "preview", "on": bool} or {"cmd": "quit"}.

Head, eyes and ARKit values are unmirrored (FaceFrame conventions). "vts" follows the mirror setting.
"""

import base64
import json
import math
import socket

import cv2
import numpy as np

from ..adapters.vts_params import vts_params
from ..frame import ARKIT52, FaceFrame

DEFAULT_PORT = 39570
CONTROL_PORT = 39571
PREVIEW_WIDTH = 320


class LinkSink:
    def __init__(self, host: str = "127.0.0.1", port: int = DEFAULT_PORT, mirror: bool = True):
        self.addr = (host, port)
        self.mirror = mirror
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def _send(self, msg: dict) -> None:
        try:
            self.sock.sendto(json.dumps(msg, separators=(",", ":")).encode(), self.addr)
        except OSError:
            pass  # nobody listening yet is normal

    def send(self, frame: FaceFrame | None, timestamp_ms: int, hands: dict[str, float] | None = None,
             hand_points: dict[str, list] | None = None) -> None:
        msg = {"v": 1, "t": timestamp_ms, "found": frame is not None}
        if hands:
            # named by the person's hands; mirrored, the user's left hand moves the avatar's right one
            swap = (lambda k: k.replace("Left", "\0").replace("Right", "Left").replace("\0", "Right")) if self.mirror else (lambda k: k)
            msg["hands"] = {swap(k): round(v, 3) for k, v in hands.items()}
        if hand_points:
            # for the app's 3D preview: by the avatar's sides, flipped left to right like the face when mirrored
            flip = -1.0 if self.mirror else 1.0
            msg["hand_points"] = {("Left" if (side == "Left") != self.mirror else "Right"):
                                  [[round(p[0] * flip, 4), p[1], p[2]] for p in pts] for side, pts in hand_points.items()}
        if frame is not None:
            deg = lambda a: [round(math.degrees(float(x)), 3) for x in a]  # noqa: E731
            msg.update(
                head=deg(frame.head_rotation),
                pos=[round(float(x), 4) for x in frame.head_translation],
                eyes={"left": deg(frame.left_eye_rotation[:2]), "right": deg(frame.right_eye_rotation[:2])},
                arkit={n: round(float(v), 4) for n, v in zip(ARKIT52, frame.blendshapes)},
                vts={k: round(v, 4) for k, v in vts_params(frame, self.mirror).items()},
            )
            if frame.lens_glare is not None:
                msg["glare"] = [round(g, 3) for g in frame.lens_glare]
        self._send(msg)

    def status(self, state: str, message: str = "", **fields) -> None:
        self._send({"v": 1, "type": "status", "state": state, "message": message, **fields})

    def preview(self, bgr: np.ndarray, mirror: bool | None = None) -> None:
        h, w = bgr.shape[:2]
        small = cv2.resize(bgr, (PREVIEW_WIDTH, round(h * PREVIEW_WIDTH / w)), interpolation=cv2.INTER_AREA)
        if self.mirror if mirror is None else mirror:
            small = cv2.flip(small, 1)
        ok, jpg = cv2.imencode(".jpg", small, [cv2.IMWRITE_JPEG_QUALITY, 70])
        if ok:  # about 10 KB, well under one datagram
            self._send({"v": 1, "type": "preview", "jpeg": base64.b64encode(jpg.tobytes()).decode()})

    def close(self) -> None:
        self.sock.close()


class LinkControl:
    """Non-blocking receiver for commands from the app."""

    def __init__(self, host: str = "127.0.0.1", port: int = CONTROL_PORT):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind((host, port))  # no SO_REUSEADDR, so a second tracker fails loudly
        self.sock.setblocking(False)

    def poll(self) -> list[dict]:
        cmds = []
        while True:
            try:
                data, _ = self.sock.recvfrom(4096)
            except BlockingIOError:
                return cmds
            try:
                cmd = json.loads(data)
            except ValueError:
                continue
            if isinstance(cmd, dict):
                cmds.append(cmd)

    def close(self) -> None:
        self.sock.close()
