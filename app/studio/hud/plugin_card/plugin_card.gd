## Asks the user whether a plugin may control Yorishiro (lib/plugin_api/plugin_api.gd), in the middle of the
## main window over everything else. Shown while a plugin waits for its token.
extends CenterContainer

var _icon := TextureRect.new()
var _title := Label.new()
var _developer := Label.new()

func _init() -> void:
	name = "PluginCard"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"StagePanel"
	panel.custom_minimum_size = Vector2(440, 0)
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	box.add_child(head)
	_icon.custom_minimum_size = Vector2(64, 64)
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	head.add_child(_icon)
	var names := VBoxContainer.new()
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(names)
	_title.theme_type_variation = &"BoldLabel"
	_title.add_theme_font_size_override("font_size", 20)
	_title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	names.add_child(_title)
	_developer.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	names.add_child(_developer)

	var ask := Label.new()
	ask.text = "This plugin wants to control Yorishiro: read and move the model, trigger hotkeys and expressions, send tracking values. Allow it?"
	ask.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(ask)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 8)
	box.add_child(buttons)
	var deny := Button.new()
	deny.name = "PluginDenyBtn"
	deny.text = "Deny"
	deny.pressed.connect(func (): PluginApi.answer(false))
	buttons.add_child(deny)
	var allow := Button.new()
	allow.name = "PluginAllowBtn"
	allow.text = "Allow"
	allow.theme_type_variation = &"AccentButton"
	allow.pressed.connect(func (): PluginApi.answer(true))
	buttons.add_child(allow)

func _ready() -> void:
	PluginApi.approval_requested.connect(func (plugin: Dictionary):
		_title.text = plugin.name
		_developer.text = tr("by %s") % plugin.developer
		_icon.texture = plugin.icon if plugin.icon else preload("res://studio/hud/cube.svg")
		show())
	PluginApi.approval_finished.connect(hide)
