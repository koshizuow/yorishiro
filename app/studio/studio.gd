extends Control

const Serializers = preload("res://lib/utils/serializers.gd")

static var _display_scale := 0.0

## the desktop's display scale (200% gives 2). Wayland reports it. Under X11 Godot always says 1, there the desktop's
## Xft.dpi tells it (GNOME and KDE set it for X apps, 192 at 200%).
static func display_scale() -> float:
	if _display_scale > 0.0:
		return _display_scale
	_display_scale = DisplayServer.screen_get_scale()
	if _display_scale == 1.0 and DisplayServer.get_name() == "X11":
		var out := []
		if OS.execute("xrdb", ["-query"], out) == 0 and not out.is_empty():
			for line in String(out[0]).split("\n"):
				if line.begins_with("Xft.dpi:"):
					var dpi := line.get_slice(":", 1).strip_edges().to_float()
					if dpi > 96.0:
						_display_scale = snappedf(dpi / 96.0, 0.25)
	return _display_scale

func _ready() -> void:
	if not Engine.is_embedded_in_editor():
		get_window().borderless = false

	var scale = display_scale()
	DisplayServer.window_set_min_size(Vector2i(540,360) * scale, 0)

## sizes are stored in logical pixels so they survive a change of display scale
func save_settings(settings: Dictionary):
	var scale = display_scale()

	var window_settings = settings.get("window", {})
	window_settings["size"] = Serializers.Vec2Serializer.to_json(Vector2(get_window().size) / scale)
	settings["window"] = window_settings

func load_settings(settings: Dictionary):
	var scale = display_scale()
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
