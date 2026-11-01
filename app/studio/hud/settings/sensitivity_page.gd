## Sensitivity page (VTube Studio's parameter settings, simplified): one row per model parameter driven by
## face tracking, grouped by face part. Each row shows the live tracking value on a range bar, the band is
## the part of the input that drives the parameter's full range (narrower = more sensitive), and a
## smoothing slider. Rows edit the rangemap and smoothing nodes of the model's Musubi graphs, inserting them
## when a chain has none, so the node editor shows the same settings.
extends VBoxContainer

## tracker parameter prefix -> face part, first match wins, in display order
const PARTS = [
	["EyeOpen", "Eyes: open and close"],
	["Eye", "Eyes: gaze"],
	["Brow", "Eyebrows"],
	["MouthSmile", "Mouth: smile"],
	["MouthOpen", "Mouth: open"],
	["Mouth", "Mouth: other"],
	["Cheek", "Cheeks"],
	["FaceAngle", "Head: angle"],
	["FacePosition", "Head: position"],
	["", "Other"],
]

var model
var _list := VBoxContainer.new()
var _rows: Array = []  # [{chain, meter}]
## Live2D parameter id -> the name the model's author gave it (<name>.cdi3.json)
var _names := {}
## live FacePositionX/Y/Z next to the follow-the-face switch
var _position_label := Label.new()

func _init() -> void:
	name = "SensitivityPage"
	var hint := Label.new()
	hint.text = "The dot is your face right now. Drag the two handles to the range you actually move: a narrower range reacts more. Smoothing steadies the motion but adds delay."
	hint.theme_type_variation = &"FieldLabel"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var top := HBoxContainer.new()
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(hint)
	var calibrate := Button.new()
	calibrate.name = "CalibrateBtn"
	calibrate.text = "Auto calibrate..."
	calibrate.theme_type_variation = &"AccentButton"
	calibrate.tooltip_text = "Guides you through a few expressions and sets the ranges to how your face moves."
	calibrate.pressed.connect(calibrate_guided)
	top.add_child(calibrate)
	add_child(top)
	_build_guide()
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)
	add_child(scroll)
	visibility_changed.connect(func (): if is_visible_in_tree(): refresh())

func refresh() -> void:
	for c in _list.get_children():
		c.queue_free()
	_rows.clear()
	var stage = get_tree().get_first_node_in_group("system:stage")
	model = stage.active_model if stage else null
	if model == null:
		return
	_names = _display_names()
	var follow := Label.new()
	follow.text = "Move with your face"
	follow.theme_type_variation = &"BoldLabel"
	_list.add_child(follow)
	_list.add_child(_movement_options())
	if model.has_method("physics_group_list"):
		var physics_title := Label.new()
		physics_title.text = "Physics"
		physics_title.theme_type_variation = &"BoldLabel"
		_list.add_child(physics_title)
		_list.add_child(_physics_options())
	var by_part := {}
	for chain in chains():
		var part := _part(chain.tracker_param)
		by_part.get_or_add(part, []).append(chain)
	for p in PARTS:
		if p[1] not in by_part:
			continue
		var heading := Label.new()
		heading.text = p[1]
		heading.theme_type_variation = &"BoldLabel"
		_list.add_child(heading)
		if p[0] == "EyeOpen":
			_list.add_child(_eye_options(by_part[p[1]][0].tracker))
		for chain in by_part[p[1]]:
			_list.add_child(_row(chain))

## VTS's eye options, kept on the tracking input node of the model's graph
func _eye_options(tracker) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)
	var link := CheckButton.new()
	link.name = "LinkEyes"
	link.text = "Blink both eyes together"
	link.tooltip_text = "Both eyes follow the more closed one. Steadier blinks, but no winks."
	link.button_pressed = tracker.link_eyes
	link.toggled.connect(func (on): tracker.link_eyes = on)
	row.add_child(link)
	var auto_label := Label.new()
	auto_label.text = "Automatic blinking"
	row.add_child(auto_label)
	var auto := OptionButton.new()
	auto.name = "AutoBlink"
	for t in ["Off", "When the face is lost", "Always"]:
		auto.add_item(t)
	auto.select(tracker.auto_blink)
	auto.tooltip_text = "Blinks every few seconds on its own. When the face is lost: only while the tracker cannot see you."
	auto.item_selected.connect(func (i): tracker.auto_blink = i)
	row.add_child(auto)
	return row

