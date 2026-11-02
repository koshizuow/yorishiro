//! Draws a whole Live2D model through RenderingDevice into one texture (route B, D38, D44): the vertices are
//! deformed on the GPU (gpu_deform.rs) straight into the vertex buffer, all masks are drawn into one atlas,
//! and the meshes are drawn in one pass with Live2D's blend equations as GPU blend states. The model node
//! shows the texture as a single canvas item (it replaced one MeshInstance2D per art mesh and one SubViewport
//! per mask, D44).

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use godot::classes::rendering_device::{
    BlendFactor, BlendOperation, BufferCreationBits, DataFormat, DrawFlags, IndexBufferFormat, RenderPrimitive, SamplerFilter,
    SamplerRepeatMode, ShaderStage, TextureSamples, TextureType, TextureUsageBits, UniformType,
};
use godot::classes::{
    RdFramebufferPass, RdPipelineColorBlendState, RdPipelineColorBlendStateAttachment, RdPipelineDepthStencilState,
    RdPipelineMultisampleState, RdPipelineRasterizationState, RdSamplerState, RdShaderSource, RdTextureFormat,
    RdTextureView, RdUniform, RdVertexAttribute, RenderingDevice, RenderingServer, Texture2D, Texture2Drd,
};
use godot::prelude::*;
use katashiro_core::core::{ArtMesh, BlendMode, Collection, Item, Model, Part};
use katashiro_core::driver::{DrawNode, Driver};

use crate::gpu_deform::{GpuDeform, MeshLayout};
use katashiro_core::file::ParsedModel;

/// one atlas for every mask of a model, R8
const ATLAS_SIZE: u32 = 4096;
/// mask tiles are powers of two between these (pixels on a side)
const MIN_TILE: u32 = 64;
const MAX_TILE: u32 = 2048;
/// tile side before the first mask boxes come back from the GPU
const FIRST_TILE: u32 = 512;

const VERTEX_SHADER: &str = r#"
#version 450
layout(location = 0) in vec2 pos;
layout(location = 1) in vec2 uv;
layout(push_constant, std430) uniform Params {
    vec4 xf0;      // target x = xf0.x * pos.x + xf0.y * pos.y + xf0.z
    vec4 xf1;      // target y
    vec4 multiply; // rgb, opacity
    vec4 screen;   // rgb, mask mode (0 none, 1 mask, 2 inverted mask)
    vec4 mask;     // the mask's index, 1 when drawing into the atlas
    vec4 tile;     // its tile in the atlas: origin.xy, size.xy (0..1)
    vec4 target;   // 2 / width, 2 / height, atlas size
} p;
// each mask's box in local pixels (min.xy, max.xy), from the deform pass
layout(set = 0, binding = 2, std430) readonly buffer Boxes { vec4 boxes[]; };
layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec2 v_mask;
void main() {
    vec4 b = boxes[uint(p.mask.x)];
    v_mask = (pos - b.xy) / (b.zw - b.xy);
    vec2 px;
    if (p.mask.y > 0.5) {
        px = (p.tile.xy + v_mask * p.tile.zw) * p.target.z;
    } else {
        px = vec2(dot(p.xf0.xy, pos) + p.xf0.z, dot(p.xf1.xy, pos) + p.xf1.z);
    }
    gl_Position = vec4(px * p.target.xy - 1.0, 0.0, 1.0);
    v_uv = uv;
}
"#;

/// Multiply and screen colors as the earlier canvas shaders applied them (rgb * multiply + screen * alpha), the
/// result premultiplied; the blend states do the rest.
const MESH_FRAGMENT: &str = r#"
#version 450
layout(push_constant, std430) uniform Params {
    vec4 xf0; vec4 xf1; vec4 multiply; vec4 screen; vec4 mask; vec4 tile; vec4 target;
} p;
layout(set = 0, binding = 0) uniform sampler2D tex;
layout(set = 0, binding = 1) uniform sampler2D mask_atlas;
layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec2 v_mask;
layout(location = 0) out vec4 frag;
void main() {
    float mask = 1.0;
    if (p.screen.w > 0.5) {
        bool inside = all(greaterThanEqual(v_mask, vec2(0.0))) && all(lessThanEqual(v_mask, vec2(1.0)));
        float m = inside ? texture(mask_atlas, p.tile.xy + clamp(v_mask, 0.0, 1.0) * p.tile.zw).r : 0.0;
        mask = p.screen.w > 1.5 ? 1.0 - m : m;
        if (p.screen.w < 1.5 && !inside) {
            discard;
        }
    }
    vec4 t = texture(tex, v_uv);
    if (t.a == 0.0 || mask == 0.0) {
        discard;
    }
    vec3 rgb = t.rgb * p.multiply.rgb + p.screen.rgb * t.a;
    float a = t.a * p.multiply.a * mask;
    frag = vec4(rgb * a, a);
}
"#;

/// The mask's coverage: texture alpha, blended over what is there (a + d (1 - a))
const MASK_FRAGMENT: &str = r#"
#version 450
layout(set = 0, binding = 0) uniform sampler2D tex;
layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec2 v_mask;
layout(location = 0) out vec4 frag;
void main() {
    float a = texture(tex, v_uv).a;
    frag = vec4(a, 0.0, 0.0, a);
}
"#;

