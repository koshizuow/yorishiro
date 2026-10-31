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
##   --face-preview         show the 3D tracking preview head in the window corner, next to the stage (with
##                          --poses and only --screenshot-window: one shot per pose with both)
##   --show=<name>          after --open-panel and --press, scroll the page so this node (name) is in view
##   --import-models=<dir>  add every model under dir to the model library, as the import card would
##   --cycle-models=<prefix> after the screenshot, open each library model in turn like a click on its card, save
##                          <prefix>_<nn>_<name>.png (window) after --pose-frames frames and print load time
##   --gestures=<prefix>    after the screenshot, operate the model with synthetic mouse and key events (drag,
##                          wheel, wheel while dragging, shift+wheel, right drag), save <prefix>_<step>.png and print
##                          the model transform after each step
##   --hotkey-test=<prefix> after --open-panel=hotkeys, add a hotkey through the list, set Ctrl+K with key
##                          events, switch it to an animation, hold mode, screen button 3, press that button,
##                          save, reload the model and check it is still there, then delete it
##   --sensitivity-test=<param> after --open-panel=sensitivity, drag the range handles and the smoothing slider of
##                          that model parameter's row, check the graph, the mapping and that both survive a reload
##   --eye-test             with the Yorishiro tracker running: toggle "blink both eyes together" and automatic
##                          blinking on the tracking input, sample EyeOpenLeft/Right as the graph sees them for 8 s
##   --calibration-test     after --open-panel=sensitivity, run the guided calibration with a fixed-pose tracker
##                          that follows each instruction like a user would, and check the bands it sets
##   --model-transform=<x,y,scale> place the loaded model (stage pixels, scale factor), for fixed framing
##   --expressions=<a,b>    turn these expressions of the loaded model on (e.g. outfit toggles)
##   --follow-face=<x,y,z>  move the loaded model with the face, these amounts (VTS units), or "off"
##   --record=<dir>         after the screenshot, save the window as <dir>/00001.jpg ... at 30 fps for
##                          --record-seconds (default 10), and the tracked values per frame in <dir>/params.csv
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

	if args.has("import-models"):
		for p in ModelLibrary._find_models(args["import-models"], [".model3.json", ".vrm"]):
			ModelLibrary.add_imported(p)
		print("[automation] library has %d models" % ModelLibrary.list().size())

	if model:
		print("[automation] model %s at %s scale %.4f" % [model.display_name, model.position, model.scale.x])
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
		if args.has("press"):
			for i in 15:
				await get_tree().process_frame
		for button_name in args.get("press", "").split(",", false):
			for i in 30:
				await get_tree().process_frame
			var button = get_tree().root.find_child(button_name, true, false)
			if button is BaseButton:
				button.pressed.emit()
			else:
				push_error("[automation] no button %s" % button_name)
		if args.has("face-preview"):
			var layer := CanvasLayer.new()
			layer.layer = 50
			var head := FacePreview.new()
			head.custom_minimum_size = Vector2(300, 300)
			head.position = Vector2(16, 16)
			layer.add_child(head)
			get_tree().root.add_child(layer)
		if args.has("show"):
			for i in 30:
				await get_tree().process_frame
			var target = get_tree().root.find_child(args["show"], true, false)
			var scroll = target.get_parent() if target else null
			while scroll and not (scroll is ScrollContainer):
				scroll = scroll.get_parent()
			if scroll:
				scroll.ensure_control_visible(target)
			else:
				push_error("[automation] cannot show %s" % args["show"])
		# after the model's saved settings (transform, expressions) have been applied
		var placed = stage.active_model if stage else null
		if args.has("follow-face") and placed:
			placed.movement_enabled = args["follow-face"] != "off"
			var amounts: PackedStringArray = args["follow-face"].split(",")
			if amounts.size() == 3:
				placed.movement_amount = Vector3(float(amounts[0]), float(amounts[1]), float(amounts[2]))
			print("[automation] follow face %s %s" % [placed.movement_enabled, placed.movement_amount])
		if args.has("model-transform") and placed:
			# the model slides in over 0.5 s after it loads, place it after that tween
			for i in 45:
				await RenderingServer.frame_post_draw
			var t := PackedFloat64Array()
			for x in args["model-transform"].split(","):
				t.append(float(x))
			placed.position = Vector2(t[0], t[1])
			placed.scale = Vector2(t[2], t[2])
			placed.notify_transform_updated()
			print("[automation] placed at %s scale %s" % [placed.position, placed.scale])
		if args.has("expressions") and placed:
			var controller = placed.get_expression_controller()
			for e in args["expressions"].split(",", false):
				controller.set("weight/%s" % e, 1.0)
		for i in int(args.get("wait-frames", "90")):
			await RenderingServer.frame_post_draw
		if placed:
			print("[automation] before shot at %s scale %s" % [placed.position, placed.scale])
		if args.has("screenshot-window"):
			var werr = get_viewport().get_texture().get_image().save_png(args["screenshot-window"])
			print("[automation] window screenshot %s -> %s" % [args["screenshot-window"], error_string(werr)])
			if args.has("poses") and not args.has("screenshot"):  # poses of the whole window, e.g. the face preview
				await _shoot_poses(args, get_viewport(), args["screenshot-window"])
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
		if args.has("cycle-models"):
			await _cycle_models(args)
		if args.has("gestures"):
			await _gestures(args["gestures"])
		if args.has("hotkey-test"):
			await _hotkey_test(args["hotkey-test"])
		if args.has("sensitivity-test"):
			await _sensitivity_test(args["sensitivity-test"])
		if args.has("eye-test"):
			await _eye_test()
		if args.has("calibration-test"):
			await _calibration_test(args)
		if args.has("record"):
			await _record(args)
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

