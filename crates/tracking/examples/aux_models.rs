//! The small models after the landmarks (blendshapes, eye openness) on each runtime: time per call, back to
//! back and paced like a 30 fps camera (the GPU idles between frames), and the largest difference from ONNX
//! Runtime on the same input.
//! cargo run --release --features ncnn --example aux_models -- <dir with face_blendshapes and eye_openness .onnx
//! and .ncnn.param/.bin (eye model converted with batch 1)>
use std::path::Path;
use std::time::{Duration, Instant};
use yorishiro_tracking::backend::OrtModel;
use yorishiro_tracking::ncnn::NcnnModel;

fn time(paced: bool, n: usize, mut f: impl FnMut()) -> f64 {
    for _ in 0..5 {
        f();
    }
    let mut total = 0.0;
    for _ in 0..n {
        if paced {
            std::thread::sleep(Duration::from_millis(30));
        }
        let t = Instant::now();
        f();
        total += t.elapsed().as_secs_f64() * 1000.0;
    }
    total / n as f64
}

fn max_diff(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| (x - y).abs()).fold(0.0, f32::max)
}

fn main() {
    let dir = std::env::args().nth(1).expect("model dir");
    let dir = Path::new(&dir);
    yorishiro_tracking::backend::runtime(std::env::var("ORT_DYLIB_PATH").ok().as_deref().map(Path::new)).unwrap();

    // landmark-like points, deterministic
    let pts: Vec<f32> = (0..146).flat_map(|i| {
        let a = i as f32 * 0.43;
        [320.0 + 90.0 * a.cos() * (1.0 + 0.1 * (i % 7) as f32), 240.0 + 110.0 * a.sin()]
    }).collect();
    let eye: Vec<f32> = (0..3 * 40 * 64).map(|i| ((i * 37 % 251) as f32) / 1.0).collect();

    let mut ort_b = OrtModel::open(&dir.join("face_blendshapes.onnx"), 1).unwrap();
    let mut ort_e = OrtModel::open(&dir.join("eye_openness.onnx"), 1).unwrap();
    let ref_b = ort_b.run(&[1, 146, 2], pts.clone()).unwrap()[0].clone();
    let two: Vec<f32> = eye.iter().chain(eye.iter()).copied().collect();
    let ref_e = ort_e.run(&[2, 3, 40, 64], two.clone()).unwrap()[0].clone();
    for paced in [false, true] {
        let label = if paced { "paced 30 fps" } else { "back to back" };
        println!("{label:<13} blendshapes ort-cpu {:6.2} ms   eyes ort-cpu (both) {:6.2} ms",
                 time(paced, 60, || { ort_b.run(&[1, 146, 2], pts.clone()).unwrap(); }),
                 time(paced, 60, || { ort_e.run(&[2, 3, 40, 64], two.clone()).unwrap(); }));
    }
    for (gpu, fp16) in [(false, false), (true, false), (true, true)] {
        let mut b = NcnnModel::open(&dir.join("face_blendshapes"), gpu, fp16, 1).unwrap();
        let mut e = NcnnModel::open(&dir.join("eye_openness"), gpu, fp16, 1).unwrap();
        let out_b = b.run_shape(&[146, 2], pts.clone()).unwrap();
        let ob: Vec<f32> = out_b.iter().find(|(n, _)| n == "out0").map(|(_, v)| v.clone()).unwrap_or_default();
        let oe = e.run(3, 40, 64, eye.clone()).unwrap()[0].1.clone();
        let db = if ob.len() == ref_b.len() { max_diff(&ob, &ref_b) } else { f32::NAN };
        let de = max_diff(&oe, &ref_e[..oe.len().min(ref_e.len())]);
        let name = b.name.clone();
        for paced in [false, true] {
            let label = if paced { "paced 30 fps" } else { "back to back" };
            println!("{label:<13} blendshapes {} {:6.2} ms (max diff {db:.4}, {} outputs)   eyes x2 {:6.2} ms (max diff {de:.4})",
                     name, time(paced, 60, || { b.run_shape(&[146, 2], pts.clone()).unwrap(); }), ob.len(),
                     time(paced, 60, || { e.run(3, 40, 64, eye.clone()).unwrap(); e.run(3, 40, 64, eye.clone()).unwrap(); }));
        }
    }
}
