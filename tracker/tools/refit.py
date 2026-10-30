"""Re-run only the landmark -> ARKit step on landmarks saved by tools/run_trackers.py, to try solver changes.

    uv run python tools/refit.py data/recordings/<rec> [--src facemesh-tensorrt] [--tag fit-new]
    uv run python tools/refit.py data/recordings/crema-d-60 --explain ANG,HAP

Writes <rec>/eval/experiments/<tag>.npz (head pose and gaze copied from the source run, expressions refitted with the
current MediaPipePointFitter), for tools/fit_scorecard.py.
--explain prints, per CREMA-D emotion, the ARKit shapes that rise most over each actor's neutral clip.
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_trackers import sessions  # noqa: E402

from yorishiro_tracker.adapters import mediapipe_points  # noqa: E402
from yorishiro_tracker.adapters.mediapipe_blendshapes import MediaPipeBlendshapes, merge  # noqa: E402
from yorishiro_tracker.adapters.mediapipe_points import MediaPipePointFitter  # noqa: E402
from yorishiro_tracker.avatar.ict import ensure_ict_facekit  # noqa: E402
from yorishiro_tracker.frame import ARKIT52  # noqa: E402
from yorishiro_tracker.serve import CALIBRATE_FACES, SETTLE_FACES  # noqa: E402


def joint_expressions(fitter, aligned: np.ndarray, rounds: int) -> np.ndarray:
    """Alternate expression solve and rigid re-alignment on all corresponded points: the expression model
    explains cheek and lip motion first, so it no longer tilts or shifts the head estimate."""
    from yorishiro_tracker.adapters.ict_fit import apply
    bs = fitter.expressions(aligned)
    idx = fitter.src_idx
    for _ in range(rounds):
        sv = fitter.solver
        target = fitter.reference[idx] + (sv.a @ sv.w).reshape(-1, 3)
        weights = None
        if ROBUST_C:
            # points the expression model cannot explain (lip seal, eyelid folds, noise) must not steer the head
            res = np.linalg.norm(aligned[idx] - target, axis=1)
            weights = 1.0 / (1.0 + (res / ROBUST_C) ** 2)
        s, r, t = weighted_similarity(aligned[idx], target, weights)
        aligned = apply(s, r, t, aligned)
        bs = fitter.expressions(aligned)
    return bs, aligned


def weighted_similarity(src, dst, w=None):
    """Umeyama with per-point weights."""
    w = np.ones(len(src)) if w is None else w
    w = w / w.sum()
    mu_s, mu_d = w @ src, w @ dst
    xs, xd = src - mu_s, dst - mu_d
    u, sig, vt = np.linalg.svd((xd * w[:, None]).T @ xs)
    d = np.eye(3)
    d[2, 2] = np.sign(np.linalg.det(u @ vt))
    r = u @ d @ vt
    s = float(np.trace(np.diag(sig) @ d) / (w @ (xs ** 2).sum(1)))
    return s, r, mu_d - s * r @ mu_s


ROBUST_C = 0.0


JOINT_ROUNDS = 0
CALIB = "first"
MP_MOUTH = True  # as FaceMeshGpuTracker: mouth and jaw from MediaPipe's blendshape model


def refit(rec: Path, src: str) -> tuple[np.ndarray, dict]:
    meta = json.loads((rec / "meta.json").read_text())
    d = np.load(rec / "eval" / f"{src}.npz")
    lms, det = d["landmarks"].astype(np.float64), d["detected"]
    values = d["values"].copy()
    w, h = meta["size"]
    head = ensure_ict_facekit()
    mp = MediaPipeBlendshapes() if MP_MOUTH else None
    for frames in sessions(meta):
        fitter = MediaPipePointFitter(head)
        faces, window = 0, None
        for i in frames:
            if not det[i]:
                continue
            aligned, _ = fitter.align(lms[i], w, h)
            if not fitter.calibrated:
                fitter.calibrate(aligned)
            # the same neutral steps as serve: provisional first face, then at SETTLE_FACES one frame
            # (single) or the median of CALIBRATE_FACES frames (window)
            faces += 1
            if CALIB == "single" and faces == SETTLE_FACES:
                fitter.calibrate(aligned)
            elif CALIB == "window":
                if faces == SETTLE_FACES:
                    window = []
                if window is not None:
                    window.append(aligned)
                    if len(window) == CALIBRATE_FACES:
                        fitter.calibrate_many(window)
                        window = None
                        aligned, _ = fitter.realign(aligned)
            if JOINT_ROUNDS:
                bs, aligned = joint_expressions(fitter, aligned, JOINT_ROUNDS)
            else:
                bs = fitter.expressions(aligned)
            if mp is not None:
                bs = merge(bs, mp(lms[i], w, h))
            values[i, :52] = bs + fitter.gaze(aligned)
    return values, {k: d[k] for k in d.files if k != "values"}


def explain(rec: Path, values: np.ndarray, det: np.ndarray, emotions: list[str]):
    meta = json.loads((rec / "meta.json").read_text())
    clips = meta["clips"]
    for emo in emotions:
        rises = []
        for c in clips:
            actor, _, e = c["file"].split(".")[0].split("_")[:3]
            if e != emo:
                continue
            neu = next(n for n in clips if n["file"].startswith(actor + "_") and "_NEU_" in n["file"])
            ei = np.arange(c["first"], c["first"] + c["count"])
            ni = np.arange(neu["first"], neu["first"] + neu["count"])
            rises.append(values[ei[det[ei]], :52].mean(0) - values[ni[det[ni]], :52].mean(0))
        r = np.mean(rises, axis=0)
        top = np.argsort(-np.abs(r))[:10]
        print(f"{emo}: " + ", ".join(f"{ARKIT52[k]} {r[k]:+.3f}" for k in top))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rec", type=Path)
    ap.add_argument("--src", default="facemesh-tensorrt")
    ap.add_argument("--tag", default="fit-new")
    ap.add_argument("--explain", default="")
    ap.add_argument("--rigid", default="", help="comma separated MediaPipe indices to align on, instead of MP_RIGID")
    ap.add_argument("--calib", default="first", choices=["first", "single", "window"],
                    help="neutral: first face, serve's old single frame at SETTLE_FACES, or serve's window median")
    ap.add_argument("--joint", type=int, default=0, help="rounds of joint rigid + expression refinement")
    ap.add_argument("--ict-mouth", action="store_true", help="mouth from the ICT solve, not MediaPipe's model")
    ap.add_argument("--robust", type=float, default=0.0, help="Cauchy scale (ICT cm) for joint re-alignment weights")
    a = ap.parse_args()
    global JOINT_ROUNDS, ROBUST_C, CALIB, MP_MOUTH
    MP_MOUTH = not a.ict_mouth
    JOINT_ROUNDS = a.joint
    CALIB = a.calib
    ROBUST_C = a.robust
    if a.rigid:
        mediapipe_points.MP_RIGID = np.array([int(x) for x in a.rigid.split(",")])
    values, rest = refit(a.rec, a.src)
    out = a.rec / "eval" / "experiments"
    out.mkdir(exist_ok=True)
    np.savez_compressed(out / f"{a.tag}.npz", values=values, **rest)
    if a.explain:
        explain(a.rec, values, rest["detected"], a.explain.split(","))


if __name__ == "__main__":
    main()
