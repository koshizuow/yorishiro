## Full window settings, opened from the gear button (VTube Studio style). Everything happens inside the main
## window: a dimmed backdrop with the stage still visible, tabs on top, one page at a time.
## Existing side panels are hosted as pages, setup() and teardown() run when their page shows and hides.
extends Control

signal closed

const BACKDROP = Color(0.0, 0.0, 0.0, 0.45)

var _tabs := HBoxContainer.new()
var _pages := MarginContainer.new()
var _group := ButtonGroup.new()
var _page_ids: Array[StringName] = []
var current: StringName = &""

func _init() -> void:
	name = "SettingsOverlay"
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var backdrop := ColorRect.new()
	backdrop.color = BACKDROP
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.gui_input.connect(_on_backdrop_input)
	add_child(backdrop)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)

	var frame := PanelContainer.new()
	margin.add_child(frame)
	var column := VBoxContainer.new()
	frame.add_child(column)

	var header := HBoxContainer.new()
	column.add_child(header)
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_tabs)
	header.add_child(_language_selector())
	var close := Button.new()
	close.icon = preload("res://ui/icons/xmark.svg")
	close.flat = true
	close.tooltip_text = "Close (Esc)"
	close.pressed.connect(close_overlay)
	header.add_child(close)

	column.add_child(HSeparator.new())
	_pages.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_pages)

## adds a tab, page is any Control (existing panels with setup()/teardown() are reparented here)
func add_page(id: StringName, title: String, page: Control) -> void:
	if page.get_parent():
		page.reparent(_pages, false)
	else:
		_pages.add_child(page)
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.custom_minimum_size = Vector2.ZERO
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.hide()
	page.set_meta("overlay_page", id)

	var tab := Button.new()
	tab.text = title
	tab.toggle_mode = true
	tab.button_group = _group
	tab.theme_type_variation = &"OverlayTab"
	tab.pressed.connect(open_page.bind(id))
	tab.name = "%sTab" % String(id).capitalize()
	_tabs.add_child(tab)
	_page_ids.append(id)

func open_page(id: StringName = &"") -> void:
	if id == &"":
		id = current if current != &"" else _page_ids[0]
	show()
	if id == current:
		return
	_show_page(current, false)
	current = id
	_show_page(id, true)
	_tabs.get_child(_page_ids.find(id)).button_pressed = true

func close_overlay() -> void:
	if not visible:
		return
	_show_page(current, false)
	current = &""
	hide()
	closed.emit()

func toggle() -> void:
	if visible:
		close_overlay()
	else:
		open_page()

func _show_page(id: StringName, on: bool) -> void:
	if id == &"":
		return
	for page in _pages.get_children():
		if page.get_meta("overlay_page", &"") != id:
			continue
		if on:
			page.show()
			if page.has_method("setup"):
				await page.setup()
		else:
			if page.has_method("teardown"):
				page.teardown()
			page.hide()

func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close_overlay()
		get_viewport().set_input_as_handled()

func _on_backdrop_input(event: InputEvent) -> void:
	# a click on the dimmed margin around the frame closes, like leaving a menu
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		close_overlay()

func _language_selector() -> OptionButton:
	var languages := OptionButton.new()
	languages.name = "Language"
	languages.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	languages.add_item("繁體中文")
	languages.set_item_metadata(0, "zh_TW")
	languages.add_item("English")
	languages.set_item_metadata(1, "en")
	languages.select(1 if TranslationServer.get_locale().begins_with("en") else 0)
	languages.item_selected.connect(func (i): Locale.set_language(languages.get_item_metadata(i)))
	return languages
