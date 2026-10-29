## Command line automation for tests, inert unless user args are given after "--":
##   --model=<path>         load a model at startup
##   --screenshot=<png>     save the stage after --wait-frames rendered frames
##   --wait-frames=<n>      default 90, lets physics and tracking settle
##   --quit                 exit after the screenshot
extends Node

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

	if args.has("model"):
		var model = ModelManager.make_model(args["model"])
		if model == null:
			push_error("[automation] could not load model %s" % args["model"])
		else:
			stage.spawn_model(model)

	if args.has("screenshot"):
		for i in int(args.get("wait-frames", "90")):
			await RenderingServer.frame_post_draw
		var viewport = stage.capture_viewport if stage else get_viewport()
		var path: String = args["screenshot"]
		var err = viewport.get_texture().get_image().save_png(path)
		print("[automation] screenshot %s -> %s" % [path, error_string(err)])

	if args.has("quit"):
		get_tree().quit()
