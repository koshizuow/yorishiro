//! PipeWireStageOut: sends a Godot texture (the stage) to PipeWire as a video stream with alpha, for OBS's
//! PipeWire video source (D34, the Linux counterpart of Spout2). The pixels stay on the graphics card:
//!
//! 1. Godot copies the texture into a shared image each frame (RenderingDevice.texture_copy). The shared
//!    image's memory belongs to a second Vulkan device of ours on the same graphics card and is imported into
//!    Godot's device as an opaque fd (Godot enables VK_KHR_external_memory_fd).
//! 2. Once Godot's frame has finished on the GPU (get_frame_delay() frames later, when Godot has waited for its
//!    fence), our device copies the shared image into a DMA-BUF from libfunnel (MIT) and libfunnel hands it to
//!    PipeWire with explicit sync.
//!
//! Our own device is needed because libfunnel's buffers need DMA-BUF extensions Godot does not enable.
//! Needs the Vulkan renderer (Forward+ or Mobile), PipeWire 1.2 or newer and, on NVIDIA, OBS 31 or newer.

mod funnel;

use ash::vk::{self, Handle};
use godot::classes::rendering_device::{DataFormat, DriverResource, TextureSamples, TextureType, TextureUsageBits};
use godot::classes::{RenderingDevice, RenderingServer};
use godot::prelude::*;
use std::ffi::CString;

struct PipeWireExtension;

#[gdextension]
unsafe impl ExtensionLibrary for PipeWireExtension {}

/// The shared image: Godot's 2D viewports are RGBA8 with sRGB values stored as UNORM. The image is created as
/// SRGB (the format of libfunnel's buffers, so the copy into them changes nothing) and Godot sees it as UNORM.
const SHARED_FORMAT: vk::Format = vk::Format::R8G8B8A8_SRGB;
const SHARED_FORMATS: [vk::Format; 2] = [vk::Format::R8G8B8A8_UNORM, vk::Format::R8G8B8A8_SRGB];
const SHARED_USAGE: vk::ImageUsageFlags = vk::ImageUsageFlags::from_raw(
    vk::ImageUsageFlags::TRANSFER_SRC.as_raw() | vk::ImageUsageFlags::TRANSFER_DST.as_raw() | vk::ImageUsageFlags::SAMPLED.as_raw(),
);
const OPAQUE_FD: vk::ExternalMemoryHandleTypeFlags = vk::ExternalMemoryHandleTypeFlags::OPAQUE_FD;
const COLOR: vk::ImageSubresourceRange = vk::ImageSubresourceRange {
    aspect_mask: vk::ImageAspectFlags::COLOR,
    base_mip_level: 0,
    level_count: 1,
    base_array_layer: 0,
    layer_count: 1,
};
const COLOR_LAYER: vk::ImageSubresourceLayers =
    vk::ImageSubresourceLayers { aspect_mask: vk::ImageAspectFlags::COLOR, mip_level: 0, base_array_layer: 0, layer_count: 1 };

/// Godot's Vulkan objects (not ours to destroy)
struct GodotVk {
    _entry: ash::Entry,
    instance: ash::Instance,
    physical: vk::PhysicalDevice,
    device: ash::Device,
}

/// Godot's half of a shared image, freed once Godot's frames no longer use it
struct GodotImage {
    rid: Rid,
    image: vk::Image,
    memory: vk::DeviceMemory,
}

struct Slot {
    godot: GodotImage,
    image: vk::Image,
    memory: vk::DeviceMemory,
    cmd: vk::CommandBuffer,
    /// signaled when our copy out of this slot has finished
    done: vk::Fence,
    /// the send() call that had Godot copy into this slot, until it is handed to PipeWire
    written: Option<u64>,
}

/// Our device, the libfunnel stream and the shared images
struct Output {
    device: ash::Device,
    memory_fd: ash::khr::external_memory_fd::Device,
    queue: vk::Queue,
    pool: vk::CommandPool,
    tiling: vk::ImageTiling,
    ctx: *mut funnel::funnel_ctx,
    stream: *mut funnel::funnel_stream,
    started: bool,
    size: (u32, u32),
    slots: Vec<Slot>,
}

#[derive(GodotClass)]
#[class(base=RefCounted, init)]
pub struct PipeWireStageOut {
    godot: Option<GodotVk>,
    out: Option<Output>,
    /// shared images Godot may still be using: (Engine frames drawn when retired, image)
    retired: Vec<(u64, GodotImage)>,
}

