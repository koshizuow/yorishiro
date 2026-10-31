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
##   --expressions-all      after the screenshot, turn each of the model's expressions on alone (with or without a
##                          hotkey) and save <name>_expr_<expression>.png
##   --dump-meshes=<a,b>    after each pose or hotkey shot, print these art meshes as Godot draws them
##   --dump-above=<a,b>     ... and the visible meshes drawn on top of them
##   --unmask=<a,b>, --raise=<a,b>  before each hotkey shot, draw these meshes without their mask, or on top
##   --print-params=<a,b>   model parameters printed after each pose (default: angles, eyes, mouth open)
##   --fixed-clock          blink, breathing and smoothing count frames instead of wall time, random seed 1.
##                          With Godot's --fixed-fps 60 the same run gives the same screenshots
##   --pipe-frames=<file>   keep writing the rendered stage to a shared file (for example in /dev/shm), for
##                          the PipeWire test tool (libfunnel's funnel-sender example, built outside the repo)
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
##   --plugin-api-test[=<png>]  (png: a shot of the approval card) switch the plugin API on, connect as a plugin over WebSocket, get allowed on the card,
##                          authenticate and check the requests (model, hotkeys, expressions, parameters, injection)
##   --expression-editor-test[=<png>]  after --open-panel=model: make an expression in the editor (png: a shot
##                          of it), check the preview moves the model, save, edit it again, delete it
##   --mic-test=<wav>       lip sync: play the wav (tools/lip_sync_vowels.py, with its .json timeline) through
##                          the voice bus instead of the microphone, print the voice values per part and check
##                          silence, volume and the vowel that wins in each
##   --hand-test[=<prefix>] (prefix: a window shot every 2 s as <prefix>_N.png) switch hand tracking on (restarts the Yorishiro tracker with --hands), run with a
##                          recording that shows hands (YORISHIRO_RECORDING=.../hagrid-hands), check the Hand* inputs
##   --app-action-test      after --open-panel=hotkeys: add a hotkey through the list, switch it to each app action
##                          (saved position, background, change model) and check what pressing it does
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
##   --play-motion=<name>   play this motion of the loaded model (looping) before the screenshot
##   --physics=<strength>   physics strength of the loaded model (1 as simulated), or "off"
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
	# the VTube Studio iPhone protocol input, asking 127.0.0.1 (yorishiro-tracker serve --vts-iphone)
	"vts-iphone": "res://lib/tracking/camera/vts_blendshapes/vts_tracker.gd",
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
		for p in ModelLibrary._find_models(args["import-models"], [".model3.json"]):
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
		var t = load(TRACKERS[args["tracker"]]).new()
		tracking.activate_tracker(t)
		if args["tracker"] == "vts-iphone":
			t.server.client_host = "127.0.0.1"
			t.server.start()
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
			if button is BaseButton and button.toggle_mode:
				button.button_pressed = not button.button_pressed  # switches and check boxes flip like a click
			elif button is BaseButton:
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
		if args.has("physics") and placed and "physics_strength" in placed:
			if args["physics"] == "off":
				placed.physics_enabled = false
			else:
				placed.physics_strength = float(args["physics"])
			print("[automation] physics %s" % args["physics"])
		if args.has("play-motion") and placed:
			var player: AnimationPlayer = placed.model.get_node("MotionController")
			player.play(args["play-motion"])
			print("[automation] playing %s: %s" % [args["play-motion"], player.current_animation])
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
			if args.has("expressions-all"):
				await _shoot_expressions(args, viewport, path)
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
		if args.has("app-action-test"):
			await _app_action_test()
		if args.has("expression-editor-test"):
			await _expression_editor_test(str(args["expression-editor-test"]))
		if args.has("hand-test"):
			await _hand_test(str(args["hand-test"]))
		if args.has("mic-test"):
			await _mic_test(str(args["mic-test"]))
		if args.has("plugin-api-test"):
			await _plugin_api_test(str(args["plugin-api-test"]))
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
		# like closing the window: the settings and the model's .yori.json are saved first
		get_tree().root.propagate_notification(NOTIFICATION_WM_CLOSE_REQUEST)
		await get_tree().process_frame
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

