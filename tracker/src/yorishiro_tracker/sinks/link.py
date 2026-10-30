"""Yorishiro link: one JSON datagram per frame to the Yorishiro app on localhost.

{"v": 1, "t": ms, "found": bool,
 "head": [yaw, pitch, roll] deg, "pos": [x, y, z] m, "eyes": {"left": [yaw, pitch], "right": [...]} deg,
 "arkit": {name: 0..1}, "vts": {VTS style input: value}}

Head, eyes and ARKit values are unmirrored (FaceFrame conventions). "vts" follows the mirror setting.
"""

import json
import math
import socket

from ..adapters.vts_params import vts_params
from ..frame import ARKIT52, FaceFrame

DEFAULT_PORT = 39570


class LinkSink:
    def __init__(self, host: str = "127.0.0.1", port: int = DEFAULT_PORT, mirror: bool = True):
        self.addr = (host, port)
        self.mirror = mirror
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def send(self, frame: FaceFrame | None, timestamp_ms: int) -> None:
        msg = {"v": 1, "t": timestamp_ms, "found": frame is not None}
        if frame is not None:
            deg = lambda a: [round(math.degrees(float(x)), 3) for x in a]  # noqa: E731
            msg.update(
                head=deg(frame.head_rotation),
                pos=[round(float(x), 4) for x in frame.head_translation],
                eyes={"left": deg(frame.left_eye_rotation[:2]), "right": deg(frame.right_eye_rotation[:2])},
                arkit={n: round(float(v), 4) for n, v in zip(ARKIT52, frame.blendshapes)},
                vts={k: round(v, 4) for k, v in vts_params(frame, self.mirror).items()},
            )
        try:
            self.sock.sendto(json.dumps(msg, separators=(",", ":")).encode(), self.addr)
        except OSError:
            pass  # nobody listening yet is normal

    def close(self) -> None:
        self.sock.close()
