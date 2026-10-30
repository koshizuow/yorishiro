"""OpenSeeFace side of tools/run_trackers.py. Runs in OpenSeeFace's own pinned environment (Python 3.9,
numpy 1.21, onnxruntime 1.9, OpenCV 4.5), not in ours, so it is the stock tracker. Only numpy and cv2.

    <osf python> osf_worker.py OSF_DIR JOB.json OUT.npz

JOB.json: {"frames_dir", "width", "height", "sessions": [[frame indices], ...], "count"}.
"""

import json
import sys
import time

import cv2
import numpy as np

FEATURES = ("eye_l", "eye_r", "eyebrow_steepness_l", "eyebrow_steepness_r", "eyebrow_quirk_l",
            "eyebrow_quirk_r", "eyebrow_updown_l", "eyebrow_updown_r", "mouth_corner_updown_l",
            "mouth_corner_updown_r", "mouth_corner_inout_l", "mouth_corner_inout_r", "mouth_open",
            "mouth_wide")
NAMES = ("pitch", "yaw", "roll", "blink_l", "blink_r") + FEATURES


def main():
    osf_dir, job_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
    sys.path.insert(0, osf_dir)
    from tracker import Tracker

    job = json.load(open(job_path))
    n = job["count"]
    values = np.zeros((n, len(NAMES)), np.float32)
    detected = np.zeros(n, bool)
    ms = np.zeros(n, np.float32)
    cpu0 = time.process_time()
    for frames in job["sessions"]:
        # model 3 is OpenSeeFace's default and best landmark model, 4 threads like its CLI
        t = Tracker(job["width"], job["height"], model_type=3, max_threads=4, silent=True,
                    model_dir=osf_dir + "/models")
        for i in frames:
            img = cv2.imread("%s/%05d.jpg" % (job["frames_dir"], i))
            t0 = time.perf_counter()
            faces = t.predict(img)
            ms[i] = (time.perf_counter() - t0) * 1000
            if not faces or not faces[0].success or not faces[0].current_features:
                continue
            f = faces[0]
            e = f.euler
            # RQDecomp3x3 puts pitch around +-180, fold it to around 0. Signs stay OpenSeeFace's own
            pitch = (e[0] + 360) % 360 - 180
            feats = [f.current_features.get(k, 0.0) for k in FEATURES]
            values[i] = [pitch, e[1], e[2], 1 - f.eye_blink[1], 1 - f.eye_blink[0]] + feats
            detected[i] = True
    np.savez(out, names=np.array(NAMES), values=values, detected=detected, ms=ms,
             cpu_s=time.process_time() - cpu0)


if __name__ == "__main__":
    main()