func _expression_editor_test(shot: String):
	var check := func (what: String, ok: bool): print("[automation] expression editor %s: %s" % [what, "ok" if ok else "FAILED"])
	var stage = get_tree().get_first_node_in_group("system:stage")
	var model = stage.active_model
	var root := get_tree().root
	var wait := func (n: int):
		for i in n:
			await get_tree().process_frame
	var open_list := func ():
		var b = root.find_child("Expression", true, false)
		b.pressed.emit()
		await wait.call(10)
	await open_list.call()
	var add = root.find_child("NewExpressionBtn", true, false)
	check.call("new expression button", add != null)
	add.pressed.emit()
	await wait.call(10)
	var editor = root.find_child("ExpressionName", true, false)
	check.call("editor open", editor != null)
	editor = editor.get_parent().get_parent().get_parent().get_parent()
	# pick a parameter the face does not drive much: the first one with a range
	var param := ""
	for id in model.get_parameters():
		if String(id).to_lower().contains("brow") or String(id).to_lower().contains("cheek"):
			param = String(id)
			break
	if param.is_empty():
		param = String(model.get_parameters().keys()[0])
	var r: Dictionary = editor._rows[param]
	var before = model.model.get("output/parameters/%s" % param)
	r.blend.select(2)
	r.blend.item_selected.emit(2)
	r.slider.value = r.slider.max_value
	var top: float = r.slider.max_value
	await wait.call(5)
	var during = model.model.get("output/parameters/%s" % param)
	check.call("preview moves %s (%.2f -> %.2f, max %.2f)" % [param, before, during, r.slider.max_value], absf(during - r.slider.max_value) < 0.01)
	if shot.ends_with(".png"):
		get_viewport().get_texture().get_image().save_png(shot)
	editor._name.text = "yori_test"
	root.find_child("SaveExpressionBtn", true, false).pressed.emit()
	await wait.call(15)
	var file: String = model.user_expression_dir().path_join("yori_test.exp3.json")
	check.call("saved to the settings folder, model folder untouched", FileAccess.file_exists(file) and not FileAccess.file_exists(model.modelmeta.model.get_base_dir().path_join("yori_test.exp3.json")))
	var names: Array = model.get_expression_controller().expressions.map(func (e): return e.get_name())
	check.call("in the model's expressions, preview gone", "yori_test" in names and not ("__yorishiro_preview__" in names))
	await wait.call(5)
	var after = model.model.get("output/parameters/%s" % param)
	check.call("model back after closing (%.2f)" % after, absf(after - during) > 0.01 or absf(before - during) < 0.01)
	check.call("list came back", root.find_child("NewExpressionBtn", true, false) != null)
	var edit_btn = root.find_child("Edit_yori_test", true, false)
	check.call("edit button for it", edit_btn != null)
	edit_btn.pressed.emit()
	await wait.call(10)
	editor = root.find_child("ExpressionName", true, false).get_parent().get_parent().get_parent().get_parent()
	check.call("editing keeps the value", editor._rows[param].use.button_pressed and absf(editor._rows[param].slider.value - top) < 0.01)
	var delete = root.find_child("DeleteExpressionBtn", true, false)
	check.call("delete offered for own expression", delete != null)
	delete.pressed.emit()
	await wait.call(15)
	names = model.get_expression_controller().expressions.map(func (e): return e.get_name())
	check.call("deleted", not FileAccess.file_exists(file) and not ("yori_test" in names))

