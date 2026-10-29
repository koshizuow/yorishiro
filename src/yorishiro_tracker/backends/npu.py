"""AMD Ryzen AI NPU (XDNA2) through ONNX Runtime's VitisAI EP, BF16 VAIML flow. Experimental."""

import json
import sys
from pathlib import Path

import numpy as np

from ..models import MODEL_DIR
from .ort_backend import OrtBackend

CACHE = MODEL_DIR / "cache" / "vitisai"
BF16_CONFIG = {
    "passes": [
        {"name": "init", "plugin": "vaip-pass_init"},
        {"name": "vaiml_partition", "plugin": "vaip-pass_vaiml_partition",
         "vaiml_config": {"optimize_level": 1, "preferred_data_storage": "vectorized"}},
    ],
    "target": "VAIML",
    "targets": [{"name": "VAIML", "pass": ["init", "vaiml_partition"]}],
}
WARNING = ("NPU runtime is experimental: the NPU computes in BF16. FaceMesh-V2 drifts 0.7 px on average "
           "and eye shapes by up to 0.25 versus FP32. First run compiles the model, this can take ~20 min.")


def rewrite_prelu(src: Path, dst: Path) -> int:
    """PRelu(x) = Relu(x) - a * Relu(-x). VAIML does not map PRelu, which splits the graph into CPU islands."""
    import onnx
    from onnx import helper, numpy_helper

    model = onnx.load(src)
    g = model.graph
    inits = {i.name: i for i in g.initializer}
    nodes, count = [], 0
    for n in g.node:
        if n.op_type != "PRelu" or n.input[1] not in inits:
            nodes.append(n)
            continue
        x, y, p = n.input[0], n.output[0], f"{n.output[0]}__prelu"
        neg_alpha = numpy_helper.from_array(-numpy_helper.to_array(inits[n.input[1]]).astype(np.float32),
                                            f"{p}_negalpha")
        g.initializer.append(neg_alpha)
        nodes += [
            helper.make_node("Relu", [x], [f"{p}_pos"], name=f"{p}_relu_pos"),
            helper.make_node("Neg", [x], [f"{p}_negx"], name=f"{p}_neg"),
            helper.make_node("Relu", [f"{p}_negx"], [f"{p}_rneg"], name=f"{p}_relu_neg"),
            helper.make_node("Mul", [f"{p}_rneg", neg_alpha.name], [f"{p}_scaled"], name=f"{p}_mul"),
            helper.make_node("Add", [f"{p}_pos", f"{p}_scaled"], [y], name=f"{p}_add"),
        ]
        count += 1
    del g.node[:]
    g.node.extend(nodes)
    onnx.checker.check_model(model)
    onnx.save(model, dst)
    return count


def npu_model(stem: Path) -> Path:
    """ONNX model rewritten for the NPU, regenerated when the source changes."""
    src = stem.with_suffix(".onnx")
    dst = CACHE / f"{stem.name}.npu.onnx"
    if not dst.exists() or dst.stat().st_mtime < src.stat().st_mtime:
        rewrite_prelu(src, dst)
    return dst


class NpuBackend(OrtBackend):
    def __init__(self, stem: Path):
        print(WARNING, file=sys.stderr)
        CACHE.mkdir(parents=True, exist_ok=True)
        config = CACHE / "bf16_config.json"
        config.write_text(json.dumps(BF16_CONFIG))
        options = {"config_file": str(config), "cache_dir": str(CACHE), "cache_key": f"{stem.name}.npu",
                   "enable_cache_file_io_in_mem": "0"}
        super().__init__(npu_model(stem), ["VitisAIExecutionProvider"], [options], name="ryzen-ai-npu-bf16")
