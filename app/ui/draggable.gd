extends Node2D

const Math = preload("res://lib/utils/math.gd")

enum SampleMode {
	BOUNDS,
	ALPHA
}

signal transform_updated(position: Vector2, scale: Vector2, rotation: float, offset: Vector2, yrp: Vector3)
signal drag_pressed
signal drag_released

@export var locked = false
@export var sample_mode = SampleMode.BOUNDS
@export var centered = false :
	set(v):
		centered = v
		_update_rect()
		
@export var debug = false
var dragging = false

var size: Vector2 = Vector2.ONE :
	set(v):
		size = v
		_update_rect()
		
var rect: Rect2 :
	get():
		var offset = (-size / 2) if centered else Vector2.ZERO
		return Rect2(offset, size)
		
var center: Vector2 :
	get():
		return rect.get_center()

# extra transformations, useful for 3D draggables
var free_rotation: Vector3
var free_offset: Vector2 = Vector2.ZERO

@export var is_3D: bool = false

func _init() -> void:
	item_rect_changed.connect(
		func ():
			notify_transform_updated()
	)

func _draw() -> void:
	if debug:
		draw_rect(
			rect,
			Color.GREEN, false, 8.0, false
		)

func _update_rect():
	var offset = (-size / 2) if centered else Vector2.ZERO
	RenderingServer.canvas_item_set_custom_rect(
		get_canvas_item(), true, 
		Rect2(position + offset, size)
	)
	queue_redraw()

## one wheel step scales by this factor, the same feel at any size
const ZOOM_STEP = 1.06
## degrees per wheel step with Shift
const ROTATE_STEP = 2.5
func _handle_mouse_button_down(event: InputEventMouseButton):
	var dirty = false
	var wheel := event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]
	var up := 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0

	# the wheel works over the object, holding the button is not needed (it still works while dragging)
	if wheel:
		if Input.is_key_pressed(KEY_SHIFT):
			rotation = wrapf(rotation + deg_to_rad(ROTATE_STEP * up), 0, 2 * PI)
		else:
			# zoom toward the cursor: the point under it stays where it is
			var factor := ZOOM_STEP if up > 0 else 1.0 / ZOOM_STEP
			var new_scale: Vector2 = (scale * factor).clamp(Vector2(0.01, 0.01), Vector2(5.0, 5.0))
			factor = new_scale.x / scale.x
			var cursor := get_canvas_transform().affine_inverse() * event.position
			global_position = cursor + (global_position - cursor) * factor
			scale = new_scale
		dirty = true

	if event.button_index == MOUSE_BUTTON_LEFT:
		dragging = true
		drag_pressed.emit()

	return dirty

func _handle_mouse_motion(event: InputEventMouseMotion) -> bool:
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		var movement = event.relative
		if Input.is_key_pressed(KEY_SHIFT):
			free_rotation = Vector3(
				free_rotation.x,
				wrapf(free_rotation.y + (PI / 360.0 * movement.x), 0, 2 * PI),
				free_rotation.z
			)
		elif Input.is_key_pressed(KEY_CTRL):
			free_rotation = Vector3(
				wrapf(free_rotation.x + (PI / 360.0 * movement.y), 0, 2 * PI),
				free_rotation.y,
				free_rotation.z
			)
		elif Input.is_key_pressed(KEY_ALT):
			free_offset += movement
		else:
			global_position += movement
			_keep_on_screen()
		return true
	return false

## pulls the object back so the center of its box stays in the viewport. The box is often much larger than
## the drawn figure (a Live2D canvas has wide transparent margins), so keeping a few pixels of the box
## visible could still leave nothing to grab.
func _keep_on_screen() -> void:
	var view := get_viewport_rect()
	var center: Vector2 = get_global_transform_with_canvas() * rect.get_center()
	var inside := center.clamp(view.position, view.end)
	if inside != center:
		global_position += get_canvas_transform().affine_inverse().basis_xform(inside - center)

# can't use gui_input because if the mouse input is within the bounds of the element,
# it won't pass through to other controls, inhibiting clicking objects
# this behavior conflicts with the ability to handle mouse input relative to sampled pixels
# so that we can ignore clicking on transparent parts
func _unhandled_input(event: InputEvent) -> void:
	# prevent transformations
	if locked:
		return
	
	var dirty = false
	if event is InputEventMouseButton:
		if event.pressed:
			# mouse event must be within the bounds of the control. Use the event's own position (already in this
			# viewport's coordinates): the viewport's last mouse position lags when other UI took the motion
			var p_xy = get_global_transform_with_canvas().affine_inverse() * event.position
			if not rect.has_point(p_xy):
				return
			# sample for alpha if control has texture
			if "texture" in self and sample_mode == SampleMode.ALPHA:
				if self.texture != null:
					var px = self.texture.get_image().get_pixelv(p_xy)
					var opaque = px.a > 0.0
					if not opaque:
						return
			dirty = dirty || _handle_mouse_button_down(event)
			get_viewport().set_input_as_handled()
		elif not event.pressed and event.button_index == MOUSE_BUTTON_LEFT and dragging:
			dragging = false
			drag_released.emit()
			get_viewport().set_input_as_handled()
		else:
			return
		
	if dragging and event is InputEventMouseMotion:
		dirty = dirty || _handle_mouse_motion(event)
		get_viewport().set_input_as_handled()
	
	if dirty:
		notify_transform_updated()
		_update_rect()

func notify_transform_updated():
	queue_redraw()
	transform_updated.emit(global_position, scale, rotation_degrees, free_offset, free_rotation)
	
