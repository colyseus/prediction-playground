class_name Lab05
extends LabBase
## Lab 05 — Dead Reckoning.
##
## Instead of drawing the PAST (lerp), forward-simulate the latest snapshot
## to the PRESENT with the same step function the server runs. The reckon
## horizon is exactly the snapshot age.
##   smooth_ms  glide applied to each snapshot REBASE.
##   snap       rebases beyond this distance POP instead of gliding.
## Port of labs/05-dead-reckoning/.

const PATTERNS := ["teleport", "patrol", "wander", "circle"]
const MAX_DOTS := 40

var _lerp = null       # Colyseus.Predict
var _reckon = null     # Colyseus.Predict
var _input = null
var _pacer: Pacer
var _sid := ""
var _bot = null

var _smooth_ms := 40.0
var _snap := 8.0
var _pattern := 0

var _dots: Array = []          # [x, y, t]
var _last_raw_x := NAN
var _last_raw_y := NAN
var _last_reckon_x := NAN
var _warps := 0
var _peak_gap := 0.0
var _warp_flash_t := -INF
## Fresh per-frame snapshot + kind: get_state() copies are frozen, and the
## reckon scratch carries scalars only, so the step needs kind handed in.
var _bot_fresh = null
var _bot_kind := ""

func _init() -> void:
	id = "05-dead-reckoning"
	num = 5
	title = "Dead Reckoning"
	blurb = "Forward-simulate remotes to the present with the shared step."

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

	# The delayed baseline to compare against.
	_lerp = Colyseus.Predict.of(room)
	var lerp_opts := { "mode": Colyseus.Predict.LERP, "delay": Sim.REMOTE_INTERP_MS }
	_lerp.attach(_bot, { "x": lerp_opts, "y": lerp_opts })

	_attach_reckon()

	_input = room.input()
	if _input == null: return false
	_pacer = Pacer.new(1000.0 / Sim.TICK_HZ)

	_send_pattern()   # the teleporter is the most legible default
	return true

## The reckon step, called by the SDK with a scratch COPY of the bot.
## `elapsed_ms` is absolute server-time at the end of the substep — what
## makes the circle's closed form and the teleport schedule evaluable at any
## instant. Scratch mutation only persists within one forward pass: periods
## chain, nothing leaks into the snapshot.
func _reckon_step(b, dt: float, elapsed_ms: float) -> void:
	Sim.step_bot(b, dt, elapsed_ms, _bot_kind)

func _attach_reckon() -> void:
	_reckon = Colyseus.Predict.of(room)
	_reckon.attach_reckon(_bot, ["x", "y"], _reckon_step,
		{ "smooth_ms": _smooth_ms, "snap": _snap })

func _rebuild() -> void:
	_reckon = null
	_attach_reckon()

func _send_pattern() -> void:
	room.send_message("pattern", { "kind": PATTERNS[_pattern] })

func frame(_app: App, now: float, _dt_ms: float) -> void:
	if Kb.key(KEY_B):
		_pattern = (_pattern + 1) % PATTERNS.size()
		_send_pattern()
		_warps = 0
	var smooth_step := 10 if Kb.key(KEY_EQUAL) else (-10 if Kb.key(KEY_MINUS) else 0)
	if smooth_step != 0:
		_smooth_ms = clampf(_smooth_ms + smooth_step, 0, 200)
		_rebuild()
	var snap_step := 6 if Kb.key(KEY_PERIOD) else (-6 if Kb.key(KEY_COMMA) else 0)
	if snap_step != 0:
		_snap = clampf(_snap + snap_step, 1, 60)
		_rebuild()

	var st = state()
	if st != null and st.get("bots") is Dictionary:
		_bot_fresh = st.get("bots").get("bot1")
		if _bot_fresh != null: _bot_kind = str(_bot_fresh.get("kind", ""))

	var steps := _pacer.steps(now)
	for i in steps:
		_input.data.moveX = Kb.move_x()
		_input.data.moveY = Kb.move_y()
		_input.send()
	_lerp.tick(now)
	_reckon.tick(now)

	var b = _bot_fresh if _bot_fresh != null else _bot
	var bx: float = b.get("x", 0.0)
	var by: float = b.get("y", 0.0)
	if bx != _last_raw_x or by != _last_raw_y:
		_last_raw_x = bx
		_last_raw_y = by
		if _dots.size() == MAX_DOTS: _dots.pop_front()
		_dots.append([bx, by, now])

	var rx: float = _reckon.value(_bot, "x")
	if not is_nan(_last_reckon_x) and absf(rx - _last_reckon_x) > 15:
		_warps += 1
		_warp_flash_t = now
	_last_reckon_x = rx

	var gx: float = rx - _lerp.value(_bot, "x")
	var gy: float = _reckon.value(_bot, "y") - _lerp.value(_bot, "y")
	_peak_gap = maxf(_peak_gap, sqrt(gx * gx + gy * gy))

