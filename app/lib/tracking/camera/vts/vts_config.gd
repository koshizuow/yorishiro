extends Control

const SocketTracker = preload("res://lib/tracking/net/socket_tracker.gd")

var tracker: SocketTracker

func _ready() -> void:
	# this computer's address, for the phone's PC connection settings (any private IPv4: 192.168, 10, 172.16-31)
	var lan := Array(IP.get_local_addresses()).filter(func (ip: String):
		return ip.begins_with("192.168.") or ip.begins_with("10.") or (ip.begins_with("172.") and ip.split(".")[1].to_int() in range(16, 32)))
	%Hostname.text = lan[0] if lan else ""
	tracker.connection_status.connect(
		func (status):
			match status:
				SocketTracker.ConnectionStatus.OFF:
					%ActiveIndicator.text = "Off"
					%ActiveIndicator.modulate = Color.RED
				SocketTracker.ConnectionStatus.ON:
					%ActiveIndicator.text = "On"
					%ActiveIndicator.modulate = Color.WHITE
				SocketTracker.ConnectionStatus.WAIT:
					%ActiveIndicator.text = "Waiting..."
					%ActiveIndicator.modulate = Color.WHITE
	)
	
func _on_connect_pressed() -> void:
	tracker.host = "*"
	tracker.port = %Port.value
	tracker.start()
	
func _on_disconnect_pressed() -> void:
	tracker.stop()
