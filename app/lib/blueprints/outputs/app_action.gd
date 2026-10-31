## Things a hotkey or screen button can do in the app, beside expressions and animations (VTube Studio has
## the same kinds): move the model to one of its saved positions, change the background, open another model,
## put an item on the stage or take it away, reload the model, take a screenshot.
## `target` holds the action's value: a position number, a background mode, a model path or item paths.
extends "../vt_action.gd"

const ACTIONS: Array[StringName] = [&"position", &"background", &"model", &"item", &"reload", &"screenshot"]
const ACTION_NAMES = ["Move to saved position", "Change background", "Change model", "Toggle item", "Reload model", "Take a screenshot"]
## how long the model glides to a saved position
const MOVE_SECONDS = 0.35

var action: StringName = &"position":
	set(v):
		action = v if v in ACTIONS else &"position"
		if is_node_ready():
			%Action.select(ACTIONS.find(action))
var target := "1":
	set(v):
		target = v
		if is_node_ready():
			%Target.text = v

func _ready() -> void:
	for n in ACTION_NAMES:
		%Action.add_item(n)
	%Action.select(ACTIONS.find(action))
	%Action.item_selected.connect(func (i): action = ACTIONS[i])
	%Target.text = target
	%Target.text_changed.connect(func (t): target = t)

func get_type() -> StringName:
	return &"app_action"

func serialize():
	return {"action": String(action), "target": target}

func deserialize(data: Dictionary):
	action = StringName(data.get("action", "position"))
	target = str(data.get("target", "1"))

func get_input_slot_by_port(port: int) -> int:
	return 1 if port == 0 else -1

func get_input_port_by_name(slot: StringName) -> int:
	return 0 if slot.to_lower() == "trigger" else -1

func get_output_slot_by_port(_port: int) -> int:
	return -1

func get_output_port_by_name(_slot: StringName) -> int:
	return -1

func invoke_trigger(slot: int) -> void:
	if slot != 1:
		return
	var stage = get_tree().get_first_node_in_group("system:stage")
	if stage == null:
		return
	match action:
		&"position":
			_move_to_position(stage)
		&"background":
			stage.background_mode = clampi(int(target), 0, 3)
		&"model":
			if FileAccess.file_exists(target):
				ModelLibrary.open(target)
		&"item":
			_toggle_item(stage)
		&"reload":
			if stage.active_model and stage.active_model.modelmeta:
				ModelLibrary.open(stage.active_model.modelmeta.model)
		&"screenshot":
			Screenshot.snap(stage.capture_viewport)

## a few words for an on-screen button
func short_label() -> String:
	match action:
		&"position":
			return tr("Position %s") % target
		&"background":
			return tr(["Default Grid", "Image", "Color", "Transparent"][clampi(int(target), 0, 3)])
		&"model":
			return target.get_file().get_slice(".", 0)
		&"item":
			return target.split("|")[0].get_file().get_basename()
		&"reload":
			return tr("Reload")
		_:
			return tr("Screenshot")

func _move_to_position(stage) -> void:
	var m = stage.active_model
	if m == null or not m.saved_positions.has(target):
		return
	var p: Dictionary = m.saved_positions[target]
	var t: Tween = m.create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	t.tween_property(m, "position", Vector2(p.x, p.y), MOVE_SECONDS)
	t.tween_property(m, "scale", Vector2.ONE * float(p.scale), MOVE_SECONDS)
	t.tween_property(m, "rotation_degrees", float(p.rotation), MOVE_SECONDS)

## the same picture (or animation folder) is taken away when it is on the stage, put in the middle otherwise
func _toggle_item(stage) -> void:
	var paths := PackedStringArray(target.split("|", false))
	if paths.is_empty():
		return
	for i in stage.canvas.get_children():
		if i is VtItem and PackedStringArray(i.path) == paths:
			stage.remove_item(i)
			return
	var item = await ItemManager.create_item(paths)
	if item:
		stage.spawn_item(item)

const VtItem = preload("res://lib/items/vt_item.gd")
