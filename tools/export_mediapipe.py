"""Dev tool: convert MediaPipe face detector and FaceMesh-V2 to ONNX and ncnn.

Run: uv run python tools/export_mediapipe.py
Detector: tflite2onnx from the face_landmarker.task bundle.
Landmarks: PINTO model zoo 410_FaceMeshV2 ONNX (Apache-2.0), tflite2onnx cannot handle its fp16 weights.
"""

import re
import subprocess
import sys
import tarfile
import urllib.request
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from facecap.models import MODEL_DIR, ensure_face_landmarker  # noqa: E402

OUT = MODEL_DIR / "mediapipe"
PINTO_URL = "https://s3.ap-northeast-2.wasabisys.com/pinto-model-zoo/410_FaceMeshV2/resources.tar.gz"
PINTO_ONNX = "face_landmarks_detector_1x3x256x256.onnx"


def pnnx(onnx_path: Path, shape: str) -> None:
    subprocess.run(["pnnx", onnx_path.name, f"inputshape={shape}"], cwd=onnx_path.parent,
                   check=True, stdout=subprocess.DEVNULL)
    fix_channel_pads(onnx_path.with_suffix(".pnnx.param"), onnx_path.with_suffix(".ncnn.param"))
    for p in sorted(onnx_path.parent.glob(f"{onnx_path.stem}.ncnn.*")):
        print(f"wrote {p}")


def fix_channel_pads(pnnx_param: Path, ncnn_param: Path) -> None:
    """pnnx leaves NCHW Pad ops that only pad channels as raw `Pad`, which ncnn cannot load.

    ncnn's Padding layer handles channel padding through 7=front and 8=behind.
    """
    pads = {}
    for line in pnnx_param.read_text().splitlines():
        m = re.match(r"F\.pad\s+(\S+).*pad=\(([^)]*)\)", line) or re.match(r"Pad\s+(\S+).*pads=\(([^)]*)\)", line)
        if m:
            pads[m.group(1)] = [int(v) for v in m.group(2).split(",")]
    lines = ncnn_param.read_text().splitlines()
    for i, line in enumerate(lines):
        parts = line.split()
        if not parts or parts[0] != "Pad":
            continue
        p = pads.get(parts[1])
        if p is None or len(p) != 8 or any(p[k] for k in (0, 2, 3, 4, 6, 7)):
            raise SystemExit(f"unsupported Pad in {ncnn_param}: {line} pads={p}")
        name, n_in, n_out, blob_in, blob_out = parts[1:6]
        lines[i] = (f"{'Padding':<24} {name:<24} {n_in} {n_out} {blob_in} {blob_out} "
                    f"0=0 1=0 2=0 3=0 4=0 5=0.0 7={p[1]} 8={p[5]}")
        print(f"patched {name}: channel pad front={p[1]} behind={p[5]}")
    ncnn_param.write_text("\n".join(lines) + "\n")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(ensure_face_landmarker()) as z:
        z.extract("face_detector.tflite", OUT)
    det_onnx = OUT / "face_detector.onnx"
    subprocess.run(["tflite2onnx", str(OUT / "face_detector.tflite"), str(det_onnx)], check=True)
    pnnx(det_onnx, "[1,3,128,128]")

    lm_onnx = OUT / "face_landmarks.onnx"
    if not lm_onnx.exists():
        tgz = OUT / "pinto.tar.gz"
        urllib.request.urlretrieve(PINTO_URL, tgz)
        with tarfile.open(tgz) as t:
            member = t.getmember(PINTO_ONNX)
            member.name = lm_onnx.name
            t.extract(member, OUT, filter="data")
        tgz.unlink()
    pnnx(lm_onnx, "[1,3,256,256]")


if __name__ == "__main__":
    main()
