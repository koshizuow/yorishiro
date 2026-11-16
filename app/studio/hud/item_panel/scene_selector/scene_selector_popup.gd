extends Node

const VtItem = preload("res://lib/items/vt_item.gd")
const VtModel = preload("res://lib/model/vt_model.gd")
const Stage = preload("res://studio/stage/stage.gd")
const Math = preload("res://lib/utils/math.gd")
const Serializers = preload("res://lib/utils/serializers.gd")
const Files = preload("res://lib/utils/files.gd")
const VtsPins = preload("res://lib/items/vts_pins.gd")

const FILE_DIR = "user://ItemScenes"
const EXT = ".itemscene.json"

var btn_group: ButtonGroup

func get_selected_cfg() -> Dictionary:
	var selected = btn_group.get_pressed_button()
	if not selected:
		return {}
	return selected.get_meta("item_scene", {})

func get_scenes() -> Array:
	return Array(DirAccess.get_files_at(FILE_DIR)).filter(
		func (f: String):
			return f.ends_with(EXT)
	).map(
		func (f: String):
			var path = FILE_DIR.path_join(f)
			var data = JSON.parse_string(FileAccess.get_file_as_string(path))
			return {
				"ref": path,
				"id": data["SceneID"],
				"name": data["SceneName"],
				"group_name": StringName(data["SceneGroupName"]),
				"model": data["SceneModel"]
			}
	)

## puts the scene's items on the stage: pinned ones on the current model's art meshes when it is the model they
## were pinned to (lib/items/vts_pins.gd), the others where VTube Studio had them on its stage
func load_item_scene():
	var stage: Stage = get_tree().get_first_node_in_group("system:stage")
	var model = stage.active_model
	var group_name = %GroupName.text
	if group_name:  # a named group replaces its items; without one the scene adds to the stage (pinned items stay)
		stage.clear_items(group_name)
	var view: Vector2 = stage.get_viewport().get_visible_rect().size

	for i in %SceneItems.get_children():
		var cfg: Dictionary = i.get_meta("cfg", {})
		var paths: PackedStringArray = i.get_meta("filepath")
		var item: VtItem = await ItemManager.create_item(paths)
		if item == null or model == null:
			continue
		var spec := {}
		if cfg.get("IsPinned", false) and _pinned_to(cfg, model):
			spec = VtsPins.from_vts(model, cfg, paths)
		if not spec.is_empty():
			# no grow-in for a pinned item: it sizes itself every frame
			stage.spawn_item(item, false, false)
			if VtsPins.apply(item, model, spec):
				spec["ok"] = true
		if not spec.get("ok", false):
			# set before spawning: the grow-in animation ends at the scale the item has then
			var loose := VtsPins.loose_from_vts(cfg, paths, view)
			item.model = model
			item.pinned_to = null
			item.scale = Vector2.ONE * loose.scale
			item.global_position = loose.position
			item.rotation_degrees = -float(cfg.get("Rotation", 0.0))
			item.mirror = cfg.get("IsFlipped", false)
			if cfg.get("IsAnimated", false) and item.render is AnimatedSprite2D and float(cfg.get("FPS", 0.0)) > 0.0:
				var render: AnimatedSprite2D = item.render
				render.speed_scale = float(cfg.FPS) / maxf(render.sprite_frames.get_animation_speed("default"), 0.001)
			if item.get_parent() == null:
				stage.spawn_item(item, true, false)
		var order := int(cfg.get("Order", 1))
		item.set_meta("order", order)
		if order < 0 and model.get_parent() == item.get_parent():
			item.get_parent().move_child(item, model.get_index())
		if group_name:
			item.group_name = group_name

## the scene's item was pinned to this model (by its VTube Studio model ID, else its name)
func _pinned_to(cfg: Dictionary, model) -> bool:
	var id := str(cfg.get("PinnedModel_InternalID", ""))
	if id and model.modelmeta and str(model.modelmeta.id) == id:
		return true
	var name := str(cfg.get("PinnedModel_Live2D", ""))
	return name != "" and model.modelmeta and model.modelmeta.model.get_file().trim_suffix(".model3.json") == name

func _on_load_button_pressed() -> void:
	await load_item_scene()
	_on_close_requested()

func _on_file_dialog_file_selected(path: String) -> void:
	%FileDialog.hide()
	
	var cfg = Files.read_json(path)
	
	%ModelName.text = cfg.get("SceneModel", "")
	%GroupName.text = cfg.get("SceneGroupName", "")
	
	for i in %SceneItems.get_children():
		%SceneItems.remove_child(i)
		i.queue_free()
	
	for i in cfg.get("Items", []):
		# older scene files may hold an absolute path
		var item_file = i.get("ItemPath", "")
		if not item_file:
			# matching VTS for compatibility
			# fallback to looking in an Items directory relative to the item scene
			# otherwise load from the user data folder
			var item_file_name = str(i.get("ItemFileName", ""))
			item_file = path.get_base_dir().get_base_dir().path_join("Items").path_join(item_file_name)
			if not FileAccess.file_exists(item_file):
				var found := VtsPins.find_item(path.get_base_dir(), item_file_name)
				var stage = get_tree().get_first_node_in_group("system:stage")
				if found.is_empty() and stage and stage.active_model and stage.active_model.modelmeta:
					# beside the model on stage, as for its pinned items
					found = VtsPins.find_item(stage.active_model.modelmeta.model.get_base_dir(), item_file_name)
				item_file = found[0] if found.size() == 1 else ProjectSettings.globalize_path("user://Items".path_join(item_file_name))
			
		var meta = ItemManager.about_item(item_file)
		if meta.is_empty():
			continue

		var row = preload("./item_row.tscn").instantiate()
		match meta.type:
			VtItem.ItemType.IMAGE:
				row.get_node("%Icon").texture = preload("../static_image.svg")
			VtItem.ItemType.ANIMATED:
				row.get_node("%Icon").texture = preload("../animated_image.svg")
			VtItem.ItemType.MODEL:
				row.get_node("%Icon").texture = preload("../motion.svg")
		
		row.get_node("%ModelName").text = i["ItemFileName"]
		if not i.get("PinnedTo", "").is_empty():
			row.get_node("%Pinned").text = i.get("PinnedTo")
		row.get_node("%Ordering").value = i.get("Order", 0)
		row.set_meta("filepath", PackedStringArray([item_file]))
		row.set_meta("cfg", i)
		row.set_meta("item_type", meta.type)
		%SceneItems.add_child(row)
	
	%ScenePreview.show()

func _on_close_requested() -> void:
	queue_free()
