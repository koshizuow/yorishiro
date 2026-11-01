//! ncnn with Vulkan (feature "ncnn"): the GPU path on any graphics card (NVIDIA, AMD, Intel), like
//! the Python tracker's NcnnBackend. Models are the pnnx conversions next to the ONNX files
//! (<name>.ncnn.param / .ncnn.bin, from tools/export_mediapipe.py). Through ncnn's C API plus a small shim
//! (ncnn_shim.cpp) for listing GPUs.

use crate::backend::Error;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::path::Path;

#[allow(non_camel_case_types)]
type ncnn_net_t = *mut c_void;
#[allow(non_camel_case_types)]
type ncnn_option_t = *mut c_void;
#[allow(non_camel_case_types)]
type ncnn_mat_t = *mut c_void;
#[allow(non_camel_case_types)]
type ncnn_extractor_t = *mut c_void;

extern "C" {
    fn ncnn_net_create() -> ncnn_net_t;
    fn ncnn_net_destroy(net: ncnn_net_t);
    fn ncnn_net_set_option(net: ncnn_net_t, opt: ncnn_option_t);
    fn ncnn_net_set_vulkan_device(net: ncnn_net_t, device: c_int);
    fn ncnn_net_load_param(net: ncnn_net_t, path: *const c_char) -> c_int;
    fn ncnn_net_load_model(net: ncnn_net_t, path: *const c_char) -> c_int;
    fn ncnn_net_get_input_count(net: ncnn_net_t) -> c_int;
    fn ncnn_net_get_output_count(net: ncnn_net_t) -> c_int;
    fn ncnn_net_get_input_name(net: ncnn_net_t, i: c_int) -> *const c_char;
    fn ncnn_net_get_output_name(net: ncnn_net_t, i: c_int) -> *const c_char;
    fn ncnn_option_create() -> ncnn_option_t;
    fn ncnn_option_destroy(opt: ncnn_option_t);
    fn ncnn_option_set_num_threads(opt: ncnn_option_t, n: c_int);
    fn ncnn_option_set_use_vulkan_compute(opt: ncnn_option_t, on: c_int);
    fn ncnn_option_set_use_fp16_packed(opt: ncnn_option_t, on: c_int);
    fn ncnn_option_set_use_fp16_storage(opt: ncnn_option_t, on: c_int);
    fn ncnn_option_set_use_fp16_arithmetic(opt: ncnn_option_t, on: c_int);
    fn ncnn_mat_create_external_3d(w: c_int, h: c_int, c: c_int, data: *mut c_void, allocator: *mut c_void) -> ncnn_mat_t;
    fn ncnn_mat_destroy(mat: ncnn_mat_t);
    fn ncnn_mat_get_w(mat: ncnn_mat_t) -> c_int;
    fn ncnn_mat_get_h(mat: ncnn_mat_t) -> c_int;
    fn ncnn_mat_get_d(mat: ncnn_mat_t) -> c_int;
    fn ncnn_mat_get_c(mat: ncnn_mat_t) -> c_int;
    fn ncnn_mat_get_channel_data(mat: ncnn_mat_t, c: c_int) -> *mut c_void;
    fn ncnn_extractor_create(net: ncnn_net_t) -> ncnn_extractor_t;
    fn ncnn_extractor_destroy(ex: ncnn_extractor_t);
    fn ncnn_extractor_input(ex: ncnn_extractor_t, name: *const c_char, mat: ncnn_mat_t) -> c_int;
    fn ncnn_extractor_extract(ex: ncnn_extractor_t, name: *const c_char, mat: *mut ncnn_mat_t) -> c_int;
    fn yori_ncnn_gpu_count() -> c_int;
    fn yori_ncnn_gpu_type(i: c_int) -> c_int;
    fn yori_ncnn_gpu_name(i: c_int) -> *const c_char;
}

/// ncnn's GPU type for a CPU (software Vulkan such as llvmpipe), never picked
const GPU_TYPE_CPU: c_int = 3;

/// The first real GPU ncnn sees, with its name.
pub fn pick_vulkan_device() -> Option<(i32, String)> {
    unsafe {
        (0..yori_ncnn_gpu_count()).find(|&i| yori_ncnn_gpu_type(i) != GPU_TYPE_CPU).map(|i| {
            (i, CStr::from_ptr(yori_ncnn_gpu_name(i)).to_string_lossy().into_owned())
        })
    }
}

pub struct NcnnModel {
    net: ncnn_net_t,
    input: CString,
    outputs: Vec<CString>,
    /// e.g. "ncnn-NVIDIA GeForce RTX 2060 SUPER-fp16", as the Python backend names itself
    pub name: String,
}

