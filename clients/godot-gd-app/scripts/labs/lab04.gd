class_name Lab04
extends LabBase
## Lab 04 — Remote Interpolation.
##
## The SAME bot rendered through four Predict instances, one per mode:
##   raw          the decoded snapshot verbatim: stutters at patch rate.
##   lerp         render `delay` ms in the PAST, between two real samples.
##   damped       exponential chase of the newest sample.
##   extrapolate  project the trend FORWARD; overshoots every turn.
## The strip along the bottom plots the bot's x over time: white dots are
## received samples, the coloured traces are what each mode rendered.
## Port of labs/04-interp-modes/.

const TRACE_CAP := 400
const STRIP_SPAN_MS := 2500.0
const PATTERNS := ["patrol", "circle", "wander"]

## One render mode: its Predict (null = raw), trace, and metric.
class Mode:
	var mode_name: String
	var color: Color
	var predict = null      # Colyseus.Predict; null for "raw"
	var visible := true
	var trace := Series.new(400)
	var smooth := Smoothness.new()

var _input = null
var _pacer: Pacer
var _sid := ""
var _bot = null

var _modes: Array[Mode] = []
var _samples := Series.new(TRACE_CAP)
var _last_raw_x := NAN
var _last_raw_y := NAN
var _pattern := 0
var _bot_travel := 0.0
## Fresh per-frame snapshot of bot1 — get_state() copies are frozen, so raw
## reads must re-fetch. `_bot` stays the stable predict HANDLE (__ref_id).
var _bot_fresh = null

func _init() -> void:
	id = "04-interp-modes"
	num = 4
	title = "Remote Interpolation"
	blurb = "lerp / damped / extrapolate / raw, side by side."

func mount(app: App) -> bool:
	room = await Shell.join_lab(app, "lab-bots", func(r):
		var st = r.get_state()
		return st is Dictionary and st.get("bots") is Dictionary \
			and st.get("bots").has("bot1"))
	if room == null: return false
	_sid = room.get_session_id()
	var st = state()
	if st == null or not (st.get("bots") is Dictionary): return false
	_bot = st.get("bots").get("bot1")
	if _bot == null: return false

	_input = room.input()
	if _input == null: return false
	_pacer = Pacer.new(1000.0 / Sim.TICK_HZ)

	var raw := Mode.new()
	raw.mode_name = "raw"
	raw.color = Palette.TEXT
	_modes = [
		raw,
		_attach("lerp", Palette.BLUE,
			{ "mode": Colyseus.Predict.LERP, "delay": Sim.REMOTE_INTERP_MS }),
		_attach("damped", Palette.GOOD,
			{ "mode": Colyseus.Predict.DAMPED, "smooth_ms": 83.0 }),
		_attach("extrapolate", Palette.WARN,
			{ "mode": Colyseus.Predict.EXTRAPOLATE, "max_extrapolate": 250.0 }),
	]
	return true

## One Predict per mode — same entity, same fields, different smoothing.
func _attach(mode_name: String, color: Color, opts: Dictionary) -> Mode:
	var m := Mode.new()
	m.mode_name = mode_name
	m.color = color
	m.predict = Colyseus.Predict.of(room)
	m.predict.attach(_bot, { "x": opts, "y": opts })
	return m

func _value(m: Mode, field: String) -> float:
	if m.predict == null:
		var b = _bot_fresh if _bot_fresh != null else _bot
		return b.get(field, 0.0)
	return m.predict.value(_bot, field)

func frame(_app: App, now: float, dt_ms: float) -> void:
	if Kb.key(KEY_B):
		_pattern = (_pattern + 1) % PATTERNS.size()
		room.send_message("pattern", { "kind": PATTERNS[_pattern] })
	for i in _modes.size():
		if Kb.key(KEY_F1 + i): _modes[i].visible = not _modes[i].visible

	var steps := _pacer.steps(now)
	for i in steps:
		_input.data.moveX = Kb.move_x()
		_input.data.moveY = Kb.move_y()
		_input.send()
	for m in _modes:
		if m.predict != null: m.predict.tick(now)

	var st = state()
	if st != null and st.get("bots") is Dictionary:
		_bot_fresh = st.get("bots").get("bot1")

	# A received sample = the decoded value changing, once per patch.
	var b = _bot_fresh if _bot_fresh != null else _bot
	var bx: float = b.get("x", 0.0)
	var by: float = b.get("y", 0.0)
	if bx != _last_raw_x or by != _last_raw_y:
		if not is_nan(_last_raw_x):
			var bdx := bx - _last_raw_x
			var bdy := by - _last_raw_y
			_bot_travel += sqrt(bdx * bdx + bdy * bdy)
		_last_raw_x = bx
		_last_raw_y = by
		_samples.push(room.clock.last_server_time(), bx)

	var s_now: float = room.clock.server_now()
	for m in _modes:
		var x := _value(m, "x")
		var y := _value(m, "y")
		m.trace.push(s_now, x)
		m.smooth.sample(x, y, dt_ms)

