## Shown in the middle of the stage while no model is loaded (a new user's first start, or after the last
## model was removed): how to add a model, whether face tracking is ready, and how to handle the model.
## Hidden while the settings overlay is open.
extends CenterContainer

const YorishiroConfig = preload("res://lib/tracking/camera/yorishiro/yorishiro_config.gd")

const READY_COLOR := Color(0.4, 0.9, 0.5)
const WAIT_COLOR := Color(1, 0.8, 0.3)
const ERROR_COLOR := Color(1, 0.45, 0.45)

var _tracking: Label
var _library_btn: Button
## the library scans model folders, so it is checked when the card appears and every few seconds
var _library_check := 0.0

func _init() -> void:
	name = "WelcomeCard"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"StagePanel"
	panel.custom_minimum_size = Vector2(460, 0)
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)

	var title := Label.new()
	title.text = "Welcome to Yorishiro"
	title.theme_type_variation = &"BoldLabel"
	title.add_theme_font_size_override("font_size", 22)
	box.add_child(title)

	var model := _step(box, "1", "Add your model", "A Live2D model folder (with a .model3.json file).")
	var choose := Button.new()
	choose.name = "WelcomeImportBtn"
	choose.text = "Choose a model..."
	choose.theme_type_variation = &"AccentButton"
	choose.pressed.connect(func (): _hud().call("_on_model_btn_pressed"))
	model.add_child(choose)
	_library_btn = Button.new()
	_library_btn.name = "WelcomeLibraryBtn"
	_library_btn.text = "Your models"
	_library_btn.pressed.connect(func (): _hud().stage_models.show())
	model.add_child(_library_btn)

	var tracking := _step(box, "2", "Face tracking", "")
	_tracking = Label.new()
	_tracking.name = "WelcomeTrackingStatus"
	_tracking.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tracking.custom_minimum_size = Vector2(300, 0)
	_tracking.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tracking.add_child(_tracking)
	var settings := Button.new()
	settings.name = "WelcomeTrackingBtn"
	settings.text = "Tracking settings"
	settings.pressed.connect(func (): _hud().overlay.open_page(&"settings"))
	tracking.add_child(settings)

	_step(box, "3", "Place it", "Drag the model to move it, scroll to resize, Shift + scroll to tilt. The gear in the corner opens all settings.")

func _step(box: VBoxContainer, number: String, heading: String, text: String) -> HBoxContainer:
	var head := Label.new()
	head.text = heading
	head.theme_type_variation = &"BoldLabel"
	var num := Label.new()
	num.text = number
	num.theme_type_variation = &"SubscriptLabel"
	var row := HBoxContainer.new()
	row.add_child(num)
	row.add_child(head)
	box.add_child(row)
	if text:
		var body := Label.new()
		body.text = text
		body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.custom_minimum_size = Vector2(420, 0)
		box.add_child(body)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	box.add_child(actions)
	return actions

func _hud() -> Node:
	return find_parent("HUD")

func _process(delta: float) -> void:
	var stage = get_tree().get_first_node_in_group("system:stage")
	var hud = _hud()
	# the saved model starts loading a frame or two after start, the card must not flash before it
	if stage == null or Time.get_ticks_msec() < 1500:
		visible = false
		return
	# a model that is still loading counts, one that failed to load (queued for deletion) does not
	var loading = stage._requested_model
	loading = loading != null and is_instance_valid(loading) and not loading.is_queued_for_deletion()
	var empty: bool = stage.active_model == null and not loading
	visible = empty and hud != null and not hud.overlay.visible and not hud.stage_models.visible
	if not visible:
		_library_check = 0.0
		return
	_library_check -= delta
	if _library_check <= 0.0:
		_library_check = 3.0
		_library_btn.visible = not ModelLibrary.list().is_empty()
	_show_tracking()

## the face tracker's state in a few words, the full status is on the settings page
func _show_tracking() -> void:
	var tracking = get_tree().get_first_node_in_group("system:tracking")
	var face = tracking.get_node_or_null("FaceTracker") if tracking else null
	if face == null:
		_set_tracking(tr("No face tracking input is selected."), WAIT_COLOR)
	elif not "status" in face:
		_set_tracking(tr("Another tracking input is selected, see the tracking settings."), READY_COLOR)
	else:
		var s: Dictionary = face.status
		match s.get("state", ""):
			"running":
				if s.get("message", "") == "tracking":
					_set_tracking(tr("Ready: your face is in view."), READY_COLOR)
				else:
					_set_tracking(tr("Running, but no face is in view. Sit in front of the camera with some light on your face."), WAIT_COLOR)
			"error":
				_set_tracking(tr("Not working: %s") % YorishiroConfig.translate_message(s.get("message", "")), ERROR_COLOR)
			_:
				_set_tracking(tr("Starting the tracker. The first start takes a little longer."), WAIT_COLOR)

func _set_tracking(text: String, color: Color) -> void:
	_tracking.text = text
	_tracking.modulate = color