## opens every library model in turn, the way the picker does, and reports how each one went
func _cycle_models(args: Dictionary):
	var stage = get_tree().get_first_node_in_group("system:stage")
	var entries := ModelLibrary.list()
	var n := 0
	for entry in entries:
		n += 1
		var start := Time.get_ticks_msec()
		ModelLibrary.open(entry.path)
		var loaded := false
		for i in 600:
			await get_tree().process_frame
			if stage.active_model and stage.active_model.modelmeta and stage.active_model.modelmeta.model == entry.path:
				loaded = true
				break
		var ms := Time.get_ticks_msec() - start
		for i in int(args.get("pose-frames", "90")):
			await RenderingServer.frame_post_draw
		var shot = "%s_%02d_%s.png" % [args["cycle-models"], n, entry.name.validate_filename()]
		get_viewport().get_texture().get_image().save_png(shot)
		var m = stage.active_model
		print("[automation] cycle %d/%d %s: %s in %d ms, %d meshes, %.0f fps, %d nodes on stage -> %s" % [
			n, entries.size(), entry.name, "loaded" if loaded else "NOT LOADED", ms,
			m.get_meshes().size() if loaded and m.has_method("get_meshes") else -1,
			Engine.get_frames_per_second(), stage.canvas.get_child_count(), shot])

