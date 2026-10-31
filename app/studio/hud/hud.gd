extends "res://ui/popout_panel.gd"

const SettingsOverlay = preload("res://studio/hud/settings/settings_overlay.gd")
const HotkeysPage = preload("res://studio/hud/settings/hotkeys_page.gd")
const AboutPage = preload("res://studio/hud/settings/about_page.gd")
const SensitivityPage = preload("res://studio/hud/settings/sensitivity_page.gd")
const ModelStrip = preload("res://studio/hud/model_strip/model_strip.gd")
const WelcomeCard = preload("res://studio/hud/welcome/welcome_card.gd")
## seconds without mouse movement before the stage buttons fade out (clean window capture)
const IDLE_FADE_SECONDS = 3.0

## hosts a side panel scene as an overlay page, with optional buttons above it. The panel is created here,
## not moved from elsewhere: Preferences saves "persist" nodes whenever they leave the tree, and a move
## saved the camera panel before it had restored its tracker selection.
class PanelPage extends VBoxContainer:
	var inner: Control
	func _init(scene: PackedScene, unique_name: String, top: Array = []) -> void:
		var panel: Control = scene.instantiate()
		panel.name = unique_name
		name = "%sPage" % unique_name
		if top:
			var bar := HBoxContainer.new()
			for b in top:
				bar.add_child(b)
			add_child(bar)
		inner = panel
		add_child(panel)
		panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		panel.custom_minimum_size = Vector2.ZERO
		panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	func setup():
		inner.show()
		await inner.setup()
	func teardown():
		inner.teardown()

var open
var group: ButtonGroup
var model_browser_opened := false
var overlay: SettingsOverlay
## user setting: show the screen buttons that have a Musubi binding (VTS's on-screen hotkeys)
var show_screen_buttons := true
var stage_models: PanelContainer
var _idle := 0.0

@onready var stage = get_tree().get_first_node_in_group("system:stage")
@onready var popup_bg = %Bg
@onready var panels = %Panels
@onready var onscreen_buttons = %OnscreenButtons
@onready var popup_btn = %PopoutBtn

func _ready() -> void:
	for fmt in ModelManager.formats.values():
		%ModelBrowser.add_filter(
			",".join(fmt.supported_extension().map(func (e): return "*%s" % e)),
			fmt.model_format(),
			fmt.mime_type(),
		)
	
	_build_overlay()

	group = %CameraBtn.button_group
	group.pressed.connect(
		func (button):
			if not button.has_meta("panel"):
				return
			if button != null and button.button_pressed:
				var panel = button.get_node(button.get_meta("panel"))
				_open_panel(panel)
			else:
				_close_panel()
	)
	
	on_popout_requested.connect(
		func ():
			# get_window().unresizable = true
			onscreen_buttons.popout(true)
			self.size = Vector2i(580, 720)
			group.allow_unpress = false
			popup_bg.show()
			popup_btn.hide()
			_close_panel()
	)
	
	on_popout.connect(
		func ():
			var curr = open
			if curr == null:
				curr = panels.get_child(0)
			open = null
			
			_open_panel(curr)
	)
	
	on_restore.connect(
		func ():
			self.size = get_parent_area_size()
			group.allow_unpress = true
			popup_bg.hide()
			for p in panels.get_children():
				if p is Control:
					p.offset_right = p.size.x
			onscreen_buttons.restore()
			open == null
			_clear_buttons()
			popup_btn.show()
			# get_window().unresizable = false
	)
	
	var stage = get_tree().get_first_node_in_group("system:stage")
	if stage:
		stage.item_added.connect(
			func (_item):
				_clear_buttons()
		)
		stage.model_changed.connect(
			func (_model):
				_clear_buttons()
		)

func _build_overlay() -> void:
	if stage:
		ModelLibrary.watch(stage)
	var layer := CanvasLayer.new()
	layer.name = "OverlayLayer"
	layer.layer = 10
	layer.add_to_group("hide_screenshot")
	add_child(layer)
	overlay = SettingsOverlay.new()
	layer.add_child(overlay)

	var page_models := _model_strip()
	page_models.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	overlay.add_page(&"model", "Models & Items", PanelPage.new(preload("res://studio/hud/item_panel/item_panel.tscn"), "ItemPanel", [page_models]))
	overlay.add_page(&"hotkeys", "Hotkeys", HotkeysPage.new())
	overlay.add_page(&"sensitivity", "Sensitivity", SensitivityPage.new())
	overlay.add_page(&"settings", "Settings", PanelPage.new(preload("res://studio/hud/camera_panel/camera_panel.tscn"), "CameraPanel"))
	overlay.add_page(&"about", "About", AboutPage.new())

	# the button column spans the window's height, its empty middle must not swallow clicks meant for a
	# model dragged to the left edge
	for c in [%Menu] + %Menu.find_children("*", "Container", true, false):
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# the stage keeps a gear (settings), screenshot and nothing else
	for b in [%ModelBtn, %ItemBtn, %CameraBtn, %PopoutBtn]:
		b.hide()
	var gear := Button.new()
	gear.name = "SettingsBtn"
	gear.icon = preload("res://ui/icons/gear.svg")
	gear.tooltip_text = "Settings"
	gear.theme_type_variation = %CameraBtn.theme_type_variation
	gear.custom_minimum_size = %CameraBtn.custom_minimum_size
	gear.expand_icon = %CameraBtn.expand_icon
	gear.pressed.connect(overlay.toggle)
	%CameraBtn.get_parent().add_child(gear)
	%CameraBtn.get_parent().move_child(gear, 0)

	# the person button shows the model picker along the bottom of the stage
	var models := Button.new()
	models.name = "ModelsBtn"
	models.icon = preload("res://studio/hud/person.svg")
	models.tooltip_text = "Models"
	models.theme_type_variation = gear.theme_type_variation
	models.custom_minimum_size = gear.custom_minimum_size
	models.expand_icon = gear.expand_icon
	%CameraBtn.get_parent().add_child(models)
	%CameraBtn.get_parent().move_child(models, 1)
	stage_models = PanelContainer.new()
	stage_models.name = "StageModels"
	stage_models.theme_type_variation = &"StagePanel"
	stage_models.visible = false
	stage_models.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE, Control.PRESET_MODE_MINSIZE, 16)
	stage_models.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var strip := _model_strip()
	strip.picked.connect(func (_p): stage_models.hide(), CONNECT_DEFERRED)
	stage_models.add_child(strip)
	layer.add_child(stage_models)
	layer.move_child(stage_models, 0)
	var welcome := WelcomeCard.new()
	layer.add_child(welcome)
	layer.move_child(welcome, 0)
	models.pressed.connect(func (): stage_models.visible = not stage_models.visible)