func render(app: App) -> void:
	var v := app.view
	var st = state()
	if st != null and st.get("players") is Dictionary:
		var players = st.get("players")
		for k in players:
			var p = players[k]
			Draw.square(v, p.get("x", 0.0), p.get("y", 0.0), Sim.PLAYER_HALF,
				Palette.hue(int(p.get("hue", 0)), 0.9 if k == _sid else 0.4))

	for i in _modes.size():
		var m := _modes[i]
		if not m.visible: continue
		var x := _value(m, "x")
		var y := _value(m, "y")
		Draw.circle_outline(v, x, y, Sim.BOT_RADIUS, m.color, i == 0)
		# Stagger the labels: the four modes sit within a bot radius of each
		# other most of the time, so a shared baseline is unreadable.
		Draw.label(v, x, y, m.mode_name, m.color, 10, -v.s(Sim.BOT_RADIUS) - 14 - i * 11)

	_draw_strip(app)

	var h := app.hud
	h.section("SMOOTHNESS (speed CV)")
	for m in _modes:
		var cv := m.smooth.cv()
		if is_nan(cv):
			h.row(m.mode_name, "--", Palette.TEXT_FAINT)
		else:
			h.row(m.mode_name, "%.0f %%" % (cv * 100),
				Palette.GOOD if cv < 0.15 else (Palette.WARN if cv < 0.5 else Palette.BAD))
	h.row("samples buffered", str(_samples.count), Palette.TEXT)

	h.section("CONTROLS")
	h.key("WASD", "drive your own square")
	h.key("B", "bot pattern: %s" % PATTERNS[_pattern])
	for i in _modes.size():
		h.key("F%d" % (i + 1), "%s %s" % ["hide" if _modes[i].visible else "show", _modes[i].mode_name])
	h.note("Lower CV = smoother render. raw stutters at the patch rate; lerp is " +
		"smooth but late; damped rounds corners; extrapolate is present-time but " +
		"overshoots every turn — press B and watch it on circle.")

## The buffer timeline: received samples vs per-mode rendered traces.
func _draw_strip(app: App) -> void:
	const H := 118.0
	const PAD := 10.0
	var x0 := app.stage.position.x + 24
	var x1 := app.stage.end.x - 16
	var y0 := app.stage.end.y - H - 10
	var y1 := y0 + H
	if x1 - x0 < 200: return

	Draw.rect(Rect2(x0, y0, x1 - x0, H), Palette.a(Palette.PANEL, 0.9))

	var s_now: float = room.clock.server_now()
	var last_patch: float = room.clock.last_server_time()
	var t_min := s_now - STRIP_SPAN_MS
	var t_max := s_now + 150.0
	# Value axis: bot x spans ~[20,80]; leave headroom for overshoot.
	const V_MIN := 12.0
	const V_MAX := 88.0
	var tx := func(t: float) -> float:
		return x0 + PAD + (t - t_min) / (t_max - t_min) * (x1 - x0 - PAD * 2)
	var ty := func(val: float) -> float:
		return y1 - PAD - (val - V_MIN) / (V_MAX - V_MIN) * (H - PAD * 2 - 14)

	for pair in [[last_patch, "newest patch"], [s_now, "now"]]:
		var x: float = tx.call(pair[0])
		if x < x0 or x > x1: continue
		Draw.dashed(Vector2(x, y0 + 4), Vector2(x, y1 - 4), Palette.a(Palette.TEXT, 0.25), 1.0, 3.0, 3.0)
		Draw.text(x - 40, y0 + 6, 80, pair[1], Palette.a(Palette.TEXT, 0.5), 9,
			HORIZONTAL_ALIGNMENT_CENTER)

	_samples.for_each(func(t, val):
		if t < t_min or t > t_max: return
		Draw.rect(Rect2(tx.call(t) - 1.5, ty.call(val) - 1.5, 3, 3), Palette.a(Palette.TEXT, 0.85)))

	for m in _modes:
		if not m.visible or m.predict == null: continue
		var started := [false]
		var prev := [Vector2.ZERO]
		m.trace.for_each(func(t, val):
			if t < t_min or t > t_max:
				started[0] = false
				return
			var pt := Vector2(tx.call(t), ty.call(val))
			if started[0]: Draw.line(prev[0], pt, Palette.a(m.color, 0.9), 1.2)
			prev[0] = pt
			started[0] = true)

# ------------------------------------------------------- harness accessors

## Drive the bot pattern from the harness, as the B key would.
func set_pattern(kind: String) -> void:
	var i := PATTERNS.find(kind)
	if i < 0: return
	_pattern = i
	room.send_message("pattern", { "kind": kind })

## How far the raw bot has travelled — a stationary bot scores NaN.
func bot_travel() -> float:
	return _bot_travel

## Start a clean measurement window once the pattern has landed.
func reset_meters() -> void:
	for m in _modes: m.smooth.clear()
	_bot_travel = 0.0

## Per-mode speed CV, for the acceptance harness.
func smoothness_by_mode() -> Dictionary:
	var r := {}
	for m in _modes: r[m.mode_name] = m.smooth.cv()
	return r

## Per-mode meter state, so a NaN can explain itself.
func describe_mode(mode_name: String) -> String:
	for m in _modes:
		if m.mode_name == mode_name: return m.smooth.describe()
	return "?"

func unmount() -> void:
	for m in _modes: m.predict = null
	_modes = []

func on_reconnect() -> void:
	_pacer.reset()
	var st = state()
	if st != null and st.get("bots") is Dictionary:
		_bot = st.get("bots").get("bot1")
