## Yorishiro tracker input. Starts yorishiro-tracker in the background (unless one is already
## sending), receives frames, status and camera previews over the local link, and controls it.
## Protocol: yorishiro_tracker/sinks/link.py.
extends "../camera_tracker.gd"

const DATA_PORT = 39570
const CONTROL_PORT = 39571
## an already running tracker (started by hand for development) is used if it speaks up within this time
const ADOPT_WAIT_SEC = 1.5
const RUNTIMES = ["vulkan", "vulkan-fp32", "ncnn-cpu", "ort-cpu"]
const LOG_LINES = 200
const SETTINGS_PATH = "user://yorishiro_tracker.json"

signal status_changed(status: Dictionary)
signal preview_changed(texture: Texture2D)
signal log_changed(lines: PackedStringArray)

var camera := 0
var tracker_name := "facemesh"
var runtime := "vulkan"

var found := false
## latest raw ARKit 52 values, for bindings that want more than the VTS style inputs
var arkit := {}
var status := {"state": "starting", "message": "waiting for the tracker"}
var log_lines := PackedStringArray()
var preview := ImageTexture.new()

var _data := PacketPeerUDP.new()
var _control := PacketPeerUDP.new()
var _proc := {}
var _pid := 0
var _started_msec := 0
var _adopted := false
var _partial := {"stdio": "", "stderr": ""}

func _ready():
	super._ready()
	load_settings()
	_control.set_dest_address("127.0.0.1", CONTROL_PORT)
	var err = _data.bind(DATA_PORT, "127.0.0.1")
	if err != OK:
		_set_status({"state": "error", "message": "port %d is in use by another program" % DATA_PORT})
		return
	_started_msec = Time.get_ticks_msec()

func _exit_tree():
	stop()
	_data.close()

## path of the tracker command, YORISHIRO_TRACKER overrides it
func tracker_command() -> String:
	var override = OS.get_environment("YORISHIRO_TRACKER")
	if override:
		return override
	var app_dir = ProjectSettings.globalize_path("res://").trim_suffix("/")
	return app_dir.get_base_dir().path_join("tracker/.venv/bin/yorishiro-tracker")

func start():
	stop()
	var cmd = tracker_command()
	if not FileAccess.file_exists(cmd):
		_set_status({"state": "error",
			"message": "yorishiro-tracker is not installed at %s. Run `uv sync` in the tracker folder." % cmd})
		return
	var args = ["serve", "--camera", str(camera), "--tracker", tracker_name, "--runtime", runtime,
		"--parent-pid", str(OS.get_process_id())]
	_append_log("$ %s %s" % [cmd.get_file(), " ".join(args)])
	OS.set_environment("PYTHONUNBUFFERED", "1")  # otherwise its log arrives in 4 KB bursts
	_proc = OS.execute_with_pipe(cmd, args, false)
	if _proc.is_empty():
		_set_status({"state": "error", "message": "could not start %s" % cmd})
		return
	_pid = _proc["pid"]
	_set_status({"state": "starting", "message": "starting tracker (first start loads models)"})

func stop():
	if _pid and OS.is_process_running(_pid):
		send_command({"cmd": "quit"})
		OS.kill(_pid)
	_pid = 0
	_proc = {}

func restart():
	_adopted = false
	start()

func calibrate():
	send_command({"cmd": "calibrate"})

func send_command(cmd: Dictionary):
	_control.put_packet(JSON.stringify(cmd).to_utf8_buffer())

func is_managed() -> bool:
	return _pid != 0

func _process(_delta):
	_receive()
	_drain_pipes()
	if _pid == 0 and not _adopted and _started_msec and status.get("state") != "error":
		if Time.get_ticks_msec() - _started_msec > ADOPT_WAIT_SEC * 1000:
			_started_msec = 0
			start()
	elif _pid and not OS.is_process_running(_pid):
		var code = OS.get_process_exit_code(_pid)
		_drain_pipes()
		_pid = 0
		if status.get("state") != "error":
			_set_status({"state": "error", "message": "tracker stopped (exit code %d), see the log" % code})

func _receive():
	var latest_frame = null
	while _data.get_available_packet_count() > 0:
		var msg = JSON.parse_string(_data.get_packet().get_string_from_utf8())
		if typeof(msg) != TYPE_DICTIONARY:
			continue
		if not _adopted and _pid == 0:
			_adopted = true
			_started_msec = 0
			_append_log("using a tracker that was already running")
		match msg.get("type", "frame"):
			"status":
				_set_status(msg)
			"preview":
				_show_preview(msg.get("jpeg", ""))
			_:
				latest_frame = msg
	if latest_frame != null:
		found = latest_frame.get("found", false)
		if found:
			arkit = latest_frame.get("arkit", {})
			update(latest_frame.get("vts", {}))

func _show_preview(b64: String):
	var image = Image.new()
	if image.load_jpg_from_buffer(Marshalls.base64_to_raw(b64)) != OK:
		return
	if preview.get_image() == null or preview.get_size() != Vector2(image.get_size()):
		preview.set_image(image)
	else:
		preview.update(image)
	preview_changed.emit(preview)

func _drain_pipes():
	for key in ["stdio", "stderr"]:
		var pipe: FileAccess = _proc.get(key)
		if pipe == null:
			continue
		var chunk = pipe.get_buffer(65536)
		if chunk.is_empty():
			continue
		var text = _partial[key] + chunk.get_string_from_utf8()
		var lines = text.split("\n")
		_partial[key] = lines[-1]
		for i in lines.size() - 1:
			if lines[i].strip_edges() and not lines[i].begins_with("["):  # skip ncnn's GPU capability dump
				_append_log(lines[i])

func _append_log(line: String):
	log_lines.append(line)
	if log_lines.size() > LOG_LINES:
		log_lines = log_lines.slice(log_lines.size() - LOG_LINES)
	log_changed.emit(log_lines)

func _set_status(s: Dictionary):
	var repeated = s.get("state") == status.get("state") and s.get("message") == status.get("message")
	status = s
	if s.get("state") == "error" and not repeated:
		_append_log("error: %s" % s.get("message", ""))
	status_changed.emit(status)

func create_config() -> Node:
	var panel = preload("./yorishiro_config.gd").new()
	panel.tracker = self
	return panel

func load_settings():
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_PATH))
	if typeof(data) == TYPE_DICTIONARY:
		camera = int(data.get("camera", camera))
		tracker_name = data.get("tracker", tracker_name)
		runtime = data.get("runtime", runtime)

func save_settings():
	var f = FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"camera": camera, "tracker": tracker_name, "runtime": runtime}))
