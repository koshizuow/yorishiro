"""Turn video clips into one recording (frames/%05d.jpg + meta.json), the format `record` writes, so
`golden`, `serve --replay` and tools/compare_runtimes.py work on outside footage.

    uv run python tools/video_to_recording.py OUT clip.flv [clip ...] [--label-from crema-d]

Each frame is labeled with its clip's name, or with the emotion code for CREMA-D file names
(1001_IEO_ANG_HI.flv -> ANG_HI). Timestamps follow the source frame rate, clip after clip.
"""

import argparse
import json
from pathlib import Path

import cv2


def label(path: Path, scheme: str) -> str:
    if scheme == "crema-d":
        return "_".join(path.stem.split("_")[2:])
    return path.stem


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", type=Path)
    ap.add_argument("clips", type=Path, nargs="+")
    ap.add_argument("--label-from", choices=["name", "crema-d"], default="name")
    a = ap.parse_args()
    frames = a.out / "frames"
    frames.mkdir(parents=True, exist_ok=False)
    stamps, labels, clips, size, t = [], [], [], None, 0.0
    for clip in a.clips:
        cap = cv2.VideoCapture(str(clip))
        step = 1000.0 / (cap.get(cv2.CAP_PROP_FPS) or 30.0)
        first = len(stamps)
        while True:
            ok, bgr = cap.read()
            if not ok:
                break
            size = [bgr.shape[1], bgr.shape[0]]
            cv2.imwrite(str(frames / f"{len(stamps):05d}.jpg"), bgr, [cv2.IMWRITE_JPEG_QUALITY, 95])
            stamps.append(round(t))
            labels.append(label(clip, a.label_from))
            t += step
        clips.append({"file": clip.name, "first": first, "count": len(stamps) - first})
    meta = {"count": len(stamps), "size": size, "timestamps_ms": stamps, "labels": labels, "clips": clips}
    (a.out / "meta.json").write_text(json.dumps(meta))
    print(f"{len(stamps)} frames from {len(clips)} clips -> {a.out}")


if __name__ == "__main__":
    main()
