use std::fs::OpenOptions;
use std::io::Write;

use godot::prelude::*;
use godot::classes::RenderingServer;
use godot::classes::Viewport;
use godot::classes::Engine;

use v4l::prelude::*;
use v4l::v4l_sys::v4l2_format;
use v4l::v4l_sys::v4l2_format__bindgen_ty_1;
use v4l::v4l2;
use v4l::capability::Flags;

/// YUYV (BT.601, limited range): the format camera readers take, AB24 was refused by ffmpeg. The node's viewport is
/// opaque: the stage over the chosen background (stage.gd).
fn rgba_to_yuyv(rgba: &[u8], width: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(rgba.len() / 2);
    for row in rgba.chunks_exact(width * 4) {
        for px in row.chunks_exact(8) {
            let (r0, g0, b0) = (px[0] as i32, px[1] as i32, px[2] as i32);
            let (r1, g1, b1) = (px[4] as i32, px[5] as i32, px[6] as i32);
            let y = |r: i32, g: i32, b: i32| (((66 * r + 129 * g + 25 * b + 128) >> 8) + 16) as u8;
            let (r, g, b) = ((r0 + r1) / 2, (g0 + g1) / 2, (b0 + b1) / 2);
            out.push(y(r0, g0, b0));
            out.push((((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128) as u8);
            out.push(y(r1, g1, b1));
            out.push((((112 * r - 94 * g - 18 * b + 128) >> 8) + 128) as u8);
        }
    }
    out
}

#[derive(GodotClass)]
#[class(init, base=Node)]
pub struct VirtualCamera {
    base: Base<Node>,
	#[export]
	pub loopback_device: GString,
    is_valid_device: bool,
    /// stays open while the camera is on: on v4l2loopback 0.15.3 readers get EIO between a writer's close and open
    output: Option<std::fs::File>,
}

#[godot_api]
impl VirtualCamera {
    fn bind_to_viewport(&mut self, viewport: Gd<Viewport>) -> Result<(), &str> {
        if Engine::singleton().is_editor_hint() {
            return Err("virtual cameras can not be initialized within the editor");
        }

        let rect = viewport.get_visible_rect();

        let dev = Device::with_path(self.loopback_device.to_string()).expect("unable to open device path");
        let caps = dev.query_caps().expect("unable to query device capabilities");

        if !caps.capabilities.contains(Flags::VIDEO_OUTPUT) {
            return Err("device is not capable of video output (not a loopback device)");
        }

        // built in set_format on Devices is strictly set to be for type VideoCapture
        // so we have to manually replicate functionality and target VideoOutput instead
        let result = unsafe {
            let mut fmt = v4l::Format::new(
                rect.size.x as u32,
                rect.size.y as u32,
                v4l::FourCC::new(b"YUYV"),
            );
            fmt.field_order = v4l::format::FieldOrder::Progressive;
            fmt.stride = 2 * (rect.size.x as u32);
            fmt.size = 2 * (rect.size.x as u32) * (rect.size.y as u32);
            let mut v4l2_fmt = v4l2_format {
                type_: v4l::buffer::Type::VideoOutput as u32,
                fmt: v4l2_format__bindgen_ty_1 { 
                    pix: fmt.into() 
                },
            };
            v4l2::ioctl(
                dev.handle().fd(),
                v4l2::vidioc::VIDIOC_S_FMT,
                &mut v4l2_fmt as *mut _ as *mut std::os::raw::c_void,
            )
        };

        if let Err(_) = result {
            return Err("unable to set video format");
        }

        Ok(())
    }

    fn update_camera(&mut self) {
        if !self.is_valid_device {
            return;
        }

        let data = self.base().get_viewport()
            .and_then(|vp| vp.get_texture())
            .and_then(|tex| tex.get_image())
            .map(|mut img| {
                img.convert(godot::classes::image::Format::RGBA8);
                rgba_to_yuyv(img.get_data().as_slice(), img.get_width() as usize)
            });

        if let Some(data) = data {
            if self.output.is_none() {
                match OpenOptions::new().write(true).open(self.loopback_device.to_string()) {
                    Ok(f) => self.output = Some(f),
                    Err(e) => {
                        self.is_valid_device = false;
                        godot_error!("{}", e);
                        return;
                    }
                }
            }
            if let Err(e) = self.output.as_mut().unwrap().write(data.as_slice()) {
                self.is_valid_device = false;
                self.output = None;
                godot_error!("{}", e);
            }
        }        
    }

    #[func]
    fn get_devices(&self) -> Array<VarDictionary> {
        Array::from_iter(
            std::fs::read_dir("/dev").expect("unable to enumerate /dev directory")
                .into_iter()
                .filter_map(|entry| {
                    let path_buf = entry.ok()?.path();
                    let path = path_buf.to_str()?;
                    if path.starts_with("/dev/video") {
                        let dev = Device::with_path(path).ok()?;
                        let cap = dev.query_caps().ok()?;
                        if cap.capabilities.contains(Flags::VIDEO_OUTPUT) {
                            return Some(dict!{
                                "name" => &cap.card.to_gstring(),
                                "id" => &path.to_gstring()
                            });
                        }
                    }
                    return None;
                }
            )
        )
    }
}

#[godot_api]
impl INode for VirtualCamera {
    fn ready(&mut self) {
        if !self.loopback_device.is_empty() {
            let vp = self.base().get_viewport().expect("node is not within viewport");
            match self.bind_to_viewport(vp) {
                Ok(_) => { self.is_valid_device = true; },
                Err(msg) => { godot_error!("{}", msg); },
            }
        }

        if !Engine::singleton().is_editor_hint() {
            RenderingServer::singleton().signals()
                .frame_post_draw()
                .connect_other(self, VirtualCamera::update_camera);
        }
    }

    fn on_set(&mut self, property: StringName, value: Variant) -> bool {
        if property == "loopback_device" {
            let Ok(device) = value.try_to::<GString>() else { return false };
            self.loopback_device = device.clone();
            self.output = None;

            // clear value
            if device.is_empty() {
                self.is_valid_device = false;
                return true;
            }

            let vp = self.base().get_viewport().expect("node is not within viewport");
            match self.bind_to_viewport(vp) {
                Ok(_) => {
                    self.is_valid_device = true;
                    return true;
                }
                Err(msg) => { godot_error!("{}", msg); }
            }
        }

        return false;
    }
}
