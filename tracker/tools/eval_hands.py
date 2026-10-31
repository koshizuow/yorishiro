"""Hand tracking check on HaGRID pictures (evaluation only, D8): our ONNX pipeline against MediaPipe's own
HandLandmarker as the judge, and finger bend against the gesture each picture shows.

    uv run python tools/eval_hands.py [--per-gesture 40] [--hagrid DIR]

Prints per gesture: hands found by both, landmark distance to MediaPipe's (in palm lengths), handedness
agreement, and how often each finger is straight or bent as the gesture says.
"""

import argparse
import json
import random
import sys
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from yorishiro_tracker.mediapipe_ncnn.hands import FINGERS, MIDDLE_MCP, WRIST, HandTracker, finger_curl  # noqa: E402
from yorishiro_tracker.models import ensure_hand_landmarker  # noqa: E402

HAGRID = Path(__file__).resolve().parents[3] / "testdata/external/hagrid/hagrid-sample-30k-384p"
# straight fingers of each gesture (the others are bent); gestures with an unclear thumb leave it out
STRAIGHT = {
    "fist": {"Index": 0, "Middle": 0, "Ring": 0, "Pinky": 0},
    "palm": {"Thumb": 1, "Index": 1, "Middle": 1, "Ring": 1, "Pinky": 1},
    "one": {"Index": 1, "Middle": 0, "Ring": 0, "Pinky": 0},
    "peace": {"Index": 1, "Middle": 1, "Ring": 0, "Pinky": 0},
    "like": {"Thumb": 1, "Index": 0, "Middle": 0, "Ring": 0, "Pinky": 0},
    "call": {"Thumb": 1, "Index": 0, "Middle": 0, "Ring": 0, "Pinky": 1},
    "four": {"Index": 1, "Middle": 1, "Ring": 1, "Pinky": 1},
    "rock": {"Index": 1, "Middle": 0, "Ring": 0, "Pinky": 1},
}
STRAIGHT_BELOW, BENT_ABOVE = 0.35, 0.5


def reference():
    import mediapipe as mp
    from mediapipe.tasks.python import vision
    from mediapipe.tasks.python.core.base_options import BaseOptions

    opts = vision.HandLandmarkerOptions(base_options=BaseOptions(model_asset_path=str(ensure_hand_landmarker())),
                                        num_hands=2, running_mode=vision.RunningMode.IMAGE)
    lm = vision.HandLandmarker.create_from_options(opts)

    def run(bgr):
        h, w = bgr.shape[:2]
        img = mp.Image(image_format=mp.ImageFormat.SRGB, data=cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB))
        r = lm.detect(img)
        out = []
        for pts, hd in zip(r.hand_landmarks, r.handedness):
            xy = np.array([[p.x * w, p.y * h] for p in pts])
            # on camera (not mirrored) pictures "Right" is the person's right hand, as the HaGRID labels say
            out.append((xy, hd[0].category_name == "Right"))
        return out
    return run


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--per-gesture", type=int, default=40)
    ap.add_argument("--hagrid", type=Path, default=HAGRID)
    ap.add_argument("--runtime", default="ort-cpu", help="vulkan, vulkan-fp32, ncnn-cpu, ort-cpu, cuda, tensorrt")
    args = ap.parse_args()
    ours = HandTracker(max_hands=2, runtime=args.runtime)
    print(f"runtime {ours.runtime}")
    judge = reference()
    rng = random.Random(0)
    total = {"found": 0, "both": 0, "judge": 0, "err": [], "hand_ok": 0, "finger_ok": 0, "finger_n": 0}
    for gesture, want in STRAIGHT.items():
        ann = json.load(open(args.hagrid / "ann_train_val" / f"{gesture}.json"))
        files = sorted((args.hagrid / "hagrid_30k" / f"train_val_{gesture}").glob("*.jpg"))
        rng.shuffle(files)
        g = {"n": 0, "found": 0, "both": 0, "err": [], "hand_ok": 0, "finger_ok": 0, "finger_n": 0}
        for f in files[: args.per_gesture]:
            a = ann.get(f.stem)
            if not a or gesture not in a["labels"]:
                continue
            bgr = cv2.imread(str(f))
            h, w = bgr.shape[:2]
            box = a["bboxes"][a["labels"].index(gesture)]
            gx, gy = (box[0] + box[2] / 2) * w, (box[1] + box[3] / 2) * h
            g["n"] += 1
            ours.reset()
            mine = ours.process(bgr)
            theirs = judge(bgr)
            # the gesture hand: the one nearest the labelled box
            pick = lambda hands, xy: min(hands, key=lambda x: np.linalg.norm(xy(x).mean(0) - (gx, gy)), default=None)
            m = pick(mine, lambda x: x.landmarks[:, :2])
            t = pick(theirs, lambda x: x[0])
            if m is not None and np.linalg.norm(m.landmarks[:, :2].mean(0) - (gx, gy)) < max(box[2] * w, box[3] * h):
                g["found"] += 1
                curl = finger_curl(m)
                for name, straight in want.items():
                    g["finger_n"] += 1
                    if (straight and curl[name] < STRAIGHT_BELOW) or (not straight and curl[name] > BENT_ABOVE):
                        g["finger_ok"] += 1
                if t is not None:
                    g["both"] += 1
                    palm = np.linalg.norm(t[0][MIDDLE_MCP] - t[0][WRIST])
                    g["err"].append(float(np.linalg.norm(m.landmarks[:, :2] - t[0], axis=1).mean() / max(palm, 1e-6)))
                    g["hand_ok"] += int(m.right == t[1])
                if a.get("leading_conf", 0) >= 0.8:
                    g["label_n"] = g.get("label_n", 0) + 1
                    g["label_ok"] = g.get("label_ok", 0) + int(m.right == (a["leading_hand"] == "right"))
            if t is not None:
                total["judge"] += 1
        err = np.median(g["err"]) if g["err"] else float("nan")
        print(f"{gesture:6s} {g['n']:3d} pictures: found {g['found']:3d}, with MediaPipe {g['both']:3d}, "
              f"landmark error {err:.3f} palm, same hand {g['hand_ok']}/{g['both']}, "
              f"fingers as the gesture {g['finger_ok']}/{g['finger_n']}, hand as labelled {g.get('label_ok', 0)}/{g.get('label_n', 0)}")
        for k in ("found", "both", "hand_ok", "finger_ok", "finger_n", "label_ok", "label_n"):
            total[k] = total.get(k, 0) + g.get(k, 0)
        total["err"] += g["err"]
    n = len(STRAIGHT) * args.per_gesture
    print(f"all: found {total['found']}/{n} (MediaPipe {total['judge']}), median landmark error "
          f"{np.median(total['err']):.3f} palm, same hand {total['hand_ok']}/{total['both']}, "
          f"fingers {total['finger_ok']}/{total['finger_n']} ({100 * total['finger_ok'] / max(total['finger_n'], 1):.1f} %), "
          f"hand as labelled {total['label_ok']}/{total['label_n']}")


if __name__ == "__main__":
    main()