#[godot_api]
impl PipeWireStageOut {
    /// Starts the stream under that name. Returns "" or what failed.
    #[func]
    fn start(&mut self, name: GString) -> GString {
        self.stop();
        match self.open(&name.to_string()) {
            Ok(out) => {
                self.out = Some(out);
                GString::new()
            }
            Err(e) => GString::from(&e),
        }
    }

    /// Sends the texture (a RenderingServer texture RID, e.g. Viewport.get_texture().get_rid()). Call once
    /// per frame from RenderingServer.frame_post_draw. Returns "" or what failed (the stream is then stopped).
    #[func]
    fn send(&mut self, texture: Rid) -> GString {
        if self.out.is_none() {
            return GString::from("not started");
        }
        match self.send_frame(texture) {
            Ok(()) => GString::new(),
            Err(e) => {
                self.stop();
                GString::from(&e)
            }
        }
    }

    /// "streaming" while a consumer (OBS) receives the stream, "waiting" before, "" when stopped
    #[func]
    fn state(&self) -> GString {
        let Some(out) = &self.out else { return GString::new() };
        if !out.started {
            return GString::from("waiting"); // libfunnel has no PipeWire stream before the first frame
        }
        let mut state = 0;
        let ret = unsafe { funnel::funnel_stream_get_state(out.stream, &mut state) };
        GString::from(if ret == 0 && state == funnel::STATE_STREAMING { "streaming" } else { "waiting" })
    }

    #[func]
    fn stop(&mut self) {
        if let Some(mut out) = self.out.take() {
            let now = frames_drawn();
            for slot in std::mem::take(&mut out.slots) {
                unsafe { out.free_slot_parts(&slot) };
                self.retire(now, slot.godot);
            }
            unsafe { out.close() };
        }
    }

    /// Frees the shared images of a stopped stream once Godot no longer uses them. Call every frame while
    /// stopped (send() does it while running).
    #[func]
    fn collect(&mut self) {
        let Some(g) = &self.godot else { return };
        let Ok(rd) = rendering_device() else { return };
        let (now, delay) = (frames_drawn(), rd.get_frame_delay() as u64);
        // Godot frees its view of a texture when the frame that freed it comes round again
        let (old, keep): (Vec<_>, Vec<_>) = self.retired.drain(..).partition(|(at, _)| now > at + delay + 1);
        self.retired = keep;
        for (_, img) in old {
            unsafe {
                g.device.destroy_image(img.image, None);
                g.device.free_memory(img.memory, None);
            }
        }
    }
}

impl Drop for PipeWireStageOut {
    fn drop(&mut self) {
        // Godot may still hold views of retired images (at exit it frees them after us): those stay allocated
        // until the process ends rather than being destroyed under it
        self.stop();
    }
}

fn rendering_device() -> Result<Gd<RenderingDevice>, String> {
    RenderingServer::singleton()
        .get_rendering_device()
        .ok_or_else(|| "needs the Vulkan renderer (Forward+ or Mobile), not Compatibility".to_string())
}

fn frames_drawn() -> u64 {
    godot::classes::Engine::singleton().get_frames_drawn() as u64
}

impl PipeWireStageOut {
    /// Godot frees its texture now (its view of the image a few frames later), the image waits in `retired`
    fn retire(&mut self, now: u64, img: GodotImage) {
        if let Ok(mut rd) = rendering_device() {
            rd.free_rid(img.rid);
        }
        self.retired.push((now, img));
    }

    fn godot_vk(&mut self) -> Result<&GodotVk, String> {
        if self.godot.is_none() {
            let rd = rendering_device()?;
            let handle = |r| rd.get_driver_resource(r, Rid::Invalid, 0);
            let (instance, physical, device) = (
                vk::Instance::from_raw(handle(DriverResource::TOPMOST_OBJECT)),
                vk::PhysicalDevice::from_raw(handle(DriverResource::PHYSICAL_DEVICE)),
                vk::Device::from_raw(handle(DriverResource::LOGICAL_DEVICE)),
            );
            if instance.is_null() || device.is_null() {
                return Err("Godot's renderer is not Vulkan".into());
            }
            let entry = unsafe { ash::Entry::load() }.map_err(|e| format!("loading Vulkan failed ({e})"))?;
            let instance = unsafe { ash::Instance::load(entry.static_fn(), instance) };
            let have_fd = unsafe { (instance.fp_v1_0().get_device_proc_addr)(device, c"vkGetMemoryFdKHR".as_ptr()) };
            if have_fd.is_none() {
                return Err("Godot's Vulkan device cannot share memory (VK_KHR_external_memory_fd)".into());
            }
            let device = unsafe { ash::Device::load(instance.fp_v1_0(), device) };
            self.godot = Some(GodotVk { _entry: entry, instance, physical, device });
        }
        Ok(self.godot.as_ref().unwrap())
    }

