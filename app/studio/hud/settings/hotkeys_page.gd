## Hotkeys page of the settings overlay. The simple hotkey list comes here, the Musubi node editor is
## the advanced tool and only gets a small button at the bottom.
extends VBoxContainer

const HotkeyList = preload("res://studio/hud/settings/hotkey_list.gd")

func _init() -> void:
	name = "HotkeysPage"
	var screen := CheckButton.new()
	screen.name = "ShowScreenButtons"
	screen.text = "Show screen buttons on the stage"
	screen.tooltip_text = "Clickable buttons in the corner of the stage for hotkeys that have one. Off: keyboard hotkeys only."
	screen.toggled.connect(func (on):
		var hud = find_parent("HUD")
		if hud:
			hud.show_screen_buttons = on
			hud.refresh_screen_buttons())
	add_child(screen)
	visibility_changed.connect(func ():
		var hud = find_parent("HUD")
		if hud and is_visible_in_tree():
			screen.set_pressed_no_signal(hud.show_screen_buttons))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var list := HotkeyList.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	add_child(scroll)
	visibility_changed.connect(func (): if is_visible_in_tree(): list.refresh())

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
