"""Eye measures against hand labels (testdata/phone/eye_labels.json, every 6th frame of the phone clips).
    <tracker venv python> eval_labeled.py <real dir> <model dir> [<model dir> ...]
Per clip and measure: AUC closed (label <= 0.2) vs open (>= 0.7) over all labeled eyes, the share of eyes
read correctly at the measure's own best threshold, and for one-eye frames (one closed, the other open)
how often the closed eye reads lower than the open one.
"""
import json
import sys
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).parent))
from train import EyeNet  # noqa: E402

# private test data (D28), next to the monorepo
LABELS = json.load(open(Path(__file__).resolve().parents[4] / "testdata" / "phone" / "eye_labels.json"))
real = Path(sys.argv[1])
models = {Path(m).name: m for m in sys.argv[2:]}


def predict(path, crops):
    m = EyeNet()
    m.load_state_dict(torch.load(Path(path) / "model.pt"))
    m.eval()
    x = torch.from_numpy(crops.reshape(-1, *crops.shape[2:])).permute(0, 3, 1, 2).float()
    with torch.no_grad():
        return torch.cat([m(x[k:k + 1024]) for k in range(0, len(x), 1024)]).numpy().reshape(len(crops), 2)


def auc(pos, neg):
    """probability that a closed eye reads lower than an open one"""
    pos, neg = np.asarray(pos), np.asarray(neg)
    return float(((pos[:, None] < neg[None]).mean() + 0.5 * (pos[:, None] == neg[None]).mean()))


for clip in ("1433", "1434"):
    z = np.load(real / f"phone-{clip}.npz")
    measures = {"lid gap": z["lid"]}
    for name, path in models.items():
        measures[name] = predict(path, z["crops"])
    lab = {int(k): v for k, v in LABELS[clip].items()}
    frames = sorted(lab)
    print(f"phone {clip} ({'glasses' if clip == '1433' else 'no glasses'}), {len(frames)} labeled frames")
    for name, m in measures.items():
        closed, open_ = [], []
        wink_ok, wink_n = 0, 0
        for f in frames:
            for e in (0, 1):
                (closed if lab[f][e] <= 0.2 else open_ if lab[f][e] >= 0.7 else []).append(m[f, e])
            l = lab[f]
            if min(l) <= 0.2 and max(l) >= 0.7:
                c, o = (0, 1) if l[0] < l[1] else (1, 0)
                wink_n += 1
                wink_ok += m[f, c] < m[f, o]
        vals = np.r_[closed, open_]
        truth = np.r_[np.ones(len(closed)), np.zeros(len(open_))]
        best = max(((vals < t) == truth).mean() for t in np.unique(vals))
        print(f"  {name:9s} AUC {auc(closed, open_):.3f}  best accuracy {best * 100:.1f}%  "
              f"one-eye frames right {wink_ok}/{wink_n}   ({len(closed)} closed, {len(open_)} open eyes)")
