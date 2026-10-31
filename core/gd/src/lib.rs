//! YorishiroCore: the tracking core as a Godot node (Phase B4), in place of the yorishiro-tracker process.
//! It speaks the process's link protocol (tracker/src/yorishiro_tracker/sinks/link.py) as dictionaries:
//! poll() returns status messages and the newest frame ({found, vts, arkit, glare}), so the app's tracker
//! input (yorishiro_tracker.gd) handles both the same way. Camera, inference and fit run in a thread.

use godot::prelude::*;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Instant;
use yorishiro_core::backend::{preload_nvidia, runtime as ort_runtime, Provider};
use yorishiro_core::camera::Camera;
use yorishiro_core::frame::ARKIT52;
use yorishiro_core::inference::LandmarkRuntime;
use yorishiro_core::sinks::{IFacialMocapSink, VtsIphoneSink, VTS_REQUEST_PORT};
use yorishiro_core::tracker::{ModelPaths, Tracker};
use yorishiro_core::vts::vts_params;

struct YorishiroCoreExtension;

#[gdextension]
unsafe impl ExtensionLibrary for YorishiroCoreExtension {}

/// Plain values only (Variant is not Send), turned into dictionaries in poll().
#[derive(Clone)]
struct FrameOut {
    found: bool,
    vts: Vec<(&'static str, f64)>,
    arkit: [f64; 52],
    glare: Option<[f64; 2]>,
}

#[derive(Default)]
struct Shared {
    messages: Mutex<Vec<(String, String, Vec<(String, f64)>, Vec<(String, String)>)>>,
    logs: Mutex<Vec<String>>,
    frame: Mutex<Option<FrameOut>>,
    stop: AtomicBool,
    calibrate: AtomicBool,
}

impl Shared {
    fn status(&self, state: &str, message: &str, numbers: Vec<(String, f64)>, texts: Vec<(String, String)>) {
        self.messages.lock().unwrap().push((state.into(), message.into(), numbers, texts));
    }
    fn log(&self, line: String) {
        self.logs.lock().unwrap().push(line);
    }
}

#[derive(GodotClass)]
#[class(init, base = Node)]
pub struct YorishiroCore {
    /// /dev/video<camera>
    #[export]
    camera: i32,
    /// ort-cpu, cuda, tensorrt, vulkan, vulkan-fp32, ncnn-cpu (the last three when built with ncnn)
    #[export]
    #[init(val = GString::from("ort-cpu"))]
    runtime: GString,
    /// the tracker's models folder (mediapipe/, core/fit.npz, cache/)
    #[export]
    models_dir: GString,
    /// the eye openness model (assets/eye_openness.onnx), empty for the lid gap
    #[export]
    eye_model: GString,
    /// libonnxruntime.so to load: the CPU build, or the GPU build for cuda and tensorrt
    #[export]
    ort_library: GString,
    /// the avatar mirrors the user (the VTuber default)
    #[export]
    #[init(val = true)]
    mirror: bool,
    /// answer VTube Studio iPhone protocol requests on UDP 21412 (VTube Studio, OpenVT)
    #[export]
    send_vts_iphone: bool,
    /// send iFacialMocap to this host's 49983 (VSeeFace, Warudo, VNyan), empty for off
    #[export]
    ifacialmocap_host: GString,
    shared: Option<Arc<Shared>>,
    worker: Option<JoinHandle<()>>,
    base: Base<Node>,
}

#[godot_api]
impl YorishiroCore {
    /// Starts camera and tracking in a thread; progress and errors arrive as status messages.
    #[func]
    fn start(&mut self) {
        self.stop();
        let shared = Arc::new(Shared::default());
        let cfg = Config {
            camera: self.camera.max(0) as usize,
            runtime: self.runtime.to_string(),
            models: PathBuf::from(self.models_dir.to_string()),
            eye_model: Some(self.eye_model.to_string()).filter(|s| !s.is_empty()).map(PathBuf::from),
            ort_library: Some(self.ort_library.to_string()).filter(|s| !s.is_empty()).map(PathBuf::from),
            mirror: self.mirror,
            vts_iphone: self.send_vts_iphone,
            ifacialmocap: Some(self.ifacialmocap_host.to_string()).filter(|s| !s.is_empty()),
        };
        let s = shared.clone();
        self.worker = std::thread::Builder::new().name("yorishiro-core".into()).spawn(move || run(cfg, s)).ok();
        self.shared = Some(shared);
    }

    #[func]
    fn stop(&mut self) {
        if let Some(s) = &self.shared {
            s.stop.store(true, Ordering::Relaxed);
        }
        if let Some(w) = self.worker.take() {
            let _ = w.join();
        }
        self.shared = None;
    }

