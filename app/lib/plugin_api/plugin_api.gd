## Plugin API: a WebSocket server on 127.0.0.1:8001 that speaks the JSON message format VTuber plugins
## already use (apiName "VTubeStudioPublicAPI", messageType "<Name>Request" -> "<Name>Response" or "APIError"),
## so existing plugins connect without changes. Off until switched on in Settings.
## A plugin asks for a token once (AuthenticationTokenRequest), the user allows or denies it on a card in the
## main window, then the plugin authenticates each session with that token.
## Supported: status, statistics, folders, current/available/load model, move model, hotkeys (list, trigger),
## expressions (state, activate), input and Live2D parameters, creating/deleting custom parameters,
## injecting parameter values, face found.
extends Node

const PluginInput = preload("./plugin_input.gd")

const PORT = 8001
const API_NAME = "VTubeStudioPublicAPI"
const API_VERSION = "1.0"
const STATE = "user://plugin_api.cfg"
const CUSTOM_GROUP = "Plugins"

## error ids of the public API
const ERR_INTERNAL = 0
const ERR_API_NAME = 1
const ERR_API_VERSION = 2
const ERR_REQUEST_ID = 3
const ERR_TYPE_MISSING = 4
const ERR_TYPE_UNKNOWN = 5
const ERR_NEEDS_AUTH = 8
const ERR_TOKEN_DENIED = 50
const ERR_TOKEN_ONGOING = 51
const ERR_PLUGIN_NAME = 52
const ERR_PLUGIN_DEVELOPER = 53
const ERR_PLUGIN_ICON = 54
const ERR_NO_MODEL = 100
const ERR_MODEL_ID = 150
const ERR_HOTKEY = 200
const ERR_EXPRESSION = 450
const ERR_PARAMETER_NAME = 350
const ERR_PARAMETER_EXISTS = 352
const ERR_PARAMETER_NOT_FOUND = 353
const ERR_PARAMETER_DEFAULT = 354
const ERR_INJECT = 453

## a plugin is waiting for the user's answer: {name, developer, icon (Texture2D or null)}
signal approval_requested(plugin: Dictionary)
## the card was answered or the plugin went away
signal approval_finished
signal enabled_changed(on: bool)

var enabled := false:
	set(on):
		if on == enabled:
			return
		enabled = on
		_cfg.set_value("api", "enabled", on)
		_cfg.save(STATE)
		_listen()
		enabled_changed.emit(on)
## why the server is not listening ("" when it is, or when it is switched off)
var error := ""

var _cfg := ConfigFile.new()
var _server := TCPServer.new()
## {peer: WebSocketPeer, authenticated, plugin, developer}
var _sessions: Array[Dictionary] = []
## the token request waiting for the user: {session, request}
var _pending := {}
var _input: PluginInput
var _started := Time.get_ticks_msec()
## "live2dparameterlist" -> "_on_live2d_parameter_list" (to_snake_case splits "Live2D" differently)
var _handlers := {}

func _ready() -> void:
	for m in get_method_list():
		if m.name.begins_with("_on_"):
			_handlers[m.name.trim_prefix("_on_").replace("_", "")] = m.name
	_cfg.load(STATE)
	for p in _custom_parameters():
		var c: Dictionary = _custom_parameters()[p]
		Registry.add_parameter(p, Vector2(c.min, c.max), c.default, CUSTOM_GROUP)
	enabled = bool(_cfg.get_value("api", "enabled", false))

func _listen() -> void:
	for s in _sessions:
		s.peer.close()
	_sessions.clear()
	_server.stop()
	error = ""
	if not enabled:
		return
	var e := _server.listen(PORT, "127.0.0.1")
	if e != OK:
		error = "Port %d is in use by another program." % PORT
		push_warning("[plugin api] cannot listen on %d: %s" % [PORT, error_string(e)])

func is_listening() -> bool:
	return _server.is_listening()

## plugins the user allowed: [{token, name, developer}]
func allowed_plugins() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for t in _cfg.get_value("api", "tokens", {}):
		var p: Dictionary = _cfg.get_value("api", "tokens", {})[t]
		out.append({"token": t, "name": p.name, "developer": p.developer})
	return out

func revoke(token: String) -> void:
	var tokens: Dictionary = _cfg.get_value("api", "tokens", {})
	tokens.erase(token)
	_cfg.set_value("api", "tokens", tokens)
	_cfg.save(STATE)

