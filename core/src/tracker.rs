//! The whole tracker on pictures: landmarks, then the pipeline with the eye model, MediaPipe's mouth and the
//! lens glare (trackers/facemesh_gpu.py with serve.py's calibration and smoothing).

use crate::backend::Error;
use crate::fit::Fitter;
use crate::glare::lens_glare;
use crate::image::Image;
use crate::inference::{eye_widths, Blendshapes, Eyes, FaceMesh, LandmarkRuntime};
use crate::pipeline::{Extras, Output, Pipeline};
use std::path::Path;

pub struct Tracker {
    pub mesh: FaceMesh,
    blend: Blendshapes,
    eyes: Option<Eyes>,
    pub pipeline: Pipeline,
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
        Ok(Self {
            mesh: FaceMesh::open_on(paths.mediapipe, runtime, threads)?,
            blend: Blendshapes::open(&paths.mediapipe.join("face_blendshapes.onnx"))?,
            eyes: paths.eyes.map(Eyes::open).transpose()?,
            pipeline: Pipeline::new(Fitter::load(paths.fit).map_err(|e| e.to_string())?),
        })
    }

    /// One picture: None when no face was found.
    pub fn process(&mut self, img: &Image, timestamp_ms: i64) -> Result<Option<Output>, Error> {
        let Some(lm) = self.mesh.process(img)? else {
            self.pipeline.lost();
            return Ok(None);
        };
        self.process_landmarks(img, &lm.points, timestamp_ms).map(Some)
    }

    /// Everything after the landmarks, for landmarks found elsewhere (tests feed the Python tracker's).
    pub fn process_landmarks(&mut self, img: &Image, points: &[crate::P3], timestamp_ms: i64) -> Result<Output, Error> {
        let (w, h) = (img.width as f64, img.height as f64);
        let mut failure = None;
        let (blend, eyes) = (&mut self.blend, &mut self.eyes);
        let out = self.pipeline.process_with(points, w, h, timestamp_ms, &mut |smoothed| {
            let mut x = Extras { lens_glare: Some(lens_glare(img, smoothed)), ..Default::default() };
            match blend.run(smoothed, w, h) {
                Ok(m) => x.mouth = Some(m),
                Err(e) => failure = Some(e),
            }
            if let Some(eyes) = eyes.as_mut() {
                match eyes.run(img, smoothed) {
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
