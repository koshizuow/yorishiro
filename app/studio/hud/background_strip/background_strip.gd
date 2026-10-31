## A row of background cards on the settings page: the default grid, a solid color, transparent, then every
## picture of the background library (lib/background_library.gd) and an "add" card. The current one is
## highlighted. Picking a card sets the stage's background; the mode picker and color button stay for details.
extends ScrollContainer

signal picked(mode: int, path: String)
signal import_requested

const CARD_SIZE = Vector2(128, 96)
const MODES = [[0, "Default Grid"], [2, "Color"], [3, "Transparent"]]

var _row := HBoxContainer.new()
var _group := ButtonGroup.new()

func _init() -> void:
	name = "BackgroundStrip"
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	custom_minimum_size.y = CARD_SIZE.y + 30
	_row.add_theme_constant_override("separation", 8)
	add_child(_row)

func _ready() -> void:
	BackgroundLibrary.changed.connect(refresh)
	visibility_changed.connect(func (): if is_visible_in_tree(): refresh())
	refresh()

func refresh() -> void:
	for c in _row.get_children():
		_row.remove_child(c)
		c.queue_free()
	var stage = get_tree().get_first_node_in_group("system:stage")
	var mode: int = stage.background_mode if stage else 0
	var current: String = stage.background_image if stage else ""
	for m in MODES:
		_row.add_child(_card("Bg_%d" % m[0], tr(m[1]), _mode_picture(m[0], stage), m[0] == mode, m[0], ""))
	for b in BackgroundLibrary.list():
		var tex: Texture2D = ItemLibrary.thumbnail(b.path)
		_row.add_child(_card("Bg_%s" % b.name.validate_node_name(), b.name, tex, mode == 1 and current == b.path, 1, b.path))
	var add := Button.new()
	add.name = "AddBackgroundCard"
	add.theme_type_variation = &"ModelCardImport"
	add.custom_minimum_size = CARD_SIZE
	add.text = "Add picture..."
	add.icon = preload("res://ui/icons/plus.svg")
	add.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	add.tooltip_text = "Pictures in the Backgrounds folder show up here. Add one from anywhere on this computer."
	add.pressed.connect(import_requested.emit)
	_row.add_child(add)

func _card(node_name: String, title: String, picture: Texture2D, active: bool, mode: int, path: String) -> Button:
	var card := Button.new()
	card.name = node_name
	card.theme_type_variation = &"ModelCard"
	card.custom_minimum_size = CARD_SIZE
	card.toggle_mode = true
	card.button_group = _group
	card.button_pressed = active
	card.tooltip_text = path if path else title
	card.toggled.connect(func (on):
		if on:
			picked.emit(mode, path))
	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 6)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(column)
	var pic := TextureRect.new()
	pic.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pic.texture = picture
	column.add_child(pic)
	var label := Label.new()
	label.text = title
	label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.clip_text = true
	column.add_child(label)
	return card

## small pictures of the modes without a file: the grid, the chosen color, a checkerboard for transparent
func _mode_picture(mode: int, stage) -> Texture2D:
	var img := Image.create(64, 48, false, Image.FORMAT_RGBA8)
	for y in 48:
		for x in 64:
			var c: Color
			match mode:
				0:
					c = Color(0.16, 0.15, 0.2) if (x % 8 == 0 or y % 8 == 0) else Color(0.12, 0.11, 0.15)
				2:
					c = stage.background_color if stage else Color.BLACK
				_:
					c = Color(0.85, 0.85, 0.88) if ((x / 8) + (y / 8)) % 2 == 0 else Color(0.6, 0.6, 0.65)
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)
