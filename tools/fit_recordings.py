#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow"]
# ///
"""Recordings fitted into 1920x1080 (shape kept, black around), as JPEG frames with the same meta.json: what a
reference tracker gets through the Windows recording player and virtual camera, and what Yorishiro then replays, so
both see the same pictures (the player fitting frames itself fell behind on a laptop).

    tools/fit_recordings.py SRC_DIR DST_DIR RECORDING...
"""
import json
import sys
from pathlib import Path

from PIL import Image

src_root, dst_root = Path(sys.argv[1]), Path(sys.argv[2])
for name in sys.argv[3:]:
    src, dst = src_root / name, dst_root / name
    (dst / "frames").mkdir(parents=True, exist_ok=True)
    meta = json.load(open(src / "meta.json"))
    n = len(meta["timestamps_ms"])
    for i in range(n):
        im = Image.open(src / f"frames/{i:05d}.jpg").convert("RGB")
        k = min(1920 / im.width, 1080 / im.height)
        sw, sh = max(1, round(im.width * k)), max(1, round(im.height * k))
        if (sw, sh) != im.size:
            im = im.resize((sw, sh), Image.BILINEAR)
        out = Image.new("RGB", (1920, 1080))
        out.paste(im, ((1920 - sw) // 2, (1080 - sh) // 2))
        out.save(dst / f"frames/{i:05d}.jpg", quality=95)
    meta["size"] = [1920, 1080]
    meta["fitted_from"] = name
    json.dump(meta, open(dst / "meta.json", "w"))
    print(name, n, "frames")
