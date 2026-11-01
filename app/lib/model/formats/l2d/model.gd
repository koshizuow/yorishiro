# System for loading models from VTubeStudio's format
# and spawning them into the scene to be managed
extends "../../vt_model.gd"

const Pose3 = preload("res://lib/model/formats/l2d/pose3.gd")

var model: KatashiroModel
var container: Node
## parent of the model (or its pixel viewport), offset by the follow-the-face movement so the user's own
## placement on the VtModel stays untouched
var mover := Node2D.new()

const ParameterModifier = preload("./modifiers/parameter_modifier.gd")
const PartModifier = preload("./modifiers/part_modifier.gd")
const MeshModifier = preload("./modifiers/mesh_modifier.gd")

var model_settings: ModelModifier
var param_settings: Dictionary[StringName, ModelModifier] = {}
var part_settings: Dictionary[StringName, ModelModifier] = {}
var mesh_settings: Dictionary[StringName, ModelModifier] = {}

## physics on/off, overall strength (1 as simulated) and strength per physics setting id, kept in the
## model's .yori.json as "physics"; VTube Studio's PhysicsSettings seed them (PhysicsStrength 50 = 1)
var physics_enabled := true:
	set(v):
		physics_enabled = v
		_apply_physics()
var physics_strength := 1.0:
	set(v):
		physics_strength = v
		_apply_physics()
var physics_groups := {}

func get_physics() -> Node:
	return model.get_node_or_null("PhysicsController") if model else null

## the model's physics settings as [{id, name}], empty without a physics3.json
func physics_group_list() -> Array:
	var physics = get_physics()
	return physics.get_physics_groups() if physics and physics.definition else []

func set_physics_group(id: String, value: float) -> void:
	physics_groups[id] = value
	_apply_physics()

func _apply_physics() -> void:
	var physics = get_physics()
	if physics == null:
		return
	physics.enabled = physics_enabled
	physics.strength = physics_strength
	for id in physics_groups:
		physics.set_group_strength(id, float(physics_groups[id]))

func get_modifier_map():
	return {
		"model": model_settings,
		"parts": part_settings,
		"meshes": mesh_settings,
		"parameters": param_settings
	}

func _ready() -> void:
	model_settings = preload("./modifiers/base_modifier.gd").new(self)
	mover.name = "FaceMovement"
	add_child(mover)
	container = preload("./pixel_subviewport.tscn").instantiate()
	mover.add_child(container)

func is_initialized() -> bool:
	return model != null
	
func get_meshes() -> Array:
	return model.get_node("Meshes").get_children()
	
func get_parts() -> Array:
	return model.get_parts()
	
func get_size() -> Vector2:
	return model.size
	
func get_origin() -> Vector2:
	return model.origin
	
func get_parameters() -> Dictionary:
	return model.get_parameters().reduce(
		func (acc, p):
			acc[p] = {
				"default": model.get("parameters/%s/default" % p),
				"range": model.get("parameters/%s/range" % p) 
			}
			return acc,
		{}
	)
	
func _get(property: StringName) -> Variant:
	if property.begins_with("parameters/") or property.begins_with("parts/"):
		return model.get(property)
	
	return null

func _property_get_revert(property: StringName) -> Variant:
	if property.begins_with("parameters/") or property.begins_with("parts/"):
		return model.property_get_revert(property)
		
	return null

func _set(property: StringName, value: Variant) -> bool:
	if property.begins_with("parameters/"):
		if not property.ends_with("/range") and not property.ends_with("/default"):
			model.set(property, value)
			return true
	
	return false
		
func _get_property_list() -> Array[Dictionary]:
	var properties: Array[Dictionary] = []
	var base_properties = model.get_property_list()
	
	for param in Collections.select(base_properties, "name", RegEx.create_from_string("^parameters/")):
		var p_name = param.name.trim_prefix("parameters/")
		properties.append(param)
	
	return properties
	
