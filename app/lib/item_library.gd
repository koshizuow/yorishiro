## The items the user can put on the stage (VTube Studio's item library): every picture in user://Items,
## folders of PNG frames there as animations, folders with a Live2D model (.model3.json in the folder or one below,
## as VTS keeps Live2D items), and items added from elsewhere with the file browser.
## The files stay where they are, only their paths are remembered.
extends Node

signal changed

const DIR = "user://Items"
const STATE = "user://item_library.cfg"
const IMAGE_EXTENSIONS = ["png", "jpg", "jpeg", "webp", "svg", "gif"]
const AnimFrames = preload("res://lib/utils/anim_frames.gd")
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
		var model := live2d_in(dir.path_join(d))
		if model:
			var e := _entry(PackedStringArray([model]))
			e.name = d
			out.append(e)
			continue
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
	var img := AnimFrames.load_still(path)
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
	if first.ends_with(".model3.json"):
		return {"paths": paths, "name": first.get_base_dir().get_file(), "animated": false, "live2d": true, "thumb": live2d_thumbnail(first)}
	var name := first.get_base_dir().get_file() if paths.size() > 1 else first.get_file().get_basename()
	# GIF and APNG files count as animations (decoding each to be sure would slow the list down)
	var animated := paths.size() > 1 or first.get_extension().to_lower() in ["gif", "apng"]
	return {"paths": paths, "name": name, "animated": animated, "thumb": first}

## the .model3.json of a Live2D item folder (in it or one folder below), "" when there is none
static func live2d_in(dir: String) -> String:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".model3.json"):
			return dir.path_join(f)
	for sub in DirAccess.get_directories_at(dir):
		for f in DirAccess.get_files_at(dir.path_join(sub)):
			if f.ends_with(".model3.json"):
				return dir.path_join(sub).path_join(f)
	return ""

## a picture for a Live2D item's card: icon.png beside the model or in the item folder, else its first texture
static func live2d_thumbnail(model3: String) -> String:
	for d in [model3.get_base_dir(), model3.get_base_dir().get_base_dir()]:
		for name in ["icon.png", "Icon.png", "thumbnail.png"]:
			if FileAccess.file_exists(d.path_join(name)):
				return d.path_join(name)
	var data = JSON.parse_string(FileAccess.get_file_as_string(model3))
	if data is Dictionary:
		var textures: Array = data.get("FileReferences", {}).get("Textures", [])
		if textures.size() > 0:
			return model3.get_base_dir().path_join(textures[0])
	return ""

## PNG frames of an animation folder, in name order
func _frames(dir: String) -> PackedStringArray:
	return AnimFrames.folder_frames(dir)
