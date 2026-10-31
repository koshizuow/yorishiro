//! Hand tracking (tracker/src/yorishiro_tracker/mediapipe_ncnn/hands.py): MediaPipe's palm detector while fewer
//! hands are tracked than wanted, a rotated crop around each palm or around the previous landmarks, 21
//! landmarks with handedness and world points, then finger bends and the Hand* inputs VTube Studio models bind.

use crate::backend::Error;
use crate::image::{Affine, Border, Image};
use crate::net::{Net, Runtime};
use crate::P3;
use nalgebra::{Matrix3, Matrix2x3};
use std::f64::consts::PI;
use std::path::Path;

const PALM_INPUT: usize = 192;
const LANDMARK_INPUT: usize = 224;
const PALM_SCORE: f64 = 0.5;
const PRESENCE_SCORE: f64 = 0.5;
const NMS_IOU: f64 = 0.3;
// MediaPipe's hand landmarker crops: around the palm box, and around the previous landmarks
const PALM_SCALE: f64 = 2.6;
const PALM_SHIFT_Y: f64 = -0.5;
const TRACK_SCALE: f64 = 2.0;
const TRACK_SHIFT_Y: f64 = -0.1;
/// landmarks the tracking crop is fitted to: wrist, thumb base, finger bases
const CROP_POINTS: [usize; 7] = [0, 1, 2, 5, 9, 13, 17];
pub const WRIST: usize = 0;
pub const MIDDLE_MCP: usize = 9;
/// base to tip
pub const FINGERS: [(&str, [usize; 4]); 5] = [
    ("Thumb", [1, 2, 3, 4]),
    ("Index", [5, 6, 7, 8]),
    ("Middle", [9, 10, 11, 12]),
    ("Ring", [13, 14, 15, 16]),
    ("Pinky", [17, 18, 19, 20]),
];

/// A crop: centre (image pixels), side, angle (radians, 0 with the hand pointing up).
pub type Roi = ([f64; 2], f64, f64);

#[derive(Clone, Debug)]
pub struct Hand {
    /// image pixels, z in the same scale relative to the wrist
    pub landmarks: Vec<P3>,
    /// metres, around the hand's centre
    pub world: Vec<P3>,
    /// the person's right hand
    pub right: bool,
    pub score: f64,
    pub roi: Roi,
}

fn anchors() -> Vec<[f64; 2]> {
    let mut out = vec![];
    for (stride, per_cell) in [(8, 2), (16, 6)] {
        let n = PALM_INPUT / stride;
        for y in 0..n {
            for x in 0..n {
                for _ in 0..per_cell {
                    out.push([(x as f64 + 0.5) / n as f64, (y as f64 + 0.5) / n as f64]);
                }
            }
        }
    }
    out
}

fn sigmoid(x: f64) -> f64 {
    1.0 / (1.0 + (-x.clamp(-100.0, 100.0)).exp())
}

fn iou(a: [f64; 4], b: [f64; 4]) -> f64 {
    let (x0, y0, x1, y1) = (a[0].max(b[0]), a[1].max(b[1]), a[2].min(b[2]), a[3].min(b[3]));
    let inter = (x1 - x0).max(0.0) * (y1 - y0).max(0.0);
    let union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter;
    if union > 0.0 { inter / union } else { 0.0 }
}

/// OpenCV's getAffineTransform: the affine map taking three points onto three others (inputs float32 like
/// the Python code's np.float32 arrays, solved in f64).
fn affine_from_points(src: [[f64; 2]; 3], dst: [[f64; 2]; 3]) -> Affine {
    let r = |v: f64| v as f32 as f64;
    let p = Matrix3::new(r(src[0][0]), r(src[1][0]), r(src[2][0]), r(src[0][1]), r(src[1][1]), r(src[2][1]), 1.0, 1.0, 1.0);
    let q = Matrix2x3::new(r(dst[0][0]), r(dst[1][0]), r(dst[2][0]), r(dst[0][1]), r(dst[1][1]), r(dst[2][1]));
    let m = q * p.try_inverse().unwrap_or(Matrix3::identity());
    [[m[(0, 0)], m[(0, 1)], m[(0, 2)]], [m[(1, 0)], m[(1, 1)], m[(1, 2)]]]
}

