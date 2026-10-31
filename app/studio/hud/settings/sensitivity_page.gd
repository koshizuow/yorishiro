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

func _init() -> void:
	name = "SensitivityPage"
	var hint := Label.new()
	hint.text = "The dot is your face right now. Drag the two handles to the range you actually move: a narrower range reacts more. Smoothing steadies the motion but adds delay."
	hint.theme_type_variation = &"FieldLabel"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(hint)
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
	if not is_visible_in_tree() or _rows.is_empty():
		return
	var tracking = get_tree().get_first_node_in_group("system:tracking")
	if tracking == null:
		return
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
	to.unbind(to.get_input_slot_by_port(link.to_port), from)
	graph._on_connection_request(link.from_node, link.from_port, node.name, node.get_input_port_by_name("value"))
	graph._on_connection_request(node.name, node.get_output_port_by_name("value"), link.to_node, link.to_port)
	# the links the chain remembers changed, read the chain from the graph again
	for c in chains():
		if c.output == chain.output and c.param == chain.param:
			chain.merge(c, true)
	return node

#endregion