func _build_model():
	var reload = is_initialized()
	if reload:
		model.queue_free()
		model = null
		await get_tree().process_frame
		
	print_debug("loading model from %s" % modelmeta.model)
	model = KatashiroLoader.load_model(modelmeta.model)
	if model == null:
		push_error("could not load model %s" % modelmeta.model)
		return false
	# adjust anchor to be top-left to match godot's control coordinate system
	mover.add_child(model)
	await get_tree().process_frame # wait for the model to initialize
	
	var anim_lib = KatashiroLoader.load_motion_library(model)
	var idle_anim: AnimationPlayer = model.get_node("MotionController")
	if idle_anim.has_animation_library(""):
		idle_anim.remove_animation_library("") # remove just in case
	idle_anim.add_animation_library("", anim_lib)
	
	# emotion controller
	load_expressions()
		
	# add ONE_SHOT animation player
	var os_lib = AnimationLibrary.new()
	for anim in anim_lib.get_animation_list():
		var a = anim_lib.get_animation(anim)
		var os_a = a.duplicate(true)
		os_a.loop_mode = Animation.LOOP_NONE
		os_lib.add_animation(anim, os_a)
	var one_shot = KatashiroMotionMutator.new()
	one_shot.add_animation_library("", os_lib)
	one_shot.name = "OneshotMotionController"
	model.add_child(one_shot)

	# pose groups last, after the motions that pick their parts
	var pose = Pose3.from_model_file(modelmeta.model)
	if pose:
		model.add_child(pose)
	
	#var physics = GDCubismEffectPhysics.new()
	#loaded_model.add_child(physics)
	#physics.name = "Physics"
	
	for m in get_meshes():
		if (m as MeshInstance2D).mesh.get_surface_count() <= 0:
			continue
		
		var centroid = Math.v32xy(Math.centroid(m.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]))
		m.set_meta("centroid", centroid)
		m.set_meta("start_centroid", centroid)
		
		mesh_settings[m.name] = MeshModifier.new(m)
		
	for p in get_parameters():
		param_settings[p] = ParameterModifier.new()
	
	for p in get_parts():
		part_settings[p] = PartModifier.new(model, p)
					
	await get_tree().process_frame
	
	model.position = Vector2.ZERO
	size = model.size
	centered = true
			
	return true

func apply_parameters(values: Dictionary):
	for p_name in values:
		model.set(p_name, values.get(p_name, 0.0))
	
func tracking_updated(tracking_data: Dictionary, delta: float):
	var move := follow_face(tracking_data, delta)
	# screen pixels to this model's local space (it may be scaled and rotated)
	mover.position = global_transform.affine_inverse().basis_xform(Vector2(move.x, move.y))
	mover.scale = Vector2.ONE * (1.0 + move.z)

func get_texture() -> Texture2D:
	if container is SubViewportContainer:
		return (container.get_child(0) as SubViewport).get_texture()
	return null
	
func get_idle_animation_player() -> AnimationPlayer:
	return model.get_node("MotionController")
	
func get_animation_player() -> AnimationPlayer:
	return model.get_node("OneshotMotionController")
	
func get_expression_controller() -> KatashiroExpressionMutator:
	return model.get_node("ExpressionController")

## expressions made or changed in the expression editor, beside the model's settings file; the model's own
## folder is never written. One with the name of a model expression takes its place.
func user_expression_dir() -> String:
	return modelmeta.settings_file.get_basename().get_basename() + ".expressions"

func user_expression_names() -> PackedStringArray:
	var out := PackedStringArray()
	if not DirAccess.dir_exists_absolute(user_expression_dir()):
		return out
	for f in DirAccess.get_files_at(user_expression_dir()):
		if f.ends_with(".exp3.json"):
			out.append(f.trim_suffix(".exp3.json"))
	return out

