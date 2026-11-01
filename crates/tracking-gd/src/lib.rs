//! YorishiroCore: the tracking core as a Godot node. poll() returns status messages and the newest frame
//! ({found, vts, arkit, glare, hands}) as dictionaries, the messages the Python tracker process once sent
//! over UDP, for the app's tracker input (yorishiro_tracker.gd). Camera (or a replayed recording),
//! inference and fit run in a thread.

use godot::prelude::*;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Instant;
use yorishiro_tracking::backend::runtime as ort_runtime;
use yorishiro_tracking::camera::{Camera, Frame};
use yorishiro_tracking::frame::ARKIT52;
use yorishiro_tracking::hands::{hand_params, HandTracker};
use yorishiro_tracking::image::Image;
use yorishiro_tracking::inference::LandmarkRuntime;
use yorishiro_tracking::recording::Recording;
use yorishiro_tracking::sinks::{IFacialMocapSink, VtsIphoneSink, VTS_REQUEST_PORT};
use yorishiro_tracking::tracker::{ModelPaths, Tracker};
use yorishiro_tracking::vts::vts_params;

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
    /// Hand* inputs by the avatar's sides, when hand tracking runs
    hands: Option<Vec<(String, f64)>>,
    /// 21 world points per hand, by the avatar's sides, flipped left to right when mirrored
    hand_points: Vec<(String, Vec<[f64; 3]>)>,
}

/// Hand tracking beside the face: its own thread on the newest picture, the
/// face never waits for it.
struct HandWorker {
    latest: Arc<(Mutex<Option<Image>>, std::sync::Condvar)>,
    result: Arc<Mutex<(Vec<(String, f64)>, Vec<(String, Vec<[f64; 3]>)>)>>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

/// share of the previous value kept per result
const HAND_SMOOTHING: f64 = 0.5;

impl HandWorker {
    fn start(mut tracker: HandTracker) -> Self {
        let latest: Arc<(Mutex<Option<Image>>, std::sync::Condvar)> = Arc::new((Mutex::new(None), std::sync::Condvar::new()));
        let result = Arc::new(Mutex::new((vec![], vec![])));
        let stop = Arc::new(AtomicBool::new(false));
        let (l, r, st) = (latest.clone(), result.clone(), stop.clone());
        let thread = std::thread::Builder::new().name("yorishiro-hands".into()).spawn(move || {
            let mut prev: Vec<(String, f64)> = vec![];
            loop {
                let img = {
                    let mut g = l.0.lock().unwrap();
                    while g.is_none() && !st.load(Ordering::Relaxed) {
                        g = l.1.wait(g).unwrap();
                    }
                    if st.load(Ordering::Relaxed) {
                        return;
                    }
                    g.take().unwrap()
                };
                let Ok(hands) = tracker.process(&img) else { continue };
                let mut params = hand_params(&hands, img.width as f64, img.height as f64);
                for (k, v) in params.iter_mut() {
                    // a hand that just appeared starts at its value; angles near +-180 are not averaged across the wrap
                    let angle = k.ends_with("AngleX") || k.ends_with("AngleZ");
                    if let Some((_, p)) = prev.iter().find(|(pk, _)| pk == k) {
                        if !k.ends_with("Found") && !(angle && (*v - p).abs() > 180.0) {
                            *v = HAND_SMOOTHING * p + (1.0 - HAND_SMOOTHING) * *v;
                        }
                    }
                }
                prev = params.clone();
                let points = hands.iter().map(|h| ((if h.right { "Right" } else { "Left" }).to_string(), h.world.clone())).collect();
                *r.lock().unwrap() = (params, points);
            }
        }).ok();
        Self { latest, result, stop, thread }
    }

