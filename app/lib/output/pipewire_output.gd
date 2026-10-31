## Sends the stage to OBS as a PipeWire video stream with alpha (D34, the Linux counterpart of Spout2).
## The stage is copied into a frame file in /dev/shm every frame and the helper yorishiro-funnel
## (app/native/funnel_out, libfunnel) publishes it; OBS receives it with a PipeWire video source (the
## obs-pwvideo plugin). Only the stage goes out, not the settings or buttons.
## Saved in the profile as window.pipewire_out.
extends Node

signal status_changed(text: String, ok: bool)

const STREAM_NAME = "Yorishiro"

var enabled := false:
	set(on):
		if on == enabled:
			return
		enabled = on
		if on:
			_start()
		else:
			_stop()
var status := ""
var status_ok := true

var _viewport: Viewport
var _file: FileAccess
var _path := ""
var _proc := {}
var _seq := 0
var _size := Vector2i.ZERO
var _partial := ""

func _init() -> void:
	name = "PipeWireOutput"
	add_to_group("persist")
	add_to_group("output:pipewire")

func _ready() -> void:
	RenderingServer.frame_post_draw.connect(_write_frame)

func helper_path() -> String:
	var override = OS.get_environment("YORISHIRO_FUNNEL")
	if override:
		return override
	var app_dir = ProjectSettings.globalize_path("res://").trim_suffix("/")
	return app_dir.path_join("native/funnel_out/build/yorishiro-funnel")

func _start() -> void:
	var stage = get_tree().get_first_node_in_group("system:stage")
	_viewport = stage.capture_viewport if stage else get_viewport()
	var helper := helper_path()
	if not FileAccess.file_exists(helper):
		_set_status(tr("The PipeWire helper is not built (%s).") % helper, false)
		return
	_path = "/dev/shm/yorishiro-stage-%d.rgba" % OS.get_process_id()
	_file = FileAccess.open(_path, FileAccess.WRITE_READ)
	if _file == null:
		_set_status(tr("Cannot write %s.") % _path, false)
		return
	_seq = 0
	_size = Vector2i.ZERO
	_launch(helper)

func _launch(helper: String) -> void:
	_proc = OS.execute_with_pipe(helper, [_path, STREAM_NAME, "--parent-pid", str(OS.get_process_id())], false)
	if _proc.is_empty():
		_set_status(tr("Could not start the PipeWire helper."), false)
		return
	_set_status(tr("Starting..."), true)

func _stop() -> void:
	if not _proc.is_empty() and OS.is_process_running(_proc["pid"]):
		OS.kill(_proc["pid"])
	_proc = {}
	_file = null
	if _path:
		DirAccess.remove_absolute(_path)
	_path = ""
	_set_status("", true)

func _exit_tree() -> void:
	_stop()

func _write_frame() -> void:
	if not enabled or _file == null:
		return
	var image := _viewport.get_texture().get_image()
	if image == null:
		return
	image.convert(Image.FORMAT_RGBA8)
	var size := image.get_size()
	if size != _size:
		_size = size  # the helper sees the new size and exits with 3, _process starts it again
	_file.seek(0)
	_file.store_32(_seq + 1)  # odd while writing
	_file.flush()
	_file.store_32(size.x)
	_file.store_32(size.y)
	_file.store_32(0)
	_file.store_buffer(image.get_data())
	_seq += 2
	_file.seek(0)
	_file.store_32(_seq)
	_file.flush()

func _process(_delta: float) -> void:
	if _proc.is_empty():
		return
	var err: FileAccess = _proc["stderr"]
	var chunk := err.get_buffer(4096)
	if not chunk.is_empty():
		var lines := (_partial + chunk.get_string_from_utf8()).split("\n")
		_partial = lines[-1]
		for i in lines.size() - 1:
			var line: String = lines[i]
			if line.begins_with("status: error: "):
				_set_status(_explain(line.trim_prefix("status: error: ")), false)
			elif line.begins_with("status: "):
				_set_status(_translate(line.trim_prefix("status: ")), true)
	if not OS.is_process_running(_proc["pid"]):
		var code := OS.get_process_exit_code(_proc["pid"])
		_proc = {}
		if enabled and (code == 3 or code == 0):  # new frame size, or it stopped while we kept writing
			_launch(helper_path())
		elif enabled and status_ok:
			_set_status(tr("The PipeWire helper stopped (exit code %d).") % code, false)

func _translate(text: String) -> String:
	var m := RegEx.create_from_string("^streaming (\\d+)x(\\d+)").search(text)
	if m:
		return tr("Sending %sx%s, waiting for OBS") % [m.get_string(1), m.get_string(2)]
	if text.begins_with("OBS"):
		return tr("Sending to OBS")
	return text

## the failures users can act on, with what to do
func _explain(error: String) -> String:
	if error.begins_with("connecting to PipeWire"):
		return tr("PipeWire is not running or not reachable.")
	if error.begins_with("setting up the PipeWire stream"):
		return tr("PipeWire refused the stream. NVIDIA drivers need PipeWire 1.2 or newer and OBS 31 or newer.") + " (%s)" % error
	return error

func _set_status(text: String, ok: bool) -> void:
	status = text
	status_ok = ok
	status_changed.emit(text, ok)

func load_settings(data: Dictionary) -> void:
	enabled = bool(data.get("window", {}).get("pipewire_out", false))

func save_settings(data: Dictionary) -> void:
	var w = data.get("window", {})
	w["pipewire_out"] = enabled
	data["window"] = w
