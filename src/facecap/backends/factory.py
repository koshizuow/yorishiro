"""Pick an inference runtime for a model stem (<stem>.onnx, <stem>.ncnn.param/.bin)."""

import json
from pathlib import Path

from ..models import MODEL_DIR
from .base import Backend

RUNTIMES = ("vulkan", "vulkan-fp32", "ncnn-cpu", "ort-cpu", "npu")
VITISAI_CACHE = MODEL_DIR / "cache" / "vitisai"

# Ryzen AI default BF16 compile config, CNN data layout.
VITISAI_BF16_CONFIG = {
    "passes": [
        {"name": "init", "plugin": "vaip-pass_init"},
        {"name": "vaiml_partition", "plugin": "vaip-pass_vaiml_partition",
         "vaiml_config": {"optimize_level": 1, "preferred_data_storage": "vectorized"}},
    ],
    "target": "VAIML",
    "targets": [{"name": "VAIML", "pass": ["init", "vaiml_partition"]}],
}


def open_model(stem: Path, runtime: str) -> Backend:
    if runtime in ("vulkan", "vulkan-fp32", "ncnn-cpu"):
        from .ncnn_backend import NcnnBackend
        return NcnnBackend(stem.with_suffix(".ncnn.param"), stem.with_suffix(".ncnn.bin"),
                           gpu=runtime != "ncnn-cpu", fp16=runtime == "vulkan")
    if runtime == "ort-cpu":
        from .ort_backend import OrtCpuBackend
        return OrtCpuBackend(stem.with_suffix(".onnx"))
    if runtime == "npu":
        from .ort_backend import OrtBackend
        VITISAI_CACHE.mkdir(parents=True, exist_ok=True)
        config = VITISAI_CACHE / "bf16_config.json"
        config.write_text(json.dumps(VITISAI_BF16_CONFIG))
        options = {"config_file": str(config), "cache_dir": str(VITISAI_CACHE), "cache_key": stem.name,
                   "enable_cache_file_io_in_mem": "0"}
        return OrtBackend(stem.with_suffix(".onnx"), ["VitisAIExecutionProvider"], [options],
                          name="ryzen-ai-npu-bf16")
    raise SystemExit(f"unknown runtime {runtime!r}, choose from {', '.join(RUNTIMES)}")