/// Move a crop along its own vertical axis (negative: towards the fingers), MediaPipe's RectTransformation.
fn shift(center: [f64; 2], size: f64, angle: f64, shift_y: f64) -> [f64; 2] {
    [center[0] - shift_y * size * angle.sin(), center[1] + shift_y * size * angle.cos()]
}

/// Square crop around landmark pixels, rotated so the wrist-to-middle-finger line points up.
fn roi_from(points: &[P3], scale: f64, shift_y: f64) -> Roi {
    let (a, b) = (points[WRIST], points[MIDDLE_MCP]);
    let angle = (b[1] - a[1]).atan2(b[0] - a[0]) + PI / 2.0;
    let (c, s) = ((-angle).cos(), (-angle).sin());
    let (mut lo, mut hi) = ([f64::MAX; 2], [f64::MIN; 2]);
    for &i in &CROP_POINTS {
        let p = points[i];
        let l = [c * p[0] - s * p[1], s * p[0] + c * p[1]];
        for k in 0..2 {
            lo[k] = lo[k].min(l[k]);
            hi[k] = hi[k].max(l[k]);
        }
    }
    let size = (hi[0] - lo[0]).max(hi[1] - lo[1]);
    let mid = [(lo[0] + hi[0]) / 2.0, (lo[1] + hi[1]) / 2.0];
    // the inverse rotation is the transpose
    let center = [c * mid[0] + s * mid[1], -s * mid[0] + c * mid[1]];
    (shift(center, size, angle, shift_y), size * scale, angle)
}

pub struct HandTracker {
    palm: Net,
    landmark: Net,
    anchors: Vec<[f64; 2]>,
    pub max_hands: usize,
    pub tracked: Vec<Hand>,
    pub runtime: String,
}

impl HandTracker {
    /// models: the folder with palm_detection_full and hand_landmark_full (.onnx, .ncnn.*)
    pub fn open(models: &Path, runtime: &Runtime, threads: usize) -> Result<Self, Error> {
        let landmark = Net::open(&models.join("hand_landmark_full"), runtime, threads)?;
        let name = landmark.name();
        Ok(Self { palm: Net::open(&models.join("palm_detection_full"), runtime, threads)?, landmark, anchors: anchors(),
                  max_hands: 2, tracked: vec![], runtime: name })
    }

    pub fn reset(&mut self) {
        self.tracked.clear();
    }

    /// Crops for the landmark model from the palm detector.
    pub fn detect_palms(&mut self, img: &Image) -> Result<Vec<Roi>, Error> {
        let s = PALM_INPUT as f64 / img.width.max(img.height) as f64;
        let (nw, nh) = ((img.width as f64 * s).round() as usize, (img.height as f64 * s).round() as usize);
        let (px, py) = ((PALM_INPUT - nw) / 2, (PALM_INPUT - nh) / 2);
        let small = img.resize_area(nw, nh);
        let mut canvas = Image::new(PALM_INPUT, PALM_INPUT);
        for y in 0..nh {
            let at = ((py + y) * PALM_INPUT + px) * 3;
            canvas.rgb[at..at + nw * 3].copy_from_slice(&small.rgb[y * nw * 3..(y + 1) * nw * 3]);
        }
        let out = self.palm.run(3, PALM_INPUT, PALM_INPUT, canvas.to_nchw(1.0 / 255.0, 0.0))?;
        let (boxes, scores) = (&out[0], &out[1]);
        let mut keep: Vec<(usize, f64)> = scores.iter().enumerate().map(|(i, &v)| (i, sigmoid(v as f64)))
            .filter(|(_, p)| *p >= PALM_SCORE).collect();
        keep.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
        let mut found: Vec<([f64; 4], [f64; 2], f64, [[f64; 2]; 7])> = vec![];
        let to_img = |v: [f64; 2]| [(v[0] * PALM_INPUT as f64 - px as f64) / s, (v[1] * PALM_INPUT as f64 - py as f64) / s];
        for (i, _) in keep {
            let r: Vec<f64> = boxes[i * 18..i * 18 + 18].iter().map(|&v| v as f64 / PALM_INPUT as f64).collect();
            let a = self.anchors[i];
            let (cx, cy, bw, bh) = (r[0] + a[0], r[1] + a[1], r[2], r[3]);
            let bx = [cx - bw / 2.0, cy - bh / 2.0, cx + bw / 2.0, cy + bh / 2.0];
            if found.iter().any(|f| iou(bx, f.0) > NMS_IOU) {
                continue;
            }
            let mut kp = [[0.0; 2]; 7];
            for k in 0..7 {
                kp[k] = to_img([r[4 + k * 2] + a[0], r[5 + k * 2] + a[1]]);
            }
            found.push((bx, to_img([cx, cy]), bw.max(bh) * PALM_INPUT as f64 / s, kp));
        }
        Ok(found.into_iter().take(self.max_hands).map(|(_, center, size, kp)| {
            // wrist (0) to middle finger base (2) points up
            let angle = (kp[2][1] - kp[0][1]).atan2(kp[2][0] - kp[0][0]) + PI / 2.0;
            (shift(center, size, angle, PALM_SHIFT_Y), size * PALM_SCALE, angle)
        }).collect())
    }

