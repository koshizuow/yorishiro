use std::collections::HashMap;

use katashiro_core::pose::Pose;
use fastxfix::CommonStr;
use glob::glob;
use godot::classes::animation::{LoopMode, TrackType};
use godot::classes::mesh::PrimitiveType;
use godot::classes::{
    Animation, AnimationLibrary, ArrayMesh, FileAccess, Image, ImageTexture, Json, MeshInstance2D,
    ProjectSettings, ResourceLoader, Texture2D,
    mesh,
};
use godot::prelude::*;

use katashiro_core::core::{ArtMesh, Collection, Item, Model};
use katashiro_core::driver::DrawNode;

use crate::expression::{KatashiroExpression, KatashiroExpressionMutator, KatashiroExpressionTrack};
use crate::importer::EXPRESSION_EXTENSION;
use crate::model::{KatashiroModel, PARAMETER_PREFIX, PART_PREFIX};
use crate::motion::KatashiroMotionMutator;
use crate::physics::KatashiroPhysicsMutator;

#[derive(GodotClass)]
#[class(tool, init, singleton)]
pub struct KatashiroLoader;

#[godot_api]
impl KatashiroLoader {
    #[func]
    pub fn load_model(&self, file_path: GString) -> Gd<KatashiroModel> {
        let settings: katashiro_core::meta::Model3 = {
            let json = FileAccess::get_file_as_string(&file_path);
            serde_json::from_str(&json.to_string()).expect("unable to parse model3 json")
        };
        let base_path = file_path.get_base_dir();

        let mut scene = KatashiroModel::new_alloc();
        scene.set_scene_file_path(&file_path);

        // build materials for each texture
        let textures: Vec<Gd<Texture2D>> = settings
            .file_references
            .textures
            .iter()
            .map(|t_path| {
                let real_path = &base_path.path_join(t_path);
                let mut tex: Gd<Texture2D>;
                if ResourceLoader::singleton().exists(real_path) {
                    tex = ResourceLoader::singleton().load(real_path).unwrap().cast();
                } else {
                    let mut img = Image::load_from_file(real_path);
                    img.as_mut().unwrap().generate_mipmaps();
                    let img_tex = ImageTexture::create_from_image(img.as_ref()).unwrap();
                    tex = img_tex.upcast();
                    tex.take_over_path(real_path);
                }

                tex
            })
            .collect();

        let mut meshes = HashMap::new();
        let mut mesh_group = Node2D::new_alloc();
        mesh_group.set_name("Meshes");
        // the art mesh nodes name the meshes and keep their triangles (pinning); Katashiro draws the model
        // through RenderingDevice (rd_renderer.rs), so they never draw
        mesh_group.set_visible(false);
        scene.add_child(&mesh_group);
        mesh_group.set_owner(&scene);

        let mut expression_controller = KatashiroExpressionMutator::new_alloc();
        expression_controller.set_name("ExpressionController");
        scene.add_child(&expression_controller);
        expression_controller.set_owner(&scene);

        let mut m_scene = scene.bind_mut();
        m_scene.load();

        let md = m_scene.model.as_mut().unwrap();
        let m = md.model.as_ref();
        let pose = Pose::new(m);

        // update art meshes to their initial states
        md.driver.apply_pose(&pose);
        md.driver.drive(m);

        let px_size = m.canvas_properties().scale;
        let canvas_size = m.canvas_properties().dimensions;
        let origin = m.canvas_properties().center;

        // make all the art meshes
        for node in md.driver.draw_nodes(None).unwrap().into_iter() {
            let DrawNode::ArtMesh(uid) = node else {
                continue;
            };

            let artmesh = md.model.artmeshes().get(*uid).unwrap();
            // TODO get mesh state when parameters are at defaults
            // let raw_mesh = md.driver.artmesh_state(artmesh.uid());
            let mut mesh = ArrayMesh::new_gd();
            let id = artmesh.id().to_string_name();
            let uid = artmesh.uid().clone();
            mesh.set_local_to_scene(true);

            let vtx_count = artmesh.vertex_count();
            let am = md.driver.artmesh_state(uid).unwrap();

            let mut mesh_instance = MeshInstance2D::new_alloc();
            mesh_instance.set_name(&id);
            mesh_instance.set_mesh(&mesh);
            mesh_instance.set_meta("uid", &uid.to_variant());
            mesh_instance.set_self_modulate(Color {
                r: 1.0,
                g: 1.0,
                b: 1.0,
                a: am.visual.opacity,
            });

            let tex_id = artmesh.texture() as usize;
            let tex = textures.get(tex_id).unwrap();
            mesh_instance.set_texture(tex);

            mesh_group.add_child(&mesh_instance);
            meshes.insert(artmesh.uid(), mesh_instance);

            // must have enough vertices to create a tri
            if vtx_count < 3 {
                continue;
            }
            // some models ship art meshes with vertices but no triangles (Hiyori has one), and Godot
            // rejects an empty index array with four errors per mesh. Nothing to draw, so skip it.
            if artmesh.indices_slice().is_empty() {
                continue;
            }

            let mut ary = VarArray::new();
            ary.resize(mesh::ArrayType::MAX.ord() as usize, &Variant::nil());

            // vertices
            {
                let mut vary = PackedVector2Array::new();
                vary.resize(vtx_count as usize);

                for (i, vtx) in am.vertices.iter().enumerate() {
                    vary[i] = Vector2 {
                        x: vtx.x * px_size,
                        y: vtx.y * px_size,
                    };
                }
                ary.set(mesh::ArrayType::VERTEX.ord() as usize, &vary);
            }

            // texture UVs
            {
                let texcoords = md.model.texcoord_buffer().unwrap();
                let offset = artmesh.texcoord_offset();
                let mut vary = PackedVector2Array::new();
                vary.resize(vtx_count as usize);

                for i in 0..vtx_count {
                    let uv = texcoords[(offset + i) as usize];
                    vary[i as usize] = Vector2 { x: uv.x, y: uv.y };
                }

                ary.set(mesh::ArrayType::TEX_UV.ord() as usize, &vary);
            }

            // indices
            {
                let vary =
                    PackedInt32Array::from_iter(artmesh.indices_slice().iter().map(|i| *i as i32));

                ary.set(mesh::ArrayType::INDEX.ord() as usize, &vary);
            }

            mesh.add_surface_from_arrays(PrimitiveType::TRIANGLES, &ary);

            let aabb = mesh.get_aabb();
            mesh.set_custom_aabb(aabb);
        }

        drop(m_scene);

        // make sure all nodes are persisted within the scene
        for child in meshes.values_mut() {
            child.set_owner(&scene);
        }

        scene.bind_mut().set_size(Vector2i {
            x: canvas_size.x as i32,
            y: canvas_size.y as i32,
        });
        scene.bind_mut().set_origin(Vector2 {
            x: origin.x,
            y: origin.y,
        });

        // setup animation player
        {
            let mut motion_controller = KatashiroMotionMutator::new_alloc();
            motion_controller.set_name("MotionController");
            motion_controller.set_root(&".".to_node_path());
            scene.add_child(&motion_controller);
            motion_controller.set_owner(&scene);

            let mut animation_library = AnimationLibrary::new_gd();
            let reset = self.create_reset_motion(&scene);
            animation_library.add_animation("RESET", &reset);
            motion_controller.add_animation_library("", &animation_library);
        }

        // setup physics
        {
            let mut mutator = KatashiroPhysicsMutator::new_alloc();
            mutator.set_name("PhysicsController");

            scene.add_child(&mutator);
            mutator.set_owner(&scene);
            if let Some(physics_file) = settings.file_references.physics {
                let physics_filepath = base_path.path_join(&physics_file.to_gstring());
                mutator.bind_mut().set_definition(physics_filepath);
            }
        }

        scene
    }

