"""iFacialMocap output: tracking for VSeeFace, Warudo, VNyan, VMagicMirror and other receivers of the
iFacialMocap iPhone app.

Format (iFacialMocap developer page, v1/v2 text): one UDP datagram per frame,
  name-value|name-value|...|=head#rx,ry,rz,px,py,pz|rightEye#rx,ry,rz|leftEye#rx,ry,rz|
names are ARKit's with _L/_R for Left/Right (eyeBlink_L, mouthSmile_R, jawOpen), values 0 to 100,
angles in degrees. The phone app waits for a handshake from the receiver on 49983, but a receiver on
the same computer holds that port itself, so this sends straight to HOST:49983 like the bridges that
feed VSeeFace from a webcam tracker do.

Axis signs and the position unit are not documented and senders disagree (D16). ROTATION_SIGN keeps the
signs in one place, the command line can flip them; check against a real receiver.
"""

import math
import socket

from ..frame import ARKIT52, FaceFrame

PORT = 49983
ROTATION_SIGN = {"x": 1.0, "y": 1.0, "z": 1.0}
NAMES = [n.replace("Left", "_L").replace("Right", "_R") for n in ARKIT52]


class IFacialMocapSink:
    def __init__(self, host: str = "127.0.0.1", port: int = PORT, sign: dict[str, float] | None = None):
        self.addr = (host, port)
        self.sign = {**ROTATION_SIGN, **(sign or {})}
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        print(f"iFacialMocap: sending to {host}:{port}")

    def payload(self, frame: FaceFrame) -> str:
        shapes = "|".join(f"{n}-{int(round(max(0.0, min(1.0, float(v))) * 100))}"
                          for n, v in zip(NAMES, frame.blendshapes))
        yaw, pitch, roll = (math.degrees(float(a)) for a in frame.head_rotation)
        # rx is the nod, ry the turn, rz the tilt (rotation about the x, y and z axes)
        head = [self.sign["x"] * pitch, self.sign["y"] * yaw, self.sign["z"] * roll]
        pos = [float(v) * 100.0 for v in frame.head_translation]  # cm

        def eye(e):
            return f"{math.degrees(float(e[1])):.2f},{math.degrees(float(e[0])):.2f},0.00"
        nums = ",".join(f"{v:.2f}" for v in head + pos)
        return f"{shapes}|=head#{nums}|rightEye#{eye(frame.right_eye_rotation)}|leftEye#{eye(frame.left_eye_rotation)}|"

    def send(self, frame: FaceFrame | None, timestamp_ms: int) -> None:
        if frame is None:  # receivers keep the last pose, as when the phone loses the face
            return
        try:
            self.sock.sendto(self.payload(frame).encode(), self.addr)
        except OSError:
            pass

    def close(self) -> None:
        self.sock.close()
