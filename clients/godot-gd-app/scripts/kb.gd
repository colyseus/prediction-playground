class_name Kb
## WASD / arrows -> tri-state axes, exactly like framework/input.ts. Held
## state polls the engine; edge state ("pressed this frame") is fed by the
## shell from _unhandled_input and cleared at end of frame. The acceptance
## harness feeds the same accessors, so a lab never learns whether a human or
## a script is playing.

static var autopilot := false
static var auto_x := 0
static var auto_y := 0

## Pointer position in viewport coords — set by the shell each frame.
static var mouse_pos := Vector2.ZERO

static var _frame := {}
static var _mouse_down := false

static func feed(e: InputEventKey) -> void:
	if e.pressed and not e.echo:
		_frame[e.physical_keycode if e.physical_keycode != KEY_NONE else e.keycode] = true

static func feed_mouse(e: InputEventMouseButton) -> void:
	if e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		_mouse_down = true

## Left button pressed this frame (edge).
static func mouse_down() -> bool:
	return _mouse_down

static func end_frame() -> void:
	_frame.clear()
	_mouse_down = false

static func key(k: Key) -> bool:
	return _frame.has(k)

static func move_x() -> int:
	if autopilot: return auto_x
	var l := Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT)
	var r := Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT)
	if r == l: return 0
	return 1 if r else -1

static func move_y() -> int:
	if autopilot: return auto_y
	var u := Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP)
	var d := Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN)
	if d == u: return 0
	return 1 if d else -1

static func any_move() -> bool:
	return move_x() != 0 or move_y() != 0
