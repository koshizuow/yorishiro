## Items between the model's layers (VTube Studio's "pin within model layers"): an item with a layer_mesh is drawn
## right above that art mesh of the model, under what the model draws after it. Katashiro splits the model there
## (KatashiroModel.set_layer_splits): the model's own node shows the part up to the first split, and a sprite here
## shows each part after one (an image the size of the viewport, like its own), placed in the stage's layer order
## above the items that go there.
##
## A Live2D item with split_mesh is cut the same way: its own node (the part up to split_mesh) goes at its
## back_layer_mesh, a sprite with the rest at its layer_mesh. A layer mesh of BOTTOM puts the part behind the model.
##
## Stage order: items behind the model, the model, then for each split in draw order: the parts placed there and
## the model's sprite for it, then everything else.
extends Node

const VtModel = preload("res://lib/model/vt_model.gd")
const TOP := "<<<LAYER_SPECIAL_TOP>>>"
const BOTTOM := "<<<LAYER_SPECIAL_BOTTOM>>>"

var stage: Node
## model sprites by split mesh, item sprites by item
var _model_parts := {}
var _item_parts := {}
var _signature := ""

func _process(_delta: float) -> void:
	var model = stage.active_model
	var canvas: Node = stage.canvas
	if model == null or not is_instance_valid(model) or model.get("model") == null:
		_clear()
		return
	var items: Array = canvas.get_children().filter(
		func (c): return "layer_mesh" in c and not c.is_queued_for_deletion() and c.model == model)
	var sig := _signature_of(model, items)
	if sig != _signature:
		_signature = sig
		_rebuild(model, items)
	_follow(model)

## what the layout depends on: the model, each layered item and its meshes
func _signature_of(model, items: Array) -> String:
	var parts := PackedStringArray([str(model.get_instance_id())])
	for i in items:
		if i.layer_mesh != "" or i.split_mesh != "":
			parts.append("%d:%s:%s:%s" % [i.get_instance_id(), i.layer_mesh, i.back_layer_mesh, i.split_mesh])
	return "|".join(parts)

func _rebuild(model, items: Array) -> void:
	var km: KatashiroModel = model.model
	var canvas: Node = stage.canvas
	# the item sprites: Live2D items split in two
	var keep := {}
	for i in items:
		if i.split_mesh == "" or not (i.render is VtModel) or i.render.get("model") == null:
			continue
		var tex: Array = i.render.model.set_layer_splits(PackedStringArray([i.split_mesh]))
		if tex.is_empty():
			continue
		var s: Sprite2D = _item_parts.get(i)
		if s == null or not is_instance_valid(s):
			s = _sprite("ItemFront")
			canvas.add_child(s)
			_item_parts[i] = s
		s.texture = tex[0]
		keep[i] = true
	for i in _item_parts.keys():
		if not keep.has(i):
			if is_instance_valid(i) and i.render and i.render.get("model"):
				i.render.model.set_layer_splits(PackedStringArray())
			if is_instance_valid(_item_parts[i]):
				_item_parts[i].queue_free()
			_item_parts.erase(i)

	# what goes where: [node, mesh] for each item part
	var placed := []
	for i in items:
		if i.split_mesh != "" and _item_parts.has(i):
			placed.append([i, i.back_layer_mesh if i.back_layer_mesh != "" else BOTTOM])
			placed.append([_item_parts[i], i.layer_mesh if i.layer_mesh != "" else TOP])
		elif i.layer_mesh != "":
			placed.append([i, i.layer_mesh])

	# the model's splits, in draw order
	var meshes := []
	for p in placed:
		var m: String = p[1]
		if m != TOP and m != BOTTOM and m not in meshes and km.mesh_draw_position(m) >= 0:
			meshes.append(m)
	meshes.sort_custom(func (a, b): return km.mesh_draw_position(a) < km.mesh_draw_position(b))
	var tex: Array = km.set_layer_splits(PackedStringArray(meshes))
	for m in _model_parts.keys():
		if m not in meshes or tex.is_empty():
			if is_instance_valid(_model_parts[m]):
				_model_parts[m].queue_free()
			_model_parts.erase(m)
	if tex.size() == meshes.size():
		for k in meshes.size():
			var s: Sprite2D = _model_parts.get(meshes[k])
			if s == null or not is_instance_valid(s):
				s = _sprite("ModelFront")
				canvas.add_child(s)
				_model_parts[meshes[k]] = s
			s.texture = tex[k]

	# stage order
	var at: int = model.get_index()
	for p in placed:
		if p[1] == BOTTOM:
			canvas.move_child(p[0], at)
			at = model.get_index()
	at = model.get_index() + 1
	for m in meshes:
		for p in placed:
			if p[1] == m:
				canvas.move_child(p[0], at)
				at = p[0].get_index() + 1
		if _model_parts.has(m):
			canvas.move_child(_model_parts[m], at)
			at = _model_parts[m].get_index() + 1
	# parts at TOP (or on a mesh the model does not have) stay in front, above the model's parts
	for p in placed:
		if p[1] == TOP or (p[1] != BOTTOM and p[1] not in meshes):
			canvas.move_child(p[0], -1)

func _sprite(name: String) -> Sprite2D:
	var s := Sprite2D.new()
	s.name = name
	s.centered = false
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA
	s.material = mat
	return s

## the sprites sit where the model's (or the item's) own image is shown
func _follow(model) -> void:
	for m in _model_parts:
		_place(_model_parts[m], model)
	for i in _item_parts:
		if is_instance_valid(i) and is_instance_valid(_item_parts[i]):
			_place(_item_parts[i], i.render)
			_item_parts[i].modulate = i.modulate

func _place(s: Sprite2D, model) -> void:
	# Katashiro draws the model into an image the size of the viewport it is in, shown by its RdView sprite
	var km = model.get("model")
	var view: Node2D = km.get_node_or_null("RdView") if km else null
	if view == null or not is_instance_valid(s):
		s.visible = false
		return
	s.global_transform = view.global_transform
	s.visible = view.is_visible_in_tree()
	s.texture_filter = view.texture_filter

func _clear() -> void:
	for s in _model_parts.values() + _item_parts.values():
		if is_instance_valid(s):
			s.queue_free()
	_model_parts.clear()
	_item_parts.clear()
	_signature = ""