## each step is what a user would do with the mouse over the model, in window coordinates
func _gestures(prefix: String):
	var stage = get_tree().get_first_node_in_group("system:stage")
	var model = stage.active_model
	# [name, operations, aim point as a fraction of the model's rect (default its center)]
	var steps := [
		["start", []],
		["drag_right_200", [["press", MOUSE_BUTTON_LEFT], ["move", Vector2(200, 0)], ["release", MOUSE_BUTTON_LEFT]]],
		["wheel_up_x10_at_head", [["wheel", MOUSE_BUTTON_WHEEL_UP, 10]], Vector2(0.5, 0.12)],
		["wheel_down_x10_at_head", [["wheel", MOUSE_BUTTON_WHEEL_DOWN, 10]], Vector2(0.5, 0.12)],
		["wheel_down_x10_while_dragging", [["press", MOUSE_BUTTON_LEFT], ["wheel", MOUSE_BUTTON_WHEEL_DOWN, 10], ["release", MOUSE_BUTTON_LEFT]]],
		["shift_wheel_x10", [["key", KEY_SHIFT, true], ["wheel", MOUSE_BUTTON_WHEEL_UP, 10], ["key", KEY_SHIFT, false]]],
		["shift_wheel_back_x10", [["key", KEY_SHIFT, true], ["wheel", MOUSE_BUTTON_WHEEL_DOWN, 10], ["key", KEY_SHIFT, false]]],
		["drag_left_1500_offscreen", [["press", MOUSE_BUTTON_LEFT], ["move", Vector2(-1500, 0)], ["release", MOUSE_BUTTON_LEFT]]],
		["drag_back_right_300", [["press", MOUSE_BUTTON_LEFT], ["move", Vector2(300, 0)], ["release", MOUSE_BUTTON_LEFT]], Vector2(0.6, 0.5)],
		["drag_down_1000_offscreen", [["press", MOUSE_BUTTON_LEFT], ["move", Vector2(0, 1000)], ["release", MOUSE_BUTTON_LEFT]]],
	]
	for step in steps:
		# aim at the model's current center, converted from the stage viewport to the window
		var aim: Vector2 = step[2] if step.size() > 2 else Vector2(0.5, 0.5)
		var center: Vector2 = model.get_global_transform_with_canvas() * (model.rect.position + model.rect.size * aim)
		var at := _stage_to_window(stage, center)
		_mouse_motion(at, Vector2.ZERO)
		await get_tree().process_frame
		for op in step[1]:
			match op[0]:
				"press", "release":
					var e := InputEventMouseButton.new()
					e.button_index = op[1]
					e.pressed = op[0] == "press"
					e.position = at
					e.global_position = at
					e.button_mask = MOUSE_BUTTON_MASK_LEFT if op[1] == MOUSE_BUTTON_LEFT and e.pressed else 0
					Input.parse_input_event(e)
				"move":
					for i in 10:
						var d: Vector2 = op[1] / 10.0
						at += d
						_mouse_motion(at, d)
						await get_tree().process_frame
				"wheel":
					for i in op[2]:
						for pressed in [true, false]:
							var e := InputEventMouseButton.new()
							e.button_index = op[1]
							e.pressed = pressed
							e.position = at
							e.global_position = at
							e.factor = 1.0
							Input.parse_input_event(e)
						await get_tree().process_frame
				"key":
					var k := InputEventKey.new()
					k.keycode = op[1]
					k.physical_keycode = op[1]
					k.pressed = op[2]
					Input.parse_input_event(k)
			await get_tree().process_frame
		for i in 20:
			await RenderingServer.frame_post_draw
		var shot = "%s_%s.png" % [prefix, step[0]]
		get_viewport().get_texture().get_image().save_png(shot)
		print("[automation] gesture %s: position %s scale %.3f rotation %.1f deg -> %s" % [
			step[0], model.position.round(), model.scale.x, model.rotation_degrees, shot])

func _stage_to_window(stage, p: Vector2) -> Vector2:
	var container: Control = stage.capture_viewport.get_parent()
	return container.get_global_transform_with_canvas() * (p * Vector2(container.size) / Vector2(stage.capture_viewport.size))

func _mouse_motion(at: Vector2, rel: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = at
	m.global_position = at
	m.relative = rel
	m.button_mask = MOUSE_BUTTON_MASK_LEFT if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) else 0
	Input.parse_input_event(m)

