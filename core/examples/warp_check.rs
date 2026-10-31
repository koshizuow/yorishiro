//! Our warps against OpenCV's on the same decoded picture (saved by Python):
//!     cargo run --release --example warp_check -- <npz>
use yorishiro_core::data::Npz;
use yorishiro_core::image::{Border, Image};
use yorishiro_core::inference::{crop_eye, roi_matrix, Roi};
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let mut z = Npz::open(std::path::Path::new(&a[1])).unwrap();
    let (rgb, shape) = z.f64s("rgb").unwrap();
    let img = Image { width: shape[1] as usize, height: shape[0] as usize, rgb: rgb.iter().map(|&v| v as u8).collect() };
    let r = z.f64s("roi").unwrap().0;
    let roi = Roi { center: [r[0], r[1]], size: r[2], angle: r[3] };
    let compare = |name: &str, ours: &Image, theirs: &[f64]| {
        let (mut n, mut max) = (0, 0.0f64);
        for (x, y) in ours.rgb.iter().zip(theirs) {
            let d = (*x as f64 - y).abs();
            n += (d > 0.0) as usize;
            max = max.max(d);
        }
        println!("{name}: {n} of {} values differ, largest {max}", theirs.len());
    };
    compare("landmark crop", &img.warp_affine(&roi_matrix(&roi), 256, 256, Border::Constant), &z.f64s("crop").unwrap().0);
    let lm: Vec<[f64; 3]> = z.f64s("landmarks").unwrap().0.chunks(3).map(|c| [c[0], c[1], c[2]]).collect();
    compare("left eye crop", &crop_eye(&img, &lm, 0), &z.f64s("eye0").unwrap().0);
    compare("right eye crop", &crop_eye(&img, &lm, 1), &z.f64s("eye1").unwrap().0);
}
