//! PipeWireStageOut: sends a Godot texture (the stage) to PipeWire as a video stream with alpha, for OBS's
//! PipeWire video source (D34, the Linux counterpart of Spout2). The pixels stay on the graphics card:
//!
//! 1. Right after Godot has submitted a frame (RenderingServer.frame_post_draw), send() submits a copy of the
//!    texture into a shared image on Godot's own queue, behind the frame, with a fence of ours. The shared
//!    image's memory belongs to a second Vulkan device of ours on the same graphics card and is imported into
//!    Godot's device as an opaque fd (Godot enables VK_KHR_external_memory_fd).
//! 2. A thread waits for that fence and has our device copy the shared image into a DMA-BUF from libfunnel
//!    (MIT), which hands it to PipeWire with explicit sync. The frame leaves as soon as the GPU has drawn it.
//!
//! Our own device is needed because libfunnel's buffers need DMA-BUF extensions Godot does not enable.
//! Submitting to Godot's queue needs Godot's rendering on the main thread (the default thread model), and the
//! copy needs the layout Godot leaves the texture in at the end of a frame: TEXTURE_LAYOUT (checked with the
//! Vulkan validation layers, Godot's --gpu-validation).
//! Needs the Vulkan renderer (Forward+ or Mobile), PipeWire 1.2 or newer and, on NVIDIA, OBS 31 or newer.

mod funnel;

use ash::vk::{self, Handle};
use godot::classes::rendering_device::DriverResource;
use godot::classes::{ProjectSettings, RenderingDevice, RenderingServer};
use godot::prelude::*;
use std::ffi::CString;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Instant;

struct PipeWireExtension;

#[gdextension]
unsafe impl ExtensionLibrary for PipeWireExtension {}

/// Where Godot leaves a viewport's texture after a frame in which it was drawn on screen (sampled)
const TEXTURE_LAYOUT: vk::ImageLayout = vk::ImageLayout::SHADER_READ_ONLY_OPTIMAL;
/// The shared image: Godot's 2D viewports are RGBA8 with sRGB values stored as UNORM, copied bit for bit into an
/// SRGB image (the format of libfunnel's buffers, so the copy into them changes nothing)
const SHARED_FORMAT: vk::Format = vk::Format::R8G8B8A8_SRGB;
const SOURCE_FORMATS: [vk::Format; 2] = [vk::Format::R8G8B8A8_UNORM, vk::Format::R8G8B8A8_SRGB];
const SHARED_USAGE: vk::ImageUsageFlags =
    vk::ImageUsageFlags::from_raw(vk::ImageUsageFlags::TRANSFER_SRC.as_raw() | vk::ImageUsageFlags::TRANSFER_DST.as_raw());
const OPAQUE_FD: vk::ExternalMemoryHandleTypeFlags = vk::ExternalMemoryHandleTypeFlags::OPAQUE_FD;
/// shared images in flight: one being drawn, one being copied out, one spare
const SLOTS: usize = 3;
const COLOR: vk::ImageSubresourceRange = vk::ImageSubresourceRange {
    aspect_mask: vk::ImageAspectFlags::COLOR,
    base_mip_level: 0,
    level_count: 1,
    base_array_layer: 0,
    layer_count: 1,
};
const COLOR_LAYER: vk::ImageSubresourceLayers =
    vk::ImageSubresourceLayers { aspect_mask: vk::ImageAspectFlags::COLOR, mip_level: 0, base_array_layer: 0, layer_count: 1 };

fn barrier(
    image: vk::Image,
    (old, new): (vk::ImageLayout, vk::ImageLayout),
    (src, dst): (vk::AccessFlags, vk::AccessFlags),
    (src_family, dst_family): (u32, u32),
) -> vk::ImageMemoryBarrier<'static> {
    vk::ImageMemoryBarrier::default()
        .image(image)
        .old_layout(old)
        .new_layout(new)
        .src_access_mask(src)
        .dst_access_mask(dst)
        .src_queue_family_index(src_family)
        .dst_queue_family_index(dst_family)
        .subresource_range(COLOR)
}
const NO_TRANSFER: (u32, u32) = (vk::QUEUE_FAMILY_IGNORED, vk::QUEUE_FAMILY_IGNORED);

