class_name Hud
## Immediate-mode side panel: telemetry rows, sparklines, pending-input chips,
## and the keyboard "controls" list that stands in for the web build's sliders.

var _x := 0.0
var _y := 0.0
var _w := 0.0
var _cursor := 0.0

func begin(x: float, y: float, w: float) -> void:
	_x = x
	_y = y
	_w = w
	_cursor = y

func section(title: String) -> void:
	_cursor += 10
	Draw.text(_x, _cursor, _w, title, Palette.TEXT_FAINT, 10)
	_cursor += 14
	Draw.rect(Rect2(_x, _cursor, _w, 1), Palette.BORDER)
	_cursor += 6

func row(label: String, value: String, value_color: Color) -> void:
	Draw.text(_x, _cursor, _w, label, Palette.TEXT_DIM, 12)
	Draw.text(_x, _cursor, _w, value, value_color, 12, HORIZONTAL_ALIGNMENT_RIGHT)
	_cursor += 18

func key(k: String, what: String) -> void:
	Draw.rect(Rect2(_x, _cursor - 1, 58, 15), Palette.INSET)
	Draw.text(_x + 4, _cursor - 2, 60, k, Palette.TEXT, 10)
	Draw.text(_x + 64, _cursor - 2, _w - 64, what, Palette.TEXT_DIM, 10)
	_cursor += 17

func note(text: String) -> void:
	var h := Draw.text_wrapped(_x, _cursor, _w, text, Palette.TEXT_FAINT, 10)
	_cursor += h + 6

## One chip per pending (unacked) input — drains as acks land.
func chips(label: String, n: int, mx := 48) -> void:
	row(label, str(n), Palette.ACCENT)
	var cx := _x
	var cy := _cursor
	for i in mini(n, mx):
		Draw.rect(Rect2(cx, cy, 5, 10), Palette.a(Palette.ACCENT, 0.75))
		cx += 7
		if cx + 5 > _x + _w:
			cx = _x
			cy += 12
	_cursor = cy + 18

func spark(s: Spark, label: String, value: String, color: Color, fixed_max := 0.0) -> void:
	row(label, value, color)
	const GH := 30.0
	var box := Rect2(_x, _cursor, _w, GH)
	Draw.rect(box, Palette.INSET)
	s.render(box, color, fixed_max)
	_cursor += GH + 8
