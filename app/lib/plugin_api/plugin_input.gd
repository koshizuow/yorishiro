## Tracking input from plugins (InjectParameterDataRequest). It sits after the face tracker under the tracking
## system, so "add" values and weights apply on top of what the trackers before it reported this frame.
## A value holds for HOLD_SECONDS after its last injection, then the tracker's own value comes back.
extends "res://lib/tracking/tracker.gd"

const HOLD_SECONDS = 1.0

## id -> {value, weight, add, until}
var _injected := {}

func _init() -> void:
	name = "PluginInput"

func inject(id: String, value: float, weight: float, add: bool) -> void:
	_injected[id] = {"value": value, "weight": clampf(weight, 0.0, 1.0), "add": add,
		"until": Time.get_ticks_msec() + int(HOLD_SECONDS * 1000)}

func parameters(_time: float = Clock.msec()) -> Dictionary:
	var out := {}
	var now := Time.get_ticks_msec()
	var before: Dictionary = get_parent().parameters  # what the trackers before this one reported
	for id in _injected.keys():
		var p: Dictionary = _injected[id]
		if now > p.until:
			_injected.erase(id)
			continue
		var current: float = before.get(id, Registry.get_default(id))
		var target: float = current + p.value if p.add else p.value
		out[id] = lerpf(current, target, p.weight)
	return out