## the model's expressions and the user's, keeping the weights of those still there
func load_expressions() -> void:
	var controller: KatashiroExpressionMutator = get_expression_controller()
	var weights := {}
	for e in controller.expressions:
		weights[e.get_name()] = controller.get("weight/%s" % e.get_name())
	var library: Dictionary = KatashiroLoader.load_expression_library(modelmeta.model.get_base_dir(), true)
	var list: Array[KatashiroExpression] = []
	var groups := {}
	for e in library.keys():
		list.append(e)
		groups[e.get_name()] = library[e]
	var dir := user_expression_dir()
	for n in user_expression_names():
		var e: KatashiroExpression = KatashiroLoader.load_expression(ProjectSettings.globalize_path(dir.path_join(n + ".exp3.json")))
		if e == null:
			continue
		var i := list.find_custom(func (x): return x.get_name() == n)
		if i >= 0:
			list[i] = e
		else:
			list.append(e)
	controller.expressions = list
	for e in list:
		var n: String = e.get_name()
		if groups.get(n, &"") != &"":
			controller.set("expression_groups/%s" % n, groups[n])
		if weights.has(n) and weights[n] != null:
			controller.set("weight/%s" % n, weights[n])

## writes an expression ({id: [value, blend]}, blend Add, Multiply or Overwrite) and reloads the list
func save_user_expression(expression_name: String, tracks: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(user_expression_dir())
	var params := []
	for id in tracks:
		params.append({"Id": id, "Value": tracks[id][0], "Blend": tracks[id][1]})
	var f := FileAccess.open(user_expression_dir().path_join(expression_name + ".exp3.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"Type": "Live2D Expression", "FadeInTime": 0.5, "FadeOutTime": 0.5, "Parameters": params}, "\t"))
	f.close()
	load_expressions()

## the model's own expression of that name comes back, if it has one
func delete_user_expression(expression_name: String) -> void:
	DirAccess.remove_absolute(user_expression_dir().path_join(expression_name + ".exp3.json"))
	load_expressions()

## save bidirectional vts compatible settings
## Disabled: it rewrote the user's <name>.vtube.json (key order, and every mesh listed as excluded from
## pinning since the check is inverted), which breaks the model in VTube Studio. Yorishiro only reads VTS
## files, its own settings go to SettingsLocation.
const WRITE_VTS_FILES = false

func _save_to_vts():
	if not WRITE_VTS_FILES or modelmeta.studio_parameters.is_empty():
		return
	
	var vtube_data = Files.read_json(modelmeta.studio_parameters)
	# vtube_data["ParameterSettings"] = studio_parameters.map(func (x): return x.serialize())
	vtube_data["ArtMeshDetails"]["ArtMeshesExcludedFromPinning"] = get_meshes().reduce(
		func (acc, mesh):
			if mesh.name not in mesh_settings:
				return acc
			var pinnable = get("modifiers/meshes/%s/pinnable" % mesh.name)
			if pinnable:
				acc.append(mesh.name)
			return acc,
		[]
	)
	vtube_data["ArtMeshDetails"]["ArtMeshMultiplyAndScreenColors"] = get_meshes().reduce(
		func (acc, mesh):
			if mesh.name not in mesh_settings:
				return acc
			var override = get("modifiers/meshes/%s/color_override" % mesh.name)
			if override:
				acc.append({
					"ID": mesh.name,
					"Value": "%s|%s" % [
						(get("modifiers/meshes/%s/multiply_color" % mesh.name) as Color).to_html(true),
						(get("modifiers/meshes/%s/screen_color" % mesh.name) as Color).to_html(true),
					]
				})
			return acc,
		[]
	)
	vtube_data["FileReferences"]["IdleAnimation"] = get_idle_animation_player().current_animation
	
	Files.write_json(modelmeta.studio_parameters, vtube_data)
	
## load bidirectional vts compatible settings
func _load_from_vts():
	if modelmeta.studio_parameters.is_empty():
		return
	
	var vtube_data = Files.read_json(modelmeta.studio_parameters)
	
	var idle_animation = vtube_data.get("FileReferences", {}).get("IdleAnimation")
	if idle_animation:
		get_idle_animation_player().play(idle_animation)
		
	# the model's own .yori.json settings override these when it has them
	var physics_settings = vtube_data.get("PhysicsSettings", {})
	if not physics_settings.is_empty():
		physics_enabled = physics_settings.get("Use", true)
		physics_strength = float(physics_settings.get("PhysicsStrength", 50)) / 50.0
	var movement_settings = vtube_data.get("ModelPositionMovement", {})
	if not movement_settings.is_empty():
		movement_enabled = movement_settings.get("Use", false)
		movement_amount = Vector3(movement_settings.get("X", 6), movement_settings.get("Y", 8), movement_settings.get("Z", 11))
		movement_smoothing = movement_settings.get("SmoothingX", 10)

	var mesh_details = vtube_data.get("ArtMeshDetails", {})
	var pin_settings = mesh_details.get("ArtMeshesExcludedFromPinning", [])
		
	# color settings
	var tint = {}
	for v in mesh_details.get("ArtMeshMultiplyAndScreenColors", []):
		var colors = v.Value.split("|")
		tint[v.ID] = {
			"multiply": Color(colors[0]),
			"screen": Color(colors[1])
		}
	
	for mesh in get_meshes():
		if mesh.name not in mesh_settings:
			continue
		var settings = mesh_settings[mesh.name]
		var exclude = mesh.name in pin_settings
		settings.pinnable = not exclude
		
		settings.color_override = mesh.name in tint
		if mesh.name in tint:
			var colors = tint[mesh.name]
			settings.multiply_color = colors.multiply
			settings.screen_color = colors.creen
		
func save_model_settings(settings: Dictionary):
	super.save_model_settings(settings)
	
	# expression groups
	var expression_groups = {}
	for expression in get_expression_controller().expressions:
		var name = expression.get_name()
		var groups = get_expression_controller().get("expression_groups/%s" % name)
		var path = expression.resource_path.trim_prefix(modelmeta.path + "/")
		expression_groups[name] = {
			"path": path,
			"groups": groups
		}
	settings["expressions"] = expression_groups
	settings["physics"] = {"use": physics_enabled, "strength": physics_strength, "groups": physics_groups}
	
	_save_to_vts()
	
func load_model_settings(settings: Dictionary):
	_load_from_vts()
	super.load_model_settings(settings)
	var physics: Dictionary = settings.get("physics", {})
	if not physics.is_empty():
		physics_groups = physics.get("groups", {}).duplicate()
		physics_enabled = physics.get("use", true)
		physics_strength = float(physics.get("strength", 1.0))
	_apply_physics()

	for p in self.get_parameters():
		var modifier = param_settings[StringName(p)]
		var saved = settings.get("modifiers", {}).get("parameters", {}).get(p, {})
		Serializers.ObjSerializer.from_json(saved, modifier)
	
	for m in self.get_meshes():
		if m.name not in mesh_settings:
			continue
		var modifier = mesh_settings[m.name]
		var saved = settings.get("modifiers", {}).get("meshes", {}).get(m.name, {})
		# fallback to what's loaded from vts
		Serializers.ObjSerializer.from_json(saved, modifier)
		
	for p in self.get_parts():
		var modifier = part_settings[p]
		var saved = settings.get("modifiers", {}).get("parts", {}).get(p, {})
		Serializers.ObjSerializer.from_json(saved, modifier)
	
	var exp_controller = self.get_expression_controller()
	var expressions = exp_controller.expressions
	var expression_settings: Dictionary = settings.get("expressions", {})
	for e in expression_settings:
		var s = expression_settings[e]
		for expression in expressions:
			var path = self.modelmeta.path.path_join(s.get("path", "%s.exp3.json" % e))
			if e == expression.get_name() and path == expression.resource_path:
				exp_controller.set("expression_groups/%s" % e, s.get("groups", []))
				break
	
