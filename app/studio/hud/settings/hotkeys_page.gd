## Hotkeys page of the settings overlay. The simple hotkey list comes here, the Musubi node editor is
## the advanced tool and only gets a small button at the bottom.
extends VBoxContainer

func _init() -> void:
	name = "HotkeysPage"
	var list := Label.new()
	list.name = "Placeholder"
	list.text = "The hotkey list is being built. Hotkeys can be set in the Musubi node editor for now."
	list.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(list)

	var advanced := HBoxContainer.new()
	advanced.alignment = BoxContainer.ALIGNMENT_END
	var editor := Button.new()
	editor.name = "NodeEditorBtn"
	editor.text = "Advanced: Musubi node editor"
	editor.flat = true
	editor.pressed.connect(_open_node_editor)
	advanced.add_child(editor)
	add_child(advanced)

func _open_node_editor() -> void:
	var stage = get_tree().get_first_node_in_group("system:stage")
	var model = stage.active_model if stage else null
	if model == null:
		get_tree().get_first_node_in_group("system:alert").alert(tr("Load a model first."))
		return
	var key = "{name}_{uid}_blueprints".format({"name": model.name, "uid": model.uid})
	var popup = WindowManager.get_popup(
		key,
		func ():
			var e = load("res://studio/hud/blueprint_editor/editor.tscn").instantiate()
			e.active_model = model
			e.visible = true
			model.tree_exiting.connect(e.queue_free, CONNECT_ONE_SHOT)
			return e
	)
	# the editor takes the whole window, the overlay would sit on top of it
	var overlay = find_parent("SettingsOverlay")
	if overlay:
		overlay.close_overlay()
	popup.grab_focus()
