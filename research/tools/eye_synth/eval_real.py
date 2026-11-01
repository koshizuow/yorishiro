"""Eye model on real recordings, next to the FaceMesh lid gap the tracker uses now.
    <research venv python> eval_real.py <model dir> <real dir> <out dir>
Guided recording (2026-10-29, glasses with screen reflections): per labeled segment the median and minimum
of each eye, both measures scaled to their median over the neutral and head-turn segments (1 = the user's
open eye). The wink segments show if a closed eye reads closed and the other stays open. CREMA-D (no
glasses): agreement with the lid gap, which works there. Writes report.txt and timeline.png.
"""
import sys
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).parent))
from train import EyeNet  # noqa: E402

model_dir, real, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
out.mkdir(parents=True, exist_ok=True)
model = EyeNet()
model.load_state_dict(torch.load(model_dir / "model.pt"))
model.eval()


def predict(crops):
    x = torch.from_numpy(crops.reshape(-1, *crops.shape[2:])).permute(0, 3, 1, 2).float()
    with torch.no_grad():
        p = torch.cat([model(x[k:k + 1024]) for k in range(0, len(x), 1024)])
    return p.numpy().reshape(len(crops), 2)


lines = []
z = np.load(real / "20261029-105439.npz")
labels, valid = z["labels"], z["valid"]
pred = predict(z["crops"])
lid = z["lid"]
open_ref = np.isin(labels, ["neutral", "head_left", "head_right", "roll_left", "roll_right"]) & valid
model_rel = pred / np.nanmedian(pred[open_ref], axis=0)
lid_rel = lid / np.nanmedian(lid[open_ref], axis=0)


def median3(x):
    """3 frame median: drops one-frame spikes, keeps a blink (4 or more frames at 30 fps)"""
    p = np.r_[x[:1], x, x[-1:]]
    return np.median(np.stack([p[:-2], p[1:-1], p[2:]]), axis=0)


# fused, the way the app would: the lid gap without glare, the model while the lens reflects the screen
# (glare share over the last half second, lens_glare.py's 0.02 per frame as in the app)
glare = np.nan_to_num(z["lens_glare"])
recent = np.array([glare[max(0, i - 15):i + 1].max(0) for i in range(len(glare))])
w_model = np.clip(recent / 0.02, 0, 1)
smooth = median3(model_rel)
measures = {"model": model_rel, "lid gap": lid_rel, "model median3": smooth,
            "fused": (1 - w_model) * lid_rel + w_model * smooth}
lines.append("2026-10-29 guided recording (glasses). Per eye L / R, 1 = open. median | min")
segs = ["neutral", "head_left", "head_right", "head_up", "head_down", "eyes_left", "eyes_right", "eyes_up",
        "eyes_down", "blink", "wink_left", "wink_right", "smile", "brows_up"]
for name, m in measures.items():
    lines.append(f"  {name}")
    for s in segs:
        k = (labels == s) & valid
        med, mn = np.nanmedian(m[k], axis=0), np.nanmin(m[k], axis=0)
        lines.append(f"    {s:11s} L {med[0]:.2f} R {med[1]:.2f} | L {mn[0]:.2f} R {mn[1]:.2f}")
    # wink contrast: the frames where the winking eye is lowest, how open the other eye reads there
    for s, e in (("wink_left", 0), ("wink_right", 1)):
        k = np.nonzero((labels == s) & valid)[0]
        low = k[np.argsort(m[k, e])[:8]]
        lines.append(f"    {s}: winking eye {np.median(m[low, e]):.2f}, other eye {np.median(m[low, 1 - e]):.2f}")


def blink_depths(x, valid):
    """bottom and frame of each dip below 0.75 (a blink fully closes, so a good measure bottoms near 0)"""
    out, cur = [], None
    for i, (v, ok) in enumerate(zip(x, valid)):
        if ok and v < 0.75:
            cur = (v, i) if cur is None or v < cur[0] else cur
        elif cur is not None:
            out.append(cur)
            cur = None
    return np.array(out).reshape(-1, 2)


EYES_CLOSE = np.isin(labels, ["blink", "wink_left", "wink_right"])


lines.append("  blink depth over the whole recording (bottom of each dip, near 0 = fully closed)")
for name, m in measures.items():
    for e, side in ((0, "L"), (1, "R")):
        d = blink_depths(m[:, e], valid)
        if len(d):
            inside = EYES_CLOSE[d[:, 1].astype(int)]
            deep = d[:, 0] < 0.4
            lines.append(f"    {name:13s} {side}: {len(d)} dips, median bottom {np.median(d[:, 0]):.2f}; "
                         f"below 0.4 in the blink and wink parts {np.sum(deep & inside)}, elsewhere {np.sum(deep & ~inside)}")

c = np.load(real / "crema-d-60.npz")
pc, lc, vc = predict(c["crops"]), c["lid"], c["valid"]
r = [np.corrcoef(pc[vc, e], lc[vc, e])[0, 1] for e in (0, 1)]
lines.append(f"CREMA-D (no glasses): correlation with the lid gap L {r[0]:.2f} R {r[1]:.2f}")
both = np.r_[pc[vc] / np.median(pc[vc], 0)]
lines.append(f"  model closed (<0.35 of median) {np.mean(both < 0.35) * 100:.1f}% of eye frames, "
             f"lid gap {np.mean((lc[vc] / np.median(lc[vc], 0)) < 0.35) * 100:.1f}%")
text = "\n".join(lines)
print(text)
(out / "report.txt").write_text(text + "\n")

import matplotlib  # noqa: E402
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

fig, ax = plt.subplots(len(measures), 1, figsize=(13, 3 * len(measures)), sharex=True, sharey=True)
t = np.arange(len(labels))
for a_, (name, m) in zip(ax, measures.items()):
    a_.plot(t, m[:, 0], lw=0.9, color="#c2185b", label="subject's left")
    a_.plot(t, m[:, 1], lw=0.9, color="#1565c0", label="subject's right")
    a_.set_ylabel(name)
    a_.set_ylim(0, 1.6)
    for s in ("blink", "wink_left", "wink_right", "eyes_down"):
        k = np.nonzero(labels == s)[0]
        a_.axvspan(k[0], k[-1], color="#999", alpha=0.15)
        a_.text(k[0], 1.5, s, fontsize=8)
ax[0].legend(loc="lower left")
ax[1].set_xlabel("frame")
fig.tight_layout()
fig.savefig(out / "timeline.png", dpi=90)
