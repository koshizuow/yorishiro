## Settings panel for the Yorishiro tracker input: status, a 3D head showing what is tracked (never the camera
## picture), pickers, log.
extends VBoxContainer

const STATE_COLORS = {"running": Color(0.4, 0.9, 0.5), "starting": Color(1, 0.8, 0.3), "error": Color(1, 0.4, 0.4)}

var tracker

var _state: Label
var _details: Label
var _preview: FacePreview
var _camera: OptionButton
var _model: OptionButton
var _runtime: OptionButton
var _log: TextEdit

func _ready():
	size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_state = Label.new()
	_state.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_state)
	_details = Label.new()
	_details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_details.add_theme_font_size_override("font_size", 12)
	add_child(_details)

	_preview = FacePreview.new()
	_preview.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	add_child(_preview)

	_camera = _picker("Camera")
	for cam in _list_cameras():
		_camera.add_item(cam[1], cam[0])
	if _camera.item_count == 0:
		_camera.add_item("no camera found", 0)
	_select_id(_camera, tracker.camera)

	_model = _picker("Tracker")
	_model.add_item(tracker.tracker_name)
	_model.set_item_metadata(0, tracker.tracker_name)
	_load_tracker_list()

	_runtime = _picker("Compute")
	for r in tracker.RUNTIMES:
		_runtime.add_item(r)
	_select_text(_runtime, tracker.runtime)

	_lost_options()

	for b in [["Restart tracker", _on_restart], ["Recalibrate (look straight, relax)", tracker.calibrate]]:
		var button = Button.new()
		button.text = b[0]
		button.pressed.connect(b[1])
		add_child(button)

	var log_title = Label.new()
	log_title.text = "Tracker log"
	add_child(log_title)
	_log = TextEdit.new()
	_log.editable = false
	_log.custom_minimum_size = Vector2(0, 140)
	_log.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_log.add_theme_font_size_override("font_size", 11)
	add_child(_log)

	tracker.status_changed.connect(_on_status)
	tracker.log_changed.connect(_on_log)
	_on_status(tracker.status)
	_on_log(tracker.log_lines)

func _picker(title: String) -> OptionButton:
	var row = HBoxContainer.new()
	var label = Label.new()
	label.text = title
	label.custom_minimum_size = Vector2(70, 0)
	row.add_child(label)
	var option = OptionButton.new()
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option.clip_text = true
	option.item_selected.connect(func (_i): _on_restart())
	row.add_child(option)
	add_child(row)
	return option

## VTS's tracking-lost choice: freeze, or ease back to the resting pose after a delay
func _lost_options():
	var row = HBoxContainer.new()
	var label = Label.new()
	label.text = "When the face is lost"
	row.add_child(label)
	var mode = OptionButton.new()
	mode.name = "WhenLost"
	mode.add_item("Return to the resting pose")
	mode.add_item("Freeze in the last pose")
	# items in display order, the enum is FREEZE, REST
	mode.select(0 if tracker.when_lost == tracker.WhenLost.REST else 1)
	row.add_child(mode)
	var after = Label.new()
	after.text = "after"
	row.add_child(after)
	var delay = SpinBox.new()
	delay.name = "LostDelay"
	delay.min_value = 0.0
	delay.max_value = 10.0
	delay.step = 0.5
	delay.suffix = "s"
	delay.value = tracker.lost_delay
	delay.editable = tracker.when_lost == tracker.WhenLost.REST
	row.add_child(delay)
	mode.item_selected.connect(func (i):
		tracker.when_lost = tracker.WhenLost.REST if i == 0 else tracker.WhenLost.FREEZE
		delay.editable = i == 0
		tracker.save_settings())
	delay.value_changed.connect(func (v):
		tracker.lost_delay = v
		tracker.save_settings())
	add_child(row)

func _on_restart():
	tracker.camera = _camera.get_selected_id()
	tracker.tracker_name = _model.get_item_metadata(_model.selected)
	tracker.runtime = _runtime.get_item_text(_runtime.selected)
	tracker.save_settings()
	tracker.restart()

func _on_status(s: Dictionary):
	var state = s.get("state", "")
	_state.text = "%s: %s" % [state.capitalize(), s.get("message", "")]
	_state.modulate = STATE_COLORS.get(state, Color.WHITE)
	var parts = []
	if s.has("fps"):
		parts.append("%.0f fps, %.1f ms" % [s["fps"], s.get("infer_ms", 0)])
	if s.has("calibrated"):
		parts.append("calibrated" if s["calibrated"] else "calibrating, keep a neutral face")
	if s.has("runtime"):
		parts.append(s["runtime"])
	if s.get("commercial_use") == false:
		parts.append("NON-COMMERCIAL model")
	if not tracker.is_managed() and state != "error":
		parts.append("external tracker")
	_details.text = "  |  ".join(parts)

func _on_log(lines: PackedStringArray):
	_log.text = "\n".join(lines)
	_log.scroll_vertical = _log.get_line_count()

## V4L2 capture devices as [index, name]. Metadata nodes (index > 0 in sysfs) are skipped.
func _list_cameras() -> Array:
	var cams = []
	var dir = DirAccess.open("/sys/class/video4linux")
	if dir == null:
		return cams
	for dev in dir.get_directories():
		var base = "/sys/class/video4linux/%s/" % dev
		if FileAccess.get_file_as_string(base + "index").strip_edges() != "0":
			continue
		var name = FileAccess.get_file_as_string(base + "name").strip_edges()
		cams.append([int(dev.trim_prefix("video")), "%s (%s)" % [name, dev]])
	cams.sort_custom(func (a, b): return a[0] < b[0])
	return cams

func _load_tracker_list():
	var cmd = tracker.tracker_command()
	if not FileAccess.file_exists(cmd):
		return
	var thread = Thread.new()
	# the panel may be freed before the list arrives, so the result goes through a weak reference
	var panel = weakref(self)
	var deliver = Callable(get_script(), "_deliver_trackers")
	thread.start(func ():
		var out = []
		OS.execute(cmd, ["trackers", "--json"], out)
		deliver.call_deferred(panel, out[0] if out else "", thread)
	)

static func _deliver_trackers(panel: WeakRef, json: String, thread: Thread):
	thread.wait_to_finish()
	var me = panel.get_ref()
	if me:
		me._fill_trackers(json)

func _fill_trackers(json: String):
	var list = JSON.parse_string(json)
	# the list loads on a thread, the tracker may have been switched away and freed meanwhile
	if typeof(list) != TYPE_ARRAY or not is_inside_tree() or not is_instance_valid(tracker):
		return
	_model.clear()
	for t in list:
		if t.has("error"):
			continue
		_model.add_item(t["name"] if t.get("commercial_use", true) else "%s (non-commercial)" % t["name"])
		_model.set_item_metadata(_model.item_count - 1, t["name"])
		_model.set_item_tooltip(_model.item_count - 1, "%s\n%s" % [t.get("description", ""), t.get("license", "")])
	for i in _model.item_count:
		if _model.get_item_metadata(i) == tracker.tracker_name:
			_model.select(i)

func _select_id(option: OptionButton, id: int):
	var i = option.get_item_index(id)
	if i >= 0:
		option.select(i)

func _select_text(option: OptionButton, text: String):
	for i in option.item_count:
		if option.get_item_text(i) == text:
			option.select(i)
