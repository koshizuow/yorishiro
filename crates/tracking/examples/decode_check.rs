//! Compare our JPEG decoding with OpenCV's (a frame saved by Python): cargo run --release --example decode_check -- <jpg> <npz>
use yorishiro_tracking::data::Npz;
use yorishiro_tracking::image::Image;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let img = Image::load(std::path::Path::new(&a[1])).unwrap();
    let cv = Npz::open(std::path::Path::new(&a[2])).unwrap().f64s("rgb").unwrap().0;
    let (mut sum, mut max) = (0.0, 0.0f64);
    for (x, y) in img.rgb.iter().zip(&cv) {
        let d = (*x as f64 - y).abs();
        sum += d;
        max = max.max(d);
    }
    println!("decode difference: mean {:.3}, largest {max}", sum / cv.len() as f64);
}