    /// The landmark model on one crop, None when it sees no hand there.
    pub fn landmarks(&mut self, img: &Image, roi: Roi) -> Result<Option<Hand>, Error> {
        let (center, size, angle) = roi;
        let (c, s) = (angle.cos(), angle.sin());
        let half = size / 2.0;
        let (ux, uy) = ([c * half, s * half], [-s * half, c * half]);
        let src = [
            [center[0] - ux[0] - uy[0], center[1] - ux[1] - uy[1]],
            [center[0] + ux[0] - uy[0], center[1] + ux[1] - uy[1]],
            [center[0] - ux[0] + uy[0], center[1] - ux[1] + uy[1]],
        ];
        let n = LANDMARK_INPUT as f64;
        let dst = [[0.0, 0.0], [n, 0.0], [0.0, n]];
        let m = affine_from_points(src, dst);
        let back = affine_from_points(dst, src);
        let crop = img.warp_affine(&m, LANDMARK_INPUT, LANDMARK_INPUT, Border::Constant);
        let out = self.landmark.run(3, LANDMARK_INPUT, LANDMARK_INPUT, crop.to_nchw(1.0 / 255.0, 0.0))?;
        let mut score = out[1][0] as f64;
        if !(0.0..=1.0).contains(&score) {
            score = sigmoid(score);
        }
        if score < PRESENCE_SCORE {
            return Ok(None);
        }
        let mut right = out[2][0] as f64;
        if !(0.0..=1.0).contains(&right) {
            right = sigmoid(right);
        }
        let landmarks = (0..21).map(|k| {
            let (x, y, z) = (out[0][k * 3] as f64, out[0][k * 3 + 1] as f64, out[0][k * 3 + 2] as f64);
            [back[0][0] * x + back[0][1] * y + back[0][2], back[1][0] * x + back[1][1] * y + back[1][2], z * size / n]
        }).collect();
        let world = (0..21).map(|k| [out[3][k * 3] as f64, out[3][k * 3 + 1] as f64, out[3][k * 3 + 2] as f64]).collect();
        // above 0.5 is the person's right hand on camera pictures (checked on HaGRID, tools/eval_hands.py)
        Ok(Some(Hand { landmarks, world, right: right >= 0.5, score, roi }))
    }

    pub fn process(&mut self, img: &Image) -> Result<Vec<Hand>, Error> {
        let mut hands = vec![];
        for prev in std::mem::take(&mut self.tracked) {
            if let Some(h) = self.landmarks(img, roi_from(&prev.landmarks, TRACK_SCALE, TRACK_SHIFT_Y))? {
                hands.push(h);
            }
        }
        if hands.len() < self.max_hands {
            for roi in self.detect_palms(img)? {
                // a palm where a tracked hand already is, is that hand
                let taken = hands.iter().any(|h: &Hand| {
                    let m = h.landmarks[MIDDLE_MCP];
                    (roi.0[0] - m[0]).hypot(roi.0[1] - m[1]) < roi.1 * 0.25
                });
                if taken {
                    continue;
                }
                if let Some(h) = self.landmarks(img, roi)? {
                    hands.push(h);
                }
                if hands.len() >= self.max_hands {
                    break;
                }
            }
        }
        self.tracked = hands.clone();
        Ok(hands)
    }
}

