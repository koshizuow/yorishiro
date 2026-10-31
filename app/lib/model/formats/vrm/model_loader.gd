extends "../model_loader.gd"

const SettingsLocation = preload("res://lib/model/settings_location.gd")

func model_format() -> StringName:
	return "VRM"
	
func supported_extension() -> Array[String]:
	return [".vrm"]

func mime_type() -> String:
	return "model/gltf-binary"

func strategy() -> Script:
	return preload("./model.gd")

func load_data(path: String) -> ModelMeta:
	var meta = ModelMeta.new()
	
	var base_name = path.get_file()
	var name = base_name
	for ext in supported_extension():
		name = name.trim_suffix(ext)
	meta.name = name
	meta.id = base_name
	meta.model = path
	meta.path = path.get_base_dir()
	meta.format = model_format()
	meta.settings_file = SettingsLocation.resolve(path, "%s/%s.ovt.json" % [meta.path, meta.name])
	
	return meta