## VTS's "move model with face": a switch, how far per axis and smoothing, kept in the model's settings
func _movement_options() -> Control:
	var box := VBoxContainer.new()
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 24)
	var use := CheckButton.new()
	use.name = "FollowFace"
	use.text = "Move the model with your face"
	use.tooltip_text = "Lean left or right and the model slides along, come closer and it grows."
	use.button_pressed = model.movement_enabled
	top.add_child(use)
	_position_label = Label.new()  # refresh() frees the old page, the label goes with it
	_position_label.theme_type_variation = &"SubscriptLabel"
	_position_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_position_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	top.add_child(_position_label)
	box.add_child(top)
	var grid := GridContainer.new()
	grid.name = "FollowFaceAmounts"
	grid.columns = 6  # two label, slider, value groups per row
	grid.add_theme_constant_override("h_separation", 14)
	# [label, axis or "smoothing", min, max]
	for a in [["Left and right", 0, 0.0, 20.0], ["Up and down", 1, 0.0, 20.0], ["Closer and farther", 2, -20.0, 20.0], ["Smoothing", -1, 0.0, 30.0]]:
		var label := Label.new()
		label.text = a[0]
		grid.add_child(label)
		var slider := HSlider.new()
		slider.min_value = a[2]
		slider.max_value = a[3]
		slider.step = 1
		slider.custom_minimum_size.x = 160
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.value = model.movement_smoothing if a[1] < 0 else model.movement_amount[a[1]]
		var value := Label.new()
		value.text = str(int(slider.value))
		value.custom_minimum_size.x = 28
		var axis: int = a[1]
		slider.value_changed.connect(func (v):
			value.text = str(int(v))
			if axis < 0:
				model.movement_smoothing = v
			else:
				model.movement_amount[axis] = v)
		grid.add_child(slider)
		grid.add_child(value)
	box.add_child(grid)
	grid.visible = use.button_pressed
	use.toggled.connect(func (on):
		model.movement_enabled = on
		grid.visible = on)
	return box

## physics on/off, overall strength and one slider per physics group (hair, skirt, accessories...)
func _physics_options() -> Control:
	var box := VBoxContainer.new()
	box.name = "PhysicsOptions"
	var use := CheckButton.new()
	use.name = "PhysicsToggle"
	use.text = "Use physics"
	use.tooltip_text = "Hair, clothes and accessories swing with the movement, as the model's maker set them up."
	use.button_pressed = model.physics_enabled
	box.add_child(use)
	var grid := GridContainer.new()
	grid.name = "PhysicsStrengths"
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 14)
	var groups: Array = model.physics_group_list()
	if groups.is_empty():
		var none := Label.new()
		none.text = "This model has no physics."
		none.theme_type_variation = &"SubscriptLabel"
		box.add_child(none)
		use.disabled = true
		return box
	_physics_slider(grid, tr("Overall strength"), model.physics_strength, "PhysicsStrength",
		func (v): model.physics_strength = v)
	# models have up to dozens of groups (hair strands, skirt, ribbons), folded away until wanted
	var fold := Button.new()
	fold.name = "PhysicsGroupsFold"
	fold.toggle_mode = true
	fold.flat = true
	fold.alignment = HORIZONTAL_ALIGNMENT_LEFT
	fold.text = tr("Each part (%d)") % groups.size()
	fold.icon = preload("res://ui/icons/fold_right_arrow.svg")
	var group_grid := GridContainer.new()
	group_grid.name = "PhysicsGroups"
	group_grid.columns = 3
	group_grid.add_theme_constant_override("h_separation", 14)
	group_grid.visible = false
	fold.toggled.connect(func (on):
		group_grid.visible = on
		fold.icon = preload("res://ui/icons/fold_down_arrow.svg") if on else preload("res://ui/icons/fold_right_arrow.svg"))
	for g in groups:
		var id: String = g.id
		_physics_slider(group_grid, g.name, float(model.physics_groups.get(id, 1.0)), "PhysicsGroup_%s" % id.validate_node_name(),
			func (v): model.set_physics_group(id, v))
	var settings := VBoxContainer.new()
	settings.add_child(grid)
	settings.add_child(fold)
	settings.add_child(group_grid)
	box.add_child(settings)
	settings.visible = use.button_pressed
	use.toggled.connect(func (on):
		model.physics_enabled = on
		settings.visible = on)
	return box

