//! YUYV to RGB against OpenCV's COLOR_YUV2RGB_YUYV on random data (saved by Python):
//!     cargo run --release --example yuyv_check -- <npz>
use yorishiro_core::camera::yuyv_to_rgb;
use yorishiro_core::data::Npz;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let mut z = Npz::open(std::path::Path::new(&a[1])).unwrap();
    let yuyv: Vec<u8> = z.f64s("yuyv").unwrap().0.iter().map(|&v| v as u8).collect();
    let cv = z.f64s("rgb").unwrap().0;
    let ours = yuyv_to_rgb(&yuyv, 128, 64);
    let (mut n, mut max) = (0, 0.0f64);
    for (x, y) in ours.rgb.iter().zip(&cv) {
        let d = (*x as f64 - y).abs();
        n += (d > 0.0) as usize;
        max = max.max(d);
    }
    println!("{n} of {} values differ, largest {max}", cv.len());
}