    #[func]
    pub fn load_motion(&self, file_path: GString) -> Option<Gd<Animation>> {
        let json = FileAccess::get_file_as_string(&file_path);
        let motion: VarDictionary = Json::parse_string(&json).to();

        let meta = motion.at("Meta").to::<VarDictionary>();
        let mut anim = Animation::new_gd();

        let loop_mode = if meta.get("Loop").map_or(false, |v| v.to()) {
            LoopMode::LINEAR
        } else {
            LoopMode::NONE
        };
        anim.set_loop_mode(loop_mode);

        let fps: f32 = meta.get("FPS").map_or(60.0, |v| v.to());
        anim.set_step(1.0 / fps);

        let mut last_frame: f64 = 0.0;

        // parse motion curves
        let curves: VarArray = motion.at("Curves").to();
        for curve in curves.iter_shared().map(|v| v.to::<VarDictionary>()) {
            let property: GString = curve.at("Id").to();
            let segments: VarArray = curve.at("Segments").to();

            if segments.len() < 2 {
                godot_error!("Invalid Segment, must have at least one point");
                return None;
            }

            let track = anim.add_track(TrackType::BEZIER);

            let target_type = match curve.at("Target").to_string().as_str() {
                "Parameter" => "parameters",
                "PartOpacity" => "parts",
                _ => "",
            };

            anim.track_set_path(
                track,
                &format![".:{}/{}", target_type, property].to_node_path(),
            );
            anim.track_set_interpolation_loop_wrap(track, false);

            // first key is always the starting time and value
            anim.bezier_track_insert_key(track, segments.at(0).to(), segments.at(1).to());

            let mut last_key = anim.track_get_key_count(track) - 1;
            let mut s_idx = 2;
            loop {
                let seg_type: i32 = segments.at(s_idx).to::<f32>() as i32;

                match seg_type {
                    // LINEAR
                    0 => {
                        let p0_t: f64 = segments.at(s_idx - 2).to();
                        let p0_v: f32 = segments.at(s_idx - 1).to();
                        let p1_t: f64 = segments.at(s_idx + 1).to();
                        let p1_v: f32 = segments.at(s_idx + 2).to();

                        // tangents
                        let out_t = Vector2 {
                            x: (p1_t - p0_t) as f32,
                            y: p1_v - p0_v,
                        };
                        let in_t = out_t * Vector2 { x: -1.0, y: 1.0 };

                        anim.bezier_track_set_key_out_handle(track, last_key, out_t);

                        last_key = anim.bezier_track_insert_key(track, p1_t, p1_v);
                        anim.bezier_track_set_key_in_handle(track, last_key, in_t);

                        s_idx += 3;
                    }
                    // CUBIC BEZIER
                    1 => {
                        let p0_t: f64 = segments.at(s_idx - 2).to();
                        let p0_v: f32 = segments.at(s_idx - 1).to();
                        let _p1_t: f64 = segments.at(s_idx + 1).to();
                        let p1_v: f32 = segments.at(s_idx + 2).to();
                        let _p2_t: f64 = segments.at(s_idx + 3).to();
                        let p2_v: f32 = segments.at(s_idx + 4).to();
                        let p3_t: f64 = segments.at(s_idx + 5).to();
                        let p3_v: f32 = segments.at(s_idx + 6).to();

                        let tangent_len: f32 = (p0_t - p3_t).abs() as f32 * 0.33333;
                        let out_t = Vector2 {
                            x: tangent_len,
                            y: p1_v - p0_v,
                        };
                        let in_t = Vector2 {
                            x: -tangent_len,
                            y: p3_v - p2_v,
                        };

                        anim.bezier_track_set_key_out_handle(track, last_key, out_t);

                        last_key = anim.bezier_track_insert_key(track, p3_t, p3_v);

                        anim.bezier_track_set_key_in_handle(track, last_key, in_t);

                        s_idx += 7;
                    }
                    // Stepped
                    2 => {
                        let p1_t: f64 = segments.at(s_idx + 1).to();
                        let p1_v: f32 = segments.at(s_idx + 2).to();

                        last_key = anim.bezier_track_insert_key(track, p1_t, p1_v);
                        anim.bezier_track_set_key_in_handle(
                            track,
                            last_key,
                            Vector2 {
                                x: 0.0,
                                y: f32::MAX,
                            },
                        );

                        s_idx += 3;
                    }
                    // Inverse Stepped
                    3 => {
                        let p0_t: f64 = segments.at(s_idx - 2).to();
                        let p0_v: f32 = segments.at(s_idx - 1).to();
                        let p1_t: f64 = segments.at(s_idx + 1).to();
                        let p1_v: f32 = segments.at(s_idx + 2).to();

                        let out_t = Vector2 {
                            x: (p1_t - p0_t) as f32,
                            y: p1_v - p0_v,
                        };

                        anim.bezier_track_set_key_out_handle(track, last_key, out_t);

                        last_key = anim.bezier_track_insert_key(track, p0_t + 0.01, p1_v);
                        anim.bezier_track_set_key_in_handle(track, last_key, out_t);

                        last_key = anim.bezier_track_insert_key(track, p1_t, p1_v);

                        s_idx += 3;
                    }
                    _ => {
                        godot_error!("Invalid Motion Segment Type");
                        return None;
                    }
                }

                last_frame = last_frame
                    .max(anim.track_get_key_time(track, anim.track_get_key_count(track) - 1));

                if s_idx >= segments.len() {
                    break;
                }
            }
        }

        let duration: f64 = meta.get("Duration").map_or(1.0, |v| v.to());

        anim.set_length(duration.max(last_frame) as f32);
        anim.take_over_path(&file_path);  // a reload while the old one is cached must not fail

        Some(anim)
    }