func _hand_test(shots: String):
	var check := func (what: String, ok: bool): print("[automation] hands %s: %s" % [what, "ok" if ok else "FAILED"])
	var tracking = get_tree().get_first_node_in_group("system:tracking")
	var face = tracking.get_node("FaceTracker")
	check.call("Yorishiro tracker", "track_hands" in face)
	face.track_hands = true
	face.restart()
	var seen := {"HandLeftFound": 0, "HandRightFound": 0}
	var open_hi := 0.0
	var open_lo := 1.0
	var frames := 0
	var t0 := Time.get_ticks_msec()
	var next_shot := 6000
	while Time.get_ticks_msec() - t0 < 20000:
		await get_tree().process_frame
		if shots and shots != "true" and Time.get_ticks_msec() - t0 >= next_shot:
			get_viewport().get_texture().get_image().save_png("%s_%d.png" % [shots, next_shot / 1000])
			# and a close-up: the preview's camera right in front of a shown hand
			var preview = get_tree().root.find_child("PreviewHandLeft", true, false)
			var hand = preview if preview and preview.visible else get_tree().root.find_child("PreviewHandRight", true, false)
			if hand and hand.visible:
				var cam: Camera3D = hand.get_viewport().get_camera_3d()
				var keep := cam.position
				cam.set_meta("hold", true)
				cam.position = hand.global_position + Vector3(0, 0, 0.22)
				await RenderingServer.frame_post_draw
				await RenderingServer.frame_post_draw
				hand.get_viewport().get_texture().get_image().save_png("%s_%d_close.png" % [shots, next_shot / 1000])
				cam.position = keep
				cam.remove_meta("hold")
			next_shot += 2000
		var p: Dictionary = tracking.parameters
		for k in seen:
			if p.get(k, 0.0) > 0.5:
				seen[k] += 1
		if p.get("HandLeftFound", 0.0) > 0.5:
			frames += 1
			open_hi = maxf(open_hi, p.get("HandLeftOpen", 0.0))
			open_lo = minf(open_lo, p.get("HandLeftOpen", 1.0))
	print("[automation] hands status %s" % JSON.stringify(face.status))
	check.call("left hand seen (%d frames)" % seen.HandLeftFound, seen.HandLeftFound > 30)
	check.call("right hand seen (%d frames)" % seen.HandRightFound, seen.HandRightFound > 10)
	check.call("open and closed hand apart (Open %.2f to %.2f)" % [open_lo, open_hi], open_hi > 0.6 and open_lo < 0.35)
	face.track_hands = false
	face.save_settings()

func _mic_test(wav: String):
	var check := func (what: String, ok: bool): print("[automation] lip sync %s: %s" % [what, "ok" if ok else "FAILED"])
	var tracking = get_tree().get_first_node_in_group("system:tracking")
	var mic = tracking.get_node("MicrophoneTracker")
	var timeline: Array = JSON.parse_string(FileAccess.get_file_as_string(wav.get_basename() + ".json"))
	mic.use_file(wav)
	var keys := ["VoiceVolume", "VoiceFrequency", "VoiceA", "VoiceI", "VoiceU", "VoiceE", "VoiceO", "VoiceSilence"]
	var sums := {}
	var counts := {}
	var end: float = timeline[-1].end
	while mic.mic.playing:
		await get_tree().process_frame
		var t: float = mic.mic.get_playback_position()
		if t >= end - 0.05:
			break
		for part in timeline:
			# the middle of each part, away from fades and smoothing
			if t > part.start + 0.3 and t < part.end - 0.15:
				var k: String = part.part
				counts[k] = counts.get(k, 0) + 1
				var acc: Dictionary = sums.get_or_add(k, {})
				for p in keys:
					acc[p] = acc.get(p, 0.0) + float(tracking.parameters.get(p, 0.0))
				acc["F1"] = acc.get("F1", 0.0) + mic.formants.x
				acc["F2"] = acc.get("F2", 0.0) + mic.formants.y
	var vowels := ["a", "i", "u", "e", "o"]
	var right := 0
	for k in counts:
		var mean := {}
		for p in keys:
			mean[p] = sums[k][p] / counts[k]
		var line := ", ".join(keys.map(func (p): return "%s %.2f" % [p.trim_prefix("Voice"), mean[p]]))
		print("[automation] lip sync part %s (%d frames, formants %.0f / %.0f Hz): %s" % [k, counts[k], sums[k].F1 / counts[k], sums[k].F2 / counts[k], line])
		if k == "silence":
			check.call("silence closes the mouth (volume %.2f)" % mean.VoiceVolume, mean.VoiceVolume < 0.05)
		else:
			var best: String = vowels.reduce(func (a, b): return a if mean["Voice" + a.to_upper()] >= mean["Voice" + b.to_upper()] else b)
			check.call("%s opens the mouth (volume %.2f)" % [k, mean.VoiceVolume], mean.VoiceVolume > 0.5)
			print("[automation] lip sync vowel %s heard as %s" % [k, best])
			if best == k:
				right += 1
	check.call("vowels recognized %d of 5" % right, right >= 4)

