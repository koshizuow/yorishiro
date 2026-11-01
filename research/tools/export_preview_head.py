"""Exports the ICT-FaceKit head (MIT) as a glTF binary for the app's tracking preview: a bald clay head that
shows what the tracker sees without showing the camera picture.
    uv run python tools/export_preview_head.py ../app/studio/hud/face_preview/head.glb   (in research/)
Keeps the face, scalp, mouth inside and eyes (eyelashes and the iris meshes behind the sclera are dropped,
the iris is painted on the sclera). The 53 expressions become morph targets named by their ARKit name
(browInnerUp and cheekPuff are split in ICT: the _L and _R halves keep their own names, the app drives both).
Morph targets are sparse: only vertices that move more than 0.1 mm are stored.
"""
import json
import struct
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from yorishiro_research.avatar.ict import REGIONS, ensure_ict_facekit, ict_to_arkit  # noqa: E402

KEEP = ("face", "head", "mouth_socket", "eye_socket", "gums_tongue", "teeth", "sclera_l", "sclera_r")
# yorishiro palette: porcelain skin with a little sakura, plum iris
SKIN = (0.80, 0.76, 0.78)
COLORS = {
    "mouth_socket": (0.30, 0.13, 0.17), "eye_socket": (0.58, 0.50, 0.53),
    "gums_tongue": (0.74, 0.42, 0.48), "teeth": (0.93, 0.91, 0.88),
}
IRIS, PUPIL, SCLERA = (0.36, 0.22, 0.34), (0.06, 0.04, 0.07), (0.95, 0.94, 0.95)
CM = 0.01
MIN_DELTA_CM = 0.01


def main(out: str) -> None:
    head = ensure_ict_facekit()
    keep = np.zeros(len(head.neutral), bool)
    colors = np.zeros((len(head.neutral), 3), np.float32)
    for region in KEEP:
        lo, hi = REGIONS[region]
        keep[lo:hi] = True
        colors[lo:hi] = COLORS.get(region, SKIN)
    for region in ("sclera_l", "sclera_r"):  # iris and pupil painted on the sclera shell, as the tracker's renderer
        lo, hi = REGIONS[region]
        d = head.neutral[lo:hi] - head.neutral[lo:hi].mean(axis=0)
        angle = np.degrees(np.arccos(np.clip(d[:, 2] / np.linalg.norm(d, axis=1), -1, 1)))
        c = np.tile(np.array(SCLERA, np.float32), (hi - lo, 1))
        c[angle < 32] = IRIS
        c[angle < 14] = PUPIL
        colors[lo:hi] = c

    remap = -np.ones(len(head.neutral), np.int64)
    remap[keep] = np.arange(keep.sum())
    tris = head.faces[np.all(keep[head.faces], axis=1)]
    tris = remap[tris].astype(np.uint32)
    pos = (head.neutral[keep] * CM).astype(np.float32)
    col = colors[keep]
    normals = vertex_normals(pos, tris)

    blob = bytearray()
    views, accessors = [], []

    def add(data: np.ndarray, target: int | None = None) -> int:
        while len(blob) % 4:
            blob.append(0)
        view = {"buffer": 0, "byteOffset": len(blob), "byteLength": data.nbytes}
        if target:
            view["target"] = target
        blob.extend(data.tobytes())
        views.append(view)
        return len(views) - 1

    def accessor(data: np.ndarray, kind: str, minmax: bool = False, target: int | None = 34962) -> int:
        comp = {np.float32: 5126, np.uint32: 5125}[data.dtype.type]
        a = {"bufferView": add(data, target), "componentType": comp, "count": len(data), "type": kind}
        if minmax:
            a["min"], a["max"] = data.min(axis=0).tolist(), data.max(axis=0).tolist()
        accessors.append(a)
        return len(accessors) - 1

    attributes = {
        "POSITION": accessor(pos, "VEC3", minmax=True),
        "NORMAL": accessor(normals, "VEC3"),
        "COLOR_0": accessor(col, "VEC3"),
    }
    indices = accessor(tris.reshape(-1), "SCALAR", target=34963)

    targets, names = [], []
    for s, name in enumerate(head.names):
        delta = (head.deltas[s][keep] * CM).astype(np.float32)
        moving = np.nonzero(np.linalg.norm(delta, axis=1) > MIN_DELTA_CM * CM)[0].astype(np.uint32)
        a = {"componentType": 5126, "count": len(pos), "type": "VEC3",
             "min": delta.min(axis=0).tolist(), "max": delta.max(axis=0).tolist(),
             "sparse": {"count": len(moving),
                        "indices": {"bufferView": add(moving), "componentType": 5125},
                        "values": {"bufferView": add(delta[moving].reshape(-1))}}}
        accessors.append(a)
        targets.append({"POSITION": len(accessors) - 1})
        names.append(ict_name(name))

    gltf = {
        "asset": {"version": "2.0", "generator": "yorishiro export_preview_head.py",
                  "copyright": "ICT-FaceKit, USC Institute for Creative Technologies, MIT license"},
        "scene": 0, "scenes": [{"nodes": [0]}],
        "nodes": [{"name": "Head", "mesh": 0}],
        "meshes": [{"name": "Head", "primitives": [{"attributes": attributes, "indices": indices,
                                                    "targets": targets, "material": 0}],
                    "weights": [0.0] * len(targets), "extras": {"targetNames": names}}],
        "materials": [{"name": "Clay", "pbrMetallicRoughness": {"metallicFactor": 0.0, "roughnessFactor": 0.75}}],
        "buffers": [{"byteLength": len(blob)}],
        "bufferViews": views, "accessors": accessors,
    }
    write_glb(Path(out), gltf, bytes(blob))
    print(f"{out}: {len(pos)} vertices, {len(tris)} triangles, {len(targets)} morph targets, "
          f"{Path(out).stat().st_size / 1e6:.1f} MB")


def ict_name(name: str) -> str:
    """ARKit name, except the split ICT halves keep a side: browInnerUp_L -> browInnerUpLeft"""
    base = ict_to_arkit(name)
    if base in ("browInnerUp", "cheekPuff"):
        return base + ("Left" if name.endswith("_L") else "Right")
    return base


def vertex_normals(pos: np.ndarray, tris: np.ndarray) -> np.ndarray:
    a, b, c = pos[tris[:, 0]], pos[tris[:, 1]], pos[tris[:, 2]]
    fn = np.cross(b - a, c - a)
    n = np.zeros_like(pos)
    for i in range(3):
        np.add.at(n, tris[:, i], fn)
    n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-12)
    return n.astype(np.float32)


def write_glb(path: Path, gltf: dict, blob: bytes) -> None:
    js = json.dumps(gltf, separators=(",", ":")).encode()
    js += b" " * (-len(js) % 4)
    blob += b"\0" * (-len(blob) % 4)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(blob)))
        f.write(struct.pack("<II", len(js), 0x4E4F534A) + js)
        f.write(struct.pack("<II", len(blob), 0x004E4942) + blob)


if __name__ == "__main__":
    main(sys.argv[1])
