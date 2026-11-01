use godot::classes::{EditorPlugin, IEditorPlugin};
use godot::prelude::*;

use crate::importer::*;

#[derive(GodotClass)]
#[class(tool, init, base=EditorPlugin)]
struct KatashiroPlugin {
    base: Base<EditorPlugin>,
    model_importer: Gd<KatashiroImporter>,
    motion_importer: Gd<KatashiroMotionImporter>,
    expression_importer: Gd<KatashiroExpressionImporter>,
}

#[godot_api]
impl IEditorPlugin for KatashiroPlugin {
    fn enter_tree(&mut self) {
        {
            let plugin: Gd<KatashiroImporter> = KatashiroImporter::new_gd();
            self.model_importer = plugin.clone();
            self.base_mut().add_import_plugin(&plugin);
        }

        {
            let plugin: Gd<KatashiroMotionImporter> = KatashiroMotionImporter::new_gd();
            self.motion_importer = plugin.clone();
            self.base_mut().add_import_plugin(&plugin);
        }

        {
            let plugin: Gd<KatashiroExpressionImporter> = KatashiroExpressionImporter::new_gd();
            self.expression_importer = plugin.clone();
            self.base_mut().add_import_plugin(&plugin);
        }
    }

    fn exit_tree(&mut self) {
        {
            let plugin = self.model_importer.clone();
            self.base_mut().remove_import_plugin(&plugin);
        }

        {
            let plugin = self.motion_importer.clone();
            self.base_mut().remove_import_plugin(&plugin);
        }

        {
            let plugin = self.expression_importer.clone();
            self.base_mut().remove_import_plugin(&plugin);
        }
    }
}
