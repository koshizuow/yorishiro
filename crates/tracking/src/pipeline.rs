//! The tracker's per-frame loop after the landmarks (trackers/facemesh_gpu.py process, serve.py): smoothing,
//! fit, a provisional neutral from the first face, the real one from a window of frames once tracking has
//! settled, neutral removal, frame smoothing. Matches tools/export_core.py's golden loop.

use crate::fit::{head_position, mouth_gap, Fitter};
use crate::frame::FaceFrame;
use crate::pose::{eye_rotations_from_blendshapes, rotation_to_ypr, ypr_to_rotation};
use crate::smooth::{FrameSmoother, LandmarkSmoother};
use crate::{f32r, P3};
use nalgebra::Matrix3;

/// The first frames use the detector's crop; the neutral window starts after this many faces.
pub const SETTLE_FACES: usize = 30;
/// The neutral is the median over this many faces.
pub const CALIBRATE_FACES: usize = 24;

/// Everything one frame produced, for the app and for the golden tests.
pub struct Output {
    pub smoothed: Vec<P3>,
    pub aligned: Vec<P3>,
    pub rotation: Matrix3<f64>,
    /// before neutral removal and smoothing
    pub frame: FaceFrame,
    /// what goes to the app
    pub final_frame: FaceFrame,
    /// the neutral window finished with this frame
    pub calibrated: bool,
}

/// Removes the per-session neutral: camera placement for the pose, resting values for the blendshapes.
#[derive(Default)]
pub struct NeutralCalibration {
    neutral: Option<FaceFrame>,
    rot: Matrix3<f64>,
}

impl NeutralCalibration {
    pub fn is_set(&self) -> bool {
        self.neutral.is_some()
    }

    pub fn set(&mut self, frame: FaceFrame) {
        self.rot = ypr_to_rotation(frame.head_rotation);
        self.neutral = Some(frame);
    }

    /// Per-channel median over a window, the resting values without the blinks and words in it.
    pub fn set_many(&mut self, frames: &[FaceFrame]) {
        let med = |get: &dyn Fn(&FaceFrame) -> f64| {
            let mut v: Vec<f64> = frames.iter().map(get).collect();
            f32r(crate::fit::median(&mut v))
        };
        let mut n = frames.last().unwrap().clone();
        for i in 0..52 {
            n.blendshapes[i] = med(&|f| f.blendshapes[i]);
        }
        for k in 0..3 {
            n.head_rotation[k] = med(&|f| f.head_rotation[k]);
            n.head_translation[k] = med(&|f| f.head_translation[k]);
            n.left_eye_rotation[k] = med(&|f| f.left_eye_rotation[k]);
            n.right_eye_rotation[k] = med(&|f| f.right_eye_rotation[k]);
        }
        self.set(n);
    }

    pub fn apply(&self, frame: &FaceFrame) -> FaceFrame {
        let Some(n) = &self.neutral else { return frame.clone() };
        let mut out = frame.clone();
        for i in 0..52 {
            let v = (frame.blendshapes[i] - n.blendshapes[i]) / (1.0 - n.blendshapes[i]).max(1e-3);
            out.blendshapes[i] = f32r(v.clamp(0.0, 1.0));
        }
        // left-multiply: the offset comes from camera placement, so remove it in camera space
        out.head_rotation = rotation_to_ypr(&(self.rot.transpose() * ypr_to_rotation(frame.head_rotation)));
        for k in 0..3 {
            out.head_translation[k] = f32r(frame.head_translation[k] - n.head_translation[k]);
            out.left_eye_rotation[k] = f32r(frame.left_eye_rotation[k] - n.left_eye_rotation[k]);
            out.right_eye_rotation[k] = f32r(frame.right_eye_rotation[k] - n.right_eye_rotation[k]);
        }
        out
    }
}

/// What the image side adds to a frame, computed from the smoothed landmarks (eye model, MediaPipe's
/// blendshape model, lens glare); all optional, the fit falls back to the lid gap and its own mouth.
#[derive(Default, Clone)]
pub struct Extras {
    /// the eye model's openness, subject's left and right
    pub eye_open: Option<[f64; 2]>,
    /// MediaPipe's blendshapes; mouth and jaw are taken from them
    pub mouth: Option<[f64; 52]>,
    pub lens_glare: Option<[f64; 2]>,
    /// each eye's corner distance in pixels, for the hidden eye rule
    pub eye_widths: Option<[f64; 2]>,
}

/// A far eye shorter than this share of the near one (head turned) is behind the nose: it takes the near
/// eye's openness, scaled by the two neutrals.
pub const HIDDEN_EYE_WIDTH: f64 = 0.55;

