class_name Spark
## Rolling graph; auto-scales to the window max unless given one.

const CAP := 140

var _data: PackedFloat64Array
var _head := 0
var _count := 0

func _init() -> void:
	_data.resize(CAP)

func push(v: float) -> void:
	_data[_head] = v
	_head = (_head + 1) % CAP
	if _count < CAP: _count += 1

func last() -> float:
	return 0.0 if _count == 0 else _data[(_head - 1 + CAP) % CAP]

func render(box: Rect2, color: Color, fixed_max: float) -> void:
	if _count < 2: return
	var mx := fixed_max
	if mx <= 0.0:
		for i in _count:
			mx = maxf(mx, _data[i])
	if mx <= 0.0: mx = 1e-6
	var start := (_head - _count + CAP * 2) % CAP
	for i in range(1, _count):
		var v0 := _data[(start + i - 1) % CAP]
		var v1 := _data[(start + i) % CAP]
		var x0 := box.position.x + (i - 1) / float(CAP - 1) * box.size.x
		var x1 := box.position.x + i / float(CAP - 1) * box.size.x
		var y0 := box.end.y - 2 - minf(1.0, v0 / mx) * (box.size.y - 4)
		var y1 := box.end.y - 2 - minf(1.0, v1 / mx) * (box.size.y - 4)
		Draw.line(Vector2(x0, y0), Vector2(x1, y1), color)