    /// A new neutral from the next faces, like the process's calibrate command.
    #[func]
    fn recalibrate(&mut self) {
        if let Some(s) = &self.shared {
            s.calibrate.store(true, Ordering::Relaxed);
        }
    }

    #[func]
    fn is_running(&self) -> bool {
        self.worker.as_ref().map(|w| !w.is_finished()).unwrap_or(false)
    }

    /// Status messages since the last call, then the newest frame if there is one, as the link sends them.
    #[func]
    fn poll(&mut self) -> Array<VarDictionary> {
        let mut out = Array::new();
        let Some(s) = &self.shared else { return out };
        for (state, message, numbers, texts) in s.messages.lock().unwrap().drain(..) {
            let mut d = VarDictionary::new();
            d.set("v", 1);
            d.set("type", "status");
            d.set("state", state);
            d.set("message", message);
            for (k, v) in numbers {
                // the link sends these as JSON booleans
                if ["face", "calibrated", "commercial_use"].contains(&k.as_str()) {
                    d.set(k, v != 0.0);
                } else {
                    d.set(k, v);
                }
            }
            for (k, v) in texts {
                d.set(k, v);
            }
            out.push(&d);
        }
        if let Some(f) = s.frame.lock().unwrap().take() {
            let mut d = VarDictionary::new();
            d.set("v", 1);
            d.set("found", f.found);
            if f.found {
                let mut vts = VarDictionary::new();
                for (k, v) in f.vts {
                    vts.set(k, v);
                }
                d.set("vts", &vts);
                let mut arkit = VarDictionary::new();
                for (k, v) in ARKIT52.iter().zip(f.arkit) {
                    arkit.set(*k, v);
                }
                d.set("arkit", &arkit);
                if let Some(g) = f.glare {
                    d.set("glare", &PackedFloat64Array::from(&g[..]));
                }
            }
            out.push(&d);
        }
        out
    }

