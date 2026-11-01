//! Deforms a Live2D model on the GPU (route B, D44): the driver only decides which forms blend with what
//! weights (Driver::set_gpu_geometry), one compute shader does the rest each frame:
//!
//! 1. the deformer tree level by level: warp grids blend their forms and go through their parent, rotation
//!    deformers compose their transform with their parent's;
//! 2. every art mesh vertex: its forms blended, through its deformer, in the model's local pixels, written
//!    straight into the vertex buffer the renderer draws;
//! 3. glue, in batches that share no mesh (in the model's order where they do);
//! 4. each mask's box around its meshes, for the mask atlas.
//!
//! The arithmetic follows the driver's CPU path (driver/mod.rs WarpState::apply, calc_rot) step by step.

use std::collections::HashMap;

use godot::classes::rendering_device::{ShaderStage, UniformType};
use godot::classes::{RdShaderSource, RdUniform, RenderingDevice};
use godot::prelude::*;
use katashiro_core::core::{
    ArtMesh, BlendFormMap, Collection, Deformer, Glue, Item, ItemArray, Model, TypedDeformer, WarpDeformer,
    WarpForm, ArtMeshForm,
};
use katashiro_core::driver::{DeformerPlan, Driver};
use katashiro_core::file::ParsedModel;

/// local pixels around a mask's meshes
pub const MASK_MARGIN: f32 = 4.0;

const SHADER: &str = r#"
#version 450
layout(local_size_x = 64) in;
layout(push_constant, std430) uniform Push { uint mode; uint start; uint count; float px; } pc;

struct DefDyn { uint start; uint count; uint valid; float parent_warp_scale; vec4 m; vec4 t; };
struct RotOut { vec4 m; vec4 t; };
struct GluePair { uint va; uint vb; float wa; float wb; uint glue; uint ma; uint mb; uint pad; };

layout(set = 0, binding = 0, std430) readonly buffer ArtForms { vec2 art_forms[]; };
layout(set = 0, binding = 1, std430) readonly buffer WarpForms { vec2 warp_forms[]; };
layout(set = 0, binding = 2, std430) buffer Grid { vec2 grid[]; };
// x: kind (1 warp, 2 rotation) | bilinear << 4, y: parent + 1, z: grid offset, w: size.x | size.y << 16
layout(set = 0, binding = 3, std430) readonly buffer DefStatic { uvec4 def_static[]; };
layout(set = 0, binding = 4, std430) readonly buffer DefDynBuf { DefDyn def_dyn[]; };
layout(set = 0, binding = 5, std430) buffer RotBuf { RotOut rot[]; };
// (form offset, weight bits)
layout(set = 0, binding = 6, std430) readonly buffer Weights { uvec2 weights[]; };
// (deformer, point) by tree level
layout(set = 0, binding = 7, std430) readonly buffer Items { uvec2 items[]; };
layout(set = 0, binding = 8, std430) readonly buffer VertMesh { uint vert_mesh[]; };
// x: first vertex, y: deformer + 1
layout(set = 0, binding = 9, std430) readonly buffer MeshStatic { uvec4 mesh_static[]; };
// (weights start, count), count 0: no geometry this frame
layout(set = 0, binding = 10, std430) readonly buffer MeshDyn { uvec2 mesh_dyn[]; };
layout(set = 0, binding = 11, std430) buffer Pos { vec2 pos[]; };
layout(set = 0, binding = 12, std430) readonly buffer Glues { GluePair glue_pairs[]; };
layout(set = 0, binding = 13, std430) readonly buffer GlueCompat { float compat[]; };
// per mask: (start, count) into mask_items, the mesh indices of its meshes
layout(set = 0, binding = 14, std430) readonly buffer MaskSets { uvec2 mask_sets[]; };
layout(set = 0, binding = 15, std430) readonly buffer MaskItems { uint mask_items[]; };
layout(set = 0, binding = 16, std430) buffer Boxes { vec4 boxes[]; };

