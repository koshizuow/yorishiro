## Live2D pose groups (<model>.pose3.json, FileReferences.Pose in model3.json): parts that are alternatives
## of each other, such as two sets of arms. Katashiro draws every part, so without this a model shows all of
## them at once. Written from the file format and the models' behavior only (D25, D26).
##
## Per group one part is shown, at first the first one. Motions pick another by raising its part opacity
## (PartOpacity curves); the newly picked part fades in over FadeInTime (0.5 s when the file has none) while
## the others fade out behind it. Parts in a member's Link follow that member.
## Runs as the last mutator of the model, so its opacities are what gets drawn.
extends KatashiroMutator

const DEFAULT_FADE = 0.5

## each group: {"parts": [id, ...], "links": {id: [linked ids]}, "shown": index, "opacity": [per part]}
var _groups: Array[Dictionary] = []
var _fade := DEFAULT_FADE

static func from_model_file(model_path: String) -> Node:
	var data = JSON.parse_string(FileAccess.get_file_as_string(model_path))
	if not data is Dictionary:
		return null
	var pose_file = data.get("FileReferences", {}).get("Pose", "")
	if not pose_file is String or pose_file == "":
		return null
	var pose = JSON.parse_string(FileAccess.get_file_as_string(model_path.get_base_dir().path_join(pose_file)))
	if not pose is Dictionary or not pose.get("Groups") is Array:
		push_warning("unreadable pose file %s" % pose_file)
		return null
	var node = new()
	node.name = "Pose"
	node._fade = maxf(float(pose.get("FadeInTime", DEFAULT_FADE)), 0.0)
	for g in pose["Groups"]:
		if not g is Array or g.size() < 2:
			continue
		var parts: Array[String] = []
		var links := {}
		for member in g:
			if member is Dictionary and member.get("Id") is String:
				parts.append(member["Id"])
				links[member["Id"]] = member.get("Link", []).filter(func (l): return l is String)
		if parts.size() >= 2:
			var opacity: Array[float] = []
			for i in parts.size():
				opacity.append(1.0 if i == 0 else 0.0)
			node._groups.append({"parts": parts, "links": links, "shown": 0, "opacity": opacity})
	return node if not node._groups.is_empty() else null

func _process(delta: float) -> void:
	var players := get_parent().find_children("*", "AnimationPlayer", false, false).filter(
		func (p): return p.current_animation != &"")
	for g in _groups:
		var picked := _picked_by_motion(g, players)
		if picked >= 0:
			g["shown"] = picked
		var step := 1.0 if _fade <= 0.0 else delta / _fade
		var shown: int = g["shown"]
		var opacity: Array[float] = g["opacity"]
		opacity[shown] = minf(1.0, opacity[shown] + step)
		# the others stay nearly opaque until the shown one is mostly in: at 1 - s and s (a plain cross fade)
		# the background showed through both halfway, with 1 - s^3 the two cover at least 93 % of it
		var keep := 1.0 - pow(opacity[shown], 3.0)
		for i in opacity.size():
			if i != shown:
				opacity[i] = minf(opacity[i], keep)

## the part a playing motion raises the most in this group, or -1
func _picked_by_motion(g: Dictionary, players: Array) -> int:
	var best := -1
	var best_value := 0.5
	for p in players:
		for i in g["parts"].size():
			var v = p.get("parts/%s" % g["parts"][i])
			if v is float and v > best_value:
				best = i
				best_value = v
	return best

func _apply(pose: KatashiroPose) -> void:
	for g in _groups:
		for i in g["parts"].size():
			var id: String = g["parts"][i]
			var value: float = g["opacity"][i]
			pose.blend("parts/%s" % id, value)
			for link in g["links"][id]:
				pose.blend("parts/%s" % link, value)
