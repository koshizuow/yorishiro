#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy", "pillow"]
# ///
"""Render regression over every test model: 13 poses, each expression hotkey and each expression on its own,
compared to a baseline.

    tools/render_regress.py              run all models, compare, write a report
    tools/render_regress.py --accept     same, then make this run the new baseline
    tools/render_regress.py hiyori_free hiyori_pro    only these models (name substring)
    tools/render_regress.py --compare testdata/render-runs/<time>   compare a finished run again

Models are every folder with a .model3.json under testdata/models, plus the Hiyori samples in
userdata/yorishiro/Live2DModels. Runs use --fixed-clock and --fixed-fps 60 and an empty data folder per model (default settings), so an
unchanged app gives pixel-identical shots and any difference is real. Baselines live in testdata/render-baseline/<model>/
(private, D28). Output and report go to testdata/render-runs/<timestamp>/ (not committed).
"""
import argparse
import datetime
import os
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
TESTDATA = ROOT.parent / "testdata"
BASELINE = TESTDATA / "render-baseline"
RUNS = TESTDATA / "render-runs"
# a pixel counts as changed when any channel moves more than this, a shot fails above FAIL_PCT changed
PIXEL_TOL = 8
FAIL_PCT = 0.05


def find_models():
    found = {}
    for base in (TESTDATA / "models", ROOT / "userdata/yorishiro/Live2DModels"):
        for m3 in sorted(base.rglob("*.model3.json")):
            # a model folder name, unique enough to key baselines by
            name = m3.relative_to(base).parts[0]
            found.setdefault(name, m3)
    return found


def render(model: Path, out: Path):
    out.mkdir(parents=True, exist_ok=True)
    cmd = [str(ROOT / "run.sh"), "--disable-vsync", "--fixed-fps", "60", "--",
           f"--model={model}", f"--screenshot={out / 'main.png'}", "--wait-frames=60",
           f"--poses={ROOT / 'tools/poses.json'}", "--pose-frames=40", "--hotkeys", "--expressions-all", "--fixed-clock", "--quit"]
    # a fresh data folder per model: default settings, whatever earlier runs or tests saved does not count
    data = out / "userdata"
    shutil.rmtree(data, ignore_errors=True)
    env = {**os.environ, "YORISHIRO_USERDATA": str(data), "YORISHIRO_RECORDING": str(TESTDATA / "recordings/crema-d-60")}
    with open(out / "run.log", "w") as log:
        rc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, timeout=900, env=env).returncode
    shutil.rmtree(data, ignore_errors=True)
    errors = [l for l in (out / "run.log").read_text(errors="replace").splitlines()
              if "SCRIPT ERROR" in l or "Parse Error" in l]
    # camera_panel.gd:117 fires when automation swaps in a pose tracker, known and harmless
    errors = [e for e in errors if "on a base object of type 'Nil'" not in e]
    return rc, errors


def _premultiplied(path: Path) -> np.ndarray:
    """color times alpha: what any consumer sees, the color of fully transparent pixels does not matter
    (the stage cleared to gray with alpha 0 before app 8c670e8, to black after)"""
    x = np.asarray(Image.open(path).convert("RGBA"), dtype=np.int32)
    x[..., :3] = x[..., :3] * x[..., 3:] // 255
    return x.astype(np.int16)


def diff(a: Path, b: Path):
    x = _premultiplied(a)
    y = _premultiplied(b)
    if x.shape != y.shape:
        return 100.0, 255
    d = np.abs(x - y).max(axis=2)
    return float((d > PIXEL_TOL).mean() * 100), int(d.max())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("only", nargs="*")
    ap.add_argument("--accept", action="store_true")
    ap.add_argument("--compare", type=Path, help="compare an earlier run (testdata/render-runs/<time>) again, no rendering")
    a = ap.parse_args()
    models = {n: p for n, p in find_models().items() if not a.only or any(o in n for o in a.only)}
    run = a.compare or RUNS / datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    lines, failed = [], 0
    for name, m3 in models.items():
        out = run / name
        if a.compare:
            if not out.exists():
                continue
            rc, errors = 0, []
        else:
            rc, errors = render(m3, out)
        shots = sorted(p.name for p in out.glob("*.png"))
        base = BASELINE / name
        changed, missing = [], []
        for s in shots:
            if not (base / s).exists():
                missing.append(s)
                continue
            pct, mx = diff(base / s, out / s)
            if pct > FAIL_PCT:
                changed.append(f"{s} {pct:.2f}% (max {mx})")
        gone = sorted(p.name for p in base.glob("*.png") if p.name not in shots) if base.exists() else []
        bad = rc != 0 or errors or changed or gone
        failed += bool(bad)
        status = "FAIL" if bad else ("NEW" if missing and not base.exists() else "ok")
        block = [f"{status:4} {name}: {len(shots)} shots, rc {rc}"
                 + (f", {len(errors)} script errors" if errors else "")
                 + (f", {len(changed)} changed" if changed else "")
                 + (f", {len(missing)} without baseline" if missing else "")
                 + (f", {len(gone)} missing vs baseline" if gone else "")]
        block += [f"     changed {c}" for c in changed] + [f"     gone {g}" for g in gone]
        block += [f"     {e}" for e in errors[:5]]
        print("\n".join(block), flush=True)
        lines += block
        if a.accept:
            base.mkdir(parents=True, exist_ok=True)
            for p in base.glob("*.png"):
                p.unlink()
            for s in shots:
                shutil.copy2(out / s, base / s)
    report = "\n".join(lines) + f"\n\n{len(models)} models, {failed} failed\n"
    (run / "report.txt").write_text(report)
    print(f"\n{len(models)} models, {failed} failed. Report {run / 'report.txt'}")
    if a.accept:
        print(f"baseline updated in {BASELINE}")
    sys.exit(1 if failed and not a.accept else 0)


if __name__ == "__main__":
    main()
