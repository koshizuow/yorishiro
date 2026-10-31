## A row of item thumbnails from the item library (lib/item_library.gd), with an "add" card at the end.
## On the models and items page of the settings overlay, under the model row. Picking a card opens the same
## preview the file browser leads to, where the item is placed on the stage.
extends ScrollContainer

signal picked(paths: PackedStringArray)
signal import_requested

const CARD_SIZE = Vector2(92, 112)

var _row := HBoxContainer.new()

func _init() -> void:
	name = "ItemStrip"
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	custom_minimum_size.y = CARD_SIZE.y + 16
	_row.add_theme_constant_override("separation", 8)
	add_child(_row)

func _ready() -> void:
	ItemLibrary.changed.connect(refresh)
	visibility_changed.connect(func (): if is_visible_in_tree(): refresh())
	refresh()

func refresh() -> void:
	for c in _row.get_children():
		_row.remove_child(c)  # out now, so the new cards keep their names
		c.queue_free()
	for entry in ItemLibrary.list():
		_row.add_child(_card(entry))
	_row.add_child(_import_card())

func _card(entry: Dictionary) -> Button:
	var card := Button.new()
	card.name = "Item_%s" % entry.name.validate_node_name()
	card.theme_type_variation = &"ModelCard"
	card.custom_minimum_size = CARD_SIZE
	card.tooltip_text = entry.paths[0] if not entry.animated else entry.paths[0].get_base_dir()
	card.pressed.connect(func (): picked.emit(entry.paths))

	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 6)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(column)

	var pic := TextureRect.new()
	pic.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pic.texture = ItemLibrary.thumbnail(entry.paths[0])
	column.add_child(pic)

	var title := Label.new()
	title.text = entry.name
	title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.clip_text = true
	column.add_child(title)
	if entry.animated:
		var kind := Label.new()
		kind.text = "Animation"
		kind.theme_type_variation = &"SubscriptLabel"
		kind.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		column.add_child(kind)
	return card

func _import_card() -> Button:
	var card := Button.new()
	card.name = "AddItemCard"
	card.theme_type_variation = &"ModelCardImport"
	card.custom_minimum_size = CARD_SIZE
	card.text = "Add item..."
	card.icon = preload("res://ui/icons/plus.svg")
	card.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	card.tooltip_text = "Pictures in the Items folder show up here. Add one from anywhere on this computer."
	card.pressed.connect(import_requested.emit)
	return card