## the user's answer on the approval card
func answer(allow: bool) -> void:
	if _pending.is_empty():
		return
	var s: Dictionary = _pending.session
	var req: Dictionary = _pending.request
	_pending = {}
	approval_finished.emit()
	if s not in _sessions:
		return
	if not allow:
		_error(s, req, ERR_TOKEN_DENIED, "The user denied this plugin.")
		return
	var token := Crypto.new().generate_random_bytes(32).hex_encode()
	var tokens: Dictionary = _cfg.get_value("api", "tokens", {})
	tokens[token] = {"name": req.data.pluginName, "developer": req.data.pluginDeveloper}
	_cfg.set_value("api", "tokens", tokens)
	_cfg.save(STATE)
	_reply(s, req, "AuthenticationTokenResponse", {"authenticationToken": token})

func _process(_delta: float) -> void:
	if not _server.is_listening():
		return
	while _server.is_connection_available():
		var peer := WebSocketPeer.new()
		peer.inbound_buffer_size = 1 << 20  # plugin icons come as base64 PNG
		peer.accept_stream(_server.take_connection())
		_sessions.append({"peer": peer, "authenticated": false, "plugin": "", "developer": ""})
	for s in _sessions.duplicate():
		var peer: WebSocketPeer = s.peer
		peer.poll()
		match peer.get_ready_state():
			WebSocketPeer.STATE_CLOSED:
				_sessions.erase(s)
				if not _pending.is_empty() and _pending.session == s:
					_pending = {}
					approval_finished.emit()
			WebSocketPeer.STATE_OPEN:
				while peer.get_available_packet_count() > 0:
					_handle(s, peer.get_packet().get_string_from_utf8())

func _handle(s: Dictionary, text: String) -> void:
	var req = JSON.parse_string(text)
	if not req is Dictionary:
		_error(s, {}, ERR_INTERNAL, "The message is not a JSON object.")
		return
	if req.get("apiName") != API_NAME:
		_error(s, req, ERR_API_NAME, "apiName must be %s." % API_NAME)
		return
	if str(req.get("apiVersion", "")) != API_VERSION:
		_error(s, req, ERR_API_VERSION, "apiVersion must be %s." % API_VERSION)
		return
	if req.has("requestID") and not req.requestID is String:
		_error(s, req, ERR_REQUEST_ID, "requestID must be a string.")
		return
	var type: String = str(req.get("messageType", ""))
	if type.is_empty():
		_error(s, req, ERR_TYPE_MISSING, "messageType is missing.")
		return
	if not req.get("data") is Dictionary:
		req.data = {}
	var name := type.trim_suffix("Request")
	var handler: String = _handlers.get(name.to_lower(), "")
	if not type.ends_with("Request") or handler.is_empty():
		_error(s, req, ERR_TYPE_UNKNOWN, "%s is not supported by Yorishiro." % type)
		return
	if name not in ["APIState", "AuthenticationToken", "Authentication"] and not s.authenticated:
		_error(s, req, ERR_NEEDS_AUTH, "Authenticate first.")
		return
	var data = call(handler, s, req)
	if data is Dictionary:
		_reply(s, req, name + "Response", data)

func _reply(s: Dictionary, req: Dictionary, type: String, data: Dictionary) -> void:
	var peer: WebSocketPeer = s.peer
	if peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	peer.send_text(JSON.stringify({
		"apiName": API_NAME,
		"apiVersion": API_VERSION,
		"timestamp": int(Time.get_unix_time_from_system() * 1000),
		"requestID": str(req.get("requestID", "")),
		"messageType": type,
		"data": data,
	}))

## handlers return null after sending an error
func _error(s: Dictionary, req: Dictionary, id: int, message: String) -> Variant:
	_reply(s, req, "APIError", {"errorID": id, "message": message})
	return null

# --- session ---

func _on_api_state(s: Dictionary, _req: Dictionary):
	return {"active": true, "vTubeStudioVersion": _version(), "currentSessionAuthenticated": s.authenticated}

