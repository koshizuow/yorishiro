## The platform layer: res://platform/platform.gd when a build has one (a build for another system adds it with its
## own outputs and settings), else nothing. The app asks it for what differs between systems through hooks, each
## optional, and keeps its own behaviour where the layer has none:
##   stage_output() -> Node               the stage's output to OBS and other apps where PipeWire is not there
##   add_output_rows(panel, anchor) -> Node  rows for those outputs in the camera panel, after anchor; returns the last
##   automation(automation, args)         its own automation checks (awaited), after the app's
## Translations for its strings go in res://platform/i18n/*.translation, added at start (lib/locale.gd).
class_name Platform

const PATH := "res://platform/platform.gd"
const I18N := "res://platform/i18n"

static var _layer: Object = null
static var _loaded := false

static func layer() -> Object:
	if not _loaded:
		_loaded = true
		if ResourceLoader.exists(PATH):
			_layer = load(PATH).new()
	return _layer

static func has_hook(hook: String) -> bool:
	var l := layer()
	return l != null and l.has_method(hook)

## the hook's result, or null when the layer or the hook is missing
static func call_hook(hook: String, args: Array = []) -> Variant:
	if not has_hook(hook):
		return null
	return layer().callv(hook, args)

## the layer's translations, if it has any
static func add_translations() -> void:
	if not DirAccess.dir_exists_absolute(I18N):
		return
	for f in ResourceLoader.list_directory(I18N):
		if f.ends_with(".translation"):
			var t = load(I18N.path_join(f))
			if t is Translation:
				TranslationServer.add_translation(t)
