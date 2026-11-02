use std::fs::OpenOptions;
use std::io::Write;
use std::sync::mpsc::{sync_channel, SyncSender, TrySendError};

use godot::prelude::*;
use godot::classes::RenderingServer;
use godot::classes::Viewport;
use godot::classes::Engine;

use v4l::prelude::*;
use v4l::v4l_sys::v4l2_format;
use v4l::v4l_sys::v4l2_format__bindgen_ty_1;
use v4l::v4l2;

use crate::yuyv::Yuyv;
use v4l::capability::Flags;

/// Frames waiting in the GPU readback. More would only add delay: a frame over this is dropped.
const MAX_PENDING: u32 = 2;

#[derive(GodotClass)]
#[class(init, base=Node)]
pub struct VirtualCamera {
    base: Base<Node>,
	#[export]
	pub loopback_device: GString,
    is_valid_device: bool,
    /// the thread that writes frames to the device, which keeps it open while the camera is on: on v4l2loopback
    /// 0.15.3 readers get EIO between a writer's close and open
    writer: Option<SyncSender<Vec<u8>>>,
    yuyv: Option<Yuyv>,
    size: (u32, u32),
    pending: u32,
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

        // YUYV holds pixels in pairs
        let (width, height) = (rect.size.x as u32 & !1, rect.size.y as u32);
        self.size = (width, height);

        // built in set_format on Devices is strictly set to be for type VideoCapture
        // so we have to manually replicate functionality and target VideoOutput instead
        let result = unsafe {
            let mut fmt = v4l::Format::new(
                width,
                height,
                v4l::FourCC::new(b"YUYV"),
            );
            fmt.field_order = v4l::format::FieldOrder::Progressive;
            fmt.stride = 2 * width;
            fmt.size = 2 * width * height;
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

    fn start_writer(&mut self) -> Result<(), String> {
        let mut file = OpenOptions::new().write(true).open(self.loopback_device.to_string()).map_err(|e| e.to_string())?;
        let (send, receive) = sync_channel::<Vec<u8>>(1);
        std::thread::Builder::new().name("virtual camera".into()).spawn(move || {
            while let Ok(frame) = receive.recv() {
                if let Err(e) = file.write(&frame) {
                    godot_print!("virtual camera: {e}");
                    break;
                }
            }
        }).map_err(|e| e.to_string())?;
        self.writer = Some(send);
        Ok(())
    }

    fn update_camera(&mut self) {
        if !self.is_valid_device || self.pending >= MAX_PENDING {
            return;
        }
        let Some(viewport) = self.base().get_viewport() else { return };
        let Some(texture) = viewport.get_texture() else { return };
        let mut server = RenderingServer::singleton();
        let Some(mut rd) = server.get_rendering_device() else {
            godot_error!("the virtual camera needs the Vulkan renderer");
            self.is_valid_device = false;
            return;
        };
        if self.writer.is_none() {
            if let Err(e) = self.start_writer() {
                godot_error!("{}", e);
                self.is_valid_device = false;
                return;
            }
        }
        if self.yuyv.is_none() {
            match Yuyv::new(rd.clone(), self.size.0, self.size.1) {
                Ok(y) => self.yuyv = Some(y),
                Err(e) => {
                    godot_error!("{}", e);
                    self.is_valid_device = false;
                    return;
                }
            }
        }
        let source = server.texture_get_rd_texture(texture.get_rid());
        let size = viewport.get_visible_rect().size;
        let yuyv = self.yuyv.as_mut().unwrap();
        yuyv.convert(source, size);
        let out = yuyv.out;
        let done = self.to_gd().callable("frame_read");
        if rd.texture_get_data_async(out, 0, &done) == godot::global::Error::OK {
            self.pending += 1;
        }
    }

    #[func]
    fn frame_read(&mut self, data: PackedByteArray) {
        self.pending = self.pending.saturating_sub(1);
        let Some(writer) = &self.writer else { return };
        // a device that is slow only loses this frame
        if let Err(TrySendError::Disconnected(_)) = writer.try_send(data.to_vec()) {
            self.writer = None;
            self.is_valid_device = false;
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
    /// while the render device is still there: dropped with the node at exit, these would free into a device that is gone
    fn exit_tree(&mut self) {
        self.is_valid_device = false;
        self.yuyv = None;
        self.writer = None;
    }

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
            self.writer = None;
            self.yuyv = None;

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
