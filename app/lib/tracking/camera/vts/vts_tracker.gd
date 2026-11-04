extends "../camera_tracker.gd"

const TCPTracker = preload("res://lib/tracking/net/tcp_tracker.gd")

# for compatibility with VTS and its Stream to PC functionality
# it's important to maintain exact enum order, as they are serialized by the ordinal
const Inputs = [
	"Unset",
	"FacePositionX",
	"FacePositionY",
	"FacePositionZ",
	"FaceAngleX",
	"FaceAngleY",
	"FaceAngleZ",
	"MouthSmile",
	"MouthOpen",
	"Brows",
	"TongueOut", # iOS/Android only
	"EyeOpenLeft",
	"EyeOpenRight",
	"EyeLeftX",
	"EyeLeftY",
	"EyeRightX",
	"EyeRightY",
	"CheekPuff", # iOS only
	"FaceAngry", # iOS only
	"BrowLeftY",
	"BrowRightY",
	"MousePositionX",
	"MousePositionY",
	# microphone
	"VoiceVolume",
	"VoiceFrequency",
	"VoiceVolumePlusMouthOpen",
	"VoiceFrequencyPlusMouthSmile",
	"MouthX",
	# pc only
	"HandLeftFound",
	"HandRightFound",
	"BothHandsFound",
	"HandDistance",
	"HandLeftPositionX",
	"HandLeftPositionY",
	"HandLeftPositionZ",
	"HandRightPositionX",
	"HandRightPositionY",
	"HandRightPositionZ",
	"HandLeftAngleX",
	"HandLeftAngleZ",
	"HandRightAngleX",
	"HandRightAngleZ",
	"HandLeftOpen",
	"HandRightOpen",
	"HandLeftFinger1Thumb",
	"HandLeftFinger2Index",
	"HandLeftFinger3Middle",
	"HandLeftFinger4Ring",
	"HandLeftFinger5Pinky",
	"HandRightFinger1Thumb",
	"HandRightFinger2Index",
	"HandRightFinger3Middle",
	"HandRightFinger4Ring",
	"HandRightFinger5Pinky",
	# more voice
	"VoiceA",
	"VoiceI",
	"VoiceU",
	"VoiceE",
	"VoiceO",
	"VoiceSilence"
]

var server: TCPTracker

var poller: Timer

func _ready():
	super._ready()
	server = TCPTracker.new()
	server.port = 25565
	
	server.packet_received.connect(_packet_received)
	
	add_child(server)

func create_config() -> Node:
	var panel = preload("./vts_config.tscn").instantiate()
	panel.tracker = server
	return panel

## The phone streams over TCP: each message is a 4 byte big-endian length, then that much JSON (about 1.1 kB, 57 a
## second from an iPhone, 2026-11-04). TCP does not keep message boundaries, so one read can hold part of a message
## or several: the bytes collect here until a whole message is in. Before, the length was read little-endian and each
## read parsed as one message, which only worked while every read happened to be exactly one.
var _pending := PackedByteArray()
const MAX_MESSAGE = 1 << 20

func _packet_received(packet: PackedByteArray):
	_pending.append_array(packet)
	var latest = null
	while _pending.size() >= 4:
		var n := (_pending[0] << 24) | (_pending[1] << 16) | (_pending[2] << 8) | _pending[3]
		if n <= 0 or n > MAX_MESSAGE:
			_pending.clear()  # out of step with the stream, start over with the next read
			return
		if _pending.size() < 4 + n:
			break
		var msg = JSON.parse_string(_pending.slice(4, 4 + n).get_string_from_utf8())
		_pending = _pending.slice(4 + n)
		if msg is Dictionary and "Data" in msg:
			latest = msg
	if latest != null:
		_data_received(latest.Data)

func _data_received(data: Array):
	var param = {}
	for p in data:
		var parameter = Inputs[int(p.p)]
		param[parameter] = p.v
	update(param)