func _on_authentication_token(s: Dictionary, req: Dictionary):
	var d: Dictionary = req.data
	var plugin := str(d.get("pluginName", ""))
	var developer := str(d.get("pluginDeveloper", ""))
	if plugin.length() < 3 or plugin.length() > 32:
		return _error(s, req, ERR_PLUGIN_NAME, "pluginName must be 3 to 32 characters.")
	if developer.length() < 3 or developer.length() > 32:
		return _error(s, req, ERR_PLUGIN_DEVELOPER, "pluginDeveloper must be 3 to 32 characters.")
	if not _pending.is_empty():
		return _error(s, req, ERR_TOKEN_ONGOING, "Another plugin is waiting for the user's answer.")
	var icon: Texture2D = null
	if d.get("pluginIcon"):
		var img := Image.new()
		if img.load_png_from_buffer(Marshalls.base64_to_raw(str(d.pluginIcon))) != OK:
			return _error(s, req, ERR_PLUGIN_ICON, "pluginIcon must be a base64 PNG.")
		icon = ImageTexture.create_from_image(img)
	_pending = {"session": s, "request": req}
	approval_requested.emit({"name": plugin, "developer": developer, "icon": icon})
	return null

func _on_authentication(s: Dictionary, req: Dictionary):
	var d: Dictionary = req.data
	var p = _cfg.get_value("api", "tokens", {}).get(str(d.get("authenticationToken", "")))
	var ok: bool = p != null and p.name == str(d.get("pluginName", "")) and p.developer == str(d.get("pluginDeveloper", ""))
	s.authenticated = ok
	if ok:
		s.plugin = p.name
		s.developer = p.developer
	return {"authenticated": ok, "reason": "Token valid." if ok else "Token invalid or not allowed by the user."}

func _on_statistics(_s: Dictionary, _req: Dictionary):
	var size := DisplayServer.window_get_size()
	return {
		"uptime": Time.get_ticks_msec() - _started,
		"framerate": int(Engine.get_frames_per_second()),
		"vTubeStudioVersion": _version(),
		"allowedPlugins": allowed_plugins().size(),
		"connectedPlugins": _sessions.filter(func (x): return x.authenticated).size(),
		"startedWithSteam": false,
		"windowWidth": size.x,
		"windowHeight": size.y,
		"windowIsFullscreen": DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN,
	}

func _on_vts_folder_info(_s: Dictionary, _req: Dictionary):
	return {"models": "Live2DModels", "backgrounds": "Backgrounds", "items": "Items", "config": "", "logs": "logs", "backup": ""}

# --- models ---

func _on_current_model(_s: Dictionary, _req: Dictionary):
	var m = _model()
	if m == null:
		return {"modelLoaded": false, "modelName": "", "modelID": "", "vtsModelName": "", "vtsModelIconName": "",
			"live2DModelName": "", "modelLoadTime": 0, "timeSinceModelLoaded": 0, "numberOfLive2DParameters": 0,
			"numberOfLive2DArtmeshes": 0, "hasPhysicsFile": false, "numberOfTextures": 0, "textureResolution": 0,
			"modelPosition": {"positionX": 0, "positionY": 0, "rotation": 0, "size": 0}}
	var path: String = m.modelmeta.model
	return {
		"modelLoaded": true,
		"modelName": _model_name(path),
		"modelID": _model_id(path),
		"vtsModelName": path.get_file().get_basename().get_basename() + ".vtube.json",
		"vtsModelIconName": "",
		"live2DModelName": path.get_file(),
		"modelLoadTime": 0,
		"timeSinceModelLoaded": 0,
		"numberOfLive2DParameters": m.get_parameters().size(),
		"numberOfLive2DArtmeshes": m.get_meshes().size() if m.has_method("get_meshes") else 0,
		"hasPhysicsFile": "physics_groups" in m and not m.physics_groups.is_empty(),
		"numberOfTextures": 0,
		"textureResolution": 0,
		"modelPosition": _position_of(m),
	}

func _on_available_models(_s: Dictionary, _req: Dictionary):
	var m = _model()
	var current: String = ProjectSettings.globalize_path(m.modelmeta.model) if m else ""
	var models := ModelLibrary.list().map(func (x): return {
		"modelLoaded": ProjectSettings.globalize_path(x.path) == current,
		"modelName": x.name,
		"modelID": _model_id(x.path),
		"vtsModelName": x.path.get_file().get_basename().get_basename() + ".vtube.json",
		"vtsModelIconName": "",
	})
	return {"numberOfModels": models.size(), "availableModels": models}

func _on_model_load(s: Dictionary, req: Dictionary):
	var id := str(req.data.get("modelID", ""))
	for x in ModelLibrary.list():
		if _model_id(x.path) == id:
			ModelLibrary.open(x.path)
			return {"modelID": id}
	return _error(s, req, ERR_MODEL_ID, "No model with this modelID.")

