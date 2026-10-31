## Yorishiro tracker input. Starts yorishiro-tracker in the background (unless one is already
## sending), receives frames, status and camera previews over the local link, and controls it.
## Protocol: yorishiro_tracker/sinks/link.py.
extends "../camera_tracker.gd"

const DATA_PORT = 39570
const CONTROL_PORT = 39571
## an already running tracker (started by hand for development) is used if it speaks up within this time
const ADOPT_WAIT_SEC = 1.5
const RUNTIMES = ["vulkan", "vulkan-fp32", "ncnn-cpu", "ort-cpu", "cuda", "tensorrt"]  # cuda, tensorrt: NVIDIA, tracker synced with the ort-nvidia group
const LOG_LINES = 200
const SETTINGS_PATH = "user://yorishiro_tracker.json"

signal status_changed(status: Dictionary)
signal preview_changed(texture: Texture2D)
signal log_changed(lines: PackedStringArray)

## what the model does when the tracker loses the face (VTS has the same choice)
enum WhenLost { FREEZE, REST }
## the values the tracker sends for a relaxed face looking straight ahead (vts_params.py at the neutral)
const REST = {"FaceAngleX": 0.0, "FaceAngleY": 0.0, "FaceAngleZ": 0.0, "FacePositionX": 0.0, "FacePositionY": 0.0,
	"FacePositionZ": 0.0, "EyeOpenLeft": 1.0, "EyeOpenRight": 1.0, "EyeLeftX": 0.0, "EyeLeftY": 0.0,
	"EyeRightX": 0.0, "EyeRightY": 0.0, "MouthOpen": 0.0, "MouthSmile": 0.5, "MouthX": 0.0, "Brows": 0.5,
	"BrowLeftY": 0.0, "BrowRightY": 0.0, "CheekPuff": 0.0, "TongueOut": 0.0}
## time the model eases back to the resting pose
const REST_EASE_SEC = 0.8

var camera := 0
## FREEZE keeps the last pose, REST eases back to the resting pose after lost_delay seconds
var when_lost := WhenLost.REST
var lost_delay := 1.0
var _lost_msec := 0

## glasses: AUTO decides from screen reflections on the lenses (lens_glare.py in the tracker)
enum Glasses { AUTO, ON, OFF }
var glasses := Glasses.AUTO
## a frame counts as glare when a lens shows more than this share of reflection (no-glasses faces stay
## under 0.002, the user's glasses above 0.02 in 44% of frames)
const GLARE_FRAME = 0.02
## glare is "now" when that many of the last GLARE_WINDOW frames had it, glasses are detected after
## GLARE_SECONDS of glare in this session
const GLARE_WINDOW = 90
const GLARE_SHARE = 0.2
const GLARE_SECONDS = 2.0
var glare_now := false
var _glare_frames: Array[bool] = []
var _glare_msec := 0
var _last_glare_check := 0
var tracker_name := "facemesh"
var runtime := "vulkan"
## tracking for other apps on this computer, sent by the tracker next to the app's own link:
## VTube Studio and OpenVT read the VTube Studio iPhone protocol, VSeeFace, Warudo and VNyan iFacialMocap
var send_vts_iphone := false
var send_ifacialmocap := false

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
	var tracker_dir = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir().path_join("tracker")
	# NVIDIA machines keep the ORT GPU build in its own env: syncing the default CPU group into .venv
	# (any plain `uv run`) removes onnxruntime-gpu's files, see tracker/pyproject.toml
	var nvidia = tracker_dir.path_join(".venv-nvidia/bin/yorishiro-tracker")
	if FileAccess.file_exists(nvidia):
		return nvidia
	return tracker_dir.path_join(".venv/bin/yorishiro-tracker")

func start():
	stop()
	var cmd = tracker_command()
	if not FileAccess.file_exists(cmd):
		_set_status({"state": "error",
			"message": "yorishiro-tracker is not installed at %s. Run `uv sync` in the tracker folder." % cmd})
		return
	var args = ["serve", "--camera", str(camera), "--tracker", tracker_name, "--runtime", runtime,
		"--parent-pid", str(OS.get_process_id())]
	if send_vts_iphone:
		args.append("--vts-iphone")
	if send_ifacialmocap:
		args.append("--ifacialmocap")
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

func _process(delta):
	_receive()
	_ease_to_rest(delta)
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
		if found and latest_frame.has("glare"):
			_count_glare(latest_frame["glare"])
		if not found and _lost_msec == 0:
			_lost_msec = Time.get_ticks_msec()
		if found:
			_lost_msec = 0
			arkit = latest_frame.get("arkit", {})
			update(latest_frame.get("vts", {}))

func _count_glare(g: Array):
	var now := Time.get_ticks_msec()
	var hit: bool = maxf(float(g[0]), float(g[1])) > GLARE_FRAME
	_glare_frames.append(hit)
	if _glare_frames.size() > GLARE_WINDOW:
		_glare_frames.pop_front()
	glare_now = _glare_frames.count(true) >= GLARE_SHARE * GLARE_WINDOW
	if glare_now and _last_glare_check:
		_glare_msec += now - _last_glare_check
	_last_glare_check = now

## whether the user wears glasses: set by hand, or seen from lens reflections
func wears_glasses() -> bool:
	return glasses == Glasses.ON or (glasses == Glasses.AUTO and _glare_msec >= GLARE_SECONDS * 1000)

## while the face is lost (and the setting says so), move every tracked value toward its resting value
func _ease_to_rest(delta: float):
	if when_lost != WhenLost.REST or _lost_msec == 0:
		return
	if Time.get_ticks_msec() - _lost_msec < lost_delay * 1000:
		return
	var k := clampf(delta * 3.0 / REST_EASE_SEC, 0.0, 1.0)  # about 95% of the way in REST_EASE_SEC
	var eased := {}
	for p in REST:
		if p in _parameters:
			eased[p] = lerpf(float(_parameters[p]), REST[p], k)
	update(eased)

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
		when_lost = int(data.get("when_lost", when_lost))
		glasses = int(data.get("glasses", glasses))
		lost_delay = float(data.get("lost_delay", lost_delay))
		send_vts_iphone = bool(data.get("send_vts_iphone", send_vts_iphone))
		send_ifacialmocap = bool(data.get("send_ifacialmocap", send_ifacialmocap))

func save_settings():
	var f = FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"camera": camera, "tracker": tracker_name, "runtime": runtime,
			"when_lost": when_lost, "lost_delay": lost_delay, "glasses": glasses,
			"send_vts_iphone": send_vts_iphone, "send_ifacialmocap": send_ifacialmocap}))