func _hotkey_test(prefix: String):
	var list = get_tree().root.find_child("HotkeyList", true, false)
	var stage = get_tree().get_first_node_in_group("system:stage")
	var check := func (what: String, ok: bool): print("[automation] hotkey %s: %s" % [what, "ok" if ok else "FAILED"])
	list.refresh()
	var before: int = list.entries().size()
	list.get_node("AddHotkeyBtn").pressed.emit()
	for i in 3:
		await get_tree().process_frame
	var entries: Array = list.entries()
	check.call("add (%d -> %d)" % [before, entries.size()], entries.size() == before + 1)
	var row = list._rows.get_child(list._rows.get_child_count() - 1)
	# key capture: click the keys button, then Ctrl+K as real key events
	row.get_child(1).pressed.emit()
	for k in [[KEY_CTRL, true, false], [KEY_K, true, true], [KEY_K, false, true], [KEY_CTRL, false, false]]:
		var ev := InputEventKey.new()
		ev.keycode = k[0]
		ev.physical_keycode = k[0]
		ev.pressed = k[1]
		ev.ctrl_pressed = k[2]
		Input.parse_input_event(ev)
		await get_tree().process_frame
	var e: Dictionary = list.entries()[-1]
	var keys: Array = e.key.get_node("%Handler").input_as_list
	check.call("keys %s" % [keys], keys == ["Ctrl", "K"])
	# switch to the first animation, hold mode, screen button 3
	var action: OptionButton = row.get_child(0)
	var anim_index := -1
	for i in action.item_count:
		if action.get_item_text(i).begins_with(tr("Animation: %s") % ""):
			anim_index = i
			break
	if anim_index >= 0:
		action.select(anim_index)
		action.item_selected.emit(anim_index)
	(row.get_child(2) as CheckBox).button_pressed = true
	var screen: OptionButton = row.get_child(3)
	screen.select(3)
	screen.item_selected.emit(3)
	for i in 3:
		await get_tree().process_frame
	e = list.entries()[-1]
	check.call("action %s" % e.kind, anim_index < 0 or e.kind == &"animation")
	check.call("hold", e.hold)
	check.call("screen button %d" % list._button_index(e), list._button_index(e) == 2)
	list.refresh()
	await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png("%s_edited.png" % prefix)
	var hud = get_tree().root.find_child("HUD", true, false)
	hud.refresh_screen_buttons()
	var btn: Button = hud.onscreen_buttons.get_node("%Buttons").get_child(2)
	check.call("stage shows screen button 3 (%s)" % btn.text, btn.visible)
	# clicking it plays the animation, or toggles the expression, it was wired to
	var player: AnimationPlayer = stage.active_model.get_animation_player()
	var controller = stage.active_model.get_expression_controller()
	var was_on: bool = e.kind == &"expression" and controller.is_activated(e.target.expression)
	hud.onscreen_buttons.get_node("%Buttons").get_child(2).pressed.emit()
	for i in 5:
		await get_tree().process_frame
	if e.kind == &"animation":
		check.call("screen button 3 plays %s" % player.current_animation, player.is_playing())
	else:
		var now_on: bool = controller.is_activated(e.target.expression)
		check.call("screen button 3 toggles %s (%s -> %s)" % [e.target.expression, was_on, now_on], now_on != was_on)
	# save, load the same model again, the hotkey must come back from .yori.json
	var path: String = stage.active_model.modelmeta.model
	var count: int = list.entries().size()
	stage.active_model.save_settings()
	ModelLibrary.open(path)
	for i in 600:
		await get_tree().process_frame
		if stage.active_model and stage.active_model.modelmeta.model == path and stage.active_model != list.model and not stage.active_model.blueprints.is_empty():
			break
	for i in 30:
		await get_tree().process_frame
	list.refresh()
	entries = list.entries()
	check.call("after reload %d entries (expected %d)" % [entries.size(), count], entries.size() == count)
	var found := entries.filter(func (x): return x.key and x.key.get_node("%Handler").input_as_list == ["Ctrl", "K"])
	check.call("Ctrl+K kept", found.size() == 1)
	if found:
		list._delete(found[0])
		await get_tree().process_frame
		await get_tree().process_frame
		check.call("delete (%d left, expected %d)" % [list.entries().size(), before], list.entries().size() == before)
		# quitting from here skips the save a window close does
		stage.active_model.save_settings()
	get_viewport().get_texture().get_image().save_png("%s_after.png" % prefix)

