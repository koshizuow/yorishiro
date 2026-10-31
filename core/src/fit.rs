//! Landmarks to ARKit 52: rigid alignment, the ICT expression fit with regional solves, eyelids, gaze, head
//! position and mouth gap (adapters/ict_fit.py, adapters/mediapipe_points.py, adapters/vts_params.py
//! mouth_gap). The solver matrices come precomputed in the fit data.

use crate::data::{DataError, Npz};
use crate::frame::arkit;
use crate::{f32r, P3};
use nalgebra::{DMatrix, DVector, Matrix3, Vector3};
use std::path::Path;

// Iris centres and eye corners, subject's side (iris, inner, outer).
const LEFT_EYE: [usize; 3] = [473, 362, 263];
const RIGHT_EYE: [usize; 3] = [468, 133, 33];
/// Iris offset in eye widths that reads as a full look; vertical is noisier.
const GAZE_FULL_X: f64 = 0.18;
const GAZE_FULL_Y: f64 = 0.14;
/// Eyelids, subject's side: upper and lower lid points, inner and outer corner.
const LIDS: [(&str, [usize; 3], [usize; 3], usize, usize); 2] = [
    ("Left", [386, 385, 387], [374, 380, 373], 362, 263),
    ("Right", [159, 158, 160], [145, 153, 144], 133, 33),
];
const LID_CLOSED: f64 = 0.2;
const LID_WIDE: f64 = 1.35;
const LID_DEADBAND: f64 = 0.05;
/// Head position from the image alone: MediaPipe's own field of view and an average face size.
const CAMERA_FOV_Y_DEG: f64 = 63.0;
const RIGID_RADIUS_M: f64 = 0.0617;
const PIVOT_BEHIND_FACE_M: f64 = 0.09;

/// Umeyama: scale, rotation, translation minimizing |s R src + t - dst|.
pub fn similarity_transform(src: &[P3], dst: &[P3]) -> (f64, Matrix3<f64>, Vector3<f64>) {
    let n = src.len() as f64;
    let mean = |pts: &[P3]| pts.iter().fold(Vector3::zeros(), |a, p| a + Vector3::from(*p)) / n;
    let (mu_s, mu_d) = (mean(src), mean(dst));
    let mut cov = Matrix3::zeros();
    let mut var = 0.0;
    for (s, d) in src.iter().zip(dst) {
        let xs = Vector3::from(*s) - mu_s;
        let xd = Vector3::from(*d) - mu_d;
        cov += xd * xs.transpose();
        var += xs.norm_squared();
    }
    cov /= n;
    var /= n;
    // numpy returns the singular values in descending order; the sign fix goes on the smallest
    let svd = cov.svd(true, true);
    let (u0, vt0) = (svd.u.unwrap(), svd.v_t.unwrap());
    let mut order = [0usize, 1, 2];
    order.sort_by(|&a, &b| svd.singular_values[b].partial_cmp(&svd.singular_values[a]).unwrap());
    let mut u = Matrix3::zeros();
    let mut vt = Matrix3::zeros();
    let mut sig = Vector3::zeros();
    for (k, &i) in order.iter().enumerate() {
        u.set_column(k, &u0.column(i));
        vt.set_row(k, &vt0.row(i));
        sig[k] = svd.singular_values[i];
    }
    let mut d = Matrix3::identity();
    d[(2, 2)] = (u * vt).determinant().signum();
    let r = u * d * vt;
    let s = (sig[0] * d[(0, 0)] + sig[1] * d[(1, 1)] + sig[2] * d[(2, 2)]) / var;
    (s, r, mu_d - s * r * mu_s)
}

pub fn apply(s: f64, r: &Matrix3<f64>, t: &Vector3<f64>, pts: &[P3]) -> Vec<P3> {
    pts.iter().map(|p| (s * r * Vector3::from(*p) + t).into()).collect()
}

/// Bounded least squares for ICT expression weights in [0, 1] (FISTA, warm started).
pub struct Solver {
    a: DMatrix<f64>,
    h: DMatrix<f64>,
    step: f64,
    active: Vec<usize>,
    w: DVector<f64>,
    n_shapes: usize,
}

