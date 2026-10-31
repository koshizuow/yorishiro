"""Phase B1: data and golden outputs for the Rust core (core/ in the monorepo).

    uv run python tools/export_core.py [recording ...]

1. models/core/fit.npz: everything the landmark -> ARKit fit needs that is computed once from ICT-FaceKit and
   MediaPipe's canonical face (the correspondence, the solvers' matrices). The core reads it instead of
   redoing that setup, so it needs neither ICT-FaceKit nor Python.
2. testdata/core-golden/<recording>.npz: per frame of a recording's saved FaceMesh landmarks
   (eval/facemesh-vulkan.npz from tools/run_trackers.py), every stage of the geometric pipeline as the
   tracker runs it, minus the parts that look at the image or run a network (eye model, MediaPipe's mouth
   blendshapes, lens glare; B2): smoothed landmarks, aligned points, rotation, ARKit 52 from the fit and the
   gaze, head position, mouth gap, the frame after neutral calibration and smoothing, VTS inputs.
   The loop below is the reference the Rust port is held to.
"""

import sys
from dataclasses import replace
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from yorishiro_tracker.adapters import mediapipe_points as mpp  # noqa: E402
from yorishiro_tracker.adapters.landmark_smoother import LandmarkSmoother  # noqa: E402
from yorishiro_tracker.adapters.mediapipe_points import MediaPipePointFitter, head_position  # noqa: E402
from yorishiro_tracker.adapters.vts_params import mouth_gap, vts_params  # noqa: E402
from yorishiro_tracker.avatar.ict import ICT_SHAPES, IctHead, ensure_ict_facekit  # noqa: E402,F401
from yorishiro_tracker.frame import FaceFrame  # noqa: E402
from yorishiro_tracker.models import MODEL_DIR  # noqa: E402
from yorishiro_tracker.pose import eye_rotations_from_blendshapes, rotation_to_ypr, ypr_to_rotation  # noqa: E402
from yorishiro_tracker.processing import FrameSmoother, NeutralCalibration  # noqa: E402
from yorishiro_tracker.serve import CALIBRATE_FACES, SETTLE_FACES  # noqa: E402

TESTDATA = ROOT.parents[1] / "testdata"
VTS_KEYS = ("FaceAngleX", "FaceAngleY", "FaceAngleZ", "FacePositionX", "FacePositionY", "FacePositionZ",
            "EyeOpenLeft", "EyeOpenRight", "EyeLeftX", "EyeLeftY", "EyeRightX", "EyeRightY",
            "BrowLeftY", "BrowRightY", "MouthSmile", "MouthOpen", "MouthX", "Brows", "CheekPuff", "TongueOut")


def solver_arrays(prefix: str, solver) -> dict:
    return {f"{prefix}_a": solver.a, f"{prefix}_h": solver.h, f"{prefix}_step": np.float64(solver.step),
            f"{prefix}_active": solver.active.astype(np.int64)}


def export_fit(fitter: MediaPipePointFitter, out: Path) -> None:
    data = {
        "reference": fitter.reference,
        "src_idx": fitter.src_idx.astype(np.int64),
        "ict_idx": fitter.ict_idx.astype(np.int64),
        "arkit_of_shape": np.array(fitter.arkit_of_shape, np.int64),
        "n_shapes": np.int64(len(ICT_SHAPES)),
        "rigid": mpp.MP_RIGID.astype(np.int64),
        "flip_mirror": __import__("yorishiro_tracker.mediapipe_ncnn.landmarks", fromlist=["x"]).mirror_index(mpp.load_canonical()).astype(np.int64),
        **solver_arrays("main", fitter.solver),
    }
    for i, (rows, taken, solver) in enumerate(fitter.regions):
        data[f"region{i}_rows"] = rows.astype(np.int64)
        data[f"region{i}_taken"] = taken.astype(np.uint8)
        data.update(solver_arrays(f"region{i}", solver))
    data["n_regions"] = np.int64(len(fitter.regions))
    out.parent.mkdir(parents=True, exist_ok=True)
    # row-major everywhere: the core reads arrays in C order (the solver's matrix is a transpose)
    np.savez(out, **{k: np.ascontiguousarray(v) for k, v in data.items()})
    print(f"wrote {out} ({sum(v.nbytes for v in data.values()) / 1e6:.1f} MB)")


def fit_blendshapes(fitter, aligned):
    """The geometric part of the tracker's blendshapes: ICT fit (lid gap for blink and wide) plus iris gaze."""
    return fitter.expressions(aligned) + fitter.gaze(aligned)


