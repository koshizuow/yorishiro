import argparse
from datetime import datetime
from pathlib import Path

from .models import PROJECT_ROOT


def _size(text: str) -> tuple[int, int]:
    w, h = text.lower().split("x")
    return int(w), int(h)


def main() -> None:
    parser = argparse.ArgumentParser(prog="facecap")
    sub = parser.add_subparsers(dest="cmd", required=True)

    for name in ("preview", "record"):
        p = sub.add_parser(name)
        p.add_argument("--camera", type=int, default=0)
        p.add_argument("--size", type=_size, default=(1280, 720), help="WxH")
        p.add_argument("--no-avatar", dest="avatar", action="store_false",
                       help="skip the ICT-FaceKit head preview")
        p.add_argument("--tracker", default="mediapipe", help="tracker plugin, see `facecap trackers`")
    sub.choices["record"].add_argument("--seconds", type=float, default=10.0)
    sub.choices["record"].add_argument("--out", type=Path, default=None)
    sub.choices["record"].add_argument(
        "--guided", action="store_true", help="on-screen motion script, labels every frame")

    g = sub.add_parser("golden", help="replay a recording through the MediaPipe reference")
    g.add_argument("recording", type=Path)
    sub.add_parser("trackers", help="list available tracker plugins")

    args = parser.parse_args()
    if args.cmd == "trackers":
        from .registry import available_trackers
        for name, target in sorted(available_trackers().items()):
            print(f"{name:16s} {target}")
        return
    import cv2
    cv2.setNumThreads(1)  # its worker pool spins after tiny warps and burns ~10 ms CPU per frame
    from . import app

    if args.cmd == "preview":
        app.run_preview(args.camera, *args.size, avatar=args.avatar, tracker_name=args.tracker)
    elif args.cmd == "record":
        out = args.out or PROJECT_ROOT / "data" / "recordings" / datetime.now().strftime("%Y%m%d-%H%M%S")
        app.run_preview(args.camera, *args.size, record_dir=out, seconds=args.seconds,
                        guided=args.guided, avatar=args.avatar, tracker_name=args.tracker)
    elif args.cmd == "golden":
        app.run_golden(args.recording)
