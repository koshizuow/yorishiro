use godot::classes::{Engine, ResourceLoader};
use godot::prelude::*;

use crate::physics::*;

pub mod expression;
pub mod importer;
pub mod loader;
pub mod model;
pub mod motion;
pub mod mutator;
pub mod physics;
pub mod plugin;

struct KatashiroExtension;

#[derive(GodotClass)]
#[class(base=Object, tool)]
struct KatashiroSingletons {
    base: Base<Object>,

    physics_loader: Gd<KatashiroPhysicsLoader>,
}

#[godot_api]
impl IObject for KatashiroSingletons {
    fn init(base: Base<Object>) -> Self {
        let physics_loader = KatashiroPhysicsLoader::new_gd();

        ResourceLoader::singleton().add_resource_format_loader(&physics_loader);

        Self {
            base,
            physics_loader,
        }
    }
}

// Unregister the loader and saver when the extension is unloaded.
impl Drop for KatashiroSingletons {
    fn drop(&mut self) {
        ResourceLoader::singleton().remove_resource_format_loader(&self.physics_loader);
    }
}

#[gdextension]
unsafe impl ExtensionLibrary for KatashiroExtension {
    fn on_stage_init(stage: InitStage) {
        match stage {
            InitStage::Scene => {
                Engine::singleton().register_singleton(
                    &KatashiroSingletons::class_id().to_string_name(),
                    &KatashiroSingletons::new_alloc(),
                );
            }
            _ => {}
        }
    }

    fn on_stage_deinit(stage: InitStage) {
        match stage {
            InitStage::Scene => {
                let mut engine = Engine::singleton();
                let singleton_name = &KatashiroSingletons::class_id().to_string_name();
                let my_singleton = engine.get_singleton(singleton_name).unwrap();
                engine.unregister_singleton(singleton_name);
                my_singleton.free();
            }
            _ => {}
        }
    }
}
