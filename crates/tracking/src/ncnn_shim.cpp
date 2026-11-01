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

}