shared vec4 red[64];

vec2 grid_point(uint d, uvec2 pt) {
    uvec4 s = def_static[d];
    uint row = (s.w & 0xffffu) + 1u;
    return grid[s.z + row * pt.y + pt.x];
}

uvec2 grid_size(uint d) {
    uint w = def_static[d].w;
    return uvec2(w & 0xffffu, w >> 16);
}

// the grid's "average" affine transform, input (0.5, 0.5) at its center
vec2 warp_affine(uint d, vec2 q) {
    uvec2 size = grid_size(d);
    vec2 p00 = grid_point(d, uvec2(0u));
    vec2 p01 = grid_point(d, uvec2(size.x, 0u));
    vec2 p10 = grid_point(d, uvec2(0u, size.y));
    vec2 p11 = grid_point(d, size);
    vec2 pc = (p00 + p01 + p10 + p11) / 4.0;
    vec2 dx = (p01 - p00 + p11 - p10) / 2.0;
    vec2 dy = (p10 - p00 + p11 - p01) / 2.0;
    q -= 0.5;
    return dx * q.x + dy * q.y + pc;
}

vec2 extrap_point(uint d, uvec2 pt) {
    uvec2 size = grid_size(d);
    bvec2 low = lessThan(pt, uvec2(1u));
    bvec2 high = greaterThan(pt, size + 1u);
    if (!any(low) && !any(high)) {
        return grid_point(d, pt - 1u);
    }
    vec2 inner = (vec2(pt) - 1.0) / vec2(size);
    vec2 pi = mix(mix(inner, vec2(3.0), high), vec2(-2.0), low);
    return warp_affine(d, pi);
}

vec2 tri(vec2 fpos, vec2 p00, vec2 p01, vec2 p10, vec2 p11) {
    if ((fpos.x + fpos.y) < 1.0) {
        return (1.0 - (fpos.x + fpos.y)) * p00 + fpos.x * p01 + fpos.y * p10;
    }
    vec2 f = vec2(1.0) - fpos;
    return (1.0 - (f.x + f.y)) * p11 + f.x * p10 + f.y * p01;
}

vec2 lerp2(vec2 a, vec2 b, float t) {
    return a * (1.0 - t) + b * t;
}

vec2 warp_apply(uint d, vec2 c) {
    uvec2 size = grid_size(d);
    vec2 fsize = vec2(size);
    float lo = min(c.x, c.y), hi = max(c.x, c.y);
    if (lo < 0.0 || hi > 1.0) {
        if (lo <= -2.0 || hi >= 3.0) {
            return warp_affine(d, c);
        }
        vec2 rpos = mix(mix(c * fsize, (c - 1.0) / 2.0 + fsize, greaterThan(c, vec2(1.0))), c / 2.0, lessThan(c, vec2(0.0))) + 1.0;
        uvec2 ipos = min(uvec2(max(rpos, vec2(0.0))), size + 1u);
        vec2 fpos = rpos - vec2(ipos);
        return tri(fpos, extrap_point(d, ipos), extrap_point(d, ipos + uvec2(1u, 0u)),
                   extrap_point(d, ipos + uvec2(0u, 1u)), extrap_point(d, ipos + uvec2(1u)));
    }
    vec2 rpos = c * fsize;
    uvec2 ipos = min(uvec2(rpos), size - 1u);
    vec2 fpos = rpos - vec2(ipos);
    vec2 p00 = grid_point(d, ipos);
    vec2 p01 = grid_point(d, ipos + uvec2(1u, 0u));
    vec2 p10 = grid_point(d, ipos + uvec2(0u, 1u));
    vec2 p11 = grid_point(d, ipos + uvec2(1u));
    if (((def_static[d].x >> 4) & 1u) != 0u) {
        return lerp2(lerp2(p00, p01, fpos.x), lerp2(p10, p11, fpos.x), fpos.y);
    }
    return tri(fpos, p00, p01, p10, p11);
}

