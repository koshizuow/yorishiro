## Makes a new expression or changes one: a slider per Live2D parameter, how it combines with tracking
## (add, multiply, overwrite), and a live preview on the model while editing. Saved with the model's
## Yorishiro settings (l2d model.gd save_user_expression), the model's folder is not touched.
extends Window

const BLENDS = ["Add", "Multiply", "Overwrite"]
const BLEND_KEYS = ["ADD", "MULTIPLY", "OVERRIDE"]
const PREVIEW = "__yorishiro_preview__"

signal saved(expression_name: String)

var model  # the l2d model
## the expression being changed, "" for a new one
var original := ""

## id -> {use: CheckBox, slider: HSlider, value: Label, blend: OptionButton, row}
var _rows := {}
var _name := LineEdit.new()
var _filter := LineEdit.new()
var _only_used := CheckBox.new()
var _error := Label.new()
var _preview: KatashiroExpression
var _original_weight := 0.0

func _ready() -> void:
	title = tr("Edit expression") if original else tr("New expression")
	size = Vector2i(720, 640)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.theme_type_variation = &"WindowPanel"
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	var head := HBoxContainer.new()
	box.add_child(head)
	var name_label := Label.new()
	name_label.text = "Name"
	head.add_child(name_label)
	_name.name = "ExpressionName"
	_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name.text = original if original else _free_name()
	_name.text_changed.connect(func (_t): _check_name())
	head.add_child(_name)
	_error.modulate = Color(1, 0.45, 0.45)
	_error.visible = false
	box.add_child(_error)

	var tools := HBoxContainer.new()
	box.add_child(tools)
	_filter.placeholder_text = "Search parameters"
	_filter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_filter.text_changed.connect(func (_t): _apply_filter())
	tools.add_child(_filter)
	_only_used.text = "Only the ones in use"
	_only_used.toggled.connect(func (_on): _apply_filter())
	tools.add_child(_only_used)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	var existing := _tracks_of(original)
	var params: Dictionary = model.get_parameters()
	var ids := params.keys()
	ids.sort_custom(func (a, b): return (a in existing) and not (b in existing) or ((a in existing) == (b in existing) and String(a) < String(b)))
	for id in ids:
		list.add_child(_row(String(id), params[id], existing.get(String(id))))

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 8)
	box.add_child(buttons)
	if original in model.user_expression_names():
		var delete := Button.new()
		delete.name = "DeleteExpressionBtn"
		delete.text = "Delete my version"
		delete.tooltip_text = "The model's own expression of this name comes back, if it has one."
		delete.pressed.connect(_delete)
		buttons.add_child(delete)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(func (): close_requested.emit())
	buttons.add_child(cancel)
	var save := Button.new()
	save.name = "SaveExpressionBtn"
	save.text = "Save"
	save.theme_type_variation = &"AccentButton"
	save.pressed.connect(_save)
	buttons.add_child(save)

	close_requested.connect(_end_preview)
	tree_exiting.connect(_end_preview)
	# watch the model while editing: the settings panel moves to the right half
	var overlay = get_tree().root.find_child("SettingsOverlay", true, false)
	if overlay:
		overlay.side_by_side(true)
		tree_exiting.connect(func (): overlay.side_by_side(false))
	_start_preview()
	_apply_filter()

func _row(id: String, info: Dictionary, track) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "Param_" + id.validate_node_name()
	var use := CheckBox.new()
	use.tooltip_text = "Part of this expression"
	use.button_pressed = track != null
	row.add_child(use)
	var label := Label.new()
	label.text = id
	label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	label.custom_minimum_size.x = 170
	label.clip_text = true
	label.tooltip_text = id
	row.add_child(label)
	var blend := OptionButton.new()
	for b in BLENDS:
		blend.add_item(b)
	blend.select(BLENDS.find(track[1]) if track else 0)
	blend.tooltip_text = "Add: on top of tracking. Multiply: scales tracking. Overwrite: replaces tracking."
	row.add_child(blend)
	var slider := HSlider.new()
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)
	var value := Label.new()
	value.custom_minimum_size.x = 48
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value)
	var r := {"use": use, "slider": slider, "value": value, "blend": blend, "row": row, "range": info.range, "default": float(info.default)}
	_rows[id] = r
	_set_range(r, track[0] if track else _neutral(r, blend.selected))
	slider.value_changed.connect(func (v):
		value.text = "%.2f" % v
		use.set_pressed_no_signal(true)
		_update_preview())
	use.toggled.connect(func (_on): _update_preview())
	blend.item_selected.connect(func (i):
		_set_range(r, _neutral(r, i))
		_update_preview())
	value.text = "%.2f" % slider.value
	return row

