//! The outputs to other apps against the Python tracker's sinks on random frames (written by a small Python
//! script to SINK_GOLDEN): iFacialMocap text equal character for character, the VTS iPhone JSON equal value
//! for value (the timestamp aside). Golden: testdata/core-golden/sinks.json from the retired Python tracker's export_core.py,
//! or SINK_GOLDEN; skipped without either.
use yorishiro_tracking::frame::FaceFrame;
use yorishiro_tracking::sinks::{swap_sides, IFacialMocapSink, VtsIphoneSink};

/// The Python sink sent our own directions; the phone's are mirrored (see VtsIphoneSink::payload): the golden
/// payload turned into what the phone would send for the same face.
fn phone_sides(v: &serde_json::Value) -> serde_json::Value {
    let mut v = v.clone();
    let neg = |x: &mut serde_json::Value| { if let Some(f) = x.as_f64() { *x = serde_json::json!(if f == 0.0 { 0.0 } else { -f }); } };
    neg(&mut v["Rotation"]["x"]);
    neg(&mut v["Rotation"]["y"]);
    neg(&mut v["Position"]["x"]);
    let (l, r) = (v["EyeLeft"].clone(), v["EyeRight"].clone());
    v["EyeLeft"] = r;
    v["EyeRight"] = l;
    neg(&mut v["EyeLeft"]["y"]);
    neg(&mut v["EyeRight"]["y"]);
    for s in v["BlendShapes"].as_array_mut().unwrap() {
        s["k"] = serde_json::json!(swap_sides(s["k"].as_str().unwrap()));
    }
    v
}

#[test]
fn sinks_match_python() {
    let path = std::env::var_os("SINK_GOLDEN").map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../testdata/core-golden/sinks.json"));
    if !path.exists() {
        eprintln!("skipping: {} missing", path.display());
        return;
    }
    let golden: Vec<serde_json::Value> = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let vts = VtsIphoneSink::open(0).unwrap();
    let ifm = IFacialMocapSink::open("127.0.0.1").unwrap();
    let arr = |v: &serde_json::Value| -> Vec<f64> { v.as_array().unwrap().iter().map(|x| x.as_f64().unwrap()).collect() };
    let three = |v: &serde_json::Value| -> [f64; 3] { let a = arr(v); [a[0], a[1], a[2]] };
    let (mut same_ifm, mut same_vts) = (0, 0);
    for g in &golden {
        let mut bs = [0.0; 52];
        bs.copy_from_slice(&arr(&g["bs"]));
        let f = FaceFrame { timestamp_ms: 0, blendshapes: bs, head_rotation: three(&g["head"]), head_translation: three(&g["pos"]),
                            left_eye_rotation: three(&g["le"]), right_eye_rotation: three(&g["re"]), mouth_gap: None, lens_glare: None };
        let ours = ifm.payload(&f);
        if ours == g["ifm"].as_str().unwrap() {
            same_ifm += 1;
        } else {
            println!("iFacialMocap differs:\n  ours   {ours}\n  python {}", g["ifm"].as_str().unwrap());
        }
        let mut a: serde_json::Value = serde_json::from_str(&vts.payload(Some(&f))).unwrap();
        let mut b = phone_sides(&g["vts"]);  // Python's payload() is the dict before json.dumps
        a.as_object_mut().unwrap().remove("Timestamp");
        b.as_object_mut().unwrap().remove("Timestamp");
        if a == b {
            same_vts += 1;
        } else {
            println!("VTS iPhone differs:\n  ours   {a}\n  python {b}");
        }
    }
    println!("{} frames: iFacialMocap equal {same_ifm}, VTS iPhone equal {same_vts}", golden.len());
    assert_eq!(same_ifm, golden.len());
    assert_eq!(same_vts, golden.len());
}