func _on_move_model(s: Dictionary, req: Dictionary):
	var m = _model()
	if m == null:
		return _error(s, req, ERR_NO_MODEL, "No model is loaded.")
	var d: Dictionary = req.data
	var seconds := clampf(float(d.get("timeInSeconds", 0.0)), 0.0, 2.0)
	var relative := bool(d.get("valuesAreRelativeToModel", false))
	var view: Vector2 = m.get_viewport().get_visible_rect().size
	var pos: Vector2 = m.position
	var rot: float = m.rotation_degrees
	var scl: float = m.scale.x
	if d.get("positionX") != null:
		var x := float(d.positionX) * view.x / 2.0
		pos.x = pos.x + x if relative else view.x / 2.0 + x
	if d.get("positionY") != null:
		var y := -float(d.positionY) * view.y / 2.0
		pos.y = pos.y + y if relative else view.y / 2.0 + y
	if d.get("rotation") != null:
		rot = rot + float(d.rotation) if relative else float(d.rotation)
	if d.get("size") != null:
		scl = scl * _size_to_scale(float(d.size)) if relative else _size_to_scale(float(d.size))
	if seconds <= 0.0:
		m.position = pos
		m.rotation_degrees = rot
		m.scale = Vector2.ONE * scl
	else:
		var t: Tween = m.create_tween().set_parallel().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		t.tween_property(m, "position", pos, seconds)
		t.tween_property(m, "rotation_degrees", rot, seconds)
		t.tween_property(m, "scale", Vector2.ONE * scl, seconds)
	return {}

# --- hotkeys and expressions ---

func _on_hotkeys_in_current_model(_s: Dictionary, _req: Dictionary):
	var m = _model()
	var keys := []
	if m:
		for h in _hotkeys(m):
			keys.append({"name": h.name, "type": h.type, "description": h.description, "file": h.file,
				"hotkeyID": h.id, "keyCombination": h.keys, "onScreenButtonID": h.button})
	return {"modelLoaded": m != null, "modelName": _model_name(m.modelmeta.model) if m else "",
		"modelID": _model_id(m.modelmeta.model) if m else "", "availableHotkeys": keys}

func _on_hotkey_trigger(s: Dictionary, req: Dictionary):
	var m = _model()
	if m == null:
		return _error(s, req, ERR_NO_MODEL, "No model is loaded.")
	var want := str(req.data.get("hotkeyID", ""))
	for h in _hotkeys(m):
		if h.id == want or h.name == want:
			h.source.slot_updated.emit(0)  # a press, like the key or the on-screen button
			return {"hotkeyID": h.id}
	return _error(s, req, ERR_HOTKEY, "No hotkey with this hotkeyID or name in the current model.")

func _on_expression_state(s: Dictionary, req: Dictionary):
	var m = _model()
	if m == null or not m.has_method("get_expression_controller"):
		return {"modelLoaded": false, "modelName": "", "modelID": "", "expressions": []}
	var controller = m.get_expression_controller()
	var only := _expression_name(str(req.data.get("expressionFile", "")))
	var used := {}
	for h in _hotkeys(m):
		if h.type == "ToggleExpression":
			used.get_or_add(h.expression, []).append(h.name)
	var out := []
	for x in controller.expressions:
		var n: String = x.get_name()
		if only and n != only:
			continue
		out.append({"name": n, "file": n + ".exp3.json", "active": controller.is_activated(StringName(n)),
			"deactivateWhenKeyIsLetGo": false, "autoDeactivateAfterSeconds": false, "secondsRemaining": 0,
			"usedInHotkeys": used.get(n, []), "parameters": []})
	if only and out.is_empty():
		return _error(s, req, ERR_EXPRESSION, "No expression %s in the current model." % only)
	return {"modelLoaded": true, "modelName": _model_name(m.modelmeta.model), "modelID": _model_id(m.modelmeta.model), "expressions": out}

func _on_expression_activation(s: Dictionary, req: Dictionary):
	var m = _model()
	if m == null or not m.has_method("get_expression_controller"):
		return _error(s, req, ERR_NO_MODEL, "No model is loaded.")
	var controller = m.get_expression_controller()
	var n := _expression_name(str(req.data.get("expressionFile", "")))
	if not (controller.expressions as Array).any(func (x): return x.get_name() == n):
		return _error(s, req, ERR_EXPRESSION, "No expression %s in the current model." % n)
	var fade := clampf(float(req.data.get("fadeTime", 0.25)), 0.0, 2.0)
	var t: Tween = controller.create_tween()
	t.tween_property(controller, "weight/%s" % n, 1.0 if bool(req.data.get("active", true)) else 0.0, fade)
	return {}

