## The app in the desktop's application menu, with its icon in the dock: an AppImage or a tar.gz is not installed, so the
## desktop knows neither. Only on request, from the About page, as it writes to the user's home folder.
## The entry is app/branding/io.github.koshizuow.yorishiro.desktop, shipped beside the program in a release (the same
## file the AppImage carries for Gear Lever and AppImageLauncher); only its Exec line is replaced.
extends RefCounted

## the AppStream id: the name of the desktop file, the icon and the metainfo
const ID = "io.github.koshizuow.yorishiro"
## the window's class: desktops match it to the entry through StartupWMClass
const WM_CLASS = "Yorishiro"
## what versions up to 0.1.4 wrote, removed when the entry is written or removed
const OLD_ENTRY = "Yorishiro.desktop"
const OLD_ICON = "yorishiro.svg"

static func available() -> bool:
	return _program() != "" and FileAccess.file_exists(_icon_source()) and FileAccess.file_exists(_entry_source())

static func installed() -> bool:
	return FileAccess.file_exists(_entry_path())

## A menu entry for this app that something else made (Gear Lever, AppImageLauncher, a package): adding ours too
## would show Yorishiro twice. The file's name, or an empty string.
static func integrated_elsewhere() -> String:
	var dir := _data().path_join("applications")
	for file in DirAccess.get_files_at(dir):
		if not file.ends_with(".desktop") or file == ID + ".desktop" or file == OLD_ENTRY:
			continue
		var text := FileAccess.get_file_as_string(dir.path_join(file))
		for line in text.split("\n"):
			line = line.strip_edges()
			if line == "StartupWMClass=" + WM_CLASS or line == "Icon=" + ID:
				return file
	return ""

## The running AppImage or release binary, again when the file moved. An empty string, or what went wrong.
static func install() -> String:
	var icon_dir := _icon_dir()
	var entry := _entry_path()
	for dir in [icon_dir, entry.get_base_dir()]:
		if DirAccess.make_dir_recursive_absolute(dir) != OK:
			return tr_error(dir)
	if DirAccess.copy_absolute(_icon_source(), icon_dir.path_join(ID + ".svg")) != OK:
		return tr_error(icon_dir)
	var lines := PackedStringArray()
	for line in FileAccess.get_file_as_string(_entry_source()).split("\n"):
		lines.append("Exec=%s" % _quoted(_program()) if line.begins_with("Exec=") else line)
	var file := FileAccess.open(entry, FileAccess.WRITE)
	if file == null:
		return tr_error(entry)
	file.store_string("\n".join(lines))
	file.close()
	_remove_old()
	return ""

static func remove() -> void:
	DirAccess.remove_absolute(_entry_path())
	DirAccess.remove_absolute(_icon_dir().path_join(ID + ".svg"))
	_remove_old()

static func tr_error(path: String) -> String:
	return "Cannot write %s." % path

static func _remove_old() -> void:
	DirAccess.remove_absolute(_data().path_join("applications").path_join(OLD_ENTRY))
	DirAccess.remove_absolute(_icon_dir().path_join(OLD_ICON))

static func _program() -> String:
	var appimage := OS.get_environment("APPIMAGE")
	if appimage != "":
		return appimage
	return OS.get_executable_path() if OS.has_feature("template") else ""

## beside the program in a release
static func _icon_source() -> String:
	return OS.get_executable_path().get_base_dir().path_join(ID + ".svg")

static func _entry_source() -> String:
	return OS.get_executable_path().get_base_dir().path_join(ID + ".desktop")

static func _icon_dir() -> String:
	return _data().path_join("icons/hicolor/scalable/apps")

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
