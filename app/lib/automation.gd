## Command line automation for tests, inert unless user args are given after "--":
##   --model=<path>         load a model at startup
##   --tracker=<name>       activate a tracking input, e.g. yorishiro
##   --screenshot=<png>     save the stage after --wait-frames rendered frames
##   --wait-frames=<n>      default 90, lets physics and tracking settle
##   --burst=<n>            after the screenshot, n more (<name>_01.png ...) with the tracked pose
##   --burst-every=<n>      frames between burst shots, default 60
##   --poses=<json>         instead of a camera, hold each named pose ({"name": {"FaceAngleX": 30}}) and
##                          save <name>_<pose>.png after --pose-frames (default 90) frames
##   --hotkeys              after the screenshot, toggle each expression hotkey and save <name>_hotkey_<expression>.png
##   --dump-meshes=<a,b>    after each pose or hotkey shot, print these art meshes as Godot draws them
##   --dump-above=<a,b>     ... and the visible meshes drawn on top of them
##   --unmask=<a,b>, --raise=<a,b>  before each hotkey shot, draw these meshes without their mask, or on top
##   --print-params=<a,b>   model parameters printed after each pose (default: angles, eyes, mouth open)
##   --fixed-clock          blink, breathing and smoothing count frames instead of wall time, random seed 1.
##                          With Godot's --fixed-fps 60 the same run gives the same screenshots
##   --pipe-frames=<file>   keep writing the rendered stage to a shared file (for example in /dev/shm), for
##                          the PipeWire test tool (/media/koshizu/Work/dev/external/funnel-sender, outside the repo)
##   --press=<a,b>          after --open-panel, press these buttons (node names) in order, for screenshots of what they open
##   --quit                 exit after the screenshot
extends Node

const CameraTracker = preload("res://lib/tracking/camera/camera_tracker.gd")
const Clock = preload("res://lib/utils/clock.gd")

var _pose_tracker
const TRACKERS = {
	"yorishiro": "res://lib/tracking/camera/yorishiro/yorishiro_tracker.gd",
	"openseeface": "res://lib/tracking/camera/openseeface/osf_tracker.gd",
}

