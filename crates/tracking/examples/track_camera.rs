//! The core on a live camera: cargo run --release --example track_camera -- <video index|auto> <monorepo> [seconds]
//! [auto|vulkan|vulkan-fp32|ort-cpu] [width height fps]
//! Prints the camera mode, the landmark runtime, frames per second, faces found, the tracker's time per frame and
//! some inputs; auto is the first free camera. rec:<recording dir> runs a recording's frames back to back instead
//! (compute only), TRACK_CSV=<file> writes every frame's inputs, TRACK_SAVE=<png> keeps frame 60.
use std::time::Instant;
use yorishiro_tracking::camera::Camera;
use yorishiro_tracking::inference::{auto_runtime, LandmarkRuntime};
use yorishiro_tracking::tracker::{ModelPaths, Tracker};
use yorishiro_tracking::vts::vts_params;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let root = std::path::Path::new(&a[2]);
    let seconds: f64 = a.get(3).and_then(|s| s.parse().ok()).unwrap_or(10.0);
    let num = |i: usize, d: u32| a.get(i).and_then(|s| s.parse().ok()).unwrap_or(d);
    let (w, h, fps) = (num(5, 1280), num(6, 720), num(7, 30));
    let (mp, fit, eyes) = (root.join("models/mediapipe"), root.join("models/core/fit.npz"),
                           root.join("models/eye_openness.onnx"));
    let runtime = match a.get(4).map(String::as_str).unwrap_or("auto") {
        "ort-cpu" => LandmarkRuntime::OrtCpu,
        #[cfg(feature = "ncnn")]
        "vulkan" => LandmarkRuntime::Vulkan { fp16: true },
        #[cfg(feature = "ncnn")]
        "vulkan-fp32" => LandmarkRuntime::Vulkan { fp16: false },
        "auto" => {
            let (r, trials) = auto_runtime(&mp, 4);
            for t in trials {
                println!("  trial {}: pass {:.2} ms, max diff {:.3} px", t.name, t.pass_ms, t.max_diff);
            }
            r
        }
        x => panic!("unknown runtime {x}"),
    };
    let paths = ModelPaths { mediapipe: &mp, fit: &fit, eyes: Some(&eyes) };
    let mut tracker = Tracker::open_on(&paths, runtime, 4).unwrap();
    println!("landmarks on {}", tracker.runtime_name());
    // rec:<recording dir>: the recording's frames at its timestamps, back to back (compute only, no camera)
    if let Some(dir) = a[1].strip_prefix("rec:") {
        let dir = std::path::Path::new(dir);
        let meta: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(dir.join("meta.json")).unwrap()).unwrap();
        let times: Vec<i64> = meta["timestamps_ms"].as_array().unwrap().iter().map(|v| v.as_i64().unwrap()).collect();
        let (mut busy, mut faces, mut list) = (0.0, 0, vec![]);
        for (i, ts) in times.iter().enumerate() {
            let img = image::open(dir.join(format!("frames/{i:05}.jpg"))).unwrap().to_rgb8();
            let img = yorishiro_tracking::image::Image { width: img.width() as usize, height: img.height() as usize, rgb: img.into_raw() };
            let t = Instant::now();
            let out = tracker.process(&img, *ts).unwrap();
            let ms = t.elapsed().as_secs_f64() * 1000.0;
            if i >= 10 {
                busy += ms;
                list.push(ms);
            }
            faces += out.is_some() as usize;
        }
        list.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let n = list.len().max(1);
        println!("{} frames, {faces} with a face, tracker mean {:.2} ms, median {:.2}, p95 {:.2} (after 10 warm-up frames)",
                 times.len(), busy / n as f64, list[n / 2], list[n * 95 / 100]);
        let s = tracker.stage_ms;
        println!("stages (smoothed, ms): landmarks {:.1}, blendshapes {:.1}, eyes {:.1}; {}", s[0], s[1], s[2], tracker.runtime_name());
        return;
    }
    let (index, cam) = if a[1] == "auto" {
        yorishiro_tracking::camera::first_free(w, h, fps).unwrap()
    } else {
        let i: usize = a[1].parse().unwrap();
        (i, Camera::open(i, w, h, fps).unwrap())
    };
    println!("camera {index}: {}", cam.mode);
    let start = Instant::now();
    let (mut seq, mut frames, mut faces, mut skipped, mut busy) = (0u64, 0, 0, 0u64, 0.0);
    let keys = ["FaceAngleX", "FaceAngleY", "EyeOpenLeft", "EyeOpenRight", "MouthOpen", "MouthSmile"];
    let mut sums = [0.0f64; 6];
    // TRACK_CSV=<file>: every frame's VTube Studio style inputs, with the wall clock (Unix ms) when it was done
    let mut csv = std::env::var("TRACK_CSV").ok().map(|p| std::io::BufWriter::new(std::fs::File::create(p).unwrap()));
    let mut csv_head = false;
    while start.elapsed().as_secs_f64() < seconds {
        let f = cam.next(seq).unwrap();
        if frames == 60 {
            if let Ok(path) = std::env::var("TRACK_SAVE") {
                let _ = image::save_buffer(&path, &f.image.rgb, f.image.width as u32, f.image.height as u32, image::ExtendedColorType::Rgb8);
            }
        }
        skipped += f.sequence - seq - 1;
        seq = f.sequence;
        let t = Instant::now();
        let out = tracker.process(&f.image, start.elapsed().as_millis() as i64).unwrap();
        busy += t.elapsed().as_secs_f64();
        frames += 1;
        if let (Some(w), Some(o)) = (csv.as_mut(), out.as_ref()) {
            use std::io::Write;
            let p = vts_params(&o.final_frame, true);
            if !csv_head {
                csv_head = true;
                let _ = writeln!(w, "unix_ms,{}", p.iter().map(|(k, _)| k.to_string()).collect::<Vec<_>>().join(","));
            }
            let at = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs_f64() * 1000.0;
            let _ = writeln!(w, "{at:.1},{}", p.iter().map(|(_, v)| format!("{v:.4}")).collect::<Vec<_>>().join(","));
        }
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
    let s = tracker.stage_ms;
    println!("stages (smoothed, ms): landmarks {:.1}, blendshapes {:.1}, eyes {:.1}", s[0], s[1], s[2]);
}
