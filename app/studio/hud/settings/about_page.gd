## About page of the settings overlay: what Yorishiro is, where it came from (a fork of OpenVT) and every
## third-party component with its license. The full license texts open below the list.
extends ScrollContainer

## [name, author or source, license, what it does here]
const COMPONENTS = [
	["OpenVT", "erodozer", "MIT", "The app this one was forked from"],
	["Godot Engine", "Godot contributors, with the custom blend modes patch (godot#116686)", "MIT", "Game engine the app runs on"],
	["Katashiro", "Yorishiro's fork of ayagami-gd by The Ayagami Project Contributors", "MIT", "Live2D models in Godot"],
	["Ayagami", "The Ayagami Project Contributors", "MIT / Apache-2.0", "Live2D renderer (the core library Katashiro uses)"],
	["gd-virtualcamera", "erodozer", "Unlicense", "Virtual webcam output"],
	["libfunnel", "the libfunnel contributors", "MIT", "Sending the stage to OBS over PipeWire"],
	["PipeWire", "PipeWire contributors", "MIT", "Sending the stage to OBS over PipeWire"],
	["godot-keylogger", "erodozer", "MIT", "Global hotkeys"],
	["godot-rust and Rust crates", "crates.io authors", "MPL-2.0 and others", "Native addons"],
	["jf open 粉圓 (Huninn)", "justfont", "SIL OFL 1.1", "Interface font"],
	["MediaPipe Face Landmarker", "Google", "Apache-2.0", "Face tracking models (yorishiro-tracker)"],
	["ICT-FaceKit", "USC Institute for Creative Technologies", "MIT", "Expression shapes (yorishiro-tracker) and the 3D head of the tracking preview"],
]
## license files shown in full, the app's own first
const LICENSE_FILES = [
	["Yorishiro app (with OpenVT)", "res://LICENSE.txt"],
	["Katashiro (fork of ayagami-gd)", "res://license/LICENSE.katashiro.md"],
	["gd-virtualcamera", "res://license/LICENSE.gdvirtualcamera.md"],
	["libfunnel", "res://license/LICENSE.libfunnel.txt"],
	["godot-keylogger", "res://license/LICENSE.keylogger.md"],
	["jf open 粉圓 (Huninn)", "res://ui/fonts/OFL.txt"],
	["ICT-FaceKit", "res://license/LICENSE.ict-facekit.txt"],
]

var _texts := RichTextLabel.new()

func _init() -> void:
	name = "AboutPage"
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 14)
	add_child(column)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 18)
	var icon := TextureRect.new()
	icon.texture = load("res://branding/icon.svg")
	icon.custom_minimum_size = Vector2(88, 88)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	head.add_child(icon)
	var names := VBoxContainer.new()
	names.alignment = BoxContainer.ALIGNMENT_CENTER
	var title := Label.new()
	title.text = "Yorishiro"
	title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	title.add_theme_font_size_override("font_size", 30)
	names.add_child(title)
	var version := Label.new()
	version.text = tr("Version %s") % ProjectSettings.get_setting("application/config/version", "dev")
	version.theme_type_variation = &"FieldLabel"
	names.add_child(version)
	head.add_child(names)
	column.add_child(head)

	column.add_child(_paragraph(tr("Yorishiro is a VTubing app with its own face tracker. Its app started as a fork of OpenVT by erodozer, released under the MIT license. Yorishiro is not the OpenVT project, please send problems with Yorishiro to Yorishiro.")))
	column.add_child(_paragraph(tr("\"Live2D\" and \"Cubism\" are trademarks of Live2D Inc. \"VTube Studio\" is a trademark of its respective owner. Yorishiro is not affiliated with them and does not include the Live2D Cubism SDK.")))

	var heading := Label.new()
	heading.text = "Open source components"
	heading.theme_type_variation = &"BoldLabel"
	column.add_child(heading)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 6)
	for c in COMPONENTS:
		var who := Label.new()
		who.text = "%s\n%s" % [c[0], c[1]]
		who.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		grid.add_child(who)
		var lic := Label.new()
		lic.text = c[2]
		lic.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		lic.theme_type_variation = &"FieldLabel"
		grid.add_child(lic)
		var role := Label.new()
		role.text = c[3]
		role.theme_type_variation = &"FieldLabel"
		role.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		role.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		grid.add_child(role)
	column.add_child(grid)

	var show := Button.new()
	show.name = "LicenseTextsBtn"
	show.text = "Show full license texts"
	show.toggle_mode = true
	show.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	show.toggled.connect(func (on): _texts.visible = on; if on and _texts.text.is_empty(): _fill_texts())
	column.add_child(show)
	_texts.visible = false
	_texts.fit_content = true
	_texts.selection_enabled = true
	_texts.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	column.add_child(_texts)

func _paragraph(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l

func _fill_texts() -> void:
	for f in LICENSE_FILES:
		_texts.push_bold()
		_texts.add_text(f[0])
		_texts.pop()
		_texts.add_text("\n\n%s\n\n" % FileAccess.get_file_as_string(f[1]).strip_edges())