impl Solver {
    fn load(npz: &mut Npz, prefix: &str, n_shapes: usize) -> Result<Self, DataError> {
        let (a, sa) = npz.f64s(&format!("{prefix}_a"))?;
        let (h, sh) = npz.f64s(&format!("{prefix}_h"))?;
        let a = DMatrix::from_row_slice(sa[0] as usize, sa[1] as usize, &a);
        let h = DMatrix::from_row_slice(sh[0] as usize, sh[1] as usize, &h);
        let w = DVector::zeros(h.ncols());
        Ok(Self { a, h, step: npz.scalar(&format!("{prefix}_step"))?, active: npz.ints(&format!("{prefix}_active"))?, w, n_shapes })
    }

    pub fn reset(&mut self) {
        self.w.fill(0.0);
    }

    /// displacement: the region's points' motion from the neutral, flattened x, y, z per point
    pub fn solve(&mut self, displacement: &[f64], iters: usize) -> Vec<f64> {
        let g = self.a.tr_mul(&DVector::from_column_slice(displacement));
        let mut w = self.w.clone();
        let mut y = w.clone();
        let mut tk = 1.0f64;
        for _ in 0..iters {
            let mut w_next = &y - self.step * (&self.h * &y - &g);
            w_next.apply(|v| *v = v.clamp(0.0, 1.0));
            let tk_next = (1.0 + (1.0 + 4.0 * tk * tk).sqrt()) / 2.0;
            y = &w_next + (tk - 1.0) / tk_next * (&w_next - &w);
            w = w_next;
            tk = tk_next;
        }
        self.w = w;
        let mut full = vec![0.0; self.n_shapes];
        for (k, &i) in self.active.iter().enumerate() {
            full[i] = f32r(self.w[k]);
        }
        full
    }
}

struct Region {
    rows: Vec<usize>,
    taken: Vec<bool>,
    solver: Solver,
}

pub struct Fitter {
    pub reference: Vec<P3>,
    src_idx: Vec<usize>,
    rigid: Vec<usize>,
    solver: Solver,
    regions: Vec<Region>,
    arkit_of_shape: Vec<usize>,
    pub calibrated: bool,
    gaze_neutral: [f64; 4],
    lid_neutral: [f64; 2],
}

pub const FIT_ITERS: usize = 60;

impl Fitter {
    pub fn load(path: &Path) -> Result<Self, DataError> {
        let mut npz = Npz::open(path)?;
        let n_shapes = npz.scalar("n_shapes")? as usize;
        let (r, _) = npz.f64s("reference")?;
        let reference = r.chunks(3).map(|c| [c[0], c[1], c[2]]).collect();
        let mut regions = vec![];
        for i in 0..npz.scalar("n_regions")? as usize {
            regions.push(Region {
                rows: npz.ints(&format!("region{i}_rows"))?,
                taken: npz.ints(&format!("region{i}_taken"))?.into_iter().map(|x| x != 0).collect(),
                solver: Solver::load(&mut npz, &format!("region{i}"), n_shapes)?,
            });
        }
        Ok(Self {
            reference,
            src_idx: npz.ints("src_idx")?,
            rigid: npz.ints("rigid")?,
            solver: Solver::load(&mut npz, "main", n_shapes)?,
            regions,
            arkit_of_shape: npz.ints("arkit_of_shape")?,
            calibrated: false,
            gaze_neutral: [0.0; 4],
            lid_neutral: [1.0; 2],
        })
    }

    /// All 478 points rigidly aligned onto the reference, and the head rotation (face -> camera).
    pub fn align(&self, landmarks: &[P3], width: f64, height: f64) -> (Vec<P3>, Matrix3<f64>) {
        let pts = landmarks_to_points(landmarks, width, height);
        let src: Vec<P3> = self.rigid.iter().map(|&i| pts[i]).collect();
        let dst: Vec<P3> = self.rigid.iter().map(|&i| self.reference[i]).collect();
        let (s, r, t) = similarity_transform(&src, &dst);
        (apply(s, &r, &t, &pts), r.transpose())
    }