vec2 rot_apply(uint d, vec2 p) {
    RotOut r = rot[d];
    return vec2(r.m.x * p.x + r.m.z * p.y, r.m.y * p.x + r.m.w * p.y) + r.t.xy;
}

vec2 deform(uint d, vec2 p) {
    uint kind = def_static[d].x & 15u;
    if (kind == 1u) {
        return warp_apply(d, p);
    }
    if (kind == 2u) {
        return rot_apply(d, p);
    }
    return p;
}

void deformer_item(uint i) {
    uvec2 it = items[i];
    uint d = it.x;
    DefDyn dd = def_dyn[d];
    if (dd.valid == 0u) {
        return;
    }
    uvec4 s = def_static[d];
    uint parent = s.y;
    if ((s.x & 15u) == 1u) {
        vec2 p = vec2(0.0);
        for (uint k = dd.start; k < dd.start + dd.count; k++) {
            p += warp_forms[weights[k].x + it.y] * uintBitsToFloat(weights[k].y);
        }
        if (parent > 0u) {
            p = deform(parent - 1u, p);
        }
        grid[s.z + it.y] = p;
        return;
    }
    // rotation: local transform, then the parent's
    vec4 m = dd.m;
    vec2 t = dd.t.xy;
    if (parent > 0u) {
        uint pd = parent - 1u;
        if ((def_static[pd].x & 15u) == 2u) {
            RotOut r = rot[pd];
            vec4 pm = r.m;
            m = vec4(pm.x * m.x + pm.z * m.y, pm.y * m.x + pm.w * m.y, pm.x * m.z + pm.z * m.w, pm.y * m.z + pm.w * m.w);
            t = vec2(pm.x * t.x + pm.z * t.y, pm.y * t.x + pm.w * t.y) + r.t.xy;
        } else {
            vec2 p0 = warp_apply(pd, t);
            vec2 p1 = warp_apply(pd, t + vec2(0.0, -0.1));
            float angle = 0.0;
            if (p1 != p0) {
                vec2 v = p1 - p0;
                angle = atan(v.x, -v.y);
            }
            float sc = dd.parent_warp_scale;
            vec4 a = vec4(cos(angle) * sc, sin(angle) * sc, -sin(angle) * sc, cos(angle) * sc);
            m = vec4(a.x * m.x + a.z * m.y, a.y * m.x + a.w * m.y, a.x * m.z + a.z * m.w, a.y * m.z + a.w * m.w);
            t = p0;
        }
    }
    rot[d].m = m;
    rot[d].t = vec4(t, 0.0, 0.0);
}

void mesh_vertex(uint v) {
    uint m = vert_mesh[v];
    uvec2 md = mesh_dyn[m];
    if (md.y == 0u) {
        return;
    }
    uvec4 ms = mesh_static[m];
    uint local_index = v - ms.x;
    vec2 p = vec2(0.0);
    for (uint k = md.x; k < md.x + md.y; k++) {
        p += art_forms[weights[k].x + local_index] * uintBitsToFloat(weights[k].y);
    }
    if (ms.y > 0u) {
        p = deform(ms.y - 1u, p);
    }
    pos[v] = p * pc.px;
}

void glue_pair(uint i) {
    GluePair g = glue_pairs[i];
    float c = compat[g.glue];
    if (isnan(c) || mesh_dyn[g.ma].y == 0u || mesh_dyn[g.mb].y == 0u) {
        return;
    }
    vec2 v1 = pos[g.va];
    vec2 v2 = pos[g.vb];
    vec2 vg1 = lerp2(v1, v2, g.wa);
    vec2 vg2 = lerp2(v2, v1, g.wb);
    pos[g.va] = lerp2(v1, vg1, c);
    pos[g.vb] = lerp2(v2, vg2, c);
}

