## iFacialMocap input: the iPhone app streams ARKit blendshapes and the head pose over UDP. Yorishiro asks the
## phone to start by sending the app's start message to <phone>:49983, then the phone sends one text datagram a
## frame to this computer's port 49983:
##   eyeBlink_L-0|eyeBlink_R-3|...|jawOpen-12|=head#nod,turn,tilt,x,y,z|rightEye#a,b,c|leftEye#a,b,c|
## values 0..100, names are ARKit's with Left/Right shortened to _L/_R, angles in degrees, position in cm. Some
## versions write name&value instead of name-value; both are read. The format is the one the app documents for
## PC receivers, the same Yorishiro's own iFacialMocap output writes (crates/tracking/src/sinks.rs).
## Do not turn on Yorishiro's iFacialMocap output at the same time: it sends to this computer's 49983 too.

extends "../blendshape_tracker.gd"

const BidirectionalTracker = preload("res://lib/tracking/net/bidirectional_tracker.gd")
const ArkitToVts = preload("../arkit_to_vts.gd")

const PORT := 49983
## what the app waits for before it streams to the sender's address
const START := "iFacialMocap_sahuasouryya9218sauhuiayeta91555dy3719"
## ask again when nothing came for this long (the phone app restarted, the phone slept)
const QUIET_S := 2.0

var server: BidirectionalTracker
var last_parameters := {}
var _last_packet_ms := -100000

func _ready():
	server = BidirectionalTracker.new()
	server.host = "0.0.0.0"
	server.port = PORT
	server.client_port = PORT
	server.packet_received.connect(_packet_received)
	server.try_handshake.connect(
		func (client: PacketPeerUDP):
			if Time.get_ticks_msec() - _last_packet_ms < QUIET_S * 1000:
				return
			var err = client.put_packet(START.to_ascii_buffer())
			if err != OK:
				push_warning("[iFacialMocap] could not ask the phone to start: ", err)
	)
	add_child(server)

func create_config() -> Node:
	var panel = preload("./ifm_config.tscn").instantiate()
	panel.tracker = self
	panel.server = server
	return panel

## Parses one datagram: {"shapes": {name: 0..1}, "head": [nod, turn, tilt], "position": Vector3 cm} or {} when it
## is not iFacialMocap data.
static func parse(text: String) -> Dictionary:
	var parts := text.split("=", true, 1)
	var shapes := {}
	for item in parts[0].split("|", false):
		var cut := maxi(item.rfind("-"), item.rfind("&"))
		if cut <= 0:
			continue
		var value := item.substr(cut + 1)
		if not value.is_valid_float():
			continue
		var key := item.substr(0, cut).replace("_L", "Left").replace("_R", "Right").to_pascal_case()
		shapes[key] = clampf(value.to_float() / 100.0, 0.0, 1.0)
	var head := []
	# each eye: the first number nods, the second turns
	var eyes := {"leftEye": Vector2.ZERO, "rightEye": Vector2.ZERO}
	if parts.size() > 1:
		for item in parts[1].split("|", false):
			var tag := item.get_slice("#", 0)
			var nums := Array(item.get_slice("#", 1).split(",")).map(func (v): return float(v))
			if tag == "head":
				head = nums
			elif tag in eyes and nums.size() >= 2:
				eyes[tag] = Vector2(nums[1], nums[0])
	if shapes.is_empty() or head.size() < 6:
		return {}
	return {"shapes": shapes, "head": [head[0], head[1], head[2]], "position": Vector3(head[3], head[4], head[5]),
		"eye_left": eyes["leftEye"], "eye_right": eyes["rightEye"]}

func _packet_received(packet: PackedByteArray):
	var data := parse(packet.get_string_from_utf8())
	if data.is_empty():
		return
	if Time.get_ticks_msec() - _last_packet_ms > QUIET_S * 1000:
		print("[iFacialMocap] receiving from the phone (%d blendshapes)" % data["shapes"].size())
	_last_packet_ms = Time.get_ticks_msec()
	tracker.has_tracking_data = true
	var h: Array = data["head"]
	# the same axes as the VTube Studio iPhone input: nod about x, turn about y, tilt about z
	tracker.set_joint_transform(XRBodyTracker.JOINT_HEAD, Transform3D(
		Basis(Quaternion.from_euler(Vector3(deg_to_rad(h[0]), deg_to_rad(h[1]), deg_to_rad(h[2])))),
		Vector3.ZERO
	))
	tracker.set_joint_transform(XRBodyTracker.JOINT_ROOT, Transform3D(Basis(Quaternion.IDENTITY), data["position"]))
	# the raw blendshapes for node-editor wiring, and the inputs models are bound to
	var parameters: Dictionary = data["shapes"].duplicate()
	parameters.merge(ArkitToVts.params(data["shapes"], h, data["position"], data["eye_left"], data["eye_right"]))
	last_parameters = parameters
	update(parameters)
