//! The few image operations the tracker needs, written out instead of linking OpenCV: area resize (for the
//! detector's letterbox) and bilinear affine warps (landmark and eye crops). They follow OpenCV's
//! definitions: INTER_AREA's exact overlaps, and warpAffine's float32 arithmetic as OpenCV 5 does it, so
//! crops come out as OpenCV's do.

use std::path::Path;

/// An RGB picture, 8 bits per channel, rows top to bottom.
#[derive(Clone)]
pub struct Image {
    pub width: usize,
    pub height: usize,
    pub rgb: Vec<u8>,
}

#[derive(Clone, Copy, PartialEq)]
pub enum Border {
    /// outside is black
    Constant,
    /// outside repeats the nearest edge pixel
    Replicate,
}

/// 2x3 affine matrix [[a, b, c], [d, e, f]] mapping (x, y) to (a x + b y + c, d x + e y + f).
pub type Affine = [[f64; 3]; 2];

pub fn invert_affine(m: &Affine) -> Affine {
    let det = m[0][0] * m[1][1] - m[0][1] * m[1][0];
    let d = if det != 0.0 { 1.0 / det } else { 0.0 };
    let a = m[1][1] * d;
    let b = -m[0][1] * d;
    let c = -m[1][0] * d;
    let e = m[0][0] * d;
    [[a, b, -a * m[0][2] - b * m[1][2]], [c, e, -c * m[0][2] - e * m[1][2]]]
}

impl Image {
    pub fn new(width: usize, height: usize) -> Self {
        Self { width, height, rgb: vec![0; width * height * 3] }
    }

    pub fn load(path: &Path) -> Result<Self, String> {
        let img = image::open(path).map_err(|e| format!("{}: {e}", path.display()))?.to_rgb8();
        Ok(Self { width: img.width() as usize, height: img.height() as usize, rgb: img.into_raw() })
    }

    #[inline]
    fn px(&self, x: usize, y: usize) -> &[u8] {
        let i = (y * self.width + x) * 3;
        &self.rgb[i..i + 3]
    }

    /// OpenCV's INTER_AREA: each output pixel averages the input area it covers, partial pixels weighted.
    pub fn resize_area(&self, nw: usize, nh: usize) -> Image {
        let sx = self.width as f64 / nw as f64;
        let sy = self.height as f64 / nh as f64;
        let spans = |n: usize, scale: f64, limit: usize| -> Vec<Vec<(usize, f64)>> {
            (0..n)
                .map(|o| {
                    let (lo, hi) = (o as f64 * scale, ((o + 1) as f64 * scale).min(limit as f64));
                    let mut v = vec![];
                    let mut i = lo.floor() as usize;
                    while (i as f64) < hi && i < limit {
                        let w = ((i + 1) as f64).min(hi) - (i as f64).max(lo);
                        if w > 1e-9 {
                            v.push((i, w));
                        }
                        i += 1;
                    }
                    v
                })
                .collect()
        };
        let xs = spans(nw, sx, self.width);
        let ys = spans(nh, sy, self.height);
        let mut out = Image::new(nw, nh);
        for (oy, yspan) in ys.iter().enumerate() {
            for (ox, xspan) in xs.iter().enumerate() {
                let mut acc = [0.0f64; 3];
                let mut total = 0.0;
                for &(iy, wy) in yspan {
                    for &(ix, wx) in xspan {
                        let w = wx * wy;
                        let p = self.px(ix, iy);
                        for c in 0..3 {
                            acc[c] += p[c] as f64 * w;
                        }
                        total += w;
                    }
                }
                let o = (oy * nw + ox) * 3;
                for c in 0..3 {
                    out.rgb[o + c] = (acc[c] / total).round().clamp(0.0, 255.0) as u8;
                }
            }
        }
        out
    }

    /// OpenCV's warpAffine with INTER_LINEAR on 8 bit pictures: m maps this image's pixels into the output's.
    /// OpenCV 4.11 and later (5.0 in the tracker) work in float32: the source position as M0 x + (M1 y + M2),
    /// interpolated along x then y, rounded half to even. Matches it on all but a few values in 200 000
    /// (by one grey level).
    pub fn warp_affine(&self, m: &Affine, w: usize, h: usize, border: Border) -> Image {
        let inv = invert_affine(m);
        let f: [f32; 6] = [inv[0][0] as f32, inv[0][1] as f32, inv[0][2] as f32, inv[1][0] as f32, inv[1][1] as f32, inv[1][2] as f32];
        let mut out = Image::new(w, h);
        let (iw, ih) = (self.width as i64, self.height as i64);
        let sample = |x: i64, y: i64, c: usize| -> f32 {
            match border {
                Border::Constant if x < 0 || y < 0 || x >= iw || y >= ih => 0.0,
                Border::Constant => self.px(x as usize, y as usize)[c] as f32,
                Border::Replicate => self.px(x.clamp(0, iw - 1) as usize, y.clamp(0, ih - 1) as usize)[c] as f32,
            }
        };
        for oy in 0..h {
            let (rx, ry) = (f[1] * oy as f32 + f[2], f[4] * oy as f32 + f[5]);
            for ox in 0..w {
                let (sx, sy) = (f[0] * ox as f32 + rx, f[3] * ox as f32 + ry);
                let (x0, y0) = (sx.floor(), sy.floor());
                let (ax, ay) = (sx - x0, sy - y0);
                let (x0, y0) = (x0 as i64, y0 as i64);
                if border == Border::Constant && (x0 < -1 || y0 < -1 || x0 >= iw || y0 >= ih) {
                    continue; // all four neighbours outside
                }
                let o = (oy * w + ox) * 3;
                for c in 0..3 {
                    let (p00, p01) = (sample(x0, y0, c), sample(x0 + 1, y0, c));
                    let (p10, p11) = (sample(x0, y0 + 1, c), sample(x0 + 1, y0 + 1, c));
                    let a = p00 + ax * (p01 - p00);
                    let b = p10 + ax * (p11 - p10);
                    out.rgb[o + c] = (a + ay * (b - a)).round_ties_even().clamp(0.0, 255.0) as u8;
                }
            }
        }
        out
    }

    /// NCHW float tensor data (1, 3, h, w), RGB scaled by `scale` then shifted by `offset`.
    pub fn to_nchw(&self, scale: f32, offset: f32) -> Vec<f32> {
        let n = self.width * self.height;
        let mut out = vec![0.0f32; 3 * n];
        for i in 0..n {
            for c in 0..3 {
                out[c * n + i] = self.rgb[i * 3 + c] as f32 * scale + offset;
            }
        }
        out
    }

    /// Mirrored left to right.
    pub fn flip_horizontal(&self) -> Image {
        let mut out = self.clone();
        for y in 0..self.height {
            for x in 0..self.width {
                let (a, b) = ((y * self.width + x) * 3, (y * self.width + self.width - 1 - x) * 3);
                out.rgb[a..a + 3].copy_from_slice(&self.rgb[b..b + 3]);
            }
        }
        out
    }
}