/// Godot's Vulkan objects (not ours to destroy)
struct GodotVk {
    _entry: ash::Entry,
    instance: ash::Instance,
    physical: vk::PhysicalDevice,
    device: ash::Device,
    queue: vk::Queue,
    family: u32,
}

/// Godot's half of a shared image and the copy into it
struct GodotSlot {
    image: vk::Image,
    memory: vk::DeviceMemory,
    cmd: vk::CommandBuffer,
    /// signaled when the copy has finished on the GPU
    fence: vk::Fence,
    /// until the thread has sent it to PipeWire
    busy: Arc<AtomicBool>,
}

/// Our half of a shared image and the copy out of it
struct OurSlot {
    image: vk::Image,
    memory: vk::DeviceMemory,
    cmd: vk::CommandBuffer,
    done: vk::Fence,
}

/// Our device and the libfunnel stream, used by the copy thread (and by the main thread to resize)
struct Ours {
    device: ash::Device,
    memory_fd: ash::khr::external_memory_fd::Device,
    queue: vk::Queue,
    family: u32,
    pool: vk::CommandPool,
    tiling: vk::ImageTiling,
    ctx: *mut funnel::funnel_ctx,
    stream: *mut funnel::funnel_stream,
    started: bool,
    size: (u32, u32),
    slots: Vec<OurSlot>,
    /// counts resizes, a job for older slots is dropped
    generation: u64,
    /// time from the copy's submission to the frame handed to PipeWire, since latency() last asked
    latency: (f64, f64, u32),
}

// the raw libfunnel pointers are only used under the Mutex
unsafe impl Send for Ours {}

struct Job {
    slot: usize,
    generation: u64,
    fence: vk::Fence,
    busy: Arc<AtomicBool>,
    submitted: Instant,
}

struct Output {
    ours: Arc<Mutex<Ours>>,
    error: Arc<Mutex<Option<String>>>,
    jobs: Option<mpsc::Sender<Job>>,
    thread: Option<JoinHandle<()>>,
    pool: vk::CommandPool,
    slots: Vec<GodotSlot>,
}

#[derive(GodotClass)]
#[class(base=RefCounted, init)]
pub struct PipeWireStageOut {
    godot: Option<GodotVk>,
    out: Option<Output>,
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
        let ours = out.ours.lock().unwrap();
        if !ours.started {
            return GString::from("waiting"); // libfunnel has no PipeWire stream before the first frame
        }
        let mut state = 0;
        let ret = unsafe { funnel::funnel_stream_get_state(ours.stream, &mut state) };
        GString::from(if ret == 0 && state == funnel::STATE_STREAMING { "streaming" } else { "waiting" })
    }

    /// Milliseconds from a frame's submission to its hand-over to PipeWire since the last call: [mean, max,
    /// frames]. Frames are only handed over while a consumer takes them.
    #[func]
    fn latency(&self) -> PackedFloat64Array {
        let Some(out) = &self.out else { return PackedFloat64Array::new() };
        let mut ours = out.ours.lock().unwrap();
        let (sum, max, n) = std::mem::take(&mut ours.latency);
        PackedFloat64Array::from(&[if n > 0 { sum / n as f64 } else { 0.0 }, max, n as f64][..])
    }

    #[func]
    fn stop(&mut self) {
        let Some(mut out) = self.out.take() else { return };
        let g = self.godot.as_ref().unwrap();
        drop(out.jobs.take());
        if let Some(t) = out.thread.take() {
            let _ = t.join();
        }
        unsafe {
            for slot in std::mem::take(&mut out.slots) {
                free_godot_slot(g, out.pool, slot);
            }
            g.device.destroy_command_pool(out.pool, None);
            out.ours.lock().unwrap().close();
        }
    }
}

