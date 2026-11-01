## Yorishiro tracker input: the tracking core built into the app (the yorishiro_tracking extension,
## crates/tracking-gd). Its YorishiroCore node runs camera and tracking in a thread, poll() returns status
## messages and frames.
## YORISHIRO_RECORDING (a recording folder) replays that recording in a loop instead of the camera, for tests.
extends "../camera_tracker.gd"

## vulkan: the GPU on any graphics card (ncnn), the default; vulkan-fp32 for drivers with fp16 trouble;
## ncnn-cpu and ort-cpu without a GPU
const RUNTIMES = ["vulkan", "vulkan-fp32", "ncnn-cpu", "ort-cpu"]
const LOG_LINES = 200
const SETTINGS_PATH = "user://yorishiro_tracker.json"

signal status_changed(status: Dictionary)
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
var runtime := "vulkan"
## tracking for other apps on this computer, sent by the tracker next to the app's own link:
## VTube Studio and OpenVT read the VTube Studio iPhone protocol, VSeeFace, Warudo and VNyan iFacialMocap
var send_vts_iphone := false
var send_ifacialmocap := false
## also track hands (MediaPipe hands on the CPU beside the face), the Hand* inputs
var track_hands := false
## a recording folder to replay instead of the camera (YORISHIRO_RECORDING), empty for the camera
var replay := ""
var _core: Node
## 21 points per hand for the 3D preview, by the avatar's sides: {"Left": [[x, y, z], ...]} in metres, y down
var hand_points := {}

var found := false
## latest raw ARKit 52 values, for bindings that want more than the VTS style inputs
var arkit := {}
var status := {"state": "starting", "message": "waiting for the tracker"}
var log_lines := PackedStringArray()

func _ready():
	super._ready()
	load_settings()
	replay = OS.get_environment("YORISHIRO_RECORDING")
	start()

func _exit_tree():
	stop()

## the tracking core is built into this app (addons/yorishiro_tracking)
static func core_available() -> bool:
	return ClassDB.class_exists(&"YorishiroCore")

## the models folder next to the app folder (models/README.md)
func _models_dir() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir().path_join("models")

## ONNX Runtime next to the extension (build_dependencies.sh fetches it)
func _ort_library() -> String:
	var lib := ProjectSettings.globalize_path("res://addons/yorishiro_tracking/lib")
	for f in DirAccess.get_files_at(lib):
		if f.begins_with("libonnxruntime.so."):
			return lib.path_join(f)
	return ""

func _start_core():
	_core = ClassDB.instantiate(&"YorishiroCore")
	_core.name = "YorishiroCore"
	add_child(_core)
	var models := _models_dir()
	_core.camera = camera
	_core.replay = replay
	_core.runtime = runtime
	_core.models_dir = models
	_core.eye_model = models.path_join("eye_openness.onnx")
	_core.ort_library = _ort_library()
	_core.send_vts_iphone = send_vts_iphone
	_core.ifacialmocap_host = "127.0.0.1" if send_ifacialmocap else ""
	_core.track_hands = track_hands
	var source := ("recording %s" % replay.trim_suffix("/").get_file()) if replay else ("camera %d" % camera)
	_append_log("tracking core: %s, %s, ONNX Runtime %s" % [source, runtime, _core.ort_library.get_file()])
	_core.start()
	_set_status({"state": "starting", "message": "starting tracker (first start loads models)"})

func start():
	stop()
	if not core_available():
		_set_status({"state": "error",
			"message": "the tracking core is not built (addons/yorishiro_tracking). Run app/build_dependencies.sh."})
		return
	_start_core()

func stop():
	if _core:
		_core.stop()
		_core.queue_free()
		_core = null

func restart():
	start()

func calibrate():
	if _core:
		_core.recalibrate()

func _process(delta):
	_receive()
	_ease_to_rest(delta)
	if _core:
		for line in _core.take_log():
			_append_log(line)

func _receive():
	if not _core:
		return
	var latest_frame = null
	for msg in _core.poll():
		if msg.get("type", "frame") == "status":
			_set_status(msg)
		else:
			latest_frame = msg
	if latest_frame != null:
		found = latest_frame.get("found", false)
		if found and latest_frame.has("glare"):
			_count_glare(Array(latest_frame["glare"]))
		if not found and _lost_msec == 0:
			_lost_msec = Time.get_ticks_msec()
		if found:
			_lost_msec = 0
			arkit = latest_frame.get("arkit", {})
			update(latest_frame.get("vts", {}))
		# hands are tracked apart from the face, a hand can be seen without it
		if latest_frame.has("hands"):
			update(latest_frame["hands"])
		hand_points = latest_frame.get("hand_points", {})

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
		runtime = data.get("runtime", runtime)
		if not runtime in RUNTIMES:  # e.g. cuda or tensorrt from before they were removed
			runtime = RUNTIMES[0]
		when_lost = int(data.get("when_lost", when_lost))
		glasses = int(data.get("glasses", glasses))
		lost_delay = float(data.get("lost_delay", lost_delay))
		send_vts_iphone = bool(data.get("send_vts_iphone", send_vts_iphone))
		send_ifacialmocap = bool(data.get("send_ifacialmocap", send_ifacialmocap))
		track_hands = bool(data.get("track_hands", track_hands))

func save_settings():
	var f = FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"camera": camera, "runtime": runtime,
			"when_lost": when_lost, "lost_delay": lost_delay, "glasses": glasses,
			"send_vts_iphone": send_vts_iphone, "send_ifacialmocap": send_ifacialmocap, "track_hands": track_hands}))
