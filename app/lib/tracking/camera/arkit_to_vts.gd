## ARKit blendshapes and a head pose to the VTube Studio style inputs Live2D models are bound to (FaceAngleX,
## EyeOpenLeft, MouthOpen and so on). The same rules as the Yorishiro tracker's core (crates/tracking/src/vts.rs),
## for inputs that bring ARKit data from a phone: without this the phone's values only reach models wired to the raw
## blendshapes in the node editor, so a normal model did not move.
## Left/Right are the avatar's sides; mirrored (the VTuber default) the user's left eye drives the avatar's right eye.

const EYE_FULL_DEG := 25.0

## shapes: ARKit names in PascalCase (EyeBlinkLeft), 0..1. head: nod (pitch), turn (yaw), tilt (roll) in degrees.
## position: cm from the neutral. eye_left, eye_right: x turn, y nod in degrees.
static func params(shapes: Dictionary, head: Array, position: Vector3, eye_left: Vector2, eye_right: Vector2,
		mirror: bool = true) -> Dictionary:
	var bs := func (n: String) -> float: return float(shapes.get(n, 0.0))
	var s := -1.0 if mirror else 1.0
	var pitch: float = head[0]
	var yaw: float = head[1]
	var roll: float = head[2]
	var eye_open := [0.0, 0.0]
	var eye_x := [0.0, 0.0]
	var eye_y := [0.0, 0.0]
	var brow := [0.0, 0.0]
	for side in ["Left", "Right"]:
		var avatar_left: bool = (side == "Right") if mirror else (side == "Left")
		var a := 0 if avatar_left else 1
		eye_open[a] = 1.0 - bs.call("EyeBlink" + side)
		var eye: Vector2 = eye_left if side == "Left" else eye_right
		eye_x[a] = s * eye.x / EYE_FULL_DEG
		eye_y[a] = eye.y / EYE_FULL_DEG
		brow[a] = bs.call("BrowOuterUp" + side) + 0.5 * bs.call("BrowInnerUp") - bs.call("BrowDown" + side)
	var smile: float = (bs.call("MouthSmileLeft") + bs.call("MouthSmileRight")) / 2.0
	var frown: float = (bs.call("MouthFrownLeft") + bs.call("MouthFrownRight")) / 2.0
	# Brows reads the brow values before they are clipped, as the core does
	var brows: float = 0.5 + 0.25 * (brow[0] + brow[1])
	return {
		"FaceAngleX": clampf(s * yaw, -30, 30),
		"FaceAngleY": clampf(pitch, -30, 30),
		"FaceAngleZ": clampf(s * roll, -30, 30),
		"FacePositionX": clampf(s * position.x, -15, 15),
		"FacePositionY": clampf(position.y, -15, 15),
		"FacePositionZ": clampf(position.z, -10, 10),
		"EyeOpenLeft": clampf(eye_open[0], 0, 1),
		"EyeOpenRight": clampf(eye_open[1], 0, 1),
		"EyeLeftX": clampf(eye_x[0], -1, 1),
		"EyeLeftY": clampf(eye_y[0], -1, 1),
		"EyeRightX": clampf(eye_x[1], -1, 1),
		"EyeRightY": clampf(eye_y[1], -1, 1),
		"BrowLeftY": clampf(brow[0], -1, 1),
		"BrowRightY": clampf(brow[1], -1, 1),
		"MouthSmile": clampf(0.5 + 0.5 * (smile - frown), 0, 1),
		"MouthOpen": clampf(bs.call("JawOpen") - bs.call("MouthClose"), 0, 1),
		"MouthX": clampf(s * (bs.call("MouthLeft") - bs.call("MouthRight")), -1, 1),
		"Brows": clampf(brows, 0, 1),
		"CheekPuff": clampf(bs.call("CheekPuff"), 0, 1),
		"TongueOut": clampf(bs.call("TongueOut"), 0, 1),
	}
