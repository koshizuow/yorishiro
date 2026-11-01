extends "res://lib/model/modifier.gd"

## per art mesh settings; colors replace the model's own multiply and screen colors while color_override is on
var mesh: MeshInstance2D
@export var color_override: bool = false :
	set(v):
		color_override = v
		_apply_colors()
@export var multiply_color: Color = Color.WHITE :
	set(v):
		multiply_color = v
		_apply_colors()

@export var screen_color: Color = Color.BLACK :
	set(v):
		screen_color = v
		_apply_colors()
@export var pinnable: bool = true

func _init(m: MeshInstance2D) -> void:
	mesh = m

## Katashiro draws the model (the mesh node only names the art mesh), it takes the colors by mesh name
func _apply_colors() -> void:
	mesh.get_parent().get_parent().set_mesh_colors(mesh.name, color_override, multiply_color, screen_color)
