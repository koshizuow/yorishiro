# Tracking models

The tracking core (crates/tracking) loads these at run time. Only the eye model is kept in git, the others
are made from upstream files by the research tools and will come with releases.

| File | What | Source and license |
|---|---|---|
| `mediapipe/face_detector.onnx` | Face detector (ONNX Runtime CPU) | MediaPipe Face Landmarker, Apache-2.0 |
| `mediapipe/face_landmarks.onnx`, `.ncnn.param`, `.ncnn.bin` | 478 face landmarks (ONNX Runtime CPU, or ncnn on Vulkan) | MediaPipe Face Landmarker, Apache-2.0 |
| `mediapipe/face_blendshapes.onnx` | MediaPipe's blendshapes, used for mouth and jaw | MediaPipe Face Landmarker, Apache-2.0 |
| `mediapipe/hands/palm_detection_full.*`, `hand_landmark_full.*` | Hand tracking | MediaPipe Hand Landmarker, Apache-2.0 |
| `core/fit.npz` | Landmark to ARKit 52 fit data | Computed from ICT-FaceKit, MIT (Copyright (c) 2020 USC Institute for Creative Technologies) |
| `eye_openness.onnx` | Eye openness | Yorishiro, Apache-2.0, trained only on renders of the ICT-FaceKit head |
