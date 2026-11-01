extends GraphEdit

const Serializers = preload("res://lib/utils/serializers.gd")
const VtModel = preload("res://lib/model/vt_model.gd")
const VtAction = preload("./vt_action.gd")

static var _action_types: Array[PackedScene] = [
	preload("res://lib/blueprints/inputs/hotkey_action.tscn"),
	preload("res://lib/blueprints/inputs/screen_button.tscn"),
	preload("res://lib/blueprints/inputs/tracker_input.tscn"),
	preload("res://lib/blueprints/inputs/xr_tracker_input.tscn"),
	preload("res://lib/blueprints/inputs/blink.tscn"),
	preload("res://lib/blueprints/inputs/breathe.tscn"),
	preload("res://lib/blueprints/inputs/value_emitter.tscn"),
	preload("res://lib/blueprints/inputs/metastore_input.tscn"),
	preload("res://lib/blueprints/logic/arithmetic.tscn"),
	preload("res://lib/blueprints/logic/compose.tscn"),
	preload("res://lib/blueprints/logic/decompose.tscn"),
	preload("res://lib/blueprints/logic/evaluator.tscn"),
	preload("res://lib/blueprints/logic/smoothing.tscn"),
	preload("res://lib/blueprints/logic/tweener.tscn"),
	preload("res://lib/blueprints/logic/range_map.tscn"),
	preload("res://lib/blueprints/logic/toggle_state.tscn"),
	preload("res://lib/blueprints/logic/toggle_group.tscn"),
	preload("res://lib/blueprints/outputs/model_output.tscn"),
	preload("res://lib/blueprints/outputs/play_animation.tscn"),
	preload("res://lib/blueprints/outputs/toggle_expression.tscn"),
	preload("res://lib/blueprints/outputs/metastore_output.tscn"),
	preload("res://lib/blueprints/outputs/app_action.tscn"),
]

static var palette: Dictionary[StringName, PackedScene] = _action_types.reduce(
	func (acc, template: PackedScene):
		var action = template.instantiate() as VtAction
		acc[action.get_type()] = template
		action.free()
		return acc,
	{} as Dictionary[StringName, PackedScene]
)

static func create_action(type: StringName) -> VtAction:
	if type in palette:
		var node = palette[type].instantiate()
		return node
	return null
	
func spawn_action(action_type, model: VtModel, initial_parameters: Dictionary = {}) -> VtAction:
	var node: VtAction
	if action_type is VtAction:
		node = action_type
	elif action_type is StringName:
		node = create_action(action_type)
		
	if node == null:
		return null
		
	for i in initial_parameters:
		node.set(i, initial_parameters[i])
		
	if not node.can_spawn(self):
		return null
		
	node.graph = self
	node.model = model
	
	if node.id.is_empty():
		node.id = "%d" % rid_allocate_id()
		
	add_child(node, true)
	node.owner = self
	node.position_offset = (scroll_offset + size / 2) / zoom - node.size / 2
	node.build_slots()
	
	return node

var graph_elements: Dictionary[String, GraphNode] = {}
var enabled: bool = true

func _ready() -> void:
	add_valid_connection_type(VtAction.SlotType.VECTOR, VtAction.SlotType.NUMERIC)

# allow disconnecting using right click
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.is_pressed():
			var connection: Dictionary = self.get_closest_connection_at_point(event.position)
			if connection.is_empty():
				return
			else:
				disconnection_request.emit(
					connection.from_node, connection.from_port,
					connection.to_node, connection.to_port,
				)

func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	if not is_node_ready():
		await self.ready
		
	var n1: VtAction = get_node(NodePath(from_node))
	var n2: VtAction = get_node(NodePath(to_node))
	
	var s1: int = n1.get_output_slot_by_port(from_port)
	var s2: int = n2.get_input_slot_by_port(to_port)
	
	var slot_type = n2.get_input_type(s1)
	# fail to connect
	if slot_type == -1:
		return
		
	var count = get_connection_count(to_node, to_port)
	
	if slot_type not in VtAction.MultiBindSlotTypes and count > 0:
		var disconnected = connections.filter(
			func (f):
				return f.to_node == to_node and f.to_port == to_port
		)
		for i in disconnected:
			disconnect_node(i.from_node, i.from_port, to_node, to_port)
		
	connect_node(from_node, from_port, to_node, to_port)
	invalidate_routes()
	n2.bind(s2, n1)

