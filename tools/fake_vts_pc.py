#!/usr/bin/env python3
"""fake_vts_pc.py HOST PORT FACE_ANGLE_X [SECONDS] : plays an iPhone running VTube Studio with "Connect to PC" on, for
testing the VTube Studio (Wi-Fi) input without a phone. Connects to TCP HOST:PORT (the port the copy of Yorishiro
listens on: 25565 for the first) and sends VTube Studio's frames at 60 fps: a 4 byte big-endian length, then JSON with
FaceAngleX (input 4) = FACE_ANGLE_X and MouthOpen (input 8) = 0.5. Retries the connection until SECONDS run out."""
import json, socket, struct, sys, time
HOST, PORT, ANGLE = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
SECONDS = float(sys.argv[4]) if len(sys.argv) > 4 else 20
body = json.dumps({"Timestamp": 0, "Hotkey": -1, "FaceFound": True,
                   "Data": [{"p": 4, "v": ANGLE}, {"p": 8, "v": 0.5}]}).encode()
frame = struct.pack(">I", len(body)) + body
end = time.time() + SECONDS
while time.time() < end:
    try:
        s = socket.create_connection((HOST, PORT), timeout=2)
    except OSError:
        time.sleep(0.5)
        continue
    print("connected to", PORT, flush=True)
    try:
        while time.time() < end:
            s.sendall(frame); time.sleep(1 / 60)
    except OSError:
        print("dropped", flush=True)
        continue
print("done", flush=True)