    /// Log lines since the last call.
    #[func]
    fn take_log(&mut self) -> PackedStringArray {
        let Some(s) = &self.shared else { return PackedStringArray::new() };
        s.logs.lock().unwrap().drain(..).map(|l| GString::from(l.as_str())).collect()
    }
}

#[godot_api]
impl INode for YorishiroCore {
    fn exit_tree(&mut self) {
        self.stop();
    }
}

struct Config {
    camera: usize,
    runtime: String,
    models: PathBuf,
    eye_model: Option<PathBuf>,
    ort_library: Option<PathBuf>,
    mirror: bool,
    vts_iphone: bool,
    ifacialmocap: Option<String>,
}

fn landmark_runtime(name: &str, models: &std::path::Path) -> Result<LandmarkRuntime, String> {
    Ok(match name {
        "ort-cpu" => LandmarkRuntime::OrtCpu,
        "cuda" => LandmarkRuntime::Ort(Provider::Cuda),
        "tensorrt" => LandmarkRuntime::Ort(Provider::TensorRt { cache: models.join("cache/tensorrt-core") }),
        #[cfg(feature = "ncnn")]
        "vulkan" => LandmarkRuntime::Vulkan { fp16: true },
        #[cfg(feature = "ncnn")]
        "vulkan-fp32" => LandmarkRuntime::Vulkan { fp16: false },
        #[cfg(feature = "ncnn")]
        "ncnn-cpu" => LandmarkRuntime::NcnnCpu,
        other => return Err(format!("runtime {other} is not available in this build of the core")),
    })
}

/// The worker: models, camera, then frames until stopped. Mirrors serve.py's loop and its status messages.
fn run(cfg: Config, s: Arc<Shared>) {
    let source = format!("camera {}", cfg.camera);
    let texts = |extra: &[(&str, &str)]| -> Vec<(String, String)> {
        let mut t = vec![("source".to_string(), source.clone()), ("tracker".into(), "facemesh-core".into())];
        t.extend(extra.iter().map(|(k, v)| (k.to_string(), v.to_string())));
        t
    };
    s.status("starting", "loading tracker facemesh-core", vec![], texts(&[]));
    if let Some(lib) = &cfg.ort_library {
        if cfg.runtime == "cuda" || cfg.runtime == "tensorrt" {
            // .../site-packages/onnxruntime/capi/libonnxruntime.so -> .../site-packages
            if let Some(site) = lib.parent().and_then(|p| p.parent()).and_then(|p| p.parent()) {
                s.log(format!("preloaded {} NVIDIA libraries", preload_nvidia(site)));
            }
        }
        if let Err(e) = ort_runtime(Some(lib)) {
            s.status("error", &format!("ONNX Runtime did not load: {e}"), vec![], texts(&[]));
            return;
        }
    }
    let runtime = match landmark_runtime(&cfg.runtime, &cfg.models) {
        Ok(r) => r,
        Err(e) => return s.status("error", &e, vec![], texts(&[])),
    };
    let mediapipe = cfg.models.join("mediapipe");
    let fit = cfg.models.join("core/fit.npz");
    let paths = ModelPaths { mediapipe: &mediapipe, fit: &fit, eyes: cfg.eye_model.as_deref() };
    let mut tracker = match Tracker::open_on(&paths, runtime, 4) {
        Ok(t) => t,
        Err(e) => return s.status("error", &format!("tracker failed to start: {e}"), vec![], texts(&[])),
    };
    let runtime_name = tracker.mesh.runtime.clone();
    s.log(format!("tracker facemesh-core on {runtime_name}"));
    let camera = match Camera::open(cfg.camera, 1280, 720, 30) {
        Ok(c) => c,
        Err(e) => {
            return s.status("error", &format!("cannot open camera {}: {e}. Check that no other app uses it, or pick another camera.", cfg.camera),
                            vec![], texts(&[]));
        }
    };
    s.log(format!("camera {}: {}", cfg.camera, camera.mode));
    let mut vts = None;
    if cfg.vts_iphone {
        match VtsIphoneSink::open(VTS_REQUEST_PORT) {
            Ok(v) => {
                s.log(format!("VTS iPhone protocol: answering requests on UDP {VTS_REQUEST_PORT}"));
                vts = Some(v);
            }
            Err(e) => s.log(format!("VTS iPhone protocol: port {VTS_REQUEST_PORT} unavailable ({e})")),
        }
    }
    let mut ifm = None;
    if let Some(host) = &cfg.ifacialmocap {
        match IFacialMocapSink::open(host) {
            Ok(m) => {
                s.log(format!("iFacialMocap: sending to {host}:49983"));
                ifm = Some(m);
            }
            Err(e) => s.log(format!("iFacialMocap: {e}")),
        }
    }
    let start = Instant::now();
    let (mut seq, mut sent, mut report) = (0u64, 0u32, Instant::now());
    let (mut infer_ms, mut calibrated) = (0.0f64, false);
    while !s.stop.load(Ordering::Relaxed) {
        let frame = match camera.next(seq) {
            Ok(f) => f,
            Err(e) => return s.status("error", &format!("{e} (unplugged or used by another app?)"), vec![], texts(&[])),
        };
        seq = frame.sequence;
        if s.calibrate.swap(false, Ordering::Relaxed) {
            tracker.pipeline.recalibrate();
            s.log("collecting the neutral for the app".into());
        }
        let t = Instant::now();
        let out = match tracker.process(&frame.image, start.elapsed().as_millis() as i64) {
            Ok(o) => o,
            Err(e) => return s.status("error", &format!("tracking failed: {e}"), vec![], texts(&[])),
        };
        infer_ms = 0.9 * infer_ms + 100.0 * t.elapsed().as_secs_f64();
        let last_found = out.is_some();
        let finished = out.as_ref().map(|o| &o.final_frame);
        if let Some(v) = vts.as_mut() {
            v.send(finished);
        }
        if let Some(m) = ifm.as_mut() {
            m.send(finished);
        }
        let f = match &out {
            Some(o) => {
                calibrated |= o.calibrated;
                FrameOut { found: true, vts: vts_params(&o.final_frame, cfg.mirror), arkit: o.final_frame.blendshapes,
                           glare: o.frame.lens_glare }
            }
            None => FrameOut { found: false, vts: vec![], arkit: [0.0; 52], glare: None },
        };
        *s.frame.lock().unwrap() = Some(f);
        sent += 1;
        if report.elapsed().as_secs_f64() >= 1.0 {
            let fps = sent as f64 / report.elapsed().as_secs_f64();
            sent = 0;
            report = Instant::now();
            let numbers = vec![("fps".into(), (fps * 10.0).round() / 10.0), ("infer_ms".into(), (infer_ms * 10.0).round() / 10.0),
                               ("face".into(), last_found as u8 as f64), ("calibrated".into(), calibrated as u8 as f64),
                               ("commercial_use".into(), 1.0)];
            s.status("running", if last_found { "tracking" } else { "no face in view" }, numbers,
                     texts(&[("runtime", &format!("{runtime_name} (Rust core)"))]));
        }
    }
}

