// What ncnn's C API leaves out and the core needs: the GPUs ncnn sees, to pick a real one (the Python
// backend's pick_vulkan_device) and to name it in the status.
#include "gpu.h"

extern "C" {

int yori_ncnn_gpu_count() {
    return ncnn::get_gpu_count();
}

// 0 discrete, 1 integrated, 2 virtual, 3 cpu (llvmpipe and friends)
int yori_ncnn_gpu_type(int i) {
    return ncnn::get_gpu_info(i).type();
}

const char* yori_ncnn_gpu_name(int i) {
    return ncnn::get_gpu_info(i).device_name();
}

// The Vulkan instance down now, not in ncnn's static destructor: on Windows that runs while the DLL unloads, under
// the loader lock, and the GPU driver's teardown waited there for ever (the app never exited).
void yori_ncnn_release_gpu() {
    ncnn::destroy_gpu_instance();
}

}
