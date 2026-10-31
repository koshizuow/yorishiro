extends Node

const Collections = preload("res://lib/utils/collections.gd")

## the meter shows this range (dB)
const METER_LOW_DB = -80.0
const METER_HIGH_DB = 0.0

var tracker

var _gain: HSlider
var _gate: HSlider
var _smoothing: HSlider
var _meter: ProgressBar
var _gate_mark: ColorRect

func _ready():
	var devices = AudioServer.get_input_device_list()
	for d in devices:
		%DeviceList.add_item(d)
	var box: VBoxContainer = %Enabled.get_parent()
	_meter = ProgressBar.new()
	_meter.name = "MicLevel"
	_meter.show_percentage = false
	_meter.custom_minimum_size.y = 10
	_meter.min_value = METER_LOW_DB
	_meter.max_value = METER_HIGH_DB
	_meter.tooltip_text = "Microphone level. The line is the noise gate: quieter than it, the mouth stays closed."
	_gate_mark = ColorRect.new()
	_gate_mark.color = Color(1, 0.8, 0.3)
	_gate_mark.size = Vector2(2, 10)
	_gate_mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_meter.add_child(_gate_mark)
	box.add_child(_meter)
	_gain = _slider(box, "MicGain", "Gain", -20, 30, tracker.gain_db, "dB", "Makes a quiet microphone louder.")
	_gain.value_changed.connect(func (v): tracker.gain_db = v)
	_gate = _slider(box, "MicGate", "Noise gate", -80, -10, tracker.gate_db, "dB", "Sounds quieter than this do not move the mouth, like a fan or keyboard.")
	_gate.value_changed.connect(func (v): tracker.gate_db = v)
	_smoothing = _slider(box, "MicSmoothing", "Smoothing", 0, 1, tracker.smoothing, "", "Higher is calmer, lower follows every syllable.")
	_smoothing.step = 0.05
	_smoothing.value_changed.connect(func (v): tracker.smoothing = v)

func _process(_delta: float) -> void:
	if _meter == null or not _meter.is_visible_in_tree():
		return
	_meter.value = tracker.level_db if tracker.enabled else METER_LOW_DB
	var t := inverse_lerp(METER_LOW_DB, METER_HIGH_DB, tracker.gate_db)
	_gate_mark.position = Vector2(t * _meter.size.x - 1, 0)
	_gate_mark.size.y = _meter.size.y

func _slider(box: Container, node_name: String, label_text: String, lo: float, hi: float, value: float, unit: String, tip: String) -> HSlider:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.tooltip_text = tip
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	label.custom_minimum_size.x = 120
	row.add_child(label)
	var slider := HSlider.new()
	slider.name = node_name
	slider.min_value = lo
	slider.max_value = hi
	slider.step = 1
	slider.value = value
	slider.tooltip_text = tip
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)
	var shown := Label.new()
	shown.custom_minimum_size.x = 64
	shown.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	shown.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	var show := func (v): shown.text = ("%d %s" % [v, unit]) if unit else "%.2f" % v
	show.call(value)
	slider.value_changed.connect(show)
	row.add_child(shown)
	box.add_child(row)
	return slider

func _on_enabled_toggled(toggled_on: bool) -> void:
	tracker.enabled = toggled_on

func _on_device_list_item_selected(index: int) -> void:
	tracker.device = %DeviceList.get_item_text(index)

func save_settings(settings: Dictionary):
	var trackers = settings.get("trackers", {})
	var config = trackers.get("microphone", {})
	config["enabled"] = %Enabled.button_pressed
	config["device"] = %DeviceList.get_item_text(%DeviceList.selected)
	config["gain_db"] = tracker.gain_db
	config["gate_db"] = tracker.gate_db
	config["smoothing"] = tracker.smoothing

	trackers["microphone"] = config
	settings["trackers"] = trackers

func load_settings(settings: Dictionary):
	var enabled: bool = Collections.path(settings, "trackers.microphone.enabled", false)
	%Enabled.button_pressed = enabled
	tracker.gain_db = float(Collections.path(settings, "trackers.microphone.gain_db", tracker.gain_db))
	tracker.gate_db = float(Collections.path(settings, "trackers.microphone.gate_db", tracker.gate_db))
	tracker.smoothing = float(Collections.path(settings, "trackers.microphone.smoothing", tracker.smoothing))
	if _gain:  # built in _ready from the tracker's values otherwise
		_gain.value = tracker.gain_db
		_gate.value = tracker.gate_db
		_smoothing.value = tracker.smoothing

	await get_tree().process_frame
	var device: String = Collections.path(settings, "trackers.microphone.device", "Default")
	for i in %DeviceList.item_count:
		if %DeviceList.get_item_text(i) == device:
			%DeviceList.select(i)
			break