/// Composites a source image (an advanced-blend mesh drawn alone, or an offscreen part's contents, both
/// premultiplied) onto a copy of what is under it, written back over the whole target. Cubism 5.3's blend modes
/// as the editor manual describes them: color blends are the W3C Compositing and Blending ones on straight
/// colors, alpha blends are Porter-Duff source-over, source-atop, destination-out (the object cuts the canvas)
/// and XRender's conjoint and disjoint over (larger alpha, added alphas).
const COMPOSITE_VERTEX: &str = r#"
#version 450
void main() {
    vec2 p = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
"#;

const COMPOSITE_FRAGMENT: &str = r#"
#version 450
layout(push_constant, std430) uniform Params {
    vec4 inv0;     // model local x = inv0.x * px.x + inv0.y * px.y + inv0.z (for masks)
    vec4 inv1;     // local y
    vec4 multiply; // rgb, opacity
    vec4 screen;   // rgb, mask mode (0 none, 1 mask, 2 inverted)
    vec4 mask;     // mask index
    vec4 tile;     // the mask's tile in the atlas
    vec4 modes;    // color blend, alpha blend
} p;
layout(set = 0, binding = 0) uniform sampler2D src;
layout(set = 0, binding = 1) uniform sampler2D backdrop;
layout(set = 0, binding = 2) uniform sampler2D mask_atlas;
layout(set = 0, binding = 3, std430) readonly buffer Boxes { vec4 boxes[]; };
layout(location = 0) out vec4 frag;

float lum(vec3 c) { return dot(c, vec3(0.3, 0.59, 0.11)); }
vec3 clip_color(vec3 c) {
    float l = lum(c), n = min(min(c.r, c.g), c.b), x = max(max(c.r, c.g), c.b);
    if (n < 0.0) c = l + (c - l) * l / (l - n);
    if (x > 1.0) c = l + (c - l) * (1.0 - l) / (x - l);
    return c;
}
vec3 set_lum(vec3 c, float l) { return clip_color(c + (l - lum(c))); }
float sat(vec3 c) { return max(max(c.r, c.g), c.b) - min(min(c.r, c.g), c.b); }
vec3 set_sat(vec3 c, float s) {
    float mx = max(max(c.r, c.g), c.b), mn = min(min(c.r, c.g), c.b);
    if (mx <= mn) return vec3(0.0);
    return (c - mn) * s / (mx - mn);
}
float burn(float b, float s) { return b >= 1.0 ? 1.0 : (s <= 0.0 ? 0.0 : 1.0 - min(1.0, (1.0 - b) / s)); }
float dodge(float b, float s) { return b <= 0.0 ? 0.0 : (s >= 1.0 ? 1.0 : min(1.0, b / (1.0 - s))); }
float hard(float b, float s) { return s <= 0.5 ? b * 2.0 * s : b + (2.0 * s - 1.0) - b * (2.0 * s - 1.0); }
float soft(float b, float s) {
    if (s <= 0.5) return b - (1.0 - 2.0 * s) * b * (1.0 - b);
    float d = b <= 0.25 ? ((16.0 * b - 12.0) * b + 4.0) * b : sqrt(b);
    return b + (2.0 * s - 1.0) * (d - b);
}
vec3 blend(vec3 b, vec3 s, int mode) {
    switch (mode) {
        case 1: case 3: return min(b + s, vec3(1.0));
        case 4: return b + s;
        case 5: return min(b, s);
        case 2: case 6: return b * s;
        case 7: return vec3(burn(b.r, s.r), burn(b.g, s.g), burn(b.b, s.b));
        case 8: return max(b + s - 1.0, vec3(0.0));
        case 9: return max(b, s);
        case 10: return b + s - b * s;
        case 11: return vec3(dodge(b.r, s.r), dodge(b.g, s.g), dodge(b.b, s.b));
        case 12: return vec3(hard(s.r, b.r), hard(s.g, b.g), hard(s.b, b.b));
        case 13: return vec3(soft(b.r, s.r), soft(b.g, s.g), soft(b.b, s.b));
        case 14: return vec3(hard(b.r, s.r), hard(b.g, s.g), hard(b.b, s.b));
        case 15: return clamp(b + 2.0 * s - 1.0, 0.0, 1.0);
        case 16: return set_lum(set_sat(s, sat(b)), lum(b));
        case 17: return set_lum(s, lum(b));
    }
    return s;
}
void main() {
    ivec2 px = ivec2(gl_FragCoord.xy);
    vec4 s = texelFetch(src, px, 0);
    vec4 b = texelFetch(backdrop, px, 0);
    float m = 1.0;
    if (p.screen.w > 0.5) {
        vec2 local = vec2(dot(p.inv0.xy, gl_FragCoord.xy) + p.inv0.z, dot(p.inv1.xy, gl_FragCoord.xy) + p.inv1.z);
        vec4 box = boxes[uint(p.mask.x)];
        vec2 v = (local - box.xy) / (box.zw - box.xy);
        bool inside = all(greaterThanEqual(v, vec2(0.0))) && all(lessThanEqual(v, vec2(1.0)));
        float mv = inside ? texture(mask_atlas, p.tile.xy + v * p.tile.zw).r : 0.0;
        m = p.screen.w > 1.5 ? 1.0 - mv : mv;
    }
    float as = s.a * p.multiply.a * m;
    vec3 cs = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
    cs = cs * p.multiply.rgb + p.screen.rgb;
    float ab = b.a;
    vec3 cb = ab > 0.0 ? b.rgb / ab : vec3(0.0);
    vec3 mixed = (1.0 - ab) * cs + ab * blend(cb, cs, int(p.modes.x));
    vec3 co;
    float ao;
    int alpha_mode = int(p.modes.y);
    if (alpha_mode == 1) {
        co = as * ab * mixed + b.rgb * (1.0 - as);
        ao = ab;
    } else if (alpha_mode == 2) {
        co = b.rgb * (1.0 - as);
        ao = ab * (1.0 - as);
    } else if (alpha_mode == 3 || alpha_mode == 4) {
        float fb = ab > 0.0 ? (alpha_mode == 3 ? max(1.0 - as / ab, 0.0) : min(1.0, (1.0 - as) / ab)) : 0.0;
        co = as * mixed + b.rgb * fb;
        ao = as + ab * fb;
    } else {
        co = as * mixed + b.rgb * (1.0 - as);
        ao = as + ab * (1.0 - as);
    }
    frag = clamp(vec4(co, ao), 0.0, 1.0);
}
"#;

const PARAMS_SIZE: usize = 7 * 16;

struct MeshDraw {
    uid: u32,
    index_array: Option<Rid>,
    vertex_offset: usize,
    vertex_count: usize,
    texture: usize,
    /// Normal, or the pre-5.3 additive and multiply with Over: one of the fixed blend pipelines
    simple: Option<BlendMode>,
    /// advanced (Cubism 5.3): color and alpha blend, composited through the backdrop
    blend: (u8, u8),
    mask: Option<usize>,
    invert: bool,
}

/// An offscreen part: its contents are drawn into their own image and composited as one
struct PartDraw {
    blend: (u8, u8),
    mask: Option<usize>,
    invert: bool,
}

/// Images for the advanced paths (all one sample, the target's size): one per offscreen nesting level
/// (level 0 is the target itself), the backdrop copy, and an advanced mesh drawn alone
struct Layers {
    levels: Vec<(Rid, Rid)>,
    backdrop: Rid,
    single: (Rid, Rid),
    /// composite uniform sets: the single image's, then each level's (index 1..)
    sets: Vec<Rid>,
    owned: Vec<Rid>,
}

/// the meshes that make up one mask (the same clip list), and where it went this frame
struct MaskSet {
    meshes: Vec<usize>,
    /// tile in the atlas (0..1)
    tile: Rect2,
    drawn: bool,
}

struct Target {
    size: Vector2i,
    samples: TextureSamples,
    /// what the canvas shows; with MSAA the multisampled image is resolved into it
    texture: Rid,
    msaa: Option<Rid>,
    framebuffer: Rid,
}

pub struct RdRenderer {
    rd: Gd<RenderingDevice>,
    rids: Vec<Rid>,
    vertex_format: i64,
    pos_buffer: Rid,
    vertex_array: Rid,
    meshes: Vec<MeshDraw>,
    by_uid: HashMap<u32, usize>,
    masks: Vec<MaskSet>,
    /// set 0 per model texture: (texture, mask atlas) for meshes, (texture) for masks
    mesh_sets: Vec<Rid>,
    mask_sets: Vec<Rid>,
    mesh_pipelines: [Rid; 3],
    mask_pipeline: Rid,
    atlas_framebuffer: Rid,
    target: Option<Target>,
    mesh_shader: Rid,
    view: Gd<Texture2Drd>,
    deform: GpuDeform,
    /// offscreen parts by uid, how deep they nest, and whether the model needs the advanced paths (then the
    /// target has one sample, the composite reads it back)
    parts: HashMap<u32, PartDraw>,
    depth: usize,
    advanced: bool,
    composite_shader: Rid,
    composite_pipeline: Rid,
    layers: Option<Layers>,
    atlas: Rid,
    sampler: Rid,
    mask_sampler: Rid,
    /// pipeline and texture bound in the open draw list
    bound: (usize, usize),
    params: PackedByteArray,
    /// each mask's box (min.xy, max.xy) as last read back from the GPU, for the tile sizes
    boxes: Rc<RefCell<Vec<f32>>>,
    box_pending: Rc<RefCell<bool>>,
    /// meshes whose vertices are read back for the app (pinned items), and what came back
    watched: HashSet<u32>,
    read_vertices: Rc<RefCell<HashMap<u32, PackedVector2Array>>>,
    /// per mesh color settings that replace the model's (the app's mesh modifiers)
    pub color_overrides: HashMap<u32, (Color, Color)>,
}

fn compile(rd: &mut Gd<RenderingDevice>, vertex: &str, fragment: &str) -> Result<Rid, String> {
    let mut src = RdShaderSource::new_gd();
    src.set_stage_source(ShaderStage::VERTEX, vertex);
    src.set_stage_source(ShaderStage::FRAGMENT, fragment);
    let spirv = rd.shader_compile_spirv_from_source(&src).ok_or("shader compiler unavailable")?;
    for stage in [ShaderStage::VERTEX, ShaderStage::FRAGMENT] {
        let err = spirv.get_stage_compile_error(stage);
        if !err.is_empty() {
            return Err(format!("shader: {err}"));
        }
    }
    let shader = rd.shader_create_from_spirv(&spirv);
    if !shader.is_valid() {
        return Err("shader creation failed".into());
    }
    Ok(shader)
}

fn blend_attachment(
    (src_c, dst_c): (BlendFactor, BlendFactor),
    (src_a, dst_a): (BlendFactor, BlendFactor),
) -> Gd<RdPipelineColorBlendState> {
    let mut att = RdPipelineColorBlendStateAttachment::new_gd();
    att.set_enable_blend(true);
    att.set_src_color_blend_factor(src_c);
    att.set_dst_color_blend_factor(dst_c);
    att.set_color_blend_op(BlendOperation::ADD);
    att.set_src_alpha_blend_factor(src_a);
    att.set_dst_alpha_blend_factor(dst_a);
    att.set_alpha_blend_op(BlendOperation::ADD);
    let mut state = RdPipelineColorBlendState::new_gd();
    state.set_attachments(&array![&att]);
    state
}

fn pipeline(
    rd: &mut Gd<RenderingDevice>,
    shader: Rid,
    fb_format: i64,
    vertex_format: i64,
    blend: Gd<RdPipelineColorBlendState>,
    samples: TextureSamples,
) -> Rid {
    let mut ms = RdPipelineMultisampleState::new_gd();
    ms.set_sample_count(samples);
    rd.render_pipeline_create(
        shader,
        fb_format,
        vertex_format,
        RenderPrimitive::TRIANGLES,
        &RdPipelineRasterizationState::new_gd(),
        &ms,
        &RdPipelineDepthStencilState::new_gd(),
        &blend,
    )
}

fn color_texture(rd: &mut Gd<RenderingDevice>, size: Vector2i, format: DataFormat, samples: TextureSamples) -> Rid {
    let mut tf = RdTextureFormat::new_gd();
    tf.set_format(format);
    tf.set_width(size.x as u32);
    tf.set_height(size.y as u32);
    tf.set_texture_type(TextureType::TYPE_2D);
    tf.set_samples(samples);
    let usage = if samples == TextureSamples::SAMPLES_1 {
        TextureUsageBits::SAMPLING_BIT | TextureUsageBits::COLOR_ATTACHMENT_BIT | TextureUsageBits::CAN_COPY_FROM_BIT
    } else {
        TextureUsageBits::COLOR_ATTACHMENT_BIT
    };
    tf.set_usage_bits(usage);
    rd.texture_create(&tf, &RdTextureView::new_gd())
}

fn sampler_uniform(binding: i32, sampler: Rid, texture: Rid) -> Gd<RdUniform> {
    let mut u = RdUniform::new_gd();
    u.set_uniform_type(UniformType::SAMPLER_WITH_TEXTURE);
    u.set_binding(binding);
    u.add_id(sampler);
    u.add_id(texture);
    u
}

/// next power of two of n, within the tile limits
fn tile_side(n: f32) -> u32 {
    (n.max(1.0).ceil() as u32).next_power_of_two().clamp(MIN_TILE, MAX_TILE)
}

/// x, y of the i-th unit square along the Z-order curve
fn morton(i: u32) -> (u32, u32) {
    let (mut x, mut y) = (0, 0);
    for b in 0..16 {
        x |= ((i >> (2 * b)) & 1) << b;
        y |= ((i >> (2 * b + 1)) & 1) << b;
    }
    (x, y)
}

impl RdRenderer {
    /// Builds the buffers for a loaded model; textures[i] is the model's texture i
    pub fn new(model: &ParsedModel, textures: &[Gd<Texture2D>]) -> Result<Self, String> {
        let mut rd = RenderingServer::singleton().get_rendering_device().ok_or("needs the Vulkan renderer")?;
        let mut rids = vec![];

        // static data: texture coordinates and indices of every mesh, in draw order
        let mut meshes = vec![];
        let mut uvs: Vec<f32> = vec![];
        let mut indices: Vec<u32> = vec![];
        let mut ranges = vec![];
        let texcoords = model.texcoord_buffer().ok_or("no texture coordinates")?;
        let mut vertex_offset = 0usize;
        let mut mask_keys: HashMap<Vec<u32>, usize> = HashMap::new();
        let mut masks: Vec<MaskSet> = vec![];
        // vertex layout by uid; the draw order is looked up each frame
        let mut uid_order: Vec<u32> = model.artmeshes().into_iter().map(|a| a.uid()).collect();
        uid_order.sort();
        for uid in uid_order {
            let a = model.artmeshes().get(uid).unwrap();
            let count = a.vertex_count() as usize;
            let offset = a.texcoord_offset() as usize;
            for i in 0..count {
                let t = texcoords[offset + i];
                uvs.extend([t.x, t.y]);
            }
            let tri = a.indices_slice();
            let range = if count >= 3 && !tri.is_empty() {
                let start = indices.len();
                indices.extend(tri.iter().map(|&i| i as u32 + vertex_offset as u32));
                Some((start, tri.len()))
            } else {
                None
            };
            ranges.push(range);
            let clips: Vec<u32> = a.clips().into_iter().map(|c| c.uid()).collect();
            let mask = if clips.is_empty() {
                None
            } else {
                let n = masks.len();
                Some(*mask_keys.entry(clips.clone()).or_insert_with(|| {
                    masks.push(MaskSet { meshes: vec![], tile: Rect2::default(), drawn: false });
                    n
                }))
            };
            meshes.push(MeshDraw {
                uid,
                index_array: None,
                vertex_offset,
                vertex_count: count,
                texture: a.texture() as usize,
                simple: a.blend_config().simple(),
                blend: (a.blend_config().color as u8, a.blend_config().alpha as u8),
                mask,
                invert: a.invert_mask(),
            });
            vertex_offset += count;
        }
        let mut parts = HashMap::new();
        let mut depth = 0;
        for part in model.parts() {
            if !part.offscreen() {
                continue;
            }
            let mut nesting = 1;
            let mut up = part.parent().map(|p| p.uid());
            while let Some(u) = up {
                let p = model.parts().get(u).unwrap();
                nesting += p.offscreen() as usize;
                up = p.parent().map(|q| q.uid());
            }
            depth = depth.max(nesting);
            let clips: Vec<u32> = part.clips().map(|c| c.into_iter().map(|m| m.uid()).collect()).unwrap_or_default();
            let mask = if clips.is_empty() {
                None
            } else {
                let n = masks.len();
                Some(*mask_keys.entry(clips).or_insert_with(|| {
                    masks.push(MaskSet { meshes: vec![], tile: Rect2::default(), drawn: false });
                    n
                }))
            };
            let cfg = part.blend_config().unwrap_or_default();
            parts.insert(part.uid(), PartDraw { blend: (cfg.color as u8, cfg.alpha as u8), mask, invert: part.invert_mask().unwrap_or(false) });
        }
        let advanced = !parts.is_empty() || meshes.iter().any(|m| m.simple.is_none());
        let by_uid: HashMap<u32, usize> = meshes.iter().enumerate().map(|(i, m)| (m.uid, i)).collect();
        for (key, &set) in mask_keys.iter() {
            masks[set].meshes = key.iter().filter_map(|uid| by_uid.get(uid).copied()).collect();
        }
        let total = vertex_offset.max(1);

        let f32_bytes = |v: &[f32]| PackedByteArray::from(v.iter().flat_map(|f| f.to_le_bytes()).collect::<Vec<u8>>());
        // written by the deform pass
        let pos_buffer = rd.vertex_buffer_create_ex((total * 8) as u32).creation_bits(BufferCreationBits::AS_STORAGE_BIT).done();
        let uv_bytes = f32_bytes(&uvs);
        let uv_buffer = rd.vertex_buffer_create_ex((total * 8) as u32).data(&uv_bytes).done();
        let index_bytes = PackedByteArray::from(indices.iter().flat_map(|i| i.to_le_bytes()).collect::<Vec<u8>>());
        let index_buffer = rd.index_buffer_create_ex(indices.len().max(1) as u32, IndexBufferFormat::UINT32).data(&index_bytes).done();
        rids.extend([pos_buffer, uv_buffer, index_buffer]);
        for (m, range) in meshes.iter_mut().zip(ranges) {
            if let Some((start, len)) = range {
                let ia = rd.index_array_create(index_buffer, start as u32, len as u32);
                m.index_array = Some(ia);
            }
        }

        let attr = |location: u32| {
            let mut a = RdVertexAttribute::new_gd();
            a.set_location(location);
            a.set_format(DataFormat::R32G32_SFLOAT);
            a.set_stride(8);
            a
        };
        let vertex_format = rd.vertex_format_create(&array![&attr(0), &attr(1)]);
        let vertex_array = rd.vertex_array_create(total as u32, vertex_format, &array![pos_buffer, uv_buffer]);

        let mesh_shader = compile(&mut rd, VERTEX_SHADER, MESH_FRAGMENT)?;
        let mask_shader = compile(&mut rd, VERTEX_SHADER, MASK_FRAGMENT)?;
        let composite_shader = compile(&mut rd, COMPOSITE_VERTEX, COMPOSITE_FRAGMENT)?;
        rids.extend([mesh_shader, mask_shader, composite_shader]);

        // the canvas default: linear with mipmaps, clamped
        let mut ss = RdSamplerState::new_gd();
        ss.set_min_filter(SamplerFilter::LINEAR);
        ss.set_mag_filter(SamplerFilter::LINEAR);
        ss.set_mip_filter(SamplerFilter::LINEAR);
        ss.set_repeat_u(SamplerRepeatMode::CLAMP_TO_EDGE);
        ss.set_repeat_v(SamplerRepeatMode::CLAMP_TO_EDGE);
        let sampler = rd.sampler_create(&ss);
        let mut ms = RdSamplerState::new_gd();
        ms.set_min_filter(SamplerFilter::LINEAR);
        ms.set_mag_filter(SamplerFilter::LINEAR);
        ms.set_repeat_u(SamplerRepeatMode::CLAMP_TO_EDGE);
        ms.set_repeat_v(SamplerRepeatMode::CLAMP_TO_EDGE);
        let mask_sampler = rd.sampler_create(&ms);
        rids.extend([sampler, mask_sampler]);

        let atlas = color_texture(&mut rd, Vector2i::new(ATLAS_SIZE as i32, ATLAS_SIZE as i32), DataFormat::R8_UNORM, TextureSamples::SAMPLES_1);
        let atlas_framebuffer = rd.framebuffer_create(&array![atlas]);
        rids.extend([atlas]);

        let layout: Vec<MeshLayout> = meshes
            .iter()
            .map(|m| MeshLayout { uid: m.uid, vertex_offset: m.vertex_offset, vertex_count: m.vertex_count })
            .collect();
        let mask_meshes: Vec<Vec<usize>> = masks.iter().map(|m| m.meshes.clone()).collect();
        let deform = GpuDeform::new(&mut rd, model, &layout, pos_buffer, &mask_meshes)?;
        let boxes_uniform = || {
            let mut u = RdUniform::new_gd();
            u.set_uniform_type(UniformType::STORAGE_BUFFER);
            u.set_binding(2);
            u.add_id(deform.boxes);
            u
        };

        let rs = RenderingServer::singleton();
        let mut mesh_sets = vec![];
        let mut mask_sets = vec![];
        for t in textures {
            let rd_tex = rs.texture_get_rd_texture(t.get_rid());
            mesh_sets.push(rd.uniform_set_create(
                &array![&sampler_uniform(0, sampler, rd_tex), &sampler_uniform(1, mask_sampler, atlas), &boxes_uniform()],
                mesh_shader,
                0,
            ));
            mask_sets.push(rd.uniform_set_create(&array![&sampler_uniform(0, sampler, rd_tex), &boxes_uniform()], mask_shader, 0));
        }

        use BlendFactor as F;
        let atlas_format = rd.framebuffer_get_format(atlas_framebuffer);
        let mask_pipeline = pipeline(
            &mut rd,
            mask_shader,
            atlas_format,
            vertex_format,
            blend_attachment((F::ONE, F::ONE_MINUS_SRC_ALPHA), (F::ONE, F::ONE_MINUS_SRC_ALPHA)),
            TextureSamples::SAMPLES_1,
        );

        let mut params = PackedByteArray::new();
        params.resize(PARAMS_SIZE);
        let mut view = Texture2Drd::new_gd();
        view.set_texture_rd_rid(Rid::Invalid);
        Ok(Self {
            rd,
            rids,
            vertex_format,
            pos_buffer,
            vertex_array,
            meshes,
            by_uid,
            masks,
            mesh_sets,
            mask_sets,
            mesh_pipelines: [Rid::Invalid; 3],
            parts,
            depth,
            advanced,
            composite_shader,
            composite_pipeline: Rid::Invalid,
            layers: None,
            atlas,
            sampler,
            mask_sampler,
            bound: (usize::MAX, usize::MAX),
            mask_pipeline,
            atlas_framebuffer,
            target: None,
            mesh_shader,
            view,
            deform,
            params,
            boxes: Rc::new(RefCell::new(vec![])),
            box_pending: Rc::new(RefCell::new(false)),
            watched: HashSet::new(),
            read_vertices: Rc::new(RefCell::new(HashMap::new())),
            color_overrides: HashMap::new(),
        })
    }

    /// The texture the model is drawn into, for the canvas item that shows it
    pub fn texture(&self) -> Gd<Texture2Drd> {
        self.view.clone()
    }

    fn ensure_target(&mut self, size: Vector2i, samples: TextureSamples) {
        // the advanced paths read the target back: one sample
        let samples = if self.advanced { TextureSamples::SAMPLES_1 } else { samples };
        if self.target.as_ref().is_some_and(|t| t.size == size && t.samples == samples) {
            return;
        }
        let rd = &mut self.rd;
        let old_samples = self.target.as_ref().map(|t| t.samples);
        if let Some(old) = self.target.take() {
            rd.free_rid(old.texture);
            if let Some(m) = old.msaa {
                rd.free_rid(m);
            }
        }
        let texture = color_texture(rd, size, DataFormat::R8G8B8A8_UNORM, TextureSamples::SAMPLES_1);
        let (msaa, framebuffer) = if samples == TextureSamples::SAMPLES_1 {
            (None, rd.framebuffer_create(&array![texture]))
        } else {
            let msaa = color_texture(rd, size, DataFormat::R8G8B8A8_UNORM, samples);
            let mut pass = RdFramebufferPass::new_gd();
            pass.set_color_attachments(&PackedInt32Array::from(&[0][..]));
            pass.set_resolve_attachments(&PackedInt32Array::from(&[1][..]));
            (Some(msaa), rd.framebuffer_create_multipass(&array![msaa, texture], &array![&pass]))
        };
        if old_samples != Some(samples) {
            for p in self.mesh_pipelines.iter_mut() {
                if p.is_valid() {
                    rd.free_rid(*p);
                }
            }
            use BlendFactor as F;
            let format = rd.framebuffer_get_format(framebuffer);
            // Live2D's equations, on premultiplied color: normal (1, 1 - Sa) for color and alpha; additive
            // (1, 1) color, alpha kept; multiply (Dst, 1 - Sa) color, alpha kept
            let blends = [
                ((F::ONE, F::ONE_MINUS_SRC_ALPHA), (F::ONE, F::ONE_MINUS_SRC_ALPHA)),
                ((F::ONE, F::ONE), (F::ZERO, F::ONE)),
                ((F::DST_COLOR, F::ONE_MINUS_SRC_ALPHA), (F::ZERO, F::ONE)),
            ];
            for (i, (c, a)) in blends.into_iter().enumerate() {
                self.mesh_pipelines[i] = pipeline(rd, self.mesh_shader, format, self.vertex_format, blend_attachment(c, a), samples);
            }
        }
        self.view.set_texture_rd_rid(texture);
        self.target = Some(Target { size, samples, texture, msaa, framebuffer });
        if self.advanced {
            self.make_layers(size, texture, framebuffer);
        }
    }

    /// The images and composite sets for offscreen parts and advanced blends, at the target's size
    fn make_layers(&mut self, size: Vector2i, target: Rid, framebuffer: Rid) {
        let rd = &mut self.rd;
        if let Some(old) = self.layers.take() {
            for rid in old.sets.into_iter().chain(old.owned.into_iter().rev()) {
                rd.free_rid(rid);
            }
        }
        let mut owned = vec![];
        let image = |rd: &mut Gd<RenderingDevice>, owned: &mut Vec<Rid>| {
            let t = color_texture(rd, size, DataFormat::R8G8B8A8_UNORM, TextureSamples::SAMPLES_1);
            let fb = rd.framebuffer_create(&array![t]);
            owned.push(t);
            (t, fb)
        };
        let mut levels = vec![(target, framebuffer)];
        for _ in 0..self.depth {
            levels.push(image(rd, &mut owned));
        }
        let single = image(rd, &mut owned);
        let mut tf = RdTextureFormat::new_gd();
        tf.set_format(DataFormat::R8G8B8A8_UNORM);
        tf.set_width(size.x as u32);
        tf.set_height(size.y as u32);
        tf.set_texture_type(TextureType::TYPE_2D);
        tf.set_usage_bits(TextureUsageBits::SAMPLING_BIT | TextureUsageBits::CAN_COPY_TO_BIT);
        let backdrop = rd.texture_create(&tf, &RdTextureView::new_gd());
        owned.push(backdrop);
        if !self.composite_pipeline.is_valid() {
            let format = rd.framebuffer_get_format(framebuffer);
            // replaces the target: the shader has already composited
            let mut state = RdPipelineColorBlendState::new_gd();
            state.set_attachments(&array![&RdPipelineColorBlendStateAttachment::new_gd()]);
            self.composite_pipeline = rd.render_pipeline_create(
                self.composite_shader,
                format,
                -1,
                RenderPrimitive::TRIANGLES,
                &RdPipelineRasterizationState::new_gd(),
                &RdPipelineMultisampleState::new_gd(),
                &RdPipelineDepthStencilState::new_gd(),
                &state,
            );
        }
        let boxes = self.deform.boxes;
        let set_for = |rd: &mut Gd<RenderingDevice>, src: Rid| {
            let mut b = RdUniform::new_gd();
            b.set_uniform_type(UniformType::STORAGE_BUFFER);
            b.set_binding(3);
            b.add_id(boxes);
            rd.uniform_set_create(
                &array![
                    &sampler_uniform(0, self.sampler, src),
                    &sampler_uniform(1, self.sampler, backdrop),
                    &sampler_uniform(2, self.mask_sampler, self.atlas),
                    &b
                ],
                self.composite_shader,
                0,
            )
        };
        let mut sets = vec![set_for(rd, single.0)];
        for l in levels.iter().skip(1) {
            sets.push(set_for(rd, l.0));
        }
        self.layers = Some(Layers { levels, backdrop, single, sets, owned });
    }

    fn set_params(&mut self, values: [[f32; 4]; 7]) {
        let bytes = self.params.as_mut_slice();
        for (i, v) in values.iter().flatten().enumerate() {
            bytes[i * 4..i * 4 + 4].copy_from_slice(&v.to_le_bytes());
        }
    }

    /// Draws the driven model. to_target maps the model's local pixels (vertex * canvas scale) to target
    /// pixels, size is the target's size (the viewport the model is in).
    /// An art mesh's vertices for the app (pinned items): read back from the GPU, a frame or two old; None
    /// until the first read arrives
    pub fn vertices(&mut self, uid: u32) -> Option<PackedVector2Array> {
        self.watched.insert(uid);
        self.read_vertices.borrow().get(&uid).cloned()
    }

    /// Compares the GPU's vertices with a CPU-deformed driver in the same pose (waits for the GPU): a report
    /// line with the largest error in local pixels and the meshes off by more than a pixel
    pub fn check_against(&mut self, model: &ParsedModel, gpu: &Driver<ParsedModel>, cpu: &Driver<ParsedModel>) -> String {
        let data = self.rd.buffer_get_data(self.pos_buffer);
        let f: Vec<f32> = data.as_slice().chunks_exact(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect();
        let px = model.canvas_properties().scale;
        let (mut worst, mut checked, mut no_forms) = (0f32, 0, 0);
        let mut bad = vec![];
        for m in &self.meshes {
            let Some(c) = cpu.artmesh_state(m.uid) else { continue };
            if c.vertices.len() != m.vertex_count {
                continue;
            }
            if gpu.artmesh_state(m.uid).is_none_or(|g| g.forms.is_empty()) {
                no_forms += 1;
                continue;
            }
            checked += 1;
            let mut e = 0f32;
            for (k, v) in c.vertices.iter().enumerate() {
                let i = (m.vertex_offset + k) * 2;
                e = e.max((f[i] - v.x * px).abs()).max((f[i + 1] - v.y * px).abs());
            }
            worst = worst.max(e);
            if e > 1.0 {
                bad.push(format!("{}:{:.1}", m.uid, e));
            }
        }
        bad.truncate(12);
        format!("checked {checked} meshes ({no_forms} with CPU vertices but no GPU forms), largest error {worst:.4} px, off by more than 1 px: {} {:?}", bad.len(), bad)
    }

    /// Reads back the boxes (for next frames' tile sizes) and the watched meshes, without waiting for the GPU
    fn request_readbacks(&mut self) {
        if !*self.box_pending.borrow() && !self.masks.is_empty() {
            *self.box_pending.borrow_mut() = true;
            let (boxes, pending) = (self.boxes.clone(), self.box_pending.clone());
            let callback = Callable::from_fn("katashiro_boxes", move |args: &[&Variant]| {
                if let Some(Ok(data)) = args.first().map(|a| a.try_to::<PackedByteArray>()) {
                    *boxes.borrow_mut() = data.as_slice().chunks_exact(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect();
                }
                *pending.borrow_mut() = false;
            });
            let n = (self.masks.len() * 16) as u32;
            self.rd.buffer_get_data_async_ex(self.deform.boxes, &callback).size_bytes(n).done();
        }
        for &uid in &self.watched {
            let Some(&mi) = self.by_uid.get(&uid) else { continue };
            let m = &self.meshes[mi];
            let read = self.read_vertices.clone();
            let callback = Callable::from_fn("katashiro_vertices", move |args: &[&Variant]| {
                if let Some(Ok(data)) = args.first().map(|a| a.try_to::<PackedByteArray>()) {
                    let f: Vec<f32> = data.as_slice().chunks_exact(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect();
                    read.borrow_mut().insert(uid, f.chunks_exact(2).map(|p| Vector2::new(p[0], p[1])).collect());
                }
            });
            self.rd
                .buffer_get_data_async_ex(self.pos_buffer, &callback)
                .offset_bytes((m.vertex_offset * 8) as u32)
                .size_bytes((m.vertex_count.max(1) * 8) as u32)
                .done();
        }
    }

    /// Draws the driven model (its driver in GPU geometry mode). to_target maps the model's local pixels
    /// (vertex * canvas scale) to target pixels, size is the target's size (the viewport the model is in);
    /// samples: the MSAA of that viewport, so its edges look the same
    pub fn render(
        &mut self,
        model: &ParsedModel,
        driver: &Driver<ParsedModel>,
        to_target: Transform2D,
        size: Vector2i,
        samples: TextureSamples,
    ) {
        if size.x < 1 || size.y < 1 {
            return;
        }
        self.ensure_target(size, samples);
        let px_size = model.canvas_properties().scale;
        self.deform.run(driver, px_size);

        // masks: a tile sized for each mask's size on screen (boxes from a frame or two ago)
        let scale = to_target.a.length().max(to_target.b.length());
        let boxes = self.boxes.borrow().clone();
        let mut order: Vec<(u32, usize)> = vec![];
        for (i, set) in self.masks.iter_mut().enumerate() {
            set.drawn = set.meshes.iter().any(|&mi| driver.artmesh_state(self.meshes[mi].uid).is_some_and(|st| !st.forms.is_empty()));
            if !set.drawn {
                continue;
            }
            let side = match boxes.get(i * 4..i * 4 + 4) {
                Some(b) if b[2] > b[0] && b[3] > b[1] => tile_side((b[2] - b[0]).max(b[3] - b[1]) * scale),
                _ => FIRST_TILE,
            };
            order.push((side, i));
        }
        // largest first along the Z-order curve: power of two squares pack without gaps; halve all if they
        // do not fit
        order.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
        let mut shrink = 0;
        while order.iter().map(|(s, _)| ((s >> shrink).max(MIN_TILE) as u64).pow(2)).sum::<u64>() > (ATLAS_SIZE as u64).pow(2) {
            shrink += 1;
        }
        let mut cursor = 0u64;
        for &(side, i) in &order {
            let side = (side >> shrink).max(MIN_TILE);
            let (x, y) = morton((cursor / (MIN_TILE as u64 * MIN_TILE as u64)) as u32);
            cursor += (side as u64).pow(2);
            let inv = 1.0 / ATLAS_SIZE as f32;
            self.masks[i].tile = Rect2::new(
                Vector2::new((x * MIN_TILE) as f32 * inv, (y * MIN_TILE) as f32 * inv),
                Vector2::splat(side as f32 * inv),
            );
        }

        let atlas_target = [2.0 / ATLAS_SIZE as f32, 2.0 / ATLAS_SIZE as f32, ATLAS_SIZE as f32, 0.0];
        if !order.is_empty() {
            let clear = PackedColorArray::from(&[Color::from_rgba(0.0, 0.0, 0.0, 0.0)][..]);
            let list = self
                .rd
                .draw_list_begin_ex(self.atlas_framebuffer)
                .draw_flags(DrawFlags::CLEAR_COLOR_0)
                .clear_color_values(&clear)
                .done();
            self.rd.draw_list_bind_render_pipeline(list, self.mask_pipeline);
            self.rd.draw_list_bind_vertex_array(list, self.vertex_array);
            let mut bound_set = usize::MAX;
            for si in 0..self.masks.len() {
                let set = &self.masks[si];
                if !set.drawn {
                    continue;
                }
                let t = set.tile;
                let values = [
                    [0.0; 4],
                    [0.0; 4],
                    [0.0; 4],
                    [0.0; 4],
                    [si as f32, 1.0, 0.0, 0.0],
                    [t.position.x, t.position.y, t.size.x, t.size.y],
                    atlas_target,
                ];
                let meshes: Vec<usize> = set.meshes.clone();
                self.set_params(values);
                for mi in meshes {
                    let m = &self.meshes[mi];
                    let Some(ia) = m.index_array else { continue };
                    if !driver.artmesh_state(m.uid).is_some_and(|st| !st.forms.is_empty()) {
                        continue;
                    }
                    if m.texture != bound_set {
                        bound_set = m.texture;
                        self.rd.draw_list_bind_uniform_set(list, self.mask_sets[m.texture], 0);
                    }
                    self.rd.draw_list_bind_index_array(list, ia);
                    self.rd.draw_list_set_push_constant(list, &self.params, PARAMS_SIZE as u32);
                    self.rd.draw_list_draw(list, true, 1);
                }
            }
            self.rd.draw_list_end();
        }

        // the model, in draw order: offscreen parts and advanced blends composite through the layers
        let tsize = self.target.as_ref().unwrap().size;
        let t = to_target;
        let inv = to_target.affine_inverse();
        let ctx = DrawCtx {
            xf: [[t.a.x, t.b.x, t.origin.x, 0.0], [t.a.y, t.b.y, t.origin.y, 0.0]],
            inv: [[inv.a.x, inv.b.x, inv.origin.x, 0.0], [inv.a.y, inv.b.y, inv.origin.y, 0.0]],
            target: [2.0 / tsize.x as f32, 2.0 / tsize.y as f32, ATLAS_SIZE as f32, 0.0],
            size: tsize,
        };
        let root: Vec<DrawNode<u32>> = driver.draw_nodes(None).map(|n| n.to_vec()).unwrap_or_default();
        let mut list = Some(self.begin(0, true));
        self.draw_tree(driver, &root, 0, &mut list, &ctx);
        if list.is_some() {
            self.rd.draw_list_end();
        }
        self.request_readbacks();
    }
}


/// What every draw in a frame shares
struct DrawCtx {
    /// model local pixels -> target pixels, and back (for part masks)
    xf: [[f32; 4]; 2],
    inv: [[f32; 4]; 2],
    target: [f32; 4],
    size: Vector2i,
}

impl RdRenderer {
    /// A draw list on a level (0: the target), cleared or loading what is there
    fn begin(&mut self, level: usize, clear: bool) -> i64 {
        let fb = match &self.layers {
            Some(l) => l.levels[level].1,
            None => self.target.as_ref().unwrap().framebuffer,
        };
        self.begin_on(fb, clear)
    }

    fn begin_on(&mut self, fb: Rid, clear: bool) -> i64 {
        let colors = PackedColorArray::from(&[Color::from_rgba(0.0, 0.0, 0.0, 0.0)][..]);
        let list = if clear {
            self.rd.draw_list_begin_ex(fb).draw_flags(DrawFlags::CLEAR_COLOR_0).clear_color_values(&colors).done()
        } else {
            self.rd.draw_list_begin(fb)
        };
        self.rd.draw_list_bind_vertex_array(list, self.vertex_array);
        self.bound = (usize::MAX, usize::MAX);
        list
    }

    fn end(&mut self, list: &mut Option<i64>) {
        if list.take().is_some() {
            self.rd.draw_list_end();
        }
    }

    fn draw_tree(&mut self, driver: &Driver<ParsedModel>, nodes: &[DrawNode<u32>], level: usize, list: &mut Option<i64>, ctx: &DrawCtx) {
        for node in nodes {
            match node {
                DrawNode::ArtMesh(uid) => {
                    let Some(&mi) = self.by_uid.get(uid) else { continue };
                    let simple = self.meshes[mi].simple;
                    match simple {
                        Some(mode) => {
                            let l = *list.get_or_insert_with(|| self.begin(level, false));
                            self.draw_mesh(driver, mi, mode, l, ctx);
                        }
                        None => self.draw_advanced_mesh(driver, mi, level, list, ctx),
                    }
                }
                DrawNode::OffscreenPart(uid) => self.draw_offscreen(driver, *uid, level, list, ctx),
            }
        }
    }

    /// One mesh with a fixed blend pipeline into the open list; false when it is not drawn
    fn draw_mesh(&mut self, driver: &Driver<ParsedModel>, mi: usize, mode: BlendMode, list: i64, ctx: &DrawCtx) -> bool {
        let m = &self.meshes[mi];
        let Some(ia) = m.index_array else { return false };
        let Some(st) = driver.artmesh_state(m.uid) else { return false };
        if !st.visual.visible || st.forms.is_empty() {
            return false;
        }
        let (multiply, screen) = match self.color_overrides.get(&m.uid) {
            Some((mul, scr)) => ([mul.r, mul.g, mul.b], [scr.r, scr.g, scr.b]),
            None => (st.visual.multiply_color.to_array(), st.visual.screen_color.to_array()),
        };
        let Some((mask_mode, mask, tile)) = self.mask_params(m.mask, m.invert) else { return false };
        let pipeline = match mode {
            BlendMode::Normal => 0,
            BlendMode::Add => 1,
            BlendMode::Multiply => 2,
        };
        let values = [
            ctx.xf[0],
            ctx.xf[1],
            [multiply[0], multiply[1], multiply[2], st.visual.opacity],
            [screen[0], screen[1], screen[2], mask_mode],
            mask,
            tile,
            ctx.target,
        ];
        let texture = m.texture;
        self.set_params(values);
        if pipeline != self.bound.0 {
            self.bound = (pipeline, usize::MAX);
            self.rd.draw_list_bind_render_pipeline(list, self.mesh_pipelines[pipeline]);
        }
        if texture != self.bound.1 {
            self.bound.1 = texture;
            self.rd.draw_list_bind_uniform_set(list, self.mesh_sets[texture], 0);
        }
        self.rd.draw_list_bind_index_array(list, ia);
        self.rd.draw_list_set_push_constant(list, &self.params, PARAMS_SIZE as u32);
        self.rd.draw_list_draw(list, true, 1);
        true
    }

    /// (mode, mask, tile) push values for a mask; None when a mask that covers nothing hides the object
    fn mask_params(&self, mask: Option<usize>, invert: bool) -> Option<(f32, [f32; 4], [f32; 4])> {
        match mask.map(|i| (i, &self.masks[i])) {
            Some((i, set)) if set.drawn => Some((
                if invert { 2.0 } else { 1.0 },
                [i as f32, 0.0, 0.0, 0.0],
                [set.tile.position.x, set.tile.position.y, set.tile.size.x, set.tile.size.y],
            )),
            Some(_) if !invert => None,
            _ => Some((0.0, [0.0; 4], [0.0; 4])),
        }
    }

    /// Copies a level into the backdrop and composites a source (0: the single image, n: level n) over it
    fn composite(&mut self, level: usize, source: usize, values: [[f32; 4]; 7], list: &mut Option<i64>, ctx: &DrawCtx) {
        self.end(list);
        let layers = self.layers.as_ref().unwrap();
        let (from, backdrop, set) = (layers.levels[level].0, layers.backdrop, layers.sets[source]);
        let size = Vector3::new(ctx.size.x as f32, ctx.size.y as f32, 1.0);
        self.rd.texture_copy(from, backdrop, Vector3::ZERO, Vector3::ZERO, size, 0, 0, 0, 0);
        let l = self.begin(level, false);
        self.rd.draw_list_bind_render_pipeline(l, self.composite_pipeline);
        self.rd.draw_list_bind_uniform_set(l, set, 0);
        self.set_params(values);
        self.rd.draw_list_set_push_constant(l, &self.params, PARAMS_SIZE as u32);
        self.rd.draw_list_draw_ex(l, false, 1).procedural_vertex_count(3).done();
        // the mesh pipelines are bound again on the next mesh
        self.bound = (usize::MAX, usize::MAX);
        *list = Some(l);
    }

    /// A Cubism 5.3 blend mesh: drawn alone (its colors, opacity and mask), then composited with its blend
    fn draw_advanced_mesh(&mut self, driver: &Driver<ParsedModel>, mi: usize, level: usize, list: &mut Option<i64>, ctx: &DrawCtx) {
        self.end(list);
        let single = self.layers.as_ref().unwrap().single.1;
        let l = self.begin_on(single, true);
        let drawn = self.draw_mesh(driver, mi, BlendMode::Normal, l, ctx);
        self.rd.draw_list_end();
        if drawn {
            let (c, a) = self.meshes[mi].blend;
            let values = [ctx.inv[0], ctx.inv[1], [1.0; 4], [0.0; 4], [0.0; 4], [0.0; 4], [c as f32, a as f32, 0.0, 0.0]];
            self.composite(level, 0, values, list, ctx);
        }
    }

    /// An offscreen part: its contents into the next level, then composited with the part's opacity, colors,
    /// blend and mask
    fn draw_offscreen(&mut self, driver: &Driver<ParsedModel>, uid: u32, level: usize, list: &mut Option<i64>, ctx: &DrawCtx) {
        let Some(visual) = driver.part_state(uid).and_then(|p| p.visual) else { return };
        if !visual.visible || visual.opacity <= 0.0 {
            return;
        }
        let Some(part) = self.parts.get(&uid) else { return };
        let (blend, mask, invert) = (part.blend, part.mask, part.invert);
        let Some((mask_mode, mask, tile)) = self.mask_params(mask, invert) else { return };
        let children: Vec<DrawNode<u32>> = driver.draw_nodes(Some(uid)).map(|n| n.to_vec()).unwrap_or_default();
        self.end(list);
        let mut inner = Some(self.begin(level + 1, true));
        self.draw_tree(driver, &children, level + 1, &mut inner, ctx);
        self.end(&mut inner);
        let (m, sc) = (visual.multiply_color.to_array(), visual.screen_color.to_array());
        let values = [
            ctx.inv[0],
            ctx.inv[1],
            [m[0], m[1], m[2], visual.opacity],
            [sc[0], sc[1], sc[2], mask_mode],
            mask,
            tile,
            [blend.0 as f32, blend.1 as f32, 0.0, 0.0],
        ];
        self.composite(level, level + 1, values, list, ctx);
    }
}

impl Drop for RdRenderer {
    fn drop(&mut self) {
        self.view.set_texture_rd_rid(Rid::Invalid);
        if let Some(l) = self.layers.take() {
            for rid in l.sets.into_iter().chain(l.owned.into_iter().rev()) {
                self.rd.free_rid(rid);
            }
        }
        if let Some(t) = self.target.take() {
            self.rd.free_rid(t.texture);
            if let Some(m) = t.msaa {
                self.rd.free_rid(m);
            }
        }
        // dependents (arrays, sets, pipelines, framebuffers) go with what they use
        for rid in self.rids.drain(..).rev() {
            if rid.is_valid() {
                self.rd.free_rid(rid);
            }
        }
    }
}
