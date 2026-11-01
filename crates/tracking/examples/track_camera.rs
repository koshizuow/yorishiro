//! The core on a live camera: cargo run --release --example track_camera -- <video index> <monorepo> [seconds]
//! Prints the camera mode, frames per second, faces found, the tracker's time per frame and some inputs.
use std::time::Instant;
use yorishiro_tracking::camera::Camera;
use yorishiro_tracking::tracker::{ModelPaths, Tracker};
use yorishiro_tracking::vts::vts_params;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let index: usize = a[1].parse().unwrap();
    let root = std::path::Path::new(&a[2]);
    let seconds: f64 = a.get(3).and_then(|s| s.parse().ok()).unwrap_or(10.0);
    let (mp, fit, eyes) = (root.join("models/mediapipe"), root.join("models/core/fit.npz"),
                           root.join("models/eye_openness.onnx"));
    let mut tracker = Tracker::open(&ModelPaths { mediapipe: &mp, fit: &fit, eyes: Some(&eyes) }, 4).unwrap();
    let cam = Camera::open(index, 1280, 720, 30).unwrap();
    println!("camera {index}: {}", cam.mode);
    let start = Instant::now();
    let (mut seq, mut frames, mut faces, mut skipped, mut busy) = (0u64, 0, 0, 0u64, 0.0);
    let keys = ["FaceAngleX", "FaceAngleY", "EyeOpenLeft", "EyeOpenRight", "MouthOpen", "MouthSmile"];
    let mut sums = [0.0f64; 6];
    while start.elapsed().as_secs_f64() < seconds {
        let f = cam.next(seq).unwrap();
        skipped += f.sequence - seq - 1;
        seq = f.sequence;
        let t = Instant::now();
        let out = tracker.process(&f.image, start.elapsed().as_millis() as i64).unwrap();
        busy += t.elapsed().as_secs_f64();
        frames += 1;
        if let Some(o) = out {
            faces += 1;
            for (k, v) in vts_params(&o.final_frame, true) {
                if let Some(j) = keys.iter().position(|x| *x == k) {
                    sums[j] += v;
                }
            }
            if faces % 30 == 0 {
                let p: Vec<String> = vts_params(&o.final_frame, true).into_iter().filter(|(k, _)| ["FaceAngleX", "EyeOpenLeft", "MouthOpen"].contains(k))
                    .map(|(k, v)| format!("{k} {v:.2}")).collect();
                println!("  {}", p.join(", "));
            }
        }
    }
    let el = start.elapsed().as_secs_f64();
    println!("{frames} frames in {el:.1} s ({:.1} fps), {faces} with a face, {skipped} camera frames skipped, tracker {:.1} ms per frame",
             frames as f64 / el, busy / frames as f64 * 1000.0);
    let means: Vec<String> = keys.iter().zip(sums).map(|(k, s)| format!("{k} {:.3}", s / faces.max(1) as f64)).collect();
    println!("means: {}", means.join(", "));
}
