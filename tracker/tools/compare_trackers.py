"""Compare tracker outputs written by tools/run_trackers.py: agreement, CREMA-D emotion signatures, speed.

    uv run python tools/compare_trackers.py data/recordings/<rec> [more recordings]

Writes <rec>/eval/report.md and prints it. No tracker here is ground truth. Agreement is Pearson r against
MediaPipe's own blendshape model (our reference, D3) on shared signals. OpenSeeFace has its own
outputs, mapped to the closest shared signal below, so only r (not values) is comparable.

The CREMA-D part needs per-frame emotion labels (ANG_HI ...) and clip names (actor_sentence_emotion_level):
1. Signatures: for each actor, the clip mean of the signal minus the same actor's neutral clip mean. An
   emotion's signature signal should rise (Happy: smile ...). Reported as how many actors it rose for, and
   Cohen's d of the rise (mean over actors / std of the signal over all frames).
2. Emotion from all outputs: nearest centroid on clip means minus the actor's neutral, z-scored per channel,
   leave one actor out, 5 emotions (neutral is the reference, not a class). Chance is 20 %. A measure of how
   much expression a tracker's outputs carry, not a product feature.

CPU ms per frame is process CPU time over a batch run. OpenSeeFace's onnxruntime threads busy-wait between
calls, so its number is an upper bound, not what it costs at 30 fps live.
"""

import json
import sys
from pathlib import Path

import numpy as np

REFERENCE = "mediapipe"


def mean(*xs):
    return np.mean(xs, axis=0)


# shared signals: name -> (from our ARKit frame, from OpenSeeFace channels)
SIGNALS = {
    "head yaw": (lambda c: c["headYaw"], lambda c: c["yaw"]),
    # OpenSeeFace's pitch and roll turn the other way round from ours (D10 convention)
    "head pitch": (lambda c: c["headPitch"], lambda c: -c["pitch"]),
    "head roll": (lambda c: c["headRoll"], lambda c: -c["roll"]),
    "blink left": (lambda c: c["eyeBlinkLeft"], lambda c: c["blink_l"]),
    "blink right": (lambda c: c["eyeBlinkRight"], lambda c: c["blink_r"]),
    "mouth open": (lambda c: c["jawOpen"], lambda c: c["mouth_open"]),
    # OpenSeeFace computes these features on its 3D points, y up, so its brow height rises with the brows
    # and its "mouth corner" value (outer upper lip minus an inner lip point) falls in a smile. Signs read
    # from tracker.py, then checked: r is positive against MediaPipe on both recordings
    "smile": (lambda c: mean(c["mouthSmileLeft"], c["mouthSmileRight"]),
              lambda c: -mean(c["mouth_corner_updown_l"], c["mouth_corner_updown_r"])),
    "frown": (lambda c: mean(c["mouthFrownLeft"], c["mouthFrownRight"]),
              lambda c: mean(c["mouth_corner_updown_l"], c["mouth_corner_updown_r"])),
    "brows up": (lambda c: mean(c["browInnerUp"], c["browOuterUpLeft"], c["browOuterUpRight"]),
                 lambda c: mean(c["eyebrow_updown_l"], c["eyebrow_updown_r"])),
    "brows down": (lambda c: mean(c["browDownLeft"], c["browDownRight"]),
                   lambda c: -mean(c["eyebrow_updown_l"], c["eyebrow_updown_r"])),
    "inner brows up": (lambda c: c["browInnerUp"], None),
    "eyes wide": (lambda c: mean(c["eyeWideLeft"], c["eyeWideRight"]),
                  lambda c: -mean(c["blink_l"], c["blink_r"])),
    "cheek squint": (lambda c: mean(c["cheekSquintLeft"], c["cheekSquintRight"]), None),
    "nose sneer": (lambda c: mean(c["noseSneerLeft"], c["noseSneerRight"]), None),
    "upper lip up": (lambda c: mean(c["mouthUpperUpLeft"], c["mouthUpperUpRight"]), None),
}
SIGNATURES = {
    "HAP": ("smile", "cheek squint"),
    "ANG": ("brows down",),
    "SAD": ("inner brows up", "frown", "brows up"),
    "FEA": ("eyes wide", "brows up"),
    "DIS": ("nose sneer", "upper lip up", "brows down"),
}
EMOTION_NAMES = {"HAP": "Happy", "ANG": "Angry", "SAD": "Sad", "FEA": "Fear", "DIS": "Disgust"}


def load(rec: Path) -> dict:
    out = {}
    for f in sorted((rec / "eval").glob("*.npz")):
        d = np.load(f)
        names = [str(n) for n in d["names"]]
        chans = {n: d["values"][:, i] for i, n in enumerate(names)}
        osf = "yaw" in chans
        sig = {}
        for s, (ours, theirs) in SIGNALS.items():
            fn = theirs if osf else ours
            if fn is not None:
                sig[s] = np.asarray(fn(chans), np.float64)
        out[f.stem] = {"sig": sig, "detected": d["detected"], "ms": d["ms"], "cpu_s": float(d["cpu_s"]),
                       "values": d["values"], "labels": [str(x) for x in d["labels"]]}
    return out


