//! ARKit 52 frame to VTube Studio style tracking inputs (adapters/vts_params.py). Left/Right are the
//! avatar's own sides; mirrored (the VTuber default), the user's left eye drives the avatar's right eye.

use crate::frame::{arkit, FaceFrame};

const EYE_FULL_DEG: f64 = 25.0;
/// Head turn (degrees) up to which the vertical gaze is used as measured, and from which it is level.
const EYE_Y_TRUST_DEG: f64 = 10.0;
const EYE_Y_LEVEL_DEG: f64 = 25.0;
/// Lip gap over face height that counts as closed lips and as a wide open mouth.
const LIP_GAP_CLOSED: f64 = 0.015;
const LIP_GAP_OPEN: f64 = 0.22;

/// EyeOpen as VTube Studio's webcam tracking gives it: (ours, theirs) points, linear between them. Ours is 1.0 with
/// the eyes open as an iPhone has it; VTube Studio's NVIDIA tracker rests near 0.47 and models rigged for it map about
/// 0..0.5, so with ours as is their eyes only start to close below half open and a blink looks short and shallow.
/// Fitted to that tracker on our recordings (2026-11-18, testdata/nvidia-ref): held out, the mean difference went
/// from about 0.45 to 0.04..0.18.
const WEBCAM_EYE_OPEN: [(f64, f64); 6] = [(0.0, 0.0), (0.2, 0.0), (0.35, 0.25), (0.55, 0.36), (0.75, 0.45), (1.0, 0.47)];

/// An EyeOpen value (iPhone range, 1.0 open) on VTube Studio's webcam range.
pub fn webcam_eye_open(open: f64) -> f64 {
    let x = open.clamp(0.0, 1.0);
    for w in WEBCAM_EYE_OPEN.windows(2) {
        let ((x0, y0), (x1, y1)) = (w[0], w[1]);
        if x <= x1 {
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0);
        }
    }
    WEBCAM_EYE_OPEN[WEBCAM_EYE_OPEN.len() - 1].1
}

/// How much of the measured vertical gaze is kept at a head turn (degrees), 1 facing the camera to 0 turned away.
pub fn gaze_y_trust(yaw_deg: f64) -> f64 {
    ((EYE_Y_LEVEL_DEG - yaw_deg.abs()) / (EYE_Y_LEVEL_DEG - EYE_Y_TRUST_DEG)).clamp(0.0, 1.0)
}