## a 0 to 200 % strength slider (100 % = as the model's maker simulated it)
func _physics_slider(grid: GridContainer, text: String, value: float, slider_name: String, changed: Callable) -> void:
	var label := Label.new()
	label.text = text
	label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED  # group names come from the model
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.custom_minimum_size.x = 180
	grid.add_child(label)
	var slider := HSlider.new()
	slider.name = slider_name
	slider.min_value = 0
	slider.max_value = 200
	slider.step = 5
	slider.custom_minimum_size.x = 220
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value = value * 100.0
	var shown := Label.new()
	shown.text = "%d%%" % int(slider.value)
	shown.custom_minimum_size.x = 48
	slider.value_changed.connect(func (v):
		shown.text = "%d%%" % int(v)
		changed.call(v / 100.0))
	grid.add_child(slider)
	grid.add_child(shown)

func _part(tracker_param: String) -> String:
	for p in PARTS:
		if tracker_param.begins_with(p[0]):
			return p[1]
	return "Other"

## [{graph, output, param, tracker, tracker_param, smoothing, rangemap, first (tracker -> next link), last (link into the output)}]
func chains() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for graph in model.blueprints:
		for output in graph.get_children():
			if not output.has_method("get_type") or output.get_type() != &"model_output":
				continue
			for c in graph.connections:
				if c.to_node != output.name:
					continue
				var chain := {"graph": graph, "output": output, "last": c, "smoothing": null, "rangemap": null, "tracker": null,
					"param": output.get_input_slot_name(output.get_input_slot_by_port(c.to_port))}
				var link: Dictionary = c
				for step in 12:
					var src = graph.get_node_or_null(NodePath(link.from_node))
					if src == null or not src.has_method("get_type"):
						break
					var follow := ""
					match src.get_type():
						&"tracking_input":
							chain.tracker = src
							chain.tracker_param = src.get_output_slot_name(src.get_output_slot_by_port(link.from_port))
							chain.first = link
						&"smoothing":
							chain.smoothing = src
							follow = "value"
						&"rangemap":
							chain.rangemap = src
							follow = "value"
						&"arithmetic":
							follow = "a"  # VTS blink mixing: the tracked value is input a
					if follow.is_empty():
						break
					var port: int = src.get_input_port_by_name(follow)
					var up: Array = graph.connections.filter(func (x): return x.to_node == src.name and x.to_port == port)
					if up.is_empty():
						break
					link = up[0]
				if chain.tracker:
					out.append(chain)
	return out

