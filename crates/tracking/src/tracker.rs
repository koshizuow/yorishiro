//! The whole tracker on pictures: landmarks, then the pipeline with the eye model, MediaPipe's mouth and the
//! lens glare (trackers/facemesh_gpu.py with serve.py's calibration and smoothing).

use crate::backend::Error;
use crate::fit::Fitter;
use crate::glare::lens_glare;
use crate::image::Image;
use crate::inference::{eye_widths, Blendshapes, Eyes, FaceMesh, LandmarkRuntime};
use crate::pipeline::{Extras, Output, Pipeline};
use std::path::Path;

/// Flip averaging (the landmark model also on the mirrored crop) when one pass takes at most this long:
/// a quarter of a 30 fps frame, the Python tracker's FLIP_MAX_PASS_MS. Steadier still faces, mouth and cheeks.
pub const FLIP_MAX_PASS_MS: f64 = 8.0;

pub struct Tracker {
    pub mesh: FaceMesh,
    blend: Blendshapes,
    eyes: Option<Eyes>,
    pub pipeline: Pipeline,
    /// whole-frame times (ms) and the gaps between the frames' timestamps since the last flip decision
    frame_times: Vec<f64>,
    intervals: Vec<f64>,
    last_timestamp: Option<i64>,
    /// time per frame (ms, smoothed) in the landmark stage (detector, crop, passes), the blendshape model and
    /// the eye model, for the status
    pub stage_ms: [f64; 3],
}

/// Where the models are: MediaPipe's (face_detector, face_landmarks, face_blendshapes .onnx), the fit data,
/// and the eye model.
pub struct ModelPaths<'a> {
    pub mediapipe: &'a Path,
    pub fit: &'a Path,
    pub eyes: Option<&'a Path>,
}

impl Tracker {
    pub fn open(paths: &ModelPaths, threads: usize) -> Result<Self, Error> {
        Self::open_on(paths, LandmarkRuntime::OrtCpu, threads)
    }

    /// With the landmark model on the given runtime.
    pub fn open_on(paths: &ModelPaths, runtime: LandmarkRuntime, threads: usize) -> Result<Self, Error> {
        let mut mesh = FaceMesh::open_on(paths.mediapipe, runtime, threads)?;
        let pass = mesh.pass_ms()?;
        if pass <= FLIP_MAX_PASS_MS {
            mesh.flip_mirror = Some(Self::mirror_table(paths)?);
        }
        mesh.runtime = format!("{} (pass {pass:.1} ms)", mesh.runtime);
        Ok(Self {
            mesh,
            blend: Blendshapes::open(&paths.mediapipe.join("face_blendshapes.onnx"))?,
            eyes: paths.eyes.map(Eyes::open).transpose()?,
            pipeline: Pipeline::new(Fitter::load(paths.fit).map_err(|e| e.to_string())?),
            frame_times: Vec::new(),
            intervals: Vec::new(),
            last_timestamp: None,
            stage_ms: [0.0; 3],
        })
    }

    /// The landmark pairs that swap in a mirrored face
    fn mirror_table(paths: &ModelPaths) -> Result<Vec<usize>, Error> {
        let mut fit = crate::data::Npz::open(paths.fit).map_err(|e| e.to_string())?;
        Ok(fit.ints("flip_mirror").map_err(|e| e.to_string())?)
    }

    /// Flip averaging decided again from the pass times while tracking (FaceMesh::adapt_flip), for live use
    pub fn adapt_flip(&mut self, paths: &ModelPaths) -> Result<(), Error> {
        self.mesh.adapt_flip(Self::mirror_table(paths)?);
        Ok(())
    }

    /// The landmark runtime as the status shows it, with flip averaging as it is now
    pub fn runtime_name(&self) -> String {
        format!("{}{}", self.mesh.runtime, if self.mesh.flip_mirror.is_some() { " flip-averaged" } else { "" })
    }

    /// One picture: None when no face was found.
    pub fn process(&mut self, img: &Image, timestamp_ms: i64) -> Result<Option<Output>, Error> {
        let start = std::time::Instant::now();
        let Some(lm) = self.mesh.process(img)? else {
            self.pipeline.lost();
            return Ok(None);
        };
        smooth(&mut self.stage_ms[0], start.elapsed());
        let out = self.process_landmarks(img, &lm.points, timestamp_ms)?;
        self.note_frame(start.elapsed().as_secs_f64() * 1000.0, timestamp_ms);
        Ok(Some(out))
    }

    /// Frame times against the time between frames, for adaptive flip averaging
    fn note_frame(&mut self, ms: f64, timestamp_ms: i64) {
        if let Some(last) = self.last_timestamp.replace(timestamp_ms) {
            if timestamp_ms > last {
                self.intervals.push((timestamp_ms - last) as f64);
            }
        }
        self.frame_times.push(ms);
        if self.frame_times.len() >= 30 && !self.intervals.is_empty() {
            let frame = crate::fit::median(&mut self.frame_times);
            // the shortest gap between frames the tracker took: about the camera's interval while it keeps up,
            // about its own frame time when it does not (it never waits then)
            let interval = self.intervals.iter().copied().fold(f64::MAX, f64::min);
            self.frame_times.clear();
            self.intervals.clear();
            self.mesh.adapt(frame, interval);
        }
    }

    /// Everything after the landmarks, for landmarks found elsewhere (tests feed the Python tracker's).
    pub fn process_landmarks(&mut self, img: &Image, points: &[crate::P3], timestamp_ms: i64) -> Result<Output, Error> {
        let (w, h) = (img.width as f64, img.height as f64);
        let mut failure = None;
        let (blend, eyes, stage_ms) = (&mut self.blend, &mut self.eyes, &mut self.stage_ms);
        let out = self.pipeline.process_with(points, w, h, timestamp_ms, &mut |smoothed| {
            let mut x = Extras { lens_glare: Some(lens_glare(img, smoothed)), ..Default::default() };
            let t = std::time::Instant::now();
            match blend.run(smoothed, w, h) {
                Ok(m) => x.mouth = Some(m),
                Err(e) => failure = Some(e),
            }
            smooth(&mut stage_ms[1], t.elapsed());
            if let Some(eyes) = eyes.as_mut() {
                let t = std::time::Instant::now();
                let r = eyes.run(img, smoothed);
                smooth(&mut stage_ms[2], t.elapsed());
                match r {
                    Ok(o) => x.eye_open = Some(o),
                    Err(e) => failure = Some(e),
                }
                x.eye_widths = Some(eye_widths(smoothed, w, h));
            }
            x
        });
        match failure {
            Some(e) => Err(e),
            None => Ok(out),
        }
    }
}

/// A running average of a stage's time in ms, as the status's infer_ms
fn smooth(avg: &mut f64, d: std::time::Duration) {
    *avg = 0.9 * *avg + 100.0 * d.as_secs_f64();
}
