## Items pinned to a model: VTube Studio's items_pinned_to_model.json beside the model, read once, and Yorishiro's
## own list in the model's settings after that.
##
## A Yorishiro placement ("spec") is {paths, mesh, triangle, weights, pin_angle, rotation, scale, flip, order, fps}:
## the art mesh, a triangle of it (an index into its index array) and the point's weights in it, the triangle's
## angle when pinned, the item's own turn, its size against the model's, mirrored or not, its place in the layer
## order (negative: behind the model) and an animation's frames per second (0: its own).
##
## VTube Studio stores the pin as six vertices of the art mesh with their positions in model units (canvas pixels
## over the moc3's pixels per unit, y up) and an offset from their middle to the item's center. Sizes were measured
## on VTube Studio 1.35's Spout output (models of five canvas shapes, Live2D items of six): VTube Studio draws
## every model at the same pixels per model unit times its scale, and a pinned item at its Size in model units:
## IMAGE_PER_SIZE per picture pixel, LIVE2D_PER_SIZE per unit of a Live2D item's own canvas.
extends RefCounted

const VtItem = preload("res://lib/items/vt_item.gd")
const AnimFrames = preload("res://lib/utils/anim_frames.gd")
const VTS_FILE = "items_pinned_to_model.json"

## model units per picture pixel, per unit of Size
const IMAGE_PER_SIZE = 0.0102
## model units per unit of a Live2D item's canvas, per unit of Size
const LIVE2D_PER_SIZE = 9.7

## the items VTube Studio pinned to this model, as Yorishiro placements (the model must be loaded and on stage).
## Items whose file cannot be found are left out, with a warning.
static func import_vts(model) -> Array:
	var file: String = model.modelmeta.model.get_base_dir().path_join(VTS_FILE)
	if not FileAccess.file_exists(file):
		return []
	var data = JSON.parse_string(FileAccess.get_file_as_string(file))
	if not data is Dictionary:
		push_warning("%s: not readable" % file)
		return []
	var out := []
	for it in data.get("Items", []):
		if not it is Dictionary or not it.get("IsPinned", false) or it.get("IsWeb", false) or it.get("IsVideo", false):
			continue
		var paths := find_item(model.modelmeta.model.get_base_dir(), str(it.get("ItemFileName", "")))
		if paths.is_empty():
			push_warning("%s: item %s not found" % [file, it.get("ItemFileName", "")])
			continue
		var spec := from_vts(model, it, paths)
		if not spec.is_empty():
			out.append(spec)
	return out

## a VTube Studio item file or folder: in the Items folder beside the model's (VTube Studio's own layout), in the
## item library, then beside the model's folder (items kept with the models). An animation folder gives its frames,
## a Live2D item folder its .model3.json.
static func find_item(model_dir: String, name: String) -> PackedStringArray:
	if name.is_empty():
		return PackedStringArray()
	var places := [
		model_dir.get_base_dir().get_base_dir().path_join("Items"),
		ProjectSettings.globalize_path("user://Items"),
		model_dir.get_base_dir(),
	]
	for dir in places:
		var p: String = dir.path_join(name)
		if FileAccess.file_exists(p):
			return PackedStringArray([p])
		if DirAccess.dir_exists_absolute(p):
			var l2d := _live2d_in(p)
			if l2d:
				return PackedStringArray([l2d])
			var frames := AnimFrames.folder_frames(p)
			if frames.size() > 0:
				return frames
	return PackedStringArray()

static func _live2d_in(dir: String) -> String:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".model3.json"):
			return dir.path_join(f)
	return ""

## the art mesh node of a model by name, null when the model has none
static func mesh_named(model, mesh_name: String) -> MeshInstance2D:
	for m in model.get_meshes():
		if m.name == mesh_name:
			return m
	return null

