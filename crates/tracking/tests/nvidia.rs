//! The landmark model on CUDA and TensorRT against ONNX Runtime CPU's landmarks on the same crops (golden
//! <recording>-inference.npz, PNG frames). Needs NVIDIA_ORT_DYLIB_PATH: the GPU build of ONNX Runtime
//! (tracker/.venv-nvidia), whose site-packages also hold the CUDA, cuDNN and TensorRT wheels.
//!     NVIDIA_ORT_DYLIB_PATH=... cargo test --release --test nvidia -- --nocapture

use std::path::PathBuf;
use std::time::Instant;
use yorishiro_tracking::backend::{preload_nvidia, runtime, Provider};
use yorishiro_tracking::data::Npz;
use yorishiro_tracking::image::Image;
use yorishiro_tracking::inference::{FaceMesh, LandmarkRuntime, Roi};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

#[test]
fn nvidia_landmarks() {
    let Some(lib) = std::env::var_os("NVIDIA_ORT_DYLIB_PATH").map(PathBuf::from) else {
        eprintln!("skipping: NVIDIA_ORT_DYLIB_PATH not set");
        return;
    };
    let testdata = root().join("../testdata/core-golden");
    // .../site-packages/onnxruntime/capi/libonnxruntime.so -> .../site-packages
    let site = lib.parent().unwrap().parent().unwrap().parent().unwrap();
    println!("preloaded {} NVIDIA libraries", preload_nvidia(site));
    runtime(Some(&lib)).unwrap();
    let models = root().join("tracker/models/mediapipe");
    let mut ok = true;
    for name in ["crema-d-60", "20261029-105439"] {
        let mut inf = Npz::open(&testdata.join(format!("{name}-inference.npz"))).unwrap();
        let roi = inf.f64s("roi").unwrap().0;
        let cpu = inf.f64s("landmarks").unwrap().0;
        let frames = testdata.join(format!("{name}-frames"));
        let n = std::fs::read_dir(&frames).unwrap().count();
        let imgs: Vec<Image> = (0..n).map(|i| Image::load(&frames.join(format!("{i:05}.png"))).unwrap()).collect();
        // CUDA is fp32 like the CPU; TensorRT's fp16 spreads like ncnn's fp16 does
        for (provider, tol_mean, tol_max) in [
            (Provider::Cuda, 0.01, 0.1),
            (Provider::TensorRt { cache: root().join("tracker/models/cache/tensorrt-core") }, 0.1, 1.0),
        ] {
            let mut mesh = FaceMesh::open_on(&models, LandmarkRuntime::Ort(provider), 4).unwrap();
            let (mut mean, mut max, mut ms) = (0.0f64, 0.0f64, 0.0f64);
            for (i, img) in imgs.iter().enumerate() {
                let (w, h) = (img.width as f64, img.height as f64);
                let r = &roi[i * 4..i * 4 + 4];
                let t = Instant::now();
                let got = mesh.landmarks_at(img, Roi { center: [r[0], r[1]], size: r[2], angle: r[3] }).unwrap().unwrap();
                if i >= 5 {
                    ms += t.elapsed().as_secs_f64() * 1000.0;
                }
                let mut sum = 0.0;
                for k in 0..478 {
                    let p = got.landmarks.points[k];
                    let at = (i * 478 + k) * 3;
                    let d = ((p[0] - cpu[at]) * w).hypot((p[1] - cpu[at + 1]) * h);
                    max = max.max(d);
                    sum += d;
                }
                mean += sum / 478.0;
            }
            mean /= n as f64;
            let pass = mean <= tol_mean && max <= tol_max;
            ok &= pass;
            println!("{name} {:20} vs ORT CPU: mean {mean:.4} px, largest {max:.3} px, {:.2} ms per crop (crop and network) {}",
                     mesh.runtime, ms / (n - 5) as f64, if pass { "ok" } else { "FAILED" });
        }
    }
    assert!(ok);
}
