class_name Smoothness
## Coefficient of variation of rendered per-frame speed — the "limp" metric
## lab 04 scores its interpolation modes with. Constant speed scores 0; a mode
## that stutters between stalls and jumps scores high.

# Sized for wall time, not frames — a fast headless run needs the window to
# still span several patches (see godot-app's Series.cs for the war story).
const CAP := 4000
## The window must span several patches before the ratio means anything.
const MIN_WINDOW_MS := 400.0

var _speeds: PackedFloat64Array
var _dts: PackedFloat64Array
var _head := 0
var _count := 0
var _last_x := 0.0
var _last_y := 0.0
var _seeded := false

func _init() -> void:
	_speeds.resize(CAP)
	_dts.resize(CAP)

func clear() -> void:
	_head = 0
	_count = 0
	_seeded = false

func sample(x: float, y: float, dt_ms: float) -> void:
	if _seeded and dt_ms > 0.0:
		var dx := x - _last_x
		var dy := y - _last_y
		_speeds[_head] = sqrt(dx * dx + dy * dy) / dt_ms * 1000.0
		_dts[_head] = dt_ms
		_head = (_head + 1) % CAP
		if _count < CAP: _count += 1
	_last_x = x
	_last_y = y
	_seeded = true

## Why cv() returned what it did — for a failing assertion to quote.
func describe() -> String:
	var span := 0.0
	var mean := 0.0
	for i in _count:
		span += _dts[i]
		mean += _speeds[i]
	if _count > 0: mean /= _count
	return "n=%d span=%.0fms mean=%.2fu/s" % [_count, span, mean]

## NAN until the window is long enough to mean anything.
func cv() -> float:
	if _count < 20: return NAN
	var span := 0.0
	for i in _count: span += _dts[i]
	if span < MIN_WINDOW_MS: return NAN
	var mean := 0.0
	for i in _count: mean += _speeds[i]
	mean /= _count
	if mean < 0.5: return NAN
	var variance := 0.0
	for i in _count: variance += (_speeds[i] - mean) * (_speeds[i] - mean)
	return sqrt(variance / _count) / mean