func _row(chain: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	var names := VBoxContainer.new()
	names.custom_minimum_size.x = 210
	var title := Label.new()
	title.text = _names.get(chain.param, chain.param)
	title.tooltip_text = chain.param
	title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	title.clip_text = true
	names.add_child(title)
	var source := Label.new()
	source.text = tr("%s from %s") % [chain.param, chain.tracker_param]
	source.theme_type_variation = &"SubscriptLabel"
	names.add_child(source)
	row.add_child(names)

	var domain: Vector2 = Registry.get(chain.tracker_param).range if Registry.get(chain.tracker_param) else Vector2(0, 1)
	var meter := RangeMeter.new()
	meter.domain = domain
	meter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var band: Vector2 = chain.rangemap.a if chain.rangemap else domain
	meter.set_band(band.x, band.y)
	meter.tooltip_text = tr("Input range %.2f to %.2f") % [band.x, band.y]
	meter.range_changed.connect(func (l, h):
		meter.tooltip_text = tr("Input range %.2f to %.2f") % [l, h]
		_set_range(chain, Vector2(l, h)))
	row.add_child(meter)

	var smooth_box := VBoxContainer.new()
	smooth_box.custom_minimum_size.x = 150
	var smooth_label := Label.new()
	smooth_label.theme_type_variation = &"SubscriptLabel"
	var smooth := HSlider.new()
	smooth.min_value = 0
	smooth.max_value = 100
	smooth.step = 1
	smooth.value = chain.smoothing.smoothing * 100.0 if chain.smoothing else 0.0
	smooth_label.text = tr("Smoothing %d%%") % smooth.value
	smooth.value_changed.connect(func (v):
		smooth_label.text = tr("Smoothing %d%%") % v
		_set_smoothing(chain, v / 100.0))
	smooth_box.add_child(smooth_label)
	smooth_box.add_child(smooth)
	row.add_child(smooth_box)
	_rows.append({"chain": chain, "meter": meter})
	return row

func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	var tracking = get_tree().get_first_node_in_group("system:tracking")
	if tracking == null:
		return
	var p: Dictionary = tracking.parameters
	if is_instance_valid(_position_label):
		_position_label.text = tr("Head %+.1f / %+.1f / %+.1f cm") % [p.get("FacePositionX", 0.0), p.get("FacePositionY", 0.0), p.get("FacePositionZ", 0.0)]
	for r in _rows:
		r.meter.value = float(tracking.parameters.get(r.chain.tracker_param, 0.0))

func _display_names() -> Dictionary:
	var out := {}
	if model.modelmeta == null or not model.modelmeta.model.ends_with(".model3.json"):
		return out
	var data = JSON.parse_string(FileAccess.get_file_as_string(model.modelmeta.model))
	if not data is Dictionary:
		return out
	var cdi: String = data.get("FileReferences", {}).get("DisplayInfo", "")
	if cdi.is_empty():
		return out
	var info = JSON.parse_string(FileAccess.get_file_as_string(model.modelmeta.model.get_base_dir().path_join(cdi)))
	if info is Dictionary:
		for p in info.get("Parameters", []):
			out[p.get("Id", "")] = String(p.get("Name", "")).replace("\u3000", " ").strip_edges()
	return out

#region guided calibration

## [id, instruction, seconds]. Samples from the last 60% of each step, after the face has changed
const STEPS = [
	["neutral", "Relax your face and look at the camera", 3.0],
	["eyes_closed", "Close both eyes", 2.5],
	["mouth_open", "Open your mouth as wide as is comfortable", 3.0],
	["smile", "Smile broadly", 3.0],
	["brows_up", "Raise your eyebrows", 3.0],
]
const MEASURED = ["EyeOpenLeft", "EyeOpenRight", "MouthOpen", "MouthSmile", "Brows"]

var _guide := PanelContainer.new()
var _guide_text := Label.new()
var _guide_bar := ProgressBar.new()
var _guide_step := Label.new()
var _cancelled := false
## the result of the last calibration, for the summary and tests
var last_calibration := {}

func _build_guide() -> void:
	_guide.name = "CalibrationGuide"
	_guide.theme_type_variation = &"SubPanelContainer"
	_guide.visible = false
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	_guide_step.theme_type_variation = &"FieldLabel"
	box.add_child(_guide_step)
	_guide_text.add_theme_font_size_override("font_size", 26)
	_guide_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_guide_text)
	_guide_bar.show_percentage = false
	_guide_bar.max_value = 1.0
	box.add_child(_guide_bar)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.size_flags_horizontal = Control.SIZE_SHRINK_END
	cancel.pressed.connect(func (): _cancelled = true)
	box.add_child(cancel)
	_guide.add_child(box)
	add_child(_guide)

## runs the steps, then narrows each measured parameter's band to the user's own movement
func calibrate_guided() -> void:
	var tracking = get_tree().get_first_node_in_group("system:tracking")
	if model == null or tracking == null:
		return
	_cancelled = false
	_guide.visible = true
	var samples := {}  # step -> param -> [values]
	for i in STEPS.size():
		var step: Array = STEPS[i]
		_guide_step.text = tr("Step %d of %d") % [i + 1, STEPS.size()]
		_guide_text.text = tr(step[1])
		var per := {}
		var start := Time.get_ticks_msec()
		var length := int(step[2] * 1000)
		while Time.get_ticks_msec() - start < length:
			await get_tree().process_frame
			if _cancelled:
				_guide.visible = false
				return
			var t := float(Time.get_ticks_msec() - start) / length
			_guide_bar.value = t
			if t >= 0.4:
				for p in MEASURED:
					per.get_or_add(p, []).append(float(tracking.parameters.get(p, 0.0)))
		samples[step[0]] = per
	_guide.visible = false
	last_calibration = _apply_calibration(samples)
	refresh()
	var parts: Array = last_calibration.applied.map(func (p): return tr(p))
	var alert = get_tree().get_first_node_in_group("system:alert")
	if alert:
		alert.alert(tr("Calibrated: %s") % ", ".join(parts) if parts else tr("No clear movement measured, nothing changed."))