func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv = a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	if args.is_empty():
		return
	if args.has("fixed-clock"):
		seed(1)
	# wait for the main scene so the stage exists
	await get_tree().process_frame
	var stage = get_tree().get_first_node_in_group("system:stage")
	var model = null

	if args.has("model"):
		model = ModelManager.make_model(args["model"])
		if model == null:
			push_error("[automation] could not load model %s" % args["model"])
		else:
			# loading takes a varying number of frames, so count waits and the fixed clock from the end of it
			await stage.spawn_model(model)
			Clock.origin_frame = Engine.get_process_frames()

	if args.has("poses"):
		# hold the model still from the start, the saved tracker could still be feeding it otherwise
		_pose_tracker = get_tree().get_first_node_in_group("system:tracking").activate_tracker(CameraTracker.new())

	if args.has("tracker"):
		# the settings panel restores the saved tracker a frame after startup, go after it
		for i in 10:
			await get_tree().process_frame
		var tracking = get_tree().get_first_node_in_group("system:tracking")
		tracking.activate_tracker(load(TRACKERS[args["tracker"]]).new())
		print("[automation] tracker %s" % args["tracker"])

	if args.has("pipe-frames"):
		_pipe_frames(args["pipe-frames"], stage.capture_viewport if stage else get_viewport())

	if args.has("screenshot") or args.has("screenshot-window"):
		if args.has("open-panel"):
			# the HUD restores its own state over the first frames, open the panel after that
			for i in 15:
				await get_tree().process_frame
			_open_panel(args["open-panel"])
			for button_name in args.get("press", "").split(",", false):
				for i in 30:
					await get_tree().process_frame
				var button = get_tree().root.find_child(button_name, true, false)
				if button is BaseButton:
					button.pressed.emit()
				else:
					push_error("[automation] no button %s" % button_name)
		for i in int(args.get("wait-frames", "90")):
			await RenderingServer.frame_post_draw
		if args.has("screenshot-window"):
			var werr = get_viewport().get_texture().get_image().save_png(args["screenshot-window"])
			print("[automation] window screenshot %s -> %s" % [args["screenshot-window"], error_string(werr)])
		var viewport = stage.capture_viewport if stage else get_viewport()
		var path: String = args.get("screenshot", "")
		if path:
			var err = viewport.get_texture().get_image().save_png(path)
			print("[automation] screenshot %s -> %s" % [path, error_string(err)])
			if args.has("poses"):
				await _shoot_poses(args, viewport, path)
			if args.has("hotkeys"):
				await _shoot_hotkeys(args, viewport, path)
			for b in int(args.get("burst", "0")):
				for i in int(args.get("burst-every", "60")):
					await RenderingServer.frame_post_draw
				var shot = "%s_%02d.png" % [path.get_basename(), b + 1]
				err = viewport.get_texture().get_image().save_png(shot)
				var tp = get_tree().get_first_node_in_group("system:tracking").parameters
				print("[automation] burst %s -> %s, %.0f fps, FaceAngleX %.1f FaceAngleY %.1f FaceAngleZ %.1f EyeOpenLeft %.2f MouthOpen %.2f MouthSmile %.2f" % [
					shot, error_string(err), Engine.get_frames_per_second(), tp.get("FaceAngleX", 0.0), tp.get("FaceAngleY", 0.0),
					tp.get("FaceAngleZ", 0.0), tp.get("EyeOpenLeft", 0.0), tp.get("MouthOpen", 0.0), tp.get("MouthSmile", 0.0)])
		var tracking = get_tree().get_first_node_in_group("system:tracking")
		if tracking:
			var p = tracking.parameters
			print("[automation] tracker %s, FaceAngleX %s, EyeOpenLeft %s, MouthOpen %s" % [
				tracking.get_node_or_null("FaceTracker"), p.get("FaceAngleX"), p.get("EyeOpenLeft"), p.get("MouthOpen")])
			var face = tracking.get_node_or_null("FaceTracker")
			if face and "status" in face:
				print("[automation] tracker status %s" % JSON.stringify(face.status))
				for line in face.log_lines:
					print("[automation] tracker log: %s" % line)
		if model:
			print("[automation] graphs %s, ParamAngleX %s" % [
				model.blueprints.map(func (g): return "%s(%d nodes, %s)" % [g.name, g.get_child_count(), g.process_mode]),
				model.get("parameters/ParamAngleX")])

	if args.has("quit"):
		get_tree().quit()