    #[func]
    pub fn load_motion_library(&self, model: Gd<KatashiroModel>) -> Gd<AnimationLibrary> {
        let base_path: GString = ProjectSettings::singleton()
            .globalize_path(&model.bind().base().get_scene_file_path().get_base_dir());
        let mut animation_library = AnimationLibrary::new_gd();

        for entry in glob(&format!("{}/**/*.motion3.json", base_path.to_string())).unwrap() {
            if let Ok(path) = entry {
                let gpath = path.display().to_string().to_gstring();
                let name = gpath.get_file().to_string_name();
                if let Some(animation) = self.load_motion(gpath) {
                    animation_library.add_animation(&name, &animation);
                }
            }
        }

        let reset = self.create_reset_motion(&model);
        animation_library.add_animation("RESET", &reset);

        return animation_library;
    }

    pub fn create_reset_motion(&self, model: &Gd<KatashiroModel>) -> Gd<Animation> {
        let mut animation = Animation::new_gd();
        animation.set_name("RESET");
        animation.set_length(0.0001);

        for p in model.bind().get_parameters().iter_shared() {
            let name = format!("{}{}", PARAMETER_PREFIX, p).to_string_name();
            let value = model.get(&name);
            let track = animation.add_track(TrackType::VALUE);
            animation.track_set_path(track, &format!(".:{}", name));
            animation.track_insert_key(track, 0.0, &value);
        }

        for p in model.bind().get_parts().iter_shared() {
            let name = format!("{}{}", PART_PREFIX, p).to_string_name();
            let value = model.get(&name.to_string_name());
            let track = animation.add_track(TrackType::VALUE);
            animation.track_set_path(track, &format!(".:{}", name));
            animation.track_insert_key(track, 0.0, &value);
        }

        animation
    }

