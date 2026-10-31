//! Hand tracking against the Python tracker (golden hagrid-hands-hands.npz and its PNG frames from
//! tracker/tools/export_core.py, ORT CPU). Needs the private test data and ORT_DYLIB_PATH.
//! Tracking runs on its own for the hand counts and sides; landmarks and the Hand* inputs are compared on
//! Python's crops (open loop): fed back frame after frame, a 0.02 px difference wanders to about 0.2 px on a
//! still picture, as with the face.
use std::path::PathBuf;
use yorishiro_core::data::Npz;
use yorishiro_core::hands::{hand_params, HandTracker};
use yorishiro_core::image::Image;
use yorishiro_core::net::Runtime;

#[test]
fn hands_match_python() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
    let golden = root.join("../testdata/core-golden/hagrid-hands-hands.npz");
    if !golden.exists() || std::env::var_os("ORT_DYLIB_PATH").is_none() {
        eprintln!("skipping: needs {} and ORT_DYLIB_PATH", golden.display());
        return;
    }
    let frames = root.join("../testdata/core-golden/hagrid-hands-frames");
    let mut g = Npz::open(&golden).unwrap();
    let count = g.ints("count").unwrap();
    let right = g.ints("right").unwrap();
    let lms = g.f64s("landmarks").unwrap().0;
    let rois = g.f64s("roi").unwrap().0;
    let params: Vec<std::collections::HashMap<String, f64>> =
        serde_json::from_str(&std::fs::read_to_string(golden.with_extension("params.json")).unwrap()).unwrap();
    let mut tracker = HandTracker::open(&root.join("tracker/models/mediapipe/hands"), &Runtime::OrtCpu, 4).unwrap();
    let (mut same_count, mut same_side, mut lm_max, mut lm_sum, mut n_lm, mut p_max) = (0, 0, 0.0f64, 0.0, 0, 0.0f64);
    let mut worst_param = String::new();
    for i in 0..count.len() {
        let img = Image::load(&frames.join(format!("{i:05}.png"))).unwrap();
        let tracked = tracker.process(&img).unwrap();
        same_count += (tracked.len() == count[i]) as usize;
        for (k, h) in tracked.iter().enumerate().take(count[i].min(2)) {
            same_side += (h.right == (right[i * 2 + k] == 1)) as usize;
        }
        // the landmark model on Python's crops
        let mut hands = vec![];
        for k in 0..count[i].min(2) {
            let r = &rois[(i * 2 + k) * 4..(i * 2 + k) * 4 + 4];
            let h = tracker.landmarks(&img, ([r[0], r[1]], r[2], r[3])).unwrap().expect("a hand on Python's crop");
            for j in 0..21 {
                let at = ((i * 2 + k) * 21 + j) * 3;
                let d = (h.landmarks[j][0] - lms[at]).hypot(h.landmarks[j][1] - lms[at + 1]);
                lm_max = lm_max.max(d);
                lm_sum += d;
                n_lm += 1;
            }
            hands.push(h);
        }
        for (k, v) in hand_params(&hands, img.width as f64, img.height as f64) {
            match params[i].get(&k) {
                Some(t) => {
                    let d = (v - t).abs();
                    if d > p_max {
                        p_max = d;
                        worst_param = format!("{k} frame {i}");
                    }
                }
                None => {
                    p_max = f64::MAX;
                    worst_param = format!("{k} frame {i} missing in Python's");
                }
            }
        }
    }
    let total: usize = count.iter().sum();
    println!("{} frames: hand counts alike {same_count}, sides alike {same_side} of {total}, landmarks mean {:.4} px largest {lm_max:.4} px, Hand* largest diff {p_max:.4} ({worst_param})",
             count.len(), lm_sum / n_lm.max(1) as f64);
    assert_eq!(same_count, count.len());
    assert_eq!(same_side, total);
    assert!(lm_max < 0.01 && p_max < 0.01, "landmarks {lm_max} px, Hand* {p_max}");
}

