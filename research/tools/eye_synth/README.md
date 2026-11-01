# Synthetic eye data and the eye openness model

The model in `models/eye_openness.onnx` (in the repository root) (adapters/eye_openness.py) is trained only on
renders of the ICT-FaceKit head (MIT). No face dataset is used for training (D8: research sets are for
evaluation only).

1. `run_gen.sh <out dir> [seed offset]`: 4 x 10000 samples of `gen.py` (random pose, expression, skin, brows,
   lashes, iris, lights, backgrounds, 55 % glasses with screen-content reflections, webcam effects; FaceMesh on
   the render, eye crops with exact openness labels). About 35 minutes on the RTX 2060 SUPER machine.
2. `train.py <model dir> <data dir>...`: 116k parameter CNN, 12 epochs on CPU (4 min each for 150k crops),
   writes model.pt and model.onnx. v2 (2026-10-31) = v1 data (seeds 1-4, small quad reflections) + v2 data
   (seeds 11-14, screen-content reflections), synthetic val MAE 0.071.
3. Evaluation on real faces: `prep_real.py` crops a recording the same way, `eval_real.py` scores without
   labels (blink depth, wink contrast) on the guided glasses recording and CREMA-D, `eval_labeled.py` scores
   against hand labels (testdata/phone/eye_labels.json).
