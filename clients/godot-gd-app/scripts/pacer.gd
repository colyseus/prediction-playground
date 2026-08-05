class_name Pacer
## Fixed-step accumulator for labs WITHOUT a reconciler: predict.tick() only
## paces once a reconciler adopts the fixed step, but a prediction-free client
## still has to send one input per server tick.

var _acc := 0.0
var _last := 0.0
var _started := false
var _step_ms: float

func _init(step_ms: float) -> void:
	_step_ms = step_ms

func reset() -> void:
	_acc = 0.0
	_started = false

func steps(now: float) -> int:
	if not _started:
		_started = true
		_last = now
		return 0
	_acc += now - _last
	_last = now
	var n := int(_acc / _step_ms)
	if n > 5:
		n = 5      # hitch: drop the backlog
		_acc = 0.0
	else:
		_acc -= n * _step_ms
	return n
