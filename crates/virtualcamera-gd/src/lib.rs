use godot::prelude::*;

mod yuyv;
pub mod camera;

struct VirtualCamExtension;

#[gdextension]
unsafe impl ExtensionLibrary for VirtualCamExtension {

}

