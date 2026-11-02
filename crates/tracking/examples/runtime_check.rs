//! The automatic runtime choice on this machine: each runtime's pass time and how far its landmarks are from
//! ONNX Runtime's on the probe picture, then the pick.
//! cargo run --release --features ncnn --example runtime_check -- <monorepo>
fn main() {
    let root = std::path::PathBuf::from(std::env::args().nth(1).unwrap_or_else(|| ".".into()));
    let (pick, trials) = yorishiro_tracking::inference::auto_runtime(&root.join("models/mediapipe"), 2);
    for t in &trials {
        println!("{:50} pass {:6.2} ms  max diff {:.3} px", t.name, t.pass_ms, t.max_diff);
    }
    println!("pick: {pick:?}");
}
