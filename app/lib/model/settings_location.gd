## Where Yorishiro keeps a model's own settings (<key>.yori.json): in the app's data folder, keyed by the
## model file, never in the model's folder. Model folders belong to the user and are often shared with
## VTube Studio, a synced folder or a read-only copy.
## Settings an older OpenVT install left next to the model (<name>.ovt.json, same format) are copied over
## once and left untouched, so moving to Yorishiro keeps a user's bindings.
extends RefCounted

const DIR = "user://model_settings"
const EXTENSION = ".yori.json"

static func resolve(model_file: String, legacy_file: String) -> String:
	var key := ProjectSettings.globalize_path(model_file).md5_text()
	var path := DIR.path_join(key + EXTENSION)
	if not FileAccess.file_exists(path):
		DirAccess.make_dir_recursive_absolute(DIR)
		# early Yorishiro builds stored the same file here under the old extension
		var early := DIR.path_join(key + ".ovt.json")
		if FileAccess.file_exists(early):
			DirAccess.rename_absolute(early, path)
		elif FileAccess.file_exists(legacy_file):
			DirAccess.copy_absolute(legacy_file, path)
	return path