    fn open(&mut self, name: &str) -> Result<Output, String> {
        let g = self.godot_vk()?;
        let (instance, physical) = (&g.instance, g.physical);
        unsafe {
            let available = instance.enumerate_device_extension_properties(physical).map_err(|e| e.to_string())?;
            let needed = [
                ash::khr::external_memory_fd::NAME,
                ash::khr::external_semaphore_fd::NAME,
                ash::ext::external_memory_dma_buf::NAME,
                ash::ext::image_drm_format_modifier::NAME,
            ];
            for ext in needed {
                if !available.iter().any(|p| p.extension_name_as_c_str() == Ok(ext)) {
                    return Err(format!("the graphics driver lacks {}", ext.to_string_lossy()));
                }
            }
            let family = instance
                .get_physical_device_queue_family_properties(physical)
                .iter()
                .position(|f| f.queue_flags.contains(vk::QueueFlags::GRAPHICS))
                .ok_or("no graphics queue")? as u32;
            let queue_info = [vk::DeviceQueueCreateInfo::default().queue_family_index(family).queue_priorities(&[1.0])];
            let names: Vec<_> = needed.iter().map(|n| n.as_ptr()).collect();
            let device = instance
                .create_device(physical, &vk::DeviceCreateInfo::default().queue_create_infos(&queue_info).enabled_extension_names(&names), None)
                .map_err(|e| format!("creating a Vulkan device failed ({e})"))?;
            let queue = device.get_device_queue(family, 0);
            let pool = device
                .create_command_pool(
                    &vk::CommandPoolCreateInfo::default().queue_family_index(family).flags(vk::CommandPoolCreateFlags::RESET_COMMAND_BUFFER),
                    None,
                )
                .map_err(|e| e.to_string())?;
            let mut out = Output {
                memory_fd: ash::khr::external_memory_fd::Device::new(instance, &device),
                device,
                queue,
                pool,
                tiling: shared_tiling(instance, physical),
                ctx: std::ptr::null_mut(),
                stream: std::ptr::null_mut(),
                started: false,
                size: (0, 0),
                slots: vec![],
            };
            if let Err(e) = out.open_stream(instance.handle(), physical, name) {
                out.close();
                return Err(e);
            }
            Ok(out)
        }
    }

    fn send_frame(&mut self, texture: Rid) -> Result<(), String> {
        let mut rd = rendering_device()?;
        let tex = RenderingServer::singleton().texture_get_rd_texture(texture);
        let format = rd.texture_get_format(tex).ok_or("the texture is not on the GPU")?;
        let format_vk = vk::Format::from_raw(rd.get_driver_resource(DriverResource::TEXTURE_DATA_FORMAT, tex, 0) as i32);
        if !SHARED_FORMATS.contains(&format_vk) {
            return Err(format!("the texture's format {format_vk:?} is not RGBA8"));
        }
        let size = (format.get_width(), format.get_height());
        let delay = rd.get_frame_delay() as u64;
        let now = frames_drawn();
        self.collect();

        if size != self.out.as_ref().unwrap().size {
            let slots = std::mem::take(&mut self.out.as_mut().unwrap().slots);
            for slot in slots {
                unsafe { self.out.as_ref().unwrap().free_slot_parts(&slot) };
                self.retire(now, slot.godot);
            }
            let g = self.godot.as_ref().unwrap();
            unsafe {
                self.out.as_mut().unwrap().resize(g, &mut rd, size, delay as usize + 2)?;
            }
        }
        let out = self.out.as_mut().unwrap();

        // Godot has finished the frame that copied into a slot `delay` send() calls ago: send that one
        let ready = out.slots.iter().enumerate().filter(|(_, s)| s.written.is_some_and(|w| now >= w + delay)).max_by_key(|(_, s)| s.written);
        if let Some((i, _)) = ready {
            for s in out.slots.iter_mut() {
                if s.written.is_some_and(|w| now >= w + delay) {
                    s.written = None; // older ones are skipped
                }
            }
            unsafe { out.copy_out(i)? };
        }

        // this frame goes into the next slot once our copy out of it has finished
        let i = (now % out.slots.len() as u64) as usize;
        let slot = &mut out.slots[i];
        let free = slot.written.is_none() && unsafe { out.device.get_fence_status(slot.done) } == Ok(true);
        if free {
            let whole = Vector3::new(size.0 as f32, size.1 as f32, 1.0);
            let err = rd.texture_copy(tex, slot.godot.rid, Vector3::ZERO, Vector3::ZERO, whole, 0, 0, 0, 0);
            if err != godot::global::Error::OK {
                return Err(format!("copying the texture failed ({err:?})"));
            }
            slot.written = Some(now);
        }
        Ok(())
    }
}

