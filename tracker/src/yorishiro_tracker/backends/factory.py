"""Pick an inference runtime for a model stem (<stem>.onnx, <stem>.ncnn.param/.bin)."""

from pathlib import Path

from .base import Backend

RUNTIMES = ("vulkan", "vulkan-fp32", "ncnn-cpu", "ort-cpu", "cuda", "tensorrt")


def open_model(stem: Path, runtime: str) -> Backend:
    if runtime in ("vulkan", "vulkan-fp32", "ncnn-cpu"):
        from .ncnn_backend import NcnnBackend
        return NcnnBackend(stem.with_suffix(".ncnn.param"), stem.with_suffix(".ncnn.bin"),
                           gpu=runtime != "ncnn-cpu", fp16=runtime == "vulkan")
    if runtime == "ort-cpu":
        from .ort_backend import OrtCpuBackend
        return OrtCpuBackend(stem.with_suffix(".onnx"))
    if runtime == "cuda":
        from .nvidia import CudaBackend
        return CudaBackend(stem)
    if runtime == "tensorrt":
        from .nvidia import TensorRtBackend
        return TensorRtBackend(stem)
    raise SystemExit(f"unknown runtime {runtime!r}, choose from {', '.join(RUNTIMES)}")
