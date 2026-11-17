extends "./socket_tracker.gd"

var server: TCPServer
var peer: StreamPeerTCP

## false when the port could not be opened (another program, or another copy of the app, has it)
func start():
	if server != null and server.is_listening():
		return true
	
	server = TCPServer.new()
	var err = server.listen(port, host)
	if err != OK:
		server = null
		return false
	
	connection_status.emit(ConnectionStatus.WAIT)
	return true
	
func stop():
	if server != null and server.is_listening():
		server.stop()
	server = null
	# a connected phone goes too, or a restart on another port would keep reading it
	if peer != null:
		peer.disconnect_from_host()
		peer = null
	call_deferred_thread_group("emit_signal", "connection_status", ConnectionStatus.OFF)

func _listen():
	if server == null:
		return
		
	if not server.is_listening():
		return
	
	if server.is_connection_available() and peer == null:
		peer = server.take_connection()
		connection_status.emit(ConnectionStatus.ON)
	
	if peer == null:
		return
		
	peer.poll()
	var is_alive = peer.get_status()
	if is_alive == StreamPeerTCP.Status.STATUS_NONE or is_alive == StreamPeerTCP.Status.STATUS_ERROR:
		peer = null
		connection_status.emit(ConnectionStatus.WAIT)  # the phone left: wait for it to connect again
		return
	
	if peer.get_available_bytes() <= 0:
		return
		
	var packet = peer.get_data(peer.get_available_bytes())
	var err = packet[0]
	var data = packet[1]
	if err != OK:
		return
	
	packet_received.emit(data)
