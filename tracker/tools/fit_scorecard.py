"""Short scorecard for solver experiments (tools/refit.py tags): the numbers that moved, on both recordings.

    uv run python tools/fit_scorecard.py data/recordings/<user rec> data/recordings/crema-d-60 fit-base fit-x ...
"""

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compare_trackers import REFERENCE, clips, load  # noqa: E402

USER_SIGNALS = ("blink left", "blink right", "mouth open", "smile", "brows up", "brows down", "inner brows up",
                "cheek squint", "nose sneer")
CREMA = (("HAP", "eyes wide"), ("HAP", "cheek squint"), ("ANG", "brows down"), ("SAD", "inner brows up"),
         ("FEA", "eyes wide"), ("DIS", "nose sneer"), ("DIS", "brows down"))


def r(ref, tr, s):
    m = ref["detected"] & tr["detected"]
    return np.corrcoef(ref["sig"][s][m], tr["sig"][s][m])[0, 1]


def leak(tr, s, pose):
    """Correlation of an expression with head pose. Should be near 0, a face does not frown by looking up."""
    m = tr["detected"]
    x = tr["sig"][s][m]
    p = tr["sig"]["head pitch"][m] if pose == "pitch" else np.abs(tr["sig"]["head yaw"][m])
    return np.corrcoef(x, p)[0, 1] if x.std() > 1e-9 else float("nan")


def rise(rec, tr, emo, s):
    cl = clips(rec)
    x, det = tr["sig"][s], tr["detected"]
    out = []
    for a in sorted({c["actor"] for c in cl}):
        ni = next(c for c in cl if c["actor"] == a and c["emotion"] == "NEU")["idx"]
        ei = next(c for c in cl if c["actor"] == a and c["emotion"] == emo)["idx"]
        out.append(x[ei[det[ei]]].mean() - x[ni[det[ni]]].mean())
    return np.mean(out) / x[det].std()


def main():
    user, crema, tags = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3:]
    u, c = load(user), load(crema)
    print("user rec, r vs mediapipe".ljust(28) + "".join(t[:12].rjust(13) for t in tags))
    for s in USER_SIGNALS:
        print(f"  {s}".ljust(28) + "".join(f"{r(u[REFERENCE], u[t], s):+13.2f}" for t in tags))
    print("user rec, head pose leak (r)".ljust(28))
    for s, pose in (("brows down", "pitch"), ("cheek squint", "|yaw|"), ("blink left", "|yaw|"), ("smile", "|yaw|")):
        print(f"  {s} ~ {pose}".ljust(28) + "".join(f"{leak(u[t], s, pose):+13.2f}" for t in tags))
    print("crema-d, Cohen's d of rise".ljust(28))
    for emo, s in CREMA:
        print(f"  {emo} {s}".ljust(28) + "".join(f"{rise(crema, c[t], emo, s):+13.2f}" for t in tags))


if __name__ == "__main__":
    main()
