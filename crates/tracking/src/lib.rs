//! Yorishiro's face tracking core: camera (V4L2) or a replayed recording, MediaPipe's face detector and
//! landmarks (ncnn on Vulkan, or the CPU), the landmark -> ARKit 52 fit, eyes, gaze, head pose, neutral
//! calibration, smoothing and the VTube Studio style inputs. Hands beside the face, outputs to other apps.
//!
//! It began as a stage by stage port of the Python tracker (retired, in git history), held to that tracker's
//! golden outputs (tests/golden.rs and the others, with the private test data). Numbers follow the Python
//! code: f64 math, rounded to f32 where Python stored float32 arrays, so the two agree to a few 1e-6.

pub mod backend;
pub mod camera;
pub mod data;
pub mod fit;
pub mod frame;
pub mod hands;
pub mod glare;
pub mod tracker;
pub mod image;
pub mod inference;
pub mod net;
#[cfg(feature = "ncnn")]
pub mod ncnn;
pub mod pipeline;
pub mod pose;
pub mod recording;
pub mod sinks;
pub mod smooth;
pub mod vts;

/// A 3D point.
pub type P3 = [f64; 3];

/// Rounds through f32 like the Python code's float32 arrays.
#[inline]
pub(crate) fn f32r(x: f64) -> f64 {
    x as f32 as f64
}
