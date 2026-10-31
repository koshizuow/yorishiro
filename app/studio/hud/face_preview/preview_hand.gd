## A clay hand for the tracking preview, built straight from the 21 points the tracker sees: a rounded
## capsule per finger bone, a ball per joint and a soft palm plate. Nothing to retarget and no model file,
## so it always shows exactly what is tracked.
extends Node3D

## bones between the 21 MediaPipe hand points
const BONES = [
	[0, 1], [1, 2], [2, 3], [3, 4],
	[0, 5], [5, 6], [6, 7], [7, 8],
	[9, 10], [10, 11], [11, 12],
	[13, 14], [14, 15], [15, 16],
	[0, 17], [17, 18], [18, 19], [19, 20],
	[5, 9], [9, 13], [13, 17],
]
## the palm plate's outline
const PALM = [0, 1, 5, 9, 13, 17]
## finger thickness (metres, before the preview's scale), thinner towards the tips
const RADIUS = 0.009
const TIP_RADIUS = 0.007

var _bones: Array[MeshInstance3D] = []
var _joints: Array[MeshInstance3D] = []
var _palm := MeshInstance3D.new()

func _init(material: Material) -> void:
	for b in BONES:
		var m := MeshInstance3D.new()
		var capsule := CapsuleMesh.new()
		capsule.radial_segments = 12
		capsule.rings = 2
		m.mesh = capsule
		m.material_override = material
		add_child(m)
		_bones.append(m)
	for i in 21:
		var m := MeshInstance3D.new()
		var ball := SphereMesh.new()
		ball.radial_segments = 12
		ball.rings = 6
		var r := _radius(i)
		ball.radius = r
		ball.height = r * 2
		m.mesh = ball
		m.material_override = material
		add_child(m)
		_joints.append(m)
	_palm.material_override = material
	add_child(_palm)

func _radius(i: int) -> float:
	return TIP_RADIUS if i in [4, 8, 12, 16, 20] else RADIUS

## points: 21 [x, y, z] in metres with y down and z away from the camera (tracker world coordinates)
func show_points(points: Array) -> void:
	if points.size() != 21:
		visible = false
		return
	visible = true
	var p: Array[Vector3] = []
	for q in points:
		p.append(Vector3(float(q[0]), -float(q[1]), -float(q[2])))
	for i in 21:
		_joints[i].position = p[i]
	for k in BONES.size():
		var a: Vector3 = p[BONES[k][0]]
		var b: Vector3 = p[BONES[k][1]]
		var length := a.distance_to(b)
		var m := _bones[k]
		var capsule: CapsuleMesh = m.mesh
		var r := minf(_radius(BONES[k][0]), _radius(BONES[k][1]))
		capsule.radius = r
		capsule.height = maxf(length + r * 2, r * 2.01)
		m.position = (a + b) / 2
		var dir := (b - a).normalized() if length > 1e-5 else Vector3.UP
		# turn the capsule's own up axis onto the bone
		var axis := Vector3.UP.cross(dir)
		if axis.length() < 1e-5:
			m.basis = Basis() if dir.y > 0 else Basis(Vector3.RIGHT, PI)
		else:
			m.basis = Basis(axis.normalized(), Vector3.UP.angle_to(dir))
	_palm.mesh = _palm_mesh(p)

## a plate through the palm outline, as thick as a finger: two fans and a rim
func _palm_mesh(p: Array[Vector3]) -> ArrayMesh:
	var outline: Array[Vector3] = []
	for i in PALM:
		outline.append(p[i])
	var center := Vector3.ZERO
	for v in outline:
		center += v
	center /= outline.size()
	var normal := (p[5] - p[0]).cross(p[17] - p[0]).normalized() * RADIUS * 0.8
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := outline.size()
	for side in [1.0, -1.0]:
		var off: Vector3 = normal * side
		for i in n:
			var a := outline[i] + off
			var b := outline[(i + 1) % n] + off
			if side > 0:
				st.add_vertex(center + off); st.add_vertex(a); st.add_vertex(b)
			else:
				st.add_vertex(center + off); st.add_vertex(b); st.add_vertex(a)
	for i in n:
		var a := outline[i]
		var b := outline[(i + 1) % n]
		st.add_vertex(a + normal); st.add_vertex(a - normal); st.add_vertex(b + normal)
		st.add_vertex(b + normal); st.add_vertex(a - normal); st.add_vertex(b - normal)
	st.generate_normals()
	return st.commit()
