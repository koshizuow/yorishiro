"""Tiny CNN: one eye crop (crop.py, BGR 64x40, right eyes mirrored) -> openness (0 closed, 1 neutral, >1 wide).
    <research venv python> train.py <out dir> <data dir with shard_*.npz>... [--epochs 12]
Each crop is normalized by its own mean and spread, so exposure differences between renders and webcams
matter less. Augmentation: shifts, scale and rotation (landmark errors), brightness, contrast, noise.
The last shard of the last data dir is held out. Writes model.pt, model.onnx (input 1x3x40x64 float, output openness).
"""
import argparse
import glob
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F


class EyeNet(nn.Module):
    def __init__(self):
        super().__init__()

        def block(i, o):
            return nn.Sequential(nn.Conv2d(i, o, 3, padding=1, bias=False), nn.BatchNorm2d(o), nn.ReLU(),
                                 nn.Conv2d(o, o, 3, padding=1, bias=False), nn.BatchNorm2d(o), nn.ReLU())
        self.b1, self.b2, self.b3, self.b4 = block(3, 16), block(16, 32), block(32, 48), block(48, 64)
        self.head = nn.Linear(64, 1)

    def forward(self, x):  # x: N x 3 x 40 x 64, BGR 0..255
        mean = x.mean(dim=(1, 2, 3), keepdim=True)
        std = x.std(dim=(1, 2, 3), keepdim=True) + 8.0
        x = (x - mean) / std
        x = F.max_pool2d(self.b1(x), 2)  # 20 x 32
        x = F.max_pool2d(self.b2(x), 2)  # 10 x 16
        x = F.max_pool2d(self.b3(x), 2)  # 5 x 8
        x = self.b4(x).mean(dim=(2, 3))
        return self.head(x).squeeze(1)


def load(files):
    crops, opens = [], []
    for f in files:
        z = np.load(f)
        crops.append(z["crops"].reshape(-1, *z["crops"].shape[2:]))
        opens.append(z["open"].reshape(-1))
    return np.concatenate(crops), np.concatenate(opens).astype(np.float32)


def augment(x: torch.Tensor) -> torch.Tensor:
    n = len(x)
    ang = torch.randn(n) * 0.06
    scale = 1 + torch.randn(n) * 0.06
    tx, ty = torch.randn(n) * 0.06, torch.randn(n) * 0.08
    theta = torch.stack([torch.stack([scale * torch.cos(ang), -scale * torch.sin(ang), tx], 1),
                         torch.stack([scale * torch.sin(ang), scale * torch.cos(ang), ty], 1)], 1)
    grid = F.affine_grid(theta, x.shape, align_corners=False)
    x = F.grid_sample(x, grid, padding_mode="border", align_corners=False)
    x = x * (0.7 + 0.6 * torch.rand(n, 1, 1, 1)) + (torch.rand(n, 1, 1, 1) - 0.5) * 60
    x = x + torch.randn_like(x) * torch.rand(n, 1, 1, 1) * 8
    gray = torch.rand(n) < 0.15  # some webcams are close to gray in dim light
    x[gray] = x[gray].mean(1, keepdim=True).expand(-1, 3, -1, -1)
    return x.clamp(0, 255)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("data", nargs="+")
    ap.add_argument("--epochs", type=int, default=12)
    ap.add_argument("--batch", type=int, default=256)
    a = ap.parse_args()
    torch.set_num_threads(8)
    files = [f for d in a.data for f in sorted(glob.glob(f"{d}/shard_*.npz"))]
    xtr, ytr = load(files[:-1])
    xva, yva = load(files[-1:])
    print(f"train {len(xtr)} eyes, val {len(xva)}")
    xtr = torch.from_numpy(xtr).permute(0, 3, 1, 2).contiguous()
    xva = torch.from_numpy(xva).permute(0, 3, 1, 2).float()
    ytr, yva = torch.from_numpy(ytr).clamp(0, 1.4), torch.from_numpy(yva).clamp(0, 1.4)
    model = EyeNet()
    print(f"{sum(p.numel() for p in model.parameters())} parameters")
    opt = torch.optim.AdamW(model.parameters(), 2e-3, weight_decay=1e-4)
    steps = a.epochs * (len(xtr) // a.batch)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, 3e-3, total_steps=steps)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    for ep in range(a.epochs):
        model.train()
        perm = torch.randperm(len(xtr))
        t0, total = time.time(), 0.0
        for j in range(len(xtr) // a.batch):
            idx = perm[j * a.batch:(j + 1) * a.batch]
            x = augment(xtr[idx].float())
            loss = F.smooth_l1_loss(model(x), ytr[idx], beta=0.1)
            opt.zero_grad()
            loss.backward()
            opt.step()
            sched.step()
            total += loss.item()
        model.eval()
        with torch.no_grad():
            p = torch.cat([model(xva[k:k + 1024]) for k in range(0, len(xva), 1024)])
        mae = (p - yva).abs().mean().item()
        closed = yva < 0.2
        acc = ((p < 0.35) == closed).float().mean().item()
        print(f"epoch {ep + 1}: loss {total / (j + 1):.4f} val MAE {mae:.3f} closed/open acc {acc:.3f} "
              f"({time.time() - t0:.0f} s)", flush=True)
    torch.save(model.state_dict(), out / "model.pt")
    torch.onnx.export(model, torch.zeros(1, 3, 40, 64), out / "model.onnx", input_names=["eye"],
                      output_names=["openness"], dynamo=False, dynamic_axes={"eye": {0: "n"}, "openness": {0: "n"}})


if __name__ == "__main__":
    main()