func _sensitivity_test(param: String):
	var page = get_tree().root.find_child("SensitivityPage", true, false)
	var stage = get_tree().get_first_node_in_group("system:stage")
	var check := func (what: String, ok: bool): print("[automation] sensitivity %s: %s" % [what, "ok" if ok else "FAILED"])
	page.refresh()
	var row = page._rows.filter(func (r): return r.chain.param == param)
	check.call("row for %s" % param, not row.is_empty())
	if row.is_empty():
		return
	var meter: RangeMeter = row[0].meter
	var had_rangemap: bool = row[0].chain.rangemap != null
	# drag the high handle to 60% of the track, the low one to 10%
	for target in [[1.0, 0.6], [0.0, 0.1]]:
		for step in [[true, target[0]], [false, target[1]]]:
			var e: InputEventMouse = InputEventMouseButton.new() if step[0] else InputEventMouseMotion.new()
			e.position = Vector2(meter._x(lerpf(meter.domain.x, meter.domain.y, step[1])), meter.size.y / 2)
			if e is InputEventMouseButton:
				e.button_index = MOUSE_BUTTON_LEFT
				e.pressed = true
			meter._gui_input(e)
		var up := InputEventMouseButton.new()
		up.button_index = MOUSE_BUTTON_LEFT
		meter._gui_input(up)
		for i in 3:
			await get_tree().process_frame
	var chain: Dictionary = row[0].chain
	var span: float = meter.domain.y - meter.domain.x
	var want := Vector2(meter.domain.x + span * 0.1, meter.domain.x + span * 0.6)
	check.call("rangemap %s (was there: %s)" % ["inserted" if not had_rangemap else "kept", had_rangemap], chain.rangemap != null)
	check.call("band %s, expected about %s" % [chain.rangemap.a, want], chain.rangemap.a.distance_to(want) < span * 0.02)
	# the middle of the band drives the middle of the parameter range
	var b: Vector2 = chain.rangemap.b
	chain.rangemap.update_value(chain.rangemap.v_slot, (want.x + want.y) / 2)
	var mid: float = chain.rangemap.get_value(0)
	check.call("mapping middle -> %.3f (expected %.3f)" % [mid, (b.x + b.y) / 2], absf(mid - (b.x + b.y) / 2) < absf(b.y - b.x) * 0.03)
	# smoothing slider to 40
	var slider: HSlider = meter.get_parent().get_child(2).get_child(1)
	slider.value = 40
	for i in 3:
		await get_tree().process_frame
	check.call("smoothing %s" % (chain.smoothing.smoothing if chain.smoothing else -1.0), chain.smoothing != null and is_equal_approx(chain.smoothing.smoothing, 0.4))
	var order := []
	for c in page.chains():
		if c.param == param:
			order = [c.tracker != null, c.smoothing != null, c.rangemap != null]
	check.call("chain tracker, smoothing, rangemap found again %s" % [order], order == [true, true, true])
	# save and reload
	var path: String = stage.active_model.modelmeta.model
	var old_model = stage.active_model
	old_model.save_settings()
	ModelLibrary.open(path)
	for i in 600:
		await get_tree().process_frame
		if stage.active_model != old_model and stage.active_model and not stage.active_model.blueprints.is_empty():
			break
	for i in 30:
		await get_tree().process_frame
	page.refresh()
	var again = page.chains().filter(func (c): return c.param == param)
	check.call("after reload band %s smoothing %s" % [again[0].rangemap.a if again and again[0].rangemap else null,
		again[0].smoothing.smoothing if again and again[0].smoothing else null],
		again and again[0].rangemap and again[0].rangemap.a.distance_to(want) < span * 0.02 and again[0].smoothing and is_equal_approx(again[0].smoothing.smoothing, 0.4))

func _eye_test():
	var stage = get_tree().get_first_node_in_group("system:stage")
	var tracker = null
	for g in stage.active_model.blueprints:
		for n in g.get_children():
			if n.has_method("get_type") and n.get_type() == &"tracking_input" and "EyeOpenLeft" in n.values:
				tracker = n
	if tracker == null:
		print("[automation] eye test: no tracking input with eyes")
		return
	var tracking = get_tree().get_first_node_in_group("system:tracking")
	for mode in [["off", false, 0], ["linked", true, 0], ["auto always", false, 2]]:
		tracker.link_eyes = mode[1]
		tracker.auto_blink = mode[2]
		var diffs := 0.0
		var closes := 0
		var was_closed := false
		var frames := 0
		var start := Time.get_ticks_msec()
		while Time.get_ticks_msec() - start < 8000:
			await get_tree().process_frame
			frames += 1
			var l: float = tracker.values.EyeOpenLeft
			var r: float = tracker.values.EyeOpenRight
			diffs = maxf(diffs, absf(l - r))
			var closed := minf(l, r) < 0.3
			if closed and not was_closed:
				closes += 1
			was_closed = closed
		print("[automation] eye test %s: max |left-right| %.3f, %d closes in 8 s (%d frames, face %s)" % [mode[0], diffs, closes, frames, tracking.face_present])
	tracker.link_eyes = false
	tracker.auto_blink = 0

