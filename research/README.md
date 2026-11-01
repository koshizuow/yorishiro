# Research tools

Python tools that make the models the tracking core (`crates/tracking`) loads, and the eye model's
training. None of this ships with the app. The Python tracker that came before the Rust core is in git
history (the `tracker/` directory before it became `research/`).

```sh
uv sync
uv run python tools/export_mediapipe.py   # MediaPipe face detector, FaceMesh-V2, blendshapes: ONNX and ncnn
uv run python tools/export_hands.py       # MediaPipe palm detector and hand landmarks: ONNX and ncnn
uv run python tools/export_fit.py         # models/core/fit.npz from ICT-FaceKit
```

They write into the repository's `models/` folder, see `models/README.md`.

- `tools/video_to_recording.py`: a video into a recording folder (meta.json and JPEG frames) that the app
  replays in place of the camera (`YORISHIRO_RECORDING`, used by `tools/app_tests.sh`).
- `tools/export_preview_head.py`: the ICT-FaceKit head as the glTF of the app's tracking preview.
- `tools/eye_synth/`: synthetic eye data and the eye openness model, see its README.
- `src/yorishiro_research/`: what those share: FaceMesh on ncnn or ONNX Runtime, the ICT-FaceKit head and
  its fit, eye crops, lens glare.
