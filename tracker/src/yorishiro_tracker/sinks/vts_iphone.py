"""VTube Studio iPhone protocol: tracking for apps that take an iPhone running VTube Studio as a source
(VTube Studio on the PC, OpenVT, the Yorishiro app's "iOS BlendShapes (VTS)" input).

Format from DenchiSoft/VTubeStudioBlendshapeUDPReceiverTest (MIT, VTubeStudioRawTrackingData.cs):
a receiver sends {"messageType": "iOSTrackingDataRequest", "time": seconds (0.5 to 10), "sentBy": name,
"ports": [up to 32 ports]} to UDP 21412 and repeats it every few seconds. The sender then streams one JSON
object per frame to each listed port of the requesting address until the time runs out:
  {"Timestamp": unix ms, "Hotkey": -1, "FaceFound": bool, "Rotation": {"x","y","z"}, "Position": {...},
   "EyeLeft": {...}, "EyeRight": {...}, "BlendShapes": [{"k": "EyeBlinkLeft", "v": 0..1}, ...]}
Blendshape names are ARKit's with a capital first letter. Rotation x is the head turn, y the nod, z the
tilt, in degrees (the reference example rotates a cube by Euler(-y, -x, z)). Values are unmirrored like a
phone's raw data, the receiver applies its own mirror setting.

The signs of the rotation axes are not documented; ROTATION_SIGN keeps them in one place and the
command line can flip them (D16: verify against a real receiver).
"""

import json
import math
import socket
import time

from ..frame import ARKIT52, FaceFrame

REQUEST_PORT = 21412
MAX_SECONDS = 10.0
ROTATION_SIGN = {"x": 1.0, "y": 1.0, "z": 1.0}
NAMES = [n[0].upper() + n[1:] for n in ARKIT52]


class VtsIPhoneSink:
    def __init__(self, port: int = REQUEST_PORT, sign: dict[str, float] | None = None):
        self.sign = {**ROTATION_SIGN, **(sign or {})}
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("0.0.0.0", port))
        self.sock.setblocking(False)
        self.clients: dict[tuple[str, int], float] = {}  # (host, port) -> monotonic expiry

    def _poll_requests(self) -> None:
        while True:
            try:
                data, (host, _) = self.sock.recvfrom(4096)
            except (BlockingIOError, OSError):
                return
            try:
                msg = json.loads(data.decode("utf-8", "replace"))
            except ValueError:
                continue
            if not isinstance(msg, dict) or msg.get("messageType") != "iOSTrackingDataRequest":
                continue
            # the reference names the field "time", OpenVT sends "sendForSeconds"
            seconds = msg.get("time", msg.get("sendForSeconds", MAX_SECONDS))
            try:
                seconds = min(max(float(seconds), 0.5), MAX_SECONDS)
            except (TypeError, ValueError):
                seconds = MAX_SECONDS
            for port in list(msg.get("ports", []))[:32]:
                if isinstance(port, int) and 0 < port < 65536:
                    if (host, port) not in self.clients:
                        print(f"VTS iPhone protocol: sending to {host}:{port} ({msg.get('sentBy', '?')})")
                    self.clients[(host, port)] = time.monotonic() + seconds

    def payload(self, frame: FaceFrame | None) -> dict:
        msg = {"Timestamp": int(time.time() * 1000), "Hotkey": -1, "FaceFound": frame is not None}
        if frame is None:
            return msg
        deg = [math.degrees(float(a)) for a in frame.head_rotation]  # yaw, pitch, roll

        def vec(x, y, z):
            return {"x": round(x, 3), "y": round(y, 3), "z": round(z, 3)}
        msg["Rotation"] = vec(self.sign["x"] * deg[0], self.sign["y"] * deg[1], self.sign["z"] * deg[2])
        t = [float(v) * 100.0 for v in frame.head_translation]  # cm
        msg["Position"] = vec(*t)
        for key, eye in (("EyeLeft", frame.left_eye_rotation), ("EyeRight", frame.right_eye_rotation)):
            msg[key] = vec(math.degrees(float(eye[1])), math.degrees(float(eye[0])), 0.0)
        msg["BlendShapes"] = [{"k": n, "v": round(float(v), 4)} for n, v in zip(NAMES, frame.blendshapes)]
        return msg

    def send(self, frame: FaceFrame | None, timestamp_ms: int) -> None:
        self._poll_requests()
        if not self.clients:
            return
        now = time.monotonic()
        self.clients = {c: t for c, t in self.clients.items() if t > now}
        data = json.dumps(self.payload(frame), separators=(",", ":")).encode()
        for client in self.clients:
            try:
                self.sock.sendto(data, client)
            except OSError:
                pass

    def close(self) -> None:
        self.sock.close()
