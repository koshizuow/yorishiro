//! Where the CPU goes, stage by stage, on the PNG frames:
//! cargo run --release --features ncnn --example cpu_profile -- <frames dir> <monorepo> [runtime] [threads]
//! runtime: ort-cpu (default), vulkan, ncnn-cpu. Prints wall and process CPU milliseconds per frame for
//! each stage (CPU above wall means several threads worked), so a GPU runtime shows what is still on the CPU.
use std::time::Instant;
use yorishiro_tracking::glare::lens_glare;
use yorishiro_tracking::hands::HandTracker;
use yorishiro_tracking::image::{Border, Image};
use yorishiro_tracking::inference::{roi_matrix, Blendshapes, Eyes, FaceMesh, LandmarkRuntime};
use yorishiro_tracking::tracker::{ModelPaths, Tracker};

extern "C" {
    fn clock_gettime(clock: i32, ts: *mut [i64; 2]) -> i32;
}

/// CPU time of the whole process (all threads), in ms
fn cpu_ms() -> f64 {
    let mut ts = [0i64; 2];
    unsafe { clock_gettime(2, &mut ts) }; // CLOCK_PROCESS_CPUTIME_ID
    ts[0] as f64 * 1000.0 + ts[1] as f64 / 1e6
}

/// Runs f over the frames and prints its wall and CPU ms per frame.
fn stage(name: &str, frames: &[Image], mut f: impl FnMut(usize, &Image)) {
    for (i, img) in frames.iter().enumerate().take(5) {
        f(i, img);
    }
    let (w0, c0) = (Instant::now(), cpu_ms());
    for (i, img) in frames.iter().enumerate() {
        f(i, img);
    }
    let n = frames.len() as f64;
    println!("{name:<34} wall {:6.2} ms   cpu {:6.2} ms", w0.elapsed().as_secs_f64() * 1000.0 / n, (cpu_ms() - c0) / n);
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let dir = std::path::Path::new(&a[1]);
    let root = std::path::Path::new(&a[2]);
    let rt_name = a.get(3).map(String::as_str).unwrap_or("ort-cpu");
    let threads: usize = a.get(4).and_then(|v| v.parse().ok()).unwrap_or(4);
    let (mp, fit, eyes_path) = (root.join("models/mediapipe"), root.join("models/core/fit.npz"),
                                root.join("models/eye_openness.onnx"));
    let rt = match rt_name {
        "vulkan" => LandmarkRuntime::Vulkan { fp16: true },
        "ncnn-cpu" => LandmarkRuntime::NcnnCpu,
        _ => LandmarkRuntime::OrtCpu,
    };
    let frames: Vec<Image> = (0..100).map(|i| Image::load(&dir.join(format!("{i:05}.png"))).unwrap()).collect();
    let (fw, fh) = (frames[0].width, frames[0].height);
    println!("{} frames {fw}x{fh}, runtime {rt_name}, threads {threads}", frames.len());

    // camera side: what the capture thread does per frame
    let yuyv: Vec<Vec<u8>> = frames.iter().map(|f| {
        f.rgb.chunks_exact(6).flat_map(|p| [p[1], 128, p[4], 128]).collect()
    }).collect();
    stage("camera: YUYV to RGB", &frames, |i, _| { std::hint::black_box(yorishiro_tracking::camera::yuyv_to_rgb(&yuyv[i], fw, fh)); });
    let jpegs: Vec<Vec<u8>> = frames.iter().map(|f| {
        let mut out = std::io::Cursor::new(Vec::new());
        image::RgbImage::from_raw(fw as u32, fh as u32, f.rgb.clone()).unwrap().write_to(&mut out, image::ImageFormat::Jpeg).unwrap();
        out.into_inner()
    }).collect();
    stage("camera: MJPG decode", &frames, |i, _| {
        std::hint::black_box(image::load_from_memory_with_format(&jpegs[i], image::ImageFormat::Jpeg).unwrap().to_rgb8());
    });

    // face
    let mut mesh = FaceMesh::open_on(&mp, rt.clone(), threads).unwrap();
    let pass = mesh.pass_ms().unwrap();
    let points: Vec<_> = frames.iter().map(|f| mesh.process(f).unwrap().unwrap().points).collect();
    let roi = mesh.roi.unwrap();
    stage("face: crop (warp 256x256)", &frames, |_, f| { std::hint::black_box(f.warp_affine(&roi_matrix(&roi), 256, 256, Border::Constant)); });
    let crop = frames[0].warp_affine(&roi_matrix(&roi), 256, 256, Border::Constant);
    stage("face: to NCHW float", &frames, |_, _| { std::hint::black_box(crop.to_nchw(1.0 / 255.0, 0.0)); });
    let input = crop.to_nchw(1.0 / 255.0, 0.0);
    let mut net = yorishiro_tracking::net::Net::open(&mp.join("face_landmarks"), &rt, threads).unwrap();
    stage("face: landmark network alone", &frames, |_, _| { net.run(3, 256, 256, input.clone()).unwrap(); });
    mesh.roi = None;
    stage("face: landmarks, one pass", &frames, |_, f| { mesh.process(f).unwrap(); });
    println!("    (one pass measured {pass:.2} ms at open; flip averaging doubles the passes)");
    let mut blend = Blendshapes::open(&mp.join("face_blendshapes.onnx")).unwrap();
    stage("face: blendshape model (ort cpu)", &frames, |i, f| { blend.run(&points[i], f.width as f64, f.height as f64).unwrap(); });
    let mut eyes = Eyes::open(&eyes_path).unwrap();
    stage("face: eye model (ort cpu)", &frames, |i, f| { eyes.run(f, &points[i]).unwrap(); });
    stage("face: lens glare", &frames, |i, f| { std::hint::black_box(lens_glare(f, &points[i])); });
    let mut tracker = Tracker::open_on(&ModelPaths { mediapipe: &mp, fit: &fit, eyes: Some(&eyes_path) }, rt.clone(), threads).unwrap();
    println!("    tracker landmark runtime: {}", tracker.mesh.runtime);
    stage("face: after landmarks (all)", &frames, |i, f| { tracker.process_landmarks(f, &points[i], 1000 + i as i64 * 33).unwrap(); });
    stage("face: whole tracker", &frames, |i, f| { tracker.process(f, 1000 + i as i64 * 33).unwrap(); });

    // hands, as the app runs them (two threads)
    let mut hands = HandTracker::open(&mp.join("hands"), &rt, 2).unwrap();
    stage("hands: whole", &frames, |_, f| { hands.process(f).unwrap(); });
}
