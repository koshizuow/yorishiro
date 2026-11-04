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
##   --dump-meshes=<a,b>    after each pose or hotkey shot, print these art meshes' vertex box and visibility
##   --model-params=<json>  after the screenshot, set each named group of model parameters ({"name": {"ParamX": 1}}),
##                          save <name>_<group>.png after --pose-frames (default 90) frames, then set them back
##   --print-params=<a,b>   model parameters printed after each pose (default: angles, eyes, mouth open)
##   --fixed-clock          blink, breathing and smoothing count frames instead of wall time, random seed 1.
##                          With Godot's --fixed-fps 60 the same run gives the same screenshots
##   --press=<a,b>          after --open-panel, press these buttons (node names) in order, for screenshots of what they open
##   --link-eyes            both eyes follow the more closed one
##   --preview-glasses      the preview head wears its glasses
##   --face-preview[=<px>]  show the 3D tracking preview head in the window corner, next to the stage (with
##                          --poses and only --screenshot-window: one shot per pose with both)
##   --show=<name>          after --open-panel and --press, scroll the page so this node (name) is in view
##   --import-models=<dir>  add every model under dir to the model library, as the import card would
##   --cycle-models=<prefix> after the screenshot, open each library model in turn like a click on its card, save
##                          <prefix>_<nn>_<name>.png (window) after --pose-frames frames and print load time
##   --gestures=<prefix>    after the screenshot, operate the model with synthetic mouse and key events (drag,
##                          wheel, wheel while dragging, shift+wheel, touchpad scroll and pinch, right drag), save <prefix>_<step>.png and print
##                          the model transform after each step
##   --plugin-api-test[=<png>]  (png: a shot of the approval card) switch the plugin API on, connect as a plugin over WebSocket, get allowed on the card,
##                          authenticate and check the requests (model, hotkeys, expressions, parameters, injection)
##   --expression-editor-test[=<png>]  after --open-panel=model: make an expression in the editor (png: a shot
##                          of it), check the preview moves the model, save, edit it again, delete it
##   --mic-test=<wav>       lip sync: play the wav (tools/lip_sync_vowels.py, with its .json timeline) through
##                          the voice bus instead of the microphone, print the voice values per part and check
##                          silence, volume and the vowel that wins in each
##   --hand-test[=<prefix>] (prefix: a window shot every 2 s as <prefix>_N.png) switch hand tracking on (restarts
##                          the tracker), run with a recording that shows hands (YORISHIRO_RECORDING=.../hagrid-hands),
##                          check the Hand* inputs
##   --pin-test             add an item over the model, pin it to the art mesh under it (as dropping it does), move
##                          the model and check the item follows the mesh (vertices read back from the GPU)
##   --blink-test=<s>      the lowest value each eye's open parameter reaches in that time, and how many frames they differ
##   --background=<RRGGBB or image path> set the stage background before the outputs start
##   --virtual-camera=<dev> send the stage to this v4l2loopback device, for --hold=<s> seconds before going on
##   --pipewire-test[=<s>]  send the stage to PipeWire, resize the window twice (s seconds per size, default 2, longer
##                          to watch it in OBS) and check the output keeps running
##   --core-test=<camera>   switch the tracker from the replayed recording to that camera (the development loopback
##                          camera is 10), check it runs and moves the model, with the outputs to other apps on;
##                          --core-runtime=<auto|vulkan|vulkan-fp32|ncnn-cpu|ort-cpu> picks the runtime (vulkan)
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
##   --motion-switch=<a,b>  play these motions in turn, print how the pose groups cross over at each switch
##   --physics=<strength>   physics strength of the loaded model (1 as simulated), or "off"
##   --follow-face=<x,y,z>  move the loaded model with the face, these amounts (VTS units), or "off"
##   --record=<dir>         after the screenshot, save the window as <dir>/00001.jpg ... at 30 fps for
##                          --record-seconds (default 10), and the tracked values per frame in <dir>/params.csv
##   --perf-report=<seconds> after the screenshot, the main thread's and the whole app's CPU per frame (from /proc),
##                          measured that long as is, then with the models not processed, the interface hidden,
##                          the stage not rendered, each autoload and tracking input stopped, to see which part
##                          costs what, and each script's nodes with _process off; --perf-rounds=<n> repeats them in turn and prints medians,
##                          --perf-only=<a,b> keeps only the phases whose names contain one of these
##   --gpu-check            after the screenshot, compare the model's GPU-deformed vertices with the CPU path
##   --render-stats=<s>     after the screenshot, measure that long: GPU and CPU render time summed over every viewport
##                          (the stage, each mask viewport), draw calls and objects per frame, the number of viewports
##   --send-outputs         turn on the Yorishiro tracker's outputs to other apps (VTS iPhone, iFacialMocap to 127.0.0.1)
##   --phone-host=<ip>      with --tracker=vts-iphone: ask a real phone running VTube Studio there instead of 127.0.0.1
##   --trace=<seconds>     print the tracked head, eye and mouth inputs every 0.1 s with the wall clock in ms, for
##                          comparing two copies (one sending, one receiving: --instance=2 --tracker=ifacialmocap)
##   --quit                 exit after the screenshot
extends Node