void mask_box(uint set, uint lane) {
    vec4 b = vec4(1e30, 1e30, -1e30, -1e30);
    uvec2 range = mask_sets[set];
    for (uint k = range.x; k < range.x + range.y; k++) {
        uint m = mask_items[k];
        if (mesh_dyn[m].y == 0u) {
            continue;
        }
        uvec4 ms = mesh_static[m];
        for (uint v = ms.x + lane; v < ms.x + ms.z; v += 64u) {
            b.xy = min(b.xy, pos[v]);
            b.zw = max(b.zw, pos[v]);
        }
    }
    red[lane] = b;
    barrier();
    for (uint s = 32u; s > 0u; s >>= 1) {
        if (lane < s) {
            red[lane].xy = min(red[lane].xy, red[lane + s].xy);
            red[lane].zw = max(red[lane].zw, red[lane + s].zw);
        }
        barrier();
    }
    if (lane == 0u) {
        boxes[set] = red[0] + vec4(-MARGIN, -MARGIN, MARGIN, MARGIN);
    }
}

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (pc.mode == 3u) {
        mask_box(pc.start + gl_WorkGroupID.x, gl_LocalInvocationID.x);
        return;
    }
    if (i >= pc.count) {
        return;
    }
    if (pc.mode == 0u) {
        deformer_item(pc.start + i);
    } else if (pc.mode == 1u) {
        mesh_vertex(pc.start + i);
    } else {
        glue_pair(pc.start + i);
    }
}
"#;

const PUSH_SIZE: usize = 16;

/// One art mesh as the renderer lays out its vertices
pub struct MeshLayout {
    pub uid: u32,
    pub vertex_offset: usize,
    pub vertex_count: usize,
}

pub struct GpuDeform {
    rd: Gd<RenderingDevice>,
    rids: Vec<Rid>,
    pipeline: Rid,
    set: Rid,
    def_dyn: Rid,
    weights: Rid,
    mesh_dyn: Rid,
    glue_compat: Rid,
    pub boxes: Rid,
    /// deformer index -> uid, and (start, count) of each tree level in the item list
    deformers: Vec<u32>,
    levels: Vec<(u32, u32)>,
    art_offset: HashMap<u64, u32>,
    warp_offset: HashMap<u64, u32>,
    meshes: Vec<u32>,
    vertices: u32,
    glue_batches: Vec<(u32, u32)>,
    glue_count: usize,
    mask_count: u32,
    def_bytes: PackedByteArray,
    mesh_bytes: PackedByteArray,
    weight_bytes: PackedByteArray,
    glue_bytes: PackedByteArray,
    push: PackedByteArray,
}

fn bytes_u32(v: &[u32]) -> PackedByteArray {
    let v = if v.is_empty() { &[0u32; 4][..] } else { v };
    PackedByteArray::from(v.iter().flat_map(|x| x.to_le_bytes()).collect::<Vec<u8>>())
}

fn bytes_f32(v: &[f32]) -> PackedByteArray {
    let v = if v.is_empty() { &[0f32; 4][..] } else { v };
    PackedByteArray::from(v.iter().flat_map(|x| x.to_le_bytes()).collect::<Vec<u8>>())
}

fn put(bytes: &mut [u8], at: usize, v: u32) {
    bytes[at * 4..at * 4 + 4].copy_from_slice(&v.to_le_bytes());
}

