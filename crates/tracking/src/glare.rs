//! Screen reflections on glasses (adapters/lens_glare.py): per eye, the share of a box around it that is light
//! and tinted unlike the skin of the cheek below. The app uses it to tell the user and to put glasses on its
//! preview head. CIELAB here is the float formula with OpenCV's 8 bit scaling (L * 255 / 100, a and b + 128);
//! OpenCV's own 8 bit path uses tables, so shares can differ by a few pixels' worth.

use crate::image::Image;
use crate::P3;

/// inner and outer eye corner, a cheek point below the eye; subject's left then right
const EYES: [(usize, usize, usize); 2] = [(362, 263, 425), (133, 33, 205)];

fn srgb_to_linear(c: f64) -> f64 {
    if c <= 0.04045 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
}

fn lab_f(t: f64) -> f64 {
    if t > 0.008856 { t.cbrt() } else { 7.787 * t + 16.0 / 116.0 }
}

/// 8 bit CIELAB as OpenCV scales it.
pub fn rgb_to_lab8(rgb: &[u8]) -> [f64; 3] {
    let [r, g, b] = [rgb[0], rgb[1], rgb[2]].map(|v| srgb_to_linear(v as f64 / 255.0));
    let x = (0.412453 * r + 0.357580 * g + 0.180423 * b) / 0.950456;
    let y = 0.212671 * r + 0.715160 * g + 0.072169 * b;
    let z = (0.019334 * r + 0.119193 * g + 0.950227 * b) / 1.088754;
    let l = if y > 0.008856 { 116.0 * y.cbrt() - 16.0 } else { 903.3 * y };
    let (fx, fy, fz) = (lab_f(x), lab_f(y), lab_f(z));
    [
        (l * 255.0 / 100.0).round().clamp(0.0, 255.0),
        (500.0 * (fx - fy) + 128.0).round().clamp(0.0, 255.0),
        (200.0 * (fy - fz) + 128.0).round().clamp(0.0, 255.0),
    ]
}

/// CIELAB pixels of a box around center, as numpy slicing clips it.
fn lab_box(img: &Image, center: [f64; 2], half_w: f64, half_h: f64) -> Vec<[f64; 3]> {
    let (x, y) = (center[0] as i64, center[1] as i64);
    let (a, b) = ((half_w as i64).max(1), (half_h as i64).max(1));
    let (x0, x1) = ((x - a).max(0), (x + a).min(img.width as i64));
    let (y0, y1) = ((y - b).max(0), (y + b).min(img.height as i64));
    let mut out = vec![];
    for yy in y0..y1 {
        for xx in x0..x1 {
            let i = (yy as usize * img.width + xx as usize) * 3;
            out.push(rgb_to_lab8(&img.rgb[i..i + 3]));
        }
    }
    out
}

/// numpy's percentile with linear interpolation.
fn percentile(v: &mut [f64], q: f64) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let pos = q / 100.0 * (v.len() - 1) as f64;
    let (lo, hi) = (pos.floor() as usize, pos.ceil() as usize);
    v[lo] + (v[hi] - v[lo]) * (pos - lo as f64)
}

/// (left, right) share of each eye box that looks like a reflection.
pub fn lens_glare(img: &Image, lm: &[P3]) -> [f64; 2] {
    let (w, h) = (img.width as f64, img.height as f64);
    let pt = |i: usize| [lm[i][0] * w, lm[i][1] * h];
    EYES.map(|(inner, outer, cheek)| {
        let (pi, po) = (pt(inner), pt(outer));
        let eye_w = (pi[0] - po[0]).hypot(pi[1] - po[1]);
        let skin = lab_box(img, pt(cheek), 0.25 * eye_w, 0.25 * eye_w);
        let eye = lab_box(img, [(pi[0] + po[0]) / 2.0, (pi[1] + po[1]) / 2.0], 0.75 * eye_w, 0.45 * eye_w);
        if skin.len() < 4 || eye.len() < 4 {
            return 0.0;
        }
        let med: [f64; 3] = [0, 1, 2].map(|k| {
            let mut v: Vec<f64> = skin.iter().map(|p| p[k]).collect();
            crate::fit::median(&mut v)
        });
        let mut dist: Vec<f64> = skin.iter().map(|p| ((p[0] - med[0]).powi(2) + (p[1] - med[1]).powi(2) + (p[2] - med[2]).powi(2)).sqrt()).collect();
        let spread = percentile(&mut dist, 90.0) + 4.0;
        let hits = eye.iter().filter(|p| {
            let chroma = ((p[1] - med[1]).powi(2) + (p[2] - med[2]).powi(2)).sqrt();
            chroma > 2.5 * spread && p[0] > med[0] - 10.0
        }).count();
        hits as f64 / eye.len() as f64
    })
}
