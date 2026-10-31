## VTube Studio style hotkey list on top of the model's Musubi graphs. A hotkey is an expression or
## animation node with a key node (hotkey) and/or a screen button node wired into it, in any graph, so
## hotkeys imported from VTS and ones made in the node editor show up here, and edits here show up there.
## New hotkeys go into a graph named "Hotkeys".
extends VBoxContainer

const GRAPH_NAME = "Hotkeys"
const BlueprintScene = preload("res://lib/blueprints/blueprint.tscn")
const MODIFIERS = [KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META]

var model
var _rows := VBoxContainer.new()
var _empty := Label.new()
## the key button waiting for a key, and its entry
var _listening: Button
var _listening_entry: Dictionary

func _init() -> void:
	name = "HotkeyList"
	add_theme_constant_override("separation", 10)
	var header := HBoxContainer.new()
	for t in [["Action", 3.0], ["Keys", 2.0], ["Hold", 0.0], ["Screen button", 1.2], ["", 0.0]]:
		var l := Label.new()
		l.text = t[0]
		l.theme_type_variation = &"FieldLabel"
		if t[1] > 0:
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			l.size_flags_stretch_ratio = t[1]
		else:
			l.custom_minimum_size.x = 64 if t[0] else 40
		header.add_child(l)
	add_child(header)
	_rows.add_theme_constant_override("separation", 6)
	add_child(_rows)
	_empty.text = "No hotkeys yet. Add one to switch an expression or play an animation with a key."
	_empty.theme_type_variation = &"FieldLabel"
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_empty)
	var add := Button.new()
	add.name = "AddHotkeyBtn"
	add.text = "Add hotkey"
	add.icon = preload("res://ui/icons/plus.svg")
	add.theme_type_variation = &"AccentButton"
	add.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	add.pressed.connect(_add)
	add_child(add)

func refresh() -> void:
	_stop_listening()
	for r in _rows.get_children():
		r.queue_free()
	var stage = get_tree().get_first_node_in_group("system:stage")
	model = stage.active_model if stage else null
	var entries := entries() if model else []
	for e in entries:
		_rows.add_child(_row(e))
	_empty.visible = entries.is_empty()

## [{graph, target, kind (&"expression" or &"animation"), key (node or null), button (node or null), hold}]
func entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for graph in model.blueprints:
		for target in graph.get_children():
			if not target.has_method("get_type") or target.get_type() not in [&"expression", &"animation"]:
				continue
			var e := {"graph": graph, "target": target, "kind": target.get_type(), "key": null, "button": null, "hold": false}
			for c in graph.connections:
				if c.to_node != target.name:
					continue
				var src = graph.get_node_or_null(NodePath(c.from_node))
				if src == null or not src.has_method("get_type"):
					continue
				match src.get_type():
					&"hotkey":
						e.key = src
						if c.from_port == 1:
							e.hold = true
					&"screen_button":
						e.button = src
			if e.key or e.button:
				out.append(e)
	return out