/// Linear images need no layout agreement between the two devices; optimal tiling if the driver cannot share
/// a linear one.
fn shared_tiling(instance: &ash::Instance, physical: vk::PhysicalDevice) -> vk::ImageTiling {
    let mut list = vk::ImageFormatListCreateInfo::default().view_formats(&SHARED_FORMATS);
    let mut external = vk::PhysicalDeviceExternalImageFormatInfo::default().handle_type(OPAQUE_FD);
    let info = vk::PhysicalDeviceImageFormatInfo2::default()
        .format(SHARED_FORMAT)
        .ty(vk::ImageType::TYPE_2D)
        .tiling(vk::ImageTiling::LINEAR)
        .usage(SHARED_USAGE)
        .flags(vk::ImageCreateFlags::MUTABLE_FORMAT)
        .push_next(&mut external)
        .push_next(&mut list);
    let mut external_props = vk::ExternalImageFormatProperties::default();
    let mut props = vk::ImageFormatProperties2::default().push_next(&mut external_props);
    let ok = unsafe { instance.get_physical_device_image_format_properties2(physical, &info, &mut props) }.is_ok();
    let features = external_props.external_memory_properties.external_memory_features;
    if ok && features.contains(vk::ExternalMemoryFeatureFlags::EXPORTABLE | vk::ExternalMemoryFeatureFlags::IMPORTABLE) {
        vk::ImageTiling::LINEAR
    } else {
        vk::ImageTiling::OPTIMAL
    }
}

/// The shared image as both devices create it (the same parameters on each side)
fn shared_image_info<'a>(
    w: u32,
    h: u32,
    tiling: vk::ImageTiling,
    external: &'a mut vk::ExternalMemoryImageCreateInfo<'a>,
    list: &'a mut vk::ImageFormatListCreateInfo<'a>,
) -> vk::ImageCreateInfo<'a> {
    vk::ImageCreateInfo::default()
        .flags(vk::ImageCreateFlags::MUTABLE_FORMAT)
        .image_type(vk::ImageType::TYPE_2D)
        .format(SHARED_FORMAT)
        .extent(vk::Extent3D { width: w, height: h, depth: 1 })
        .mip_levels(1)
        .array_layers(1)
        .samples(vk::SampleCountFlags::TYPE_1)
        .tiling(tiling)
        .usage(SHARED_USAGE)
        .initial_layout(vk::ImageLayout::UNDEFINED)
        .push_next(external)
        .push_next(list)
}

fn check(what: &str, ret: i32) -> Result<i32, String> {
    if ret < 0 {
        Err(funnel::describe(what, ret))
    } else {
        Ok(ret)
    }
}

