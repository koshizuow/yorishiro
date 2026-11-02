## The app in the desktop's application menu, with its icon in the dock: an AppImage or a tar.gz is not installed, so the
## desktop knows neither. Only on request, from the About page, as it writes to the user's home folder.
extends RefCounted

## the window's app id: desktops match it to the file's name or to StartupWMClass
const ID = "Yorishiro"
const ICON = "yorishiro"

static func available() -> bool:
	return _program() != "" and FileAccess.file_exists(_icon_source())

static func installed() -> bool:
	return FileAccess.file_exists(_entry_path())

## The running AppImage or release binary, again when the file moved. An empty string, or what went wrong.
static func install() -> String:
	var icon_dir := _data().path_join("icons/hicolor/scalable/apps")
	var entry := _entry_path()
	for dir in [icon_dir, entry.get_base_dir()]:
		if DirAccess.make_dir_recursive_absolute(dir) != OK:
			return tr_error(dir)
	if DirAccess.copy_absolute(_icon_source(), icon_dir.path_join(ICON + ".svg")) != OK:
		return tr_error(icon_dir)
	var file := FileAccess.open(entry, FileAccess.WRITE)
	if file == null:
		return tr_error(entry)
	file.store_string("\n".join([
		"[Desktop Entry]", "Type=Application", "Name=Yorishiro", "Comment=Live2D VTuber app with face tracking",
		"Exec=%s" % _quoted(_program()), "Icon=%s" % ICON, "StartupWMClass=%s" % ID, "Categories=AudioVideo;Video;",
		"Terminal=false", ""]))
	file.close()
	return ""

static func remove() -> void:
	DirAccess.remove_absolute(_entry_path())
	DirAccess.remove_absolute(_data().path_join("icons/hicolor/scalable/apps").path_join(ICON + ".svg"))

static func tr_error(path: String) -> String:
	return "Cannot write %s." % path

static func _program() -> String:
	var appimage := OS.get_environment("APPIMAGE")
	if appimage != "":
		return appimage
	return OS.get_executable_path() if OS.has_feature("template") else ""

## beside the program in a release
static func _icon_source() -> String:
	return OS.get_executable_path().get_base_dir().path_join(ICON + ".svg")

## another copy of the app has XDG_DATA_HOME set to its own folder
static func _data() -> String:
	var set_by_user := OS.get_environment("XDG_DATA_HOME")
	if set_by_user != "" and preload("res://lib/instance.gd").number() == 1:
		return set_by_user
	return OS.get_environment("HOME").path_join(".local/share")

static func _entry_path() -> String:
	return _data().path_join("applications").path_join(ID + ".desktop")

## the Exec key's quoting (Desktop Entry spec), % doubled as a field code
static func _quoted(path: String) -> String:
	var escaped := path.replace("\\", "\\\\").replace("\"", "\\\"").replace("`", "\\`").replace("$", "\\$")
	return "\"%s\"" % escaped.replace("%", "%%")
