## Builds ui/themes/sakura.tres, the 夜櫻 (night sakura) theme, from the palette below (D31).
##   godot --headless --path app --script res://ui/themes/build_sakura.gd
## Run --import first when the icons in ui/themes/sakura/ changed. Edit colors here, never in the .tres.
extends SceneTree

const OUT = "res://ui/themes/sakura.tres"

const PANEL = Color("#262430")
const RAISED = Color("#2E2B39")
const FIELD = Color("#34313F")
const FIELD_HOVER = Color("#3D3949")
const INSET = Color("#1F1D26")
const RULE = Color("#3A3746")
const STRONG_RULE = Color("#5B5568")
const TEXT = Color("#EFE9F2")
const SUB = Color("#A59FB1")
const DISABLED = Color("#6E6879")
const ACCENT = Color("#E88FAB")
const ACCENT_HOVER = Color("#F2A3BB")
const ACCENT_PRESSED = Color("#D97796")
const ACCENT_DIM = Color("#4A3442")
const ON_ACCENT = Color("#2A1820")

const RADIUS = 6
const PANEL_RADIUS = 10

var t := Theme.new()

func _init() -> void:
	# jf open 粉圓 (Huninn, SIL OFL 1.1, ui/fonts/OFL.txt), one weight; bold is a synthetic embolden
	t.default_font = load("res://ui/fonts/Huninn-Regular.ttf")
	t.default_font_size = 15
	panels()
	buttons()
	toggles()
	fields()
	menus()
	tabs()
	ranges()
	windows()
	graph()
	labels()
	variations()
	var err := ResourceSaver.save(t, OUT)
	print("saved %s: %s" % [OUT, error_string(err)])
	quit(0 if err == OK else 1)