func _model_strip() -> ModelStrip:
	var strip := ModelStrip.new()
	strip.picked.connect(ModelLibrary.open)
	strip.import_requested.connect(_on_model_btn_pressed)
	return strip

func _process(delta: float) -> void:
	# fade the stage buttons when the mouse rests, bring them back on movement
	_idle += delta
	var target := 1.0 if _idle < IDLE_FADE_SECONDS or overlay.visible or stage_models.visible else 0.0
	%Menu.modulate.a = move_toward(%Menu.modulate.a, target, delta * 4.0)
	onscreen_buttons.modulate.a = %Menu.modulate.a
	_screen_button_check -= delta
	if _screen_button_check <= 0.0:
		_screen_button_check = 1.0
		refresh_screen_buttons()

var _screen_button_check := 0.0

## shows only the screen buttons a Musubi graph of the model listens to, labelled with what they trigger
## (checked once a second, graphs change in the editor and load after the model)
func refresh_screen_buttons() -> void:
	var labels := {}
	var model = stage.active_model if stage else null
	if model and show_screen_buttons:
		for graph in model.blueprints:
			for node in graph.get_children():
				if not node.has_method("get_type") or node.get_type() != &"screen_button":
					continue
				var mapping: Array = node.get_node("%Mapping").get_children()
				var idx := mapping.find_custom(func (b): return b.button_pressed)
				if idx >= 0:
					labels[idx] = _screen_button_label(graph, node)
	var buttons: Array = onscreen_buttons.get_node("%Buttons").get_children()
	for i in buttons.size():
		var b: Button = buttons[i]
		b.visible = i in labels
		if b.visible:
			b.text = labels[i].left(4)
			b.tooltip_text = labels[i]
			b.clip_text = true
	onscreen_buttons.visible = not labels.is_empty()

func _screen_button_label(graph, node) -> String:
	for c in graph.connections:
		if c.from_node != node.name:
			continue
		var target = graph.get_node_or_null(NodePath(c.to_node))
		if target == null:
			continue
		if target.has_method("short_label"):
			return target.short_label()
		if "expression" in target and target.expression:
			return target.expression
		if target.has_node("%Animation"):
			var anim: OptionButton = target.get_node("%Animation")
			if anim.selected >= 0:
				return anim.get_item_text(anim.selected)
	return str(node.get_node("%Mapping").get_children().find_custom(func (b): return b.button_pressed) + 1)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_idle = 0.0
	if stage_models.visible and event.is_action_pressed("ui_cancel"):
		stage_models.hide()
		get_viewport().set_input_as_handled()

func _close_panel():
	if open != null:
		var t: Tween = open.create_tween()
		t.tween_property(
			open,
			"offset_right",
			open.size.x,
			0.3
		).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_CUBIC).from(0)
		t.tween_callback(open.hide)
		t.tween_callback(open.teardown)
		
		open = null

func _open_panel(panel):
	if panel != null:
		# ignore opening panels that require a model when a model isn't present
		if panel.get_meta("model", false) and stage.active_model == null:
			return
			
	if panel == open:
		return
	
	_close_panel()
	if panel != null:
		panel.show()
		await panel.setup()
		panel.create_tween().tween_property(
			panel,
			"offset_right",
			0,
			0.3
		).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_CUBIC).from(panel.size.x)
	
	open = panel
	
func _clear_buttons():
	for b in group.get_buttons():
		b.button_pressed = false
	_close_panel()

func load_settings(settings: Dictionary):
	super.load_settings(settings)
	
	show_screen_buttons = settings.get("show_screen_buttons", true)
	var do_popup = settings.get("popout_controls", false)
	if do_popup:
		await get_tree().process_frame
		self.popout()
	
func save_settings(settings: Dictionary):
	super.save_settings(settings)
	
	settings["popout_controls"] = self.is_floating
	settings["show_screen_buttons"] = show_screen_buttons
	
func _on_screenshot_btn_pressed() -> void:
	var stage = get_tree().get_first_node_in_group("system:stage")
	var filename = await Screenshot.snap(stage.capture_viewport)
	var toast = get_tree().get_first_node_in_group("system:alert")
	toast.alert("Screenshot saved: %s" % filename)
	
func _on_model_btn_pressed() -> void:
	if not model_browser_opened:
		model_browser_opened = true
		var models_dir = ModelManager.formats["l2d"].model_directory()
		DirAccess.make_dir_recursive_absolute(models_dir)
		%ModelBrowser.current_dir = ProjectSettings.globalize_path(models_dir)
	%ModelBrowser.show()

func _on_model_browser_file_selected(path: String) -> void:
	ModelLibrary.add_imported(path)
	ModelLibrary.open(path)
	stage_models.hide()
