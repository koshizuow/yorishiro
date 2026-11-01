//! The landmark model on ncnn (Vulkan fp16 and fp32, CPU) against the Python tracker's ncnn backend on the
//! same crops (golden <recording>-ncnn.npz), and against ONNX Runtime. Only with the ncnn feature and the
//! private test data.
//!     NCNN_DIR=... ORT_DYLIB_PATH=... cargo test --release --features ncnn --test ncnn -- --nocapture
#![cfg(feature = "ncnn")]

use std::path::PathBuf;
use std::time::Instant;
use yorishiro_tracking::data::Npz;
use yorishiro_tracking::image::Image;
use yorishiro_tracking::inference::{FaceMesh, LandmarkRuntime, Roi};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn testdata() -> PathBuf {
    std::env::var_os("YORISHIRO_TESTDATA").map(PathBuf::from).unwrap_or_else(|| root().join("../testdata"))
}

fn check(name: &str) -> bool {
    let golden = testdata().join("core-golden").join(format!("{name}-ncnn.npz"));
    let inference = testdata().join("core-golden").join(format!("{name}-inference.npz"));
    let frames = testdata().join("core-golden").join(format!("{name}-frames"));
    if !golden.exists() || std::env::var_os("ORT_DYLIB_PATH").is_none() {
        eprintln!("skipping {name}");
        return true;
    }
    let models = root().join("tracker/models/mediapipe");
    let mut inf = Npz::open(&inference).unwrap();
    let roi = inf.f64s("roi").unwrap().0;
    let ort_lm = inf.f64s("landmarks").unwrap().0;
    let mut g = Npz::open(&golden).unwrap();
    let n = std::fs::read_dir(&frames).unwrap().count();
    let imgs: Vec<Image> = (0..n).map(|i| Image::load(&frames.join(format!("{i:05}.png"))).unwrap()).collect();
    let mut ok = true;
    // fp32 and CPU match Python's ncnn almost exactly. fp16 on the GPU does not repeat itself bit for bit:
    // Python's own fp16 run is up to 1.24 px (mean 0.21) from ORT on the glasses recording, so the same
    // spread is allowed between the two fp16 runs.
    for (runtime, key, tol_mean, tol_py) in [
        (LandmarkRuntime::Vulkan { fp16: true }, "vulkan", 0.25, 1.5),
        (LandmarkRuntime::Vulkan { fp16: false }, "vulkan_fp32", 0.01, 0.05),
        (LandmarkRuntime::NcnnCpu, "ncnn_cpu", 0.01, 0.05),
    ] {
        let py = g.f64s(key).unwrap().0;
        let mut mesh = FaceMesh::open_on(&models, runtime, 4).unwrap();
        let (mut d_py, mut d_ort, mut mean_py) = (0.0f64, 0.0f64, 0.0f64);
        let mut ms = 0.0;
        for (i, img) in imgs.iter().enumerate() {
            let (w, h) = (img.width as f64, img.height as f64);
            let r = &roi[i * 4..i * 4 + 4];
            let t = Instant::now();
            let got = mesh.landmarks_at(img, Roi { center: [r[0], r[1]], size: r[2], angle: r[3] }).unwrap();
            if i >= 5 {
                ms += t.elapsed().as_secs_f64() * 1000.0;
            }
            let Some(got) = got else { println!("  {key}: no face on frame {i}"); ok = false; continue };
            let mut sum = 0.0;
            for k in 0..478 {
                let p = got.landmarks.points[k];
                let at = (i * 478 + k) * 3;
                let dp = ((p[0] - py[at]) * w).hypot((p[1] - py[at + 1]) * h);
                let doo = ((p[0] - ort_lm[at]) * w).hypot((p[1] - ort_lm[at + 1]) * h);
                d_py = d_py.max(dp);
                d_ort = d_ort.max(doo);
                sum += dp;
            }
            mean_py += sum / 478.0;
        }
        mean_py /= n as f64;
        let pass = d_py <= tol_py && mean_py <= tol_mean;
        ok &= pass;
        println!("{name} {:40} vs Python's ncnn: mean {mean_py:.4} px, largest {d_py:.3} px; vs ORT largest {d_ort:.3} px; {:.2} ms per crop {}",
                 mesh.runtime, ms / (n - 5) as f64, if pass { "ok" } else { "FAILED" });
    }
    ok
}

#[test]
fn ncnn_landmarks() {
    let mut ok = true;
    for name in ["crema-d-60", "20261029-105439"] {
        ok &= check(name);
    }
    assert!(ok);
}
