//! Running the networks on the CPU: tract (pure Rust, ONNX), built into the core. Until 2026-11-18 this was ONNX
//! Runtime's official build, loaded at run time; its GitHub repository and release assets went offline that day, and
//! tract gives the same outputs (largest difference on our six models 3.2e-4 of a landmark pixel, the blendshapes
//! 1.3e-6) with nothing to download or ship. The GPU path is ncnn with Vulkan (ncnn.rs).

use std::path::Path;
use tract_onnx::prelude::*;

pub type Error = Box<dyn std::error::Error + Send + Sync>;

/// One network on the CPU. tract optimizes a model for one input shape: the plan is made at the first run and again
/// when the shape changes.
pub struct CpuModel {
    proto: InferenceModel,
    plan: Option<(Vec<usize>, std::sync::Arc<TypedSimplePlan>)>,
    /// "cpu-fp32"
    pub name: String,
}

impl CpuModel {
    /// threads: tract runs a network on the calling thread; kept for the callers that pass it
    pub fn open(path: &Path, _threads: usize) -> Result<Self, Error> {
        let proto = tract_onnx::onnx().model_for_path(path).map_err(|e| format!("{}: {e}", path.display()))?;
        Ok(Self { proto, plan: None, name: "cpu-fp32".into() })
    }

    /// One input tensor in, every output as flat f32 in the model's output order.
    pub fn run(&mut self, shape: &[i64], data: Vec<f32>) -> Result<Vec<Vec<f32>>, Error> {
        let shape: Vec<usize> = shape.iter().map(|&d| d as usize).collect();
        if self.plan.as_ref().map(|(s, _)| s != &shape).unwrap_or(true) {
            let plan = self.proto.clone().with_input_fact(0, f32::fact(&shape).into())?.into_optimized()?.into_runnable()?;
            self.plan = Some((shape.clone(), plan));
        }
        let input: Tensor = tract_ndarray::ArrayD::from_shape_vec(shape, data)?.into();
        let outputs = self.plan.as_ref().unwrap().1.run(tvec!(input.into()))?;
        let mut out = vec![];
        for v in outputs.iter() {
            out.push(v.to_plain_array_view::<f32>()?.iter().copied().collect());
        }
        Ok(out)
    }
}
