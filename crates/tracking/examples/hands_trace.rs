//! Per frame: our hand crop and landmarks against Python's (golden), to find where they part.
use yorishiro_tracking::data::Npz;
use yorishiro_tracking::hands::HandTracker;
use yorishiro_tracking::image::Image;
use yorishiro_tracking::net::Runtime;
fn main() {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let mut g = Npz::open(&root.join("../testdata/core-golden/hagrid-hands-hands.npz")).unwrap();
    let roi = g.f64s("roi").unwrap().0;
    let lms = g.f64s("landmarks").unwrap().0;
    let mut t = HandTracker::open(&root.join("tracker/models/mediapipe/hands"), &Runtime::OrtCpu, 4).unwrap();
    for i in [0usize, 1, 2, 5, 10, 12, 30, 60, 61, 90] {
        // feed frames in order up to i
        let _ = i;
    }
    for i in 0..15 {
        let img = Image::load(&root.join(format!("../testdata/core-golden/hagrid-hands-frames/{i:05}.png"))).unwrap();
        let hands = t.process(&img).unwrap();
        let h = &hands[0];
        let r = &roi[i * 8..i * 8 + 4];
        let given = h.roi;
        let mut lm = 0.0f64;
        for j in 0..21 {
            let at = (i * 2 * 21 + j) * 3;
            lm = lm.max((h.landmarks[j][0] - lms[at]).hypot(h.landmarks[j][1] - lms[at + 1]));
        }
        // and the landmark model on Python's own crop
        let own = t.landmarks(&img, ([r[0], r[1]], r[2], r[3])).unwrap().unwrap();
        let mut lm2 = 0.0f64;
        for j in 0..21 {
            let at = (i * 2 * 21 + j) * 3;
            lm2 = lm2.max((own.landmarks[j][0] - lms[at]).hypot(own.landmarks[j][1] - lms[at + 1]));
        }
        println!("frame {i}: roi ours ({:.3},{:.3},{:.3},{:.4}) python ({:.3},{:.3},{:.3},{:.4}); landmarks {lm:.4} px, on Python's crop {lm2:.4} px",
                 given.0[0], given.0[1], given.1, given.2, r[0], r[1], r[2], r[3]);
    }
}
