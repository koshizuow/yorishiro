## The models the user can pick from: every model in the formats' model folders plus models imported from
## elsewhere, most recently used first, each with a thumbnail.
## Thumbnails are taken from the stage itself a moment after a model loads (head and upper body, transparent
## background), so every model gets a real picture without the user setting an icon. A model that was never
## loaded uses a VTube Studio icon when its .vtube.json names one, otherwise none (the UI draws a placeholder).
extends Node

signal changed

const STATE = "user://model_library.cfg"
const THUMBS = "user://thumbnails"
const THUMB_SIZE = Vector2i(192, 256)
## frames to wait after a model appears, so physics and the entry tween have settled
const SETTLE_FRAMES = 45

var _cfg := ConfigFile.new()

func _ready() -> void:
	_cfg.load(STATE)
	DirAccess.make_dir_recursive_absolute(THUMBS)

## the HUD hands over the stage once both exist
func watch(stage: Node) -> void:
	if not stage.model_changed.is_connected(_on_model_changed):
		stage.model_changed.connect(_on_model_changed.bind(stage))

## [{path, name, format, thumbnail (Texture2D or null), last_used (unix time, 0 if never)}], newest first
func list() -> Array[Dictionary]:
	var paths := {}
	for fmt in ModelManager.formats.values():
		if fmt.has_method("model_directory"):
			for p in _find_models(fmt.model_directory(), fmt.supported_extension()):
				paths[p] = true
	for p in _cfg.get_value("library", "imported", []):
		if FileAccess.file_exists(p):
			paths[p] = true
	var out: Array[Dictionary] = []
	for p in paths:
		out.append({
			"path": p,
			"name": _display_name(p),
			"format": "VRM" if p.ends_with(".vrm") else "Live2D",
			"thumbnail": thumbnail(p),
			"last_used": int(_cfg.get_value("last_used", _key(p), 0)),
		})
	out.sort_custom(func (a, b):
		if a.last_used != b.last_used:
			return a.last_used > b.last_used
		return a.name.naturalnocasecmp_to(b.name) < 0)
	return out

## loads a model onto the stage and remembers it
func open(path: String) -> void:
	var model = ModelManager.make_model(path)
	if model == null:
		get_tree().get_first_node_in_group("system:alert").alert(tr("Unable to load model"))
		return
	var stage = get_tree().get_first_node_in_group("system:stage")
	stage.spawn_model(model)

## a model picked from outside the model folders stays in the list
func add_imported(path: String) -> void:
	var imported: Array = _cfg.get_value("library", "imported", [])
	if path not in imported and not _inside_model_dirs(path):
		imported.append(path)
		_cfg.set_value("library", "imported", imported)
		_cfg.save(STATE)

func thumbnail(path: String) -> Texture2D:
	var file := _thumb_path(path)
	if FileAccess.file_exists(file):
		var img := Image.load_from_file(file)
		if img:
			return ImageTexture.create_from_image(img)
	var icon := _vts_icon(path)
	if icon:
		return icon
	return null

func _on_model_changed(model, stage) -> void:
	if model == null or not "modelmeta" in model or model.modelmeta == null:
		return
	# modelmeta.path is the folder, .model the file the library lists
	var path: String = model.modelmeta.model
	_cfg.set_value("last_used", _key(path), int(Time.get_unix_time_from_system()))
	_cfg.save(STATE)
	for i in SETTLE_FRAMES:
		await RenderingServer.frame_post_draw
	if is_instance_valid(model) and stage.active_model == model:
		_capture(model, stage.capture_viewport, path)
	changed.emit()

## head and upper body from the stage: the opaque part of the model's rect, a 3:4 box at its top
func _capture(model, viewport: Viewport, path: String) -> void:
	var img := viewport.get_texture().get_image()
	var screen: Rect2 = model.get_global_transform_with_canvas() * model.rect
	var region := Rect2i(screen).intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	if region.size.x < 8 or region.size.y < 8:
		return
	var part := img.get_region(region)
	var used := part.get_used_rect()
	if used.size.x < 8 or used.size.y < 8:
		return
	var w := used.size.x
	var h := mini(used.size.y, w * THUMB_SIZE.y / THUMB_SIZE.x)
	if h < w * THUMB_SIZE.y / THUMB_SIZE.x:
		# a wide, short model: keep the height, narrow the box around the middle
		w = h * THUMB_SIZE.x / THUMB_SIZE.y
	var box := Rect2i(used.position.x + (used.size.x - w) / 2, used.position.y, w, h)
	var thumb := part.get_region(box)
	thumb.resize(THUMB_SIZE.x, THUMB_SIZE.y, Image.INTERPOLATE_LANCZOS)
	thumb.save_png(_thumb_path(path))

func _find_models(dir: String, extensions: Array, depth := 2) -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		# a Live2D folder has both .model3.json and .moc3, the json is the one to open
		if f.ends_with(".model3.json") or (f.ends_with(".vrm") and ".vrm" in extensions):
			out.append(dir.path_join(f))
	if depth > 0:
		for sub in d.get_directories():
			out.append_array(_find_models(dir.path_join(sub), extensions, depth - 1))
	return out

func _inside_model_dirs(path: String) -> bool:
	var g := ProjectSettings.globalize_path(path)
	for fmt in ModelManager.formats.values():
		if fmt.has_method("model_directory") and g.begins_with(ProjectSettings.globalize_path(fmt.model_directory())):
			return true
	return false

func _display_name(path: String) -> String:
	var file := path.get_file()
	for ext in [".model3.json", ".vrm"]:
		file = file.trim_suffix(ext)
	return file

## VTube Studio models name their icon in <name>.vtube.json, FileReferences.Icon
func _vts_icon(path: String) -> Texture2D:
	var dir := path.get_base_dir()
	var d := DirAccess.open(dir)
	if d == null:
		return null
	for f in d.get_files():
		if not f.ends_with(".vtube.json"):
			continue
		var data = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join(f)))
		if data is Dictionary and data.get("FileReferences") is Dictionary:
			var icon: String = data.FileReferences.get("Icon", "")
			if icon and FileAccess.file_exists(dir.path_join(icon)):
				var img := Image.load_from_file(dir.path_join(icon))
				if img:
					return ImageTexture.create_from_image(img)
	return null

func _key(path: String) -> String:
	return ProjectSettings.globalize_path(path).md5_text()

func _thumb_path(path: String) -> String:
	return THUMBS.path_join(_key(path) + ".png")