/// 0 straight to 1 fully bent per finger, from the angles between its bones (world points).
pub fn finger_curl(hand: &Hand) -> [f64; 5] {
    let w = &hand.world;
    let sub = |a: P3, b: P3| [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
    FINGERS.map(|(name, [a, b, c, d])| {
        let chain: Vec<P3> = if name == "Thumb" { vec![w[a], w[b], w[c], w[d]] } else { vec![w[WRIST], w[a], w[b], w[c], w[d]] };
        let mut bend = 0.0;
        for i in 0..chain.len() - 2 {
            let (u, v) = (sub(chain[i + 1], chain[i]), sub(chain[i + 2], chain[i + 1]));
            let dot = u[0] * v[0] + u[1] * v[1] + u[2] * v[2];
            let norm = (u[0] * u[0] + u[1] * u[1] + u[2] * u[2]).sqrt() * (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
            bend += (dot / (norm + 1e-9)).clamp(-1.0, 1.0).acos();
        }
        // straight is 0; a fist bends a finger's three joints by about 250 degrees, a thumb about 120
        let full = if name == "Thumb" { 120f64 } else { 250f64 }.to_radians();
        (bend / full).clamp(0.0, 1.0)
    })
}

/// palm length (wrist to middle finger base) as a share of the image height that counts as depth 0
const PALM_AT_ZERO_DEPTH: f64 = 0.12;
const PALM_PER_DEPTH_UNIT: f64 = 0.006;

/// The Hand* inputs for the person's hands (hand_params in hands.py): positions -10..10 (+ outward, up,
/// nearer), angles in degrees, fingers 0 curled to 1 straight.
pub fn hand_params(hands: &[Hand], width: f64, height: f64) -> Vec<(String, f64)> {
    let mut out = vec![];
    let mut centers = vec![];
    for side in ["Left", "Right"] {
        let hand = hands.iter().find(|h| h.right == (side == "Right"));
        out.push((format!("Hand{side}Found"), if hand.is_some() { 1.0 } else { 0.0 }));
        let Some(hand) = hand else { continue };
        let lm = &hand.landmarks;
        let center = [(lm[WRIST][0] + lm[MIDDLE_MCP][0]) / 2.0, (lm[WRIST][1] + lm[MIDDLE_MCP][1]) / 2.0];
        centers.push(center);
        // the person's left hand is on the image's right; outward for it is towards the image's right
        let outward = if side == "Left" { 1.0 } else { -1.0 };
        let x = (center[0] / width * 2.0 - 1.0) * outward;
        let y = -(center[1] / height * 2.0 - 1.0);
        let palm = (lm[MIDDLE_MCP][0] - lm[WRIST][0]).hypot(lm[MIDDLE_MCP][1] - lm[WRIST][1]) / height;
        out.push((format!("Hand{side}PositionX"), (x * 10.0).clamp(-10.0, 10.0)));
        out.push((format!("Hand{side}PositionY"), (y * 10.0).clamp(-10.0, 10.0)));
        out.push((format!("Hand{side}PositionZ"), ((palm - PALM_AT_ZERO_DEPTH) / PALM_PER_DEPTH_UNIT).clamp(-10.0, 10.0)));
        let d = [lm[MIDDLE_MCP][0] - lm[WRIST][0], lm[MIDDLE_MCP][1] - lm[WRIST][1]];
        out.push((format!("Hand{side}AngleZ"), (d[0] * outward).atan2(-d[1]).to_degrees()));
        let w = &hand.world;
        let (a, b) = ([w[5][0] - w[0][0], w[5][1] - w[0][1], w[5][2] - w[0][2]], [w[17][0] - w[0][0], w[17][1] - w[0][1], w[17][2] - w[0][2]]);
        let mut normal = [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
        if side == "Left" {
            normal = normal.map(|v| -v); // the same palm side for both hands
        }
        out.push((format!("Hand{side}AngleX"), (normal[0] * outward).atan2(-normal[2]).to_degrees()));
        let curl = finger_curl(hand);
        for (i, (name, _)) in FINGERS.iter().enumerate() {
            out.push((format!("Hand{side}Finger_{}_{name}", i + 1), 1.0 - curl[i]));
        }
        out.push((format!("Hand{side}Open"), curl.iter().map(|c| 1.0 - c).sum::<f64>() / 5.0));
    }
    out.push(("BothHandsFound".into(), if centers.len() == 2 { 1.0 } else { 0.0 }));
    if centers.len() == 2 {
        out.push(("HandDistance".into(), (centers[0][0] - centers[1][0]).hypot(centers[0][1] - centers[1][1]) / width * 10.0));
    }
    out
}