const CameraTracker = preload("res://lib/tracking/camera/camera_tracker.gd")
const Clock = preload("res://lib/utils/clock.gd")

var _pose_tracker
const TRACKERS = {
	"yorishiro": "res://lib/tracking/camera/yorishiro/yorishiro_tracker.gd",
	"openseeface": "res://lib/tracking/camera/openseeface/osf_tracker.gd",
	# the VTube Studio iPhone protocol input, asking 127.0.0.1 (the tracker's VTS iPhone output)
	"vts-iphone": "res://lib/tracking/camera/vts_blendshapes/vts_tracker.gd",
	# the iFacialMocap input, asking 127.0.0.1:<--ifm-phone-port> (tools/fake_ifacialmocap.py plays the phone there:
	# the real phone's port 49983 is the one this computer listens on)
	"ifacialmocap": "res://lib/tracking/camera/ifacialmocap/ifm_tracker.gd",
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

	if args.has("send-outputs"):
		for i in 10:
			await get_tree().process_frame
		var face = get_tree().get_first_node_in_group("system:tracking").get_node("FaceTracker")
		face.send_vts_iphone = true
		face.send_ifacialmocap = true
		face.restart()
		print("[automation] outputs on")
	if args.has("trace"):
		# not awaited: runs beside the rest of the sequence
		_trace(float(args["trace"]))
	if args.has("tracker"):
		# the settings panel restores the saved tracker a frame after startup, go after it
		for i in 10:
			await get_tree().process_frame
		var tracking = get_tree().get_first_node_in_group("system:tracking")
		var t = load(TRACKERS[args["tracker"]]).new()
		tracking.activate_tracker(t)
		if args["tracker"] == "vts-iphone":
			t.server.client_host = args.get("phone-host", "127.0.0.1")
			t.server.start()
		if args["tracker"] == "ifacialmocap":
			t.server.client_host = "127.0.0.1"
			t.server.client_port = int(args.get("ifm-phone-port", "49984"))
			t.server.start()
			# what came in, for the test to compare with what the fake phone sent
			get_tree().create_timer(3.0).timeout.connect(func ():
				var shown := []
				for k in ["JawOpen", "EyeBlinkLeft", "MouthSmileRight", "MouthOpen", "EyeOpenRight", "FaceAngleX", "FaceAngleY", "FaceAngleZ"]:
					shown.append("%s=%.2f" % [k, t.last_parameters.get(k, -1.0)])
				print("[automation] ifacialmocap %s head=%s" % [" ".join(shown), t.tracker.get_joint_transform(XRBodyTracker.JOINT_HEAD).basis.get_euler() * 180.0 / PI]))
		print("[automation] tracker %s" % args["tracker"])

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
		if args.has("preview-glasses"):
			var system = get_tree().get_first_node_in_group("system:tracking")
			if system and system.get_node_or_null("FaceTracker"):
				system.get_node("FaceTracker").glasses = 1
		if args.has("face-preview"):
			var layer := CanvasLayer.new()
			layer.layer = 50
			var head := FacePreview.new()
			var side := int(args["face-preview"]) if str(args["face-preview"]).is_valid_int() else 300
			head.custom_minimum_size = Vector2(side, side)
			head.position = Vector2(16, 16) if side == 300 else Vector2(0, (720 - side) / 2)
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
		if args.has("motion-switch") and placed:
			await _motion_switch(placed, str(args["motion-switch"]).split(","))
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
			if args.has("model-params"):
				await _shoot_model_params(args, viewport, path)
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
		if args.has("core-test"):
			await _core_test(int(args["core-test"]), str(args.get("core-runtime", "vulkan")))
		if args.has("hand-test"):
			await _hand_test(str(args["hand-test"]))
		if args.has("pin-test"):
			await _pin_test()
		if args.has("link-eyes"):
			for graph in get_tree().get_first_node_in_group("system:stage").active_model.blueprints:
				for node in graph.get_children():
					if node.has_method("get_type") and node.get_type() == &"tracking_input":
						node.link_eyes = true
						print("[automation] link eyes on %s" % node.name)
		if args.has("blink-test"):
			await _blink_test(float(args["blink-test"]))
		if args.has("background"):
			_set_background(str(args["background"]))
		if args.has("virtual-camera"):
			get_tree().get_first_node_in_group("output:v4l2").set("loopback_device", str(args["virtual-camera"]))
			await get_tree().create_timer(float(args.get("hold", 0))).timeout
		if args.has("pipewire-test"):
			await _pipewire_test(float(args["pipewire-test"]) if str(args["pipewire-test"]).is_valid_float() else 2.0)
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
		if args.has("gpu-check"):
			var km = get_tree().get_first_node_in_group("system:stage").active_model.model
			print("[automation] gpu check: %s" % km.gpu_check())
		if args.has("render-stats"):
			await _render_stats(float(args["render-stats"]))
		if args.has("perf-report"):
			await _perf_report(float(args["perf-report"]), int(args.get("perf-rounds", "1")), str(args.get("perf-only", "")))
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

## GPU and CPU render time of every viewport (stage, mask viewports, window) and the draw calls, medians per frame
func _render_stats(seconds: float):
	var rs := RenderingServer
	var viewports: Array[RID] = [get_viewport().get_viewport_rid()]
	for vp in get_tree().root.find_children("*", "SubViewport", true, false):
		viewports.append(vp.get_viewport_rid())
	for vp in viewports:
		rs.viewport_set_measure_render_time(vp, true)
	var gpu: Array[float] = []
	var cpu: Array[float] = []
	var calls: Array[float] = []
	var objects: Array[float] = []
	var t0 := Time.get_ticks_msec()
	await get_tree().process_frame
	await get_tree().process_frame
	while Time.get_ticks_msec() - t0 < seconds * 1000:
		await RenderingServer.frame_post_draw
		var g := 0.0
		var c := 0.0
		for vp in viewports:
			g += rs.viewport_get_measured_render_time_gpu(vp)
			c += rs.viewport_get_measured_render_time_cpu(vp)
		gpu.append(g)
		cpu.append(c)
		calls.append(rs.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
		objects.append(rs.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME))
	var med := func (a: Array[float]) -> float:
		var b := a.duplicate()
		b.sort()
		return b[b.size() / 2] if b.size() else 0.0
	print("[automation] render stats: %d viewports, GPU %.2f ms, render CPU %.2f ms, %d draw calls, %d objects per frame (medians of %d frames), %.0f fps" % [
		viewports.size(), med.call(gpu), med.call(cpu), med.call(calls), med.call(objects), gpu.size(), Engine.get_frames_per_second()])

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
		["touchpad_scroll_up_100px_at_head", [["pan", Vector2(0, -10), 10]], Vector2(0.5, 0.12)],
		["touchpad_scroll_down_100px_at_head", [["pan", Vector2(0, 10), 10]], Vector2(0.5, 0.12)],
		["touchpad_pinch_out_x1.5", [["magnify", 1.0414, 10]]],
		["touchpad_pinch_in_back", [["magnify", 1.0 / 1.0414, 10]]],
		["drag_left_1500_offscreen", [["press", MOUSE_BUTTON_LEFT], ["move", Vector2(-1500, 0)], ["release", MOUSE_BUTTON_LEFT]]],
		["drag_back_right_300", [["press", MOUSE_BUTTON_LEFT], ["move", Vector2(300, 0)], ["release", MOUSE_BUTTON_LEFT]], Vector2(0.8, 0.5)],
		["drag_down_1000_offscreen", [["press", MOUSE_BUTTON_LEFT], ["move", Vector2(0, 1000)], ["release", MOUSE_BUTTON_LEFT]]],
		["drag_up_700_back", [["press", MOUSE_BUTTON_LEFT], ["move", Vector2(0, -700)], ["release", MOUSE_BUTTON_LEFT]], Vector2(0.5, 0.03)],
		# zoomed in on the head: the center of the box goes far out of the view, a small drag must move just that much
		["wheel_up_x24_at_head", [["wheel", MOUSE_BUTTON_WHEEL_UP, 24]], Vector2(0.5, 0.1)],
		["drag_right_40_zoomed", [["press", MOUSE_BUTTON_LEFT], ["move", Vector2(40, 0)], ["release", MOUSE_BUTTON_LEFT]], Vector2(0.5, 0.1)],
		["drag_down_120_zoomed", [["press", MOUSE_BUTTON_LEFT], ["move", Vector2(0, 120)], ["release", MOUSE_BUTTON_LEFT]], Vector2(0.5, 0.1)],
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
				"pan", "magnify":
					for i in op[2]:
						var g: InputEventGesture
						if op[0] == "pan":
							g = InputEventPanGesture.new()
							g.delta = op[1]
						else:
							g = InputEventMagnifyGesture.new()
							g.factor = op[1]
						g.position = at
						Input.parse_input_event(g)
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

func _trace(seconds: float):
	var tracking = get_tree().get_first_node_in_group("system:tracking")
	var end_ms := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < end_ms:
		var p: Dictionary = tracking.parameters
		var line := "[trace] %d" % int(Time.get_unix_time_from_system() * 1000)
		for k in ["FaceAngleX", "FaceAngleY", "FaceAngleZ", "EyeOpenLeft", "EyeOpenRight", "MouthOpen", "MouthSmile", "EyeLeftX", "EyeLeftY", "Brows"]:
			line += " %s=%.3f" % [k, float(p.get(k, 0.0))]
		print(line)
		await get_tree().create_timer(0.1).timeout

func _core_test(cam: int, runtime: String):
	var check := func (what: String, ok: bool): print("[automation] core %s: %s" % [what, "ok" if ok else "FAILED"])
	var tracking = get_tree().get_first_node_in_group("system:tracking")
	var face = tracking.get_node("FaceTracker")
	check.call("extension loaded", face.core_available())
	if not face.core_available():
		return
	face.stop()
	var keep_replay: String = face.replay
	face.replay = ""
	face.camera = cam
	face.runtime = runtime
	# the outputs to other apps too, a receiver may listen (tools: a VTS iPhone request, iFacialMocap on 49983)
	face.send_vts_iphone = true
	face.send_ifacialmocap = true
	face.restart()
	# models load first, the 15 s count from the first face
	var t0 := Time.get_ticks_msec()
	while not face.found and Time.get_ticks_msec() - t0 < 90000:
		await get_tree().process_frame
	t0 = Time.get_ticks_msec()
	var values: Array[float] = []
	var found_frames := 0
	while Time.get_ticks_msec() - t0 < 15000:
		await get_tree().process_frame
		if face.found:
			found_frames += 1
			values.append(float(tracking.parameters.get("FaceAngleX", 0.0)))
	var spread := 0.0
	if values.size() > 1:
		spread = values.max() - values.min()
	print("[automation] core status %s" % JSON.stringify(face.status))
	check.call("running (%s)" % face.status.get("state"), face.status.get("state") == "running")
	check.call("faces in %d frames" % found_frames, found_frames > 100)
	check.call("the head moves the model (FaceAngleX spread %.1f)" % spread, spread > 1.0)
	check.call("camera named in the status", str(face.status.get("source", "")) == "camera %d" % cam)
	face.replay = keep_replay
	face.send_vts_iphone = false
	face.send_ifacialmocap = false
	face.save_settings()

func _pin_test():
	var check := func (what: String, ok: bool): print("[automation] pin %s: %s" % [what, "ok" if ok else "FAILED"])
	var stage = get_tree().get_first_node_in_group("system:stage")
	var model = stage.active_model
	var item = await ItemManager.create_item(PackedStringArray([ProjectSettings.globalize_path("res://branding/splash.png")]))
	stage.spawn_item(item, false, true)
	item.pinnable = true
	item.scale *= 0.1
	item.global_position = model.global_position - item.scale * item.center
	for i in 10:
		await get_tree().process_frame
	item._on_drag_released()
	check.call("pinned to %s" % (item.pinned_to.name if item.pinned_to else "nothing"), item.pinned_to != null and item.pin_mode == item.PinMode.VERTICES)
	if item.pinned_to == null:
		return
	# a pose that deforms the body, so the mesh's vertices differ from its loaded shape
	model.model.set("parameters/ParamBodyAngleX", 10.0)
	model.model.set("parameters/ParamAngleX", 30.0)
	for i in 10:
		await get_tree().process_frame
	var before: Vector2 = item.global_position
	model.position += Vector2(80, 0)
	for i in 20:
		await get_tree().process_frame
	var moved: Vector2 = item.global_position - before
	print("[automation] pin item moved %s with the model moved (80, 0)" % moved)
	check.call("follows the mesh", absf(moved.x - 80.0) < 6.0 and absf(moved.y) < 6.0)
	model.position -= Vector2(80, 0)
	# the vertices pinning reads (read back from the GPU when it deforms) against the mesh's own shape
	var km = model.model
	var mesh: MeshInstance2D = item.pinned_to
	var now: PackedVector2Array = km.mesh_vertices(mesh.name)
	var count: int = RenderingServer.mesh_surface_get_arrays(mesh.mesh, 0)[Mesh.ARRAY_VERTEX].size()
	check.call("vertices read for %s (%d of %d)" % [mesh.name, now.size(), count], now.size() == count)
	# what the CPU computes in this pose (a wrong read would be far off, an old one a little)
	var cpu: PackedVector2Array = km.cpu_mesh_vertices(mesh.name)
	var off := 0.0
	for i in mini(now.size(), cpu.size()):
		off = maxf(off, now[i].distance_to(cpu[i]))
	var loaded: PackedVector2Array = RenderingServer.mesh_surface_get_arrays(mesh.mesh, 0)[Mesh.ARRAY_VERTEX]
	var deformed := 0.0
	for i in mini(cpu.size(), loaded.size()):
		deformed = maxf(deformed, cpu[i].distance_to(loaded[i]))
	check.call("read vertices match the CPU (%.3f px off, the mesh moved %.1f px from its loaded shape)" % [off, deformed], cpu.size() == now.size() and off < 0.5)
	stage.remove_item(item)

## plays each motion for 1.5 s and prints, per pose group, how the parts' opacities move across each switch: the part that
## leaves and the one that comes in must cover each other (at least 90 % in the worst frame)
func _motion_switch(model, motions: PackedStringArray) -> void:
	var player: AnimationPlayer = model.model.get_node("MotionController")
	var pose = model.model.get_node_or_null("Pose")
	for m in motions:
		player.play(m)
		var worst := {}
		var shown := {}
		var start := Time.get_ticks_msec()
		var fade_ms := {}
		while Time.get_ticks_msec() - start < 1500:
			await RenderingServer.frame_post_draw
			for gi in pose._groups.size():
				var g: Dictionary = pose._groups[gi]
				var clear := 1.0
				for o in g["opacity"]:
					clear *= 1.0 - o
				worst[gi] = minf(worst.get(gi, 1.0), 1.0 - clear)
				if g["opacity"].count(1.0) != 1 or g["opacity"].filter(func (o): return o > 0.0).size() != 1:
					fade_ms[gi] = Time.get_ticks_msec() - start
				shown[gi] = g["parts"][g["shown"]]
		print("[automation] motion %s: shown %s, lowest cover %s, fade ended at %s ms" % [m, shown.values(), worst.values(), fade_ms.values()])

func _pipewire_test(seconds: float):
	var check := func (what: String, ok: bool): print("[automation] pipewire %s: %s" % [what, "ok" if ok else "FAILED"])
	var out = get_tree().get_first_node_in_group("output:pipewire")
	var window := get_window()
	var keep_size := window.size
	out.enabled = true
	for size in [keep_size, Vector2i(960, 540), keep_size]:
		window.size = size
		await get_tree().create_timer(seconds).timeout
		var stage_size: Vector2i = out._viewport.get_texture().get_size()
		var latency: PackedFloat64Array = out._out.latency() if out._out else PackedFloat64Array()
		print("[automation] pipewire %s at %s: %s, frame handed over %s ms after submission (mean, max, frames)" % [
			stage_size, size, out.status, latency])
		check.call("running at %s" % size, out.status_ok and out._running)
	out.enabled = false
	check.call("stopped", not out._running and out.status_ok)

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
	# key capture: two plain keys held together (Tab+F1, as VTS hotkeys often are), set when both are released
	row.get_child(1).pressed.emit()
	for k in [[KEY_TAB, true], [KEY_F1, true], [KEY_TAB, false], [KEY_F1, false]]:
		var ev := InputEventKey.new()
		ev.keycode = k[0]
		ev.physical_keycode = k[0]
		ev.pressed = k[1]
		Input.parse_input_event(ev)
		await get_tree().process_frame
	var two: Array = list.entries()[-1].key.get_node("%Handler").input_as_list
	check.call("two keys %s" % [two], two == ["Tab", "F1"])
	# then Ctrl+K as real key events, replacing them
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
			# each step waits for its Start button
			if not page._guide_start.disabled:
				if current[0][0] == "eyes_closed" and not shot_taken:
					get_viewport().get_texture().get_image().save_png(String(args.get("screenshot-window", "/tmp/calibration.png")).get_basename() + "_start.png")
				page._guide_start.pressed.emit()
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
	# two-sided parameters keep the resting face in the middle: brow height rest 0.5, raised 0.9 -> 0.12 to 0.88
	for brow in page.chains().filter(func (c): return c.tracker_param == "Brows"):
		var out: Vector2 = brow.rangemap.b if brow.rangemap else Vector2.ZERO
		var band: Vector2 = brow.rangemap.a if brow.rangemap else Vector2(-1, -1)
		var want := Vector2(0.12, 0.88) if out.x < 0.0 and out.y > 0.0 else Vector2(0.52, 0.88)
		check.call("%s (output %s) band %s, expected %s" % [brow.param, out, band, want], band.distance_to(want) < 0.03)
	# the reset puts every row back to the model's defaults
	page.find_child("ResetBtn", true, false).pressed.emit()
	await get_tree().process_frame
	check.call("reset asks first", page._reset_confirm.visible)
	page.find_child("ResetYes", true, false).pressed.emit()
	for i in 10:
		await get_tree().process_frame
	mouth = page.chains().filter(func (c): return c.tracker_param == "MouthOpen")
	var reset_band: Vector2 = mouth[0].rangemap.a if mouth and mouth[0].rangemap else Vector2(0, 1)
	check.call("reset mouth band %s" % reset_band, reset_band.distance_to(Vector2(0, 1)) < 0.01)

const RECORD_PARAMS = ["FaceAngleX", "FaceAngleY", "FaceAngleZ", "EyeOpenLeft", "EyeOpenRight", "MouthOpen", "MouthSmile", "Brows", "FacePositionX", "FacePositionY", "FacePositionZ"]

func _perf_report(seconds: float, rounds: int = 1, only: String = ""):
	# Godot's own TIME_PROCESS monitor read more than a whole frame here, so the main thread's real CPU time
	# comes from /proc, and what costs it is found by switching parts off in turn
	var stage = get_tree().get_first_node_in_group("system:stage")
	var models: Node = stage.find_child("ModelLayer", true, false) if stage else null
	var interface = get_tree().root.find_child("Interface", true, false)  # a CanvasLayer
	var viewports: Array[Viewport] = [get_viewport()]
	viewports.append_array(get_tree().root.find_children("*", "SubViewport", true, false))
	for v in viewports:
		RenderingServer.viewport_set_measure_render_time(v.get_viewport_rid(), true)
	var phases := [["as is", func (_on): pass]]
	if models:
		phases.append(["models not processed", func (on): models.process_mode = Node.PROCESS_MODE_DISABLED if on else Node.PROCESS_MODE_INHERIT])
	# each autoload and each tracking input stopped in turn (process and input), the parts that run every frame
	var parts: Array[Node] = []
	for n in get_tree().root.get_children():
		if n != self and n != get_tree().current_scene:
			parts.append(n)
	var tracking = get_tree().get_first_node_in_group("system:tracking")
	if tracking:
		parts.append(tracking)
		parts.append_array(tracking.get_children())
	for part in parts:
		var before: Node.ProcessMode = part.process_mode
		phases.append(["%s stopped" % part.name, func (on): part.process_mode = Node.PROCESS_MODE_DISABLED if on else before])
	if interface:
		phases.append(["interface hidden", func (on): interface.visible = not on])
	if stage:
		phases.append(["stage not rendered", func (on): stage.capture_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED if on else SubViewport.UPDATE_ALWAYS])
	# every script whose nodes run _process or _physics_process each frame, those nodes' processing off together
	var groups := {}
	for n in get_tree().root.find_children("*", "", true, false):
		if n == self or not (n.is_processing() or n.is_physics_processing()):
			continue
		var script = n.get_script()
		var key: String = script.resource_path.get_file() if script else n.get_class()
		groups[key] = groups.get(key, []) + [n]
	for key in groups:
		var nodes: Array = groups[key]
		var states := nodes.map(func (n): return [n.is_processing(), n.is_physics_processing()])
		phases.append(["%s x%d off" % [key, nodes.size()], func (on):
			for i in nodes.size():
				if is_instance_valid(nodes[i]):
					nodes[i].set_process(states[i][0] and not on)
					nodes[i].set_physics_process(states[i][1] and not on)])
	var scene := get_tree().current_scene
	phases.append(["studio stopped", func (on): scene.process_mode = Node.PROCESS_MODE_DISABLED if on else Node.PROCESS_MODE_INHERIT])
	if only:
		phases = phases.filter(func (ph): return ph[0] == "as is" or Array(only.split(",")).any(func (w): return w in ph[0]))
	var results := {}  # phase -> main thread ms per frame of each round
	for round in rounds:
		for phase in phases:
			phase[1].call(true)
			for i in 30:
				await RenderingServer.frame_post_draw
			var frames := 0
			var render := 0.0
			var t0 := Time.get_ticks_usec()
			var main0 := _cpu_ms("/proc/thread-self/stat")
			var all0 := _cpu_ms("/proc/self/stat")
			while Time.get_ticks_usec() - t0 < seconds * 1e6:
				await RenderingServer.frame_post_draw
				frames += 1
				render += RenderingServer.get_frame_setup_time_cpu()
				for v in viewports:
					if is_instance_valid(v):
						render += RenderingServer.viewport_get_measured_render_time_cpu(v.get_viewport_rid())
			var n: float = max(frames, 1)
			var main: float = (_cpu_ms("/proc/thread-self/stat") - main0) / n
			results[phase[0]] = results.get(phase[0], []) + [main]
			print("[automation] perf %-40s %3.0f fps, main thread %5.2f ms CPU per frame, whole app %5.2f, renderer's own measure %4.2f" % [
				phase[0], frames / seconds, main, (_cpu_ms("/proc/self/stat") - all0) / n, render / n])
			phase[1].call(false)
	if rounds > 1:
		# rounds alternate the phases, so the CPU's clock changes (powersave governor) average out
		for key in results:
			var v: Array = results[key]
			v.sort()
			print("[automation] perf median %-40s %5.2f ms (%s)" % [key, v[v.size() / 2], ", ".join(v.map(func (x): return "%.2f" % x))])
	for v in viewports:
		if is_instance_valid(v):
			RenderingServer.viewport_set_measure_render_time(v.get_viewport_rid(), false)

## utime + stime of a /proc stat file in ms (Linux, 100 ticks a second)
func _cpu_ms(path: String) -> float:
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return 0.0
	var line := f.get_line()
	var rest := line.substr(line.rfind(")") + 2).split(" ")
	return (int(rest[11]) + int(rest[12])) * 10.0

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
## model parameter groups held one after another (effects driven by parameters, e.g. a hologram switch)
func _shoot_model_params(args: Dictionary, viewport: Viewport, path: String):
	var groups: Dictionary = JSON.parse_string(args["model-params"])
	var km = get_tree().get_first_node_in_group("system:stage").active_model.model
	for group in groups:
		var before := {}
		for param in groups[group]:
			before[param] = km.get("parameters/%s" % param)
			km.set("parameters/%s" % param, float(groups[group][param]))
		for i in int(args.get("pose-frames", "90")):
			await RenderingServer.frame_post_draw
		var shot = "%s_%s.png" % [path.get_basename(), group]
		var err = viewport.get_texture().get_image().save_png(shot)
		print("[automation] params %s -> %s" % [shot, error_string(err)])
		for param in before:
			km.set("parameters/%s" % param, before[param])

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

## debugging aid: --dump-meshes prints where these art meshes are now and whether they are drawn
func _debug_meshes_after(args: Dictionary, model):
	for mesh_name in args.get("dump-meshes", "").split(",", false):
		var mi = model.find_child(mesh_name, true, false)
		if mi == null:
			print("[automation]   %s missing" % mesh_name)
			continue
		var km = mi.get_parent().get_parent()
		var verts: PackedVector2Array = km.mesh_vertices(mi.name)
		if verts.is_empty():
			print("[automation]   %s has no vertices" % mesh_name)
			continue
		var vb := Rect2(verts[0], Vector2.ZERO)
		for vv in verts:
			vb = vb.expand(vv)
		print("[automation]   %s drawn %s, vertex box %s, first %s" % [mesh_name, km.mesh_visible(mi.name), vb, verts[0]])

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


func _set_background(value: String) -> void:
	var stage = get_tree().get_first_node_in_group("system:stage")
	if value.is_valid_html_color():
		stage.background_color = Color(value)
		stage.background_mode = 2
	else:
		stage.background_image = value
		stage.background_mode = 1


func _blink_test(seconds: float) -> void:
	var model = get_tree().get_first_node_in_group("system:stage").active_model
	var low := [9.0, 9.0]
	var high := [-9.0, -9.0]
	var apart := 0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000:
		await RenderingServer.frame_post_draw
		var l: float = model.get("parameters/ParamEyeLOpen")
		var r: float = model.get("parameters/ParamEyeROpen")
		low = [minf(low[0], l), minf(low[1], r)]
		high = [maxf(high[0], l), maxf(high[1], r)]
		apart += 1 if absf(l - r) > 0.2 else 0
	print("[automation] blink: left %.2f to %.2f, right %.2f to %.2f, frames apart %d" % [low[0], high[0], low[1], high[1], apart])
