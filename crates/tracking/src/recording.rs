//! Replaying a recording in place of the camera, for the app's automation tests and for checks without a
//! webcam: a folder with meta.json ({"timestamps_ms": [...]}) and frames/00000.jpg, 00001.jpg, ... Frames come
//! at their recorded times; a reader that falls behind gets the newest one, as from a camera.

use crate::camera::Frame;
use crate::image::Image;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub struct Recording {
    dir: PathBuf,
    timestamps_ms: Vec<u64>,
    looped: bool,
    start: Instant,
    /// frames handed out, counting every loop
    sequence: u64,
}

impl Recording {
    pub fn open(dir: &Path, looped: bool) -> Result<Self, String> {
        let meta = std::fs::read_to_string(dir.join("meta.json")).map_err(|e| format!("{}: {e}", dir.join("meta.json").display()))?;
        let meta: serde_json::Value = serde_json::from_str(&meta).map_err(|e| format!("meta.json: {e}"))?;
        let ts: Vec<u64> = meta["timestamps_ms"].as_array().map(|a| a.iter().filter_map(|v| v.as_u64()).collect()).unwrap_or_default();
        if ts.is_empty() {
            return Err(format!("{}: no timestamps_ms", dir.join("meta.json").display()));
        }
        let first = ts[0];
        Ok(Self { dir: dir.into(), timestamps_ms: ts.into_iter().map(|t| t - first).collect(), looped, start: Instant::now(), sequence: 0 })
    }

    /// The frame due now, waiting for the next one when the reader is ahead; Err at the end when not looping.
    pub fn next(&mut self) -> Result<Frame, String> {
        let n = self.timestamps_ms.len() as u64;
        let length = self.timestamps_ms[self.timestamps_ms.len() - 1] + 1;
        let at = |seq: u64| (seq / n) * length + self.timestamps_ms[(seq % n) as usize];
        // the newest frame whose time has come, never one handed out before
        let elapsed = self.start.elapsed().as_millis() as u64;
        let mut seq = self.sequence;
        while at(seq + 1) <= elapsed && (self.looped || seq + 1 < n) {
            seq += 1;
        }
        if !self.looped && seq >= n {
            return Err("recording finished".into());
        }
        let due = Duration::from_millis(at(seq));
        if let Some(wait) = due.checked_sub(self.start.elapsed()) {
            std::thread::sleep(wait);
        }
        self.sequence = seq + 1;
        let path = self.dir.join("frames").join(format!("{:05}.jpg", seq % n));
        let image = Image::load(&path)?;
        Ok(Frame { image, sequence: seq + 1, at: Instant::now() })
    }
}
