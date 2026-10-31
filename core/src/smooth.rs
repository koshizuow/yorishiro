//! Filters: MediaPipe's landmark smoothing (adapters/landmark_smoother.py) and the per-group One Euro of
//! the finished frame (processing.py FrameSmoother).

use crate::frame::FaceFrame;
use crate::{f32r, P3};
use std::f64::consts::PI;

fn alpha(cutoff: f64, dt: f64) -> f64 {
    let tau = 1.0 / (2.0 * PI * cutoff);
    1.0 / (1.0 + tau / dt)
}

/// One Euro per landmark coordinate, velocity in face sizes per second, MediaPipe's Face Landmarker settings.
pub struct LandmarkSmoother {
    min_cutoff: f64,
    beta: f64,
    d_cutoff: f64,
    raw: Vec<P3>,
    x: Vec<P3>,
    dx: Vec<P3>,
    t: Option<f64>,
}

impl Default for LandmarkSmoother {
    fn default() -> Self {
        Self { min_cutoff: 0.05, beta: 80.0, d_cutoff: 1.0, raw: vec![], x: vec![], dx: vec![], t: None }
    }
}

impl LandmarkSmoother {
    pub fn reset(&mut self) {
        self.t = None;
    }

    /// landmarks: normalized image coordinates, t in seconds
    pub fn apply(&mut self, lm: &[P3], t: f64) -> Vec<P3> {
        match self.t {
            Some(t0) if t > t0 => {}
            _ => {
                self.raw = lm.to_vec();
                self.x = lm.to_vec();
                self.dx = vec![[0.0; 3]; lm.len()];
                self.t = Some(t);
                return lm.to_vec();
            }
        }
        let dt = t - self.t.unwrap();
        // face size: the landmark box's mean side
        let (mut lo, mut hi) = ([f64::MAX; 2], [f64::MIN; 2]);
        for p in lm {
            for k in 0..2 {
                lo[k] = lo[k].min(p[k]);
                hi[k] = hi[k].max(p[k]);
            }
        }
        let size = ((hi[0] - lo[0]) + (hi[1] - lo[1])) / 2.0;
        let scale = if size > 1e-6 { 1.0 / size } else { 0.0 };
        let a_d = alpha(self.d_cutoff, dt);
        for (i, p) in lm.iter().enumerate() {
            for k in 0..3 {
                let d = (p[k] - self.raw[i][k]) * scale / dt;
                self.dx[i][k] += a_d * (d - self.dx[i][k]);
                let a = alpha(self.min_cutoff + self.beta * self.dx[i][k].abs(), dt);
                self.x[i][k] += a * (p[k] - self.x[i][k]);
            }
        }
        self.raw = lm.to_vec();
        self.t = Some(t);
        self.x.clone()
    }
}

/// One Euro filter (Casiez et al. 2012) over a vector, driven by timestamps in seconds.
pub struct OneEuro {
    min_cutoff: f64,
    beta: f64,
    d_cutoff: f64,
    x: Vec<f64>,
    dx: Vec<f64>,
    t: Option<f64>,
}

impl OneEuro {
    pub fn new(min_cutoff: f64, beta: f64) -> Self {
        Self { min_cutoff, beta, d_cutoff: 1.0, x: vec![], dx: vec![], t: None }
    }

    pub fn reset(&mut self) {
        self.t = None;
    }

    pub fn apply(&mut self, x: &[f64], t: f64) -> Vec<f64> {
        match self.t {
            Some(t0) if t > t0 => {}
            _ => {
                self.x = x.to_vec();
                self.dx = vec![0.0; x.len()];
                self.t = Some(t);
                return x.to_vec();
            }
        }
        let dt = t - self.t.unwrap();
        let a_d = alpha(self.d_cutoff, dt);
        for i in 0..x.len() {
            let d = (x[i] - self.x[i]) / dt;
            self.dx[i] = a_d * d + (1.0 - a_d) * self.dx[i];
            let a = alpha(self.min_cutoff + self.beta * self.dx[i].abs(), dt);
            self.x[i] = a * x[i] + (1.0 - a) * self.x[i];
        }
        self.t = Some(t);
        self.x.clone()
    }
}

/// Per-group One Euro settings. Units: blendshapes 0..1, angles in radians, translation in metres.
pub struct FrameSmoother {
    bs: OneEuro,
    head: OneEuro,
    eyes: OneEuro,
    trans: OneEuro,
}

impl Default for FrameSmoother {
    fn default() -> Self {
        Self {
            bs: OneEuro::new(1.5, 4.0),
            head: OneEuro::new(1.0, 0.6),
            eyes: OneEuro::new(2.0, 1.5),
            trans: OneEuro::new(1.0, 2.0),
        }
    }
}

impl FrameSmoother {
    pub fn reset(&mut self) {
        for f in [&mut self.bs, &mut self.head, &mut self.eyes, &mut self.trans] {
            f.reset();
        }
    }

    pub fn apply(&mut self, frame: &FaceFrame) -> FaceFrame {
        let t = frame.timestamp_ms as f64 / 1000.0;
        let mut eyes_in = frame.left_eye_rotation.to_vec();
        eyes_in.extend_from_slice(&frame.right_eye_rotation);
        let eyes = self.eyes.apply(&eyes_in, t);
        let bs = self.bs.apply(&frame.blendshapes, t);
        let head = self.head.apply(&frame.head_rotation, t);
        let trans = self.trans.apply(&frame.head_translation, t);
        let mut out = frame.clone();
        for i in 0..52 {
            out.blendshapes[i] = f32r(bs[i].clamp(0.0, 1.0));
        }
        for k in 0..3 {
            out.head_rotation[k] = f32r(head[k]);
            out.head_translation[k] = f32r(trans[k]);
            out.left_eye_rotation[k] = f32r(eyes[k]);
            out.right_eye_rotation[k] = f32r(eyes[k + 3]);
        }
        out
    }
}
