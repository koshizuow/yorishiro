//! The part of libfunnel's C API (include/funnel.h, funnel-vk.h) the node uses.
#![allow(non_camel_case_types)]

use ash::vk;
use std::os::raw::{c_char, c_int};

#[repr(C)]
pub struct funnel_ctx {
    _p: [u8; 0],
}
#[repr(C)]
pub struct funnel_stream {
    _p: [u8; 0],
}
#[repr(C)]
pub struct funnel_buffer {
    _p: [u8; 0],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct funnel_fraction {
    pub num: u32,
    pub den: u32,
}

pub const RATE_VARIABLE: funnel_fraction = funnel_fraction { num: 0, den: 1 };
/// enum funnel_mode
pub const FUNNEL_ASYNC: c_int = 0;
/// enum funnel_stream_state
pub const STATE_STREAMING: c_int = 3;

extern "C" {
    pub fn funnel_new(pctx: *mut *mut funnel_ctx) -> c_int;
    pub fn funnel_set_app_name(ctx: *mut funnel_ctx, name: *const c_char) -> c_int;
    pub fn funnel_set_app_id(ctx: *mut funnel_ctx, id: *const c_char) -> c_int;
    pub fn funnel_connect(ctx: *mut funnel_ctx) -> c_int;
    pub fn funnel_shutdown(ctx: *mut funnel_ctx);

    pub fn funnel_stream_create(ctx: *mut funnel_ctx, name: *const c_char, pstream: *mut *mut funnel_stream) -> c_int;
    pub fn funnel_stream_init_vulkan(
        stream: *mut funnel_stream,
        instance: vk::Instance,
        physical_device: vk::PhysicalDevice,
        device: vk::Device,
    ) -> c_int;
    pub fn funnel_stream_set_size(stream: *mut funnel_stream, width: u32, height: u32) -> c_int;
    pub fn funnel_stream_set_mode(stream: *mut funnel_stream, mode: c_int) -> c_int;
    pub fn funnel_stream_set_rate(
        stream: *mut funnel_stream,
        def: funnel_fraction,
        min: funnel_fraction,
        max: funnel_fraction,
    ) -> c_int;
    pub fn funnel_stream_vk_set_usage(stream: *mut funnel_stream, usage: vk::ImageUsageFlags) -> c_int;
    pub fn funnel_stream_vk_add_format(
        stream: *mut funnel_stream,
        format: vk::Format,
        alpha: bool,
        features: vk::FormatFeatureFlags,
    ) -> c_int;
    pub fn funnel_stream_configure(stream: *mut funnel_stream) -> c_int;
    pub fn funnel_stream_start(stream: *mut funnel_stream) -> c_int;
    pub fn funnel_stream_stop(stream: *mut funnel_stream) -> c_int;
    pub fn funnel_stream_get_state(stream: *mut funnel_stream, pstate: *mut c_int) -> c_int;
    pub fn funnel_stream_destroy(stream: *mut funnel_stream);
    pub fn funnel_stream_dequeue(stream: *mut funnel_stream, pbuf: *mut *mut funnel_buffer) -> c_int;
    pub fn funnel_stream_enqueue(stream: *mut funnel_stream, buf: *mut funnel_buffer) -> c_int;
    pub fn funnel_stream_return(stream: *mut funnel_stream, buf: *mut funnel_buffer) -> c_int;

    pub fn funnel_buffer_get_size(buf: *mut funnel_buffer, pwidth: *mut u32, pheight: *mut u32);
    pub fn funnel_buffer_get_vk_image(buf: *mut funnel_buffer, pimage: *mut vk::Image) -> c_int;
    pub fn funnel_buffer_get_vk_format(buf: *mut funnel_buffer, pformat: *mut vk::Format, phas_alpha: *mut bool) -> c_int;
    pub fn funnel_buffer_get_vk_semaphores(
        buf: *mut funnel_buffer,
        pacquire: *mut vk::Semaphore,
        prelease: *mut vk::Semaphore,
    ) -> c_int;
    pub fn funnel_buffer_get_vk_fence(buf: *mut funnel_buffer, pfence: *mut vk::Fence) -> c_int;
}

/// "what failed (-errno: text)" for a libfunnel error code
pub fn describe(what: &str, ret: c_int) -> String {
    format!("{what} failed ({ret}: {})", std::io::Error::from_raw_os_error(-ret))
}