    #[func]
    pub fn load_expression(&self, file_path: GString) -> Option<Gd<KatashiroExpression>> {
        let json = FileAccess::get_file_as_string(&file_path);
        let data: VarDictionary = Json::parse_string(&json).to();

        let mut expression = KatashiroExpression::new_gd();

        expression.bind_mut().tracks = Array::from_iter(
            data.get("Parameters")
                .map_or(VarArray::default(), |p| p.to::<VarArray>())
                .iter_shared()
                .map(|p| p.to::<VarDictionary>())
                .map(|track_data| {
                    let mut track = KatashiroExpressionTrack::new_gd();
                    track.bind_mut().property_name = format!(
                        "{}{}",
                        PARAMETER_PREFIX,
                        track_data.get("Id").unwrap().stringify()
                    )
                    .to_string_name();
                    track.bind_mut().blend_mode = match track_data
                        .get("Blend")
                        .map_or(GString::default(), |v| v.to())
                        .to_string()
                        .as_str()
                    {
                        "Multiply" => crate::expression::BlendMode::MULTIPLY,
                        // exp3 spells it Overwrite, keep Override for files written by older tools
                        "Overwrite" | "Override" => crate::expression::BlendMode::OVERRIDE,
                        _ => crate::expression::BlendMode::ADD,
                    };
                    track.bind_mut().amount = track_data.get("Value").unwrap().to();

                    track
                }),
        );

        let name = file_path
            .get_file()
            .trim_suffix(EXPRESSION_EXTENSION)
            .left(-1);
        expression.set_name(&name);
        expression.take_over_path(&file_path);

        Some(expression)
    }

    #[func]
    pub fn load_expression_library(
        &self,
        path: GString,
        #[opt(default = false)] group_by_folder: bool,
    ) -> Dictionary<Gd<KatashiroExpression>, StringName> {
        let base_path: GString = ProjectSettings::singleton().globalize_path(&path);

        let expressions: Array<Gd<KatashiroExpression>> = glob(&format!(
            "{}/**/*.{}",
            base_path.to_string(),
            EXPRESSION_EXTENSION
        ))
        .unwrap()
        .filter_map(Result::ok)
        .flat_map(|path| {
            let gpath = path.display().to_string().to_gstring();
            self.load_expression(gpath)
        })
        .collect();

        let mut library = Dictionary::new();

        if group_by_folder {
            let root = Vec::from_iter(expressions.iter_shared().map(|v| v.get_path().to_string()))
                .common_prefix()
                .unwrap_or_default()
                .to_gstring();
            for e in expressions.iter_shared() {
                let resource_path = e.get_path().get_base_dir();
                let mut group = resource_path.trim_prefix(&root);
                if group == resource_path {
                    group = "".to_gstring();
                }
                library.set(&e, &group.to_string_name());
            }
        } else {
            for e in expressions.iter_shared() {
                library.set(&e, &"".to_string_name());
            }
        }

        library
    }
}
