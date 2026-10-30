## Time source for animation (blink, breathing, tweens, smoothing). Wall clock normally. With the user arg
## --fixed-clock it counts rendered frames at 60 fps instead, so automated screenshots come out the same on
## every run. Pair it with Godot's --fixed-fps 60 so physics and motions step by the same delta.
extends RefCounted

const FRAME_MSEC := 1000.0 / 60.0
static var fixed: bool = "--fixed-clock" in OS.get_cmdline_user_args()
## frame the fixed clock counts from, automation moves it to when the model has finished loading
static var origin_frame: int = 0

static func msec() -> float:
	if fixed:
		return (Engine.get_process_frames() - origin_frame) * FRAME_MSEC
	return Time.get_ticks_msec()

static func unix() -> float:
	if fixed:
		return msec() / 1000.0
	return Time.get_unix_time_from_system()
