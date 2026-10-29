from pathlib import Path

import numpy as np
import onnxruntime as ort


class OrtCpuBackend:
    """FP32 reference that every other backend is compared against (D2)."""

    def __init__(self, onnx_path: Path):
        self.session = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
        self.input_names = [i.name for i in self.session.get_inputs()]
        self.output_names = [o.name for o in self.session.get_outputs()]
        self.name = "ort-cpu-fp32"

    def run(self, inputs: dict[str, np.ndarray]) -> dict[str, np.ndarray]:
        outs = self.session.run(self.output_names, {k: v.astype(np.float32) for k, v in inputs.items()})
        return dict(zip(self.output_names, outs))
