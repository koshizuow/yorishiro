## Tracker connecting to VTS 3rd-party API
## Instead of getting the normal VTS parameters we're used to, this API
## returns iOS BlendShapes, which can be used raw

extends "../blendshape_tracker.gd"

const BidirectionalTracker = preload("res://lib/tracking/net/bidirectional_tracker.gd")
const Serializers = preload("res://lib/utils/serializers.gd")
const ArkitToVts = preload("../arkit_to_vts.gd")


class TrackingData:
	@export var Position: Vector3 = Vector3.ZERO
	@export var Rotation: Vector3 = Vector3.ZERO
	# x nods, y turns (degrees)
	@export var EyeLeft: Vector3 = Vector3.ZERO
	@export var EyeRight: Vector3 = Vector3.ZERO
	
	# dict = { k: str, v: float }
	@export var BlendShapes: Array = []

var server: BidirectionalTracker

var poller: Timer
	
func _ready():
	server = BidirectionalTracker.new()
	server.host = "0.0.0.0"
	server.port = 50650
	server.client_port = 21412
	server.handshake_frequency = 1
	
	server.packet_received.connect(_packet_received)
	server.try_handshake.connect(
		func (client: PacketPeerUDP):
			var err = client.put_packet(
				JSON.stringify({
					"messageType": "iOSTrackingDataRequest",
					"sentBy": "Yorishiro",
					"sendForSeconds": 10,
					"ports": [server.port]
				}).to_ascii_buffer()
			)
			if err != OK:
				push_warning("[VTS] client unable to send message", err)
	)
	
	add_child(server)

func create_config() -> Node:
	var panel = preload("./vts_config.tscn").instantiate()
	panel.tracker = self
	panel.server = server
	return panel

func _packet_received(packet: PackedByteArray):
	# parse Telemetry message format
	var content = packet.get_string_from_ascii()
	if content:
		var msg = JSON.parse_string(content)
		var data: TrackingData = Serializers.ObjSerializer.from_json(msg, TrackingData.new())
		tracker.has_tracking_data = true
		_data_received(data)
	
func _data_received(data: TrackingData):
	var parameters = {}
	tracker.set_joint_transform(XRBodyTracker.JOINT_HEAD, Transform3D(
		Basis(
			Quaternion.from_euler(Vector3(
				deg_to_rad(-data.Rotation.y),
				deg_to_rad(-data.Rotation.x),
				deg_to_rad(data.Rotation.z),
			))
		),
		Vector3.ZERO
	))
	
	tracker.set_joint_transform(XRBodyTracker.JOINT_ROOT, Transform3D(
		Basis(Quaternion.IDENTITY),
		data.Position
	))
	
	for parameter in data.BlendShapes:
		# VTS uses different names for each blendshape
		var key = parameter.k.replace("_L", "Left").replace("_R", "Right").to_pascal_case()
		parameters[key] = parameter.v
	# the inputs models are bound to (only the raw blendshapes reached the model before, so it did not move).
	# The phone sends what its front camera sees, already mirrored: Left/Right names are the image's sides (closing
	# the right eye raises EyeBlinkLeft), turning to your left is a positive x and looking up a negative y, the tilt as
	# is. So the data goes in unmirrored with the nod and tilt negated (checked with a real iPhone, 2026-11-04; the
	# example receiver in DenchiSoft's VTubeStudioBlendshapeUDPReceiverTest negates x and y the same way).
	parameters.merge(ArkitToVts.params(parameters.duplicate(), [-data.Rotation.y, data.Rotation.x, -data.Rotation.z],
		data.Position, Vector2(data.EyeLeft.y, data.EyeLeft.x), Vector2(data.EyeRight.y, data.EyeRight.x), false))
	update(parameters)
