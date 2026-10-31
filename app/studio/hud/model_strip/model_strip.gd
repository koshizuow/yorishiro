## A row of model thumbnails (VTube Studio's model picker), most recently used first, with an import card
## at the end. Used on the stage (person button) and at the top of the models page of the settings overlay.
extends ScrollContainer

signal picked(path: String)
signal import_requested

const CARD_SIZE = Vector2(132, 206)
const PLACEHOLDER = preload("res://ui/themes/sakura/katashiro.svg")

var _row := HBoxContainer.new()
var _premult := CanvasItemMaterial.new()

func _init() -> void:
	name = "ModelStrip"
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	custom_minimum_size.y = CARD_SIZE.y + 16
	# thumbnails come from the stage, which holds premultiplied alpha
	_premult.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA
	_row.add_theme_constant_override("separation", 10)
	add_child(_row)

func _ready() -> void:
	ModelLibrary.changed.connect(refresh)
	visibility_changed.connect(func (): if is_visible_in_tree(): refresh())
	refresh()

func refresh() -> void:
	for c in _row.get_children():
		c.queue_free()
	var stage = get_tree().get_first_node_in_group("system:stage")
	var active: String = ""
	if stage and stage.active_model and stage.active_model.modelmeta:
		active = ProjectSettings.globalize_path(stage.active_model.modelmeta.model)
	for entry in ModelLibrary.list():
		_row.add_child(_card(entry, ProjectSettings.globalize_path(entry.path) == active))
	_row.add_child(_import_card())

func _card(entry: Dictionary, active: bool) -> Button:
	var card := Button.new()
	card.theme_type_variation = &"ModelCard"
	card.custom_minimum_size = CARD_SIZE
	card.toggle_mode = true
	card.button_pressed = active
	card.tooltip_text = entry.path
	card.pressed.connect(func ():
		card.button_pressed = true
		picked.emit(entry.path))

	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 8)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(column)

	var pic := TextureRect.new()
	pic.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if entry.thumbnail:
		pic.texture = entry.thumbnail
		pic.material = _premult
	else:
		pic.texture = PLACEHOLDER
	column.add_child(pic)

	var title := Label.new()
	title.text = entry.name
	title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.clip_text = true
	column.add_child(title)

	var kind := Label.new()
	kind.text = entry.format
	kind.theme_type_variation = &"SubscriptLabel"
	kind.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(kind)
	return card

func _import_card() -> Button:
	var card := Button.new()
	card.name = "ImportCard"
	card.theme_type_variation = &"ModelCardImport"
	card.custom_minimum_size = CARD_SIZE
	card.text = "Import..."
	card.icon = preload("res://ui/icons/plus.svg")
	card.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	card.tooltip_text = "Load a model from a folder on this computer"
	card.pressed.connect(import_requested.emit)
	return card
