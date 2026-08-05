class_name WorldView
## 100x60 world-unit arena letterboxed into a stage rect — port of
## src/client/framework/draw.ts's WorldView (via godot-app's View.cs).

var scale := 1.0
var ox := 0.0
var oy := 0.0
var stage := Rect2()

func fit(stage_rect: Rect2, margin := 28.0) -> void:
	stage = stage_rect
	var fx := (stage_rect.size.x - margin * 2.0) / Sim.ARENA_W
	var fy := (stage_rect.size.y - margin * 2.0) / Sim.ARENA_H
	scale = minf(fx, fy)
	ox = stage_rect.position.x + (stage_rect.size.x - Sim.ARENA_W * scale) / 2.0
	oy = stage_rect.position.y + (stage_rect.size.y - Sim.ARENA_H * scale) / 2.0

func sx(x: float) -> float: return ox + x * scale
func sy(y: float) -> float: return oy + y * scale
func s(len: float) -> float: return len * scale

## Screen -> world, for pointer aiming.
func wx(px: float) -> float: return (px - ox) / scale
func wy(py: float) -> float: return (py - oy) / scale