    /// Re-align points aligned to an older reference, and the rotation that took them there.
    pub fn realign(&self, aligned: &[P3]) -> (Vec<P3>, Matrix3<f64>) {
        let src: Vec<P3> = self.rigid.iter().map(|&i| aligned[i]).collect();
        let dst: Vec<P3> = self.rigid.iter().map(|&i| self.reference[i]).collect();
        let (s, r, t) = similarity_transform(&src, &dst);
        (apply(s, &r, &t, aligned), r)
    }

    pub fn calibrate(&mut self, aligned: &[P3]) {
        self.reference = aligned[..468].to_vec();
        self.gaze_neutral = iris_offsets(aligned);
        self.lid_neutral = [lid_gap(aligned, 0), lid_gap(aligned, 1)];
        self.solver.reset();
        for r in &mut self.regions {
            r.solver.reset();
        }
        self.calibrated = true;
    }

    /// Neutral = per-point median over a window of aligned frames.
    pub fn calibrate_many(&mut self, frames: &[Vec<P3>]) {
        let n = frames[0].len();
        let mut med = vec![[0.0; 3]; n];
        let mut vals = vec![0.0; frames.len()];
        for i in 0..n {
            for k in 0..3 {
                for (j, f) in frames.iter().enumerate() {
                    vals[j] = f[i][k];
                }
                med[i][k] = median(&mut vals);
            }
        }
        self.calibrate(&med);
    }

    /// ARKit 52 from the fit (eyeLook* zero, see gaze), blink and wide from the lid gap.
    pub fn expressions(&mut self, aligned: &[P3]) -> [f64; 52] {
        let mut disp = Vec::with_capacity(self.src_idx.len() * 3);
        for &i in &self.src_idx {
            for k in 0..3 {
                disp.push(aligned[i][k] - self.reference[i][k]);
            }
        }
        let mut w = self.solver.solve(&disp, FIT_ITERS);
        // the full solve keeps these shapes too, so a region's motion is not explained by other shapes
        for region in &mut self.regions {
            let sub: Vec<f64> = region.rows.iter().flat_map(|&r| disp[r * 3..r * 3 + 3].to_vec()).collect();
            let rw = region.solver.solve(&sub, FIT_ITERS);
            for (s, &taken) in region.taken.iter().enumerate() {
                if taken {
                    w[s] = rw[s];
                }
            }
        }
        let mut bs = [0.0f64; 52];
        for (s, &k) in self.arkit_of_shape.iter().enumerate() {
            bs[k] = bs[k].max(w[s]); // browInnerUp and cheekPuff come from two ICT shapes
        }
        for (i, (side, ..)) in LIDS.iter().enumerate() {
            let rel = lid_gap(aligned, i) / self.lid_neutral[i].max(1e-6);
            bs[arkit(&format!("eyeBlink{side}"))] =
                f32r(((1.0 - LID_DEADBAND - rel) / (1.0 - LID_DEADBAND - LID_CLOSED)).clamp(0.0, 1.0));
            bs[arkit(&format!("eyeWide{side}"))] =
                f32r(((rel - 1.0 - LID_DEADBAND) / (LID_WIDE - 1.0 - LID_DEADBAND)).clamp(0.0, 1.0));
        }
        bs
    }

    /// eyeLook* values from the iris landmarks, relative to the calibrated neutral.
    pub fn gaze(&self, aligned: &[P3]) -> [f64; 52] {
        let o = iris_offsets(aligned);
        let (lx, ly, rx, ry) = (o[0] - self.gaze_neutral[0], o[1] - self.gaze_neutral[1],
                                o[2] - self.gaze_neutral[2], o[3] - self.gaze_neutral[3]);
        let mut bs = [0.0f64; 52];
        let mut put = |name: &str, v: f64| bs[arkit(name)] = f32r(v.clamp(0.0, 1.0));
        // +x is the subject's left: the left eye looks out, the right eye looks in
        put("eyeLookOutLeft", lx / GAZE_FULL_X);
        put("eyeLookInLeft", -lx / GAZE_FULL_X);
        put("eyeLookInRight", rx / GAZE_FULL_X);
        put("eyeLookOutRight", -rx / GAZE_FULL_X);
        put("eyeLookUpLeft", ly / GAZE_FULL_Y);
        put("eyeLookDownLeft", -ly / GAZE_FULL_Y);
        put("eyeLookUpRight", ry / GAZE_FULL_Y);
        put("eyeLookDownRight", -ry / GAZE_FULL_Y);
        bs
    }
}