pub struct Pipeline {
    pub fitter: Fitter,
    smoother: LandmarkSmoother,
    calibration: NeutralCalibration,
    frame_smoother: FrameSmoother,
    faces: usize,
    window: Option<Vec<(Vec<P3>, Extras, FaceFrame)>>,
}

impl Pipeline {
    pub fn new(fitter: Fitter) -> Self {
        Self {
            fitter,
            smoother: LandmarkSmoother::default(),
            calibration: NeutralCalibration::default(),
            frame_smoother: FrameSmoother::default(),
            faces: 0,
            window: None,
        }
    }

    /// No face this frame.
    pub fn lost(&mut self) {
        self.smoother.reset();
    }

    /// Ask for a new neutral (the app's calibrate command): a window starts with the next face.
    pub fn recalibrate(&mut self) {
        self.window = Some(vec![]);
    }

    fn blendshapes(&mut self, aligned: &[P3], extras: &Extras) -> [f64; 52] {
        let mut e = self.fitter.expressions(aligned, extras.eye_open);
        if let Some(mouth) = extras.mouth {
            for (i, name) in crate::frame::ARKIT52.iter().enumerate() {
                if crate::inference::from_blendshape_model(name) {
                    e[i] = f32r(mouth[i]);
                }
            }
        }
        let g = self.fitter.gaze(aligned);
        let mut bs = [0.0; 52];
        for i in 0..52 {
            bs[i] = f32r(e[i] + g[i]);
        }
        bs
    }

    /// landmarks: 478 normalized image points (x, y in 0..1, z in x's scale)
    pub fn process(&mut self, landmarks: &[P3], width: f64, height: f64, timestamp_ms: i64) -> Output {
        self.process_with(landmarks, width, height, timestamp_ms, &mut |_| Extras::default())
    }

    /// As process, with the image side: extras gets the smoothed landmarks.
    pub fn process_with(&mut self, landmarks: &[P3], width: f64, height: f64, timestamp_ms: i64,
                        extras: &mut dyn FnMut(&[P3]) -> Extras) -> Output {
        let smoothed = self.smoother.apply(landmarks, timestamp_ms as f64 / 1000.0);
        let (aligned, rot) = self.fitter.align(&smoothed, width, height);
        let mut extra = extras(&smoothed);
        if let (Some(mut open), Some(widths)) = (extra.eye_open, extra.eye_widths) {
            let n = self.fitter.eye_neutral;
            for (far, near) in [(0, 1), (1, 0)] {
                if widths[far] < HIDDEN_EYE_WIDTH * widths[near] {
                    open[far] = open[near] * n[far] / n[near];
                }
            }
            extra.eye_open = Some(open);
        }
        if !self.fitter.calibrated {
            self.fitter.calibrate(&aligned, extra.eye_open);
        }
        let bs = self.blendshapes(&aligned, &extra);
        let (le, re) = eye_rotations_from_blendshapes(&bs);
        let frame = FaceFrame {
            timestamp_ms,
            blendshapes: bs,
            head_rotation: rotation_to_ypr(&rot),
            head_translation: head_position(&smoothed, width, height, &rot),
            left_eye_rotation: le,
            right_eye_rotation: re,
            mouth_gap: Some(mouth_gap(&smoothed, width, height)),
            lens_glare: extra.lens_glare,
        };
        self.faces += 1;
        if self.faces == SETTLE_FACES {
            self.window = Some(vec![]);
        }
        let mut calibrated = false;
        if let Some(window) = &mut self.window {
            window.push((aligned.clone(), extra.clone(), frame.clone()));
            if window.len() == CALIBRATE_FACES {
                let window = self.window.take().unwrap();
                let points: Vec<Vec<P3>> = window.iter().map(|(a, _, _)| a.clone()).collect();
                let eyes: Vec<[f64; 2]> = window.iter().filter_map(|(_, x, _)| x.eye_open).collect();
                self.fitter.calibrate_many(&points, Some(&eyes));
                // the window's frames again against the new neutral
                let mut redone = vec![];
                for (a, x, f) in &window {
                    let (a2, dr) = self.fitter.realign(a);
                    let b2 = self.blendshapes(&a2, x);
                    let (l2, r2) = eye_rotations_from_blendshapes(&b2);
                    let head = rotation_to_ypr(&(ypr_to_rotation(f.head_rotation) * dr.transpose()));
                    redone.push(FaceFrame { blendshapes: b2, head_rotation: head, left_eye_rotation: l2,
                                            right_eye_rotation: r2, ..f.clone() });
                }
                self.calibration.set_many(&redone);
                self.frame_smoother.reset();
                calibrated = true;
            }
        } else if !self.calibration.is_set() {
            self.calibration.set(frame.clone());
        }
        let final_frame = self.frame_smoother.apply(&self.calibration.apply(&frame));
        Output { smoothed, aligned, rotation: rot, frame, final_frame, calibrated }
    }
}
