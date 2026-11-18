# Tracking models

The tracking core (crates/tracking) loads these at run time. Only the eye model is kept in git, the others
are made from upstream files by the research tools and come with the releases (the AppImage and the tar.gz;
`SHA256SUMS` lists them).

| File | What | Source and license |
|---|---|---|
| `mediapipe/face_detector.onnx` | Face detector (CPU, tract) | MediaPipe Face Landmarker, Apache-2.0 |
| `mediapipe/face_landmarks.onnx`, `.ncnn.param`, `.ncnn.bin` | 478 face landmarks (CPU through tract, or ncnn on Vulkan) | MediaPipe Face Landmarker, Apache-2.0 |
| `mediapipe/face_blendshapes.onnx` | MediaPipe's blendshapes, used for mouth and jaw | MediaPipe Face Landmarker, Apache-2.0 |
| `mediapipe/hands/palm_detection_full.*`, `hand_landmark_full.*` | Hand tracking | MediaPipe Hand Landmarker, Apache-2.0 |
| `core/fit.npz` | Landmark to ARKit 52 fit data | Computed from ICT-FaceKit, MIT (Copyright (c) 2020 USC Institute for Creative Technologies) |
| `eye_openness.onnx`, `.ncnn.param`, `.ncnn.bin` | Eye openness (ncnn on the CPU, converted with pnnx at batch 1, or tract) | Yorishiro, Apache-2.0, trained only on renders of the ICT-FaceKit head |
