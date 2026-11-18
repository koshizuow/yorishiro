extends Node

const GROUP_NAME = "system:stage"

const Collections = preload("res://lib/utils/collections.gd")
const VtObject = preload("res://lib/vtobject.gd")
const VtModel = preload("res://lib/model/vt_model.gd")
const VtItem = preload("res://lib/items/vt_item.gd")
const AnimFrames = preload("res://lib/utils/anim_frames.gd")
const PipeWireOutput = preload("res://lib/output/pipewire_output.gd")
const VtsPins = preload("res://lib/items/vts_pins.gd")

const INDEX_RANGE = 30

var background_mode: int :
	set(mode):
		var transparent = mode == 3
		%Bg.visible = not transparent
		if is_inside_tree():
			get_tree().root.transparent_bg = transparent
			get_window().transparent = transparent
			get_window().transparent_bg = transparent
		
		%Bg/BackgroundImage.visible = mode == 1
		%Bg/DefaultBackground.visible = mode == 0 or (background_image.is_empty() and mode == 1)
		%Bg/GridFill.visible = mode == 0 or (background_image.is_empty() and mode == 1)
		%Bg/ColorFill.visible = mode == 2
		background_mode = mode
		_sync_camera_background()

var background_image: String = "" :
	set(path):
		if path.is_empty():
			%Bg/DefaultBackground.visible = true
			%Bg/GridFill.visible = true
			background_image = path
			_sync_camera_background()
			return

		# a still picture, or an animated GIF, APNG or WebP
		var tex := AnimFrames.load_texture(path)
		if tex == null:
			return
		%Bg/BackgroundImage.texture = tex
		background_image = path
		
		if background_mode == 1:
			%Bg/DefaultBackground.visible = false
			%Bg/GridFill.visible = false
		_sync_camera_background()
		
var background_color: Color = Color.BLACK :
	set(color):
		%Bg/ColorFill.color = color
		background_color = color
		_sync_camera_background()

var active_model: VtModel
## the last model asked for, a slower earlier load is dropped when it finishes
var _requested_model: VtModel
@onready var canvas = %ModelLayer
@onready var capture_viewport = %SubViewport
@onready var camera_3d = %Camera3D

signal model_changed(model: VtModel)
signal item_added(item: VtItem)
signal item_removed(item: VtItem)

## the models and items on the stage (not the model's front layer sprites, lib/items/model_layers.gd)
var objects: Array :
	get():
		return canvas.get_children().filter(func (c): return c is VtObject)

func _ready() -> void:
	var layers = preload("res://lib/items/model_layers.gd").new()
	layers.name = "ModelLayers"
	layers.stage = self
	add_child(layers)
	_stage_size = Vector2(capture_viewport.size)
	capture_viewport.size_changed.connect(_on_stage_resized)
	_setup_camera_view()
	# the stage to OBS with alpha: PipeWire on Linux, else what the platform layer (lib/platform.gd) has
	if OS.has_feature("linux"):
		_stage_out = PipeWireOutput.new()
		add_child(_stage_out)
	else:
		_stage_out = Platform.call_hook("stage_output")
		if _stage_out:
			add_child(_stage_out)
	# allow items to be dropped onto the window to spawn instantly
	get_window().files_dropped.connect(
		func (paths):
			var item = await ItemManager.create_item(paths)
			if item:
				spawn_item(item)
	)

var _stage_size := Vector2.ZERO

## the model and items keep their place and size relative to the stage when it is resized (the window, or the
## display scale applied after start), as in VTube Studio
func _on_stage_resized() -> void:
	var new_size := Vector2(capture_viewport.size)
	_camera_view.size = capture_viewport.size
	if _stage_size.x > 0 and _stage_size.y > 0 and new_size.x > 0 and new_size.y > 0 and new_size != _stage_size:
		var k := new_size / _stage_size
		for o in canvas.get_children():
			if o is VtItem and o.pinned_to != null and o.pin_mode == VtItem.PinMode.VERTICES:
				continue  # sized and placed from the model every frame, and the model is scaled here
			if o is Node2D or o is Control:
				o.position *= k
				o.scale *= k.y
	_stage_size = new_size

## the stage's pace while the window cannot draw (16 ms: 60 fps)
const HIDDEN_FRAME_MS = 16
var _next_hidden_draw := 0
@onready var _camera_view: SubViewport = %CameraView
# without the virtualcamera addon (builds for other systems) the node loads as a plain Node
@onready var _vcam = _camera_view.get_node_or_null("VirtualCamera") if ClassDB.class_exists(&"VirtualCamera") else null
var _camera_bg: CanvasLayer
var _stage_out

## The virtual camera has no alpha, so it gets the stage over the chosen background, in a view of its own. The other
## outputs keep the stage alone with alpha. The transparent mode shows over black.
func _setup_camera_view() -> void:
	_camera_view.size = capture_viewport.size
	%StageImage.texture = capture_viewport.get_texture()
	_camera_bg = %Bg.duplicate()
	_camera_bg.name = "Background"
	_camera_bg.layer = 1   # over Black, under StageLayer
	_camera_view.add_child(_camera_bg)
	_camera_view.move_child(_camera_bg, 1)
	_sync_camera_background()

