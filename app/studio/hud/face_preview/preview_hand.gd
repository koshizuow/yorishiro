## A clay hand for the tracking preview, built straight from the 21 points the tracker sees and drawn as one
## smooth surface (preview_hand.gdshader). Proportions follow average adult hands: the thumb is the
## thickest finger and the little finger the thinnest, each narrowing towards its tip; the palm is
## thick segments from the wrist to each finger's base, and on the palm side the muscles over the bones:
## the ball of the thumb (thenar), the little finger's side (hypothenar), the pads under the knuckles and
## the web between thumb and index finger. Nothing to retarget and no model file, so it always shows
## exactly what is tracked.
extends Node3D

## [from point, to point, radius at from, radius at to] in metres
const SEGMENTS = [
	# thumb
	[1, 2, 0.0115, 0.0105], [2, 3, 0.0105, 0.0095], [3, 4, 0.0095, 0.0084],
	# index, middle, ring, little finger
	[5, 6, 0.0095, 0.0088], [6, 7, 0.0088, 0.0080], [7, 8, 0.0080, 0.0071],
	[9, 10, 0.0098, 0.0090], [10, 11, 0.0090, 0.0082], [11, 12, 0.0082, 0.0073],
	[13, 14, 0.0092, 0.0085], [14, 15, 0.0085, 0.0077], [15, 16, 0.0077, 0.0068],
	[17, 18, 0.0082, 0.0075], [18, 19, 0.0075, 0.0068], [19, 20, 0.0068, 0.0060],
	# palm: the wrist to each finger's base, the knuckle line, the ball of the thumb
	[0, 5, 0.0150, 0.0110], [0, 9, 0.0155, 0.0112], [0, 13, 0.0150, 0.0106], [0, 17, 0.0145, 0.0098],
	[5, 9, 0.0110, 0.0112], [9, 13, 0.0112, 0.0106], [13, 17, 0.0106, 0.0098],
	[0, 1, 0.0170, 0.0140], [1, 5, 0.0110, 0.0095],
]
## SEGMENTS before this are fingers, the rest the palm
const FINGER_SEGMENTS = 15
## palm side muscles: [from (point, toward point, share of the way), to (same), radius from, radius to,
## how far towards the palm side (metres)]
const MUSCLES = [
	# thenar: from near the wrist to the thumb's knuckle, the fullest
	[[0, 1, 0.35], [1, 2, 0.6], 0.0145, 0.0110, 0.0065],
	[[0, 5, 0.25], [1, 2, 0.3], 0.0120, 0.0110, 0.0055],
	# hypothenar: along the little finger's edge from the wrist to below the little finger
	[[0, 17, 0.2], [0, 17, 0.8], 0.0120, 0.0100, 0.0050],
	# pads under the knuckles
	[[5, 9, 0.0], [13, 17, 1.0], 0.0085, 0.0080, 0.0045],
	# the web between thumb and index finger
	[[2, 5, 0.2], [2, 5, 0.8], 0.0070, 0.0070, 0.0010],
]
const MARGIN = 0.03

var _box := MeshInstance3D.new()
var _material := ShaderMaterial.new()

func _init(_unused: Material = null) -> void:
	_material.shader = preload("./preview_hand.gdshader")
	_box.mesh = BoxMesh.new()
	_box.material_override = _material
	_box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_box)

## points: 21 [x, y, z] in metres with y down and z away from the camera (tracker world coordinates)
## palm_sign: which side of (index base - wrist) x (little finger base - wrist) the palm is on, +1 for a
## right hand's shape, -1 for a left one's (checked on HaGRID palms facing the camera)
func show_points(points: Array, palm_sign: float = 1.0) -> void:
	if points.size() != 21:
		visible = false
		return
	visible = true
	var p: Array[Vector3] = []
	var lo := Vector3.ONE * 1e9
	var hi := -lo
	for q in points:
		var v := Vector3(float(q[0]), -float(q[1]), -float(q[2]))
		p.append(v)
		lo = lo.min(v)
		hi = hi.max(v)
	var center := (lo + hi) / 2
	var half := (hi - lo) / 2 + Vector3.ONE * MARGIN
	(_box.mesh as BoxMesh).size = half * 2
	_box.position = center
	var seg_a := PackedVector4Array()
	var seg_b := PackedVector4Array()
	for s in SEGMENTS:
		var a: Vector3 = p[s[0]] - center
		var b: Vector3 = p[s[1]] - center
		seg_a.append(Vector4(a.x, a.y, a.z, s[2]))
		seg_b.append(Vector4(b.x, b.y, b.z, s[3]))
	var palm := (p[5] - p[0]).cross(p[17] - p[0]).normalized() * palm_sign
	var at := func (spec: Array) -> Vector3: return p[spec[0]].lerp(p[spec[1]], spec[2])
	for m in MUSCLES:
		var a: Vector3 = at.call(m[0]) + palm * m[4] - center
		var b: Vector3 = at.call(m[1]) + palm * m[4] - center
		seg_a.append(Vector4(a.x, a.y, a.z, m[2]))
		seg_b.append(Vector4(b.x, b.y, b.z, m[3]))
	_material.set_shader_parameter("seg_a", seg_a)
	_material.set_shader_parameter("seg_b", seg_b)
	_material.set_shader_parameter("segment_count", SEGMENTS.size() + MUSCLES.size())
	_material.set_shader_parameter("finger_count", FINGER_SEGMENTS)
	_material.set_shader_parameter("half_size", half)
