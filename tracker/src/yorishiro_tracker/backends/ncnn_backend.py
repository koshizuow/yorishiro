import os
from pathlib import Path

# ncnn's OpenMP workers (libgomp) otherwise spin after every layer: about 2 of 4 cores on an
# i3-10105F, which starved the app's main loop to 10 fps. libgomp reads this when it loads, so it
# has to be set before the import (opt.openmp_blocktime does nothing with libgomp).
os.environ.setdefault("OMP_WAIT_POLICY", "PASSIVE")
import ncnn  # noqa: E402
import numpy as np

_CPU_DEVICE_TYPE = 3  # ncnn GpuInfo.type(): 0 discrete, 1 integrated, 2 virtual, 3 cpu (llvmpipe)


def pick_vulkan_device() -> int | None:
    for i in range(ncnn.get_gpu_count()):
        if ncnn.get_gpu_info(i).type() != _CPU_DEVICE_TYPE:
            return i
    return None


class NcnnBackend:
    def __init__(self, param: Path, model: Path, gpu: bool = True, fp16: bool = True):
        self.net = ncnn.Net()
        device = pick_vulkan_device() if gpu else None
        self.net.opt.use_vulkan_compute = device is not None
        if device is not None:
            self.net.set_vulkan_device(device)
        self.net.opt.use_fp16_packed = fp16
        self.net.opt.use_fp16_storage = fp16
        self.net.opt.use_fp16_arithmetic = fp16
        self.net.load_param(str(param))
        self.net.load_model(str(model))
        self.input_names = list(self.net.input_names())
        self.output_names = list(self.net.output_names())
        kind = ncnn.get_gpu_info(device).device_name() if device is not None else "cpu"
        self.name = f"ncnn-{kind}-{'fp16' if fp16 else 'fp32'}"

    def run(self, inputs: dict[str, np.ndarray]) -> dict[str, np.ndarray]:
        ex = self.net.create_extractor()
        for name, arr in inputs.items():
            # Hold a reference: ncnn.Mat does not keep the numpy buffer alive.
            a = np.ascontiguousarray(arr[0], dtype=np.float32)
            ex.input(name, ncnn.Mat(a).clone())
        out = {}
        for name in self.output_names:
            _, m = ex.extract(name)
            out[name] = np.array(m)[None]
        return out