func _on_disconnection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	disconnect_node(from_node, from_port, to_node, to_port)
	invalidate_routes()

	var source: VtAction = get_node(NodePath(from_node))
	var target: VtAction = get_node(NodePath(to_node))
	if target != null:
		var field = target.get_input_port_slot(to_port)
		target.unbind(field, source)
		target.reset_value(field)

func _on_child_entered_tree(node: Node) -> void:
	if node is not VtAction:
		return
	
	var id = node.id
	assert(not id.is_empty(), "node has invalid id")
	
	graph_elements[id] = node
	node.slot_updated.connect(_on_action.bind(node))
	invalidate_routes()
	
func _on_child_exiting_tree(node: Node) -> void:
	if node is not VtAction:
		return
	
	var id = node.id
	if not id.is_empty() and id in graph_elements:
		graph_elements.erase(id)
	node.slot_updated.disconnect(_on_action.bind(node))
	invalidate_routes()
		
## Where each output port leads: node name -> {port -> [[target, from_slot, output type, to_slot, input type]]}.
## _on_action runs for every value of every node each frame (tens of times), and reading `connections` builds a
## new array of dictionaries each time, so the routes are kept and built again only after the connections or
## nodes change (invalidate_routes(), called wherever the graph is rewired), and once a second in case
## something rewired it without saying so.
var _routes := {}
var _routes_frame := -1
const ROUTES_MAX_AGE_FRAMES := 60

func invalidate_routes() -> void:
	_routes_frame = -1

func _build_routes() -> void:
	_routes = {}
	# not get_connection_list_from_node(): it errors for nodes that were never connected
	for conn in connections:
		var source := get_node_or_null(NodePath(conn.from_node)) as VtAction
		var target := get_node_or_null(NodePath(conn.to_node)) as VtAction
		if source == null or target == null:
			continue
		var from_slot = source.get_output_slot_by_port(conn.from_port)
		var to_slot = target.get_input_slot_by_port(conn.to_port)
		if to_slot == -1:
			continue
		var ports: Dictionary = _routes.get_or_add(conn.from_node, {})
		ports.get_or_add(conn.from_port, []).append([target, from_slot, source.get_output_type(from_slot), to_slot, target.get_input_type(to_slot)])

func _on_action(from_port: int, node: VtAction):
	if not enabled:
		return
	var frame := Engine.get_process_frames()
	if _routes_frame < 0 or frame - _routes_frame >= ROUTES_MAX_AGE_FRAMES:
		_build_routes()
		_routes_frame = frame
	for route in _routes.get(node.name, {}).get(from_port, []):
		var target: VtAction = route[0]
		if not is_instance_valid(target):
			continue
		var from_slot = route[1]
		var output = route[2]
		var to_slot = route[3]
		var input = route[4]
		match output:
			VtAction.SlotType.TRIGGER:
				target.invoke_trigger(to_slot)
			_:
				var value = node.get_value(from_slot)
				if input == VtAction.SlotType.NUMERIC and output == VtAction.SlotType.VECTOR:
					var vec = value as Vector3
					target.update_value(to_slot, vec.z)
				else:
					target.update_value(to_slot, value)

func _on_delete_nodes_request(nodes: Array[StringName]) -> void:
	for i in nodes:
		var n = get_node(NodePath(i))
		n.queue_free()
		
func serialize() -> Dictionary:
	var nodes = []
	var bindings = []
	
	for i in graph_elements.values():
		var node = {
			"id": i.id,
			"type": i.get_type(),
			"position": Serializers.Vec2Serializer.to_json(i.position_offset),
			"parameters": i.serialize(),
		}
		nodes.append(node)
	
	for i in connections:
		var from_node: VtAction = get_node(NodePath(i.from_node))
		var from_id = from_node.id if from_node else -1
		var to_node: VtAction = get_node(NodePath(i.to_node))
		var to_id = to_node.id if to_node else -1
		var from_slot = from_node.get_output_slot_by_port(i.from_port)
		var to_slot = to_node.get_input_slot_by_port(i.to_port)
		var from_name = from_node.get_output_slot_name(from_slot)
		var to_name = to_node.get_input_slot_name(to_slot)
		bindings.append({
			"src": from_id,
			"dst": to_id,
			"src_slot": from_name,
			"dst_slot": to_name,
		})
		
	return {
		"name": self.name,
		"enabled": enabled,
		"nodes": nodes,
		"bindings": bindings,
	}
