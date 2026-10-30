extends Node

const Clock = preload("res://lib/utils/clock.gd")

var _parameters = {}

func create_config() -> Node:
	return null
	
func reset():
	update({})

func parameters(_time: float = Clock.msec()) -> Dictionary:
	return _parameters

func update(updated_parameters: Dictionary):
	for p in updated_parameters:
		_parameters[p] = float(updated_parameters[p])
