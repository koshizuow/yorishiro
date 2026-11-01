//! Draws a whole Live2D model through RenderingDevice into one texture (route B, D38): every art mesh's
//! vertices go up in one buffer update per frame, all masks are drawn into one atlas, and the meshes are drawn
//! in one pass with Live2D's blend equations as GPU blend states. The model node shows the texture as a single
//! canvas item, instead of one MeshInstance2D per art mesh and one SubViewport per mask.

use std::collections::HashMap;

use godot::classes::rendering_device::{
    BlendFactor, BlendOperation, DataFormat, DrawFlags, IndexBufferFormat, RenderPrimitive, SamplerFilter,
    SamplerRepeatMode, ShaderStage, TextureSamples, TextureType, TextureUsageBits, UniformType,
};
use godot::classes::{
    RdFramebufferPass, RdPipelineColorBlendState, RdPipelineColorBlendStateAttachment, RdPipelineDepthStencilState,
    RdPipelineMultisampleState, RdPipelineRasterizationState, RdSamplerState, RdShaderSource, RdTextureFormat,
    RdTextureView, RdUniform, RdVertexAttribute, RenderingDevice, RenderingServer, Texture2D, Texture2Drd,
};
use godot::prelude::*;
use katashiro_core::core::{ArtMesh, BlendMode, Collection, Item, Model};
use katashiro_core::driver::{DrawNode, Driver};
use katashiro_core::file::ParsedModel;

/// one atlas for every mask of a model, R8
const ATLAS_SIZE: u32 = 4096;
/// mask tiles are powers of two between these (pixels on a side)
const MIN_TILE: u32 = 64;
const MAX_TILE: u32 = 2048;
/// local pixels around a mask's meshes, as the mask viewports had
const MASK_MARGIN: f32 = 4.0;

const VERTEX_SHADER: &str = r#"
#version 450
layout(location = 0) in vec2 pos;
layout(location = 1) in vec2 uv;
layout(push_constant, std430) uniform Params {
    vec4 xf0;      // target x = xf0.x * pos.x + xf0.y * pos.y + xf0.z
    vec4 xf1;      // target y
    vec4 multiply; // rgb, opacity
    vec4 screen;   // rgb, mask mode (0 none, 1 mask, 2 inverted mask)
    vec4 mask0;    // the mask's local box: min.xy, 1 / size.xy
    vec4 mask1;    // its tile in the atlas: origin.xy, size.xy (0..1)
    vec4 target;   // 2 / width, 2 / height
} p;
layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec2 v_mask;
void main() {
    vec2 px = vec2(dot(p.xf0.xy, pos) + p.xf0.z, dot(p.xf1.xy, pos) + p.xf1.z);
    gl_Position = vec4(px * p.target.xy - 1.0, 0.0, 1.0);
    v_uv = uv;
    v_mask = (pos - p.mask0.xy) * p.mask0.zw;
}
"#;

