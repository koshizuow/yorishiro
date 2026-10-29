## Receives frames from yorishiro-tracker (GPU face tracking) over the local Yorishiro link.
## Each UDP datagram is one JSON frame, see yorishiro_tracker/sinks/link.py.
extends "../camera_tracker.gd"

const UdpTracker = preload("res://lib/tracking/net/udp_tracker.gd")
const SocketTracker = preload("res://lib/tracking/net/socket_tracker.gd")

const DEFAULT_PORT = 39570

var server: UdpTracker
var found := false
## latest raw ARKit 52 values, for bindings that want more than the VTS style inputs
var arkit := {}

func _ready():
	super._ready()
	server = UdpTracker.new()
	server.name = "YorishiroLink"
	server.host = "127.0.0.1"
	server.port = DEFAULT_PORT
	server.packet_received.connect(_packet_received)
	add_child(server)
	server.start()

func create_config() -> Node:
	var box = VBoxContainer.new()
	var status = Label.new()
	status.text = "Waiting for yorishiro-tracker on port %d" % DEFAULT_PORT
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(status)
	var fps_label = Label.new()
	box.add_child(fps_label)
	var timer = Timer.new()
	timer.wait_time = 0.5
	timer.autostart = true
	timer.timeout.connect(
		func ():
			fps_label.text = "FPS: %d   face: %s" % [max(0, fps), "yes" if found else "no"]
	)
	box.add_child(timer)
	server.connection_status.connect(
		func (s):
			if s == SocketTracker.ConnectionStatus.ON:
				status.text = "Receiving from yorishiro-tracker"
	)
	return box

func _packet_received(packet: PackedByteArray):
	var msg = JSON.parse_string(packet.get_string_from_utf8())
	if typeof(msg) != TYPE_DICTIONARY:
		return
	found = msg.get("found", false)
	if found:
		arkit = msg.get("arkit", {})
		update(msg.get("vts", {}))
