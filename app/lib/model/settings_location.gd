## Where Yorishiro keeps a model's own settings (the OpenVT .ovt.json format): in the app's data folder,
## keyed by the model file, never in the model's folder. Model folders belong to the user and are often
## shared with VTube Studio, a synced folder or a read-only copy.
## A legacy <name>.ovt.json next to the model (written by OpenVT) is copied over once and left untouched.
extends RefCounted

const DIR = "user://model_settings"

static func resolve(model_file: String, legacy_file: String) -> String:
	var key := ProjectSettings.globalize_path(model_file).md5_text()
	var path := DIR.path_join("%s.ovt.json" % key)
	if not FileAccess.file_exists(path):
		DirAccess.make_dir_recursive_absolute(DIR)
		if FileAccess.file_exists(legacy_file):
			DirAccess.copy_absolute(legacy_file, path)
	return path
