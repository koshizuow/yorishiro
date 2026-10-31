## UI language. Traditional Chinese by default, English selectable. Kept outside the profiles in
## user://locale.cfg because it belongs to the user, not to a stream setup.
## Translations live in res://i18n/ui.csv, keyed by the English text so existing scenes translate without edits.
extends Node

const PATH = "user://locale.cfg"
const DEFAULT = "zh_TW"

func _enter_tree() -> void:
	var cfg := ConfigFile.new()
	cfg.load(PATH)
	TranslationServer.set_locale(cfg.get_value("ui", "language", DEFAULT))

func set_language(code: String) -> void:
	TranslationServer.set_locale(code)
	var cfg := ConfigFile.new()
	cfg.load(PATH)
	cfg.set_value("ui", "language", code)
	cfg.save(PATH)