impl Output {
    unsafe fn open_stream(&mut self, instance: vk::Instance, physical: vk::PhysicalDevice, name: &str) -> Result<(), String> {
        use funnel::*;
        check("starting libfunnel", funnel_new(&mut self.ctx))?;
        funnel_set_app_name(self.ctx, c"Yorishiro".as_ptr());
        funnel_set_app_id(self.ctx, c"yorishiro".as_ptr());
        check("connecting to PipeWire", funnel_connect(self.ctx))?;
        let name = CString::new(name).map_err(|e| e.to_string())?;
        check("creating the PipeWire stream", funnel_stream_create(self.ctx, name.as_ptr(), &mut self.stream))?;
        let s = self.stream;
        check("setting up the PipeWire stream", funnel_stream_init_vulkan(s, instance, physical, self.device.handle()))?;
        check("setting up the PipeWire stream", funnel_stream_set_mode(s, FUNNEL_ASYNC))?;
        let fps = |n| funnel_fraction { num: n, den: 1 };
        check("setting up the PipeWire stream", funnel_stream_set_rate(s, fps(60), RATE_VARIABLE, fps(1000)))?;
        check("setting up the PipeWire stream", funnel_stream_vk_set_usage(s, vk::ImageUsageFlags::TRANSFER_DST))?;
        // RGBA takes a plain copy, BGRA a blit that swaps the channels
        let rgba = funnel_stream_vk_add_format(s, vk::Format::R8G8B8A8_SRGB, true, vk::FormatFeatureFlags::TRANSFER_DST);
        let bgra = funnel_stream_vk_add_format(s, vk::Format::B8G8R8A8_SRGB, true, vk::FormatFeatureFlags::BLIT_DST);
        if rgba < 0 && bgra < 0 {
            return Err(funnel::describe("finding a format the driver can share", rgba));
        }
        Ok(())
    }

    /// New shared images for that size, and the stream set to it
    unsafe fn resize(&mut self, g: &GodotVk, rd: &mut Gd<RenderingDevice>, size: (u32, u32), count: usize) -> Result<(), String> {
        self.size = size;
        for _ in 0..count {
            let slot = self.new_slot(g, rd)?;
            self.slots.push(slot);
        }
        check("setting the stream size", funnel::funnel_stream_set_size(self.stream, size.0, size.1))?;
        check("setting up the PipeWire stream", funnel::funnel_stream_configure(self.stream))?;
        if !self.started {
            check("starting the PipeWire stream", funnel::funnel_stream_start(self.stream))?;
            self.started = true;
        }
        Ok(())
    }

    unsafe fn new_slot(&self, g: &GodotVk, rd: &mut Gd<RenderingDevice>) -> Result<Slot, String> {
        let (w, h) = self.size;
        let err = |what: &str, e: vk::Result| format!("{what} failed ({e})");

        // our side: allocated here, exported as an fd
        let (mut ext, mut list) = (vk::ExternalMemoryImageCreateInfo::default().handle_types(OPAQUE_FD), vk::ImageFormatListCreateInfo::default().view_formats(&SHARED_FORMATS));
        let image = self.device.create_image(&shared_image_info(w, h, self.tiling, &mut ext, &mut list), None).map_err(|e| err("creating the shared image", e))?;
        let req = self.device.get_image_memory_requirements(image);
        let props = g.instance.get_physical_device_memory_properties(g.physical);
        let type_index = (0..props.memory_type_count)
            .find(|&i| req.memory_type_bits & (1 << i) != 0 && props.memory_types[i as usize].property_flags.contains(vk::MemoryPropertyFlags::DEVICE_LOCAL))
            .ok_or("no graphics memory for the shared image")?;
        let mut export = vk::ExportMemoryAllocateInfo::default().handle_types(OPAQUE_FD);
        let mut dedicated = vk::MemoryDedicatedAllocateInfo::default().image(image);
        let alloc = vk::MemoryAllocateInfo::default().allocation_size(req.size).memory_type_index(type_index).push_next(&mut export).push_next(&mut dedicated);
        let memory = self.device.allocate_memory(&alloc, None).map_err(|e| err("allocating the shared image", e))?;
        self.device.bind_image_memory(image, memory, 0).map_err(|e| err("binding the shared image", e))?;
        let fd = self
            .memory_fd
            .get_memory_fd(&vk::MemoryGetFdInfoKHR::default().memory(memory).handle_type(OPAQUE_FD))
            .map_err(|e| err("sharing the image", e))?;

        // Godot's side: the same memory, imported (the fd belongs to the driver once that succeeds)
        let (mut ext, mut list) = (vk::ExternalMemoryImageCreateInfo::default().handle_types(OPAQUE_FD), vk::ImageFormatListCreateInfo::default().view_formats(&SHARED_FORMATS));
        let g_image = g.device.create_image(&shared_image_info(w, h, self.tiling, &mut ext, &mut list), None).map_err(|e| err("creating Godot's shared image", e))?;
        let g_req = g.device.get_image_memory_requirements(g_image);
        if g_req.memory_type_bits & (1 << type_index) == 0 || g_req.size > req.size {
            libc_close(fd);
            g.device.destroy_image(g_image, None);
            return Err("Godot's device cannot use the shared memory".into());
        }
        let mut import = vk::ImportMemoryFdInfoKHR::default().handle_type(OPAQUE_FD).fd(fd);
        let mut dedicated = vk::MemoryDedicatedAllocateInfo::default().image(g_image);
        let alloc = vk::MemoryAllocateInfo::default().allocation_size(req.size).memory_type_index(type_index).push_next(&mut import).push_next(&mut dedicated);
        let g_memory = match g.device.allocate_memory(&alloc, None) {
            Ok(m) => m,
            Err(e) => {
                libc_close(fd);
                g.device.destroy_image(g_image, None);
                return Err(err("importing the shared image into Godot", e));
            }
        };
        g.device.bind_image_memory(g_image, g_memory, 0).map_err(|e| err("binding Godot's shared image", e))?;
        let usage = TextureUsageBits::SAMPLING_BIT | TextureUsageBits::CAN_COPY_TO_BIT;
        let rid = rd.texture_create_from_extension(
            TextureType::TYPE_2D,
            DataFormat::R8G8B8A8_UNORM,
            TextureSamples::SAMPLES_1,
            usage,
            g_image.as_raw(),
            w as u64,
            h as u64,
            1,
            1,
        );
        if !rid.is_valid() {
            return Err("Godot did not accept the shared image".into());
        }

        let cmd = self
            .device
            .allocate_command_buffers(&vk::CommandBufferAllocateInfo::default().command_pool(self.pool).command_buffer_count(1))
            .map_err(|e| e.to_string())?[0];
        let done = self.device.create_fence(&vk::FenceCreateInfo::default().flags(vk::FenceCreateFlags::SIGNALED), None).map_err(|e| e.to_string())?;
        Ok(Slot { godot: GodotImage { rid, image: g_image, memory: g_memory }, image, memory, cmd, done, written: None })
    }

