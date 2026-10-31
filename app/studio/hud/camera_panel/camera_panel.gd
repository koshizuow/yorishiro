extends "res://studio/hud/side_panel.gd"

const Tracker = preload("res://lib/tracking/tracker.gd")
const TrackingSystem = preload("res://lib/tracking/tracking_system.gd")
const Collections = preload("res://lib/utils/collections.gd")

const UI_THEMES: Array[Theme] = [
	preload("res://ui/themes/sakura.tres"),
]

signal update_bg_color(color: Color)

func _get_title():
	return "Settings"

func _ready() -> void:
	var face_trackers = %TrackingSource
	var tracking_system = get_tree().get_first_node_in_group("system:tracking")
	if OS.has_feature("openseeface") or OS.is_debug_build():
		face_trackers.add_item("OpenSeeFace (Webcam)")
		face_trackers.set_item_metadata(face_trackers.item_count - 1, preload("res://lib/tracking/camera/openseeface/osf_tracker.gd"))
	
	face_trackers.add_item("VTubeStudio (WiFi)")
	face_trackers.set_item_metadata(face_trackers.item_count - 1, preload("res://lib/tracking/camera/vts/vts_tracker.gd"))
	
	face_trackers.add_item("iOS BlendShapes (VTS)")
	face_trackers.set_item_metadata(face_trackers.item_count - 1, preload("res://lib/tracking/camera/vts_blendshapes/vts_tracker.gd"))

	# appended last so saved selections (stored by index) keep pointing at the same tracker
	face_trackers.add_item("Yorishiro tracker (GPU)")
	face_trackers.set_item_metadata(face_trackers.item_count - 1, preload("res://lib/tracking/camera/yorishiro/yorishiro_tracker.gd"))
	
	for tracker in tracking_system.get_children():
		var config = tracker.create_config()
		if config != null:
			%Tracking.add_child(config)
	
	Registry.parameter_list_changed.connect(
		func ():
			for c in %ParameterList.get_children():
				c.free()
			
			for i in Registry.parameters():
				var box = HBoxContainer.new()
				var l = Label.new()
				l.text = i.id
				l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				box.add_child(l)
				var v = Label.new()
				v.name = "Value"
				box.add_child(v)
				box.name = i.id
				%ParameterList.add_child.call_deferred(box)
	)
		
	if tracking_system:
		tracking_system.tracker_changed.connect(_on_tracker_system_tracker_changed)
		tracking_system.parameters_updated.connect(_on_tracker_system_parameters_updated)
		
	# conditionally handle virtual webcam controls based on platform availability
	if OS.has_feature("linux"):
		_virtual_camera_hint()
		_refresh_virtual_cameras()
		_pipewire_row.call_deferred()
	else:
		%VirtualWebcam.queue_free()
		
	%ProfileName.text = Preferences.active_file.get_file()
	%ProfileName.tooltip_text = Preferences.active_file
	Preferences.profile_changed.connect(
		func (path):
			%ProfileName.text = path.get_file()
			%ProfileName.tooltip_text = path
	)
	%ProfileOpenDialog.file_selected.connect(
		func (path):
			Preferences.change_profile(path)
	)
	%ProfileSaveDialog.file_selected.connect(
		func (path):
			Preferences.save_data() # make sure we have latest state persisted to settings
			Preferences.write_data(path)
			Preferences.change_profile(path)
	)
	%ProfileActions.get_popup().id_pressed.connect(
		func (id):
			match id:
				0: # Open
					%ProfileOpenDialog.show()
				1: # Load Default
					Preferences.change_profile(Preferences.DEFAULT_PROFILE_PATH)
				2: # Save
					Preferences.save_data()
					Preferences.write_data()
				3: # Save as
					%ProfileSaveDialog.show()
				4: # Clear Settings
					Preferences.reset()
	)
	%FovDegrees.value_changed.connect(
		func (value):
			var stage = get_tree().get_first_node_in_group("system:stage")
			stage.camera_3d.fov = value
	)
	
func _on_tracker_system_tracker_changed(new_tracker: Tracker) -> void:
	var config = Control.new()
	if new_tracker != null:
		# trackers without settings (the fixed-pose test tracker) return null
		var made = new_tracker.create_config()
		if made != null:
			config = made
	config.name = "Config"
	
	var prev_config = %FaceTracking.get_node("Config")
	if prev_config:
		%FaceTracking.remove_child(prev_config)
		prev_config.queue_free()
	
	%FaceTracking.add_child(config)

