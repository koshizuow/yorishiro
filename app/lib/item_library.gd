## The items the user can put on the stage (VTube Studio's item library): every picture in user://Items,
## folders of PNG frames there as animations, and pictures added from elsewhere with the file browser.
## The files stay where they are, only their paths are remembered.
extends Node

signal changed

const DIR = "user://Items"
const STATE = "user://item_library.cfg"
const IMAGE_EXTENSIONS = ["png", "jpg", "jpeg", "webp", "svg"]
const THUMB = 112

var _cfg := ConfigFile.new()
var _thumbs := {}

func _ready() -> void:
	_cfg.load(STATE)
	DirAccess.make_dir_recursive_absolute(DIR)

## [{paths (PackedStringArray, several for an animation), name, animated}], by name
func list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var dir := ProjectSettings.globalize_path(DIR)
	for f in DirAccess.get_files_at(dir):
		if f.get_extension().to_lower() in IMAGE_EXTENSIONS:
			out.append(_entry(PackedStringArray([dir.path_join(f)])))
	for d in DirAccess.get_directories_at(dir):
		var frames := _frames(dir.path_join(d))
		if frames.size() > 1:
			out.append(_entry(frames))
	for p in _cfg.get_value("library", "imported", []):
		var paths := PackedStringArray(p)
		if paths.size() > 0 and Array(paths).all(func (x): return FileAccess.file_exists(x)):
			if not out.any(func (e): return e.paths == paths):
				out.append(_entry(paths))
	out.sort_custom(func (a, b): return a.name.naturalnocasecmp_to(b.name) < 0)
	return out

## an item added with the file browser stays in the list
func add_imported(paths: PackedStringArray) -> void:
	if paths.is_empty() or paths[0].begins_with(ProjectSettings.globalize_path(DIR)):
		return
	var imported: Array = _cfg.get_value("library", "imported", [])
	if Array(paths) in imported:
		return
	imported.append(Array(paths))
	_cfg.set_value("library", "imported", imported)
	_cfg.save(STATE)
	changed.emit()

func thumbnail(path: String) -> Texture2D:
	if path in _thumbs:
		return _thumbs[path]
	var img := Image.load_from_file(path)
	var tex: Texture2D = null
	if img:
		var s := float(THUMB) / maxf(img.get_width(), img.get_height())
		if s < 1.0:
			img.resize(maxi(1, int(img.get_width() * s)), maxi(1, int(img.get_height() * s)), Image.INTERPOLATE_LANCZOS)
		tex = ImageTexture.create_from_image(img)
	_thumbs[path] = tex
	return tex

func _entry(paths: PackedStringArray) -> Dictionary:
	var first: String = paths[0]
	var name := first.get_base_dir().get_file() if paths.size() > 1 else first.get_file().get_basename()
	return {"paths": paths, "name": name, "animated": paths.size() > 1}

## PNG frames of an animation folder, in name order
func _frames(dir: String) -> PackedStringArray:
	var files := Array(DirAccess.get_files_at(dir)).filter(func (f): return f.get_extension().to_lower() == "png")
	files.sort_custom(func (a, b): return a.naturalnocasecmp_to(b) < 0)
	return PackedStringArray(files.map(func (f): return dir.path_join(f)))