def golden(rec: Path, head: IctHead, out: Path) -> None:
    run = np.load(rec / "eval" / "facemesh-vulkan.npz")
    meta = __import__("json").loads((rec / "meta.json").read_text())
    h, w = meta["size"]
    ts = np.asarray(meta["timestamps_ms"], np.int64)
    lms, det = run["landmarks"].astype(np.float64), run["detected"].astype(bool)
    fitter = MediaPipePointFitter(head)
    smoother = LandmarkSmoother()
    calibration, frame_smoother = NeutralCalibration(), FrameSmoother()
    n = len(lms)
    rec_out = {k: np.zeros(s) for k, s in (
        ("smoothed", (n, 478, 3)), ("aligned", (n, 478, 3)), ("rotation", (n, 3, 3)), ("bs", (n, 52)),
        ("head_ypr", (n, 3)), ("head_pos", (n, 3)), ("mouth_gap", (n,)), ("eyes", (n, 6)),
        ("final_bs", (n, 52)), ("final_head", (n, 3)), ("final_pos", (n, 3)), ("final_eyes", (n, 6)),
        ("vts", (n, len(VTS_KEYS))))}
    calibrated_at = []
    faces, window = 0, None
    for i in range(n):
        if not det[i]:
            smoother.reset()
            continue
        t = int(ts[i])
        smoothed = smoother(lms[i], t / 1000)
        aligned, rot = fitter.align(smoothed, w, h)
        if not fitter.calibrated:
            fitter.calibrate(aligned)
        bs = fit_blendshapes(fitter, aligned)
        le, re = eye_rotations_from_blendshapes(bs)
        frame = FaceFrame(timestamp_ms=t, blendshapes=bs, head_rotation=rotation_to_ypr(rot),
                          head_translation=head_position(smoothed, w, h, rot), left_eye_rotation=le,
                          right_eye_rotation=re, mouth_gap=mouth_gap(smoothed, w, h))
        for k, v in (("smoothed", smoothed), ("aligned", aligned), ("rotation", rot), ("bs", bs),
                     ("head_ypr", frame.head_rotation), ("head_pos", frame.head_translation),
                     ("mouth_gap", frame.mouth_gap), ("eyes", np.r_[le, re])):
            rec_out[k][i] = v
        # serve: the first face is a provisional neutral, a 24 frame window after 30 faces sets the real one
        faces += 1
        if faces == SETTLE_FACES:
            window = []
        if window is not None:
            window.append((aligned, frame))
            if len(window) == CALIBRATE_FACES:
                fitter.calibrate_many([a for a, _ in window])
                redone = []
                for a, f in window:  # the window's frames again against the new neutral, as calibrate_window does
                    a2, dr = fitter.realign(a)
                    b2 = fit_blendshapes(fitter, a2)
                    l2, r2 = eye_rotations_from_blendshapes(b2)
                    head = rotation_to_ypr(ypr_to_rotation(f.head_rotation) @ dr.T)
                    redone.append(replace(f, blendshapes=b2, head_rotation=head, left_eye_rotation=l2,
                                          right_eye_rotation=r2))
                calibration.set_many(redone)
                frame_smoother.reset()
                window = None
                calibrated_at.append(i)
        elif calibration.neutral is None:
            calibration.set(frame)
        final = frame_smoother(calibration(frame))
        p = vts_params(final)
        for k, v in (("final_bs", final.blendshapes), ("final_head", final.head_rotation),
                     ("final_pos", final.head_translation),
                     ("final_eyes", np.r_[final.left_eye_rotation, final.right_eye_rotation]),
                     ("vts", [p[k] for k in VTS_KEYS])):
            rec_out[k][i] = v
    out.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(out, landmarks=lms, detected=det.astype(np.uint8), timestamps_ms=ts,
                        size=np.array([w, h], np.int64), calibrated_at=np.array(calibrated_at, np.int64),
                        vts_keys=np.array(VTS_KEYS), **rec_out)
    print(f"wrote {out}: {n} frames, {int(det.sum())} faces, neutral window done at {calibrated_at}")


INFERENCE_FRAMES = 400
# the first frames also as OpenCV decoded them (PNG, lossless), so the Rust test sees the same pixels:
# JPEG decoders differ by a few grey levels, which the face networks amplify
PNG_FRAMES = 100


