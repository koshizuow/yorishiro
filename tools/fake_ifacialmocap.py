#!/usr/bin/env python3
"""fake_ifacialmocap.py [PORT] [SECONDS] : plays an iPhone running iFacialMocap, for testing the iFacialMocap input
without a phone. Waits on UDP PORT (default 49984; a real phone uses 49983, which the Yorishiro side holds on the same
computer) for the start message, then sends the app's text format to the sender's address, port 49983, at 60 fps:
jawOpen 40, eyeBlink_L 75, mouthSmile_R 10, head nod 10, turn -20, tilt 5 degrees, position 1,2,3 cm."""
import socket, sys, time
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 49984
SECONDS = float(sys.argv[2]) if len(sys.argv) > 2 else 20
START = b"iFacialMocap_sahuasouryya9218sauhuiayeta91555dy3719"
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", PORT)); s.settimeout(SECONDS)
msg, addr = s.recvfrom(1024)
assert msg == START, msg
print("start from", addr, flush=True)
shapes = {"jawOpen": 40, "eyeBlink_L": 75, "mouthSmile_R": 10, "eyeBlink_R": 0, "browInnerUp": 0}
line = "|".join("%s-%d" % kv for kv in shapes.items()) + "|=head#10.00,-20.00,5.00,1.00,2.00,3.00|rightEye#0.00,0.00,0.00|leftEye#0.00,0.00,0.00|"
end = time.time() + SECONDS
while time.time() < end:
    s.sendto(line.encode(), (addr[0], 49983)); time.sleep(1 / 60)
print("done", flush=True)
