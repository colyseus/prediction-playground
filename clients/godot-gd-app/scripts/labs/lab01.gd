class_name Lab01
extends LabBase
## Lab 01 — Feel the Lag. No prediction at all: send one input per fixed
## server tick, render the player straight from decoded state. Every key
## press waits a full round trip, so the L latency presets are what make this
## lab say anything. Port of labs/01-feel-the-lag/.

var _input = null
var _pacer: Pacer
var _sid := ""

var _damped := false
var _damping := 12.0
var _smooth := {}      # sid -> Vector2

enum Phase { IDLE, ARMED, SHOWN }
var _phase := Phase.IDLE
var _arm_t := 0.0
var _arm_x := 0.0
var _arm_y := 0.0
## Last input->motion reading, in ms. 0 until the meter fires.
var measured := 0.0

func _init() -> void:
	id = "01-feel-the-lag"
	num = 1
	title = "Feel the Lag"
	blurb = "No prediction: every key press waits a full round trip."

func _players():
	var st = state()
	return st.get("players") if st != null and st.get("players") is Dictionary else null

func mount(app: App) -> bool:
	room = await Shell.join_lab(app, "lab-move", func(r):
		var st = r.get_state()
		return st is Dictionary and st.get("players") is Dictionary \
			and st.get("players").has(r.get_session_id()))
	if room == null: return false
	_sid = room.get_session_id()
	var players = _players()
	if players == null: return false
	_input = room.input()
	if _input == null: return false
	_pacer = Pacer.new(1000.0 / Sim.TICK_HZ)
	return players.has(_sid)

func frame(_app: App, now: float, dt_ms: float) -> void:
	if Kb.key(KEY_R): _damped = not _damped
	if Kb.key(KEY_MINUS) and _damping > 4: _damping -= 2
	if Kb.key(KEY_EQUAL) and _damping < 30: _damping += 2

	# One input per fixed server tick — no reconciler here, so a local
	# accumulator paces the sends.
	var steps := _pacer.steps(now)
	for i in steps:
		_input.data.moveX = Kb.move_x()
		_input.data.moveY = Kb.move_y()
		_input.send()

	var players = _players()
	if players == null: return

	var dt := minf(0.1, dt_ms / 1000.0)
	for k in players:
		var p = players[k]
		var s: Vector2 = _smooth.get(k, Vector2(p.get("x", 0.0), p.get("y", 0.0)))
		var kk := 1.0 - exp(-_damping * dt)
		_smooth[k] = Vector2(s.x + (p.get("x", 0.0) - s.x) * kk, s.y + (p.get("y", 0.0) - s.y) * kk)

	# input->photon meter: arm on a key press while at rest, measure when the
	# RENDERED position first moves.
	var me = players.get(_sid)
	if me == null: return
	var speed: float = absf(me.get("vx", 0.0)) + absf(me.get("vy", 0.0))
	if _phase != Phase.ARMED and Kb.any_move() and speed < 0.01:
		_phase = Phase.ARMED
		_arm_t = now
		_arm_x = me.get("x", 0.0)
		_arm_y = me.get("y", 0.0)
	elif _phase == Phase.ARMED:
		if absf(me.get("x", 0.0) - _arm_x) > 0.03 or absf(me.get("y", 0.0) - _arm_y) > 0.03:
			measured = now - _arm_t
			_phase = Phase.SHOWN
		elif not Kb.any_move() and now - _arm_t > 2000:
			_phase = Phase.IDLE
	elif _phase == Phase.SHOWN and not Kb.any_move() and speed < 0.01:
		_phase = Phase.IDLE

func render(app: App) -> void:
	var v := app.view
	var players = _players()
	if players == null: return
	for k in players:
		var p = players[k]
		var is_me: bool = k == _sid
		var rx: float = p.get("x", 0.0)
		var ry: float = p.get("y", 0.0)
		if _damped and _smooth.has(k):
			rx = _smooth[k].x
			ry = _smooth[k].y
		Draw.square(v, rx, ry, Sim.PLAYER_HALF, Palette.hue(int(p.get("hue", 0)), 1.0 if is_me else 0.45))
		if is_me:
			Draw.square_outline(v, rx, ry, Sim.PLAYER_HALF, Palette.TEXT)
			Draw.label(v, rx, ry, "you", Palette.TEXT, 11, -v.s(Sim.PLAYER_HALF) - 18)

	var h := app.hud
	h.section("TELEMETRY")
	h.row("input -> motion", "%.0f ms" % measured if measured > 0 else "--",
		Palette.BAD if measured > 0 else Palette.TEXT_FAINT)
	h.row("meter state",
		"armed..." if _phase == Phase.ARMED else ("measured" if _phase == Phase.SHOWN else "idle"),
		Palette.WARN if _phase == Phase.ARMED else (Palette.GOOD if _phase == Phase.SHOWN else Palette.TEXT_DIM))
	h.row("render strategy", "damped" if _damped else "raw", Palette.TEXT)
	h.row("damping", "%.0f /s" % _damping, Palette.TEXT)

	h.section("CONTROLS")
	h.key("WASD", "drive")
	h.key("R", "raw <-> damped")
	h.key("- / =", "damping")
	h.note("raw = decoded server state verbatim. damped = smooth toward it (even laggier). " +
		"predicted = Lab 03. Raise the latency preset with L and feel the difference.")

func unmount() -> void:
	_smooth.clear()

func on_reconnect() -> void:
	_pacer.reset()
	_phase = Phase.IDLE