func box(bg: Color, radius := RADIUS, pad_h := 10, pad_v := 6, border := Color.TRANSPARENT, border_w := 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.content_margin_left = pad_h
	s.content_margin_right = pad_h
	s.content_margin_top = pad_v
	s.content_margin_bottom = pad_v
	if border_w > 0:
		s.border_color = border
		s.set_border_width_all(border_w)
	s.anti_aliasing = true
	return s

func focus_ring() -> StyleBoxFlat:
	var s := box(Color.TRANSPARENT, RADIUS + 1, 0, 0, ACCENT, 2)
	s.draw_center = false
	s.set_expand_margin_all(2)
	return s

func empty(pad := 0) -> StyleBoxEmpty:
	var s := StyleBoxEmpty.new()
	s.set_content_margin_all(pad)
	return s

func icon(name: String) -> Texture2D:
	return load("res://ui/themes/sakura/%s.svg" % name)

func shared_icon(name: String) -> Texture2D:
	return load("res://ui/icons/%s.svg" % name)

func font_colors(type: String, normal := TEXT) -> void:
	t.set_color("font_color", type, normal)
	t.set_color("font_hover_color", type, TEXT)
	t.set_color("font_pressed_color", type, TEXT)
	t.set_color("font_focus_color", type, normal)
	t.set_color("font_hover_pressed_color", type, TEXT)
	t.set_color("font_disabled_color", type, DISABLED)
	t.set_color("icon_normal_color", type, normal)
	t.set_color("icon_hover_color", type, TEXT)
	t.set_color("icon_pressed_color", type, ACCENT)
	t.set_color("icon_focus_color", type, normal)
	t.set_color("icon_hover_pressed_color", type, ACCENT_HOVER)
	t.set_color("icon_disabled_color", type, DISABLED)

func panels() -> void:
	t.set_stylebox("panel", "Panel", box(PANEL, PANEL_RADIUS, 12, 12))
	t.set_stylebox("panel", "PanelContainer", box(PANEL, PANEL_RADIUS, 12, 12))
	t.set_stylebox("panel", "PopupPanel", box(RAISED, PANEL_RADIUS, 10, 10, RULE, 1))
	t.set_stylebox("panel", "TooltipPanel", box(FIELD, RADIUS, 10, 6, RULE, 1))
	t.set_color("font_color", "TooltipLabel", TEXT)
	t.set_stylebox("separator", "HSeparator", line(RULE, false))
	t.set_stylebox("separator", "VSeparator", line(RULE, true))
	t.set_constant("separation", "HSeparator", 12)
	t.set_constant("separation", "VSeparator", 12)
	t.set_stylebox("panel", "ScrollContainer", empty())

func line(c: Color, vertical: bool) -> StyleBoxLine:
	var s := StyleBoxLine.new()
	s.color = c
	s.thickness = 1
	s.vertical = vertical
	return s

func buttons() -> void:
	for type in ["Button", "MenuButton", "OptionButton"]:
		t.set_stylebox("normal", type, box(FIELD))
		t.set_stylebox("hover", type, box(FIELD_HOVER))
		t.set_stylebox("pressed", type, box(ACCENT_DIM))
		t.set_stylebox("hover_pressed", type, box(ACCENT_DIM.lightened(0.08)))
		t.set_stylebox("disabled", type, box(FIELD.darkened(0.25)))
		t.set_stylebox("focus", type, focus_ring())
		font_colors(type)
	t.set_constant("h_separation", "Button", 8)
	t.set_constant("icon_max_width", "Button", 22)
	t.set_icon("arrow", "OptionButton", shared_icon("angle-down"))
	t.set_constant("arrow_margin", "OptionButton", 8)

func toggles() -> void:
	for type in ["CheckBox", "CheckButton"]:
		for s in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
			t.set_stylebox(s, type, empty(4))
		t.set_stylebox("focus", type, focus_ring())
		font_colors(type)
		t.set_constant("h_separation", type, 10)
		# Button's icon_max_width would shrink the switch and box icons (CheckButton looks up Button)
		t.set_constant("icon_max_width", type, 0)
	t.set_icon("checked", "CheckBox", icon("checkbox_on"))
	t.set_icon("checked_disabled", "CheckBox", icon("checkbox_on"))
	t.set_icon("unchecked", "CheckBox", icon("checkbox_off"))
	t.set_icon("unchecked_disabled", "CheckBox", icon("checkbox_off"))
	t.set_icon("radio_checked", "CheckBox", icon("radio_on"))
	t.set_icon("radio_checked_disabled", "CheckBox", icon("radio_on"))
	t.set_icon("radio_unchecked", "CheckBox", icon("radio_off"))
	t.set_icon("radio_unchecked_disabled", "CheckBox", icon("radio_off"))
	t.set_icon("checked", "CheckButton", icon("toggle_on"))
	t.set_icon("unchecked", "CheckButton", icon("toggle_off"))
	t.set_icon("checked_disabled", "CheckButton", icon("toggle_on_disabled"))
	t.set_icon("unchecked_disabled", "CheckButton", icon("toggle_off_disabled"))

func fields() -> void:
	for type in ["LineEdit", "TextEdit"]:
		t.set_stylebox("normal", type, box(FIELD, RADIUS, 10, 6))
		t.set_stylebox("focus", type, box(FIELD, RADIUS, 10, 6, ACCENT, 2))
		t.set_stylebox("read_only", type, box(INSET, RADIUS, 10, 6))
		t.set_color("font_color", type, TEXT)
		t.set_color("font_placeholder_color", type, SUB)
		t.set_color("font_readonly_color", type, SUB)
		t.set_color("caret_color", type, ACCENT)
		t.set_color("selection_color", type, Color(ACCENT, 0.35))
		t.set_color("font_selected_color", type, TEXT)
	t.set_icon("up", "SpinBox", shared_icon("angle-up"))
	t.set_icon("down", "SpinBox", shared_icon("angle-down"))
	t.set_constant("field_and_buttons_separation", "SpinBox", 4)
	for s in ["up_background", "down_background"]:
		t.set_stylebox(s, "SpinBox", empty())
		t.set_stylebox(s + "_hovered", "SpinBox", box(FIELD_HOVER, RADIUS, 0, 0))
		t.set_stylebox(s + "_pressed", "SpinBox", box(ACCENT_DIM, RADIUS, 0, 0))
		t.set_stylebox(s + "_disabled", "SpinBox", empty())
	for c in ["up_icon_modulate", "down_icon_modulate"]:
		t.set_color(c, "SpinBox", SUB)
	for c in ["up_hover_icon_modulate", "down_hover_icon_modulate", "up_pressed_icon_modulate", "down_pressed_icon_modulate"]:
		t.set_color(c, "SpinBox", ACCENT)

func menus() -> void:
	t.set_stylebox("panel", "PopupMenu", box(RAISED, PANEL_RADIUS, 6, 6, RULE, 1))
	t.set_stylebox("hover", "PopupMenu", box(FIELD_HOVER, RADIUS, 8, 4))
	t.set_stylebox("separator", "PopupMenu", line(RULE, false))
	t.set_color("font_color", "PopupMenu", TEXT)
	t.set_color("font_hover_color", "PopupMenu", TEXT)
	t.set_color("font_disabled_color", "PopupMenu", DISABLED)
	t.set_color("font_separator_color", "PopupMenu", SUB)
	t.set_constant("v_separation", "PopupMenu", 8)
	t.set_constant("item_start_padding", "PopupMenu", 10)
	t.set_constant("item_end_padding", "PopupMenu", 10)
	t.set_icon("checked", "PopupMenu", icon("checkbox_on"))
	t.set_icon("unchecked", "PopupMenu", icon("checkbox_off"))
	t.set_icon("radio_checked", "PopupMenu", icon("radio_on"))
	t.set_icon("radio_unchecked", "PopupMenu", icon("radio_off"))

func tabs() -> void:
	# selected tab: panel colored with an accent underline, others flat
	var sel := box(PANEL, 0, 14, 8)
	sel.border_color = ACCENT
	sel.border_width_bottom = 3
	for type in ["TabBar", "TabContainer"]:
		t.set_stylebox("tab_selected", type, sel)
		t.set_stylebox("tab_unselected", type, empty_tab())
		t.set_stylebox("tab_hovered", type, box(FIELD_HOVER, RADIUS, 14, 8))
		t.set_stylebox("tab_disabled", type, empty_tab())
		t.set_stylebox("tab_focus", type, focus_ring())
		t.set_color("font_selected_color", type, TEXT)
		t.set_color("font_unselected_color", type, SUB)
		t.set_color("font_hovered_color", type, TEXT)
		t.set_color("font_disabled_color", type, DISABLED)
	t.set_stylebox("panel", "TabContainer", box(PANEL, PANEL_RADIUS, 12, 12))
	t.set_stylebox("tabbar_background", "TabContainer", empty())

func empty_tab() -> StyleBoxEmpty:
	var s := StyleBoxEmpty.new()
	s.content_margin_left = 14
	s.content_margin_right = 14
	s.content_margin_top = 8
	s.content_margin_bottom = 8
	return s

func ranges() -> void:
	for type in ["HScrollBar", "VScrollBar"]:
		t.set_stylebox("scroll", type, box(Color(INSET, 0.6), 4, 3, 3))
		t.set_stylebox("scroll_focus", type, box(Color(INSET, 0.6), 4, 3, 3))
		t.set_stylebox("grabber", type, box(STRONG_RULE, 4, 3, 3))
		t.set_stylebox("grabber_highlight", type, box(DISABLED, 4, 3, 3))
		t.set_stylebox("grabber_pressed", type, box(ACCENT, 4, 3, 3))
	for type in ["HSlider", "VSlider"]:
		var track := box(FIELD, 4, 0, 3)
		var filled := box(ACCENT, 4, 0, 3)
		t.set_stylebox("slider", type, track)
		t.set_stylebox("grabber_area", type, filled)
		t.set_stylebox("grabber_area_highlight", type, box(ACCENT_HOVER, 4, 0, 3))
		for i in ["grabber", "grabber_highlight", "grabber_disabled"]:
			t.set_icon(i, type, icon("knob"))
	t.set_stylebox("background", "ProgressBar", box(FIELD, 4, 0, 4))
	t.set_stylebox("fill", "ProgressBar", box(ACCENT, 4, 0, 4))
	t.set_color("font_color", "ProgressBar", TEXT)

func windows() -> void:
	# embedded sub-windows (D31: everything inside the main window), title bar drawn in the border margin
	var frame := box(PANEL, PANEL_RADIUS, 0, 0, RULE, 1)
	frame.expand_margin_top = 34
	frame.expand_margin_left = 8
	frame.expand_margin_right = 8
	frame.expand_margin_bottom = 8
	frame.shadow_color = Color(0, 0, 0, 0.45)
	frame.shadow_size = 18
	t.set_stylebox("embedded_border", "Window", frame)
	var unfocused := frame.duplicate()
	unfocused.shadow_size = 8
	t.set_stylebox("embedded_unfocused_border", "Window", unfocused)
	t.set_color("title_color", "Window", TEXT)
	t.set_constant("title_height", "Window", 34)
	t.set_constant("close_h_offset", "Window", 26)
	t.set_constant("close_v_offset", "Window", 24)
	t.set_icon("close", "Window", shared_icon("xmark"))
	t.set_icon("close_pressed", "Window", shared_icon("xmark"))
	t.set_stylebox("panel", "AcceptDialog", box(PANEL, PANEL_RADIUS, 12, 12))

func graph() -> void:
	t.set_stylebox("panel", "GraphEdit", box(INSET, 0, 0, 0))
	t.set_color("grid_major", "GraphEdit", Color(RULE, 0.9))
	t.set_color("grid_minor", "GraphEdit", Color(RULE, 0.4))
	t.set_color("activity", "GraphEdit", ACCENT)
	var node := box(RAISED, 0, 12, 8, RULE, 1)
	node.corner_radius_bottom_left = PANEL_RADIUS
	node.corner_radius_bottom_right = PANEL_RADIUS
	t.set_stylebox("panel", "GraphNode", node)
	var sel := node.duplicate()
	sel.border_color = ACCENT
	sel.set_border_width_all(2)
	t.set_stylebox("panel_selected", "GraphNode", sel)
	var title := box(FIELD, 0, 12, 6, RULE, 1)
	title.corner_radius_top_left = PANEL_RADIUS
	title.corner_radius_top_right = PANEL_RADIUS
	t.set_stylebox("titlebar", "GraphNode", title)
	var title_sel := title.duplicate()
	title_sel.border_color = ACCENT
	title_sel.set_border_width_all(2)
	t.set_stylebox("titlebar_selected", "GraphNode", title_sel)
	t.set_color("resizer_color", "GraphNode", SUB)

func labels() -> void:
	t.set_color("font_color", "Label", TEXT)
	t.set_color("default_color", "RichTextLabel", TEXT)
	t.set_color("font_color", "LinkButton", ACCENT)
	t.set_color("font_hover_color", "LinkButton", ACCENT_HOVER)

## type variations the OpenVT scenes use, restyled
func variations() -> void:
	var v := func (name: String, base: String): t.set_type_variation(name, base)
	v.call("BoldLabel", "Label")
	var bold := FontVariation.new()
	bold.base_font = t.default_font
	bold.variation_embolden = 0.6
	t.set_font("font", "BoldLabel", bold)
	t.set_color("font_color", "BoldLabel", TEXT)
	v.call("FieldLabel", "Label")
	t.set_color("font_color", "FieldLabel", SUB)
	v.call("ValueLabel", "Label")
	t.set_color("font_color", "ValueLabel", TEXT)
	v.call("SubscriptLabel", "Label")
	t.set_color("font_color", "SubscriptLabel", SUB)
	t.set_font_size("font_size", "SubscriptLabel", 12)

	# round stage buttons (gear, screenshot): translucent so the stage shows through
	v.call("HUDButton", "Button")
	for s in ["normal", "hover", "pressed", "hover_pressed"]:
		t.set_stylebox(s, "HUDButton", box(Color(PANEL, 0.82 if s == "normal" else 0.95), PANEL_RADIUS, 8, 8))
	t.set_constant("icon_max_width", "HUDButton", 28)
	v.call("ImageButton", "Button")
	for s in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		t.set_stylebox(s, "ImageButton", box(Color.TRANSPARENT if s == "normal" else FIELD_HOVER, RADIUS, 6, 6))
	# primary action, for example "Load model"
	v.call("AccentButton", "Button")
	t.set_stylebox("normal", "AccentButton", box(ACCENT))
	t.set_stylebox("hover", "AccentButton", box(ACCENT_HOVER))
	t.set_stylebox("pressed", "AccentButton", box(ACCENT_PRESSED))
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "icon_normal_color", "icon_hover_color", "icon_pressed_color"]:
		t.set_color(c, "AccentButton", ON_ACCENT)

	# tabs of the settings overlay (toggle buttons in a ButtonGroup)
	v.call("OverlayTab", "Button")
	var tab_on := box(Color.TRANSPARENT, 0, 14, 8)
	tab_on.border_color = ACCENT
	tab_on.border_width_bottom = 3
	t.set_stylebox("normal", "OverlayTab", empty_tab())
	t.set_stylebox("hover", "OverlayTab", box(FIELD_HOVER, RADIUS, 14, 8))
	t.set_stylebox("pressed", "OverlayTab", tab_on)
	t.set_stylebox("hover_pressed", "OverlayTab", tab_on)
	t.set_color("font_color", "OverlayTab", SUB)
	t.set_color("font_pressed_color", "OverlayTab", TEXT)
	t.set_color("font_hover_pressed_color", "OverlayTab", TEXT)
	t.set_font_size("font_size", "OverlayTab", 17)

	v.call("LockButton", "CheckButton")
	t.set_icon("checked", "LockButton", shared_icon("lock"))
	t.set_icon("unchecked", "LockButton", shared_icon("unlock"))
	for s in ["normal", "hover", "pressed", "hover_pressed"]:
		t.set_stylebox(s, "LockButton", box(FIELD if s != "hover" else FIELD_HOVER, RADIUS, 6, 6))
	# accordion headers
	v.call("FoldButton", "CheckButton")
	for s in ["normal", "hover", "pressed", "hover_pressed"]:
		t.set_stylebox(s, "FoldButton", box(RAISED if not s.begins_with("hover") else FIELD_HOVER, RADIUS, 12, 8))
	t.set_icon("checked", "FoldButton", shared_icon("fold_down_arrow"))
	t.set_icon("unchecked", "FoldButton", shared_icon("fold_right_arrow"))
	t.set_color("font_color", "FoldButton", TEXT)
	t.set_color("font_pressed_color", "FoldButton", TEXT)

	v.call("ButtonPanel", "PanelContainer")
	t.set_stylebox("panel", "ButtonPanel", box(Color(PANEL, 0.82), PANEL_RADIUS, 6, 6))
	v.call("SubPanelContainer", "PanelContainer")
	t.set_stylebox("panel", "SubPanelContainer", box(RAISED, PANEL_RADIUS, 12, 10))
	v.call("Section", "PanelContainer")
	t.set_stylebox("panel", "Section", box(RAISED, PANEL_RADIUS, 12, 10))
	v.call("FlatPanelContainer", "PanelContainer")
	t.set_stylebox("panel", "FlatPanelContainer", empty())
	v.call("InsetPanel", "Panel")
	t.set_stylebox("panel", "InsetPanel", box(INSET, RADIUS, 8, 8))
	v.call("InsetPanelContainer", "PanelContainer")
	t.set_stylebox("panel", "InsetPanelContainer", box(INSET, RADIUS, 8, 8))
	v.call("WindowPanel", "PanelContainer")
	t.set_stylebox("panel", "WindowPanel", box(PANEL, 0, 12, 12))
	v.call("FramedPopupPanel", "PopupPanel")
	t.set_stylebox("panel", "FramedPopupPanel", box(RAISED, PANEL_RADIUS, 10, 10, STRONG_RULE, 1))
