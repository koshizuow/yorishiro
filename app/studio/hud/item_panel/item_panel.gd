extends "res://studio/hud/side_panel.gd"

const VtObject = preload("res://lib/vtobject.gd")
const VtItem = preload("res://lib/items/vt_item.gd")
const VtModel = preload("res://lib/model/vt_model.gd")
const Stage = preload("res://studio/stage/stage.gd")
const ItemStrip = preload("res://studio/hud/item_strip/item_strip.gd")

@onready var stage: Stage = get_tree().get_first_node_in_group("system:stage")

func _ready():
	# the item library above the items on stage
	var strip := ItemStrip.new()
	strip.picked.connect(_preview_item)
	strip.import_requested.connect(_on_add_button_pressed)
	$VBoxContainer.add_child(strip)
	$VBoxContainer.move_child(strip, 0)
	%FileDialog.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp;Images"])

	stage.model_changed.connect(_on_stage_model_changed)
	stage.item_added.connect(_on_stage_item_added)
	stage.item_removed.connect(_on_stage_item_removed)
	
	for fmt in ModelManager.formats.values():
		%FileDialog.add_filter(
			"*%s" % [fmt.supported_extension()],
			fmt.model_format()
		)

func setup():
	for i in stage.objects:
		_on_stage_item_added(i)
	
func teardown():
	for i in %StageItems.get_children():
		i.queue_free()
	
func _on_stage_item_added(item: VtObject) -> void:
	if not is_visible_in_tree():
		return
	
	var row = preload("./item_row.tscn").instantiate()
	row.item = item
	row.model = stage.active_model
	
	%StageItems.add_child(row)

func _on_stage_item_removed(item: VtItem) -> void:
	if not is_visible_in_tree():
		return
	
	for i in %StageItems.get_children():
		if i.item == item:
			i.queue_free()

func _on_stage_model_changed(model: VtModel) -> void:
	if not is_visible_in_tree():
		return
	
	for i in %StageItems.get_children():
		if i.item != null and i.item is VtModel:
			i.queue_free()

	_on_stage_item_added(model)

func _on_stage_update_order(objects: Array[Node]) -> void:
	if not is_visible_in_tree():
		return
	
	for i in range(len(objects)):
		var o = objects[i]
		for c in %StageItems.get_children():
			if c.item == o:
				%StageItems.move_child(c, i)

func _on_add_button_pressed() -> void:
	%FileDialog.show()
	
func _on_clear_button_pressed() -> void:
	stage.clear_items()

func _on_load_button_pressed() -> void:
	var popup = preload("./scene_selector/scene_selector_popup.tscn").instantiate()
	add_child(popup)

func _on_file_dialog_files_selected(paths: PackedStringArray) -> void:
	# several files only as the PNG frames of one animation
	if len(paths) > 1:
		for p in paths:
			assert(p.ends_with(".png"), "only selecting multiple PNG paths is supported")
	ItemLibrary.add_imported(paths)
	_preview_item(paths)

## the preview where an item gets placed on the stage
func _preview_item(paths: PackedStringArray) -> void:
	var item = await ItemManager.create_item(paths)
	if item == null:
		return
	var preview = preload("./preview/item_preview.tscn").instantiate()
	preview.item = item
	add_child(preview)