impl Drop for PipeWireStageOut {
    fn drop(&mut self) {
        self.stop();
    }
}

fn rendering_device() -> Result<Gd<RenderingDevice>, String> {
    RenderingServer::singleton()
        .get_rendering_device()
        .ok_or_else(|| "needs the Vulkan renderer (Forward+ or Mobile), not Compatibility".to_string())
}

unsafe fn free_godot_slot(g: &GodotVk, pool: vk::CommandPool, slot: GodotSlot) {
    let _ = g.device.wait_for_fences(&[slot.fence], true, u64::MAX);
    g.device.destroy_fence(slot.fence, None);
    g.device.free_command_buffers(pool, &[slot.cmd]);
    g.device.destroy_image(slot.image, None);
    g.device.free_memory(slot.memory, None);
}

impl PipeWireStageOut {
    fn godot_vk(&mut self) -> Result<&GodotVk, String> {
        if self.godot.is_none() {
            let thread_model = ProjectSettings::singleton().get_setting("rendering/driver/threads/thread_model");
            if thread_model.try_to::<i64>().unwrap_or(1) == 2 {
                return Err("needs Godot's rendering on the main thread (thread model Safe)".into());
            }
            let rd = rendering_device()?;
            let handle = |r| rd.get_driver_resource(r, Rid::Invalid, 0);
            let (instance, physical, device) = (
                vk::Instance::from_raw(handle(DriverResource::TOPMOST_OBJECT)),
                vk::PhysicalDevice::from_raw(handle(DriverResource::PHYSICAL_DEVICE)),
                vk::Device::from_raw(handle(DriverResource::LOGICAL_DEVICE)),
            );
            let queue = vk::Queue::from_raw(handle(DriverResource::COMMAND_QUEUE));
            let family = handle(DriverResource::QUEUE_FAMILY) as u32;
            if instance.is_null() || device.is_null() || queue.is_null() {
                return Err("Godot's renderer is not Vulkan".into());
            }
            let entry = unsafe { ash::Entry::load() }.map_err(|e| format!("loading Vulkan failed ({e})"))?;
            let instance = unsafe { ash::Instance::load(entry.static_fn(), instance) };
            let have_fd = unsafe { (instance.fp_v1_0().get_device_proc_addr)(device, c"vkGetMemoryFdKHR".as_ptr()) };
            if have_fd.is_none() {
                return Err("Godot's Vulkan device cannot share memory (VK_KHR_external_memory_fd)".into());
            }
            let device = unsafe { ash::Device::load(instance.fp_v1_0(), device) };
            self.godot = Some(GodotVk { _entry: entry, instance, physical, device, queue, family });
        }
        Ok(self.godot.as_ref().unwrap())
    }

    fn open(&mut self, name: &str) -> Result<Output, String> {
        let g = self.godot_vk()?;
        let ours = unsafe { Ours::open(g, name)? };
        let pool = unsafe {
            g.device.create_command_pool(
                &vk::CommandPoolCreateInfo::default().queue_family_index(g.family).flags(vk::CommandPoolCreateFlags::RESET_COMMAND_BUFFER),
                None,
            )
        };
        let pool = match pool {
            Ok(p) => p,
            Err(e) => {
                let mut ours = ours;
                unsafe { ours.close() };
                return Err(e.to_string());
            }
        };
        let ours = Arc::new(Mutex::new(ours));
        let error = Arc::new(Mutex::new(None));
        let (jobs, rx) = mpsc::channel::<Job>();
        let (o, e, device) = (ours.clone(), error.clone(), g.device.clone());
        let thread = std::thread::Builder::new()
            .name("yorishiro-pipewire".into())
            .spawn(move || {
                for job in rx {
                    // the copy on Godot's queue has finished: the frame is in the shared image
                    let waited = unsafe { device.wait_for_fences(&[job.fence], true, 5_000_000_000) };
                    let result = match waited {
                        Ok(()) => {
                            let mut ours = o.lock().unwrap();
                            if job.generation == ours.generation {
                                unsafe { ours.copy_out(job.slot, job.submitted) }
                            } else {
                                Ok(())
                            }
                        }
                        Err(e) => Err(format!("the GPU did not finish the copy ({e})")),
                    };
                    if let Err(msg) = result {
                        e.lock().unwrap().get_or_insert(msg);
                    }
                    job.busy.store(false, Ordering::Release);
                }
            })
            .map_err(|e| e.to_string())?;
        Ok(Output { ours, error, jobs: Some(jobs), thread: Some(thread), pool, slots: vec![] })
    }

