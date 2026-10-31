//! The whole tracker on pictures against the Python tracker (golden <recording>-full.npz on the PNG frames
//! as OpenCV decoded them, from tracker/tools/export_core.py). Needs the private test data and
//! ORT_DYLIB_PATH, skipped otherwise.
//!
//! Two ways: from Python's landmarks (everything after them, with the eye model, MediaPipe's mouth and the
//! glare from the picture), and fully on our own landmarks. The second only on crema-d-60: on the other
//! recording a fast head roll around frame 60 makes the landmark loop amplify a 0.1 px crop difference
//! into a different re-detection (Rust frame 68, Python 70), as any second implementation would.
//!     ORT_DYLIB_PATH=... cargo test --release --test full -- --nocapture

use std::path::PathBuf;
use yorishiro_core::data::Npz;
use yorishiro_core::image::Image;
use yorishiro_core::tracker::{ModelPaths, Tracker};
use yorishiro_core::vts::vts_params;

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..")
}

fn testdata() -> PathBuf {
    std::env::var_os("YORISHIRO_TESTDATA").map(PathBuf::from).unwrap_or_else(|| root().join("../testdata"))
}

fn check(name: &str, own_landmarks: bool) -> bool {
    let golden = testdata().join("core-golden").join(format!("{name}-full.npz"));
    let frames = testdata().join("core-golden").join(format!("{name}-frames"));
    if !golden.exists() || std::env::var_os("ORT_DYLIB_PATH").is_none() {
        eprintln!("skipping {name}: needs {} and ORT_DYLIB_PATH", golden.display());
        return true;
    }
    let (mp, fit, eyes) = (root().join("tracker/models/mediapipe"), root().join("tracker/models/core/fit.npz"),
                           root().join("tracker/src/yorishiro_tracker/assets/eye_openness.onnx"));
    let mut tracker = Tracker::open(&ModelPaths { mediapipe: &mp, fit: &fit, eyes: Some(&eyes) }, 2).unwrap();
    let mut g = Npz::open(&golden).unwrap();
    let found = g.ints("found").unwrap();
    let ts = g.f64s("timestamps_ms").unwrap().0;
    let calibrated_at = g.ints("calibrated_at").unwrap();
    let stages = ["eye_open", "glare", "bs", "final_bs", "final_head", "final_pos", "vts"];
    let golden: Vec<Vec<f64>> = stages.iter().map(|s| g.f64s(s).unwrap().0).collect();
    let mut worst = vec![(0.0f64, 0usize, 0usize); stages.len()];
    let mut calibrations = vec![];
    let mut same_found = 0;
    let lm_g = g.f64s("landmarks").unwrap().0;
    for i in 0..found.len() {
        let img = Image::load(&frames.join(format!("{i:05}.png"))).unwrap();
        let out = if own_landmarks {
            tracker.process(&img, ts[i] as i64).unwrap()
        } else if found[i] == 1 {
            let pts: Vec<[f64; 3]> = lm_g[i * 478 * 3..(i + 1) * 478 * 3].chunks(3).map(|c| [c[0], c[1], c[2]]).collect();
            Some(tracker.process_landmarks(&img, &pts, ts[i] as i64).unwrap())
        } else {
            tracker.pipeline.lost();
            None
        };
        same_found += (out.is_some() == (found[i] == 1)) as usize;
        let Some(out) = out else { continue };
        if out.calibrated {
            calibrations.push(i);
        }
        let f = &out.frame;
        let fin = &out.final_frame;
        let ours: Vec<Vec<f64>> = vec![
            tracker_eye_open(f),
            f.lens_glare.unwrap_or([0.0; 2]).to_vec(),
            f.blendshapes.to_vec(),
            fin.blendshapes.to_vec(),
            fin.head_rotation.to_vec(),
            fin.head_translation.to_vec(),
            vts_params(fin, true).into_iter().map(|(_, v)| v).collect(),
        ];
        for (k, o) in ours.iter().enumerate() {
            if o.is_empty() {
                continue;
            }
            let theirs = &golden[k][i * o.len()..(i + 1) * o.len()];
            for (j, (a, b)) in o.iter().zip(theirs).enumerate() {
                if (a - b).abs() > worst[k].0 {
                    worst[k] = ((a - b).abs(), i, j);
                }
            }
        }
    }
    // eye openness and lens glare: blink comes from the first, so it is checked through bs; glare's CIELAB
    // is a float formula against OpenCV's 8 bit tables
    let tolerance = [f64::MAX, 0.03, 0.01, 0.02, 2e-4, 5e-5, 0.05];
    let mut ok = same_found == found.len() && calibrations == calibrated_at;
    println!("{name} ({}): {} frames, faces alike {same_found}, neutral window at {calibrations:?} (Python {calibrated_at:?})", if own_landmarks { "own landmarks" } else { "Python's landmarks" }, found.len());
    for (k, s) in stages.iter().enumerate() {
        if tolerance[k] == f64::MAX {
            continue;
        }
        let pass = worst[k].0 <= tolerance[k];
        ok &= pass;
        println!("  {s:10} max diff {:.2e} at frame {:3} value {:3} (tolerance {:.0e}) {}", worst[k].0, worst[k].1, worst[k].2,
                 tolerance[k], if pass { "ok" } else { "FAILED" });
    }
    ok
}

/// the frame does not keep the eye openness; blink values carry it
fn tracker_eye_open(_f: &yorishiro_core::frame::FaceFrame) -> Vec<f64> {
    vec![]
}

#[test]
fn full_recordings() {
    let mut ok = true;
    for name in ["crema-d-60", "20261029-105439"] {
        ok &= check(name, false);
    }
    ok &= check("crema-d-60", true);
    assert!(ok);
}
