## A track with the live value and a low..high band with two handles, like VTube Studio's input range.
## The band is the part of the input that maps to the model's full range: a narrow band is more sensitive.
class_name RangeMeter
extends Control

signal range_changed(low: float, high: float)

var domain := Vector2(0, 1)
var low := 0.0
var high := 1.0
## the live input value, drawn as a marker
var value := 0.0 :
	set(v):
		if not is_equal_approx(v, value):
			value = v
			queue_redraw()

var _dragging := -1  # 0 low handle, 1 high handle

func _init() -> void:
	custom_minimum_size = Vector2(160, 28)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE

func set_band(l: float, h: float) -> void:
	low = l
	high = h
	queue_redraw()

func _x(v: float) -> float:
	var pad := size.y / 2
	return pad + (size.x - 2 * pad) * inverse_lerp(domain.x, domain.y, v)

func _v(x: float) -> float:
	var pad := size.y / 2
	return lerpf(domain.x, domain.y, clampf((x - pad) / maxf(1.0, size.x - 2 * pad), 0, 1))

func _draw() -> void:
	var mid := size.y / 2
	var track := get_theme_color("track", "RangeMeter")
	var band := get_theme_color("band", "RangeMeter")
	var accent := get_theme_color("handle", "RangeMeter")
	var marker := get_theme_color("value", "RangeMeter")
	draw_line(Vector2(_x(domain.x), mid), Vector2(_x(domain.y), mid), track, 6, true)
	draw_line(Vector2(_x(low), mid), Vector2(_x(high), mid), band, 6, true)
	# live value: a bright dot, filled inside the band, hollow outside it
	var inside := value >= minf(low, high) and value <= maxf(low, high)
	draw_circle(Vector2(_x(clampf(value, domain.x, domain.y)), mid), 5, marker, inside, -1 if inside else 2.0, true)
	for v in [low, high]:
		draw_circle(Vector2(_x(v), mid), 8, accent, false, 2.5, true)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = 0 if absf(event.position.x - _x(low)) <= absf(event.position.x - _x(high)) else 1
			_drag_to(event.position.x)
		else:
			_dragging = -1
		accept_event()
	elif event is InputEventMouseMotion and _dragging >= 0:
		_drag_to(event.position.x)
		accept_event()

func _drag_to(x: float) -> void:
	var v := snappedf(_v(x), (domain.y - domain.x) / 200.0)
	if _dragging == 0:
		low = v
	else:
		high = v
	queue_redraw()
	range_changed.emit(low, high)
