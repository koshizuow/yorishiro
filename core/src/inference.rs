//! The image side of the tracker: MediaPipe's face detector (when tracking is lost), FaceMesh-V2 landmarks
//! with ROI tracking from the previous landmarks, MediaPipe's blendshape model for the mouth and jaw, and
//! the eye openness model (mediapipe_ncnn/detector.py, landmarks.py, facemesh.py,
//! adapters/mediapipe_blendshapes.py, adapters/eye_openness.py).

use crate::backend::{Error, OrtModel};
use crate::frame::arkit;
use crate::image::{invert_affine, Affine, Border, Image};
use crate::P3;
use std::path::Path;

const DET_INPUT: usize = 128;
const DET_SCORE: f64 = 0.5;
const LM_INPUT: usize = 256;
const ROI_SCALE: f64 = 1.5;
/// eye corners used for the in-plane rotation of the landmark crop
const RIGHT_EYE_OUTER: usize = 33;
const LEFT_EYE_OUTER: usize = 263;
/// sigmoid 0.5, MediaPipe's default minimum tracking confidence
const PRESENCE_LOGIT: f32 = 0.0;

/// A rotated square crop: centre (image pixels), side length, angle (radians).
#[derive(Clone, Copy, Debug)]
pub struct Roi {
    pub center: [f64; 2],
    pub size: f64,
    pub angle: f64,
}

