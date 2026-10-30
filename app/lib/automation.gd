## Command line automation for tests, inert unless user args are given after "--":
##   --model=<path>         load a model at startup
##   --tracker=<name>       activate a tracking input, e.g. yorishiro
##   --screenshot=<png>     save the stage after --wait-frames rendered frames
##   --wait-frames=<n>      default 90, lets physics and tracking settle
##   --quit                 exit after the screenshot
extends Node

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
	# wait for the main scene so the stage exists
	await get_tree().process_frame
	var stage = get_tree().get_first_node_in_group("system:stage")
	var model = null

	if args.has("model"):
		model = ModelManager.make_model(args["model"])
		if model == null:
			push_error("[automation] could not load model %s" % args["model"])
		else:
			stage.spawn_model(model)

	if args.has("tracker"):
		# the settings panel restores the saved tracker a frame after startup, go after it
		for i in 10:
			await get_tree().process_frame
		var tracking = get_tree().get_first_node_in_group("system:tracking")
		tracking.activate_tracker(load(TRACKERS[args["tracker"]]).new())
		print("[automation] tracker %s" % args["tracker"])

	if args.has("screenshot"):
		for i in int(args.get("wait-frames", "90")):
			await RenderingServer.frame_post_draw
		var viewport = stage.capture_viewport if stage else get_viewport()
		var path: String = args["screenshot"]
		var err = viewport.get_texture().get_image().save_png(path)
		print("[automation] screenshot %s -> %s" % [path, error_string(err)])
		var tracking = get_tree().get_first_node_in_group("system:tracking")
		if tracking:
			var p = tracking.parameters
			print("[automation] tracker %s, FaceAngleX %s, EyeOpenLeft %s, MouthOpen %s" % [
				tracking.get_node_or_null("FaceTracker"), p.get("FaceAngleX"), p.get("EyeOpenLeft"), p.get("MouthOpen")])
		if model:
			print("[automation] graphs %s, ParamAngleX %s" % [
				model.blueprints.map(func (g): return "%s(%d nodes, %s)" % [g.name, g.get_child_count(), g.process_mode]),
				model.get("parameters/ParamAngleX")])

	if args.has("quit"):
		get_tree().quit()