def golden_inference(rec: Path, out: Path, frames: int = INFERENCE_FRAMES) -> None:
    """The image side on ONNX Runtime CPU: detector letterbox and decode, landmark crop and ROI tracking
    (no flip averaging), MediaPipe's blendshape model, the eye model. Same steps as FaceMesh.process,
    with the detector on ORT instead of ncnn so both sides run the same files."""
    import cv2

    from yorishiro_tracker.adapters.eye_openness import MODEL as EYE_MODEL, crop_eyes
    from yorishiro_tracker.adapters.mediapipe_blendshapes import MediaPipeBlendshapes
    from yorishiro_tracker.backends.ort_backend import OrtCpuBackend
    from yorishiro_tracker.mediapipe_ncnn import detector as det
    from yorishiro_tracker.mediapipe_ncnn import landmarks as lmk
    from yorishiro_tracker.mediapipe_ncnn.facemesh import MP_DIR, PRESENCE_LOGIT

    detector = OrtCpuBackend(MP_DIR / "face_detector.onnx")
    landmarker = OrtCpuBackend(MP_DIR / "face_landmarks.onnx")
    blend = MediaPipeBlendshapes()
    eyes = OrtCpuBackend(EYE_MODEL)
    n = min(frames, len(list((rec / "frames").glob("*.jpg"))))
    res = {k: np.zeros(s) for k, s in (("roi", (n, 4)), ("detected", (n,)), ("landmarks", (n, 478, 3)),
                                        ("presence", (n,)), ("found", (n,)), ("mp_bs", (n, 52)),
                                        ("eye_open", (n, 2)), ("eye_crops", (n, 2, 40, 64, 3)))}
    roi = None
    png_dir = out.parent / f"{rec.name}-frames"
    png_dir.mkdir(parents=True, exist_ok=True)
    for i in range(n):
        bgr = cv2.imread(str(rec / "frames" / f"{i:05d}.jpg"))
        if i < PNG_FRAMES:
            cv2.imwrite(str(png_dir / f"{i:05d}.png"), bgr)
        h, w = bgr.shape[:2]
        for _ in range(2):
            if roi is None:
                x, sc, px, py = det.letterbox(bgr)
                o = detector.run({"in0": x})
                roi = det.decode_best(o["out0"], o["out1"], sc, px, py)
                res["detected"][i] = 1
                if roi is None:
                    break
            res["roi"][i] = [roi[0][0], roi[0][1], roi[1], roi[2]]
            m = lmk.roi_matrix(*roi)
            o = landmarker.run({"in0": lmk.preprocess(bgr, m)})
            res["presence"][i] = o["out1"].item()
            if o["out1"].item() > PRESENCE_LOGIT:
                lm = lmk.postprocess(o["out0"], m, w, h)
                roi = lmk.roi_from_landmarks(lm * (w, h, w))
                res["landmarks"][i], res["found"][i] = lm, 1
                res["mp_bs"][i] = blend(lm, w, h)
                crops = crop_eyes(bgr, lm)
                res["eye_crops"][i] = crops
                res["eye_open"][i] = eyes.run({"in0": crops.transpose(0, 3, 1, 2).astype(np.float32)})["out0"]
                break
            roi = None
    np.savez_compressed(out, **{k: v.astype(np.uint8) if k == "eye_crops" else v for k, v in res.items()})
    print(f"wrote {out}: {n} frames, {int(res['found'].sum())} faces, {int(res['detected'].sum())} detector runs")