func _on_tracker_system_parameters_updated(parameters: Dictionary, _delta) -> void:
	if not is_node_ready():
		return
	if not is_visible_in_tree():
		return
	
	for p in Registry.parameters():
		var node = %ParameterList.get_node(NodePath(p.id))
		if node == null:
			continue
		node.get_node("Value").text = "%.02f" % parameters.get(p.id, 0)

func _on_preview_background_color_color_changed(color: Color) -> void:
	update_bg_color.emit(color)

func load_settings(data: Dictionary):
	_on_background_color_changed(Collections.path(data, "window.background_color", "000000"))
	_on_background_file_selected(Collections.path(data, "window.background_image", ""))
	%BackgroundModeSelector.selected = Collections.path(data, "window.background_mode", 0)
	_on_background_mode_selected(%BackgroundModeSelector.selected)

	%FPS.select(Collections.path(data, "window.fps", 0))
	_on_fps_value_item_selected(%FPS.get_selected_id())
	%UITheme.select(Collections.path(data, "window.theme", 0))
	_on_ui_theme_item_selected(%UITheme.selected)
	%FovDegrees.value = Collections.path(data, "window.fov", 10.0)
	
	var tracking_system = get_tree().get_first_node_in_group("system:tracking")
	if tracking_system:
		# settings load when the panel enters the tree, before _ready fills the tracker list, so the
		# default is looked up a frame later (it picked item 0, OpenSeeFace, for new profiles)
		await get_tree().process_frame
		var source = Collections.path(data, "trackers.source", _default_tracker_index())
		%TrackingSource.select(source)
		tracking_system.activate_tracker(
			%TrackingSource.get_selected_metadata().new()
		)

## new profiles start on the built-in Yorishiro tracker
func _default_tracker_index() -> int:
	var yorishiro = preload("res://lib/tracking/camera/yorishiro/yorishiro_tracker.gd")
	for i in %TrackingSource.item_count:
		if %TrackingSource.get_item_metadata(i) == yorishiro:
			return i
	return 0
	
func save_settings(data: Dictionary):
	var w = data.get("window", {})
	w["background_mode"] = %BackgroundModeSelector.selected
	w["background_image"] = %BackgroundImageSelector.get_meta("filepath")
	w["fps"] = %FPS.get_selected_id()
	w["theme"] = %UITheme.selected
	w["fov"] = %FovDegrees.value
	var c = data.get("trackers", {})
	c["source"] = %TrackingSource.get_selected_id()
	data["window"] = w
	data["trackers"] = c
	
func _on_fps_value_item_selected(index: int) -> void:
	match index:
		0: # 60 FPS
			Engine.max_fps = 60
		1: # 30 FPS
			Engine.max_fps = 30
		_: # Uncapped
			Engine.max_fps = 0

func _on_microphone_toggle_toggled(toggled_on: bool) -> void:
	var tracking_system = get_tree().get_first_node_in_group("system:tracking")
	if not tracking_system:
		return	
	tracking_system.get_node("MicrophoneTracker").enabled = toggled_on

## v4l2loopback devices the stage can be sent to. Creating one needs root, so without one the app only
## explains how (the switch stays off and a hint with the command shows), and can look again.
const LOOPBACK_COMMAND = "sudo modprobe v4l2loopback devices=1 video_nr=20 card_label=\"Yorishiro\" exclusive_caps=1"
## with the module already loaded (another app's loopback devices) modprobe adds nothing, a device is added instead
const LOOPBACK_ADD_COMMAND = "sudo v4l2loopback-ctl add -n Yorishiro /dev/video20"
var _vcam_hint: VBoxContainer

func _refresh_virtual_cameras() -> void:
	var v4l2_stream = get_tree().get_first_node_in_group("output:v4l2")
	var feeds = v4l2_stream.get_devices()
	%VirtualCameraDevice.clear()
	for feed in feeds:
		%VirtualCameraDevice.add_item(feed.name)
		%VirtualCameraDevice.set_item_metadata(%VirtualCameraDevice.item_count - 1, feed.id)
	var any: bool = len(feeds) > 0
	if any:
		%VirtualCameraDevice.select(0)
	%VirtualCameraDevice.visible = any
	%V4L2Toggle.disabled = not any
	_vcam_hint.visible = not any