func _pct(values: Array, q: float) -> float:
	if values.is_empty():
		return 0.0
	var v := values.duplicate()
	v.sort()
	return v[clampi(int(round(q * (v.size() - 1))), 0, v.size() - 1)]

## {applied: [part names], bands: {tracker param: Vector2}}
func _apply_calibration(samples: Dictionary) -> Dictionary:
	var bands := {}
	var neutral: Dictionary = samples.get("neutral", {})
	var span := func (p): return Registry.get(p).range.y - Registry.get(p).range.x
	for eye in ["EyeOpenLeft", "EyeOpenRight"]:
		var open := _pct(neutral.get(eye, []), 0.5)
		var closed := _pct(samples.get("eyes_closed", {}).get(eye, []), 0.1)
		if open - closed > 0.2 * span.call(eye):
			bands[eye] = Vector2(closed + 0.1 * (open - closed), open - 0.05 * (open - closed))
	for pair in [["MouthOpen", "mouth_open"], ["MouthSmile", "smile"], ["Brows", "brows_up"]]:
		var rest := _pct(neutral.get(pair[0], []), 0.5)
		var peak := _pct(samples.get(pair[1], {}).get(pair[0], []), 0.9)
		if peak - rest > 0.15 * span.call(pair[0]):
			bands[pair[0]] = Vector2(rest + 0.05 * (peak - rest), rest + 0.95 * (peak - rest))
	var applied := []
	for chain in chains():
		if chain.tracker_param in bands:
			_set_range(chain, bands[chain.tracker_param])
			var part := _part(chain.tracker_param)
			if part not in applied:
				applied.append(part)
	return {"applied": applied, "bands": bands}

#endregion

#region editing the graph

## a drag sends many changes while the first insert waits a frame: only the first inserts, the rest just
## leave the newest value for it to apply
func _set_range(chain: Dictionary, a: Vector2) -> void:
	chain.want_range = a
	if chain.rangemap == null:
		if chain.get("inserting_range", false):
			return
		chain.inserting_range = true
		var out_range = model.get("parameters/%s/range" % chain.param)
		var b: Vector2 = out_range if out_range is Vector2 else Vector2(0, 1)
		var domain: Vector2 = Registry.get(chain.tracker_param).range
		await _insert(chain, chain.last, &"rangemap", {"a": domain, "b": b})
		chain.inserting_range = false
	chain.rangemap.a = chain.want_range

func _set_smoothing(chain: Dictionary, amount: float) -> void:
	chain.want_smoothing = amount
	if chain.smoothing == null:
		if amount <= 0.0 or chain.get("inserting_smoothing", false):
			return
		chain.inserting_smoothing = true
		await _insert(chain, chain.first, &"smoothing", {})
		chain.inserting_smoothing = false
	chain.smoothing.smoothing = chain.want_smoothing

## puts a new node of type into the link (from -> to), returns the node
func _insert(chain: Dictionary, link: Dictionary, type: StringName, params: Dictionary):
	var graph = chain.graph
	var node = graph.spawn_action(type, model, params)
	var from = graph.get_node(NodePath(link.from_node))
	var to = graph.get_node(NodePath(link.to_node))
	node.position_offset = (from.position_offset + to.position_offset) / 2 + Vector2(0, 40)
	# a new node only has ports after the graph lays it out
	await get_tree().process_frame
	graph.disconnect_node(link.from_node, link.from_port, link.to_node, link.to_port)
	graph.invalidate_routes()
	to.unbind(to.get_input_slot_by_port(link.to_port), from)
	graph._on_connection_request(link.from_node, link.from_port, node.name, node.get_input_port_by_name("value"))
	graph._on_connection_request(node.name, node.get_output_port_by_name("value"), link.to_node, link.to_port)
	# the links the chain remembers changed, read the chain from the graph again
	for c in chains():
		if c.output == chain.output and c.param == chain.param:
			chain.merge(c, true)
	return node

#endregion
