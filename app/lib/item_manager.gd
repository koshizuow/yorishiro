extends Node

const VtModel = preload("res://lib/model/vt_model.gd")
const VtItem = preload("res://lib/items/vt_item.gd")
const AnimFrames = preload("res://lib/utils/anim_frames.gd")

func about_item(path: String) -> Dictionary:
	if ModelManager.is_model(path):
		return {
			"name": path.get_basename(),
			"type": VtItem.ItemType.MODEL
		}
	elif DirAccess.dir_exists_absolute(path) or (AnimFrames.maybe_animated(path) and not AnimFrames.load_frames(PackedStringArray([path])).is_empty()):
		return {
			"name": path.get_basename(),
			"type": VtItem.ItemType.ANIMATED
		}
	elif AnimFrames.load_still(path):
		return {
			"name": path.get_basename(),
			"type": VtItem.ItemType.IMAGE
		}
	return {}

## the expressions VTube Studio had on for this Live2D item (SavedActiveExpressions in its .vtube.json, e.g. an item
## that holds a drink only with its drink expression on)
static func _vts_saved_expressions(model) -> void:
	var controller = model.get_expression_controller()
	var vt: String = model.modelmeta.studio_parameters
	if controller == null or not FileAccess.file_exists(vt):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(vt))
	if not data is Dictionary:
		return
	var names: Array = (controller.expressions as Array).map(func (e): return e.get_name())
	for f in data.get("SavedActiveExpressions", []):
		var n := str(f).get_file().trim_suffix(".exp3.json")
		if n in names:
			controller.set("weight/%s" % n, 1.0)

func create_item(path: PackedStringArray) -> VtItem:
	assert(not path.is_empty())
	var vtitem = preload("res://lib/items/vt_item.tscn").instantiate()
	
	# a folder of PNG frames (several selected, or the folder itself), or one animated GIF, APNG or WebP
	var anim := {} if ModelManager.is_model(path[0]) else AnimFrames.load_frames(path)
	if not anim.is_empty():
		var render = AnimatedSprite2D.new()
		render.sprite_frames = anim.frames
		render.play("default")
		render.name = "Render"
		vtitem.size = anim.size
		vtitem.add_child(render)
		vtitem.item_type = VtItem.ItemType.ANIMATED
		vtitem.render = render
	elif ModelManager.is_model(path[0]):
		var model = ModelManager.make_model(path[0])
		model.name = "Render"
		model.position = Vector2.INF
		add_child(model)
		await model.loaded
		if model.is_queued_for_deletion():
			return
		model.reparent(vtitem, false)
		# erase any settings from when it's a normal model
		model.position = Vector2.ZERO
		model.scale = Vector2.ONE
		model.rotation_degrees = 0
		# do not drag by the model itself, we want to drag the item
		model.locked = true
		# the item moves with what it is pinned to (or stays put), not with the face on its own
		model.movement_enabled = false
		_vts_saved_expressions(model)
		
		vtitem.size = model.size
		vtitem.item_type = VtItem.ItemType.MODEL
		vtitem.render = model
	else:
		var render = Sprite2D.new()
		var texture: Texture2D
		var still := AnimFrames.load_still(path[0])
		if still == null:
			return
		texture = ImageTexture.create_from_image(still)
		render.name = "Render"
		render.texture = texture
		render.centered = true
		vtitem.item_type = VtItem.ItemType.IMAGE
		vtitem.size = texture.get_size()
		vtitem.add_child(render)
		vtitem.render = render
		
	vtitem.path = path
	vtitem.display_name = path[0].get_file().substr(0, path[0].get_file().find(".", 1))
	
	return vtitem