## slider limits for the blend: Add moves within the parameter's span either way, Multiply 0 to 2,
## Overwrite the parameter's own range
func _set_range(r: Dictionary, v: float) -> void:
	var lo: float = r.range.x if r.range is Vector2 else 0.0
	var hi: float = r.range.y if r.range is Vector2 else 1.0
	var s: HSlider = r.slider
	match r.blend.selected:
		0:
			s.min_value = -(hi - lo)
			s.max_value = hi - lo
		1:
			s.min_value = 0.0
			s.max_value = 2.0
		_:
			s.min_value = lo
			s.max_value = hi
	s.step = (s.max_value - s.min_value) / 200.0
	s.set_value_no_signal(v)
	r.value.text = "%.2f" % v

func _neutral(r: Dictionary, blend: int) -> float:
	return [0.0, 1.0, r.default][blend]

func _apply_filter() -> void:
	var q := _filter.text.strip_edges().to_lower()
	for id in _rows:
		var r: Dictionary = _rows[id]
		r.row.visible = (q.is_empty() or q in id.to_lower()) and (not _only_used.button_pressed or r.use.button_pressed)

func _tracks() -> Dictionary:
	var out := {}
	for id in _rows:
		var r: Dictionary = _rows[id]
		if r.use.button_pressed:
			out[id] = [snappedf(r.slider.value, 0.001), BLENDS[r.blend.selected]]
	return out

## {id: [value, blend]} of an expression on the model
func _tracks_of(expression_name: String) -> Dictionary:
	var out := {}
	if expression_name.is_empty():
		return out
	for e in model.get_expression_controller().expressions:
		if e.get_name() != expression_name:
			continue
		for t in e.tracks:
			out[String(t.property_name).trim_prefix("parameters/")] = [t.amount, BLENDS[maxi(BLEND_KEYS.find(String(t.blend_mode)), 0)]]
	return out

# --- preview: the edited expression at full weight, the original one off meanwhile ---

func _start_preview() -> void:
	var controller: KatashiroExpressionMutator = model.get_expression_controller()
	if original:
		_original_weight = float(controller.get("weight/%s" % original))
		controller.set("weight/%s" % original, 0.0)
	_preview = KatashiroExpression.new()
	_preview.resource_name = PREVIEW
	var list: Array[KatashiroExpression] = []
	list.assign(controller.expressions)
	list.append(_preview)
	controller.expressions = list
	controller.set("weight/%s" % PREVIEW, 1.0)
	_update_preview()

func _update_preview() -> void:
	if _preview == null:
		return
	var tracks: Array[KatashiroExpressionTrack] = []
	var t := _tracks()
	for id in t:
		var track := KatashiroExpressionTrack.new()
		track.property_name = "parameters/%s" % id
		track.blend_mode = BLEND_KEYS[BLENDS.find(t[id][1])]
		track.amount = t[id][0]
		tracks.append(track)
	_preview.tracks = tracks

func _end_preview() -> void:
	if _preview == null or not is_instance_valid(model):
		return
	var controller: KatashiroExpressionMutator = model.get_expression_controller()
	var list: Array[KatashiroExpression] = []
	for e in controller.expressions:
		if e != _preview:
			list.append(e)
	controller.expressions = list
	_preview = null
	if original and original in list.map(func (e): return e.get_name()):
		controller.set("weight/%s" % original, _original_weight)

# --- saving ---

func _free_name() -> String:
	var names: Array = model.get_expression_controller().expressions.map(func (e): return e.get_name())
	var i := 1
	while "expression_%d" % i in names:
		i += 1
	return "expression_%d" % i

func _check_name() -> bool:
	var n := _name.text.strip_edges()
	var problem := ""
	if n.is_empty():
		problem = tr("The expression needs a name.")
	elif not n.is_valid_filename() or n.begins_with("."):
		problem = tr("The name cannot contain / \\ : * ? \" < > |")
	elif n != original and model.get_expression_controller().expressions.any(func (e): return e.get_name() == n):
		problem = tr("The model already has an expression with this name.")
	_error.text = problem
	_error.visible = problem != ""
	return problem.is_empty()

func _save() -> void:
	if not _check_name():
		return
	var n := _name.text.strip_edges()
	_end_preview()
	model.save_user_expression(n, _tracks())
	if n == original:
		model.get_expression_controller().set("weight/%s" % n, _original_weight)
	saved.emit(n)
	close_requested.emit()

func _delete() -> void:
	_end_preview()
	model.delete_user_expression(original)
	saved.emit(original)
	close_requested.emit()