/// SSD anchors of BlazeFace short range: strides 8, 16, 16, 16, fixed size, offset 0.5.
fn anchors() -> Vec<[f64; 2]> {
    let mut out = vec![];
    for (stride, per_cell) in [(8, 2), (16, 6)] {
        let n = DET_INPUT / stride;
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

pub struct Detector {
    model: OrtModel,
    anchors: Vec<[f64; 2]>,
}

impl Detector {
    pub fn open(path: &Path) -> Result<Self, Error> {
        Ok(Self { model: OrtModel::open(path, 1)?, anchors: anchors() })
    }

    /// The best face as the landmark model's crop, or None.
    pub fn detect(&mut self, img: &Image) -> Result<Option<Roi>, Error> {
        let s = DET_INPUT as f64 / img.width.max(img.height) as f64;
        let (nw, nh) = ((img.width as f64 * s).round() as usize, (img.height as f64 * s).round() as usize);
        let (px, py) = ((DET_INPUT - nw) as f64 / 2.0, (DET_INPUT - nh) as f64 / 2.0);
        let small = img.resize_area(nw, nh);
        let mut canvas = Image::new(DET_INPUT, DET_INPUT);
        let (ox, oy) = (px as usize, py as usize);
        for y in 0..nh {
            let src = &small.rgb[y * nw * 3..(y + 1) * nw * 3];
            let at = ((oy + y) * DET_INPUT + ox) * 3;
            canvas.rgb[at..at + nw * 3].copy_from_slice(src);
        }
        let out = self.model.run(&[1, 3, DET_INPUT as i64, DET_INPUT as i64], canvas.to_nchw(1.0 / 127.5, -1.0))?;
        let (regressors, scores) = (&out[0], &out[1]);
        let (best, logit) = scores.iter().enumerate().fold((0, f32::MIN), |b, (i, &v)| if v > b.1 { (i, v) } else { b });
        let logit = (logit as f64).clamp(-100.0, 100.0);
        if 1.0 / (1.0 + (-logit).exp()) < DET_SCORE {
            return Ok(None);
        }
        let r: Vec<f64> = regressors[best * 16..best * 16 + 16].iter().map(|&v| v as f64 / DET_INPUT as f64).collect();
        let a = self.anchors[best];
        let to_img = |x: f64, y: f64| [(x * DET_INPUT as f64 - ox as f64) / s, (y * DET_INPUT as f64 - oy as f64) / s];
        let center = to_img(r[0] + a[0], r[1] + a[1]);
        // keypoints 0 and 1: the subject's right and left eye
        let e0 = to_img(r[4] + a[0], r[5] + a[1]);
        let e1 = to_img(r[6] + a[0], r[7] + a[1]);
        let angle = (e1[1] - e0[1]).atan2(e1[0] - e0[0]);
        // MediaPipe's face landmark ROI: square on the long side, scaled 1.5
        let size = r[2].max(r[3]) * DET_INPUT as f64 / s * 1.5;
        Ok(Some(Roi { center, size, angle }))
    }
}

/// Image pixels into the LM_INPUT x LM_INPUT crop.
pub fn roi_matrix(roi: &Roi) -> Affine {
    let k = LM_INPUT as f64 / roi.size;
    let (c, s) = ((-roi.angle).cos() * k, (-roi.angle).sin() * k);
    let half = LM_INPUT as f64 / 2.0;
    [[c, -s, half - (c * roi.center[0] - s * roi.center[1])], [s, c, half - (s * roi.center[0] + c * roi.center[1])]]
}

/// Rotated square ROI around landmark pixels, levelled on the eye corners.
pub fn roi_from_landmarks(px: &[P3]) -> Roi {
    let d = [px[LEFT_EYE_OUTER][0] - px[RIGHT_EYE_OUTER][0], px[LEFT_EYE_OUTER][1] - px[RIGHT_EYE_OUTER][1]];
    let angle = d[1].atan2(d[0]);
    let (c, s) = ((-angle).cos(), (-angle).sin());
    let bounds = |pts: &mut dyn Iterator<Item = [f64; 2]>| {
        let (mut lo, mut hi) = ([f64::MAX; 2], [f64::MIN; 2]);
        for p in pts {
            for k in 0..2 {
                lo[k] = lo[k].min(p[k]);
                hi[k] = hi[k].max(p[k]);
            }
        }
        (lo, hi)
    };
    let (lo0, hi0) = bounds(&mut px.iter().map(|p| [p[0], p[1]]));
    let center0 = [(lo0[0] + hi0[0]) / 2.0, (lo0[1] + hi0[1]) / 2.0];
    // into the levelled frame around center0
    let (lo, hi) = bounds(&mut px.iter().map(|p| {
        let (x, y) = (p[0] - center0[0], p[1] - center0[1]);
        [c * x - s * y, s * x + c * y]
    }));
    let mid = [(lo[0] + hi[0]) / 2.0, (lo[1] + hi[1]) / 2.0];
    // back: the inverse rotation is the transpose
    let center = [center0[0] + c * mid[0] + s * mid[1], center0[1] - s * mid[0] + c * mid[1]];
    let size = (hi[0] - lo[0]).max(hi[1] - lo[1]) * ROI_SCALE;
    Roi { center, size, angle }
}

pub struct FaceMesh {
    detector: Detector,
    landmarker: OrtModel,
    pub roi: Option<Roi>,
    /// times the detector ran
    pub detections: usize,
    /// the mirrored crop is also run and the two estimates averaged (see facemesh.py FLIP_MAX_PASS_MS)
    pub flip_mirror: Option<Vec<usize>>,
}

/// One frame's landmark result.
pub struct Landmarks {
    /// normalized image coordinates, MediaPipe convention (z in x's scale)
    pub points: Vec<P3>,
    pub presence: f32,
    /// the crop the landmarks came from
    pub roi: Roi,
}

/// Landmarks and the crop they give for the next frame.
pub struct Tracked {
    pub landmarks: Landmarks,
    pub next_roi: Roi,
}

impl FaceMesh {
    pub fn open(models: &Path, threads: usize) -> Result<Self, Error> {
        Ok(Self {
            detector: Detector::open(&models.join("face_detector.onnx"))?,
            landmarker: OrtModel::open(&models.join("face_landmarks.onnx"), threads)?,
            roi: None,
            detections: 0,
            flip_mirror: None,
        })
    }

    fn landmarks_in(&mut self, crop: &Image) -> Result<(Vec<f32>, f32), Error> {
        let out = self.landmarker.run(&[1, 3, LM_INPUT as i64, LM_INPUT as i64], crop.to_nchw(1.0 / 255.0, 0.0))?;
        Ok((out[0].clone(), out[1][0]))
    }

    pub fn process(&mut self, img: &Image) -> Result<Option<Landmarks>, Error> {
        for _ in 0..2 {
            if self.roi.is_none() {
                self.detections += 1;
                self.roi = self.detector.detect(img)?;
                if self.roi.is_none() {
                    return Ok(None);
                }
            }
            let roi = self.roi.unwrap();
            if let Some(found) = self.landmarks_at(img, roi)? {
                self.roi = Some(found.next_roi);
                return Ok(Some(found.landmarks));
            }
            self.roi = None; // lost track, re-detect once on this frame
        }
        Ok(None)
    }

    /// The landmark model on one crop, without the tracking around it: the landmarks when the model sees a
    /// face, and the next frame's crop from them.
    pub fn landmarks_at(&mut self, img: &Image, roi: Roi) -> Result<Option<Tracked>, Error> {
        let (w, h) = (img.width as f64, img.height as f64);
        {
            let m = roi_matrix(&roi);
            let crop = img.warp_affine(&m, LM_INPUT, LM_INPUT, Border::Constant);
            let (mut raw, presence) = self.landmarks_in(&crop)?;
            if presence > PRESENCE_LOGIT {
                if let Some(mirror) = self.flip_mirror.clone() {
                    let (flipped, _) = self.landmarks_in(&crop.flip_horizontal())?;
                    for i in 0..478 {
                        let j = mirror[i];
                        raw[i * 3] = (raw[i * 3] + (LM_INPUT as f32 - flipped[j * 3])) / 2.0;
                        raw[i * 3 + 1] = (raw[i * 3 + 1] + flipped[j * 3 + 1]) / 2.0;
                        raw[i * 3 + 2] = (raw[i * 3 + 2] + flipped[j * 3 + 2]) / 2.0;
                    }
                }
                let inv = invert_affine(&m);
                let scale = inv[0][0].hypot(inv[1][0]); // crop pixel -> image pixel
                let mut points = Vec::with_capacity(478);
                let mut px = Vec::with_capacity(478);
                for i in 0..478 {
                    let (x, y, z) = (raw[i * 3] as f64, raw[i * 3 + 1] as f64, raw[i * 3 + 2] as f64);
                    let ix = inv[0][0] * x + inv[0][1] * y + inv[0][2];
                    let iy = inv[1][0] * x + inv[1][1] * y + inv[1][2];
                    // float32 like the Python output, z normalized by the image width as MediaPipe does
                    let p = [(ix / w) as f32 as f64, (iy / h) as f32 as f64, (z * scale / w) as f32 as f64];
                    px.push([p[0] * w, p[1] * h, p[2] * w]);
                    points.push(p);
                }
                let next_roi = roi_from_landmarks(&px);
                return Ok(Some(Tracked { landmarks: Landmarks { points, presence, roi }, next_roi }));
            }
        }
        Ok(None)
    }
}

/// Landmarks MediaPipe's blendshape model reads (face_blendshapes_graph.cc kLandmarksSubsetIdxs).
const BLEND_SUBSET: [usize; 146] = [
    0, 1, 4, 5, 6, 7, 8, 10, 13, 14, 17, 21, 33, 37, 39, 40, 46, 52, 53, 54, 55, 58, 61, 63, 65, 66, 67, 70, 78,
    80, 81, 82, 84, 87, 88, 91, 93, 95, 103, 105, 107, 109, 127, 132, 133, 136, 144, 145, 146, 148, 149, 150,
    152, 153, 154, 155, 157, 158, 159, 160, 161, 162, 163, 168, 172, 173, 176, 178, 181, 185, 191, 195, 197,
    234, 246, 249, 251, 263, 267, 269, 270, 276, 282, 283, 284, 285, 288, 291, 293, 295, 296, 297, 300, 308,
    310, 311, 312, 314, 317, 318, 321, 323, 324, 332, 334, 336, 338, 356, 361, 362, 365, 373, 374, 375, 377,
    378, 379, 380, 381, 382, 384, 385, 386, 387, 388, 389, 390, 397, 398, 400, 402, 405, 409, 415, 454, 466,
    468, 469, 470, 471, 472, 473, 474, 475, 476, 477,
];
/// The model's outputs after _neutral, in its order.
const BLEND_OUTPUTS: [&str; 51] = [
    "browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight",
    "cheekPuff", "cheekSquintLeft", "cheekSquintRight", "eyeBlinkLeft", "eyeBlinkRight", "eyeLookDownLeft",
    "eyeLookDownRight", "eyeLookInLeft", "eyeLookInRight", "eyeLookOutLeft", "eyeLookOutRight", "eyeLookUpLeft",
    "eyeLookUpRight", "eyeSquintLeft", "eyeSquintRight", "eyeWideLeft", "eyeWideRight", "jawForward", "jawLeft",
    "jawOpen", "jawRight", "mouthClose", "mouthDimpleLeft", "mouthDimpleRight", "mouthFrownLeft",
    "mouthFrownRight", "mouthFunnel", "mouthLeft", "mouthLowerDownLeft", "mouthLowerDownRight",
    "mouthPressLeft", "mouthPressRight", "mouthPucker", "mouthRight", "mouthRollLower", "mouthRollUpper",
    "mouthShrugLower", "mouthShrugUpper", "mouthSmileLeft", "mouthSmileRight", "mouthStretchLeft",
    "mouthStretchRight", "mouthUpperUpLeft", "mouthUpperUpRight", "noseSneerLeft", "noseSneerRight",
];

pub struct Blendshapes {
    model: OrtModel,
    to_arkit: Vec<usize>,
}

impl Blendshapes {
    pub fn open(path: &Path) -> Result<Self, Error> {
        Ok(Self { model: OrtModel::open(path, 1)?, to_arkit: BLEND_OUTPUTS.iter().map(|n| arkit(n)).collect() })
    }

    /// ARKit 52 from normalized image landmarks.
    pub fn run(&mut self, lm: &[P3], width: f64, height: f64) -> Result<[f64; 52], Error> {
        let mut pts = Vec::with_capacity(146 * 2);
        for &i in &BLEND_SUBSET {
            pts.push((lm[i][0] as f32) * width as f32);
            pts.push((lm[i][1] as f32) * height as f32);
        }
        let out = self.model.run(&[1, 146, 2], pts)?;
        let mut bs = [0.0; 52];
        for (k, &a) in self.to_arkit.iter().enumerate() {
            bs[a] = out[0][k + 1] as f64;
        }
        Ok(bs)
    }
}

/// Is an ARKit shape taken from MediaPipe's model (mouth and jaw) instead of the ICT fit?
pub fn from_blendshape_model(name: &str) -> bool {
    name.starts_with("mouth") || name.starts_with("jaw")
}

const EYE_W: usize = 64;
const EYE_H: usize = 40;
const SPAN_W: f64 = 1.8;
const SPAN_H: f64 = 1.1;
/// inner and outer corner, subject's left then right eye
const EYE_CORNERS: [(usize, usize); 2] = [(362, 263), (133, 33)];

/// The eye model's crop: a box between the corners, rotated level, 1.8 eye widths by 1.1, the subject's right
/// eye mirrored so both look like a left eye.
pub fn crop_eye(img: &Image, lm: &[P3], side: usize) -> Image {
    let (w, h) = (img.width as f64, img.height as f64);
    let (a, b) = EYE_CORNERS[side];
    let mut inner = [lm[a][0] * w, lm[a][1] * h];
    let mut outer = [lm[b][0] * w, lm[b][1] * h];
    let mirror = side == 1;
    if mirror {
        std::mem::swap(&mut inner, &mut outer);
    }
    let center = [(inner[0] + outer[0]) / 2.0, (inner[1] + outer[1]) / 2.0];
    let d = [outer[0] - inner[0], outer[1] - inner[1]];
    let width = d[0].hypot(d[1]);
    let ux = [d[0] / width.max(1e-6), d[1] / width.max(1e-6)];
    let uy = [-ux[1], ux[0]];
    // the crop's corner (0, 0) and its axes in image pixels; the matrix maps image pixels into the crop
    let (hw, hh) = (width * SPAN_W / 2.0, width * SPAN_H / 2.0);
    let origin = [center[0] - ux[0] * hw - uy[0] * hh, center[1] - ux[1] * hw - uy[1] * hh];
    let (sx, sy) = (EYE_W as f64 / (2.0 * hw), EYE_H as f64 / (2.0 * hh));
    let m: Affine = [
        [ux[0] * sx, ux[1] * sx, -(ux[0] * origin[0] + ux[1] * origin[1]) * sx],
        [uy[0] * sy, uy[1] * sy, -(uy[0] * origin[0] + uy[1] * origin[1]) * sy],
    ];
    let out = img.warp_affine(&m, EYE_W, EYE_H, Border::Replicate);
    if mirror { out.flip_horizontal() } else { out }
}

pub struct Eyes {
    model: OrtModel,
}

impl Eyes {
    pub fn open(path: &Path) -> Result<Self, Error> {
        Ok(Self { model: OrtModel::open(path, 1)? })
    }

    /// (left, right) openness, subject's sides: 0 closed, about 1 open
    pub fn run(&mut self, img: &Image, lm: &[P3]) -> Result<[f64; 2], Error> {
        let mut data = vec![];
        for side in 0..2 {
            // the model was trained on OpenCV's BGR crops
            let crop = crop_eye(img, lm, side);
            let n = EYE_W * EYE_H;
            let mut chw = vec![0.0f32; 3 * n];
            for i in 0..n {
                for c in 0..3 {
                    chw[c * n + i] = crop.rgb[i * 3 + (2 - c)] as f32;
                }
            }
            data.extend(chw);
        }
        let out = self.model.run(&[2, 3, EYE_H as i64, EYE_W as i64], data)?;
        Ok([out[0][0] as f64, out[0][1] as f64])
    }
}

/// Each eye's corner distance in pixels: a turned head shows the far eye short, behind the nose.
pub fn eye_widths(lm: &[P3], width: f64, height: f64) -> [f64; 2] {
    EYE_CORNERS.map(|(a, b)| ((lm[a][0] - lm[b][0]) * width).hypot((lm[a][1] - lm[b][1]) * height))
}

