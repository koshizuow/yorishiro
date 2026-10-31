extends "res://ui/popout_panel.gd"

const SettingsOverlay = preload("res://studio/hud/settings/settings_overlay.gd")
const HotkeysPage = preload("res://studio/hud/settings/hotkeys_page.gd")
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
	var layer := CanvasLayer.new()
	layer.name = "OverlayLayer"
	layer.layer = 10
	layer.add_to_group("hide_screenshot")
	add_child(layer)
	overlay = SettingsOverlay.new()
	layer.add_child(overlay)

	var load_model := Button.new()
	load_model.text = "Load Model..."
	load_model.pressed.connect(_on_model_btn_pressed)
	overlay.add_page(&"model", "Models & Items", PanelPage.new(preload("res://studio/hud/item_panel/item_panel.tscn"), "ItemPanel", [load_model]))
	overlay.add_page(&"hotkeys", "Hotkeys", HotkeysPage.new())
	overlay.add_page(&"settings", "Settings", PanelPage.new(preload("res://studio/hud/camera_panel/camera_panel.tscn"), "CameraPanel"))

	# the stage keeps a gear (settings), screenshot and nothing else
	for b in [%ModelBtn, %ItemBtn, %CameraBtn, %PopoutBtn]:
		b.hide()
	var gear := Button.new()
	gear.name = "SettingsBtn"
	gear.icon = preload("res://ui/icons/gear.svg")
	gear.tooltip_text = "Settings"
	gear.custom_minimum_size = %CameraBtn.custom_minimum_size
	gear.expand_icon = %CameraBtn.expand_icon
	gear.pressed.connect(overlay.toggle)
	%CameraBtn.get_parent().add_child(gear)
	%CameraBtn.get_parent().move_child(gear, 0)

func _process(delta: float) -> void:
	# fade the stage buttons when the mouse rests, bring them back on movement
	_idle += delta
	var target := 1.0 if _idle < IDLE_FADE_SECONDS or overlay.visible else 0.0
	%Menu.modulate.a = move_toward(%Menu.modulate.a, target, delta * 4.0)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_idle = 0.0

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
	
	var do_popup = settings.get("popout_controls", false)
	if do_popup:
		await get_tree().process_frame
		self.popout()
	
func save_settings(settings: Dictionary):
	super.save_settings(settings)
	
	settings["popout_controls"] = self.is_floating
	
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
	var model = ModelManager.make_model(path)
	if model:
		stage.spawn_model(model)
