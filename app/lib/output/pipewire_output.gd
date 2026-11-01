## Sends the stage to OBS as a PipeWire video stream with alpha (D34, the Linux counterpart of Spout2).
## The PipeWireStageOut node (addons/yorishiro_pipewire, crates/pipewire-gd, libfunnel) copies the stage on
## the graphics card into the stream as soon as each frame is drawn, no pixels go through the CPU. OBS
## receives it with a PipeWire video source (the obs-pwvideo plugin). Only the stage goes out, not the
## settings or buttons.
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
var _out: RefCounted
var _running := false
var _state := ""

func _init() -> void:
	name = "PipeWireOutput"
	add_to_group("persist")
	add_to_group("output:pipewire")

func _ready() -> void:
	RenderingServer.frame_post_draw.connect(_send_frame)

func _start() -> void:
	var stage = get_tree().get_first_node_in_group("system:stage")
	_viewport = stage.capture_viewport if stage else get_viewport()
	if not ClassDB.class_exists(&"PipeWireStageOut"):
		_set_status(tr("The PipeWire output is not built (addons/yorishiro_pipewire). Run app/build_dependencies.sh."), false)
		return
	if _out == null:
		_out = ClassDB.instantiate(&"PipeWireStageOut")
	var err: String = _out.start(STREAM_NAME)
	if err:
		_set_status(_explain(err), false)
		return
	_running = true
	_state = ""
	_set_status(tr("Starting..."), true)

func _stop() -> void:
	if _out:
		_out.stop()
	_running = false
	_set_status("", true)

func _exit_tree() -> void:
	_stop()

func _send_frame() -> void:
	if not _running:
		return
	var err: String = _out.send(_viewport.get_texture().get_rid())
	if err:
		_running = false
		_set_status(_explain(err), false)

func _process(_delta: float) -> void:
	if not _running:
		return
	var size := Vector2i(_viewport.get_texture().get_size())
	var state: String = "%s %s" % [_out.state(), size]
	if state == _state:
		return
	_state = state
	if state.begins_with("streaming"):
		_set_status(tr("Sending to OBS"), true)
	else:
		_set_status(tr("Sending %sx%s, waiting for OBS") % [size.x, size.y], true)

## the failures users can act on, with what to do
func _explain(error: String) -> String:
	if error.begins_with("connecting to PipeWire"):
		return tr("PipeWire is not running or not reachable.")
	if error.begins_with("setting up the PipeWire stream"):
		return tr("PipeWire refused the stream. It needs PipeWire 1.2 or newer, and OBS 31 or newer on NVIDIA.") + " (%s)" % error
	if error.begins_with("needs the Vulkan renderer"):
		return tr("Sending to OBS needs the Vulkan renderer (Forward+ or Mobile).")
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
