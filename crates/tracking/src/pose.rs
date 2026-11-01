//! Head and eye angles (ported from the retired Python tracker's pose.py).

use crate::f32r;
use crate::frame::arkit;
use nalgebra::Matrix3;

pub const MAX_EYE_YAW_DEG: f64 = 30.0;
pub const MAX_EYE_PITCH_DEG: f64 = 25.0;

fn rot_x(a: f64) -> Matrix3<f64> {
    let (s, c) = a.sin_cos();
    Matrix3::new(1.0, 0.0, 0.0, 0.0, c, -s, 0.0, s, c)
}

fn rot_y(a: f64) -> Matrix3<f64> {
    let (s, c) = a.sin_cos();
    Matrix3::new(c, 0.0, s, 0.0, 1.0, 0.0, -s, 0.0, c)
}

fn rot_z(a: f64) -> Matrix3<f64> {
    let (s, c) = a.sin_cos();
    Matrix3::new(c, -s, 0.0, s, c, 0.0, 0.0, 0.0, 1.0)
}

/// Inverse of rotation_to_ypr.
pub fn ypr_to_rotation(ypr: [f64; 3]) -> Matrix3<f64> {
    rot_y(ypr[0]) * rot_x(-ypr[1]) * rot_z(-ypr[2])
}

/// Face-model rotation (x = subject's left, y up, z out of the face) to yaw/pitch/roll, as float32.
pub fn rotation_to_ypr(r: &Matrix3<f64>) -> [f64; 3] {
    let f = r.column(2);
    let yaw = f[0].atan2(f[2]);
    let pitch = f[1].clamp(-1.0, 1.0).asin();
    // remove yaw and pitch, what is left is a pure rotation about the face's z axis
    let r_roll = (rot_y(yaw) * rot_x(-pitch)).transpose() * r;
    let up = r_roll.column(1);
    let roll = up[0].atan2(up[1]);
    [f32r(yaw), f32r(pitch), f32r(roll)]
}

/// Approximate eye yaw/pitch from the eyeLook* blendshapes, same signs as the head.
pub fn eye_rotations_from_blendshapes(bs: &[f64; 52]) -> ([f64; 3], [f64; 3]) {
    let g = |n: &str| bs[arkit(n)];
    let yaw = MAX_EYE_YAW_DEG.to_radians();
    let pitch = MAX_EYE_PITCH_DEG.to_radians();
    let left = [
        f32r((g("eyeLookOutLeft") - g("eyeLookInLeft")) * yaw),
        f32r((g("eyeLookUpLeft") - g("eyeLookDownLeft")) * pitch),
        0.0,
    ];
    let right = [
        f32r((g("eyeLookInRight") - g("eyeLookOutRight")) * yaw),
        f32r((g("eyeLookUpRight") - g("eyeLookDownRight")) * pitch),
        0.0,
    ];
    (left, right)
}