## streams the stage until the app quits through a shared file (Godot opens only regular files, no FIFO):
## uint32 sequence, width, height, 0, then RGBA8 rows top first. The sequence is odd while a frame is
## being written, the reader keeps a frame only if it read the same even number before and after.
func _pipe_frames(path: String, viewport: Viewport):
	var f := FileAccess.open(path, FileAccess.WRITE_READ)
	if f == null:
		push_error("[automation] cannot open %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return
	var size := Vector2i.ZERO
	var seq := 0
	while is_inside_tree():
		await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image()
		image.convert(Image.FORMAT_RGBA8)
		if size == Vector2i.ZERO:
			size = image.get_size()
			print("[automation] piping %dx%d frames to %s" % [size.x, size.y, path])
		elif image.get_size() != size:
			image.resize(size.x, size.y)
		f.seek(0)
		f.store_32(seq + 1)
		f.flush()
		f.store_32(size.x)
		f.store_32(size.y)
		f.store_32(0)
		f.store_buffer(image.get_data())
		seq += 2
		f.seek(0)
		f.store_32(seq)
		f.flush()

func _open_panel(which: String):
	# --open-panel names: model and item open the models page, camera the settings page, others by page id
	var page = {"model": &"model", "item": &"model", "camera": &"settings"}.get(which, StringName(which))
	var overlay = get_tree().root.find_child("SettingsOverlay", true, false)
	if overlay == null:
		push_error("[automation] no settings overlay")
		return
	overlay.open_page(page)

## presses every expression hotkey of the model's graphs once (on, shot, off), as the key would
func _shoot_hotkeys(args: Dictionary, viewport: Viewport, path: String):
	var model = get_tree().get_first_node_in_group("system:stage").active_model
	var names: Array = args.get("print-params", "").split(",", false)
	for graph in model.blueprints:
		for node in graph.get_children():
			if not ("expression" in node) or node.expression.is_empty():
				continue
			node.invoke_trigger(1)
			for i in int(args.get("pose-frames", "90")):
				await RenderingServer.frame_post_draw
			_debug_meshes_before(args, model)
			await RenderingServer.frame_post_draw
			var shot = "%s_hotkey_%s.png" % [path.get_basename(), node.expression]
			var err = viewport.get_texture().get_image().save_png(shot)
			print("[automation] hotkey %s -> %s, %s" % [shot, error_string(err), " ".join(names.map(
				func (q): return "%s %s" % [q, model.get("parameters/%s" % q)]))])
			_debug_meshes_after(args, model)
			node.invoke_trigger(1)
			for i in int(args.get("pose-frames", "90")):
				await RenderingServer.frame_post_draw

## debugging aids for one mesh: --unmask and --raise change it before the shot, --dump-above and
## --dump-meshes print what Godot draws (vertex bbox from the GPU copy, mask state, meshes on top)
func _debug_meshes_before(args: Dictionary, model):
	for mesh_name in args.get("unmask", "").split(",", false):
		var mi = model.find_child(mesh_name, true, false)
		mi.material = mi.material.duplicate()
		mi.material.set_shader_parameter("has_mask", false)
	for mesh_name in args.get("raise", "").split(",", false):
		var mi = model.find_child(mesh_name, true, false)
		mi.get_parent().move_child(mi, -1)

func _debug_meshes_after(args: Dictionary, model):
	for mesh_name in args.get("dump-above", "").split(",", false):
		var target = model.find_child(mesh_name, true, false)
		var box: AABB = target.mesh.get_aabb()
		var rect = Rect2(box.position.x, box.position.y, box.size.x, box.size.y)
		for other in target.get_parent().get_children():
			if other.get_index() <= target.get_index() or not other.is_visible_in_tree() or other.self_modulate.a <= 0.0:
				continue
			var ob: AABB = other.mesh.get_aabb()
			if rect.intersects(Rect2(ob.position.x, ob.position.y, ob.size.x, ob.size.y)):
				print("[automation]   above %s: %s index %d alpha %s" % [mesh_name, other.name, other.get_index(), other.self_modulate.a])
	for mesh_name in args.get("dump-meshes", "").split(",", false):
		var mi = model.find_child(mesh_name, true, false)
		if mi == null:
			print("[automation]   %s missing" % mesh_name)
			continue
		var mat = mi.material
		var verts: PackedVector2Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var vb := Rect2(verts[0], Vector2.ZERO)
		for vv in verts:
			vb = vb.expand(vv)
		print("[automation]   %s mesh %s vertex bbox %s first %s" % [mesh_name, mi.mesh.get_rid(), vb, verts[0]])
		print("[automation]   %s path %s index %d visible %s alpha %s has_mask %s mesh_offset %s mask_invert %s aabb %s" % [
			mesh_name, model.get_path_to(mi), mi.get_index(), mi.is_visible_in_tree(), mi.self_modulate.a,
			mat.get_shader_parameter("has_mask") if mat else null, mat.get_shader_parameter("mesh_offset") if mat else null,
			mi.get_instance_shader_parameter("mask_invert"), mi.mesh.get_aabb() if mi.mesh else null])

## each pose is held by a fixed tracker, updated every frame so its smoothing converges
func _shoot_poses(args: Dictionary, viewport: Viewport, path: String):
	var poses: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(args["poses"]))
	var tracker = _pose_tracker
	var names: Array = args.get("print-params", "ParamAngleX,ParamAngleZ,ParamEyeLOpen,ParamEyeROpen,ParamMouthOpenY").split(",")
	for pose in poses:
		for i in int(args.get("pose-frames", "90")):
			tracker.update(poses[pose])
			await RenderingServer.frame_post_draw
		var shot = "%s_%s.png" % [path.get_basename(), pose]
		var err = viewport.get_texture().get_image().save_png(shot)
		var model = get_tree().get_first_node_in_group("system:stage").active_model
		print("[automation] pose %s -> %s, %s" % [shot, error_string(err), " ".join(names.map(
			func (q): return "%s %s" % [q, model.get("parameters/%s" % q) if model else null]))])
		_debug_meshes_after(args, model)
		tracker.reset()