impl GpuDeform {
    /// positions: the renderer's vertex buffer (created with AS_STORAGE_BIT); masks: per mask, the indices
    /// (into meshes) of the meshes it is drawn from
    pub fn new(
        rd: &mut Gd<RenderingDevice>,
        model: &ParsedModel,
        meshes: &[MeshLayout],
        positions: Rid,
        masks: &[Vec<usize>],
    ) -> Result<Self, String> {
        let mut rids = vec![];
        let mut storage = |rd: &mut Gd<RenderingDevice>, data: &PackedByteArray| {
            let rid = rd.storage_buffer_create_ex(data.len() as u32).data(data).done();
            rids.push(rid);
            rid
        };

        // every form's vertices, art meshes and warp deformers apart (their uids are separate)
        let mut art: Vec<f32> = vec![];
        let mut art_offset = HashMap::new();
        for a in model.artmeshes() {
            let mut add = |uid: u64, verts: &[katashiro_core::core::Coord]| {
                art_offset.entry(uid).or_insert_with(|| {
                    let at = (art.len() / 2) as u32;
                    art.extend(verts.iter().flat_map(|v| [v.x, v.y]));
                    at
                });
            };
            let forms = a.forms();
            for i in 0..forms.count() {
                let f = forms.index(i).unwrap();
                add(f.uid().into(), f.vertices());
            }
            for bfm in a.blend_form_maps().into_iter().flatten() {
                let forms = bfm.forms();
                for i in 0..forms.count() {
                    let f = forms.index(i).unwrap();
                    add(f.uid().into(), f.vertices());
                }
            }
        }
        let mut warp: Vec<f32> = vec![];
        let mut warp_offset = HashMap::new();
        let mut deformers = vec![];
        let mut index_of: HashMap<u32, usize> = HashMap::new();
        for d in model.deformers() {
            index_of.insert(d.uid(), deformers.len());
            deformers.push(d.uid());
        }
        // static deformer table and items by tree level
        let mut def_static = vec![0u32; deformers.len() * 4];
        let mut grid_len = 0u32;
        let mut level_of = vec![usize::MAX; deformers.len()];
        fn level(model: &ParsedModel, uid: u32, index_of: &HashMap<u32, usize>, level_of: &mut Vec<usize>) -> usize {
            let i = index_of[&uid];
            if level_of[i] != usize::MAX {
                return level_of[i];
            }
            let d = model.deformers().get(uid).unwrap();
            let l = match d.parent() {
                Some(p) => level(model, p.uid(), index_of, level_of) + 1,
                None => 0,
            };
            level_of[i] = l;
            l
        }
        let mut by_level: Vec<Vec<(u32, u32)>> = vec![];
        for (i, &uid) in deformers.iter().enumerate() {
            let d = model.deformers().get(uid).unwrap();
            let l = level(model, uid, &index_of, &mut level_of);
            if by_level.len() <= l {
                by_level.resize_with(l + 1, Vec::new);
            }
            let parent = d.parent().map(|p| index_of[&p.uid()] as u32 + 1).unwrap_or(0);
            match Deformer::typed(&*d) {
                TypedDeformer::Warp(w) => {
                    let size = w.size();
                    let points = (size.x + 1) * (size.y + 1);
                    def_static[i * 4] = 1 | ((w.bilinear_interpolation() as u32) << 4);
                    def_static[i * 4 + 1] = parent;
                    def_static[i * 4 + 2] = grid_len;
                    def_static[i * 4 + 3] = size.x | (size.y << 16);
                    grid_len += points;
                    for j in 0..points {
                        by_level[l].push((i as u32, j));
                    }
                    let mut add = |uid: u64, verts: &[katashiro_core::core::Coord]| {
                        warp_offset.entry(uid).or_insert_with(|| {
                            let at = (warp.len() / 2) as u32;
                            warp.extend(verts.iter().flat_map(|v| [v.x, v.y]));
                            at
                        });
                    };
                    let forms = w.forms();
                    for k in 0..forms.count() {
                        let f = forms.index(k).unwrap();
                        add(f.uid().into(), f.vertices());
                    }
                    for bfm in w.blend_form_maps().into_iter().flatten() {
                        let forms = bfm.forms();
                        for k in 0..forms.count() {
                            let f = forms.index(k).unwrap();
                            add(f.uid().into(), f.vertices());
                        }
                    }
                }
                TypedDeformer::Rotation(_) => {
                    def_static[i * 4] = 2;
                    def_static[i * 4 + 1] = parent;
                    by_level[l].push((i as u32, 0));
                }
            }
        }
        let mut items: Vec<u32> = vec![];
        let mut levels = vec![];
        for l in &by_level {
            levels.push(((items.len() / 2) as u32, l.len() as u32));
            items.extend(l.iter().flat_map(|&(d, j)| [d, j]));
        }

        // meshes: vertex -> mesh, mesh -> (first vertex, deformer + 1, count)
        let mut vert_mesh = vec![];
        let mut mesh_static = vec![0u32; meshes.len() * 4];
        let mut mesh_index: HashMap<u32, usize> = HashMap::new();
        for (m, l) in meshes.iter().enumerate() {
            mesh_index.insert(l.uid, m);
            vert_mesh.extend(std::iter::repeat_n(m as u32, l.vertex_count));
            let a = model.artmeshes().get(l.uid).unwrap();
            mesh_static[m * 4] = l.vertex_offset as u32;
            mesh_static[m * 4 + 1] = a.deformer().map(|d| index_of[&d.uid()] as u32 + 1).unwrap_or(0);
            mesh_static[m * 4 + 2] = l.vertex_count as u32;
        }
        let vertices = vert_mesh.len() as u32;

        // glue pairs, batched so that no two glues in a batch share a mesh, in model order where they do
        let mut batch_of_mesh: HashMap<usize, usize> = HashMap::new();
        let mut batches: Vec<Vec<[u32; 8]>> = vec![];
        let mut glue_count = 0;
        for (gi, g) in model.glues().into_iter().enumerate() {
            glue_count = gi + 1;
            let (ma, mb) = (mesh_index[&g.artmesh_1().uid()], mesh_index[&g.artmesh_2().uid()]);
            let b = batch_of_mesh.get(&ma).map(|b| b + 1).unwrap_or(0).max(batch_of_mesh.get(&mb).map(|b| b + 1).unwrap_or(0));
            batch_of_mesh.insert(ma, b);
            batch_of_mesh.insert(mb, b);
            if batches.len() <= b {
                batches.resize_with(b + 1, Vec::new);
            }
            for [c1, c2] in g.coords() {
                batches[b].push([
                    meshes[ma].vertex_offset as u32 + c1.vertex_index as u32,
                    meshes[mb].vertex_offset as u32 + c2.vertex_index as u32,
                    c1.weight.to_bits(),
                    c2.weight.to_bits(),
                    gi as u32,
                    ma as u32,
                    mb as u32,
                    0,
                ]);
            }
        }
        let mut glue_pairs: Vec<u32> = vec![];
        let mut glue_batches = vec![];
        for b in &batches {
            glue_batches.push(((glue_pairs.len() / 8) as u32, b.len() as u32));
            glue_pairs.extend(b.iter().flatten());
        }

        let mut mask_sets = vec![];
        let mut mask_items = vec![];
        for set in masks {
            mask_sets.extend([mask_items.len() as u32, set.len() as u32]);
            mask_items.extend(set.iter().map(|&m| m as u32));
        }

        let art_forms = storage(rd, &bytes_f32(&art));
        let warp_forms = storage(rd, &bytes_f32(&warp));
        let grid = storage(rd, &bytes_f32(&vec![0.0; (grid_len as usize * 2).max(4)]));
        let def_static_buf = storage(rd, &bytes_u32(&def_static));
        let def_dyn = storage(rd, &bytes_u32(&vec![0; (deformers.len() * 12).max(4)]));
        let rot = storage(rd, &bytes_f32(&vec![0.0; (deformers.len() * 8).max(4)]));
        // at most every form once per frame
        let weight_slots = (art_offset.len() + warp_offset.len()).max(1);
        let weights = storage(rd, &bytes_u32(&vec![0; weight_slots * 2]));
        let items_buf = storage(rd, &bytes_u32(&items));
        let vert_mesh_buf = storage(rd, &bytes_u32(&vert_mesh));
        let mesh_static_buf = storage(rd, &bytes_u32(&mesh_static));
        let mesh_dyn = storage(rd, &bytes_u32(&vec![0; meshes.len().max(2) * 2]));
        let glues = storage(rd, &bytes_u32(&glue_pairs));
        let glue_compat = storage(rd, &bytes_f32(&vec![f32::NAN; glue_count.max(4)]));
        let mask_sets_buf = storage(rd, &bytes_u32(&mask_sets));
        let mask_items_buf = storage(rd, &bytes_u32(&mask_items));
        let boxes = storage(rd, &bytes_f32(&vec![0.0; masks.len().max(1) * 4]));

        let source = SHADER.replace("MARGIN", &format!("{MASK_MARGIN:.1}"));
        let mut src = RdShaderSource::new_gd();
        src.set_stage_source(ShaderStage::COMPUTE, &source);
        let spirv = rd.shader_compile_spirv_from_source(&src).ok_or("shader compiler unavailable")?;
        let err = spirv.get_stage_compile_error(ShaderStage::COMPUTE);
        if !err.is_empty() {
            return Err(format!("deform shader: {err}"));
        }
        let shader = rd.shader_create_from_spirv(&spirv);
        if !shader.is_valid() {
            return Err("deform shader creation failed".into());
        }
        rids.push(shader);
        let pipeline = rd.compute_pipeline_create(shader);
        let buffers = [
            art_forms, warp_forms, grid, def_static_buf, def_dyn, rot, weights, items_buf, vert_mesh_buf,
            mesh_static_buf, mesh_dyn, positions, glues, glue_compat, mask_sets_buf, mask_items_buf, boxes,
        ];
        let mut uniforms = Array::new();
        for (binding, rid) in buffers.into_iter().enumerate() {
            let mut u = RdUniform::new_gd();
            u.set_uniform_type(UniformType::STORAGE_BUFFER);
            u.set_binding(binding as i32);
            u.add_id(rid);
            uniforms.push(&u);
        }
        let set = rd.uniform_set_create(&uniforms, shader, 0);
        if !set.is_valid() {
            return Err("deform uniform set failed".into());
        }

        let mut push = PackedByteArray::new();
        push.resize(PUSH_SIZE);
        let mut def_bytes = PackedByteArray::new();
        def_bytes.resize(deformers.len().max(1) * 48);
        let mut mesh_bytes = PackedByteArray::new();
        mesh_bytes.resize(meshes.len().max(1) * 8);
        let mut weight_bytes = PackedByteArray::new();
        weight_bytes.resize(weight_slots * 8);
        let mut glue_bytes = PackedByteArray::new();
        glue_bytes.resize(glue_count.max(1) * 4);
        Ok(Self {
            rd: rd.clone(),
            rids,
            pipeline,
            set,
            def_dyn,
            weights,
            mesh_dyn,
            glue_compat,
            boxes,
            deformers,
            levels,
            art_offset,
            warp_offset,
            meshes: meshes.iter().map(|m| m.uid).collect(),
            vertices,
            glue_batches,
            glue_count,
            mask_count: masks.len() as u32,
            def_bytes,
            mesh_bytes,
            weight_bytes,
            glue_bytes,
            push,
        })
    }

