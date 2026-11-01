//! Running the networks: ONNX Runtime through the `ort` crate, loaded at run time (load-dynamic) from a
//! libonnxruntime next to the extension (the official CPU build), so the core itself carries no runtime.
//! The GPU path is ncnn with Vulkan (ncnn.rs).

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

/// One network on ONNX Runtime.
pub struct OrtModel {
    session: Session,
    /// "ort-cpu-fp32"
    pub name: String,
}

impl OrtModel {
    pub fn open(path: &Path, threads: usize) -> Result<Self, Error> {
        let env = runtime(None)?;
        // idle worker threads would otherwise spin between frames (the Python backend turns it off too)
        let mut builder = Session::builder(env)?.with_intra_threads(threads).map_err(ort::Error::<()>::from)?
            .with_intra_op_spinning(false).map_err(ort::Error::<()>::from)?;
        let session = builder.commit_from_file(path)?;
        Ok(Self { session, name: "ort-cpu-fp32".into() })
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
