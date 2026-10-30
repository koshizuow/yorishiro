## Interpolated Tracker adds a degree of smoothing between values each frame
## Useful for tracking sources that have unstable intervals in which data is received,
## such as network based tracking.
extends "./tracker.gd"

var _previous = {}
var _previous_msec: float = Clock.msec()
var _latest_msec: float = Clock.msec()

var fps: float = 0.0

@export_range(0.0, 1.0) var smoothing: float = 0.2

## get fps blended parameters for stabilization
func parameters(time: float = Clock.msec()) -> Dictionary:
	# blend ranges based on sample rate
	# we always blend with a 1 update delay
	# two updates in the same millisecond made this 0 / 0, and the NaN stuck in every smoothing node after it
	var interval := _latest_msec - _previous_msec
	var progress: float = 1.0 if interval <= 0.0 else clampf((time - _latest_msec) / interval, 0.0, 1.0)
	#progress = 1.0
	
	var output = {}
	
	for p in _parameters:
		output[p] = lerp(
			float(_previous.get(p, _parameters[p])),
			float(_parameters[p]),
			progress
		)
	
	return output
	
func update(updated_parameters: Dictionary):
	var now: float = Clock.msec()
	_previous = _parameters
	_previous_msec = _latest_msec
	_latest_msec = now
	_parameters = _previous.duplicate()

	for p in updated_parameters:
		_parameters[p] = lerp(
			float(_previous.get(p, 0)),
			float(updated_parameters[p]),
			1.0 - smoothing
		)
	
	# estimate avg sample rate
	if _latest_msec > _previous_msec:
		var delta = 1.0 / ((_latest_msec - _previous_msec) / 1000.0)
		fps += delta
		fps /= 2.0
