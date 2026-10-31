## Full window settings, opened from the gear button (VTube Studio style). Everything happens inside the main
## window: a dimmed backdrop with the stage still visible, tabs on top, one page at a time.
## Existing side panels are hosted as pages, setup() and teardown() run when their page shows and hides.
## Windows a page opens (a model's expressions or settings) show as a sub page in the same frame, with a back
## button, instead of floating over it.
extends Control

signal closed

const BACKDROP = Color(0.0, 0.0, 0.0, 0.45)

var _tabs := HBoxContainer.new()
var _pages := MarginContainer.new()
var _group := ButtonGroup.new()
var _page_ids: Array[StringName] = []
var current: StringName = &""
## the window shown as a sub page, its WindowManager key, and the bar with the back button and its title
var _sub_window: Window
var _sub_key: StringName
var _sub_bar := HBoxContainer.new()
var _sub_title := Label.new()
var _header: HBoxContainer

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
	_header = header
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

	_sub_bar.name = "SubPageBar"
	_sub_bar.hide()
	var back := Button.new()
	back.name = "BackBtn"
	back.text = "Go back"  # "Back" is taken by the tween easing name
	back.icon = preload("res://ui/icons/circle-chevron-left.svg")
	back.flat = true
	back.pressed.connect(close_sub_page)
	_sub_bar.add_child(back)
	_sub_title.theme_type_variation = &"BoldLabel"
	_sub_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sub_bar.add_child(_sub_title)
	column.add_child(_sub_bar)

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

## shows a window a page opened (from WindowManager.get_popup) inside the frame, in place of the page
func open_sub_page(key: StringName, window: Window) -> void:
	if _sub_window and _sub_window != window:
		close_sub_page()
	_sub_window = window
	_sub_key = key
	window.borderless = true
	window.unresizable = true
	window.transient = true
	# no frame or resize corners, it reads as part of the page
	window.add_theme_stylebox_override("embedded_border", StyleBoxEmpty.new())
	window.add_theme_stylebox_override("embedded_unfocused_border", StyleBoxEmpty.new())
	window.transparent_bg = true  # the window's own clear color showed in its panel's rounded corners
	window.close_requested.connect(close_sub_page)
	window.tree_exiting.connect(func (): if _sub_window == window: _end_sub_page())
	_sub_title.text = window.title
	_header.hide()
	_sub_bar.show()
	for page in _pages.get_children():
		page.modulate.a = 0.0  # the page keeps its state, the window covers it
	_place_sub_window()

func close_sub_page() -> void:
	if _sub_window == null:
		return
	WindowManager.close_popup(_sub_key)
	_end_sub_page()

func _end_sub_page() -> void:
	_sub_window = null
	_sub_bar.hide()
	_header.show()
	for page in _pages.get_children():
		page.modulate.a = 1.0

func _place_sub_window() -> void:
	if _sub_window == null or not is_instance_valid(_sub_window):
		return
	var rect := _pages.get_global_rect()
	_sub_window.position = Vector2i(rect.position)
	_sub_window.size = Vector2i(rect.size)
	_sub_window.min_size = Vector2i.ZERO

func _process(_delta: float) -> void:
	if _sub_window:
		_place_sub_window()

func close_overlay() -> void:
	if not visible:
		return
	close_sub_page()
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
		if _sub_window:
			close_sub_page()
		else:
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