    fn send_frame(&mut self, texture: Rid) -> Result<(), String> {
        let mut rd = rendering_device()?;
        let g = self.godot.as_ref().unwrap();
        let out = self.out.as_mut().unwrap();
        if let Some(e) = out.error.lock().unwrap().take() {
            return Err(e);
        }
        let tex = RenderingServer::singleton().texture_get_rd_texture(texture);
        let format = rd.texture_get_format(tex).ok_or("the texture is not on the GPU")?;
        let format_vk = vk::Format::from_raw(rd.get_driver_resource(DriverResource::TEXTURE_DATA_FORMAT, tex, 0) as i32);
        if !SOURCE_FORMATS.contains(&format_vk) {
            return Err(format!("the texture's format {format_vk:?} is not RGBA8"));
        }
        let source = vk::Image::from_raw(rd.get_driver_resource(DriverResource::TEXTURE, tex, 0));
        let size = (format.get_width(), format.get_height());

        if size != out.ours.lock().unwrap().size {
            unsafe { out.resize(g, size)? };
        }

        // a shared image the copy thread is done with, else this frame is skipped
        let Some(i) = out.slots.iter().position(|s| !s.busy.load(Ordering::Acquire)) else { return Ok(()) };
        let slot = &out.slots[i];
        let d = &g.device;
        let vkerr = |e: vk::Result| e.to_string();
        unsafe {
            d.reset_fences(&[slot.fence]).map_err(vkerr)?;
            d.begin_command_buffer(slot.cmd, &vk::CommandBufferBeginInfo::default().flags(vk::CommandBufferUsageFlags::ONE_TIME_SUBMIT))
                .map_err(vkerr)?;
            use vk::{AccessFlags as A, ImageLayout as L, PipelineStageFlags as S};
            // after everything submitted before on this queue: Godot's frame
            let before = [
                barrier(source, (TEXTURE_LAYOUT, L::TRANSFER_SRC_OPTIMAL), (A::MEMORY_WRITE, A::TRANSFER_READ), NO_TRANSFER),
                barrier(slot.image, (L::UNDEFINED, L::TRANSFER_DST_OPTIMAL), (A::empty(), A::TRANSFER_WRITE), NO_TRANSFER),
            ];
            d.cmd_pipeline_barrier(slot.cmd, S::ALL_COMMANDS, S::TRANSFER, vk::DependencyFlags::empty(), &[], &[], &before);
            let region = vk::ImageCopy::default()
                .src_subresource(COLOR_LAYER)
                .dst_subresource(COLOR_LAYER)
                .extent(vk::Extent3D { width: size.0, height: size.1, depth: 1 });
            d.cmd_copy_image(slot.cmd, source, L::TRANSFER_SRC_OPTIMAL, slot.image, L::TRANSFER_DST_OPTIMAL, &[region]);
            // Godot's texture back the way Godot left it, before anything later on the queue touches it; the shared
            // image released to our device
            let after = [
                barrier(source, (L::TRANSFER_SRC_OPTIMAL, TEXTURE_LAYOUT), (A::empty(), A::MEMORY_READ | A::MEMORY_WRITE), NO_TRANSFER),
                barrier(
                    slot.image,
                    (L::TRANSFER_DST_OPTIMAL, L::TRANSFER_SRC_OPTIMAL),
                    (A::TRANSFER_WRITE, A::empty()),
                    (g.family, vk::QUEUE_FAMILY_EXTERNAL),
                ),
            ];
            d.cmd_pipeline_barrier(slot.cmd, S::TRANSFER, S::ALL_COMMANDS, vk::DependencyFlags::empty(), &[], &[], &after);
            d.end_command_buffer(slot.cmd).map_err(vkerr)?;
            let cmds = [slot.cmd];
            d.queue_submit(g.queue, &[vk::SubmitInfo::default().command_buffers(&cmds)], slot.fence)
                .map_err(|e| format!("sending the copy to the GPU failed ({e})"))?;
        }
        slot.busy.store(true, Ordering::Release);
        let generation = out.ours.lock().unwrap().generation;
        let job = Job { slot: i, generation, fence: slot.fence, busy: slot.busy.clone(), submitted: Instant::now() };
        if out.jobs.as_ref().unwrap().send(job).is_err() {
            return Err("the copy thread stopped".into());
        }
        Ok(())
    }
}