/// The inputs in a fixed order, as (name, value).
pub fn vts_params(frame: &FaceFrame, mirror: bool) -> Vec<(&'static str, f64)> {
    let bs = |n: &str| frame.blendshapes[arkit(n)];
    let s = if mirror { -1.0 } else { 1.0 };
    let [yaw, pitch, roll] = frame.head_rotation.map(f64::to_degrees);
    let (user_l, user_r) = if mirror { ("Right", "Left") } else { ("Left", "Right") };
    let mut eye_open = [0.0; 2];
    let mut eye_x = [0.0; 2];
    let mut eye_y = [0.0; 2];
    let mut brow = [0.0; 2];
    for (side, avatar) in [("Left", user_l), ("Right", user_r)] {
        let a = if avatar == "Left" { 0 } else { 1 };
        eye_open[a] = 1.0 - bs(&format!("eyeBlink{side}"));
        let eye = if side == "Left" { frame.left_eye_rotation } else { frame.right_eye_rotation };
        // VTube Studio's EyeLeftX/EyeRightX run the other way from its FaceAngleX: against its NVIDIA tracker on our
        // recordings each eye's X was anti-correlated with ours (r -0.3 to -0.85) while the head matched (2026-11-18)
        eye_x[a] = -s * eye[0].to_degrees() / EYE_FULL_DEG;
        eye_y[a] = eye[1].to_degrees() / EYE_FULL_DEG;
        let up = bs(&format!("browOuterUp{side}")) + 0.5 * bs("browInnerUp");
        brow[a] = up - bs(&format!("browDown{side}"));
    }
    // The eyes turn together, but each eye's X from the camera is noisy (an iris moves a few pixels over its whole
    // range): our two eyes correlated -0.33..0.77 where NVIDIA's do 0.9..0.99. Both eyes get their mean, which took
    // the correlation with NVIDIA from 0.66 to 0.82 over our recordings (2026-11-18).
    // each eye within its range first, so one eye's outlier does not pull the other past it
    let gaze_x = (eye_x[0].clamp(-1.0, 1.0) + eye_x[1].clamp(-1.0, 1.0)) / 2.0;
    eye_x = [gaze_x; 2];
    // Y too, and towards level as the head turns: turned, each eye's Y went wrong the opposite way of the other (up
    // to 1.6 apart on the phone recordings, following the turn) while NVIDIA's shared Y stays near level. Their mean
    // has half the error; fading it out from 10 to 25 degrees of turn took the mean difference from NVIDIA from 0.32
    // to 0.20 over our recordings at the same correlation (2026-11-18). Leaning on the eye nearer the camera did worse.
    let gaze_y = gaze_y_trust(yaw) * (eye_y[0].clamp(-1.0, 1.0) + eye_y[1].clamp(-1.0, 1.0)) / 2.0;
    eye_y = [gaze_y; 2];
    let smile = (bs("mouthSmileLeft") + bs("mouthSmileRight")) / 2.0;
    let frown = (bs("mouthFrownLeft") + bs("mouthFrownRight")) / 2.0;
    let mut mouth_open = bs("jawOpen") - bs("mouthClose");
    if let Some(gap) = frame.mouth_gap {
        mouth_open = mouth_open.max((gap - LIP_GAP_CLOSED) / (LIP_GAP_OPEN - LIP_GAP_CLOSED));
    }
    // Brows reads the brow values before they are clipped, as the Python code does
    let brows = 0.5 + 0.25 * (brow[0] + brow[1]);
    let brow = brow.map(|b| b.clamp(-1.0, 1.0));
    let unit = |x: f64| x.clamp(0.0, 1.0);
    let signed = |x: f64| x.clamp(-1.0, 1.0);
    let t = frame.head_translation;
    vec![
        ("FaceAngleX", (s * yaw).clamp(-30.0, 30.0)),
        ("FaceAngleY", pitch.clamp(-30.0, 30.0)),
        ("FaceAngleZ", (s * roll).clamp(-30.0, 30.0)),
        // centimetres from the neutral, the app's input ranges
        ("FacePositionX", (s * t[0] * 100.0).clamp(-15.0, 15.0)),
        ("FacePositionY", (t[1] * 100.0).clamp(-15.0, 15.0)),
        ("FacePositionZ", (t[2] * 100.0).clamp(-10.0, 10.0)),
        ("EyeOpenLeft", unit(eye_open[0])),
        ("EyeOpenRight", unit(eye_open[1])),
        ("EyeLeftX", signed(eye_x[0])),
        ("EyeLeftY", signed(eye_y[0])),
        ("EyeRightX", signed(eye_x[1])),
        ("EyeRightY", signed(eye_y[1])),
        ("BrowLeftY", brow[0]),
        ("BrowRightY", brow[1]),
        ("MouthSmile", unit(0.5 + 0.5 * (smile - frown))),
        ("MouthOpen", unit(mouth_open)),
        ("MouthX", signed(s * (bs("mouthLeft") - bs("mouthRight")))),
        ("Brows", unit(brows)),
        ("CheekPuff", unit(bs("cheekPuff"))),
        ("TongueOut", unit(bs("tongueOut"))),
    ]
}


#[cfg(test)]
mod tests {
    use super::webcam_eye_open;

    #[test]
    fn webcam_eye_open_curve() {
        assert_eq!(webcam_eye_open(1.0), 0.47);
        assert_eq!(webcam_eye_open(0.1), 0.0);
        assert!((webcam_eye_open(0.45) - 0.305).abs() < 1e-9);
        assert_eq!(webcam_eye_open(1.5), 0.47);
        let mut last = 0.0;
        for i in 0..=100 {
            let v = webcam_eye_open(i as f64 / 100.0);
            assert!(v >= last);
            last = v;
        }
    }
}
