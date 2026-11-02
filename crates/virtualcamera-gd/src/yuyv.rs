//! The viewport as YUYV on the GPU: a compute shader writes a texture half as wide, each RGBA8 texel being the bytes
//! Y0 U Y1 V of two pixels, so what the app reads back is the camera frame itself. The output keeps the size the camera
//! started with (readers hold that format): a resized viewport is fitted inside it over black.
use godot::classes::rendering_device::{
    DataFormat, SamplerFilter, SamplerRepeatMode, ShaderStage, TextureUsageBits, UniformType,
};
use godot::classes::{RdSamplerState, RdShaderSource, RdTextureFormat, RdTextureView, RdUniform, RenderingDevice};
use godot::prelude::*;

const SHADER: &str = r#"#version 450
layout(local_size_x = 32, local_size_y = 32) in;
layout(set = 0, binding = 0) uniform sampler2D src;
layout(set = 0, binding = 1, rgba8) uniform writeonly image2D dst;
layout(push_constant) uniform Push { vec2 size; vec2 scale; vec2 offset; vec2 pad; } p;

vec3 at(vec2 pixel) {
    vec2 uv = (pixel / p.size - p.offset) / p.scale;
    if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) return vec3(0.0);
    return texture(src, uv).rgb;
}

// BT.601, limited range
float luma(vec3 c) { return dot(c, vec3(0.257, 0.504, 0.098)) + 16.0 / 255.0; }

void main() {
    ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
    if (any(greaterThanEqual(texel, imageSize(dst)))) return;
    float y = float(texel.y) + 0.5;
    vec3 a = at(vec2(float(texel.x) * 2.0 + 0.5, y));
    vec3 b = at(vec2(float(texel.x) * 2.0 + 1.5, y));
    vec3 c = (a + b) * 0.5;
    float u = dot(c, vec3(-0.148, -0.291, 0.439)) + 128.0 / 255.0;
    float v = dot(c, vec3(0.439, -0.368, -0.071)) + 128.0 / 255.0;
    imageStore(dst, texel, vec4(luma(a), u, luma(b), v));
}
"#;
const PUSH_SIZE: u32 = 32;

pub struct Yuyv {
    rd: Gd<RenderingDevice>,
    shader: Rid,
    pipeline: Rid,
    sampler: Rid,
    pub out: Rid,
    set: Rid,
    source: Rid,
    width: u32,
    height: u32,
}

impl Yuyv {
    /// width: the camera's, even
    pub fn new(mut rd: Gd<RenderingDevice>, width: u32, height: u32) -> Result<Self, String> {
        let mut src = RdShaderSource::new_gd();
        src.set_stage_source(ShaderStage::COMPUTE, SHADER);
        let spirv = rd.shader_compile_spirv_from_source(&src).ok_or("shader compiler unavailable")?;
        let err = spirv.get_stage_compile_error(ShaderStage::COMPUTE);
        if !err.is_empty() {
            return Err(format!("camera shader: {err}"));
        }
        let shader = rd.shader_create_from_spirv(&spirv);
        let pipeline = rd.compute_pipeline_create(shader);
        let mut ss = RdSamplerState::new_gd();
        ss.set_min_filter(SamplerFilter::LINEAR);
        ss.set_mag_filter(SamplerFilter::LINEAR);
        ss.set_repeat_u(SamplerRepeatMode::CLAMP_TO_EDGE);
        ss.set_repeat_v(SamplerRepeatMode::CLAMP_TO_EDGE);
        let sampler = rd.sampler_create(&ss);
        let mut tf = RdTextureFormat::new_gd();
        tf.set_format(DataFormat::R8G8B8A8_UNORM);
        tf.set_width(width / 2);
        tf.set_height(height);
        tf.set_usage_bits(TextureUsageBits::STORAGE_BIT | TextureUsageBits::CAN_COPY_FROM_BIT);
        let out = rd.texture_create(&tf, &RdTextureView::new_gd());
        if !out.is_valid() {
            return Err("camera texture creation failed".into());
        }
        Ok(Self { rd, shader, pipeline, sampler, out, set: Rid::Invalid, source: Rid::Invalid, width, height })
    }

    fn bind(&mut self, source: Rid) {
        if self.set.is_valid() && self.rd.uniform_set_is_valid(self.set) {
            self.rd.free_rid(self.set);
        }
        let mut image = RdUniform::new_gd();
        image.set_uniform_type(UniformType::SAMPLER_WITH_TEXTURE);
        image.set_binding(0);
        image.add_id(self.sampler);
        image.add_id(source);
        let mut output = RdUniform::new_gd();
        output.set_uniform_type(UniformType::IMAGE);
        output.set_binding(1);
        output.add_id(self.out);
        let uniforms: Array<Gd<RdUniform>> = array![&image, &output];
        self.set = self.rd.uniform_set_create(&uniforms, self.shader, 0);
        self.source = source;
    }

    /// One frame of `source` (a texture of the given size) into `out`.
    pub fn convert(&mut self, source: Rid, source_size: Vector2) {
        if source != self.source || !self.rd.uniform_set_is_valid(self.set) {
            self.bind(source);
        }
        let (w, h) = (self.width as f32, self.height as f32);
        let k = (w / source_size.x).min(h / source_size.y);
        let scale = [source_size.x * k / w, source_size.y * k / h];
        let values = [w, h, scale[0], scale[1], (1.0 - scale[0]) / 2.0, (1.0 - scale[1]) / 2.0, 0.0, 0.0];
        let push: PackedByteArray = values.iter().flat_map(|v| v.to_le_bytes()).collect();
        let list = self.rd.compute_list_begin();
        self.rd.compute_list_bind_compute_pipeline(list, self.pipeline);
        self.rd.compute_list_bind_uniform_set(list, self.set, 0);
        self.rd.compute_list_set_push_constant(list, &push, PUSH_SIZE);
        self.rd.compute_list_dispatch(list, (self.width / 2).div_ceil(32), self.height.div_ceil(32), 1);
        self.rd.compute_list_end();
    }
}

impl Drop for Yuyv {
    fn drop(&mut self) {
        // the uniform set goes with the textures and the shader
        for rid in [self.out, self.sampler, self.pipeline, self.shader] {
            if rid.is_valid() {
                self.rd.free_rid(rid);
            }
        }
    }
}

