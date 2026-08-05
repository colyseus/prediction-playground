class_name Trail
## A bounded ring of world-space points, drawn as a fading polyline. Motion
## history is what makes a lag/prediction difference legible in a still frame.

var _pts: PackedVector2Array
var _head := 0
var _count := 0

func _init(capacity: int) -> void:
	_pts.resize(capacity)

func push(x: float, y: float) -> void:
	_pts[_head] = Vector2(x, y)
	_head = (_head + 1) % _pts.size()
	if _count < _pts.size(): _count += 1

func clear() -> void:
	_head = 0
	_count = 0

func render(v: WorldView, col: Color, width := 1.5, max_alpha := 0.4) -> void:
	var n := _pts.size()
	for i in range(1, _count):
		var a := _pts[(_head - _count + i - 1 + n * 2) % n]
		var b := _pts[(_head - _count + i + n * 2) % n]
		Draw.line(Vector2(v.sx(a.x), v.sy(a.y)), Vector2(v.sx(b.x), v.sy(b.y)),
			Palette.a(col, max_alpha * i / _count), width)
