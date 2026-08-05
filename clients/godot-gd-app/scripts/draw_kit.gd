class_name Draw
## Immediate-mode shapes over the CanvasItem being drawn this frame. The shell
## assigns `Draw.c` at the top of _draw(); labs never see the node, only this
## vocabulary — which matches the web build's draw.ts and godot-app's View.cs.

## The CanvasItem currently inside _draw(). Set by the shell.
static var c: CanvasItem

static var _font: Font

static func font() -> Font:
	if _font == null: _font = ThemeDB.fallback_font
	return _font

static func rect(r: Rect2, col: Color) -> void:
	c.draw_rect(r, col)

static func line(a: Vector2, b: Vector2, col: Color, width := 1.0) -> void:
	if (b - a).length_squared() < 0.0001: return
	c.draw_line(a, b, col, width)

static func dashed(a: Vector2, b: Vector2, col: Color, width := 1.0, dash := 4.0, gap := 3.0) -> void:
	var d := b - a
	var len := d.length()
	if len < 0.5: return
	var u := d / len
	var t := 0.0
	while t < len:
		line(a + u * t, a + u * minf(t + dash, len), col, width)
		t += dash + gap

static func square(v: WorldView, x: float, y: float, half: float, fill: Color) -> void:
	var s := v.s(half)
	rect(Rect2(v.sx(x) - s, v.sy(y) - s, s * 2.0, s * 2.0), fill)

static func square_outline(v: WorldView, x: float, y: float, half: float, col: Color, w := 1.0) -> void:
	var s := v.s(half)
	var l := v.sx(x) - s
	var t := v.sy(y) - s
	var r := l + s * 2.0
	var b := t + s * 2.0
	rect(Rect2(l, t, s * 2.0, w), col)
	rect(Rect2(l, b - w, s * 2.0, w), col)
	rect(Rect2(l, t, w, s * 2.0), col)
	rect(Rect2(r - w, t, w, s * 2.0), col)

## Dashed outline "ghost" — the standard raw-server-pose marker.
static func ghost_square(v: WorldView, x: float, y: float, half: float, col: Color) -> void:
	var s := v.s(half)
	var l := v.sx(x) - s
	var t := v.sy(y) - s
	var r := l + s * 2.0
	var b := t + s * 2.0
	dashed(Vector2(l, t), Vector2(r, t), col, 1.5)
	dashed(Vector2(r, t), Vector2(r, b), col, 1.5)
	dashed(Vector2(r, b), Vector2(l, b), col, 1.5)
	dashed(Vector2(l, b), Vector2(l, t), col, 1.5)

static func circle_outline(v: WorldView, x: float, y: float, r: float, col: Color, is_dashed := false) -> void:
	const SEG := 28
	var cx := v.sx(x)
	var cy := v.sy(y)
	var pr := v.s(r)
	var i := 0
	while i < SEG:
		var a0 := i * TAU / SEG
		var a1 := (i + 1) * TAU / SEG
		line(Vector2(cx + cos(a0) * pr, cy + sin(a0) * pr),
			Vector2(cx + cos(a1) * pr, cy + sin(a1) * pr), col, 1.5)
		i += 2 if is_dashed else 1

## Filled disc — bots, pucks, projectiles, pellets.
static func circle(v: WorldView, x: float, y: float, r: float, col: Color) -> void:
	c.draw_circle(Vector2(v.sx(x), v.sy(y)), v.s(r), col)

## A dashed segment between two WORLD points.
static func dashed_world(v: WorldView, x0: float, y0: float, x1: float, y1: float, col: Color, width := 1.0) -> void:
	dashed(Vector2(v.sx(x0), v.sy(y0)), Vector2(v.sx(x1), v.sy(y1)), col, width)

## Screen-space text — lane titles, captions, strip legends.
static func text(x: float, y: float, w: float, s: String, col: Color, size := 11,
		align := HORIZONTAL_ALIGNMENT_LEFT) -> void:
	c.draw_string(font(), Vector2(x, y + font().get_ascent(size)), s, align, w, size, col)

## Word-wrapped screen-space text; returns the height consumed.
static func text_wrapped(x: float, y: float, w: float, s: String, col: Color, size := 11) -> float:
	c.draw_multiline_string(font(), Vector2(x, y + font().get_ascent(size)), s,
		HORIZONTAL_ALIGNMENT_LEFT, w, size, -1, col)
	return font().get_multiline_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, w, size).y

static func arena(v: WorldView) -> void:
	var grid := Palette.a(Palette.TEXT_DIM, 0.10)
	for x in range(10, int(Sim.ARENA_W), 10):
		line(Vector2(v.sx(x), v.sy(0)), Vector2(v.sx(x), v.sy(Sim.ARENA_H)), grid)
	for y in range(10, int(Sim.ARENA_H), 10):
		line(Vector2(v.sx(0), v.sy(y)), Vector2(v.sx(Sim.ARENA_W), v.sy(y)), grid)
	var border := Palette.a(Palette.TEXT_DIM, 0.38)
	line(Vector2(v.sx(0), v.sy(0)), Vector2(v.sx(Sim.ARENA_W), v.sy(0)), border, 1.5)
	line(Vector2(v.sx(0), v.sy(Sim.ARENA_H)), Vector2(v.sx(Sim.ARENA_W), v.sy(Sim.ARENA_H)), border, 1.5)
	line(Vector2(v.sx(0), v.sy(0)), Vector2(v.sx(0), v.sy(Sim.ARENA_H)), border, 1.5)
	line(Vector2(v.sx(Sim.ARENA_W), v.sy(0)), Vector2(v.sx(Sim.ARENA_W), v.sy(Sim.ARENA_H)), border, 1.5)

static func label(v: WorldView, x: float, y: float, s: String, col: Color, size := 11, dy := 0.0) -> void:
	text(v.sx(x) - 90, v.sy(y) + dy, 180, s, col, size, HORIZONTAL_ALIGNMENT_CENTER)