func _calibration_test(args: Dictionary):
	var page = get_tree().root.find_child("SensitivityPage", true, false)
	var check := func (what: String, ok: bool): print("[automation] calibration %s: %s" % [what, "ok" if ok else "FAILED"])
	var tracker = get_tree().get_first_node_in_group("system:tracking").activate_tracker(CameraTracker.new())
	# what a cooperative user's face gives at each instruction
	var faces := {
		"neutral": {"EyeOpenLeft": 0.9, "EyeOpenRight": 0.9, "MouthOpen": 0.05, "MouthSmile": 0.1, "Brows": 0.5},
		"eyes_closed": {"EyeOpenLeft": 0.1, "EyeOpenRight": 0.1, "MouthOpen": 0.05, "MouthSmile": 0.1, "Brows": 0.5},
		"mouth_open": {"EyeOpenLeft": 0.9, "EyeOpenRight": 0.9, "MouthOpen": 0.8, "MouthSmile": 0.1, "Brows": 0.5},
		"smile": {"EyeOpenLeft": 0.9, "EyeOpenRight": 0.9, "MouthOpen": 0.05, "MouthSmile": 0.85, "Brows": 0.5},
		"brows_up": {"EyeOpenLeft": 0.9, "EyeOpenRight": 0.9, "MouthOpen": 0.05, "MouthSmile": 0.1, "Brows": 0.9},
	}
	page.refresh()
	page.calibrate_guided()
	var shot_taken := false
	while true:
		await get_tree().process_frame
		if not page._guide.visible:
			break
		var current = page.STEPS.filter(func (st): return tr(st[1]) == page._guide_text.text)
		if current:
			tracker.update(faces[current[0][0]])
			if current[0][0] == "mouth_open" and not shot_taken and page._guide_bar.value > 0.5:
				get_viewport().get_texture().get_image().save_png(String(args.get("screenshot-window", "/tmp/calibration.png")).get_basename() + "_guide.png")
				shot_taken = true
	for i in 5:
		await get_tree().process_frame
	var bands: Dictionary = page.last_calibration.get("bands", {})
	var expect := {"EyeOpenLeft": Vector2(0.18, 0.86), "MouthOpen": Vector2(0.0875, 0.7625), "MouthSmile": Vector2(0.1375, 0.8125), "Brows": Vector2(0.52, 0.88)}
	for p in expect:
		var got: Vector2 = bands.get(p, Vector2(-1, -1))
		check.call("%s band %s, expected %s" % [p, got, expect[p]], got.distance_to(expect[p]) < 0.03)
	var mouth = page.chains().filter(func (c): return c.tracker_param == "MouthOpen")
	check.call("mouth row rangemap %s" % (mouth[0].rangemap.a if mouth and mouth[0].rangemap else null), mouth and mouth[0].rangemap and mouth[0].rangemap.a.distance_to(expect.MouthOpen) < 0.03)
	check.call("parts %s" % [page.last_calibration.get("applied")], page.last_calibration.get("applied", []).size() >= 3)

const RECORD_PARAMS = ["FaceAngleX", "FaceAngleY", "FaceAngleZ", "EyeOpenLeft", "EyeOpenRight", "MouthOpen", "MouthSmile", "Brows", "FacePositionX", "FacePositionY", "FacePositionZ"]

func _record(args: Dictionary):
	var dir: String = args["record"]
	DirAccess.make_dir_recursive_absolute(dir)
	var csv := FileAccess.open(dir.path_join("params.csv"), FileAccess.WRITE)
	# move_x, move_y, move_scale: the follow-the-face offset of the active Live2D model
	csv.store_line("frame,ms,face," + ",".join(RECORD_PARAMS) + ",move_x,move_y,move_scale")
	var stage = get_tree().get_first_node_in_group("system:stage")
	var tracking = get_tree().get_first_node_in_group("system:tracking")
	var seconds := float(args.get("record-seconds", "10"))
	var start := Time.get_ticks_msec()
	var n := 0
	while Time.get_ticks_msec() - start < seconds * 1000:
		await RenderingServer.frame_post_draw
		var ms := Time.get_ticks_msec() - start
		# one picture per 1/30 s of wall time, the app renders faster
		if ms < n * 1000.0 / 30.0:
			continue
		n += 1
		get_viewport().get_texture().get_image().save_jpg(dir.path_join("%05d.jpg" % n), 0.9)
		var row := ["%d" % n, "%d" % ms, "1" if tracking.face_present else "0"]
		for p in RECORD_PARAMS:
			row.append("%.4f" % float(tracking.parameters.get(p, 0.0)))
		var mover = stage.active_model.get("mover") if stage and stage.active_model else null
		row.append_array(["%.2f" % mover.position.x, "%.2f" % mover.position.y, "%.4f" % mover.scale.x] if mover else ["0", "0", "1"])
		csv.store_line(",".join(row))
	print("[automation] recorded %d frames in %.1f s to %s" % [n, (Time.get_ticks_msec() - start) / 1000.0, dir])

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
