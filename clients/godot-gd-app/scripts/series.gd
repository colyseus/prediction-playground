class_name Series
## A bounded ring of (time, value) samples, walked oldest -> newest.

var _t: PackedFloat64Array
var _v: PackedFloat64Array
var _head := 0
var count := 0

func _init(capacity: int) -> void:
	_t.resize(capacity)
	_v.resize(capacity)

func push(t: float, value: float) -> void:
	_t[_head] = t
	_v[_head] = value
	_head = (_head + 1) % _t.size()
	if count < _t.size(): count += 1

func clear() -> void:
	_head = 0
	count = 0

## Walk oldest -> newest: visit.call(t, v).
func for_each(visit: Callable) -> void:
	var n := _t.size()
	var start := (_head - count + n * 2) % n
	for i in count:
		var k := (start + i) % n
		visit.call(_t[k], _v[k])