// the net is only used through &mut self
unsafe impl Send for NcnnModel {}

impl NcnnModel {
    /// stem: the model path without .ncnn.param / .ncnn.bin; gpu false runs ncnn on the CPU
    pub fn open(stem: &Path, gpu: bool, fp16: bool, threads: usize) -> Result<Self, Error> {
        let device = if gpu { pick_vulkan_device() } else { None };
        if gpu && device.is_none() {
            return Err("no Vulkan GPU for ncnn".into());
        }
        let path = |ext: &str| CString::new(format!("{}.{ext}", stem.display())).unwrap();
        unsafe {
            let net = ncnn_net_create();
            let opt = ncnn_option_create();
            // On the GPU the CPU side is only uploads and a few small layers: one thread. With GCC's libgomp
            // the idle workers spun and took 4 to 8 times the CPU of the work itself; ncnn is now built with
            // NCNN_SIMPLEOMP (workers sleep), but waking them still costs more than these layers.
            let threads = if device.is_some() { 1 } else { threads.max(1) };
            ncnn_option_set_num_threads(opt, threads as c_int);
            ncnn_option_set_use_vulkan_compute(opt, device.is_some() as c_int);
            for set in [ncnn_option_set_use_fp16_packed, ncnn_option_set_use_fp16_storage, ncnn_option_set_use_fp16_arithmetic] {
                set(opt, fp16 as c_int);
            }
            ncnn_net_set_option(net, opt);
            ncnn_option_destroy(opt);
            if let Some((i, _)) = &device {
                ncnn_net_set_vulkan_device(net, *i);
            }
            if ncnn_net_load_param(net, path("ncnn.param").as_ptr()) != 0 || ncnn_net_load_model(net, path("ncnn.bin").as_ptr()) != 0 {
                ncnn_net_destroy(net);
                return Err(format!("ncnn cannot load {}.ncnn.param/.bin", stem.display()).into());
            }
            let name_of = |p: *const c_char| CString::from(CStr::from_ptr(p));
            let input = name_of(ncnn_net_get_input_name(net, 0));
            let _ = ncnn_net_get_input_count(net);
            let outputs = (0..ncnn_net_get_output_count(net)).map(|i| name_of(ncnn_net_get_output_name(net, i))).collect();
            let kind = device.map(|d| d.1).unwrap_or_else(|| "cpu".into());
            Ok(Self { net, input, outputs, name: format!("ncnn-{kind}-{}", if fp16 { "fp16" } else { "fp32" }) })
        }
    }

    /// One CHW input (c, h, w), every output flattened per channel with its name (pnnx names them out0, out1..).
    pub fn run(&mut self, c: usize, h: usize, w: usize, mut data: Vec<f32>) -> Result<Vec<(String, Vec<f32>)>, Error> {
        assert_eq!(data.len(), c * h * w);
        unsafe {
            // external data: one channel after another, which needs each channel's size to be 16 byte aligned
            // (true for the crops used here; ncnn would pad otherwise)
            assert!((h * w * 4) % 16 == 0, "channel size not 16 byte aligned");
            let input = ncnn_mat_create_external_3d(w as c_int, h as c_int, c as c_int, data.as_mut_ptr() as *mut c_void, std::ptr::null_mut());
            let ex = ncnn_extractor_create(self.net);
            let mut out = vec![];
            let mut result = Ok(());
            if ncnn_extractor_input(ex, self.input.as_ptr(), input) != 0 {
                result = Err("ncnn input failed");
            }
            for name in &self.outputs {
                if result.is_err() {
                    break;
                }
                let mut m: ncnn_mat_t = std::ptr::null_mut();
                if ncnn_extractor_extract(ex, name.as_ptr(), &mut m) != 0 || m.is_null() {
                    result = Err("ncnn extract failed");
                    break;
                }
                let per = (ncnn_mat_get_w(m) * ncnn_mat_get_h(m) * ncnn_mat_get_d(m).max(1)) as usize;
                let mut flat = Vec::with_capacity(per * ncnn_mat_get_c(m) as usize);
                for ch in 0..ncnn_mat_get_c(m) {
                    let p = ncnn_mat_get_channel_data(m, ch) as *const f32;
                    flat.extend_from_slice(std::slice::from_raw_parts(p, per));
                }
                ncnn_mat_destroy(m);
                out.push((name.to_string_lossy().into_owned(), flat));
            }
            ncnn_extractor_destroy(ex);
            ncnn_mat_destroy(input);
            result.map(|_| out).map_err(Into::into)
        }
    }
}

impl Drop for NcnnModel {
    fn drop(&mut self) {
        unsafe { ncnn_net_destroy(self.net) }
    }
}
