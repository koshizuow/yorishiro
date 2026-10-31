//! Running the networks: ONNX Runtime through the `ort` crate, loaded at run time (load-dynamic) from a
//! libonnxruntime the user's install provides (CPU build, or the CUDA/TensorRT one on NVIDIA), so the core
//! itself carries no runtime. ncnn (Vulkan, for AMD and Intel GPUs) follows as a second backend.

use ort::environment::Environment;
use ort::session::Session;
use ort::value::Tensor;
use std::path::Path;
use std::sync::OnceLock;

pub type Error = Box<dyn std::error::Error + Send + Sync>;

static ENV: OnceLock<Result<Environment, String>> = OnceLock::new();

/// The process's ONNX Runtime, loaded from a libonnxruntime.so once: the given path, else ORT_DYLIB_PATH,
/// else the system's.
pub fn runtime(library: Option<&Path>) -> Result<&'static Environment, Error> {
    let env = ENV.get_or_init(|| {
        let lib = library.map(|p| p.to_path_buf()).or_else(|| std::env::var_os("ORT_DYLIB_PATH").map(Into::into));
        let builder = match lib {
            Some(p) => ort::init_from(p).map_err(|e| e.to_string())?,
            None => ort::init(),
        };
        builder.with_name("yorishiro").build().map_err(|e| e.to_string())
    });
    env.as_ref().map_err(|e| e.clone().into())
}

/// Where a network runs on ONNX Runtime. CUDA and TensorRT need the GPU build of ONNX Runtime
/// (onnxruntime-gpu) and its CUDA, cuDNN and TensorRT libraries, see preload_nvidia.
#[derive(Clone, Debug, PartialEq)]
pub enum Provider {
    Cpu,
    /// fp32, the same math as the CPU
    Cuda,
    /// fp16 engines, built on first use (tens of seconds per model) and cached in this folder
    TensorRt { cache: std::path::PathBuf },
}

static NVIDIA: OnceLock<Vec<libloading::os::unix::Library>> = OnceLock::new();

/// Loads the CUDA, cuDNN and TensorRT libraries of the pip wheels (site-packages/nvidia/*/lib,
/// site-packages/tensorrt_libs) so ONNX Runtime's providers find them by name, as onnxruntime's
/// preload_dlls does in Python. LD_LIBRARY_PATH cannot do it: it is read only when the process starts.
/// Libraries that need others load in a later pass. Returns how many loaded.
pub fn preload_nvidia(site_packages: &Path) -> usize {
    NVIDIA.get_or_init(|| {
        let mut dirs: Vec<std::path::PathBuf> = std::fs::read_dir(site_packages.join("nvidia"))
            .map(|d| d.filter_map(|e| e.ok()).map(|e| e.path().join("lib")).filter(|p| p.is_dir()).collect())
            .unwrap_or_default();
        dirs.push(site_packages.join("tensorrt_libs"));
        let mut todo: Vec<std::path::PathBuf> = dirs.iter()
            .filter_map(|d| std::fs::read_dir(d).ok())
            .flat_map(|d| d.filter_map(|e| e.ok()).map(|e| e.path()))
            .filter(|p| p.file_name().map(|n| n.to_string_lossy().contains(".so")).unwrap_or(false))
            .collect();
        let mut loaded = vec![];
        loop {
            let before = todo.len();
            todo.retain(|p| unsafe {
                match libloading::os::unix::Library::open(Some(p), libloading::os::unix::RTLD_NOW | libloading::os::unix::RTLD_GLOBAL) {
                    Ok(l) => { loaded.push(l); false }
                    Err(_) => true,
                }
            });
            if todo.is_empty() || todo.len() == before {
                break;
            }
        }
        loaded
    }).len()
}

/// One network on ONNX Runtime.
pub struct OrtModel {
    session: Session,
    /// e.g. "ort-cpu-fp32", "ort-cuda-fp32", "ort-tensorrt-fp16", as the Python backends name themselves
    pub name: String,
}

impl OrtModel {
    pub fn open(path: &Path, threads: usize) -> Result<Self, Error> {
        Self::open_on(path, threads, &Provider::Cpu)
    }

    /// A provider that does not start is an error, not a quiet fallback to the CPU.
    pub fn open_on(path: &Path, threads: usize, provider: &Provider) -> Result<Self, Error> {
        use ort::ep::{TensorRT, CUDA};
        let env = runtime(None)?;
        let mut builder = Session::builder(env)?.with_intra_threads(threads).map_err(ort::Error::<()>::from)?;
        let name = match provider {
            Provider::Cpu => "ort-cpu-fp32",
            Provider::Cuda => {
                builder = builder.with_execution_providers([CUDA::default().build().error_on_failure()]).map_err(ort::Error::<()>::from)?;
                "ort-cuda-fp32"
            }
            Provider::TensorRt { cache } => {
                std::fs::create_dir_all(cache)?;
                let cache = cache.display().to_string();
                let trt = TensorRT::default().with_fp16(true).with_engine_cache(true).with_engine_cache_path(&cache)
                    .with_timing_cache(true).with_timing_cache_path(&cache);
                // CUDA takes any node TensorRT does not support
                builder = builder.with_execution_providers([trt.build().error_on_failure(), CUDA::default().build()])
                    .map_err(ort::Error::<()>::from)?;
                "ort-tensorrt-fp16"
            }
        };
        let session = builder.commit_from_file(path)?;
        Ok(Self { session, name: name.into() })
    }

    /// One input tensor in, every output as flat f32 in the model's output order.
    pub fn run(&mut self, shape: &[i64], data: Vec<f32>) -> Result<Vec<Vec<f32>>, Error> {
        let input = Tensor::from_array((shape.to_vec(), data))?;
        let outputs = self.session.run(ort::inputs![input])?;
        let mut out = vec![];
        for (_, value) in outputs.iter() {
            let (_, data) = value.try_extract_tensor::<f32>()?;
            out.push(data.to_vec());
        }
        Ok(out)
    }
}
