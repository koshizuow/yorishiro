//! Which float32 warpAffine formulation is OpenCV 5's? cargo run --release --example warp_variants -- <npz>
use yorishiro_core::data::Npz;
use yorishiro_core::image::{invert_affine, Image};
use yorishiro_core::inference::{roi_matrix, Roi};

fn warp(img: &Image, m: &[[f64; 3]; 2], w: usize, h: usize, variant: u8) -> Vec<u8> {
    let inv = invert_affine(m);
    let mf: Vec<f32> = [inv[0][0], inv[0][1], inv[0][2], inv[1][0], inv[1][1], inv[1][2]].iter().map(|&v| v as f32).collect();
    let (iw, ih) = (img.width as i64, img.height as i64);
    let px = |x: i64, y: i64, c: usize| -> f32 {
        if x < 0 || y < 0 || x >= iw || y >= ih { 0.0 } else { img.rgb[((y * iw + x) * 3) as usize + c] as f32 }
    };
    let mut out = vec![0u8; w * h * 3];
    for oy in 0..h {
        for ox in 0..w {
            let (fx, fy) = (ox as f32, oy as f32);
            let (sx, sy) = match variant {
                0 | 1 | 2 => (mf[0] * fx + mf[1] * fy + mf[2], mf[3] * fx + mf[4] * fy + mf[5]),
                3 => ((mf[0] * fx + (mf[1] * fy + mf[2])), (mf[3] * fx + (mf[4] * fy + mf[5]))),
                _ => (mf[0].mul_add(fx, mf[1].mul_add(fy, mf[2])), mf[3].mul_add(fx, mf[4].mul_add(fy, mf[5]))),
            };
            let (x0, y0) = (sx.floor(), sy.floor());
            let (ax, ay) = (sx - x0, sy - y0);
            let (x0, y0) = (x0 as i64, y0 as i64);
            for c in 0..3 {
                let (p00, p01, p10, p11) = (px(x0, y0, c), px(x0 + 1, y0, c), px(x0, y0 + 1, c), px(x0 + 1, y0 + 1, c));
                let v = match variant {
                    0 | 3 | 4 => { let a = p00 + ax * (p01 - p00); let b = p10 + ax * (p11 - p10); a + ay * (b - a) }
                    5 => { let a = ax.mul_add(p01 - p00, p00); let b = ax.mul_add(p11 - p10, p10); ay.mul_add(b - a, a) }
                    1 => ((1.0 - ax) * p00 + ax * p01) * (1.0 - ay) + ((1.0 - ax) * p10 + ax * p11) * ay,
                    _ => (1.0 - ax) * (1.0 - ay) * p00 + ax * (1.0 - ay) * p01 + (1.0 - ax) * ay * p10 + ax * ay * p11,
                };
                out[(oy * w + ox) * 3 + c] = v.round_ties_even().clamp(0.0, 255.0) as u8;
            }
        }
    }
    out
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let mut z = Npz::open(std::path::Path::new(&a[1])).unwrap();
    let (rgb, shape) = z.f64s("rgb").unwrap();
    let img = Image { width: shape[1] as usize, height: shape[0] as usize, rgb: rgb.iter().map(|&v| v as u8).collect() };
    let r = z.f64s("roi").unwrap().0;
    let roi = Roi { center: [r[0], r[1]], size: r[2], angle: r[3] };
    let theirs = z.f64s("crop").unwrap().0;
    for v in 0..6u8 {
        let ours = warp(&img, &roi_matrix(&roi), 256, 256, v);
        let n = ours.iter().zip(&theirs).filter(|(x, y)| (**x as f64 - **y).abs() > 0.0).count();
        println!("variant {v}: {n} of {} differ", theirs.len());
    }
}
