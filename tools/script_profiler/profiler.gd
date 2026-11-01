## Stands in for the Godot editor's debugger to get the script profiler's numbers from the running app, without
## the editor: listens where the app's --remote-debug points, switches the "servers" profiler on (it carries
## the script functions), adds up every function's self and total time for a while and prints the top ones.
##   godot --headless -s tools/script_profiler/profiler.gd -- --seconds=20 --port=6007 [--top=40]
## then start the app with Godot's option --remote-debug tcp://127.0.0.1:6007 (before the "--" of app options).
extends SceneTree

var port := 6007
var seconds := 20.0
var top := 40

func _init() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		match kv[0]:
			"port": port = int(kv[1])
			"seconds": seconds = float(kv[1])
			"top": top = int(kv[1])
	_run()

func _run() -> void:
	var server := TCPServer.new()
	if server.listen(port, "127.0.0.1") != OK:
		print("cannot listen on %d" % port)
		quit(1)
		return
	print("waiting for the app on port %d" % port)
	while not server.is_connection_available():
		await process_frame
	var peer := server.take_connection()
	peer.set_no_delay(true)
	print("app connected")
	# what the editor sends to start profiling: [command, thread id, data]; the servers profiler's options are
	# the script functions kept per frame and whether native calls are counted on their own
	await create_timer(3.0).timeout
	peer.put_var(["profiler:servers", 1, [true, [1000, true]]])
	var names := {}      # signature id -> "path::line::function"
	var self_us := {}    # signature id -> summed self time
	var total_us := {}
	var calls := {}
	var frames := 0
	var frame_time := 0.0
	var script_time := 0.0
	var t0 := Time.get_ticks_msec()
	var buffer := PackedByteArray()
	while Time.get_ticks_msec() - t0 < seconds * 1000:
		await process_frame
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			print("app went away")
			break
		var n := peer.get_available_bytes()
		if n > 0:
			buffer.append_array(peer.get_data(n)[1])
		# messages: 4 byte little endian size, then the encoded Variant
		while buffer.size() >= 4:
			var size := buffer.decode_u32(0)
			if buffer.size() < 4 + size:
				break
			var msg = bytes_to_var(buffer.slice(4, 4 + size))
			buffer = buffer.slice(4 + size)
			if not (msg is Array and msg.size() == 3):
				continue
			var data: Array = msg[2]
			match msg[0]:
				"servers:function_signature":
					names[data[1]] = data[0]
				"servers:profile_frame":
					frames += 1
					frame_time += float(data[1])
					script_time += float(data[5])
					# after six times and the server count, each server: name, value count, its (name, time) values
					var i := 7
					for s in int(data[6]):
						i += 2 + int(data[i + 1])
					var fn_values := int(data[i])
					i += 1
					for k in fn_values / 5:
						var id = data[i]
						calls[id] = calls.get(id, 0) + int(data[i + 1])
						self_us[id] = self_us.get(id, 0.0) + float(data[i + 2])
						total_us[id] = total_us.get(id, 0.0) + float(data[i + 3])
						i += 5
	peer.put_var(["profiler:servers", 1, [false]])
	peer.poll()
	if frames == 0:
		print("no profile frames came")
		quit(1)
		return
	print("%d frames, frame time %.2f ms, script time %.2f ms per frame (as Godot counts them)" % [
		frames, frame_time / frames * 1000.0, script_time / frames * 1000.0])
	var ids := self_us.keys()
	ids.sort_custom(func (a, b): return self_us[a] > self_us[b])
	print("%-90s %9s %9s %8s" % ["function (by self time)", "self ms", "total ms", "calls"])
	for id in ids.slice(0, top):
		print("%-90s %9.3f %9.3f %8.1f" % [str(names.get(id, id)).right(90), self_us[id] / frames * 1000.0,
			total_us[id] / frames * 1000.0, float(calls[id]) / frames])
	quit()