func _virtual_camera_hint() -> void:
	_vcam_hint = VBoxContainer.new()
	_vcam_hint.name = "VirtualCameraHint"
	var text := Label.new()
	text.text = "No virtual camera device yet. Run this once in a terminal (it needs your password), then check again:"
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.theme_type_variation = &"SubscriptLabel"
	_vcam_hint.add_child(text)
	var row := HBoxContainer.new()
	var command := LineEdit.new()
	var loaded := DirAccess.dir_exists_absolute("/sys/module/v4l2loopback")
	var cmd_text := LOOPBACK_ADD_COMMAND if loaded else LOOPBACK_COMMAND
	command.text = cmd_text
	command.editable = false
	command.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(command)
	var copy := Button.new()
	copy.text = "Copy"
	copy.pressed.connect(func (): DisplayServer.clipboard_set(cmd_text))
	row.add_child(copy)
	var again := Button.new()
	again.name = "VirtualCameraRescan"
	again.text = "Check again"
	again.pressed.connect(_refresh_virtual_cameras)
	row.add_child(again)
	_vcam_hint.add_child(row)
	var row_parent: Node = %VirtualWebcam.get_parent()
	row_parent.add_child(_vcam_hint)
	row_parent.move_child(_vcam_hint, %VirtualWebcam.get_index() + 1)

## the stage to OBS as a PipeWire stream with alpha (lib/output/pipewire_output.gd)
func _pipewire_row() -> void:
	var output = get_tree().get_first_node_in_group("output:pipewire")
	if output == null:
		return
	var box := VBoxContainer.new()
	box.name = "PipeWireOutputRow"
	var toggle := CheckButton.new()
	toggle.name = "PipeWireToggle"
	toggle.text = "Send the stage to OBS (PipeWire, transparent)"
	toggle.tooltip_text = "In OBS add a \"PipeWire video\" source (obs-pwvideo plugin) and pick Yorishiro. Only the stage is sent, without buttons or settings."
	toggle.button_pressed = output.enabled
	toggle.toggled.connect(func (on): output.enabled = on)
	box.add_child(toggle)
	var state := Label.new()
	state.name = "PipeWireStatus"
	state.theme_type_variation = &"SubscriptLabel"
	state.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(state)
	var show_status := func (text: String, ok: bool):
		state.text = text
		state.visible = text != ""
		state.modulate = Color.WHITE if ok else Color(1, 0.45, 0.45)
	output.status_changed.connect(show_status)
	show_status.call(output.status, output.status_ok)
	var parent: Node = _vcam_hint.get_parent()
	parent.add_child(box)
	parent.move_child(box, _vcam_hint.get_index() + 1)

func _on_loopback_item_selected(index: int) -> void:
	_on_v4l2_toggled(%V4L2Toggle.button_pressed)

func _on_v4l2_toggled(toggled_on: bool) -> void:
	var v4l2_stream = get_tree().get_first_node_in_group("output:v4l2")
	if toggled_on:
		var index = %VirtualCameraDevice.selected
		if index >= 0:
			var device_id: String = %VirtualCameraDevice.get_item_metadata(index)
			v4l2_stream.loopback_device = device_id
			return
	v4l2_stream.loopback_device = ""

func _on_ui_theme_item_selected(index: int) -> void:
	# profiles saved before the OpenVT themes were removed may hold index 1 or 2
	if index < 0 or index >= UI_THEMES.size():
		index = 0
	get_tree().root.propagate_call("set_theme", [UI_THEMES[index]], true)

func _on_background_mode_selected(index: int) -> void:
	%BackgroundImage.visible = index == 1
	%BackgroundColor.visible = index == 2
	
	var stage = get_tree().get_first_node_in_group("system:stage")
	if stage:
		stage.background_mode = index
	
func _on_background_image_selector_pressed() -> void:
	%BackgroundImageSelector/FileDialog.show()

func _on_background_file_selected(path: String) -> void:
	var stage = get_tree().get_first_node_in_group("system:stage")
	if not stage:
		return
	
	stage.background_image = path
	if stage.background_image != path:  # check if file is valid
		return
	%BackgroundImageSelector.text = path.get_file()
	%BackgroundImageSelector.set_meta("filepath", path)

func _on_background_color_changed(color: Color) -> void:
	var stage = get_tree().get_first_node_in_group("system:stage")
	if stage:
		stage.background_color = color

func _on_application_scale_item_selected(index: int) -> void:
	var SCALE_FACTOR = [
		0.5, 1.0, 1.5, 2.0, 3.0, 4.0
	][index]
	ProjectSettings.set_setting("display/window/stretch/scale", SCALE_FACTOR)
	
	get_window().content_scale_factor = SCALE_FACTOR
	get_tree().root.propagate_call(
		"set_content_scale_factor", [SCALE_FACTOR]
	)

func _on_tracking_source_item_selected(index: int) -> void:
	var _tracker = %TrackingSource.get_item_metadata(index)
	var tracking_system = get_tree().get_first_node_in_group("system:tracking")
	tracking_system.activate_tracker(_tracker.new())
