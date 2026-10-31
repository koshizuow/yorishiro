import argparse
from datetime import datetime
from pathlib import Path

from .models import RECORDINGS_DIR


def _extra_sinks(args) -> list:
    """outputs for other apps next to the Yorishiro link"""
    extra = []
    if args.vts_iphone:
        from .sinks.vts_iphone import VtsIPhoneSink
        try:
            extra.append(VtsIPhoneSink(args.vts_iphone, args.vts_iphone_sign))
        except OSError as e:
            print(f"VTS iPhone protocol: port {args.vts_iphone} busy ({e}), not sending")
    if args.ifacialmocap:
        from .sinks.ifacialmocap import IFacialMocapSink
        extra.append(IFacialMocapSink(args.ifacialmocap, sign=args.ifacialmocap_sign))
    return extra


def _signs(text: str) -> dict[str, float]:
    x, y, z = (float(v) for v in text.split(","))
    return {"x": x, "y": y, "z": z}


def _size(text: str) -> tuple[int, int]:
    w, h = text.lower().split("x")
    return int(w), int(h)


def main() -> None:
    parser = argparse.ArgumentParser(prog="yorishiro-tracker")
    sub = parser.add_subparsers(dest="cmd", required=True)

    for name in ("preview", "record"):
        p = sub.add_parser(name)
        p.add_argument("--camera", type=int, default=0)
        p.add_argument("--size", type=_size, default=(1280, 720), help="WxH")
        p.add_argument("--no-avatar", dest="avatar", action="store_false",
                       help="skip the ICT-FaceKit head preview")
        p.add_argument("--tracker", default="mediapipe", help="tracker plugin, see `yorishiro-tracker trackers`")
        p.add_argument("--runtime", default=None,
                       help="inference runtime for trackers that support it: vulkan (default), "
                            "vulkan-fp32, ncnn-cpu, ort-cpu, cuda, tensorrt (NVIDIA), npu")
    sub.choices["record"].add_argument("--seconds", type=float, default=10.0)
    sub.choices["record"].add_argument("--out", type=Path, default=None)
    sub.choices["record"].add_argument(
        "--guided", action="store_true", help="on-screen motion script, labels every frame")
    sub.choices["preview"].add_argument("--link", action="store_true", help="also send to the Yorishiro app")

    s = sub.add_parser("serve", help="headless tracking that feeds the Yorishiro app")
    s.add_argument("--camera", type=int, default=0)
    s.add_argument("--size", type=_size, default=(1280, 720), help="WxH")
    s.add_argument("--tracker", default="facemesh")
    s.add_argument("--runtime", default=None)
    s.add_argument("--replay", type=Path, default=None, help="use a recording instead of the camera")
    s.add_argument("--loop", action="store_true", help="repeat the recording")
    s.add_argument("--no-smoothing", dest="smoothing", action="store_false")

    t = sub.add_parser("send-test", help="send a fixed synthetic frame, for checking directions in the app")
    t.add_argument("--seconds", type=float, default=10.0)
    for angle in ("yaw", "pitch", "roll", "eye-yaw", "eye-pitch"):
        t.add_argument(f"--{angle}", type=float, default=0.0, help="degrees, FaceFrame convention")
    t.add_argument("--bs", nargs="*", default=[], metavar="NAME=VALUE", help="ARKit blendshapes")

    for p in (s, t):
        p.add_argument("--port", type=int, default=39570)
        p.add_argument("--no-mirror", dest="mirror", action="store_false")
    s.add_argument("--control-port", type=int, default=39571, help="commands from the app, 0 to disable")
    s.add_argument("--parent-pid", type=int, default=None, help="exit when this process is gone")
    for p in (s, t):
        p.add_argument("--vts-iphone", type=int, nargs="?", const=21412, default=None, metavar="PORT",
                       help="also act as an iPhone running VTube Studio (VTube Studio, OpenVT), requests on PORT")
        p.add_argument("--vts-iphone-sign", type=_signs, default=None, metavar="X,Y,Z",
                       help="flip head rotation axes for that output, e.g. -1,1,1")
        p.add_argument("--ifacialmocap", nargs="?", const="127.0.0.1", default=None, metavar="HOST",
                       help="also send iFacialMocap (VSeeFace, Warudo, VNyan) to HOST:49983")
        p.add_argument("--ifacialmocap-sign", type=_signs, default=None, metavar="X,Y,Z",
                       help="flip head rotation axes for that output (x nod, y turn, z tilt)")

    g = sub.add_parser("golden", help="replay a recording through the MediaPipe reference")
    g.add_argument("recording", type=Path)
    tr = sub.add_parser("trackers", help="list available tracker plugins")
    tr.add_argument("--json", action="store_true", help="machine readable, for the app")

    args = parser.parse_args()
    if args.cmd == "trackers":
        from .registry import available_trackers, describe_trackers
        if args.json:
            import json
            print(json.dumps(describe_trackers()))
            return
        for name, target in sorted(available_trackers().items()):
            print(f"{name:16s} {target}")
        return
    if args.cmd == "send-test":
        from .serve import parse_blendshapes, run_send_test
        from .sinks.link import LinkSink
        run_send_test(LinkSink(port=args.port, mirror=args.mirror), args.seconds, extra_sinks=_extra_sinks(args),
                      yaw=args.yaw, pitch=args.pitch, roll=args.roll, eye_yaw=args.eye_yaw,
                      eye_pitch=args.eye_pitch, blendshapes=parse_blendshapes(args.bs))
        return
    import cv2
    cv2.setNumThreads(1)  # its worker pool spins after tiny warps and burns ~10 ms CPU per frame
    if args.cmd == "serve":
        from .serve import run_serve
        from .sinks.link import LinkControl, LinkSink
        sink = LinkSink(port=args.port, mirror=args.mirror)
        try:
            control = LinkControl(port=args.control_port) if args.control_port else None
        except OSError as e:
            sink.status("error", f"control port {args.control_port} busy, is another tracker running? ({e})")
            raise SystemExit(2)
        extra = _extra_sinks(args)
        raise SystemExit(run_serve(args.tracker, args.runtime, sink, args.camera, args.size, args.replay,
                                   args.loop, args.smoothing, control, args.parent_pid, extra))
    from . import app

    if args.cmd == "preview":
        app.run_preview(args.camera, *args.size, avatar=args.avatar, tracker_name=args.tracker,
                        runtime=args.runtime, link=args.link)
    elif args.cmd == "record":
        out = args.out or RECORDINGS_DIR / datetime.now().strftime("%Y%m%d-%H%M%S")
        app.run_preview(args.camera, *args.size, record_dir=out, seconds=args.seconds,
                        guided=args.guided, avatar=args.avatar, tracker_name=args.tracker,
                        runtime=args.runtime)
    elif args.cmd == "golden":
        app.run_golden(args.recording)