func _plugin_api_test(card_shot: String):
	var check := func (what: String, ok: bool): print("[automation] plugin api %s: %s" % [what, "ok" if ok else "FAILED"])
	PluginApi.enabled = true
	check.call("listening", PluginApi.is_listening())
	var ws := WebSocketPeer.new()
	ws.connect_to_url("ws://127.0.0.1:%d" % PluginApi.PORT)
	for i in 120:
		await get_tree().process_frame
		ws.poll()
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			break
	check.call("connected", ws.get_ready_state() == WebSocketPeer.STATE_OPEN)
	var n := [0]
	var events: Array = []  # everything that is not an answer
	var ask := func (type: String, data := {}, press := "") -> Dictionary:
		n[0] += 1
		var id := "t%d" % n[0]
		ws.send_text(JSON.stringify({"apiName": "VTubeStudioPublicAPI", "apiVersion": "1.0", "requestID": id,
			"messageType": type + "Request", "data": data}))
		for i in 600:
			await get_tree().process_frame
			ws.poll()
			if press and i == 20:
				var b = get_tree().root.find_child(press, true, false)
				if b and b.is_visible_in_tree():
					if card_shot.ends_with(".png") and press == "PluginAllowBtn":
						get_viewport().get_texture().get_image().save_png(card_shot)
					b.pressed.emit()
			while ws.get_available_packet_count() > 0:
				var msg = JSON.parse_string(ws.get_packet().get_string_from_utf8())
				if msg is Dictionary and msg.get("requestID") == id:
					return msg
				if msg is Dictionary and str(msg.get("messageType", "")).ends_with("Event"):
					events.append(msg)
		return {}
	var plugin := {"pluginName": "Test Plugin", "pluginDeveloper": "Yorishiro tests"}
	var r: Dictionary = await ask.call("APIState")
	check.call("state, not authenticated yet", r.get("data", {}).get("currentSessionAuthenticated") == false)
	r = await ask.call("CurrentModel")
	check.call("needs authentication (error %s)" % r.get("data", {}).get("errorID"), r.get("messageType") == "APIError")
	r = await ask.call("AuthenticationToken", plugin, "PluginDenyBtn")
	check.call("denied on the card", r.get("messageType") == "APIError" and r.data.errorID == PluginApi.ERR_TOKEN_DENIED)
	r = await ask.call("AuthenticationToken", plugin, "PluginAllowBtn")
	var token: String = r.get("data", {}).get("authenticationToken", "")
	check.call("allowed on the card", token.length() == 64)
	r = await ask.call("Authentication", plugin.merged({"authenticationToken": "wrong"}))
	check.call("wrong token refused", r.get("data", {}).get("authenticated") == false)
	r = await ask.call("Authentication", plugin.merged({"authenticationToken": token}))
	check.call("authenticated", r.get("data", {}).get("authenticated") == true)
	r = await ask.call("CurrentModel")
	var model_id: String = r.get("data", {}).get("modelID", "")
	check.call("current model %s, %d parameters" % [r.data.get("modelName"), r.data.get("numberOfLive2DParameters", 0)], r.data.get("modelLoaded") == true and model_id != "")
	r = await ask.call("AvailableModels")
	check.call("available models (%d)" % r.get("data", {}).get("numberOfModels", 0), r.data.get("numberOfModels", 0) > 0 and r.data.get("availableModels", []).all(func (m): return m.modelLoaded == (m.modelID == model_id)))
	var stage = get_tree().get_first_node_in_group("system:stage")
	var model = stage.active_model
	r = await ask.call("MoveModel", {"timeInSeconds": 0, "valuesAreRelativeToModel": false, "positionX": 0.5, "positionY": 0.0, "rotation": 10, "size": 0})
	var view: Vector2 = model.get_viewport().get_visible_rect().size
	check.call("move model (x %.0f, want %.0f, rotation %.0f)" % [model.position.x, view.x * 0.75, model.rotation_degrees], absf(model.position.x - view.x * 0.75) < 1 and absf(model.rotation_degrees - 10) < 0.1)
	r = await ask.call("CurrentModel")
	check.call("position read back (%.2f)" % r.data.modelPosition.positionX, absf(r.data.modelPosition.positionX - 0.5) < 0.01)
	r = await ask.call("Live2DParameterList")
	check.call("live2d parameters (%d)" % r.get("data", {}).get("parameters", []).size(), r.data.get("parameters", []).size() > 10)
	r = await ask.call("InputParameterList")
	check.call("input parameters (%d default)" % r.get("data", {}).get("defaultParameters", []).size(), r.data.get("defaultParameters", []).any(func (p): return p.name == "FaceAngleX"))
	r = await ask.call("ParameterCreation", {"parameterName": "TestWave", "explanation": "test", "min": -1, "max": 1, "defaultValue": 0})
	check.call("custom parameter created", r.get("data", {}).get("parameterName") == "TestWave")
	r = await ask.call("ParameterCreation", {"parameterName": "FaceAngleX", "min": -1, "max": 1, "defaultValue": 0})
	check.call("built-in parameter not taken over", r.get("messageType") == "APIError")
	r = await ask.call("InjectParameterData", {"mode": "set", "parameterValues": [{"id": "TestWave", "value": 0.7}, {"id": "FaceAngleX", "value": 25.0}]})
	var tracking = get_tree().get_first_node_in_group("system:tracking")
	for i in 3:
		await get_tree().process_frame
	check.call("injected (TestWave %.2f, FaceAngleX %.1f)" % [tracking.parameters.get("TestWave", -9), tracking.parameters.get("FaceAngleX", -99)], absf(tracking.parameters.get("TestWave", 0) - 0.7) < 0.001 and absf(tracking.parameters.get("FaceAngleX", 0) - 25.0) < 0.001)
	r = await ask.call("ParameterValue", {"name": "TestWave"})
	check.call("parameter value read back (%.2f)" % float(r.get("data", {}).get("value", -9)), absf(float(r.data.get("value", 0)) - 0.7) < 0.001)
	r = await ask.call("InjectParameterData", {"parameterValues": [{"id": "NoSuchParam", "value": 1}]})
	check.call("unknown parameter refused", r.get("messageType") == "APIError")
	for i in 80:  # injected values let go after a second
		await get_tree().process_frame
	await get_tree().create_timer(1.1).timeout
	check.call("injection released (FaceAngleX %.1f)" % tracking.parameters.get("FaceAngleX", 0), absf(tracking.parameters.get("FaceAngleX", 25.0) - 25.0) > 0.001)
	r = await ask.call("ParameterDeletion", {"parameterName": "TestWave"})
	check.call("custom parameter deleted", r.get("messageType") == "ParameterDeletionResponse" and Registry.get("TestWave") == null)
	r = await ask.call("ExpressionState", {"details": false})
	var expressions: Array = r.get("data", {}).get("expressions", [])
	check.call("expressions (%d)" % expressions.size(), r.get("messageType") == "ExpressionStateResponse")
	if expressions:
		var e: String = expressions[0].file
		r = await ask.call("ExpressionActivation", {"expressionFile": e, "active": true, "fadeTime": 0.0})
		for i in 5:
			await get_tree().process_frame
		r = await ask.call("ExpressionState", {"details": false, "expressionFile": e})
		check.call("expression %s on" % e, r.get("data", {}).get("expressions", [{}])[0].get("active") == true)
		await ask.call("ExpressionActivation", {"expressionFile": e, "active": false, "fadeTime": 0.0})
	# items: a picture of our own in the item library, loaded at the left, listed, then unloaded
	DirAccess.make_dir_recursive_absolute("user://Items")
	var pic := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	pic.fill(Color(0.9, 0.5, 0.6))
	pic.save_png("user://Items/yori_test_item.png")
	r = await ask.call("ItemList", {"includeAvailableItemFiles": true})
	check.call("item files listed", r.get("data", {}).get("availableItemFiles", []).any(func (f): return f.fileName == "yori_test_item.png"))
	r = await ask.call("ItemLoad", {"fileName": "yori_test_item.png", "positionX": -0.5, "positionY": 0.0, "size": 0.2, "rotation": 0, "fadeTime": 0})
	var instance: String = r.get("data", {}).get("instanceID", "")
	check.call("item loaded (%s)" % instance, r.get("messageType") == "ItemLoadResponse" and instance != "")
	var placed = stage.canvas.get_children().filter(func (i): return "uid" in i and str(i.uid) == instance)
	if placed:
		var c: Vector2 = placed[0].global_position + placed[0].scale * placed[0].center
		check.call("item placed at the left (%.0f, want %.0f; height %.0f, want %.0f)" % [c.x, view.x * 0.25, placed[0].size.y * placed[0].scale.y, view.y * 0.2], absf(c.x - view.x * 0.25) < 2 and absf(placed[0].size.y * placed[0].scale.y - view.y * 0.2) < 2)
	r = await ask.call("ItemList", {"includeItemInstancesInScene": true})
	check.call("item in the scene list", r.get("data", {}).get("itemInstancesInScene", []).any(func (i): return i.instanceID == instance))
	r = await ask.call("ItemLoad", {"fileName": "no_such_item.png"})
	check.call("unknown item refused", r.get("messageType") == "APIError")
	r = await ask.call("ItemUnload", {"instanceIDs": [instance]})
	check.call("item unloaded", r.get("data", {}).get("unloadedItems", []).size() == 1)
	DirAccess.remove_absolute("user://Items/yori_test_item.png")
	r = await ask.call("EventSubscription", {"eventName": "ModelMovedEvent", "subscribe": true})
	check.call("subscribed", r.get("data", {}).get("subscribedEvents", []) == ["ModelMovedEvent"])
	await ask.call("EventSubscription", {"eventName": "HotkeyTriggeredEvent", "subscribe": true})
	r = await ask.call("EventSubscription", {"eventName": "TestEvent", "subscribe": true, "config": {"testMessageForEvent": "hi"}})
	check.call("three events", r.get("data", {}).get("subscribedEventCount") == 3)
	r = await ask.call("EventSubscription", {"eventName": "NoSuchEvent", "subscribe": true})
	check.call("unknown event refused", r.get("messageType") == "APIError")
	model.position.x -= 100
	for i in 90:
		await ask.call("APIState")  # keeps reading while events arrive
	var moved := events.filter(func (e): return e.messageType == "ModelMovedEvent")
	check.call("model moved event (%d)" % moved.size(), moved.size() >= 1)
	var tests := events.filter(func (e): return e.messageType == "TestEvent")
	check.call("test event (%d, says %s)" % [tests.size(), tests[0].data.yourTestMessage if tests else "-"], tests.size() >= 1 and tests[0].data.yourTestMessage == "hi")
	r = await ask.call("HotkeysInCurrentModel")
	var keys: Array = r.get("data", {}).get("availableHotkeys", [])
	check.call("hotkeys (%d)" % keys.size(), r.get("messageType") == "HotkeysInCurrentModelResponse")
	if keys:
		r = await ask.call("HotkeyTrigger", {"hotkeyID": keys[0].hotkeyID})
		check.call("hotkey %s (%s) triggered" % [keys[0].name, keys[0].type], r.get("data", {}).get("hotkeyID") == keys[0].hotkeyID)
		for i in 5:
			await ask.call("APIState")
		var fired := events.filter(func (e): return e.messageType == "HotkeyTriggeredEvent")
		check.call("hotkey event, by API", fired.size() >= 1 and fired[-1].data.hotkeyTriggeredByAPI == true)
	r = await ask.call("EventSubscription", {"eventName": "", "subscribe": false})
	check.call("unsubscribed from all", r.get("data", {}).get("subscribedEventCount") == 0)
	r = await ask.call("FaceFound")
	check.call("face found answered (%s)" % r.get("data", {}).get("found"), r.get("messageType") == "FaceFoundResponse")
	r = await ask.call("NoSuchThing")
	check.call("unknown request refused", r.get("messageType") == "APIError" and r.data.errorID == PluginApi.ERR_TYPE_UNKNOWN)
	check.call("plugin listed in settings", PluginApi.allowed_plugins().any(func (p): return p.name == "Test Plugin"))
	ws.close()