    fn submit(&self, img: &Image) {
        *self.latest.0.lock().unwrap() = Some(img.clone());
        self.latest.1.notify_one();
    }
}

impl Drop for HandWorker {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        self.latest.1.notify_all();
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

/// Person's sides to the avatar's: mirrored, the user's left hand moves the avatar's right one.
fn avatar_side(name: &str, mirror: bool) -> String {
    if !mirror {
        return name.to_string();
    }
    name.replace("Left", "\u{0}").replace("Right", "Left").replace('\u{0}', "Right")
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
    /// vulkan, vulkan-fp32, ncnn-cpu (when built with ncnn), ort-cpu
    #[export]
    #[init(val = GString::from("ort-cpu"))]
    runtime: GString,
    /// a recording folder (meta.json, frames/) to replay in a loop instead of the camera, empty for the camera
    #[export]
    replay: GString,
    /// the models folder (mediapipe/, core/fit.npz)
    #[export]
    models_dir: GString,
    /// the eye openness model (models/eye_openness.onnx), empty for the lid gap
    #[export]
    eye_model: GString,
    /// libonnxruntime.so to load (the official CPU build), empty for ORT_DYLIB_PATH or the system's
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
    /// also track hands (the Hand* inputs and the preview's hands)
    #[export]
    track_hands: bool,
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
            replay: Some(self.replay.to_string()).filter(|s| !s.is_empty()).map(PathBuf::from),
            runtime: self.runtime.to_string(),
            models: PathBuf::from(self.models_dir.to_string()),
            eye_model: Some(self.eye_model.to_string()).filter(|s| !s.is_empty()).map(PathBuf::from),
            ort_library: Some(self.ort_library.to_string()).filter(|s| !s.is_empty()).map(PathBuf::from),
            mirror: self.mirror,
            vts_iphone: self.send_vts_iphone,
            ifacialmocap: Some(self.ifacialmocap_host.to_string()).filter(|s| !s.is_empty()),
            hands: self.track_hands,
        };
        let s = shared.clone();
        self.worker = std::thread::Builder::new().name("yorishiro-tracking".into()).spawn(move || run(cfg, s)).ok();
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