impl Output {
    /// New shared images for that size, after the copies in flight have finished
    unsafe fn resize(&mut self, g: &GodotVk, size: (u32, u32)) -> Result<(), String> {
        let start = Instant::now();
        while self.slots.iter().any(|s| s.busy.load(Ordering::Acquire)) {
            if start.elapsed().as_secs() > 5 {
                return Err("the copy thread is stuck".into());
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        for slot in std::mem::take(&mut self.slots) {
            free_godot_slot(g, self.pool, slot);
        }
        let mut ours = self.ours.lock().unwrap();
        ours.generation += 1;
        ours.free_slots();
        ours.size = size;
        for _ in 0..SLOTS {
            let (slot, fd, type_index, alloc_size) = ours.new_slot(g)?;
            ours.slots.push(slot);
            self.slots.push(new_godot_slot(g, self.pool, &ours, fd, type_index, alloc_size)?);
        }
        ours.configure()
    }
}

/// Godot's side of a shared image: the same memory, imported (the fd belongs to the driver once that succeeds)
unsafe fn new_godot_slot(g: &GodotVk, pool: vk::CommandPool, ours: &Ours, fd: i32, type_index: u32, alloc_size: u64) -> Result<GodotSlot, String> {
    let err = |what: &str, e: vk::Result| format!("{what} failed ({e})");
    let mut ext = vk::ExternalMemoryImageCreateInfo::default().handle_types(OPAQUE_FD);
    let image = g
        .device
        .create_image(&shared_image_info(ours.size, ours.tiling, &mut ext), None)
        .map_err(|e| err("creating Godot's shared image", e))?;
    let req = g.device.get_image_memory_requirements(image);
    if req.memory_type_bits & (1 << type_index) == 0 || req.size > alloc_size {
        libc_close(fd);
        g.device.destroy_image(image, None);
        return Err("Godot's device cannot use the shared memory".into());
    }
    let mut import = vk::ImportMemoryFdInfoKHR::default().handle_type(OPAQUE_FD).fd(fd);
    let mut dedicated = vk::MemoryDedicatedAllocateInfo::default().image(image);
    let alloc = vk::MemoryAllocateInfo::default().allocation_size(alloc_size).memory_type_index(type_index).push_next(&mut import).push_next(&mut dedicated);
    let memory = match g.device.allocate_memory(&alloc, None) {
        Ok(m) => m,
        Err(e) => {
            libc_close(fd);
            g.device.destroy_image(image, None);
            return Err(err("importing the shared image into Godot's device", e));
        }
    };
    g.device.bind_image_memory(image, memory, 0).map_err(|e| err("binding Godot's shared image", e))?;
    let cmd = g
        .device
        .allocate_command_buffers(&vk::CommandBufferAllocateInfo::default().command_pool(pool).command_buffer_count(1))
        .map_err(|e| e.to_string())?[0];
    let fence = g.device.create_fence(&vk::FenceCreateInfo::default().flags(vk::FenceCreateFlags::SIGNALED), None).map_err(|e| e.to_string())?;
    Ok(GodotSlot { image, memory, cmd, fence, busy: Arc::new(AtomicBool::new(false)) })
}

/// The shared image as both devices create it (the same parameters on each side)
fn shared_image_info<'a>(size: (u32, u32), tiling: vk::ImageTiling, external: &'a mut vk::ExternalMemoryImageCreateInfo<'a>) -> vk::ImageCreateInfo<'a> {
    vk::ImageCreateInfo::default()
        .image_type(vk::ImageType::TYPE_2D)
        .format(SHARED_FORMAT)
        .extent(vk::Extent3D { width: size.0, height: size.1, depth: 1 })
        .mip_levels(1)
        .array_layers(1)
        .samples(vk::SampleCountFlags::TYPE_1)
        .tiling(tiling)
        .usage(SHARED_USAGE)
        .initial_layout(vk::ImageLayout::UNDEFINED)
        .push_next(external)
}

/// Linear images need no layout agreement between the two devices; optimal tiling if the driver cannot share
/// a linear one.
fn shared_tiling(instance: &ash::Instance, physical: vk::PhysicalDevice) -> vk::ImageTiling {
    let mut external = vk::PhysicalDeviceExternalImageFormatInfo::default().handle_type(OPAQUE_FD);
    let info = vk::PhysicalDeviceImageFormatInfo2::default()
        .format(SHARED_FORMAT)
        .ty(vk::ImageType::TYPE_2D)
        .tiling(vk::ImageTiling::LINEAR)
        .usage(SHARED_USAGE)
        .push_next(&mut external);
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

fn check(what: &str, ret: i32) -> Result<i32, String> {
    if ret < 0 {
        Err(funnel::describe(what, ret))
    } else {
        Ok(ret)
    }
}

impl Ours {
    unsafe fn open(g: &GodotVk, name: &str) -> Result<Ours, String> {
        let (instance, physical) = (&g.instance, g.physical);
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
        let mut ours = Ours {
            memory_fd: ash::khr::external_memory_fd::Device::new(instance, &device),
            device,
            queue,
            family,
            pool,
            tiling: shared_tiling(instance, physical),
            ctx: std::ptr::null_mut(),
            stream: std::ptr::null_mut(),
            started: false,
            size: (0, 0),
            slots: vec![],
            generation: 0,
            latency: (0.0, 0.0, 0),
        };
        if let Err(e) = ours.open_stream(instance.handle(), physical, name) {
            ours.close();
            return Err(e);
        }
        Ok(ours)
    }

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

    /// The stream set to the current size (started on the first frame)
    unsafe fn configure(&mut self) -> Result<(), String> {
        check("setting the stream size", funnel::funnel_stream_set_size(self.stream, self.size.0, self.size.1))?;
        check("setting up the PipeWire stream", funnel::funnel_stream_configure(self.stream))?;
        if !self.started {
            check("starting the PipeWire stream", funnel::funnel_stream_start(self.stream))?;
            self.started = true;
        }
        Ok(())
    }

    /// Our side of a new shared image, and its memory as an fd for Godot's device (with type and size)
    unsafe fn new_slot(&self, g: &GodotVk) -> Result<(OurSlot, i32, u32, u64), String> {
        let err = |what: &str, e: vk::Result| format!("{what} failed ({e})");
        let mut ext = vk::ExternalMemoryImageCreateInfo::default().handle_types(OPAQUE_FD);
        let image = self.device.create_image(&shared_image_info(self.size, self.tiling, &mut ext), None).map_err(|e| err("creating the shared image", e))?;
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
        let cmd = self
            .device
            .allocate_command_buffers(&vk::CommandBufferAllocateInfo::default().command_pool(self.pool).command_buffer_count(1))
            .map_err(|e| e.to_string())?[0];
        let done = self.device.create_fence(&vk::FenceCreateInfo::default().flags(vk::FenceCreateFlags::SIGNALED), None).map_err(|e| e.to_string())?;
        Ok((OurSlot { image, memory, cmd, done }, fd, type_index, req.size))
    }

    /// Copies slot i into a PipeWire buffer and sends it, waiting until the copy has finished (so Godot may
    /// write the slot again). Without a consumer there is no buffer: nothing to do.
    unsafe fn copy_out(&mut self, i: usize, submitted: Instant) -> Result<(), String> {
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
        d.reset_fences(&[slot.done]).map_err(vkerr)?;
        d.begin_command_buffer(slot.cmd, &vk::CommandBufferBeginInfo::default().flags(vk::CommandBufferUsageFlags::ONE_TIME_SUBMIT))
            .map_err(vkerr)?;
        use vk::{AccessFlags as A, ImageLayout as L, PipelineStageFlags as S};
        let before = [
            // the shared image acquired from Godot's device, as it released it
            barrier(slot.image, (L::TRANSFER_DST_OPTIMAL, L::TRANSFER_SRC_OPTIMAL), (A::empty(), A::TRANSFER_READ), (vk::QUEUE_FAMILY_EXTERNAL, self.family)),
            barrier(image, (L::UNDEFINED, L::TRANSFER_DST_OPTIMAL), (A::empty(), A::TRANSFER_WRITE), NO_TRANSFER),
        ];
        d.cmd_pipeline_barrier(slot.cmd, S::TOP_OF_PIPE, S::TRANSFER, vk::DependencyFlags::empty(), &[], &[], &before);
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
        let after = [barrier(image, (L::TRANSFER_DST_OPTIMAL, L::GENERAL), (A::TRANSFER_WRITE, A::MEMORY_READ), NO_TRANSFER)];
        d.cmd_pipeline_barrier(slot.cmd, S::TRANSFER, S::BOTTOM_OF_PIPE, vk::DependencyFlags::empty(), &[], &[], &after);
        d.end_command_buffer(slot.cmd).map_err(vkerr)?;

        let (wait, signal, cmds, wait_stage) = ([acquire], [release], [slot.cmd], [S::TRANSFER]);
        let submit = vk::SubmitInfo::default().wait_semaphores(&wait).wait_dst_stage_mask(&wait_stage).command_buffers(&cmds).signal_semaphores(&signal);
        d.queue_submit(self.queue, &[submit], fence).map_err(|e| format!("sending the copy to the GPU failed ({e})"))?;
        // the slot's own fence, after everything submitted before it
        d.queue_submit(self.queue, &[], slot.done).map_err(vkerr)?;
        check("sending the PipeWire buffer", funnel_stream_enqueue(self.stream, buf))?;
        let ms = submitted.elapsed().as_secs_f64() * 1000.0;
        self.latency = (self.latency.0 + ms, self.latency.1.max(ms), self.latency.2 + 1);
        d.wait_for_fences(&[slot.done], true, u64::MAX).map_err(vkerr)?;
        Ok(())
    }

    unsafe fn free_slots(&mut self) {
        let _ = self.device.device_wait_idle();
        for slot in std::mem::take(&mut self.slots) {
            self.device.destroy_fence(slot.done, None);
            self.device.free_command_buffers(self.pool, &[slot.cmd]);
            self.device.destroy_image(slot.image, None);
            self.device.free_memory(slot.memory, None);
        }
    }

    unsafe fn close(&mut self) {
        let _ = self.device.device_wait_idle();
        if !self.stream.is_null() {
            if self.started {
                funnel::funnel_stream_stop(self.stream);
            }
            funnel::funnel_stream_destroy(self.stream);
            self.stream = std::ptr::null_mut();
        }
        if !self.ctx.is_null() {
            funnel::funnel_shutdown(self.ctx);
            self.ctx = std::ptr::null_mut();
        }
        self.free_slots();
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
