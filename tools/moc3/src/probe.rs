// probe MODEL.moc3 "Param=val,..." ArtMeshA,ArtMeshB : driven visibility, opacity and vertex bbox
use std::{env, fs::File};
use ayagami::core::{ArtMesh, Collection, Item, ItemArray, Model};
use ayagami::driver::{DrawNode, Driver};
use ayagami::file;

fn main() {
    let args: Vec<String> = env::args().collect();
    let model = file::ParsedModel::load(&mut File::open(&args[1]).unwrap()).unwrap();
    let mut driver = Driver::new(&model);
    driver.drive(&model);
    for kv in args[2].split(',').filter(|s| !s.is_empty()) {
        let (k, v) = kv.split_once('=').unwrap();
        driver.set_param_by_id(k, v.parse().unwrap()).unwrap();
    }
    driver.drive(&model);
    let want: Vec<&str> = args[3].split(',').collect();
    let meshes = model.artmeshes();
    for i in 0..meshes.count() {
        let a = meshes.index(i).unwrap();
        let id = a.id().to_string();
        if !want.contains(&id.as_str()) { continue; }
        match driver.artmesh_state(a.uid()) {
            Some(st) => {
                let (mut lo, mut hi) = (st.vertices[0], st.vertices[0]);
                for v in st.vertices { lo = lo.min(*v); hi = hi.max(*v); }
                println!("{id}: visible {} opacity {:.3} depth {} bbox {:?}..{:?}", st.visual.visible, st.visual.opacity, st.depth, lo, hi);
                if env::var("VERTS").is_ok() { println!("  {:?}", st.vertices.iter().map(|v| (v.x * 1500.0, v.y * 1500.0)).collect::<Vec<_>>()); }
            }
            None => println!("{id}: no state"),
        }
    }
    for (k, node) in driver.draw_nodes(None).unwrap().iter().enumerate() {
        if let DrawNode::ArtMesh(uid) = node {
            let id = meshes.get(*uid).unwrap().id().to_string();
            if want.contains(&id.as_str()) { println!("draw #{k} {id}"); }
        }
    }
}