func _app_action_test():
	var list = get_tree().root.find_child("HotkeyList", true, false)
	var stage = get_tree().get_first_node_in_group("system:stage")
	var check := func (what: String, ok: bool): print("[automation] app action %s: %s" % [what, "ok" if ok else "FAILED"])
	var model = stage.active_model
	list.refresh()
	list.get_node("AddHotkeyBtn").pressed.emit()
	for i in 3:
		await get_tree().process_frame
	var e: Dictionary = list.entries()[-1]
	# saved position: remember here, move away, press, it comes back
	await list._set_action(e, &"app_action", "position:2")
	list.refresh()
	await get_tree().process_frame
	e = list.entries()[-1]
	var save = list._rows.get_child(list._rows.get_child_count() - 1).find_child("SavePosition", true, false)
	check.call("save button shown", save != null)
	var home: Vector2 = model.position
	save.pressed.emit()
	model.position = home + Vector2(300, -120)
	e.target.invoke_trigger(1)
	for i in 40:
		await get_tree().process_frame
	check.call("moved back to the saved position (%s, saved %s)" % [model.position, home], model.position.distance_to(home) < 1.0)
	await list._set_action(e, &"app_action", "background:3")
	e.target.invoke_trigger(1)
	await get_tree().process_frame
	check.call("background transparent", stage.background_mode == 3)
	await list._set_action(e, &"app_action", "background:0")
	e.target.invoke_trigger(1)
	var here := ProjectSettings.globalize_path(model.modelmeta.model)
	var other = ModelLibrary.list().filter(func (m): return ProjectSettings.globalize_path(m.path) != here)
	if other:
		await list._set_action(e, &"app_action", "model:%s" % other[0].path)
		var data = e.target.serialize()
		check.call("saved as %s" % data, data.action == "model" and data.target == other[0].path)
		e.target.invoke_trigger(1)
		var want := ProjectSettings.globalize_path(other[0].path)
		for i in 300:
			await get_tree().process_frame
			if stage.active_model and ProjectSettings.globalize_path(stage.active_model.modelmeta.model) == want:
				break
		check.call("changed model to %s" % other[0].name, ProjectSettings.globalize_path(stage.active_model.modelmeta.model) == want)

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

## every expression of the model, one at a time, whether a hotkey uses it or not
func _shoot_expressions(args: Dictionary, viewport: Viewport, path: String):
	var model = get_tree().get_first_node_in_group("system:stage").active_model
	var controller = model.get_expression_controller()
	var frames := int(args.get("pose-frames", "90"))
	for e in controller.expressions:
		var expr_name: String = e.get_name()
		controller.set("weight/%s" % expr_name, 1.0)
		for i in frames:
			await RenderingServer.frame_post_draw
		var shot = "%s_expr_%s.png" % [path.get_basename(), expr_name.validate_filename()]
		var err = viewport.get_texture().get_image().save_png(shot)
		print("[automation] expression %s -> %s" % [shot, error_string(err)])
		controller.set("weight/%s" % expr_name, 0.0)
		for i in frames:
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
