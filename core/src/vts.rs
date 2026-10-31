//! ARKit 52 frame to VTube Studio style tracking inputs (adapters/vts_params.py). Left/Right are the
//! avatar's own sides; mirrored (the VTuber default), the user's left eye drives the avatar's right eye.

use crate::frame::{arkit, FaceFrame};

const EYE_FULL_DEG: f64 = 25.0;
/// Lip gap over face height that counts as closed lips and as a wide open mouth.
const LIP_GAP_CLOSED: f64 = 0.015;
const LIP_GAP_OPEN: f64 = 0.22;

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
        eye_x[a] = s * eye[0].to_degrees() / EYE_FULL_DEG;
        eye_y[a] = eye[1].to_degrees() / EYE_FULL_DEG;
        let up = bs(&format!("browOuterUp{side}")) + 0.5 * bs("browInnerUp");
        brow[a] = up - bs(&format!("browDown{side}"));
    }
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