func render(app: App) -> void:
	var v := app.view
	var now := float(Time.get_ticks_usec()) / 1000.0
	var s_now: float = room.clock.server_now()
	var age := maxf(0.0, s_now - room.clock.last_server_time())

	var st = state()
	if st != null and st.get("players") is Dictionary:
		var players = st.get("players")
		for k in players:
			var p = players[k]
			Draw.square(v, p.get("x", 0.0), p.get("y", 0.0), Sim.PLAYER_HALF,
				Palette.hue(int(p.get("hue", 0)), 0.9 if k == _sid else 0.4))

	# Raw snapshot dots, fading over 1.5 s — the samples reckon starts from.
	for d in _dots:
		var a: float = 1.0 - (now - d[2]) / 1500.0
		if a <= 0: continue
		Draw.circle(v, d[0], d[1], 0.4, Palette.a(Palette.TEXT, a * 0.5))

	var lx: float = _lerp.value(_bot, "x")
	var ly: float = _lerp.value(_bot, "y")
	var rx: float = _reckon.value(_bot, "x")
	var ry: float = _reckon.value(_bot, "y")
	var b = _bot_fresh if _bot_fresh != null else _bot
	var bx: float = b.get("x", 0.0)
	var by: float = b.get("y", 0.0)

	# The reckon horizon: newest snapshot -> forward-simulated present.
	Draw.dashed_world(v, bx, by, rx, ry, Palette.a(Palette.WARN, 0.8), 1.2)
	Draw.circle(v, bx, by, 0.7, Palette.a(Palette.TEXT, 0.9))

	Draw.circle_outline(v, lx, ly, Sim.BOT_RADIUS, Palette.BLUE)
	Draw.label(v, lx, ly, "lerp (past)", Palette.BLUE, 10, v.s(Sim.BOT_RADIUS) + 4)
	Draw.circle(v, rx, ry, Sim.BOT_RADIUS, Palette.a(Palette.WARN, 0.25))
	Draw.circle_outline(v, rx, ry, Sim.BOT_RADIUS, Palette.WARN)
	Draw.label(v, rx, ry, "reckon (present)", Palette.WARN, 10, -v.s(Sim.BOT_RADIUS) - 14)

	if now - _warp_flash_t < 500:
		Draw.label(v, rx, ry, "WARP", Palette.BAD, 13, -v.s(Sim.BOT_RADIUS) - 30)

	var h := app.hud
	h.section("TELEMETRY")
	h.row("reckon horizon (snapshot age)", "%.0f ms" % age, Palette.TEXT)
	h.row("reckon vs lerp gap",
		"%.1f u" % sqrt((rx - lx) * (rx - lx) + (ry - ly) * (ry - ly)), Palette.TEXT)
	h.row("warps seen", str(_warps), Palette.TEXT)

	h.section("CONTROLS")
	h.key("WASD", "drive your own square")
	h.key("B", "bot pattern: %s" % PATTERNS[_pattern])
	h.key("- / =", "rebase smoothing  %.0f ms" % _smooth_ms)
	h.key(", / .", "snap threshold  %.0f u" % _snap)
	h.note("patrol = fully predictable — wander = server-secret turns, so reckon " +
		"extrapolates straight through every one and gets corrected — teleport = a " +
		"scheduled discontinuity. Raise the snap threshold above the warp distance " +
		"and watch the teleport smear across the arena.")

# ------------------------------------------------------- harness accessors

## The reckoned pose, for the acceptance harness.
func reckon_y() -> float:
	return _reckon.value(_bot, "y")

## Largest reckon-lerp separation seen, for the acceptance harness.
func peak_reckon_lerp_gap() -> float:
	return _peak_gap

## Drive the bot pattern from the harness, as the B key would.
func set_pattern(kind: String) -> void:
	var i := PATTERNS.find(kind)
	if i < 0: return
	_pattern = i
	_send_pattern()
	_warps = 0
	_peak_gap = 0.0

func unmount() -> void:
	_reckon = null
	_lerp = null

func on_reconnect() -> void:
	_pacer.reset()
	var st = state()
	if st != null and st.get("bots") is Dictionary:
		_bot = st.get("bots").get("bot1")
	_dots.clear()
