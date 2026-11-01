// stats MODEL.moc3...: art meshes, masks (distinct clip sets, as Katashiro makes one mask viewport per set),
// blend modes in use, offscreen parts (Cubism 5.3)
use std::collections::{BTreeMap, BTreeSet};
use std::{env, fs::File};
use katashiro_core::core::{ArtMesh, ItemArray, Model, Part};
use katashiro_core::file;

fn main() {
    for path in env::args().skip(1) {
        let model = file::ParsedModel::load(&mut File::open(&path).unwrap()).unwrap();
        let meshes = model.artmeshes();
        let mut masks: BTreeSet<Vec<String>> = BTreeSet::new();
        let (mut masked, mut inverted, mut mask_meshes) = (0, 0, BTreeSet::new());
        let mut blends: BTreeMap<String, u32> = BTreeMap::new();
        for i in 0..meshes.count() {
            let a = meshes.index(i).unwrap();
            let clips: Vec<String> = a.clips().into_iter().map(|c| c.id().to_string()).collect();
            if !clips.is_empty() {
                masked += 1;
                inverted += a.invert_mask() as u32;
                mask_meshes.extend(clips.iter().cloned());
                masks.insert(clips);
            }
            *blends.entry(format!("{:?}/{:?}", a.blend_config().color, a.blend_config().alpha)).or_default() += 1;
        }
        let parts = model.parts();
        let offscreen = (0..parts.count()).filter(|&i| parts.index(i).unwrap().offscreen()).count();
        println!("{path}\n  meshes {}, masked {masked} ({inverted} inverted), mask sets {}, meshes drawn into masks {}, offscreen parts {offscreen}\n  blends {blends:?}",
            meshes.count(), masks.len(), mask_meshes.len());
    }
}