    /// A new neutral from the next faces.
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
                // booleans in the messages
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
            if let Some(hands) = &f.hands {
                let mut h = VarDictionary::new();
                for (k, v) in hands {
                    h.set(k.as_str(), *v);
                }
                d.set("hands", &h);
                let mut pts = VarDictionary::new();
                for (side, points) in &f.hand_points {
                    let mut list = VarArray::new();
                    for p in points {
                        list.push(&PackedFloat64Array::from(&p[..]).to_variant());
                    }
                    pts.set(side.as_str(), &list);
                }
                d.set("hand_points", &pts);
            }
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
    replay: Option<PathBuf>,
    runtime: String,
    models: PathBuf,
    eye_model: Option<PathBuf>,
    ort_library: Option<PathBuf>,
    mirror: bool,
    vts_iphone: bool,
    ifacialmocap: Option<String>,
    hands: bool,
}

fn landmark_runtime(name: &str) -> Result<LandmarkRuntime, String> {
    Ok(match name {
        "ort-cpu" => LandmarkRuntime::OrtCpu,
        #[cfg(feature = "ncnn")]
        "vulkan" => LandmarkRuntime::Vulkan { fp16: true },
        #[cfg(feature = "ncnn")]
        "vulkan-fp32" => LandmarkRuntime::Vulkan { fp16: false },
        #[cfg(feature = "ncnn")]
        "ncnn-cpu" => LandmarkRuntime::NcnnCpu,
        other => return Err(format!("runtime {other} is not available in this build of the core")),
    })
}

/// CPU threads for the networks (examples/cpu_profile on a 4 core i3): ncnn's CPU path was fastest and
/// cheapest on one thread (15 ms per frame, 15 ms CPU; four threads 18 ms for 30 ms CPU), ONNX Runtime as fast
/// on two as on four (22 ms) for 9 ms less CPU. GPU runtimes use the CPU for little more than the copies.
fn cpu_threads(runtime: &LandmarkRuntime) -> usize {
    match runtime {
        #[cfg(feature = "ncnn")]
        LandmarkRuntime::NcnnCpu => 1,
        _ => 2,
    }
}

enum Source {
    Camera(Camera),
    Recording(Recording),
}

impl Source {
    fn next(&mut self, after: u64) -> Result<Frame, String> {
        match self {
            Source::Camera(c) => c.next(after),
            Source::Recording(r) => r.next(),
        }
    }
}

/// The worker: models, camera, then frames until stopped.
fn run(cfg: Config, s: Arc<Shared>) {
    let source = match &cfg.replay {
        Some(dir) => format!("recording {}", dir.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()),
        None => format!("camera {}", cfg.camera),
    };
    let texts = |extra: &[(&str, &str)]| -> Vec<(String, String)> {
        let mut t = vec![("source".to_string(), source.clone()), ("tracker".into(), "facemesh-core".into())];
        t.extend(extra.iter().map(|(k, v)| (k.to_string(), v.to_string())));
        t
    };
    s.status("starting", "loading tracker facemesh-core", vec![], texts(&[]));
    if let Err(e) = ort_runtime(cfg.ort_library.as_deref()) {
        return s.status("error", &format!("ONNX Runtime did not load: {e}"), vec![], texts(&[]));
    }
    let runtime = match landmark_runtime(&cfg.runtime) {
        Ok(r) => r,
        Err(e) => return s.status("error", &e, vec![], texts(&[])),
    };
    let mediapipe = cfg.models.join("mediapipe");
    let fit = cfg.models.join("core/fit.npz");
    let paths = ModelPaths { mediapipe: &mediapipe, fit: &fit, eyes: cfg.eye_model.as_deref() };
    let threads = cpu_threads(&runtime);
    let mut tracker = match Tracker::open_on(&paths, runtime, threads) {
        Ok(t) => t,
        Err(e) => return s.status("error", &format!("tracker failed to start: {e}"), vec![], texts(&[])),
    };
    let runtime_name = tracker.mesh.runtime.clone();
    s.log(format!("tracker facemesh-core on {runtime_name}"));
    let mut camera = match &cfg.replay {
        Some(dir) => match Recording::open(dir, true) {
            Ok(r) => {
                s.log(format!("replaying {}", dir.display()));
                Source::Recording(r)
            }
            Err(e) => return s.status("error", &format!("cannot replay: {e}"), vec![], texts(&[])),
        },
        None => match Camera::open(cfg.camera, 1280, 720, 30) {
            Ok(c) => {
                s.log(format!("camera {}: {}", cfg.camera, c.mode));
                Source::Camera(c)
            }
            Err(e) => {
                return s.status("error", &format!("cannot open camera {}: {e}. Check that no other app uses it, or pick another camera.", cfg.camera),
                                vec![], texts(&[]));
            }
        },
    };
    let hand_worker = if cfg.hands {
        match HandTracker::open(&cfg.models.join("mediapipe/hands"), &landmark_runtime(&cfg.runtime).unwrap_or(LandmarkRuntime::OrtCpu), threads) {
            Ok(t) => {
                s.log(format!("hand tracking on {}", t.runtime));
                Some(HandWorker::start(t))
            }
            Err(e) => {
                s.log(format!("hand tracking unavailable: {e}"));
                None
            }
        }
    } else {
        None
    };
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
        if let Some(h) = &hand_worker {
            h.submit(&frame.image);
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
        let mut f = match &out {
            Some(o) => {
                calibrated |= o.calibrated;
                FrameOut { found: true, vts: vts_params(&o.final_frame, cfg.mirror), arkit: o.final_frame.blendshapes,
                           glare: o.frame.lens_glare, hands: None, hand_points: vec![] }
            }
            None => FrameOut { found: false, vts: vec![], arkit: [0.0; 52], glare: None, hands: None, hand_points: vec![] },
        };
        if let Some(h) = &hand_worker {
            let (params, points) = h.result.lock().unwrap().clone();
            f.hands = Some(params.into_iter().map(|(k, v)| (avatar_side(&k, cfg.mirror), v)).collect());
            let flip = if cfg.mirror { -1.0 } else { 1.0 };
            f.hand_points = points.into_iter().map(|(side, pts)| (avatar_side(&side, cfg.mirror), pts.into_iter().map(|p| [p[0] * flip, p[1], p[2]]).collect())).collect();
        }
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

