## The stage backgrounds the user can pick from (VTube Studio's background library): every picture in
## user://Backgrounds and pictures chosen from elsewhere with the file browser. Files stay where they are,
## only their paths are remembered.
extends Node

signal changed

const DIR = "user://Backgrounds"
const STATE = "user://background_library.cfg"
const EXTENSIONS = ["png", "jpg", "jpeg", "webp"]

var _cfg := ConfigFile.new()

func _ready() -> void:
	_cfg.load(STATE)
	DirAccess.make_dir_recursive_absolute(DIR)

## [{path, name}] by name
func list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen := {}
	var dir := ProjectSettings.globalize_path(DIR)
	var paths: Array = []
	for f in DirAccess.get_files_at(dir):
		if f.get_extension().to_lower() in EXTENSIONS:
			paths.append(DIR.path_join(f))  # user:// so the setting survives moving the data folder
	paths.append_array(_cfg.get_value("library", "imported", []))
	for p in paths:
		if p in seen or not FileAccess.file_exists(p):
			continue
		seen[p] = true
		out.append({"path": p, "name": p.get_file().get_basename()})
	out.sort_custom(func (a, b): return a.name.naturalnocasecmp_to(b.name) < 0)
	return out

## a picture chosen with the file browser stays in the list
func add_imported(path: String) -> void:
	if path.begins_with(DIR) or path.begins_with(ProjectSettings.globalize_path(DIR)):
		return
	var imported: Array = _cfg.get_value("library", "imported", [])
	if path in imported:
		return
	imported.append(path)
	_cfg.set_value("library", "imported", imported)
	_cfg.save(STATE)
	changed.emit()
