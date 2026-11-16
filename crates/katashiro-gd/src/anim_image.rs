//! AnimatedImage: decodes animated pictures for items and backgrounds (VTube Studio takes GIFs; APNG and animated
//! WebP come along): every frame composited to the full canvas as an RGBA8 Image, with its delay. A still picture
//! gives one frame. Godot itself loads only still images.

use godot::classes::image::Format;
use godot::classes::Image;
use godot::prelude::*;
use image::codecs::gif::GifDecoder;
use image::codecs::png::PngDecoder;
use image::codecs::webp::WebPDecoder;
use image::{AnimationDecoder, Frames};
use std::fs::File;
use std::io::BufReader;

/// the decoded frames must fit in this much memory
const MAX_BYTES: usize = 768 << 20;
/// a frame delay of 0 (common in GIFs) plays as browsers do, at 10 fps
const DEFAULT_DELAY: f32 = 0.1;

#[derive(GodotClass)]
#[class(base=RefCounted, init)]
pub struct AnimatedImage {}

fn frames_of(path: &str) -> Result<Option<Frames<'static>>, String> {
    let ext = path.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    let open = || File::open(path).map(BufReader::new).map_err(|e| format!("{path}: {e}"));
    let err = |e: image::ImageError| e.to_string();
    Ok(match ext.as_str() {
        "gif" => Some(GifDecoder::new(open()?).map_err(err)?.into_frames()),
        "png" | "apng" => {
            let d = PngDecoder::new(open()?).map_err(err)?;
            if d.is_apng().map_err(err)? { Some(d.apng().map_err(err)?.into_frames()) } else { None }
        }
        "webp" => {
            let d = WebPDecoder::new(open()?).map_err(err)?;
            if d.has_animation() { Some(d.into_frames()) } else { None }
        }
        _ => None,
    })
}

#[godot_api]
impl AnimatedImage {
    /// {"frames": Array[Image], "delays": PackedFloat32Array (seconds), "error": String}. A picture that is not
    /// animated (or a format without animation) gives no frames and no error: load it as a still image.
    #[func]
    fn decode(path: GString) -> VarDictionary {
        let mut out = VarDictionary::new();
        let mut images: Array<Gd<Image>> = Array::new();
        let mut delays = PackedFloat32Array::new();
        let mut error = String::new();
        match frames_of(&path.to_string()) {
            Ok(Some(frames)) => {
                let mut bytes = 0usize;
                for f in frames {
                    let f = match f {
                        Ok(f) => f,
                        Err(e) => {
                            error = e.to_string();
                            break;
                        }
                    };
                    let (n, d) = f.delay().numer_denom_ms();
                    let secs = if n == 0 || d == 0 { DEFAULT_DELAY } else { n as f32 / d as f32 / 1000.0 };
                    let buf = f.into_buffer();
                    let (w, h) = buf.dimensions();
                    bytes += (w * h * 4) as usize;
                    if bytes > MAX_BYTES {
                        error = format!("too large to keep in memory ({} frames of {w}x{h} so far)", images.len());
                        break;
                    }
                    let data = PackedByteArray::from(buf.into_raw().as_slice());
                    match Image::create_from_data(w as i32, h as i32, false, Format::RGBA8, &data) {
                        Some(img) => {
                            images.push(&img);
                            delays.push(secs.max(0.02));
                        }
                        None => {
                            error = "could not make a Godot image".into();
                            break;
                        }
                    }
                }
            }
            Ok(None) => {}
            Err(e) => error = e,
        }
        out.set("frames", &images);
        out.set("delays", &delays);
        out.set("error", &GString::from(error.as_str()));
        out
    }
}