/// Matches the canvas shaders (mix, add, mul.gdshader): multiply and screen colors as they had them, the
/// result premultiplied; the blend states do the rest.
const MESH_FRAGMENT: &str = r#"
#version 450
layout(push_constant, std430) uniform Params {
    vec4 xf0; vec4 xf1; vec4 multiply; vec4 screen; vec4 mask0; vec4 mask1; vec4 target;
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
        float m = inside ? texture(mask_atlas, p.mask1.xy + clamp(v_mask, 0.0, 1.0) * p.mask1.zw).r : 0.0;
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

const PARAMS_SIZE: usize = 7 * 16;

struct MeshDraw {
    uid: u32,
    index_array: Option<Rid>,
    vertex_offset: usize,
    vertex_count: usize,
    texture: usize,
    blend: BlendMode,
    mask: Option<usize>,
    invert: bool,
}

/// the meshes that make up one mask (the same clip list), and where it went this frame
struct MaskSet {
    meshes: Vec<usize>,
    /// local box min, 1 / size
    box_min: Vector2,
    box_inv: Vector2,
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
    positions: PackedByteArray,
    params: PackedByteArray,
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
                    masks.push(MaskSet {
                        meshes: vec![],
                        box_min: Vector2::ZERO,
                        box_inv: Vector2::ZERO,
                        tile: Rect2::default(),
                        drawn: false,
                    });
                    n
                }))
            };
            meshes.push(MeshDraw {
                uid,
                index_array: None,
                vertex_offset,
                vertex_count: count,
                texture: a.texture() as usize,
                blend: a.blend_config().simple().unwrap_or(BlendMode::Normal),
                mask,
                invert: a.invert_mask(),
            });
            vertex_offset += count;
        }
        let by_uid: HashMap<u32, usize> = meshes.iter().enumerate().map(|(i, m)| (m.uid, i)).collect();
        for (key, &set) in mask_keys.iter() {
            masks[set].meshes = key.iter().filter_map(|uid| by_uid.get(uid).copied()).collect();
        }
        let total = vertex_offset.max(1);

        let f32_bytes = |v: &[f32]| PackedByteArray::from(v.iter().flat_map(|f| f.to_le_bytes()).collect::<Vec<u8>>());
        let pos_buffer = rd.vertex_buffer_create((total * 8) as u32);
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
        rids.extend([mesh_shader, mask_shader]);

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

        let rs = RenderingServer::singleton();
        let mut mesh_sets = vec![];
        let mut mask_sets = vec![];
        for t in textures {
            let rd_tex = rs.texture_get_rd_texture(t.get_rid());
            mesh_sets.push(rd.uniform_set_create(
                &array![&sampler_uniform(0, sampler, rd_tex), &sampler_uniform(1, mask_sampler, atlas)],
                mesh_shader,
                0,
            ));
            mask_sets.push(rd.uniform_set_create(&array![&sampler_uniform(0, sampler, rd_tex)], mask_shader, 0));
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

        let mut positions = PackedByteArray::new();
        positions.resize(total * 8);
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
            mask_pipeline,
            atlas_framebuffer,
            target: None,
            mesh_shader,
            view,
            positions,
            params,
            color_overrides: HashMap::new(),
        })
    }

    /// The texture the model is drawn into, for the canvas item that shows it
    pub fn texture(&self) -> Gd<Texture2Drd> {
        self.view.clone()
    }

    fn ensure_target(&mut self, size: Vector2i, samples: TextureSamples) {
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
    }

    fn set_params(&mut self, values: [[f32; 4]; 7]) {
        let bytes = self.params.as_mut_slice();
        for (i, v) in values.iter().flatten().enumerate() {
            bytes[i * 4..i * 4 + 4].copy_from_slice(&v.to_le_bytes());
        }
    }

    /// Draws the driven model. to_target maps the model's local pixels (vertex * canvas scale) to target
    /// pixels, size is the target's size (the viewport the model is in).
    /// samples: the MSAA of the viewport the model is in, so its edges look the same
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

        // every vertex in one upload, in model local pixels
        {
            let bytes = self.positions.as_mut_slice();
            for m in &self.meshes {
                let Some(st) = driver.artmesh_state(m.uid) else { continue };
                if st.vertices.len() != m.vertex_count {
                    continue;
                }
                let out = &mut bytes[m.vertex_offset * 8..(m.vertex_offset + m.vertex_count) * 8];
                for (chunk, v) in out.chunks_exact_mut(8).zip(st.vertices) {
                    chunk[0..4].copy_from_slice(&(v.x * px_size).to_le_bytes());
                    chunk[4..8].copy_from_slice(&(v.y * px_size).to_le_bytes());
                }
            }
        }
        let len = self.positions.len() as u32;
        self.rd.buffer_update(self.pos_buffer, 0, len, &self.positions);

        // masks: each one's box from its meshes, a tile sized for its size on screen
        let scale = to_target.a.length().max(to_target.b.length());
        let mut order: Vec<(u32, usize)> = vec![];
        for (i, set) in self.masks.iter_mut().enumerate() {
            set.drawn = false;
            let (mut lo, mut hi) = (Vector2::new(f32::MAX, f32::MAX), Vector2::new(f32::MIN, f32::MIN));
            for &mi in &set.meshes {
                let m = &self.meshes[mi];
                let Some(st) = driver.artmesh_state(m.uid) else { continue };
                for v in st.vertices {
                    let p = Vector2::new(v.x * px_size, v.y * px_size);
                    lo = lo.coord_min(p);
                    hi = hi.coord_max(p);
                }
            }
            if lo.x > hi.x {
                continue;
            }
            lo -= Vector2::splat(MASK_MARGIN);
            hi += Vector2::splat(MASK_MARGIN);
            let extent = hi - lo;
            set.box_min = lo;
            set.box_inv = Vector2::new(1.0 / extent.x, 1.0 / extent.y);
            order.push((tile_side(extent.x.max(extent.y) * scale), i));
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
            let set = &mut self.masks[i];
            set.tile = Rect2::new(
                Vector2::new((x * MIN_TILE) as f32 * inv, (y * MIN_TILE) as f32 * inv),
                Vector2::splat(side as f32 * inv),
            );
            set.drawn = true;
        }

        let atlas_target = [2.0 / ATLAS_SIZE as f32, 2.0 / ATLAS_SIZE as f32, 0.0, 0.0];
        if self.masks.iter().any(|m| m.drawn) {
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
                // local pixels -> atlas pixels: (p - box_min) * box_inv * tile size + tile origin
                let size_px = set.tile.size.x * ATLAS_SIZE as f32;
                let s = Vector2::new(set.box_inv.x * size_px, set.box_inv.y * size_px);
                let o = set.tile.position * ATLAS_SIZE as f32 - set.box_min * s;
                let values = [[s.x, 0.0, o.x, 0.0], [0.0, s.y, o.y, 0.0], [0.0; 4], [0.0; 4], [0.0; 4], [0.0; 4], atlas_target];
                let meshes: Vec<usize> = set.meshes.clone();
                self.set_params(values);
                for mi in meshes {
                    let m = &self.meshes[mi];
                    let Some(ia) = m.index_array else { continue };
                    let Some(st) = driver.artmesh_state(m.uid) else { continue };
                    if st.vertices.len() != m.vertex_count {
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

        // the model, in draw order
        let target = self.target.as_ref().unwrap();
        let (fb, tsize) = (target.framebuffer, target.size);
        let clear = PackedColorArray::from(&[Color::from_rgba(0.0, 0.0, 0.0, 0.0)][..]);
        let list = self.rd.draw_list_begin_ex(fb).draw_flags(DrawFlags::CLEAR_COLOR_0).clear_color_values(&clear).done();
        self.rd.draw_list_bind_vertex_array(list, self.vertex_array);
        let t = to_target;
        let (xf0, xf1) = ([t.a.x, t.b.x, t.origin.x, 0.0], [t.a.y, t.b.y, t.origin.y, 0.0]);
        let target_scale = [2.0 / tsize.x as f32, 2.0 / tsize.y as f32, 0.0, 0.0];
        let (mut bound_pipeline, mut bound_set) = (usize::MAX, usize::MAX);
        let draw_order: Vec<usize> = driver
            .draw_nodes(None)
            .map(|nodes| {
                nodes
                    .iter()
                    .filter_map(|n| if let DrawNode::ArtMesh(uid) = n { self.by_uid.get(uid).copied() } else { None })
                    .collect()
            })
            .unwrap_or_default();
        for mi in draw_order {
            let m = &self.meshes[mi];
            let Some(ia) = m.index_array else { continue };
            let Some(st) = driver.artmesh_state(m.uid) else { continue };
            if !st.visual.visible || st.vertices.len() != m.vertex_count {
                continue;
            }
            let (multiply, screen) = match self.color_overrides.get(&m.uid) {
                Some((mul, scr)) => ([mul.r, mul.g, mul.b], [scr.r, scr.g, scr.b]),
                None => (st.visual.multiply_color.to_array(), st.visual.screen_color.to_array()),
            };
            let (mode, mask0, mask1) = match m.mask.map(|i| &self.masks[i]) {
                Some(set) if set.drawn => (
                    if m.invert { 2.0 } else { 1.0 },
                    [set.box_min.x, set.box_min.y, set.box_inv.x, set.box_inv.y],
                    [set.tile.position.x, set.tile.position.y, set.tile.size.x, set.tile.size.y],
                ),
                // a mask whose meshes have no vertices covers nothing
                Some(_) => (if m.invert { 0.0 } else { -1.0 }, [0.0; 4], [0.0; 4]),
                None => (0.0, [0.0; 4], [0.0; 4]),
            };
            if mode < 0.0 {
                continue;
            }
            let pipeline = match m.blend {
                BlendMode::Normal => 0,
                BlendMode::Add => 1,
                BlendMode::Multiply => 2,
            };
            let values = [
                xf0,
                xf1,
                [multiply[0], multiply[1], multiply[2], st.visual.opacity],
                [screen[0], screen[1], screen[2], mode],
                mask0,
                mask1,
                target_scale,
            ];
            let texture = m.texture;
            self.set_params(values);
            if pipeline != bound_pipeline {
                bound_pipeline = pipeline;
                self.rd.draw_list_bind_render_pipeline(list, self.mesh_pipelines[pipeline]);
                // a new pipeline needs its sets bound again
                bound_set = usize::MAX;
            }
            if texture != bound_set {
                bound_set = texture;
                self.rd.draw_list_bind_uniform_set(list, self.mesh_sets[texture], 0);
            }
            self.rd.draw_list_bind_index_array(list, ia);
            self.rd.draw_list_set_push_constant(list, &self.params, PARAMS_SIZE as u32);
            self.rd.draw_list_draw(list, true, 1);
        }
        self.rd.draw_list_end();
    }
}

impl Drop for RdRenderer {
    fn drop(&mut self) {
        self.view.set_texture_rd_rid(Rid::Invalid);
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
