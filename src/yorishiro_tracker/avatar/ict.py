"""ICT-FaceKit (MIT) bald head: download, convert to a compact npz, load."""

import gzip
import urllib.request
from dataclasses import dataclass

import numpy as np

from ..frame import ARKIT52_INDEX
from ..models import MODEL_DIR

ICT_COMMIT = "da5f95a607f5e6b37755b38d3385d7f2853732e5"
ICT_RAW = f"https://raw.githubusercontent.com/USC-ICT/ICT-FaceKit/{ICT_COMMIT}"
ICT_DIR = MODEL_DIR / "ict_facekit"
ICT_NPZ = ICT_DIR / "ict_facekit.npz"

# ICT names use _L/_R and split browInnerUp and cheekPuff. No tongueOut.
ICT_SHAPES = (
    "browDown_L", "browDown_R", "browInnerUp_L", "browInnerUp_R",
    "browOuterUp_L", "browOuterUp_R", "cheekPuff_L", "cheekPuff_R",
    "cheekSquint_L", "cheekSquint_R",
    "eyeBlink_L", "eyeBlink_R", "eyeLookDown_L", "eyeLookDown_R",
    "eyeLookIn_L", "eyeLookIn_R", "eyeLookOut_L", "eyeLookOut_R",
    "eyeLookUp_L", "eyeLookUp_R", "eyeSquint_L", "eyeSquint_R", "eyeWide_L", "eyeWide_R",
    "jawForward", "jawLeft", "jawOpen", "jawRight",
    "mouthClose", "mouthDimple_L", "mouthDimple_R", "mouthFrown_L", "mouthFrown_R",
    "mouthFunnel", "mouthLeft", "mouthLowerDown_L", "mouthLowerDown_R",
    "mouthPress_L", "mouthPress_R", "mouthPucker", "mouthRight",
    "mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper",
    "mouthSmile_L", "mouthSmile_R", "mouthStretch_L", "mouthStretch_R",
    "mouthUpperUp_L", "mouthUpperUp_R", "noseSneer_L", "noseSneer_R",
)
assert len(ICT_SHAPES) == 53

# Vertex ranges from the ICT-FaceKit README (end exclusive).
REGIONS = {
    "face": (0, 9409), "head": (9409, 11248), "mouth_socket": (11248, 13294),
    "eye_socket": (13294, 14062), "gums_tongue": (14062, 17039), "teeth": (17039, 21451),
    "sclera_l": (21451, 22221), "iris_l": (22221, 23021),
    "sclera_r": (23021, 23791), "iris_r": (23791, 24591),
    "eye_helpers": (24591, 25351),  # lacrimal fluid, eye blend, eye occlusion
    "eyelashes": (25351, 26719),
}
N_VERTS = 26719


def ict_to_arkit(name: str) -> str:
    base = name.replace("_L", "").replace("_R", "")
    if base in ("browInnerUp", "cheekPuff"):
        return base
    return name.replace("_L", "Left").replace("_R", "Right")


def _fetch(path: str) -> bytes:
    req = urllib.request.Request(f"{ICT_RAW}/{path}", headers={"Accept-Encoding": "gzip"})
    with urllib.request.urlopen(req) as r:
        data = r.read()
        if r.headers.get("Content-Encoding") == "gzip":
            data = gzip.decompress(data)
    return data


def _parse_vertices(text: str) -> np.ndarray:
    rows = [line.split()[1:4] for line in text.splitlines() if line.startswith("v ")]
    return np.asarray(rows, dtype=np.float32)


def _parse_faces(text: str) -> list[list[int]]:
    return [
        [int(tok.split("/")[0]) - 1 for tok in line.split()[1:]]
        for line in text.splitlines() if line.startswith("f ")
    ]


def ensure_ict_facekit() -> "IctHead":
    if not ICT_NPZ.exists():
        ICT_DIR.mkdir(parents=True, exist_ok=True)
        (ICT_DIR / "LICENSE").write_bytes(_fetch("LICENSE"))
        print("Downloading ICT-FaceKit neutral mesh and 53 expressions")
        neutral_text = _fetch("FaceXModel/generic_neutral_mesh.obj").decode()
        neutral = _parse_vertices(neutral_text)
        assert neutral.shape == (N_VERTS, 3), neutral.shape

        lo, hi = REGIONS["eye_helpers"]
        tris = []
        for poly in _parse_faces(neutral_text):
            if any(lo <= v < hi for v in poly):
                continue
            tris.extend([poly[0], poly[i], poly[i + 1]] for i in range(1, len(poly) - 1))

        deltas = np.zeros((len(ICT_SHAPES), N_VERTS, 3), dtype=np.float32)
        for s, name in enumerate(ICT_SHAPES):
            print(f"  [{s + 1:2d}/{len(ICT_SHAPES)}] {name}")
            deltas[s] = _parse_vertices(_fetch(f"FaceXModel/{name}.obj").decode()) - neutral

        np.savez_compressed(
            ICT_NPZ, neutral=neutral, faces=np.asarray(tris, dtype=np.int32),
            deltas=deltas, names=np.array(ICT_SHAPES), commit=ICT_COMMIT,
        )
    return IctHead.load()


@dataclass
class IctHead:
    neutral: np.ndarray  # (N, 3)
    faces: np.ndarray  # (T, 3) triangles, eye helper meshes removed
    deltas: np.ndarray  # (S, N, 3)
    names: tuple[str, ...]
    arkit_index: np.ndarray  # (S,) ARKit 52 index that drives each ICT shape

    @classmethod
    def load(cls) -> "IctHead":
        z = np.load(ICT_NPZ)
        names = tuple(str(n) for n in z["names"])
        arkit_index = np.array([ARKIT52_INDEX[ict_to_arkit(n)] for n in names], dtype=np.int32)
        return cls(z["neutral"], z["faces"], z["deltas"], names, arkit_index)

    def weights_from_arkit(self, bs52: np.ndarray) -> np.ndarray:
        return bs52[self.arkit_index].astype(np.float32)

    def vertex_colors(self) -> np.ndarray:
        palette = {
            "face": (0.78, 0.76, 0.74), "head": (0.78, 0.76, 0.74),
            "mouth_socket": (0.35, 0.10, 0.10), "eye_socket": (0.55, 0.45, 0.43),
            "gums_tongue": (0.80, 0.42, 0.45), "teeth": (0.93, 0.92, 0.86),
            "sclera_l": (0.95, 0.95, 0.95), "iris_l": (0.12, 0.08, 0.06),
            "sclera_r": (0.95, 0.95, 0.95), "iris_r": (0.12, 0.08, 0.06),
            "eye_helpers": (0.0, 0.0, 0.0), "eyelashes": (0.22, 0.20, 0.20),
        }
        colors = np.zeros((N_VERTS, 3), dtype=np.float32)
        for region, (lo, hi) in REGIONS.items():
            colors[lo:hi] = palette[region]
        # The sclera shell covers the iris (UE digital-human style), so paint iris and pupil onto it.
        for region in ("sclera_l", "sclera_r"):
            lo, hi = REGIONS[region]
            v = self.neutral[lo:hi]
            d = v - v.mean(axis=0)
            angle = np.degrees(np.arccos(np.clip(d[:, 2] / np.linalg.norm(d, axis=1), -1, 1)))
            colors[lo:hi][angle < 32] = (0.30, 0.20, 0.12)
            colors[lo:hi][angle < 14] = (0.03, 0.03, 0.03)
        return colors
