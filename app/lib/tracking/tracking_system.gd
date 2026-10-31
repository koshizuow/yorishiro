extends Node

const Tracker = preload("res://lib/tracking/tracker.gd")

var parameters = {}
## whether the face tracker currently sees a face. Trackers that report a status with "face" (Yorishiro's)
## decide it, others count as always seeing one
var face_present := true

signal tracker_changed(tracker: Tracker)
signal parameters_updated(parameters: Dictionary, delta: float)

func _ready():
	for i in Registry.parameters():
		parameters[i.id] = i.default_value
	parameters.erase("unset")
	
func activate_tracker(tracker: Tracker):
	if has_node("FaceTracker"):
		var prev = get_node("FaceTracker")
		remove_child(prev)
		prev.queue_free()
	
	if tracker:
		tracker.name = "FaceTracker"
		add_child(tracker)
		move_child(tracker, 0)
	tracker_changed.emit(tracker)
	
	return tracker

func _process(delta: float) -> void:
	parameters.clear()
	
	# combine tracking
	for i in get_children():
		parameters.merge(i.parameters(), true)
		
	# accumulative adjustments
	parameters.merge(
		{
			"VoiceVolumePlusMouthOpen": Registry.clamp_to_range(parameters.get("MouthOpen", 0) + parameters.get("VoiceVolume", 0), "MouthOpen"),
			"VoiceFrequencyPlusMouthSmile": Registry.clamp_to_range(parameters.get("MouthSmile", 0) + parameters.get("VoiceFrequency", 0), "MouthSmile"),
		}, true
	)
	
	var face = get_node_or_null("FaceTracker")
	face_present = true
	if face and "status" in face and face.status is Dictionary and face.status.has("face"):
		face_present = bool(face.status.face)

	parameters_updated.emit(parameters, delta)
	