def golden_full(rec: Path, head: IctHead, out: Path) -> None:
    """The whole tracker on the PNG frames, as FacemeshGpuTracker and serve run it: landmarks (ORT CPU, no
    flip averaging), smoothing, fit with the eye model's openness (the far eye takes the near one's when
    hidden), MediaPipe's model for mouth and jaw, gaze, lens glare, the neutral window, smoothing, VTS."""
    import cv2

    from yorishiro_tracker.adapters.eye_openness import EyeOpenness, eye_widths
    from yorishiro_tracker.adapters.lens_glare import lens_glare
    from yorishiro_tracker.adapters.mediapipe_blendshapes import MediaPipeBlendshapes, merge
    from yorishiro_tracker.backends.ort_backend import OrtCpuBackend
    from yorishiro_tracker.mediapipe_ncnn import detector as det
    from yorishiro_tracker.mediapipe_ncnn import landmarks as lmk
    from yorishiro_tracker.mediapipe_ncnn.facemesh import MP_DIR, PRESENCE_LOGIT
    from yorishiro_tracker.trackers.facemesh_gpu import HIDDEN_EYE_WIDTH, SIDES

    detector = OrtCpuBackend(MP_DIR / "face_detector.onnx")
    landmarker = OrtCpuBackend(MP_DIR / "face_landmarks.onnx")
    blend, eyes = MediaPipeBlendshapes(), EyeOpenness()
    fitter, smoother = MediaPipePointFitter(head), LandmarkSmoother()
    calibration, frame_smoother = NeutralCalibration(), FrameSmoother()
    frames_dir = out.parent / f"{rec.name}-frames"
    n = len(list(frames_dir.glob("*.png")))
    ts = __import__("json").loads((rec / "meta.json").read_text())["timestamps_ms"]
    res = {k: np.zeros(s) for k, s in (("found", (n,)), ("eye_open", (n, 2)), ("glare", (n, 2)), ("bs", (n, 52)),
                                        ("roi", (n, 4)), ("landmarks", (n, 478, 3)), ("detected", (n,)),
                                        ("final_bs", (n, 52)), ("final_head", (n, 3)), ("final_pos", (n, 3)),
                                        ("vts", (n, len(VTS_KEYS))))}
    roi, faces, window, calibrated_at = None, 0, None, []

    def blendshapes(smoothed, aligned, w, h, eye_open):
        return merge(fitter.expressions(aligned, eye_open), blend(smoothed, w, h)) + fitter.gaze(aligned)

    for i in range(n):
        bgr = cv2.imread(str(frames_dir / f"{i:05d}.png"))
        h, w = bgr.shape[:2]
        lm = None
        for _ in range(2):
            if roi is None:
                x, sc, px, py = det.letterbox(bgr)
                o = detector.run({"in0": x})
                roi = det.decode_best(o["out0"], o["out1"], sc, px, py)
                res["detected"][i] = 1
                if roi is None:
                    break
            res["roi"][i] = [roi[0][0], roi[0][1], roi[1], roi[2]]
            m = lmk.roi_matrix(*roi)
            o = landmarker.run({"in0": lmk.preprocess(bgr, m)})
            if o["out1"].item() > PRESENCE_LOGIT:
                lm = lmk.postprocess(o["out0"], m, w, h)
                roi = lmk.roi_from_landmarks(lm * (w, h, w))
                break
            roi = None
        if lm is None:
            smoother.reset()
            continue
        res["landmarks"][i] = lm
        t = int(ts[i])
        smoothed = smoother(lm, t / 1000)
        aligned, rot = fitter.align(smoothed, w, h)
        eye_open = eyes(bgr, smoothed)
        width = eye_widths(smoothed, w, h)
        for far, near in ((0, 1), (1, 0)):
            if width[far] < HIDDEN_EYE_WIDTH * width[near]:
                eye_open[far] = eye_open[near] * fitter.eye_neutral[SIDES[far]] / fitter.eye_neutral[SIDES[near]]
        if not fitter.calibrated:
            fitter.calibrate(aligned, eye_open)
        bs = blendshapes(smoothed, aligned, w, h, eye_open)
        le, re = eye_rotations_from_blendshapes(bs)
        glare = lens_glare(bgr, smoothed)
        frame = FaceFrame(timestamp_ms=t, blendshapes=bs, head_rotation=rotation_to_ypr(rot),
                          head_translation=head_position(smoothed, w, h, rot), left_eye_rotation=le,
                          right_eye_rotation=re, mouth_gap=mouth_gap(smoothed, w, h), lens_glare=glare)
        res["found"][i], res["eye_open"][i], res["glare"][i], res["bs"][i] = 1, eye_open, glare, bs
        faces += 1
        if faces == SETTLE_FACES:
            window = []
        if window is not None:
            window.append((smoothed, aligned, eye_open, frame))
            if len(window) == CALIBRATE_FACES:
                fitter.calibrate_many([a for _, a, _, _ in window], [e for _, _, e, _ in window])
                redone = []
                for sm, a, e, f in window:
                    a2, dr = fitter.realign(a)
                    b2 = blendshapes(sm, a2, w, h, e)
                    l2, r2 = eye_rotations_from_blendshapes(b2)
                    head_r = rotation_to_ypr(ypr_to_rotation(f.head_rotation) @ dr.T)
                    redone.append(replace(f, blendshapes=b2, head_rotation=head_r, left_eye_rotation=l2,
                                          right_eye_rotation=r2))
                calibration.set_many(redone)
                frame_smoother.reset()
                window = None
                calibrated_at.append(i)
        elif calibration.neutral is None:
            calibration.set(frame)
        final = frame_smoother(calibration(frame))
        p = vts_params(final)
        res["final_bs"][i], res["final_head"][i], res["final_pos"][i] = final.blendshapes, final.head_rotation, final.head_translation
        res["vts"][i] = [p[k] for k in VTS_KEYS]
    np.savez_compressed(out, timestamps_ms=np.array(ts[:n], np.int64), calibrated_at=np.array(calibrated_at, np.int64), **res)
    print(f"wrote {out}: {n} frames, {int(res['found'].sum())} faces, neutral window done at {calibrated_at}")


