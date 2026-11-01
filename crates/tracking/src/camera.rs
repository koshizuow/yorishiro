//! Webcam capture on Linux (V4L2, `v4l` crate), like the Python tracker's OpenCV capture (capture.py): MJPG at
//! the asked size and rate when the camera offers it, YUYV otherwise. A thread keeps only the newest frame,
//! so a slow tracker never works through a queue of old pictures.

use crate::image::Image;
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::Instant;
use v4l::buffer::Type;
use v4l::io::traits::CaptureStream;
use v4l::prelude::*;
use v4l::video::Capture;
use v4l::FourCC;

pub struct Frame {
    pub image: Image,
    /// counts every frame the camera delivered, so a reader sees how many it skipped
    pub sequence: u64,
    pub at: Instant,
}

struct Shared {
    latest: Mutex<(Option<Frame>, Option<String>)>,
    fresh: Condvar,
    stop: std::sync::atomic::AtomicBool,
}

pub struct Camera {
    shared: Arc<Shared>,
    thread: Option<JoinHandle<()>>,
    /// what the camera agreed to, e.g. "MJPG 1280x720 30 fps"
    pub mode: String,
}

/// YUYV (YUV 4:2:2, limited range, BT.601) to RGB exactly as OpenCV's COLOR_YUV2RGB_YUYV: 20 bit fixed
/// point coefficients, Y - 16 clamped at 0.
pub fn yuyv_to_rgb(data: &[u8], width: usize, height: usize) -> Image {
    const SHIFT: i32 = 20;
    const CY: i32 = 1220542;
    const CUB: i32 = 2116026;
    const CUG: i32 = -409993;
    const CVG: i32 = -852492;
    const CVR: i32 = 1673527;
    let mut img = Image::new(width, height);
    let sat = |v: i32| (v >> SHIFT).clamp(0, 255) as u8;
    for (i, quad) in data.chunks_exact(4).take(width * height / 2).enumerate() {
        let (u, v) = (quad[1] as i32 - 128, quad[3] as i32 - 128);
        let half = 1 << (SHIFT - 1);
        let (ruv, guv, buv) = (half + CVR * v, half + CVG * v + CUG * u, half + CUB * u);
        for (k, y) in [quad[0], quad[2]].into_iter().enumerate() {
            let y = (y as i32 - 16).max(0) * CY;
            let o = i * 6 + k * 3;
            img.rgb[o] = sat(y + ruv);
            img.rgb[o + 1] = sat(y + guv);
            img.rgb[o + 2] = sat(y + buv);
        }
    }
    img
}

fn decode_mjpg(data: &[u8]) -> Option<Image> {
    let img = image::load_from_memory_with_format(data, image::ImageFormat::Jpeg).ok()?.to_rgb8();
    Some(Image { width: img.width() as usize, height: img.height() as usize, rgb: img.into_raw() })
}

impl Camera {
    /// /dev/video<index>, asking for width x height at fps.
    pub fn open(index: usize, width: u32, height: u32, fps: u32) -> std::io::Result<Self> {
        let dev = Device::new(index)?;
        let mut fmt = dev.format()?;
        fmt.width = width;
        fmt.height = height;
        fmt.fourcc = FourCC::new(b"MJPG");
        let mut fmt = dev.set_format(&fmt)?;
        if fmt.fourcc != FourCC::new(b"MJPG") {
            fmt.fourcc = FourCC::new(b"YUYV");
            fmt = dev.set_format(&fmt)?;
        }
        if fmt.fourcc != FourCC::new(b"MJPG") && fmt.fourcc != FourCC::new(b"YUYV") {
            return Err(std::io::Error::other(format!("camera {index} offers neither MJPG nor YUYV ({})", fmt.fourcc)));
        }
        let _ = dev.set_params(&v4l::video::capture::Parameters::with_fps(fps));
        let got_fps = dev.params().ok().map(|p| p.interval.denominator as f64 / p.interval.numerator.max(1) as f64).unwrap_or(0.0);
        let mode = format!("{} {}x{} {:.0} fps", fmt.fourcc, fmt.width, fmt.height, got_fps);
        let shared = Arc::new(Shared {
            latest: Mutex::new((None, None)),
            fresh: Condvar::new(),
            stop: std::sync::atomic::AtomicBool::new(false),
        });
        let s = shared.clone();
        let (w, h, mjpg) = (fmt.width as usize, fmt.height as usize, fmt.fourcc == FourCC::new(b"MJPG"));
        let thread = std::thread::Builder::new().name("camera".into()).spawn(move || {
            let mut stream = match MmapStream::with_buffers(&dev, Type::VideoCapture, 4) {
                Ok(s) => s,
                Err(e) => {
                    s.latest.lock().unwrap().1 = Some(format!("cannot stream: {e}"));
                    s.fresh.notify_all();
                    return;
                }
            };
            let mut sequence = 0;
            while !s.stop.load(std::sync::atomic::Ordering::Relaxed) {
                let (buf, meta) = match stream.next() {
                    Ok(x) => x,
                    Err(e) => {
                        s.latest.lock().unwrap().1 = Some(format!("camera stopped delivering frames: {e}"));
                        s.fresh.notify_all();
                        return;
                    }
                };
                let used = &buf[..(meta.bytesused as usize).min(buf.len()).max(if mjpg { 0 } else { w * h * 2 })];
                let image = if mjpg { decode_mjpg(used) } else { Some(yuyv_to_rgb(used, w, h)) };
                sequence += 1;
                if let Some(image) = image {
                    s.latest.lock().unwrap().0 = Some(Frame { image, sequence, at: Instant::now() });
                    s.fresh.notify_all();
                }
            }
        })?;
        Ok(Self { shared, thread: Some(thread), mode })
    }

    /// The newest frame after `after` (a sequence number), waiting for one; None when the camera stopped,
    /// with the reason.
    pub fn next(&self, after: u64) -> Result<Frame, String> {
        let mut g = self.shared.latest.lock().unwrap();
        loop {
            if let Some(e) = &g.1 {
                return Err(e.clone());
            }
            if g.0.as_ref().map(|f| f.sequence > after).unwrap_or(false) {
                return Ok(g.0.take().unwrap());
            }
            g = self.shared.fresh.wait(g).unwrap();
        }
    }
}

impl Drop for Camera {
    fn drop(&mut self) {
        self.shared.stop.store(true, std::sync::atomic::Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}