/// numpy's median: the middle value, or the mean of the two middle ones.
pub fn median(v: &mut [f64]) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = v.len();
    if n % 2 == 1 { v[n / 2] } else { (v[n / 2 - 1] + v[n / 2]) / 2.0 }
}

fn dist(a: P3, b: P3) -> f64 {
    ((a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2) + (a[2] - b[2]).powi(2)).sqrt()
}

fn mean_of(points: &[P3], idx: &[usize]) -> P3 {
    let mut m = [0.0; 3];
    for &i in idx {
        for k in 0..3 {
            m[k] += points[i][k];
        }
    }
    m.map(|x| x / idx.len() as f64)
}

fn lid_gap(points: &[P3], side: usize) -> f64 {
    let (_, upper, lower, inner, outer) = LIDS[side];
    dist(mean_of(points, &upper), mean_of(points, &lower)) / dist(points[inner], points[outer])
}

fn iris_offsets(aligned: &[P3]) -> [f64; 4] {
    let mut out = [0.0; 4];
    for (e, eye) in [LEFT_EYE, RIGHT_EYE].iter().enumerate() {
        let (a, b) = (aligned[eye[1]], aligned[eye[2]]);
        let width = dist(a, b);
        let iris = aligned[eye[0]];
        out[e * 2] = (iris[0] - (a[0] + b[0]) / 2.0) / width;
        out[e * 2 + 1] = (iris[1] - (a[1] + b[1]) / 2.0) / width;
    }
    out
}

/// Normalized image landmarks to a y-up, z-toward-camera point set (pixel units).
pub fn landmarks_to_points(lm: &[P3], width: f64, height: f64) -> Vec<P3> {
    lm.iter().map(|p| [p[0] * width, -p[1] * height, -p[2] * width]).collect()
}

/// MediaPipe's rigid points (nose, inner eye corners, sides of the head).
pub const MP_RIGID: [usize; 13] = [168, 6, 197, 195, 5, 4, 1, 133, 362, 127, 356, 234, 454];

/// Camera-space head position in metres (x right, y up, -z forward); rotation moves it behind the face.
pub fn head_position(lm: &[P3], width: f64, height: f64, rotation: &Matrix3<f64>) -> [f64; 3] {
    let pts: Vec<P3> = MP_RIGID.iter().map(|&i| [lm[i][0] * width, lm[i][1] * height, lm[i][2] * width]).collect();
    let center = mean_of(&pts, &(0..pts.len()).collect::<Vec<_>>());
    let radius = (pts.iter().map(|p| dist(*p, center).powi(2)).sum::<f64>() / pts.len() as f64).sqrt();
    let focal = (height / 2.0) / (CAMERA_FOV_Y_DEG.to_radians() / 2.0).tan();
    let d = focal * RIGID_RADIUS_M / radius.max(1e-6);
    let z = rotation.column(2);
    [
        f32r((center[0] - width / 2.0) * d / focal - PIVOT_BEHIND_FACE_M * z[0]),
        f32r(-(center[1] - height / 2.0) * d / focal - PIVOT_BEHIND_FACE_M * z[1]),
        f32r(-d - PIVOT_BEHIND_FACE_M * z[2]),
    ]
}

/// Inner lip gap over face height (landmarks 13-14 over 10-152).
pub fn mouth_gap(lm: &[P3], width: f64, height: f64) -> f64 {
    let s = [width, height, width];
    let scaled = |i: usize| [lm[i][0] * s[0], lm[i][1] * s[1], lm[i][2] * s[2]];
    let face = dist(scaled(10), scaled(152));
    if face > 1e-6 { dist(scaled(13), scaled(14)) / face } else { 0.0 }
}
