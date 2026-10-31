//! The image side against the Python tracker on ONNX Runtime CPU (golden <recording>-inference.npz from
//! tracker/tools/export_core.py): detector runs, crops, landmarks, MediaPipe's blendshapes, eye crops and
//! openness, frame by frame on the recordings' pictures. Needs the private test data and
//! ORT_DYLIB_PATH (tools: tracker/.venv's onnxruntime), skipped otherwise.
//!     ORT_DYLIB_PATH=... cargo test --release --test inference -- --nocapture

use std::path::PathBuf;
use yorishiro_core::data::Npz;
use yorishiro_core::image::Image;
use yorishiro_core::inference::{crop_eye, Blendshapes, Eyes, FaceMesh, Roi};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..")
}

fn testdata() -> PathBuf {
    std::env::var_os("YORISHIRO_TESTDATA").map(PathBuf::from).unwrap_or_else(|| root().join("../testdata"))
}

/// png: the first frames as OpenCV decoded them (strict), else the JPEG frames (decoders differ a little)
fn check(name: &str, png: bool) -> bool {
    let golden = testdata().join("core-golden").join(format!("{name}-inference.npz"));
    let frames = if png { testdata().join("core-golden").join(format!("{name}-frames")) } else { testdata().join("recordings").join(name).join("frames") };
    if !golden.exists() || std::env::var_os("ORT_DYLIB_PATH").is_none() {
        eprintln!("skipping {name}: needs {} and ORT_DYLIB_PATH", golden.display());
        return true;
    }
    let models = root().join("tracker/models/mediapipe");
    let mut mesh = FaceMesh::open(&models, 2).unwrap();
    let mut blend = Blendshapes::open(&models.join("face_blendshapes.onnx")).unwrap();
    let mut eyes = Eyes::open(&root().join("tracker/src/yorishiro_tracker/assets/eye_openness.onnx")).unwrap();
    let mut g = Npz::open(&golden).unwrap();
    let found = g.ints("found").unwrap();
    let detected = g.ints("detected").unwrap();
    let roi = g.f64s("roi").unwrap().0;
    let lms = g.f64s("landmarks").unwrap().0;
    let mp = g.f64s("mp_bs").unwrap().0;
    let eye_open = g.f64s("eye_open").unwrap().0;
    let crops = g.f64s("eye_crops").unwrap().0;
    let n = if png { std::fs::read_dir(&frames).map(|d| d.count()).unwrap_or(0) } else { found.len() };
    let (mut lm_px, mut lm_mean, mut roi_px, mut bs_d, mut eye_d, mut crop_d) = (0.0f64, 0.0f64, 0.0f64, 0.0f64, 0.0f64, 0.0f64);
    let (mut same_found, mut faces, mut runs) = (0, 0, 0);
    for i in 0..n {
        let img = Image::load(&frames.join(format!("{i:05}.{}", if png { "png" } else { "jpg" }))).unwrap();
        let (w, h) = (img.width as f64, img.height as f64);
        // tracking on its own, for the record: a presence near the threshold can re-detect on another frame
        let before = mesh.detections;
        let tracked = mesh.process(&img).unwrap();
        runs += (mesh.detections > before) as usize;
        same_found += (tracked.is_some() == (found[i] == 1)) as usize;
        if found[i] == 0 {
            continue;
        }
        // compared stage by stage: the landmark model on the crop Python used
        let r = &roi[i * 4..i * 4 + 4];
        let given = Roi { center: [r[0], r[1]], size: r[2], angle: r[3] };
        let Some(t) = mesh.landmarks_at(&img, given).unwrap() else {
            println!("  frame {i}: no face on Python's crop");
            lm_px = f64::MAX;
            continue;
        };
        let lm = t.landmarks;
        faces += 1;
        // the next crop from these landmarks against Python's next one
        if i + 1 < n && found[i + 1] == 1 && detected[i + 1] == 0 {
            let r2 = &roi[(i + 1) * 4..(i + 1) * 4 + 4];
            roi_px = roi_px.max((t.next_roi.center[0] - r2[0]).abs()).max((t.next_roi.center[1] - r2[1]).abs())
                .max((t.next_roi.size - r2[2]).abs());
        }
        let mut sum = 0.0;
        for k in 0..478 {
            let g = &lms[(i * 478 + k) * 3..(i * 478 + k) * 3 + 3];
            let d = ((lm.points[k][0] - g[0]) * w).hypot((lm.points[k][1] - g[1]) * h);
            lm_px = lm_px.max(d);
            sum += d;
        }
        lm_mean += sum / 478.0;
        let bs = blend.run(&lm.points, w, h).unwrap();
        for k in 0..52 {
            bs_d = bs_d.max((bs[k] - mp[i * 52 + k]).abs());
        }
        let e = eyes.run(&img, &lm.points).unwrap();
        for k in 0..2 {
            eye_d = eye_d.max((e[k] - eye_open[i * 2 + k]).abs());
            // eye crops are BGR in the golden file
            let c = crop_eye(&img, &lm.points, k);
            let base = (i * 2 + k) * 40 * 64 * 3;
            let mut diff = 0.0;
            for p in 0..40 * 64 {
                for ch in 0..3 {
                    diff += (c.rgb[p * 3 + ch] as f64 - crops[base + p * 3 + (2 - ch)]).abs();
                }
            }
            crop_d = crop_d.max(diff / (40.0 * 64.0 * 3.0));
        }
    }
    let golden_runs: usize = detected.iter().sum();
    lm_mean /= faces.max(1) as f64;
    println!("{name} ({}): {n} frames, faces found alike {same_found}/{n}, detector runs {runs} (Python {golden_runs})", if png { "PNG as OpenCV decoded" } else { "JPEG" });
    println!("  next crop from the landmarks, largest difference {roi_px:.3} px");
    println!("  landmarks mean {lm_mean:.3} px, largest {lm_px:.3} px");
    println!("  eye crops mean grey difference at most {crop_d:.2}");
    println!("  MediaPipe blendshapes largest difference {bs_d:.4}");
    println!("  eye openness largest difference {eye_d:.4}");
    // same pixels: what is left is ONNX Runtime's thread count and a few one-level warp differences.
    // JPEG: the two decoders differ by up to a few grey levels, which the networks amplify around glasses
    let ok = if png {
        lm_mean < 0.02 && lm_px < 0.2 && bs_d < 0.01 && eye_d < 0.01
    } else {
        lm_mean < 0.3 && lm_px < 3.0 && bs_d < 0.08 && eye_d < 0.08
    };
    if !ok {
        println!("  FAILED");
    }
    ok
}

#[test]
fn inference_recordings() {
    let mut ok = true;
    for name in ["crema-d-60", "20261029-105439"] {
        ok &= check(name, true);
        ok &= check(name, false);
    }
    assert!(ok);
}
