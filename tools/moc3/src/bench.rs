// bench MODEL.moc3 [frames]: drives the model through a fixed head, eye, mouth and body animation (ALL=1: every
// parameter, as physics moves hair and clothes in the app) and prints the
// time per frame of Driver::drive and a checksum of every vertex, opacity and depth (equal before and after a
// change to the driver means the same output)
use std::{env, fs::File, time::Instant};
use katashiro_core::core::{ArtMesh, Item, ItemArray, Model, Param};
use katashiro_core::driver::Driver;
use katashiro_core::file;

const ANIMATED: [&str; 12] = [
    "ParamAngleX", "ParamAngleY", "ParamAngleZ", "ParamEyeLOpen", "ParamEyeROpen", "ParamEyeBallX", "ParamEyeBallY",
    "ParamMouthOpenY", "ParamMouthForm", "ParamBodyAngleX", "ParamBodyAngleZ", "ParamBreath",
];

fn main() {
    let args: Vec<String> = env::args().collect();
    let model = file::ParsedModel::load(&mut File::open(&args[1]).unwrap()).unwrap();
    let frames: usize = args.get(2).map(|s| s.parse().unwrap()).unwrap_or(300);
    let params: Vec<(String, f32, f32)> = model
        .params()
        .into_iter()
        .filter(|p| env::var("ALL").is_ok() || ANIMATED.contains(&p.id()))
        .map(|p| (p.id().to_string(), p.min(), p.max()))
        .collect();
    let mut driver = Driver::new(&model);
    driver.drive(&model);
    let mut times = vec![];
    let mut sum = 0f64;
    for f in 0..frames {
        for (k, (id, lo, hi)) in params.iter().enumerate() {
            let t = (f as f32 * 0.05 + k as f32 * 0.7).sin() * 0.5 + 0.5;
            driver.set_param_by_id(id, lo + (hi - lo) * t).unwrap();
        }
        let t0 = Instant::now();
        driver.drive(&model);
        times.push(t0.elapsed().as_secs_f64() * 1000.0);
        for a in model.artmeshes() {
            if let Some(st) = driver.artmesh_state(a.uid()) {
                for v in st.vertices {
                    sum += (v.x as f64) * 1.3 + v.y as f64;
                }
                sum += st.visual.opacity as f64 + st.depth as f64 * 0.001;
            }
        }
    }
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let verts: u32 = model.artmeshes().into_iter().map(|a| a.vertex_count()).sum();
    println!(
        "{}: {} meshes, {} vertices, {} animated params; drive median {:.3} ms, p90 {:.3} ms; checksum {:.6}",
        args[1].rsplit('/').next().unwrap(), model.artmeshes().count(), verts, params.len(),
        times[times.len() / 2], times[times.len() * 9 / 10], sum
    );
}
