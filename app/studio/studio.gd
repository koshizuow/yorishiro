extends Control

const Serializers = preload("res://lib/utils/serializers.gd")

func _ready() -> void:
	if not Engine.is_embedded_in_editor():
		get_window().borderless = false

	var scale = DisplayServer.screen_get_scale()
	DisplayServer.window_set_min_size(Vector2i(540,360) * scale, 0)

## sizes are stored in logical pixels so they survive a change of display scale
func save_settings(settings: Dictionary):
	var scale = DisplayServer.screen_get_scale()

	var window_settings = settings.get("window", {})
	window_settings["size"] = Serializers.Vec2Serializer.to_json(Vector2(get_window().size) / scale)
	settings["window"] = window_settings

func load_settings(settings: Dictionary):
	var scale = DisplayServer.screen_get_scale()
	var window_prefs = settings.get("window", {})

	var default_size = Vector2i(
		ProjectSettings.get_setting("display/window/size/viewport_width"),
		ProjectSettings.get_setting("display/window/size/viewport_height")
	)
	var size = default_size
	var saved = window_prefs.get("size", {})
	if saved is Dictionary:
		size = Serializers.Vec2Serializer.from_json(saved, default_size)

	var win: Window = get_window()
	win.size = Vector2i(Vector2(size) * scale)
	win.content_scale_factor = scale
	win.move_to_center()
