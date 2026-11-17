extends Control

const SocketTracker = preload("res://lib/tracking/net/socket_tracker.gd")
const Collections = preload("res://lib/utils/collections.gd")
const VtsTracker = preload("./vts_tracker.gd")

var tracker: VtsTracker
var server: SocketTracker
## why the last start failed, shown instead of "Off"
var _error := ""

func _ready() -> void:
	server.connection_status.connect(
		func (status):
			match status:
				SocketTracker.ConnectionStatus.OFF:
					%ActiveIndicator.text = _error if _error else "Off"
					%ActiveIndicator.modulate = Color.RED
				SocketTracker.ConnectionStatus.ON:
					%ActiveIndicator.text = "On"
					%ActiveIndicator.modulate = Color.WHITE
				SocketTracker.ConnectionStatus.WAIT:
					%ActiveIndicator.text = "Waiting..."
					%ActiveIndicator.modulate = Color.WHITE
	)
	# a new port while connected: listen there instead
	%LocalPort.value_changed.connect(func (_v):
		if _up():
			server.stop()
			_on_connect_pressed())
	%Connect.pressed.connect(_on_connect_pressed)
	%Disconnect.pressed.connect(_on_disconnect_pressed)
	
func _up() -> bool:
	return server.server != null and server.server.is_bound()

func _on_connect_pressed() -> void:
	server.client_host = %Hostname.text
	server.port = int(%LocalPort.value)
	_error = ""
	if not server.start():
		_error = tr("Port %d is in use by another program.") % server.port
		%ActiveIndicator.text = _error
		%ActiveIndicator.modulate = Color.RED
	
func _on_disconnect_pressed() -> void:
	_error = ""
	if not _up():
		# nothing to stop (the last start failed): no "off" will come
		%ActiveIndicator.text = "Off"
		%ActiveIndicator.modulate = Color.RED
	server.stop()

func save_settings(settings: Dictionary):
	var trackers = settings.get("trackers", {})
	var config = trackers.get("vts_blendshapes", {})
	config["client_host"] = %Hostname.text
	config["port"] = int(%LocalPort.value)
	
	trackers["vts_blendshapes"] = config
	settings["trackers"] = trackers

func load_settings(settings: Dictionary):
	%Hostname.text = Collections.path(settings, "trackers.vts_blendshapes.client_host", "0.0.0.0")
	%LocalPort.set_value_no_signal(Collections.path(settings, "trackers.vts_blendshapes.port", VtsTracker.default_port()))
