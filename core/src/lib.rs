//! Yorishiro's face tracking core (Phase B, D21/D32): the Python tracker's landmark -> ARKit 52 -> VTube
//! Studio style input pipeline, ported stage by stage and held to golden outputs written by
//! `tracker/tools/export_core.py` (tests/golden.rs).
//!
//! B1 covers the geometry and math: landmark smoothing, rigid alignment, the ICT expression fit with its
//! regional solves, eyelids, gaze, head pose and position, neutral calibration, frame smoothing and the
//! VTS inputs. Inference (landmarks, eye model, MediaPipe's mouth blendshapes) and the camera follow in B2/B3.
//!
//! Numbers follow the Python code: f64 math, rounded to f32 where Python stores float32 arrays, so the
//! two agree to a few 1e-6.

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
