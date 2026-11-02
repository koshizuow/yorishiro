//! Eye openness against head turn on a recording, to see whether a turned head reads as a blink (the far eye looks
//! narrower). One CSV line per frame: head yaw and pitch in degrees, far/near eye width, the eye model's raw
//! openness and the eyeBlink values that go to the app (subject's left, right).
//! cargo run --release --example eye_yaw -- <recording dir with frames/ and meta.json> <monorepo>
use yorishiro_tracking::image::Image;
use yorishiro_tracking::inference::{eye_widths, Eyes};
use yorishiro_tracking::tracker::{ModelPaths, Tracker};
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (rec, root) = (std::path::Path::new(&a[1]), std::path::Path::new(&a[2]));
    let (mp, fit, eyes_path) = (root.join("models/mediapipe"), root.join("models/core/fit.npz"),
                                root.join("models/eye_openness.onnx"));
    let mut t = Tracker::open(&ModelPaths { mediapipe: &mp, fit: &fit, eyes: Some(&eyes_path) }, 2).unwrap();
    let mut eyes = Eyes::open(&eyes_path).unwrap();
    let meta: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(rec.join("meta.json")).unwrap()).unwrap();
    let stamps: Vec<i64> = meta["timestamps_ms"].as_array().unwrap().iter().map(|v| v.as_i64().unwrap()).collect();
    let blink = |name: &str| yorishiro_tracking::frame::ARKIT52.iter().position(|n| *n == name).unwrap();
    let (bl, br) = (blink("eyeBlinkLeft"), blink("eyeBlinkRight"));
    println!("frame,yaw,pitch,width_l_over_r,open_l,open_r,blink_l,blink_r");
    for (i, ts) in stamps.iter().enumerate() {
        let path = rec.join(format!("frames/{i:05}.jpg"));
        let Ok(img) = Image::load(&path) else { continue };
        let Some(out) = t.process(&img, *ts).unwrap() else { continue };
        let open = eyes.run(&img, &out.smoothed).unwrap();
        let w = eye_widths(&out.smoothed, img.width as f64, img.height as f64);
        let f = &out.final_frame;
        println!("{i},{:.1},{:.1},{:.3},{:.3},{:.3},{:.3},{:.3}", f.head_rotation[0].to_degrees(), f.head_rotation[1].to_degrees(),
                 w[0] / w[1], open[0], open[1], f.blendshapes[bl], f.blendshapes[br]);
    }
}