    /// Copies slot i into a PipeWire buffer and sends it. Without a consumer there is no buffer: nothing to do.
    unsafe fn copy_out(&mut self, i: usize) -> Result<(), String> {
        use funnel::*;
        let mut buf = std::ptr::null_mut();
        if check("getting a PipeWire buffer", funnel_stream_dequeue(self.stream, &mut buf))? == 0 || buf.is_null() {
            return Ok(());
        }
        let (mut image, mut format) = (vk::Image::null(), vk::Format::UNDEFINED);
        let (mut bw, mut bh) = (0, 0);
        let (mut acquire, mut release, mut fence) = (vk::Semaphore::null(), vk::Semaphore::null(), vk::Fence::null());
        funnel_buffer_get_size(buf, &mut bw, &mut bh);
        let got = check("mapping the PipeWire buffer", funnel_buffer_get_vk_image(buf, &mut image))
            .and_then(|_| check("mapping the PipeWire buffer", funnel_buffer_get_vk_format(buf, &mut format, std::ptr::null_mut())))
            .and_then(|_| check("buffer sync", funnel_buffer_get_vk_semaphores(buf, &mut acquire, &mut release)))
            .and_then(|_| check("buffer sync", funnel_buffer_get_vk_fence(buf, &mut fence)));
        if let Err(e) = got {
            funnel_stream_return(self.stream, buf);
            return Err(e);
        }

        let d = &self.device;
        let slot = &self.slots[i];
        let vkerr = |e: vk::Result| e.to_string();
        d.wait_for_fences(&[slot.done], true, u64::MAX).map_err(vkerr)?;
        d.reset_fences(&[slot.done]).map_err(vkerr)?;
        d.begin_command_buffer(slot.cmd, &vk::CommandBufferBeginInfo::default().flags(vk::CommandBufferUsageFlags::ONE_TIME_SUBMIT))
            .map_err(vkerr)?;
        let barrier = |img, old, new, src: vk::AccessFlags, dst: vk::AccessFlags| {
            vk::ImageMemoryBarrier::default()
                .image(img)
                .old_layout(old)
                .new_layout(new)
                .src_access_mask(src)
                .dst_access_mask(dst)
                .src_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                .dst_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                .subresource_range(COLOR)
        };
        use vk::{AccessFlags as A, ImageLayout as L};
        // Godot leaves the shared image as a copy destination and expects it back that way
        let before = [
            barrier(slot.image, L::TRANSFER_DST_OPTIMAL, L::TRANSFER_SRC_OPTIMAL, A::MEMORY_WRITE, A::TRANSFER_READ),
            barrier(image, L::UNDEFINED, L::TRANSFER_DST_OPTIMAL, A::empty(), A::TRANSFER_WRITE),
        ];
        let stages = (vk::PipelineStageFlags::ALL_COMMANDS, vk::PipelineStageFlags::TRANSFER);
        d.cmd_pipeline_barrier(slot.cmd, stages.0, stages.1, vk::DependencyFlags::empty(), &[], &[], &before);
        let (w, h) = (self.size.0.min(bw), self.size.1.min(bh));
        if format == SHARED_FORMAT {
            let region = vk::ImageCopy::default()
                .src_subresource(COLOR_LAYER)
                .dst_subresource(COLOR_LAYER)
                .extent(vk::Extent3D { width: w, height: h, depth: 1 });
            d.cmd_copy_image(slot.cmd, slot.image, L::TRANSFER_SRC_OPTIMAL, image, L::TRANSFER_DST_OPTIMAL, &[region]);
        } else {
            let corner = vk::Offset3D { x: w as i32, y: h as i32, z: 1 };
            let region = vk::ImageBlit::default()
                .src_subresource(COLOR_LAYER)
                .dst_subresource(COLOR_LAYER)
                .src_offsets([vk::Offset3D::default(), corner])
                .dst_offsets([vk::Offset3D::default(), corner]);
            d.cmd_blit_image(slot.cmd, slot.image, L::TRANSFER_SRC_OPTIMAL, image, L::TRANSFER_DST_OPTIMAL, &[region], vk::Filter::NEAREST);
        }
        let after = [
            barrier(slot.image, L::TRANSFER_SRC_OPTIMAL, L::TRANSFER_DST_OPTIMAL, A::TRANSFER_READ, A::empty()),
            barrier(image, L::TRANSFER_DST_OPTIMAL, L::GENERAL, A::TRANSFER_WRITE, A::MEMORY_READ),
        ];
        d.cmd_pipeline_barrier(slot.cmd, vk::PipelineStageFlags::TRANSFER, vk::PipelineStageFlags::BOTTOM_OF_PIPE, vk::DependencyFlags::empty(), &[], &[], &after);
        d.end_command_buffer(slot.cmd).map_err(vkerr)?;

        let (wait, signal, cmds, wait_stage) = ([acquire], [release], [slot.cmd], [vk::PipelineStageFlags::TRANSFER]);
        let submit = vk::SubmitInfo::default().wait_semaphores(&wait).wait_dst_stage_mask(&wait_stage).command_buffers(&cmds).signal_semaphores(&signal);
        d.queue_submit(self.queue, &[submit], fence).map_err(|e| format!("sending the copy to the GPU failed ({e})"))?;
        // the slot's own fence, after everything submitted before it
        d.queue_submit(self.queue, &[], slot.done).map_err(vkerr)?;
        check("sending the PipeWire buffer", funnel_stream_enqueue(self.stream, buf))?;
        Ok(())
    }

    unsafe fn free_slot_parts(&self, slot: &Slot) {
        let _ = self.device.wait_for_fences(&[slot.done], true, u64::MAX);
        self.device.destroy_fence(slot.done, None);
        self.device.free_command_buffers(self.pool, &[slot.cmd]);
        self.device.destroy_image(slot.image, None);
        self.device.free_memory(slot.memory, None);
    }

    unsafe fn close(&mut self) {
        let _ = self.device.device_wait_idle();
        if !self.stream.is_null() {
            if self.started {
                funnel::funnel_stream_stop(self.stream);
            }
            funnel::funnel_stream_destroy(self.stream);
        }
        if !self.ctx.is_null() {
            funnel::funnel_shutdown(self.ctx);
        }
        for slot in std::mem::take(&mut self.slots) {
            self.free_slot_parts(&slot);
        }
        self.device.destroy_command_pool(self.pool, None);
        self.device.destroy_device(None);
    }
}

unsafe fn libc_close(fd: i32) {
    extern "C" {
        fn close(fd: i32) -> i32;
    }
    close(fd);
}