func _sync_camera_background() -> void:
	if _camera_bg == null:
		return
	_camera_bg.visible = %Bg.visible
	for shown in %Bg.get_children():
		var copy = _camera_bg.get_node(NodePath(shown.name))
		copy.visible = shown.visible
		if shown is TextureRect:
			copy.texture = shown.texture
		elif shown is ColorRect:
			copy.color = shown.color

## A window that is fully covered, minimized or on another workspace gets no frame events on Wayland and Godot stops
## drawing: the stage froze in OBS and the virtual camera, usually with OBS itself on top. They still need frames.
func _process(_delta: float) -> void:
	var camera_on: bool = _vcam != null and not _vcam.loopback_device.is_empty()
	_camera_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if camera_on else SubViewport.UPDATE_DISABLED
	var outputs: bool = camera_on or (_stage_out != null and _stage_out.running)
	if not outputs or DisplayServer.window_can_draw(get_window().get_window_id()):
		return
	if Time.get_ticks_msec() >= _next_hidden_draw:
		_next_hidden_draw = Time.get_ticks_msec() + HIDDEN_FRAME_MS
		RenderingServer.force_draw(false)

func spawn_model(model: VtModel):
	if model == null:
		push_warning("invalid model attempted to load")
		return
	_requested_model = model
	
	var prev_model
	if active_model != null:
		await Preferences.save_data()
		prev_model = active_model
		var t = create_tween().tween_property(
			active_model, "position", Vector2(0, (active_model.size.y * active_model.scale.y) + active_model.get_viewport_rect().size.y), 0.5
		).as_relative().set_trans(Tween.TRANS_CUBIC)
		await t.finished
		# clear all pinned items
		for i in canvas.get_children():
			if i is VtItem:
				i.model = null
				if i.pinned_to != null:
					remove_item(i, false)
		
		canvas.remove_child.call_deferred(active_model)
		
	model.position = Vector2.INF # initialize offscreen
	canvas.add_child(model)
	
	await model.loaded
	
	# another spawn started while this one loaded (the saved model at startup and a model picked
	# or passed with --model right away), both stayed on stage before
	if model != _requested_model:
		canvas.remove_child(model)
		model.queue_free()
		return
	
	if model.is_queued_for_deletion():
		get_tree().get_first_node_in_group("system:alert").alert("Unable to load model")	
		return
	active_model = model
	
	create_tween().tween_property(
		model, "position",
		model.position,
		0.5
	).from(
		model.position + Vector2(0, model.get_viewport_rect().size.y)
	).set_trans(Tween.TRANS_CUBIC)

	# make carried over objects aware of the new model
	for i in canvas.get_children():
		if i is VtItem:
			i.model = model
			# remove an item if it was pinned to the previous model
			if i.pinned_to != null:
				remove_item(i, false)

	model_changed.emit(active_model)
	await restore_pinned_items(model)
	if prev_model != null and not prev_model.is_queued_for_deletion():
		prev_model.queue_free()

## the model's pinned items: those saved with it, else the ones VTube Studio pinned (items_pinned_to_model.json)
func restore_pinned_items(model) -> void:
	var specs = model.saved_items
	if specs == null:
		specs = VtsPins.import_vts(model)
		if not specs.is_empty():
			print("pinned items from VTube Studio: %d" % specs.size())
	for spec in specs:
		if not spec is Dictionary:
			continue
		var paths := PackedStringArray(Array(spec.get("paths", [])).map(func (p): return Preferences.resolve(str(p))))
		if paths.is_empty() or not (FileAccess.file_exists(paths[0]) or DirAccess.dir_exists_absolute(paths[0])):
			push_warning("pinned item is gone: %s" % [spec.get("paths")])
			continue
		var item: VtItem = await ItemManager.create_item(paths)
		if item == null:
			continue
		if model != active_model or not is_instance_valid(model):
			item.queue_free()
			return
		spawn_item(item, false, false)
		if not VtsPins.apply(item, model, spec):
			push_warning("could not pin %s to %s" % [paths[0].get_file(), spec.get("mesh")])
			remove_item(item, false)
			continue
		var order := int(spec.get("order", 1))
		item.set_meta("order", order)
		if order < 0:  # behind the model, as in VTube Studio
			canvas.move_child(item, model.get_index())
	model.items_restored = true

## items on the stage that are not pinned, as saved with the window settings
func _loose_item_specs() -> Array:
	var out := []
	var view := get_viewport().get_visible_rect().size
	for i in canvas.get_children():
		if i is VtItem and i.pinned_to == null and not i.is_queued_for_deletion() and i.group_name == &"":
			out.append({
				"paths": Array(i.path).map(func (p): return Preferences.portable(p)),
				# parts of the view, so another window size keeps the layout
				"x": i.position.x / view.x, "y": i.position.y / view.y,
				"scale": i.scale.x / view.y, "rotation": i.rotation, "flip": i.mirror,
			})
	return out

