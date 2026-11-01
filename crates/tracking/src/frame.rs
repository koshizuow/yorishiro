//! ARKit 52 names and the per-frame face values (tracker/src/yorishiro_tracker/frame.py).

/// Same order as Live Link Face CSV and Apple's ARFaceAnchor.BlendShapeLocation.
pub const ARKIT52: [&str; 52] = [
    "eyeBlinkLeft", "eyeLookDownLeft", "eyeLookInLeft", "eyeLookOutLeft",
    "eyeLookUpLeft", "eyeSquintLeft", "eyeWideLeft",
    "eyeBlinkRight", "eyeLookDownRight", "eyeLookInRight", "eyeLookOutRight",
    "eyeLookUpRight", "eyeSquintRight", "eyeWideRight",
    "jawForward", "jawRight", "jawLeft", "jawOpen",
    "mouthClose", "mouthFunnel", "mouthPucker", "mouthRight", "mouthLeft",
    "mouthSmileLeft", "mouthSmileRight", "mouthFrownLeft", "mouthFrownRight",
    "mouthDimpleLeft", "mouthDimpleRight", "mouthStretchLeft", "mouthStretchRight",
    "mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper",
    "mouthPressLeft", "mouthPressRight", "mouthLowerDownLeft", "mouthLowerDownRight",
    "mouthUpperUpLeft", "mouthUpperUpRight",
    "browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight",
    "cheekPuff", "cheekSquintLeft", "cheekSquintRight",
    "noseSneerLeft", "noseSneerRight",
    "tongueOut",
];

/// Index of an ARKit name; panics on a typo, every caller uses constants.
pub fn arkit(name: &str) -> usize {
    ARKIT52.iter().position(|n| *n == name).unwrap_or_else(|| panic!("no ARKit shape {name}"))
}

/// One tracked face. Angles in radians, translation in metres (camera space, y up, -z forward).
/// yaw + = subject turns to their own left, pitch + = up, roll + = top of the head towards the subject's
/// own left shoulder. Eye rotations are yaw, pitch, roll per eye.
#[derive(Clone, Debug)]
pub struct FaceFrame {
    pub timestamp_ms: i64,
    pub blendshapes: [f64; 52],
    pub head_rotation: [f64; 3],
    pub head_translation: [f64; 3],
    pub left_eye_rotation: [f64; 3],
    pub right_eye_rotation: [f64; 3],
    /// inner lip gap over face height
    pub mouth_gap: Option<f64>,
    /// share of each eye's box that looks like a screen reflection on glasses (left, right, subject's sides)
    pub lens_glare: Option<[f64; 2]>,
}
