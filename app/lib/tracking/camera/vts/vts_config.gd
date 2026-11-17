extends Control

const SocketTracker = preload("res://lib/tracking/net/socket_tracker.gd")
const Collections = preload("res://lib/utils/collections.gd")
const VtsTracker = preload("./vts_tracker.gd")

var tracker: SocketTracker
## why the last start failed, shown instead of "Off"
var _error := ""

func _ready() -> void:
	# this computer's address, for the phone's PC connection settings (any private IPv4: 192.168, 10, 172.16-31)
	var lan := Array(IP.get_local_addresses()).filter(func (ip: String):
		return ip.begins_with("192.168.") or ip.begins_with("10.") or (ip.begins_with("172.") and ip.split(".")[1].to_int() in range(16, 32)))
	%Hostname.text = lan[0] if lan else ""
	tracker.connection_status.connect(
		func (status):
			match status:
				SocketTracker.ConnectionStatus.OFF:
					if _up():
						return  # the late "off" of a stop just before listening again
					%ActiveIndicator.text = _error if _error else "Off"
					%ActiveIndicator.modulate = Color.RED
				SocketTracker.ConnectionStatus.ON:
					%ActiveIndicator.text = "On"
					%ActiveIndicator.modulate = Color.WHITE
				SocketTracker.ConnectionStatus.WAIT:
					%ActiveIndicator.text = "Waiting..."
					%ActiveIndicator.modulate = Color.WHITE
	)
	# a new port while listening: listen there instead (the phone has to be set to it too)
	%Port.value_changed.connect(func (_v):
		if _up():
			tracker.stop()
			_on_connect_pressed())

func _up() -> bool:
	return tracker.server != null and tracker.server.is_listening()
	
func _on_connect_pressed() -> void:
	tracker.host = "*"
	tracker.port = int(%Port.value)
	_error = ""
	if not tracker.start():
		_error = tr("Port %d is in use by another program.") % tracker.port
		%ActiveIndicator.text = _error
		%ActiveIndicator.modulate = Color.RED
	
func _on_disconnect_pressed() -> void:
	_error = ""
	if not _up():
		# nothing to stop (the last start failed): no "off" will come
		%ActiveIndicator.text = "Off"
		%ActiveIndicator.modulate = Color.RED
	tracker.stop()

func save_settings(settings: Dictionary):
	var trackers = settings.get("trackers", {})
	var config = trackers.get("vts", {})
	config["port"] = int(%Port.value)
	trackers["vts"] = config
	settings["trackers"] = trackers

func load_settings(settings: Dictionary):
	%Port.set_value_no_signal(Collections.path(settings, "trackers.vts.port", VtsTracker.default_port()))