def golden_ncnn(rec: Path, out: Path) -> None:
    """The landmark model on ncnn (Vulkan fp16 and fp32, CPU) on the PNG frames at the ORT run's crops, for the
    Rust core's ncnn backend (same ncnn release, same GPU)."""
    import cv2

    from yorishiro_tracker.backends.factory import open_model
    from yorishiro_tracker.mediapipe_ncnn import landmarks as lmk
    from yorishiro_tracker.mediapipe_ncnn.facemesh import MP_DIR

    inf = np.load(out.parent / f"{rec.name}-inference.npz")
    frames = sorted((out.parent / f"{rec.name}-frames").glob("*.png"))
    res = {}
    for runtime in ("vulkan", "vulkan-fp32", "ncnn-cpu"):
        model = open_model(MP_DIR / "face_landmarks", runtime)
        lms = np.zeros((len(frames), 478, 3))
        for i, f in enumerate(frames):
            bgr = cv2.imread(str(f))
            h, w = bgr.shape[:2]
            r = inf["roi"][i]
            m = lmk.roi_matrix(np.array(r[:2]), r[2], r[3])
            lms[i] = lmk.postprocess(model.run({"in0": lmk.preprocess(bgr, m)})["out0"], m, w, h)
        res[runtime.replace("-", "_")] = lms
        print(f"  {runtime}: {model.name}")
    np.savez_compressed(out, **res)
    print(f"wrote {out}")


def golden_sinks(out: Path, frames: int = 20) -> None:
    """The outputs to other apps (VTS iPhone JSON, iFacialMocap text) on random frames, for the Rust sinks."""
    import json

    from yorishiro_tracker.sinks.ifacialmocap import IFacialMocapSink
    from yorishiro_tracker.sinks.vts_iphone import VtsIPhoneSink

    rng = np.random.default_rng(1)
    vts, ifm = VtsIPhoneSink(port=0), IFacialMocapSink()
    res = []
    for i in range(frames):
        bs = rng.random(52).astype(np.float32)
        bs[0], bs[1] = 0.125, 0.005  # values that round half way
        f = FaceFrame(timestamp_ms=i, blendshapes=bs, head_rotation=rng.normal(0, 0.3, 3).astype(np.float32),
                      head_translation=rng.normal(0, 0.05, 3).astype(np.float32),
                      left_eye_rotation=rng.normal(0, 0.2, 3).astype(np.float32),
                      right_eye_rotation=rng.normal(0, 0.2, 3).astype(np.float32))
        res.append({"bs": f.blendshapes.tolist(), "head": f.head_rotation.tolist(), "pos": f.head_translation.tolist(),
                    "le": f.left_eye_rotation.tolist(), "re": f.right_eye_rotation.tolist(),
                    "vts": vts.payload(f), "ifm": ifm.payload(f)})
    vts.close()
    ifm.close()
    out.write_text(json.dumps(res))
    print(f"wrote {out}")


def main():
    head = ensure_ict_facekit()
    export_fit(MediaPipePointFitter(head), MODEL_DIR / "core" / "fit.npz")
    golden_sinks(TESTDATA / "core-golden" / "sinks.json")
    recs = sys.argv[1:] or ["crema-d-60", "20261029-105439"]
    for r in recs:
        rec = Path(r) if "/" in r else TESTDATA / "recordings" / r
        golden(rec, head, TESTDATA / "core-golden" / f"{rec.name}.npz")
        golden_inference(rec, TESTDATA / "core-golden" / f"{rec.name}-inference.npz")
        golden_full(rec, head, TESTDATA / "core-golden" / f"{rec.name}-full.npz")
        golden_ncnn(rec, TESTDATA / "core-golden" / f"{rec.name}-ncnn.npz")


if __name__ == "__main__":
    main()