func _row(e: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()

	var action := OptionButton.new()
	action.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action.size_flags_stretch_ratio = 3.0
	action.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	var choices := _choices()
	for c in choices:
		action.add_item(c.label)
	action.select(choices.find_custom(func (c): return c.kind == e.kind and c.name == _target_name(e)))
	action.item_selected.connect(func (i): _set_action(e, choices[i].kind, choices[i].name))
	row.add_child(action)

	var keys := Button.new()
	keys.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	keys.size_flags_stretch_ratio = 2.0
	keys.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	keys.text = _keys_text(e)
	keys.tooltip_text = tr("Click, then press the keys. Esc cancels, Backspace clears.")
	keys.pressed.connect(func (): _listen(keys, e))
	row.add_child(keys)

	var hold := CheckBox.new()
	hold.custom_minimum_size.x = 64
	hold.button_pressed = e.hold
	hold.tooltip_text = tr("On: active only while the keys are held. Off: each press toggles.")
	hold.toggled.connect(func (on): e.hold = on; _wire_key(e))
	row.add_child(hold)

	var screen := OptionButton.new()
	screen.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	screen.size_flags_stretch_ratio = 1.2
	screen.add_item(tr("None"))
	for i in 8:
		screen.add_item(str(i + 1))
	screen.select(_button_index(e) + 1)
	screen.item_selected.connect(func (i): _set_screen_button(e, i - 1))
	row.add_child(screen)

	var delete := Button.new()
	delete.icon = preload("res://ui/icons/xmark.svg")
	delete.flat = true
	delete.custom_minimum_size.x = 40
	delete.tooltip_text = tr("Delete hotkey")
	delete.pressed.connect(func (): _delete(e))
	row.add_child(delete)
	return row

## everything a hotkey can trigger on this model
func _choices() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var controller = model.get_expression_controller() if model.has_method("get_expression_controller") else null
	if controller:
		for x in controller.expressions:
			out.append({"kind": &"expression", "name": x.get_name(), "label": tr("Expression: %s") % x.get_name()})
	for m in model.motions:
		# RESET is Godot's rest pose track, not a motion of the model
		if m == "RESET":
			continue
		out.append({"kind": &"animation", "name": m, "label": tr("Animation: %s") % m})
	return out

func _target_name(e: Dictionary) -> String:
	if e.kind == &"expression":
		return e.target.expression
	var anim: OptionButton = e.target.get_node("%Animation")
	return anim.get_item_text(anim.selected) if anim.selected >= 0 else ""

func _keys_text(e: Dictionary) -> String:
	if e.key == null:
		return tr("Set keys")
	var keys: Array = e.key.get_node("%Handler").input_as_list
	return " + ".join(keys) if keys else tr("Set keys")

func _button_index(e: Dictionary) -> int:
	if e.button == null:
		return -1
	return e.button.get_node("%Mapping").get_children().find_custom(func (b): return b.button_pressed)

#region editing the graph

func _graph():
	for g in model.blueprints:
		if g.name == GRAPH_NAME:
			return g
	var g = BlueprintScene.instantiate()
	g.name = GRAPH_NAME
	model.blueprints = [g]
	return g

## new nodes get their ports when the graph lays them out, callers wait a frame before wiring
func _spawn(graph, type: StringName):
	var node = graph.spawn_action(type, model)
	# stack new nodes in rows so the node editor stays readable
	var count: int = graph.get_child_count()
	node.position_offset = Vector2(0 if type in [&"hotkey", &"screen_button"] else 420, count * 70)
	return node

func _add() -> void:
	var choices := _choices()
	if model == null or choices.is_empty():
		get_tree().get_first_node_in_group("system:alert").alert(tr("This model has no expressions or animations."))
		return
	var graph = _graph()
	var target = _spawn(graph, choices[0].kind)
	var e := {"graph": graph, "target": target, "kind": choices[0].kind, "key": null, "button": null, "hold": false}
	e.key = _spawn(graph, &"hotkey")
	await get_tree().process_frame
	_apply_target(e, choices[0].name)
	_wire_key(e)
	refresh()

func _apply_target(e: Dictionary, target_name: String) -> void:
	if e.kind == &"expression":
		e.target.expression = target_name
	else:
		var anim: OptionButton = e.target.get_node("%Animation")
		for i in anim.item_count:
			if anim.get_item_text(i) == target_name:
				anim.select(i)
				anim.item_selected.emit(i)

func _set_action(e: Dictionary, kind: StringName, target_name: String) -> void:
	if kind != e.kind:
		# another node type: replace the target and wire the same key and screen button into it
		var old = e.target
		_disconnect_all(e.graph, old)
		e.target = _spawn(e.graph, kind)
		e.target.position_offset = old.position_offset
		e.kind = kind
		old.queue_free()
		await get_tree().process_frame
		_wire_key(e)
		_wire_button(e)
	_apply_target(e, target_name)

## toggle: pressed goes to the toggle input. Hold: pressed turns on, released turns off (or stops)
func _wire_key(e: Dictionary) -> void:
	if e.key == null:
		return
	var graph = e.graph
	for c in graph.connections.duplicate():
		if c.from_node == e.key.name and c.to_node == e.target.name:
			_unwire(graph, c)
	var ports := [[0, 0]]
	if e.hold:
		ports = [[0, 1], [1, 2]] if e.kind == &"expression" else [[0, 0], [1, 1]]
	for p in ports:
		graph._on_connection_request(e.key.name, p[0], e.target.name, p[1])

func _wire_button(e: Dictionary) -> void:
	if e.button:
		e.graph._on_connection_request(e.button.name, 0, e.target.name, 0)

func _set_screen_button(e: Dictionary, index: int) -> void:
	if index < 0:
		if e.button:
			_disconnect_all(e.graph, e.button)
			e.button.queue_free()
			e.button = null
		return
	if e.button == null:
		e.button = _spawn(e.graph, &"screen_button")
		await get_tree().process_frame
		_wire_button(e)
	e.button.get_node("%Mapping").get_child(index).button_pressed = true

func _set_keys(e: Dictionary, keys: Array) -> void:
	if e.key == null:
		e.key = _spawn(e.graph, &"hotkey")
		await get_tree().process_frame
		_wire_key(e)
	var handler = e.key.get_node("%Handler")
	handler.button_1 = keys[0] if keys.size() > 0 else ""
	handler.button_2 = keys[1] if keys.size() > 1 else ""
	handler.button_3 = keys[2] if keys.size() > 2 else ""
	e.key.get_node("%Input").text = " + ".join(handler.input_as_list)

func _delete(e: Dictionary) -> void:
	for n in [e.key, e.button, e.target]:
		if n:
			_disconnect_all(e.graph, n)
			n.queue_free()
	await get_tree().process_frame
	refresh()

## like the graph's own disconnection, but with the node's port map: graphs stay hidden, and GraphNode
## only knows its ports after a layout, so the engine lookup fails for nodes made since
func _unwire(graph, c: Dictionary) -> void:
	graph.disconnect_node(c.from_node, c.from_port, c.to_node, c.to_port)
	var source = graph.get_node_or_null(NodePath(c.from_node))
	var target = graph.get_node_or_null(NodePath(c.to_node))
	if source and target:
		target.unbind(target.get_input_slot_by_port(c.to_port), source)

## for a node about to be freed: plain disconnects, its partners need no unbinding (they go too, or they
## only receive triggers)
func _disconnect_all(graph, node) -> void:
	for c in graph.connections.duplicate():
		if c.from_node == node.name or c.to_node == node.name:
			graph.disconnect_node(c.from_node, c.from_port, c.to_node, c.to_port)

#endregion

#region key capture

func _listen(button: Button, e: Dictionary) -> void:
	_stop_listening()
	_listening = button
	_listening_entry = e
	button.text = tr("Press keys...")

func _stop_listening() -> void:
	if _listening and is_instance_valid(_listening):
		_listening.text = _keys_text(_listening_entry)
	_listening = null

func _input(event: InputEvent) -> void:
	if _listening == null or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	get_viewport().set_input_as_handled()
	match event.keycode:
		KEY_ESCAPE:
			_stop_listening()
			return
		KEY_BACKSPACE, KEY_DELETE:
			_set_keys(_listening_entry, [])
			_stop_listening()
			return
	if event.keycode in MODIFIERS:
		return  # wait for the main key, modifiers are read from the event
	var keys: Array = []
	if event.ctrl_pressed:
		keys.append("Ctrl")
	if event.shift_pressed:
		keys.append("Shift")
	if event.alt_pressed:
		keys.append("Alt")
	keys.append(OS.get_keycode_string(event.keycode))
	_set_keys(_listening_entry, keys.slice(0, 3))
	_stop_listening()

#endregion
