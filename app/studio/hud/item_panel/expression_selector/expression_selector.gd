extends Window

const VtModel = preload("res://lib/model/vt_model.gd")
const Collections = preload("res://lib/utils/collections.gd")

const ExpressionEditor = preload("./expression_editor.gd")

var item: VtModel
## opens this list again (set by the item row), after the editor closes
var reopen: Callable
var buttons: Dictionary[AyagamiExpression, Array] = {}

@onready var exp_controller: AyagamiExpressionMutator = item.get_expression_controller()
@onready var expressions = exp_controller.expressions.duplicate()
func _ready():
	title = tr("Set Expression [%s]") % item.display_name
	if item.has_method("save_user_expression"):
		var add := Button.new()
		add.name = "NewExpressionBtn"
		add.text = "New expression"
		add.icon = preload("res://ui/icons/plus.svg")
		add.pressed.connect(_open_editor.bind(""))
		%ExpressionList.add_child(add)
	
	# expressions without a group first, a strict order so the sort stays valid
	expressions.sort_custom(
		func (a, b):
			return exp_controller.get("expression_groups/%s" % a.get_name()).is_empty() \
				and not exp_controller.get("expression_groups/%s" % b.get_name()).is_empty()
	)
	var groups = [""] + exp_controller.get_expression_groups()
	var group_controls = {}
	var sections = {
		"": VBoxContainer.new()
	}
	for group in groups:
		sections[group] = VBoxContainer.new()
		group_controls[group] = ButtonGroup.new()
		group_controls[group].allow_unpress = true
		
	for e in expressions:
		var e_name = e.get_name()
		var e_groups = exp_controller.get("expression_groups/%s" % e_name)
		var btns: Array = buttons.get(e, [])
		for group in e_groups:
			var section = sections[group]
			var btn_group = group_controls[group]
			var row = make_row(e, btn_group)
			
			var btn = row.get_node("Toggle")
			btns.append(btn)
			
			section.add_child(row)
		if e_groups.is_empty():
			var row = make_row(e)
			var btn = row.get_node("Toggle")
			btns.append(btn)
			
			sections[""].add_child(row)
		
		buttons[e] = btns
		for b in btns:
			b.set_pressed_no_signal(exp_controller.get("expressions/%s" % e_name))
			
	for group in sections:
		var section: Node = sections[group]
		if section.get_child_count() <= 0:
			continue
			
		if not group.is_empty():
			var l = Label.new()
			l.text = group
			l.theme_type_variation = "FieldLabel"
			%ExpressionList.add_child(l)
		
		var container = PanelContainer.new()
		container.theme_type_variation = "Section"
		container.add_child(section)
		%ExpressionList.add_child(container)
	
	await get_tree().process_frame
	
	var list_height = %ExpressionList.size.y
	self.size.y = clamp(list_height, 128, 800)
		
func make_row(e: AyagamiExpression, btn_group: ButtonGroup = null):
	var e_name = e.get_name()
		
	var row = HBoxContainer.new()
	var btn = CheckBox.new()
	btn.button_group = btn_group
	btn.text = e_name
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	btn.name = "Toggle"
	row.add_child(btn)

	var duration = SpinBox.new()
	duration.step = 0.01
	duration.min_value = 0
	duration.max_value = 5.0
	duration.value = 0.5
	duration.custom_minimum_size = Vector2i(64, 0)
	btn.set_meta("spinner", duration)
	row.add_child(duration)
	if item.has_method("save_user_expression"):
		var edit_btn := Button.new()
		edit_btn.name = "Edit_" + String(e_name).validate_node_name()
		edit_btn.text = "Edit"
		edit_btn.pressed.connect(_open_editor.bind(e_name))
		row.add_child(edit_btn)
	
	btn.toggled.connect(
		func (toggled):
			toggle_expression(toggled, e, duration.value)
	)
	
	return row

## the editor takes this page's place in the settings panel; the list comes back when it closes
func _open_editor(expression_name: String) -> void:
	var key := "%s_expression_editor" % name
	var model := item
	var editor = WindowManager.get_popup(key, func ():
		var w := ExpressionEditor.new()
		w.model = model
		w.original = expression_name
		return w)
	var back := reopen
	editor.tree_exiting.connect(func ():
		var overlay = model.get_tree().root.find_child("SettingsOverlay", true, false) if model.is_inside_tree() else null
		if back.is_valid() and overlay and overlay.is_visible_in_tree():
			back.call_deferred())
	var overlay = get_tree().root.find_child("SettingsOverlay", true, false)
	await get_tree().process_frame  # the editor sets its title in _ready
	if overlay and overlay.is_visible_in_tree():
		overlay.open_sub_page(key, editor)
	editor.grab_focus()

func toggle_expression(activate: bool, expression: AyagamiExpression, fade: float):
	for b in buttons[expression]:
		b.set_pressed_no_signal(activate)
		
	var e_name: String = expression.get_name()
	var groups: Array = exp_controller.get("expression_groups/%s" % e_name)
	var tween = create_tween().set_parallel(true)
	if not groups.is_empty() and activate:
		for e2 in expressions:
			var e2_name = e2.get_name()
			if e_name == e2_name:
				continue
			var e_groups: Array = exp_controller.get("expression_groups/%s" % e2_name)
			if not Collections.intersect(groups, e_groups).is_empty():
				tween.tween_property(exp_controller, "weight/%s" % e2_name, 0.0, fade)
				for b in buttons[e2]:
					b.set_pressed_no_signal(false)
			
		tween.tween_property(exp_controller, "weight/%s" % e_name, 1.0, fade)
	elif activate:
		tween.tween_property(exp_controller, "weight/%s" % e_name, 1.0, fade)
	else:
		tween.tween_property(exp_controller, "weight/%s" % e_name, 0.0, fade)

func _on_close_requested() -> void:
	queue_free()