def agreement(trackers: dict) -> list[str]:
    ref = trackers.get(REFERENCE)
    if ref is None:
        return ["(no mediapipe run, no agreement table)"]
    names = [t for t in trackers if t != REFERENCE]
    lines = ["| signal | " + " | ".join(names) + " |", "|---|" + "---|" * len(names)]
    for s in SIGNALS:
        if s not in ref["sig"]:
            continue
        row = []
        for t in names:
            tr = trackers[t]
            if s not in tr["sig"]:
                row.append("")
                continue
            m = ref["detected"] & tr["detected"]
            a, b = ref["sig"][s][m], tr["sig"][s][m]
            row.append("" if a.std() == 0 or b.std() == 0 else f"{np.corrcoef(a, b)[0, 1]:+.2f}")
        lines.append(f"| {s} | " + " | ".join(row) + " |")
    return lines


def speed(trackers: dict) -> list[str]:
    lines = ["| tracker | faces | median ms | p95 ms | CPU ms per frame |", "|---|---|---|---|---|"]
    for t, tr in trackers.items():
        n = len(tr["ms"])
        lines.append(f"| {t} | {tr['detected'].sum()}/{n} | {np.median(tr['ms']):.2f} | "
                     f"{np.percentile(tr['ms'], 95):.2f} | {tr['cpu_s'] / n * 1000:.1f} |")
    return lines


def clips(rec: Path) -> list[dict]:
    meta = json.loads((rec / "meta.json").read_text())
    out = []
    for c in meta.get("clips", []):
        parts = c["file"].split(".")[0].split("_")
        out.append({"actor": parts[0], "emotion": parts[2], "idx": np.arange(c["first"], c["first"] + c["count"])})
    return out


def emotions(rec: Path, trackers: dict) -> list[str]:
    cl = clips(rec)
    if not cl or not any(c["emotion"] == "NEU" for c in cl):
        return []
    actors = sorted({c["actor"] for c in cl})
    names = list(trackers)
    lines = ["### Signatures (actors where it rose / Cohen's d)", "",
             "| emotion | signal | " + " | ".join(names) + " |", "|---|---|" + "---|" * len(names)]
    for emo, sigs in SIGNATURES.items():
        for s in sigs:
            row = []
            for t in names:
                tr = trackers[t]
                if s not in tr["sig"]:
                    row.append("n/a")
                    continue
                x, det = tr["sig"][s], tr["detected"]
                rises = []
                for a in actors:
                    neu = [c for c in cl if c["actor"] == a and c["emotion"] == "NEU"]
                    emc = [c for c in cl if c["actor"] == a and c["emotion"] == emo]
                    if not neu or not emc:
                        continue
                    ni, ei = neu[0]["idx"], emc[0]["idx"]
                    ni, ei = ni[det[ni]], ei[det[ei]]
                    if len(ni) and len(ei):
                        rises.append(x[ei].mean() - x[ni].mean())
                sd = x[det].std()
                d = np.mean(rises) / sd if sd > 0 else 0.0
                row.append(f"{sum(r > 0 for r in rises)}/{len(rises)} {d:+.2f}")
            lines.append(f"| {EMOTION_NAMES[emo]} | {s} | " + " | ".join(row) + " |")

    lines += ["", "### Emotion from all outputs (nearest centroid, leave one actor out, chance 20 %)", "",
              "| tracker | accuracy | per emotion |", "|---|---|---|"]
    for t in names:
        tr = trackers[t]
        v, det = tr["values"].astype(np.float64), tr["detected"]
        sd = v[det].std(axis=0)
        keep = sd > 1e-6
        v = v[:, keep] / sd[keep]
        X, y, g = [], [], []
        for a in actors:
            neu = [c for c in cl if c["actor"] == a and c["emotion"] == "NEU"][0]["idx"]
            base = v[neu[det[neu]]].mean(axis=0)
            for c in cl:
                if c["actor"] == a and c["emotion"] in SIGNATURES:
                    i = c["idx"][det[c["idx"]]]
                    X.append(v[i].mean(axis=0) - base)
                    y.append(c["emotion"])
                    g.append(a)
        X, y, g = np.array(X), np.array(y), np.array(g)
        right = {e: 0 for e in SIGNATURES}
        for a in actors:
            tr_m, te_m = g != a, g == a
            cents = {e: X[tr_m & (y == e)].mean(axis=0) for e in SIGNATURES}
            for xv, yv in zip(X[te_m], y[te_m]):
                pred = min(cents, key=lambda e: np.linalg.norm(xv - cents[e]))
                right[yv] += pred == yv
        per = " ".join(f"{EMOTION_NAMES[e]} {right[e]}/{(y == e).sum()}" for e in SIGNATURES)
        lines.append(f"| {t} | {sum(right.values()) / len(y) * 100:.0f} % | {per} |")
    return lines


def main():
    for rec in map(Path, sys.argv[1:]):
        trackers = load(rec)
        order = [REFERENCE] + sorted(t for t in trackers if t != REFERENCE and t != "osf") + ["osf"]
        trackers = {t: trackers[t] for t in order if t in trackers}
        lines = [f"# Tracker comparison: {rec.name}", "", f"Trackers: {', '.join(trackers)}", "",
                 "## Speed", ""] + speed(trackers) + ["", f"## Agreement with {REFERENCE} (Pearson r)", ""]
        lines += agreement(trackers)
        emo = emotions(rec, trackers)
        if emo:
            lines += ["", "## CREMA-D emotions", ""] + emo
        report = "\n".join(lines) + "\n"
        (rec / "eval" / "report.md").write_text(report)
        print(report)


if __name__ == "__main__":
    main()
