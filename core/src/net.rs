//! A network on any of the core's runtimes, by its file stem (<stem>.onnx for ONNX Runtime,
//! <stem>.ncnn.param / .bin for ncnn), as the Python tracker's backends.factory.open_model.

use crate::backend::{Error, OrtModel, Provider};
use std::path::Path;

/// Where a network runs.
#[derive(Clone, Debug, PartialEq)]
pub enum Runtime {
    /// ONNX Runtime CPU (the reference)
    OrtCpu,
    /// ONNX Runtime with CUDA (fp32) or TensorRT (fp16)
    Ort(Provider),
    /// ncnn on the first Vulkan GPU, fp16 or fp32
    #[cfg(feature = "ncnn")]
    Vulkan { fp16: bool },
    /// ncnn on the CPU
    #[cfg(feature = "ncnn")]
    NcnnCpu,
}

pub enum Net {
    Ort(OrtModel),
    #[cfg(feature = "ncnn")]
    Ncnn(crate::ncnn::NcnnModel),
}

impl Net {
    pub fn open(stem: &Path, runtime: &Runtime, threads: usize) -> Result<Self, Error> {
        let onnx = stem.with_extension("onnx");
        Ok(match runtime {
            Runtime::OrtCpu => Net::Ort(OrtModel::open(&onnx, threads)?),
            Runtime::Ort(p) => Net::Ort(OrtModel::open_on(&onnx, threads, p)?),
            #[cfg(feature = "ncnn")]
            Runtime::Vulkan { fp16 } => Net::Ncnn(crate::ncnn::NcnnModel::open(stem, true, *fp16, threads)?),
            #[cfg(feature = "ncnn")]
            Runtime::NcnnCpu => Net::Ncnn(crate::ncnn::NcnnModel::open(stem, false, false, threads)?),
        })
    }

    /// e.g. "ort-cpu-fp32", "ncnn-<GPU name>-fp16"
    pub fn name(&self) -> String {
        match self {
            Net::Ort(m) => m.name.clone(),
            #[cfg(feature = "ncnn")]
            Net::Ncnn(m) => m.name.clone(),
        }
    }

    /// One NCHW image input (c, h, w); the outputs in order (ONNX Runtime's, or ncnn's out0, out1, ...).
    pub fn run(&mut self, c: usize, h: usize, w: usize, data: Vec<f32>) -> Result<Vec<Vec<f32>>, Error> {
        match self {
            Net::Ort(m) => m.run(&[1, c as i64, h as i64, w as i64], data),
            #[cfg(feature = "ncnn")]
            Net::Ncnn(m) => {
                let mut out = m.run(c, h, w, data)?;
                // pnnx names outputs out0, out1, ... in the ONNX model's order
                out.sort_by_key(|(name, _)| name.trim_start_matches("out").parse::<usize>().unwrap_or(usize::MAX));
                Ok(out.into_iter().map(|(_, v)| v).collect())
            }
        }
    }
}