## the saved model, then the loose items saved with it (not awaited by load_settings, as before)
func _spawn_with_items(model, items: Array) -> void:
	await spawn_model(model)
	if active_model == model:
		await _restore_loose_items(items)

func _restore_loose_items(specs: Array) -> void:
	var view := get_viewport().get_visible_rect().size
	for spec in specs:
		if not spec is Dictionary:
			continue
		var paths := PackedStringArray(Array(spec.get("paths", [])).map(func (p): return Preferences.resolve(str(p))))
		if paths.is_empty() or not (FileAccess.file_exists(paths[0]) or DirAccess.dir_exists_absolute(paths[0])):
			continue
		var item: VtItem = await ItemManager.create_item(paths)
		if item == null or active_model == null:
			continue
		item.model = active_model
		item.position = Vector2(float(spec.get("x", 0.5)) * view.x, float(spec.get("y", 0.5)) * view.y)
		item.scale = Vector2.ONE * float(spec.get("scale", 0.001)) * view.y
		item.rotation = float(spec.get("rotation", 0.0))
		item.mirror = bool(spec.get("flip", false))
		spawn_item(item, false, false)

func spawn_item(item: VtItem, animate = true, reposition = true):
	# do not allow spawning items if there is no active model
	if active_model == null:
		return
		
	# position to center of screen
	if reposition:
		var viewport_rect = get_viewport().get_visible_rect()
		item.model = active_model
		item.scale = Vector2.ONE * min(
			clampf(viewport_rect.size.y / item.size.y, 0.001, 1.0),
			1.0
		)
		item.global_position = (viewport_rect.size / 2) - (item.scale * item.center)
	
	# simply setting z_index does not work for control nodes, as Input order is not affected by it
	# instead we'll rely on child order in the stage to define the position
	if item.get_parent():
		item.reparent(canvas)
	else:
		canvas.add_child(item)
	item_added.emit(item)
	item.request_delete.connect(remove_item.bind(item))
	
	if not animate:
		return
	
	var t = create_tween()
	t.parallel().tween_property(
		item, "scale", item.scale, 0.4
	).from(Vector2.ONE * 0.3).set_trans(Tween.TRANS_CIRC)
	#t.parallel().tween_property(
	#	item, "rotation_degrees", 0, 0.4
	#).from(60).set_trans(Tween.TRANS_QUAD)
	t.parallel().tween_property(
		item, "modulate", Color.WHITE, 0.4
	).from(Color.TRANSPARENT).set_ease(Tween.EASE_IN)

func remove_item(item: VtItem, animated = true):
	item_removed.emit(item)
	if animated:
		var t = create_tween()
		t.parallel().tween_property(
			item, "scale", item.scale * 0.3, 0.4
		).from(item.scale).set_trans(Tween.TRANS_CIRC)
		#t.parallel().tween_property(
		#	item, "rotation_degrees", 0, 0.4
		#).from(60).set_trans(Tween.TRANS_QUAD)
		t.parallel().tween_property(
			item, "modulate", Color.TRANSPARENT, 0.4
		).from(Color.WHITE).set_ease(Tween.EASE_IN)
		t.finished.connect(item.queue_free)
	else:
		item.queue_free()
	
func clear_items(group_name: StringName = &"*"):
	for i in canvas.get_children():
		if i is VtItem:
			if group_name == &"*" or i.group_name == group_name:
				remove_item(i)

func load_settings(data):
	self.background_image = Collections.path(data, "window.background_image", "")
	self.background_color = Color(Collections.path(data, "window.background_color", "000000"))
	self.background_mode = Collections.path(data, "window.background_mode", 0)
	
	if "active_model" in data:
		await get_tree().process_frame
		var path = Preferences.resolve(data["active_model"])
		if not FileAccess.file_exists(path):
			push_warning("last used model is gone: ", data["active_model"])
			return
		var mm = get_tree().get_first_node_in_group("system:model")
		var model = mm.make_model(path)
		if model:
			_spawn_with_items(model, data.get("items", []))
	
	
func save_settings(data):
	if active_model != null and active_model.modelmeta != null:
		data["active_model"] = Preferences.portable(active_model.modelmeta.model)
	data["items"] = _loose_item_specs()
	
	var window_settings = data.get("window", {})
	window_settings["transparent"] = %Bg.visible
	window_settings["background_mode"] = background_mode
	window_settings["background_image"] = background_image
	window_settings["background_color"] = background_color.to_html()
	data["window"] = window_settings
	
func _on_model_layer_child_order_changed() -> void:
	for i in canvas.get_children():
		if "sort_order" in i:  # not the model's front layer sprites (lib/items/model_layers.gd)
			i.sort_order = i.get_index()
