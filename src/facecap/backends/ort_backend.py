from pathlib import Path

import numpy as np
import onnxruntime as ort


class OrtBackend:
    """ONNX Runtime with any execution provider. Tensors use positional names in0.., out0.. like pnnx/ncnn."""

    def __init__(self, onnx_path: Path, providers: list[str], provider_options: list[dict] | None = None,
                 name: str | None = None):
        missing = [p for p in providers if p not in ort.get_available_providers()]
        if missing:
            raise SystemExit(f"onnxruntime here lacks {missing}, available: {ort.get_available_providers()}")
        opts = ort.SessionOptions()
        opts.add_session_config_entry("session.intra_op.allow_spinning", "0")  # idle threads spin otherwise
        self.session = ort.InferenceSession(str(onnx_path), sess_options=opts, providers=providers,
                                            provider_options=provider_options)
        self._in = [i.name for i in self.session.get_inputs()]
        self._out = [o.name for o in self.session.get_outputs()]
        self.input_names = [f"in{i}" for i in range(len(self._in))]
        self.output_names = [f"out{i}" for i in range(len(self._out))]
        self.name = name or f"ort-{providers[0].removesuffix('ExecutionProvider').lower()}"

    def run(self, inputs: dict[str, np.ndarray]) -> dict[str, np.ndarray]:
        feed = {self._in[int(k[2:])]: v.astype(np.float32) for k, v in inputs.items()}
        outs = self.session.run(self._out, feed)
        return {f"out{i}": o for i, o in enumerate(outs)}


class OrtCpuBackend(OrtBackend):
    """FP32 reference that every other backend is compared against (D2)."""

    def __init__(self, onnx_path: Path):
        super().__init__(onnx_path, ["CPUExecutionProvider"], name="ort-cpu-fp32")