# --- parameters ---

func _on_input_parameter_list(_s: Dictionary, _req: Dictionary):
	var m = _model()
	var custom := []
	var defaults := []
	var values: Dictionary = _tracking().parameters if _tracking() else {}
	var mine := _custom_parameters()
	for p in Registry.parameters():
		if p.id == "unset":
			continue
		var entry := {"name": p.id, "addedBy": mine[p.id].addedBy if p.id in mine else "Yorishiro",
			"value": values.get(p.id, p.default_value), "min": p.range.x, "max": p.range.y, "defaultValue": p.default_value}
		(custom if p.id in mine else defaults).append(entry)
	return {"modelLoaded": m != null, "modelName": _model_name(m.modelmeta.model) if m else "",
		"modelID": _model_id(m.modelmeta.model) if m else "", "customParameters": custom, "defaultParameters": defaults}

func _on_parameter_value(s: Dictionary, req: Dictionary):
	var id := str(req.data.get("name", ""))
	var p = Registry.get(id)
	if p == null or id == "unset":
		return _error(s, req, ERR_PARAMETER_NOT_FOUND, "No input parameter %s." % id)
	var mine := _custom_parameters()
	return {"name": id, "addedBy": mine[id].addedBy if id in mine else "Yorishiro",
		"value": _tracking().parameters.get(id, p.default_value) if _tracking() else p.default_value,
		"min": p.range.x, "max": p.range.y, "defaultValue": p.default_value}

func _on_live2d_parameter_list(_s: Dictionary, _req: Dictionary):
	var m = _model()
	if m == null:
		return {"modelLoaded": false, "modelName": "", "modelID": "", "parameters": []}
	var params := []
	var all: Dictionary = m.get_parameters()
	for id in all:
		var r = all[id].range
		var value = m.model.get("output/parameters/%s" % id) if "model" in m else null
		params.append({"name": id, "value": float(value) if value != null else float(all[id].default),
			"min": r.x if r is Vector2 else 0.0, "max": r.y if r is Vector2 else 1.0, "defaultValue": float(all[id].default)})
	return {"modelLoaded": true, "modelName": _model_name(m.modelmeta.model), "modelID": _model_id(m.modelmeta.model), "parameters": params}

func _on_parameter_creation(s: Dictionary, req: Dictionary):
	var d: Dictionary = req.data
	var id := str(d.get("parameterName", ""))
	var valid := RegEx.create_from_string("^[A-Za-z0-9]{4,32}$")
	if valid.search(id) == null:
		return _error(s, req, ERR_PARAMETER_NAME, "parameterName must be 4 to 32 letters or digits.")
	var mine := _custom_parameters()
	if Registry.get(id) != null and (id not in mine or mine[id].addedBy != s.plugin):
		return _error(s, req, ERR_PARAMETER_EXISTS, "A parameter %s already exists." % id)
	var lo := float(d.get("min", 0.0))
	var hi := float(d.get("max", 1.0))
	var default := float(d.get("defaultValue", 0.0))
	if lo >= hi or default < lo or default > hi:
		return _error(s, req, ERR_PARAMETER_DEFAULT, "min must be below max and defaultValue between them.")
	mine[id] = {"addedBy": s.plugin, "min": lo, "max": hi, "default": default, "explanation": str(d.get("explanation", ""))}
	_cfg.set_value("api", "parameters", mine)
	_cfg.save(STATE)
	Registry.add_parameter(id, Vector2(lo, hi), default, CUSTOM_GROUP)
	return {"parameterName": id}

func _on_parameter_deletion(s: Dictionary, req: Dictionary):
	var id := str(req.data.get("parameterName", ""))
	var mine := _custom_parameters()
	if id not in mine or mine[id].addedBy != s.plugin:
		return _error(s, req, ERR_PARAMETER_NOT_FOUND, "%s is not a parameter this plugin created." % id)
	mine.erase(id)
	_cfg.set_value("api", "parameters", mine)
	_cfg.save(STATE)
	if Registry.has_method("remove_parameter"):
		Registry.remove_parameter(id)
	return {"parameterName": id}