    fn dispatch(&mut self, list: i64, mode: u32, start: u32, count: u32, px: f32, groups: u32) {
        let p = self.push.as_mut_slice();
        put(p, 0, mode);
        put(p, 1, start);
        put(p, 2, count);
        put(p, 3, px.to_bits());
        self.rd.compute_list_set_push_constant(list, &self.push, PUSH_SIZE as u32);
        self.rd.compute_list_dispatch(list, groups, 1, 1);
        self.rd.compute_list_add_barrier(list);
    }

    /// Uploads this frame's weights and runs the passes; the positions buffer then holds the model in local
    /// pixels (vertex * px_size), the boxes buffer each mask's box
    pub fn run(&mut self, driver: &Driver<ParsedModel>, px_size: f32) {
        let mut slot = 0usize;
        let slots = self.weight_bytes.len() / 8;
        {
            let w = self.weight_bytes.as_mut_slice();
            let d = self.def_bytes.as_mut_slice();
            for (i, &uid) in self.deformers.iter().enumerate() {
                let base = i * 12;
                for k in 0..12 {
                    put(d, base + k, 0);
                }
                match driver.deformer_plan(uid) {
                    DeformerPlan::None => {}
                    DeformerPlan::Warp { forms } => {
                        put(d, base, slot as u32);
                        let start = slot;
                        for &(form, weight) in forms {
                            let (Some(&off), true) = (self.warp_offset.get(&form), slot < slots) else { continue };
                            put(w, slot * 2, off);
                            put(w, slot * 2 + 1, weight.to_bits());
                            slot += 1;
                        }
                        put(d, base + 1, (slot - start) as u32);
                        put(d, base + 2, 1);
                    }
                    DeformerPlan::Rotation { local, parent_warp_scale } => {
                        put(d, base + 2, 1);
                        put(d, base + 3, parent_warp_scale.to_bits());
                        let m = local.matrix2;
                        for (k, v) in [m.x_axis.x, m.x_axis.y, m.y_axis.x, m.y_axis.y, local.translation.x, local.translation.y]
                            .into_iter()
                            .enumerate()
                        {
                            put(d, base + 4 + k, v.to_bits());
                        }
                    }
                }
            }
            let md = self.mesh_bytes.as_mut_slice();
            for (m, &uid) in self.meshes.iter().enumerate() {
                let start = slot;
                if let Some(st) = driver.artmesh_state(uid) {
                    for &(form, weight) in st.forms {
                        let (Some(&off), true) = (self.art_offset.get(&form), slot < slots) else { continue };
                        put(w, slot * 2, off);
                        put(w, slot * 2 + 1, weight.to_bits());
                        slot += 1;
                    }
                }
                put(md, m * 2, start as u32);
                put(md, m * 2 + 1, (slot - start) as u32);
            }
            let g = self.glue_bytes.as_mut_slice();
            let compat = driver.glue_compatibility();
            for i in 0..self.glue_count {
                put(g, i, compat.get(i).copied().unwrap_or(f32::NAN).to_bits());
            }
        }
        let rd = &mut self.rd;
        rd.buffer_update(self.weights, 0, (slot.max(1) * 8) as u32, &self.weight_bytes);
        rd.buffer_update(self.def_dyn, 0, self.def_bytes.len() as u32, &self.def_bytes);
        rd.buffer_update(self.mesh_dyn, 0, self.mesh_bytes.len() as u32, &self.mesh_bytes);
        rd.buffer_update(self.glue_compat, 0, self.glue_bytes.len() as u32, &self.glue_bytes);

        let list = self.rd.compute_list_begin();
        self.rd.compute_list_bind_compute_pipeline(list, self.pipeline);
        self.rd.compute_list_bind_uniform_set(list, self.set, 0);
        for (start, count) in self.levels.clone() {
            if count > 0 {
                self.dispatch(list, 0, start, count, px_size, count.div_ceil(64));
            }
        }
        let v = self.vertices;
        self.dispatch(list, 1, 0, v, px_size, v.div_ceil(64).max(1));
        for (start, count) in self.glue_batches.clone() {
            self.dispatch(list, 2, start, count, px_size, count.div_ceil(64).max(1));
        }
        if self.mask_count > 0 {
            let n = self.mask_count;
            self.dispatch(list, 3, 0, n, px_size, n);
        }
        self.rd.compute_list_end();
    }
}

impl Drop for GpuDeform {
    fn drop(&mut self) {
        for rid in self.rids.drain(..).rev() {
            if rid.is_valid() {
                self.rd.free_rid(rid);
            }
        }
    }
}
