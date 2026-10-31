## Tracking preview without the camera picture: a bald clay head (ICT-FaceKit, MIT) that turns and makes the
## faces the tracker sees, so users can check tracking without worrying that their camera image shows up.
## Mirrored like the avatar. Driven by the Yorishiro tracker's ARKit values when it runs, otherwise by the
## VTS style inputs (eyes, mouth, smile) every face tracker gives.
## The mesh is made by tools/export_preview_head.py.
class_name FacePreview
extends SubViewportContainer

const HEAD = preload("./head.glb")
## head turns are drawn smaller than measured, a full 30 degree turn would hide the face
const TURN = 0.8

var _viewport := SubViewport.new()
var _pivot := Node3D.new()
var _mesh: MeshInstance3D
## morph target index -> ARKit name that drives it (sides swapped for the mirror)
var _targets := {}

func _init() -> void:
	stretch = true
	custom_minimum_size = Vector2(240, 240)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	add_child(_viewport)

	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_CLEAR_COLOR
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.55, 0.50, 0.58)
	env.environment.ambient_light_energy = 0.6
	_viewport.add_child(env)
	var key := DirectionalLight3D.new()
	key.light_energy = 1.1
	key.rotation_degrees = Vector3(-25, 30, 0)
	_viewport.add_child(key)
	var rim := DirectionalLight3D.new()
	rim.light_color = Color(1.0, 0.75, 0.85)  # sakura rim from behind
	rim.light_energy = 0.7
	rim.rotation_degrees = Vector3(-10, 160, 0)
	_viewport.add_child(rim)
	var camera := Camera3D.new()
	camera.fov = 30
	camera.position = Vector3(0, 0.015, 0.62)
	_viewport.add_child(camera)

	# the ICT head's origin is near the nose bridge, turn it around the middle of the head instead
	_pivot.position = Vector3(0, -0.02, -0.05)
	_viewport.add_child(_pivot)
	var head: Node3D = HEAD.instantiate()
	head.position = Vector3(0, 0.02, 0.05)
	_pivot.add_child(head)
	_mesh = head.find_children("*", "MeshInstance3D", true, false)[0]
	var clay := StandardMaterial3D.new()
	clay.vertex_color_use_as_albedo = true
	clay.roughness = 0.7
	clay.rim_enabled = true
	clay.rim = 0.25
	_mesh.material_override = clay
	for i in _mesh.mesh.get_blend_shape_count():
		var name := String(_mesh.mesh.get_blend_shape_name(i))
		# browInnerUpLeft / cheekPuffRight are halves of one ARKit shape
		var source := name
		if name.begins_with("browInnerUp") or name.begins_with("cheekPuff"):
			source = name.trim_suffix("Left").trim_suffix("Right")
		else:
			source = _mirror(name)
		_targets[i] = source

func _mirror(name: String) -> String:
	if name.ends_with("Left"):
		return name.trim_suffix("Left") + "Right"
	if name.ends_with("Right"):
		return name.trim_suffix("Right") + "Left"
	return name

func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	var tracking = get_tree().get_first_node_in_group("system:tracking")
	if tracking == null:
		return
	var p: Dictionary = tracking.parameters
	# avatar inputs are mirrored already: the head turns the way the model on the stage does (checked with
	# --poses --face-preview). Godot's +x rotation looks down and +z leans left, the inputs mean up and right
	_pivot.rotation = Vector3(
		deg_to_rad(-float(p.get("FaceAngleY", 0.0)) * TURN),
		deg_to_rad(float(p.get("FaceAngleX", 0.0)) * TURN),
		deg_to_rad(-float(p.get("FaceAngleZ", 0.0)) * TURN))
	var face = tracking.get_node_or_null("FaceTracker")
	var arkit: Dictionary = face.arkit if face and "arkit" in face and not face.arkit.is_empty() else _from_inputs(p)
	for i in _targets:
		_mesh.set_blend_shape_value(i, clampf(float(arkit.get(_targets[i], 0.0)), 0.0, 1.0))

## rough ARKit values from the inputs any face tracker sends, for trackers without blendshapes
func _from_inputs(p: Dictionary) -> Dictionary:
	var smile := clampf((float(p.get("MouthSmile", 0.5)) - 0.5) * 2.0, 0.0, 1.0)
	return {
		# the user's left eye is EyeOpenRight on the mirrored avatar, _mirror swaps it back
		"eyeBlinkLeft": 1.0 - float(p.get("EyeOpenRight", 1.0)),
		"eyeBlinkRight": 1.0 - float(p.get("EyeOpenLeft", 1.0)),
		"jawOpen": float(p.get("MouthOpen", 0.0)),
		"mouthSmileLeft": smile,
		"mouthSmileRight": smile,
	}
