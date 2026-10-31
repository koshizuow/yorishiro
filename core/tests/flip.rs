//! Flip averaged landmarks against the Python tracker's (golden <recording>-flip.npz, ORT CPU, PNG frames).
use std::path::PathBuf;
use yorishiro_core::data::Npz;
use yorishiro_core::image::Image;
use yorishiro_core::inference::{FaceMesh, Roi};

#[test]
fn flip_averaging_matches_python() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
    let td = root.join("../testdata/core-golden");
    if !td.join("crema-d-60-flip.npz").exists() || std::env::var_os("ORT_DYLIB_PATH").is_none() {
        eprintln!("skipping");
        return;
    }
    let mirror = Npz::open(&root.join("tracker/models/core/fit.npz")).unwrap().ints("flip_mirror").unwrap();
    let mut mesh = FaceMesh::open(&root.join("tracker/models/mediapipe"), 4).unwrap();
    mesh.flip_mirror = Some(mirror);
    for name in ["crema-d-60", "20261029-105439"] {
        let roi = Npz::open(&td.join(format!("{name}-inference.npz"))).unwrap().f64s("roi").unwrap().0;
        let want = Npz::open(&td.join(format!("{name}-flip.npz"))).unwrap().f64s("landmarks").unwrap().0;
        let n = want.len() / (478 * 3);
        let mut max = 0.0f64;
        for i in 0..n {
            let img = Image::load(&td.join(format!("{name}-frames/{i:05}.png"))).unwrap();
            let (w, h) = (img.width as f64, img.height as f64);
            let r = &roi[i * 4..i * 4 + 4];
            let got = mesh.landmarks_at(&img, Roi { center: [r[0], r[1]], size: r[2], angle: r[3] }).unwrap().unwrap();
            for k in 0..478 {
                let at = (i * 478 + k) * 3;
                max = max.max(((got.landmarks.points[k][0] - want[at]) * w).hypot((got.landmarks.points[k][1] - want[at + 1]) * h));
            }
        }
        println!("{name}: {n} frames, flip averaged landmarks within {max:.4} px of Python's");
        assert!(max < 0.05);
    }
}