## one VTube Studio pinned item as a placement on this model ({} when it does not fit the model)
static func from_vts(model, it: Dictionary, paths: PackedStringArray) -> Dictionary:
	var mesh := mesh_named(model, str(it.get("PinnedTo", "")))
	if mesh == null:
		push_warning("pinned item %s: the model has no art mesh %s" % [it.get("ItemFileName"), it.get("PinnedTo")])
		return {}
	var ppu: float = model.model.ppu
	var ids := Array(str(it.get("PinnedVertexIDs", "")).split(" ", false)).map(func (s): return int(s))
	var saved: Array = it.get("PinnedVertexPositions", [])
	if ids.size() < 3 or ids.size() != saved.size():
		return {}
	# the vertices as VTube Studio saw them, in the model's pixels (y down like the mesh)
	var at := {}
	var middle := Vector2.ZERO
	for k in ids.size():
		var v := Vector2(float(saved[k].get("x", 0.0)), -float(saved[k].get("y", 0.0))) * ppu
		at[ids[k]] = v
		middle += v
	middle /= ids.size()
	var off: Dictionary = it.get("PinnedVertexCenterOffset", {})
	var point := middle + Vector2(float(off.get("x", 0.0)), -float(off.get("y", 0.0))) * ppu

	# the triangle among those vertices the point is in (or nearest to): its weights stay the point's place
	var f: PackedInt32Array = VtItem.mesh_shape(mesh)[Mesh.ARRAY_INDEX]
	var best := -1
	var best_w := Vector3.ZERO
	var best_score := -INF
	for t in range(0, f.size(), 3):
		if not (at.has(f[t]) and at.has(f[t + 1]) and at.has(f[t + 2])):
			continue
		var w := Geometry3D.get_triangle_barycentric_coords(Vector3(point.x, point.y, 0),
			Vector3(at[f[t]].x, at[f[t]].y, 0), Vector3(at[f[t + 1]].x, at[f[t + 1]].y, 0), Vector3(at[f[t + 2]].x, at[f[t + 2]].y, 0))
		var score := minf(w.x, minf(w.y, w.z))  # >= 0 inside, the less negative the nearer
		if score > best_score:
			best_score = score
			best = t
			best_w = w
	if best < 0:
		push_warning("pinned item %s: no triangle of %s among its vertices" % [it.get("ItemFileName"), mesh.name])
		return {}
	var tri_angle: float = at[f[best]].angle_to_point(at[f[best + 1]])

	var size := float(it.get("Size", 0.0))
	var scale := _scale_for(paths, size, ppu)
	if scale <= 0.0:
		return {}
	return {
		"paths": Array(paths),
		"mesh": str(mesh.name),
		"triangle": best,
		"weights": [best_w.x, best_w.y, best_w.z],
		"pin_angle": tri_angle,
		# VTube Studio turns counterclockwise in degrees, y up
		"rotation": -deg_to_rad(float(it.get("Rotation", 0.0))),
		"scale": scale,
		"flip": bool(it.get("IsFlipped", false)),
		"order": int(it.get("Order", 1)),
		"fps": float(it.get("FPS", 0.0)) if it.get("IsAnimated", false) else 0.0,
	}

## VTube Studio's stage is VIEW_UNITS tall (an unpinned item's Position; measured: 10.95 px per unit on a 1316 px
## high view) and draws a model at MODEL_VIEW of the view's height per model unit at scale 1 (928 px on 1316)
const VIEW_UNITS = 120.2
const MODEL_VIEW = 0.705

## where an unpinned item of a VTube Studio item scene goes: {position (stage pixels), scale}. The size of unpinned
## items could not be measured (VTube Studio sized every unpinned item in a pinned-items file the same); they are
## sized as if pinned to a model at scale 1, which is what Size means for pinned ones.
static func loose_from_vts(it: Dictionary, paths: PackedStringArray, view: Vector2) -> Dictionary:
	var pos: Dictionary = it.get("Position", {})
	var per_unit := view.y / VIEW_UNITS
	var scale := _scale_for(paths, float(it.get("Size", 0.0)), 1.0) * MODEL_VIEW * view.y
	return {
		"position": view / 2.0 + Vector2(float(pos.get("x", 0.0)), -float(pos.get("y", 0.0))) * per_unit,
		"scale": scale,
	}

