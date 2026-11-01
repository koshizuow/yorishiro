"""Dev tool: convert MediaPipe's hand models (hand_landmarker.task, Apache-2.0) to ONNX.

Run: uv run python tools/export_hands.py
The bundle keeps float16 weights. tflite2onnx converts the landmark model but fails on the palm detector,
so the palm detector goes through tf2onnx in a throwaway uv environment (TensorFlow 2.15 and onnx 1.16 pinned,
newer onnx needs an ml_dtypes TensorFlow 2.15 cannot take), with its input turned NCHW for ncnn. Both
then go to ncnn with pnnx like the face models. Output: models/mediapipe/hands/.
"""

import subprocess
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from yorishiro_research.models import MODEL_DIR, ensure_hand_landmarker  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from export_mediapipe import pnnx  # noqa: E402

OUT = MODEL_DIR / "mediapipe" / "hands"
TF2ONNX = ["uvx", "--python", "3.11", "--from", "tf2onnx", "--with", "tensorflow-cpu==2.15.*",
           "--with", "numpy<2", "--with", "onnx==1.16.2", "python", "-m", "tf2onnx.convert"]


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(ensure_hand_landmarker()) as z:
        (OUT / "palm_detection_full.tflite").write_bytes(z.read("hand_detector.tflite"))
        (OUT / "hand_landmark_full.tflite").write_bytes(z.read("hand_landmarks_detector.tflite"))
    subprocess.run([str(Path(sys.executable).parent / "tflite2onnx"), str(OUT / "hand_landmark_full.tflite"), str(OUT / "hand_landmark_full.onnx")], check=True)
    subprocess.run(TF2ONNX + ["--tflite", str(OUT / "palm_detection_full.tflite"),
                              "--output", str(OUT / "palm_detection_full.onnx"), "--opset", "17",
                              "--inputs-as-nchw", "input_1"], check=True)
    import os
    os.environ["PATH"] = f"{Path(sys.executable).parent}{os.pathsep}{os.environ['PATH']}"  # pnnx from the venv
    pnnx(OUT / "palm_detection_full.onnx", "[1,3,192,192]")
    pnnx(OUT / "hand_landmark_full.onnx", "[1,3,224,224]")
    for p in sorted(OUT.glob("*.onnx")):
        print(f"wrote {p}")


if __name__ == "__main__":
    main()
