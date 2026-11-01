//! Every stage against the Python tracker on recorded landmarks (golden files from
//! tracker/tools/export_core.py, kept with the private test data). Skipped when they are not there.
//!     cargo test --release -- --nocapture

use std::path::PathBuf;
use yorishiro_tracking::data::Npz;
use yorishiro_tracking::fit::Fitter;
use yorishiro_tracking::pipeline::Pipeline;
use yorishiro_tracking::vts::vts_params;

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn testdata() -> PathBuf {
    std::env::var_os("YORISHIRO_TESTDATA").map(PathBuf::from).unwrap_or_else(|| root().join("../testdata"))
}

/// Largest difference of a stage over a recording and where it was.
#[derive(Default)]
struct Worst {
    diff: f64,
    frame: usize,
    index: usize,
}

impl Worst {
    fn add(&mut self, frame: usize, ours: &[f64], theirs: &[f64]) {
        for (j, (a, b)) in ours.iter().zip(theirs).enumerate() {
            let d = (a - b).abs();
            if d > self.diff {
                self.diff = d;
                self.frame = frame;
                self.index = j;
            }
        }
    }
}

const STAGES: [(&str, f64); 9] = [
    // normalized image coordinates
    ("smoothed", 1e-9),
    // pixel-sized units of the aligned face
    ("aligned", 1e-6),
    ("bs", 2e-4),
    ("head_ypr", 2e-5),
    ("head_pos", 2e-6),
    ("final_bs", 5e-4),
    ("final_head", 5e-5),
    ("final_pos", 5e-6),
    ("vts", 5e-3),
];

fn check(name: &str) -> bool {
    let path = testdata().join("core-golden").join(format!("{name}.npz"));
    let fit = root().join("tracker/models/core/fit.npz");
    if !path.exists() || !fit.exists() {
        eprintln!("skipping {name}: {} or {} missing (run tracker/tools/export_core.py)", path.display(), fit.display());
        return true;
    }
    let mut g = Npz::open(&path).unwrap();
    let (lms, shape) = g.f64s("landmarks").unwrap();
    let n = shape[0] as usize;
    let det = g.ints("detected").unwrap();
    let ts = g.f64s("timestamps_ms").unwrap().0;
    let size = g.f64s("size").unwrap().0;
    let golden: Vec<Vec<f64>> = STAGES.iter().map(|(s, _)| g.f64s(s).unwrap().0).collect();
    let calibrated_at = g.ints("calibrated_at").unwrap();
    let mut pipe = Pipeline::new(Fitter::load(&fit).unwrap());
    let mut worst: Vec<Worst> = STAGES.iter().map(|_| Worst::default()).collect();
    let mut calibrations = vec![];
    for i in 0..n {
        if det[i] == 0 {
            pipe.lost();
            continue;
        }
        let lm: Vec<[f64; 3]> = lms[i * 478 * 3..(i + 1) * 478 * 3].chunks(3).map(|c| [c[0], c[1], c[2]]).collect();
        let out = pipe.process(&lm, size[0], size[1], ts[i] as i64);
        if out.calibrated {
            calibrations.push(i);
        }
        let flat = |pts: &[[f64; 3]]| pts.iter().flatten().copied().collect::<Vec<f64>>();
        let vts: Vec<f64> = vts_params(&out.final_frame, true).into_iter().map(|(_, v)| v).collect();
        let ours: [Vec<f64>; 9] = [
            flat(&out.smoothed),
            flat(&out.aligned),
            out.frame.blendshapes.to_vec(),
            out.frame.head_rotation.to_vec(),
            out.frame.head_translation.to_vec(),
            out.final_frame.blendshapes.to_vec(),
            out.final_frame.head_rotation.to_vec(),
            out.final_frame.head_translation.to_vec(),
            vts,
        ];
        for (k, o) in ours.iter().enumerate() {
            let len = o.len();
            worst[k].add(i, o, &golden[k][i * len..(i + 1) * len]);
        }
    }
    let mut ok = calibrations == calibrated_at;
    println!("{name}: {n} frames, neutral window at {calibrations:?} (Python {calibrated_at:?})");
    for ((stage, tol), w) in STAGES.iter().zip(&worst) {
        let pass = w.diff <= *tol;
        ok &= pass;
        println!("  {stage:11} max diff {:.2e} at frame {:5} value {:4} (tolerance {tol:.0e}) {}", w.diff, w.frame, w.index, if pass { "ok" } else { "FAILED" });
    }
    ok
}

#[test]
fn golden_recordings() {
    let mut ok = true;
    for name in ["crema-d-60", "20261029-105439"] {
        ok &= check(name);
    }
    assert!(ok, "the Rust core differs from the Python tracker, see the table above");
}