## the item's scale against the model's (item pixels to model pixels) for a VTube Studio Size
static func _scale_for(paths: PackedStringArray, size: float, model_ppu: float) -> float:
	if paths[0].ends_with(".model3.json"):
		var item_ppu := _model_ppu(paths[0])
		if item_ppu <= 0.0:
			return 0.0
		return size * LIVE2D_PER_SIZE * model_ppu / item_ppu
	return size * IMAGE_PER_SIZE * model_ppu

## pixels per unit of a Live2D model, read from its moc3's canvas info
static func _model_ppu(model3: String) -> float:
	var data = JSON.parse_string(FileAccess.get_file_as_string(model3))
	if not data is Dictionary:
		return 0.0
	var moc: String = model3.get_base_dir().path_join(data.get("FileReferences", {}).get("Moc", ""))
	var fa := FileAccess.open(moc, FileAccess.READ)
	if fa == null or fa.get_length() < 72:
		return 0.0
	fa.seek(68)  # the section offset table starts at 64; its second entry points at the canvas info
	var at := fa.get_32()
	if at + 4 > fa.get_length():
		return 0.0
	fa.seek(at)
	return fa.get_float()

## put a created item (already on stage) where a placement says
static func apply(item: VtItem, model, spec: Dictionary) -> bool:
	var mesh := mesh_named(model, str(spec.get("mesh", "")))
	if mesh != null and spec.get("mode", "") == "centroid":
		# pinned with the pin list: follows the art mesh's middle, keeps its own size
		var o: Array = spec.get("offset", [0, 0])
		item.model = model
		item.pinned_to = mesh
		item.pin_mode = VtItem.PinMode.CENTROID
		item.pin_offset = Vector2(float(o[0]), float(o[1]))
		item.scale = Vector2.ONE * float(spec.get("scale", 1.0)) * model.scale.x
		item.mirror = bool(spec.get("flip", false))
		return true
	var w: Array = spec.get("weights", [])
	var tri := int(spec.get("triangle", -1))
	if mesh == null or w.size() != 3 or tri < 0 or tri + 2 >= VtItem.mesh_shape(mesh)[Mesh.ARRAY_INDEX].size():
		return false
	item.model = model
	item.pinned_to = mesh
	item.pin_mode = VtItem.PinMode.VERTICES
	item.pin_indicies = tri
	item.pin_vertices = Vector3(float(w[0]), float(w[1]), float(w[2]))
	item.pin_angle = float(spec.get("pin_angle", 0.0))
	item.pin_rotation = float(spec.get("rotation", 0.0))
	item.pin_scale = Vector2.ONE * float(spec.get("scale", 1.0))
	item.mirror = bool(spec.get("flip", false))
	var fps := float(spec.get("fps", 0.0))
	if fps > 0.0 and item.render is AnimatedSprite2D:
		var r: AnimatedSprite2D = item.render
		r.speed_scale = fps / maxf(r.sprite_frames.get_animation_speed("default"), 0.001)
	return true

## the placement of a pinned item, to save with the model
static func spec_of(item: VtItem) -> Dictionary:
	if item.pin_mode == VtItem.PinMode.CENTROID:
		return {
			"paths": Array(item.path).map(func (p): return Preferences.portable(p)),
			"mode": "centroid",
			"mesh": str(item.pinned_to.name),
			"offset": [item.pin_offset.x, item.pin_offset.y],
			"scale": item.scale.x / maxf(item.model.scale.x, 0.0001),
			"flip": item.mirror,
			"order": item.get_meta("order", 1),
		}
	var spec := {
		"paths": Array(item.path).map(func (p): return Preferences.portable(p)),
		"mesh": str(item.pinned_to.name),
		"triangle": item.pin_indicies,
		"weights": [item.pin_vertices.x, item.pin_vertices.y, item.pin_vertices.z],
		"pin_angle": item.pin_angle,
		"rotation": item.pin_rotation,
		"scale": item.pin_scale.x,
		"flip": item.mirror,
		"order": item.get_meta("order", 1),
		"fps": 0.0,
	}
	if item.render is AnimatedSprite2D:
		var r: AnimatedSprite2D = item.render
		spec.fps = r.speed_scale * r.sprite_frames.get_animation_speed("default")
	return spec
