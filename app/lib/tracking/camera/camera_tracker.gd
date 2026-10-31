extends "res://lib/tracking/interpolated_tracker.gd"

static func _static_init() -> void:
	Registry.add_parameter("FacePositionX", Vector2(-15, 15))
	Registry.add_parameter("FacePositionY", Vector2(-15, 15))
	Registry.add_parameter("FacePositionZ", Vector2(-10, 10))
	Registry.add_parameter("FaceAngleX", Vector2(-30, 30))
	Registry.add_parameter("FaceAngleY", Vector2(-30, 30))
	Registry.add_parameter("FaceAngleZ", Vector2(-30, 30))
	
	Registry.add_parameter("MouthSmile", Vector2(0, 1))
	Registry.add_parameter("MouthOpen", Vector2(0, 1))
	
	Registry.add_parameter("Brows", Vector2(0, 1))
	
	# iOS/Android only
	Registry.add_parameter("TongueOut", Vector2(0, 1))
	
	Registry.add_parameter("EyeOpenLeft", Vector2(0, 1), 1)
	Registry.add_parameter("EyeOpenRight", Vector2(0, 1), 1)
	Registry.add_parameter("EyeLeftX", Vector2(-1, 1))
	Registry.add_parameter("EyeLeftY", Vector2(-1, 1))
	Registry.add_parameter("EyeRightX", Vector2(-1, 1))
	Registry.add_parameter("EyeRightY", Vector2(-1, 1))
	
	# iOS only
	Registry.add_parameter("CheekPuff", Vector2(0, 1))
	Registry.add_parameter("FaceAngry", Vector2(0, 1))
	
	Registry.add_parameter("BrowLeftY", Vector2(-1, 1))
	Registry.add_parameter("BrowRightY", Vector2(-1, 1))
	
	Registry.add_parameter("MouthX", Vector2(-1, 1))
	
	# hand tracking (yorishiro tracker with hands on), names as VTube Studio models bind them
	for side in ["Left", "Right"]:
		Registry.add_parameter("Hand%sFound" % side, Vector2(0, 1), 0.0, "Hands")
		for axis in ["X", "Y", "Z"]:
			Registry.add_parameter("Hand%sPosition%s" % [side, axis], Vector2(-10, 10), 0.0, "Hands")
		Registry.add_parameter("Hand%sAngleX" % side, Vector2(-180, 180), 0.0, "Hands")
		Registry.add_parameter("Hand%sAngleZ" % side, Vector2(-180, 180), 0.0, "Hands")
		Registry.add_parameter("Hand%sOpen" % side, Vector2(0, 1), 0.0, "Hands")
		for finger in ["1_Thumb", "2_Index", "3_Middle", "4_Ring", "5_Pinky"]:
			Registry.add_parameter("Hand%sFinger_%s" % [side, finger], Vector2(0, 1), 0.0, "Hands")
	Registry.add_parameter("BothHandsFound", Vector2(0, 1), 0.0, "Hands")
	Registry.add_parameter("HandDistance", Vector2(0, 10), 0.0, "Hands")

func _ready() -> void:
	reset()

func reset():
	update([
		"FacePositionX",
		"FacePositionY",
		"FacePositionZ",
		"FaceAngleX",
		"FaceAngleY",
		"FaceAngleZ",
		"MouthSmile",
		"MouthOpen",
		"MouthX",
		"Brows",
		"TongueOut",
		"EyeOpenLeft",
		"EyeOpenRight",
		"EyeLeftX",
		"EyeLeftY",
		"EyeRightX",
		"EyeRightY",
		"CheekPuff",
		"FaceAngry",
		"BrowLeftY",
		"BrowRightY",
		"MouthX",
	].reduce(
		func (acc, parameter):
			acc[parameter] = Registry.get_default(parameter)
			return acc,
		{}
	))