func _on_inject_parameter_data(s: Dictionary, req: Dictionary):
	var input := _plugin_input()
	if input == null:
		return _error(s, req, ERR_INJECT, "Tracking is not running.")
	var add := str(req.data.get("mode", "set")) == "add"
	var values = req.data.get("parameterValues", [])
	if not values is Array:
		return _error(s, req, ERR_INJECT, "parameterValues must be a list.")
	for v in values:
		var id := str(v.get("id", "")) if v is Dictionary else ""
		if Registry.get(id) == null or id == "unset":
			return _error(s, req, ERR_PARAMETER_NOT_FOUND, "No input parameter %s." % id)
	for v in values:
		var w = v.get("weight")
		input.inject(str(v.id), float(v.get("value", 0.0)), 1.0 if w == null else float(w), add)
	return {}

func _on_face_found(_s: Dictionary, _req: Dictionary):
	var t = _tracking()
	return {"found": t.face_present if t else false}

# --- helpers ---

func _version() -> String:
	return "Yorishiro %s" % ProjectSettings.get_setting("application/config/version", "dev")

func _model():
	var stage = get_tree().get_first_node_in_group("system:stage")
	return stage.active_model if stage and stage.active_model and stage.active_model.modelmeta else null

func _tracking():
	return get_tree().get_first_node_in_group("system:tracking")

func _plugin_input() -> PluginInput:
	var t = _tracking()
	if t == null:
		return null
	if not is_instance_valid(_input) or _input.get_parent() != t:
		_input = PluginInput.new()
		t.add_child(_input)
	else:
		t.move_child(_input, -1)  # after any tracker added since
	return _input

func _custom_parameters() -> Dictionary:
	return _cfg.get_value("api", "parameters", {})

## stable across sessions: from the model file's path inside the data folder
func _model_id(path: String) -> String:
	return ProjectSettings.localize_path(ProjectSettings.globalize_path(path)).md5_text().substr(0, 16)

func _model_name(path: String) -> String:
	return path.get_file().get_basename().get_basename()

func _expression_name(file: String) -> String:
	return file.trim_suffix(".json").trim_suffix(".exp3")

## size runs from -100 to 100 in the protocol; 0 is the model's own size, every 50 doubles or halves it
func _size_to_scale(size: float) -> float:
	return pow(2.0, clampf(size, -100.0, 100.0) / 50.0)

func _position_of(m) -> Dictionary:
	var view: Vector2 = m.get_viewport().get_visible_rect().size
	return {
		"positionX": (m.position.x - view.x / 2.0) / (view.x / 2.0),
		"positionY": -(m.position.y - view.y / 2.0) / (view.y / 2.0),
		"rotation": m.rotation_degrees,
		"size": clampf(log(maxf(m.scale.x, 0.0001)) / log(2.0) * 50.0, -100.0, 100.0),
	}

## every hotkey and on-screen button of the model's node graphs with what it triggers
func _hotkeys(m) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for gi in m.blueprints.size():
		var graph = m.blueprints[gi]
		for src in graph.get_children():
			if not src.has_method("get_type") or src.get_type() not in [&"hotkey", &"screen_button"]:
				continue
			var target = null
			for c in graph.connections:
				if c.from_node == src.name:
					target = graph.get_node_or_null(NodePath(c.to_node))
					if target:
						break
			if target == null or not target.has_method("get_type"):
				continue
			var h := {"id": "%d-%s" % [gi, src.id], "source": src, "file": "", "expression": "", "description": "",
				"keys": [], "button": -1, "type": "Unset", "name": ""}
			if src.get_type() == &"hotkey":
				h.keys = Array(src.get_node("%Handler").input_as_list)
			else:
				var buttons: Array = src.get_node("%Mapping").get_children()
				h.button = buttons.find_custom(func (b): return b.button_pressed) + 1
			match target.get_type():
				&"expression":
					h.type = "ToggleExpression"
					h.expression = target.expression
					h.file = target.expression + ".exp3.json"
					h.name = target.expression
				&"animation":
					var anim: OptionButton = target.get_node("%Animation")
					h.type = "TriggerAnimation"
					h.name = anim.get_item_text(anim.selected) if anim.selected >= 0 else ""
					h.file = h.name
				&"app_action":
					h.type = {&"position": "MoveModel", &"background": "ChangeBackground", &"model": "ChangeVTSModel",
						&"item": "ToggleItemScene", &"reload": "ReloadTextures", &"screenshot": "TakeScreenshot"}.get(target.action, "Unset")
					h.name = target.short_label()
				_:
					h.name = str(target.get_type())
			h.description = h.type
			out.append(h)
	return out
