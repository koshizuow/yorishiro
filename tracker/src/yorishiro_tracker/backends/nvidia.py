"""NVIDIA GPUs through ONNX Runtime: CUDA EP (FP32, same math as the ORT CPU reference) and TensorRT EP (FP16).
Needs the ort-nvidia dependency group (onnxruntime-gpu with CUDA 13 and cuDNN wheels)."""

import sys
from pathlib import Path

import onnxruntime as ort

from ..models import MODEL_DIR
from .ort_backend import OrtBackend

TRT_CACHE = MODEL_DIR / "cache" / "tensorrt"


def _preload():
    """Load the CUDA and cuDNN libraries from the pip wheels, they are not on the library path."""
    if "CUDAExecutionProvider" not in ort.get_available_providers():
        raise SystemExit("this onnxruntime has no NVIDIA support, run: uv sync --no-group ort-cpu --group ort-nvidia")
    ort.preload_dlls(cuda=True, cudnn=True, msvc=False)


def _check(backend: OrtBackend, provider: str) -> None:
    """ORT falls back to the CPU silently when a provider fails to start. Fail loudly instead."""
    used = backend.session.get_providers()
    if not used or used[0] != provider:
        raise SystemExit(f"{provider} did not start (session uses {used}), see the onnxruntime log above")


class CudaBackend(OrtBackend):
    def __init__(self, stem: Path):
        _preload()
        super().__init__(stem.with_suffix(".onnx"), ["CUDAExecutionProvider"], name="ort-cuda-fp32")
        _check(self, "CUDAExecutionProvider")


class TensorRtBackend(OrtBackend):
    """FP16 engines built on first use (tens of seconds per model) and cached per GPU and model."""

    def __init__(self, stem: Path):
        _preload()
        try:
            import tensorrt_libs  # noqa: F401  loads libnvinfer.so.10 from the pip wheel, so ORT finds it by name
        except ImportError:
            raise SystemExit("TensorRT libraries missing, run: uv sync --no-group ort-cpu --group ort-nvidia")
        TRT_CACHE.mkdir(parents=True, exist_ok=True)
        trt = {"trt_fp16_enable": True, "trt_engine_cache_enable": True,
               "trt_engine_cache_path": str(TRT_CACHE), "trt_timing_cache_enable": True}
        print(f"TensorRT: building or loading FP16 engines in {TRT_CACHE}", file=sys.stderr)
        # CUDA EP takes any node TensorRT does not support
        super().__init__(stem.with_suffix(".onnx"), ["TensorrtExecutionProvider", "CUDAExecutionProvider"],
                         [trt, {}], name="ort-tensorrt-fp16")
        _check(self, "TensorrtExecutionProvider")
