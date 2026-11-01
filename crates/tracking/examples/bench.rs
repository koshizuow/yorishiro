//! Per-frame time of the Rust core on the PNG frames: cargo run --release --example bench -- <frames dir> <testdata models root>
use std::time::Instant;
use yorishiro_tracking::image::Image;
use yorishiro_tracking::tracker::{ModelPaths, Tracker};
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let root = std::path::Path::new(&a[2]);
    let (mp, fit, eyes) = (root.join("tracker/models/mediapipe"), root.join("tracker/models/core/fit.npz"),
                           root.join("tracker/src/yorishiro_tracker/assets/eye_openness.onnx"));
    let threads: usize = a.get(3).and_then(|v| v.parse().ok()).unwrap_or(2);
    let mut t = Tracker::open(&ModelPaths { mediapipe: &mp, fit: &fit, eyes: Some(&eyes) }, threads).unwrap();
    let frames: Vec<Image> = (0..100).map(|i| Image::load(&std::path::Path::new(&a[1]).join(format!("{i:05}.png"))).unwrap()).collect();
    for f in frames.iter().take(10) { t.process(f, 0).unwrap(); }
    let (mut lm_ms, mut rest_ms) = (0.0, 0.0);
    for (i, f) in frames.iter().enumerate() {
        let t0 = Instant::now();
        let lm = t.mesh.process(f).unwrap();
        let t1 = Instant::now();
        if let Some(lm) = lm { t.process_landmarks(f, &lm.points, 1000 + i as i64 * 33).unwrap(); }
        lm_ms += (t1 - t0).as_secs_f64() * 1000.0;
        rest_ms += t1.elapsed().as_secs_f64() * 1000.0;
    }
    // the crop alone
    let roi = yorishiro_tracking::inference::Roi { center: [640.0, 360.0], size: 300.0, angle: 0.1 };
    let t0 = Instant::now();
    for f in &frames { std::hint::black_box(f.warp_affine(&yorishiro_tracking::inference::roi_matrix(&roi), 256, 256, yorishiro_tracking::image::Border::Constant)); }
    println!("crop alone {:.2} ms", t0.elapsed().as_secs_f64() * 1000.0 / 100.0);
    println!("threads {threads}, per frame: landmarks (crop + network) {:.2} ms, rest (fit, eye model, mouth model, glare, smoothing) {:.2} ms", lm_ms / 100.0, rest_ms / 100.0);
}
