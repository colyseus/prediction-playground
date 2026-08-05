class_name Lab02
extends LabBase
## Lab 02 — Clocks & Timelines. There is no clock "API call" to make: the
## moment the server declares defineInput(), every input round-trip carries a
## TIMED prefix and the SDK maintains room.clock. This lab just reads it.
## Port of labs/02-clocks/.

const STRIP_SPAN_MS := 3000.0

var _input = null
var _pacer: Pacer
var _sid := ""
var _bot = null

var _arrivals: Array[float] = []
var _last_patch_stamp := 0.0
var _spark_gate := 0.0
var _rtt := Spark.new()
var _age := Spark.new()
var _slew := Spark.new()

func _init() -> void:
	id = "02-clocks"
	num = 2
	title = "Clocks & Timelines"
	blurb = "serverNow / renderNow / RTT / jitter."

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
	# Inputs feed the clock: one send per fixed tick = one RTT/offset sample.
	_input = room.input()
	if _input == null: return false
	_pacer = Pacer.new(1000.0 / Sim.TICK_HZ)
	return true

func frame(_app: App, now: float, dt_ms: float) -> void:
	var steps := _pacer.steps(now)
	for i in steps:
		_input.data.moveX = Kb.move_x()
		_input.data.moveY = Kb.move_y()
		_input.send()

	# A patch arrival = the server stamp changing.
	var stamp: float = room.clock.last_server_time()
	if stamp != _last_patch_stamp:
		_last_patch_stamp = stamp
		_arrivals.append(now)
		if _arrivals.size() > 128: _arrivals.pop_front()

	_age.push(maxf(0.0, room.clock.server_now() - stamp))
	_spark_gate += dt_ms
	if _spark_gate >= 200:
		_spark_gate = 0
		_rtt.push(room.clock.rtt())
		_slew.push(absf(room.clock.server_now() - room.clock.render_now()))

func render(app: App) -> void:
	var v := app.view
	var st = state()
	if st == null: return
	var players = st.get("players")
	if players is Dictionary:
		for k in players:
			var p = players[k]
			Draw.square(v, p.get("x", 0.0), p.get("y", 0.0), Sim.PLAYER_HALF,
				Palette.hue(int(p.get("hue", 0)), 0.9 if k == _sid else 0.4))

	# fresh fetch: get_state() snapshots are frozen, cached refs never move
	var bot = st.get("bots").get("bot1") if st.get("bots") is Dictionary else null
	if bot != null:
		Draw.circle_outline(v, bot.get("x", 0.0), bot.get("y", 0.0), Sim.BOT_RADIUS, Palette.TEXT, true)
		Draw.label(v, bot.get("x", 0.0), bot.get("y", 0.0), "raw snapshots (patch rate)",
			Palette.a(Palette.TEXT, 0.6), 10, -v.s(Sim.BOT_RADIUS) - 18)

	# Patch-arrival strip along the bottom of the stage.
	var x0 := app.stage.position.x + 24
	var x1 := app.stage.end.x - 20
	var y := app.stage.end.y - 34
	if x1 - x0 > 200:
		Draw.line(Vector2(x0, y), Vector2(x1, y), Palette.a(Palette.TEXT_DIM, 0.3))
		var now := float(Time.get_ticks_usec()) / 1000.0
		for t in _arrivals:
			var age := now - t
			if age > STRIP_SPAN_MS: continue
			var px := x1 - (age / STRIP_SPAN_MS) * (x1 - x0)
			Draw.rect(Rect2(px - 2, y - 2, 4, 4), Palette.GOOD)
		Draw.text(x0, y - 18, 420, "patch arrivals (local clock, last 3 s) ->",
			Palette.a(Palette.TEXT, 0.55), 10)

	var h := app.hud
	h.section("TELEMETRY")
	h.spark(_rtt, "rtt", "%.0f ms" % _rtt.last(), Palette.BLUE)
	h.spark(_age, "patch age (sawtooth)", "%.0f ms" % _age.last(), Palette.GOOD)
	h.spark(_slew, "|serverNow - renderNow| (slew)", "%.1f ms" % _slew.last(), Palette.WARN)
	h.row("serverNow", "%.0f ms" % room.clock.server_now(), Palette.TEXT)
	h.row("renderNow (slewed)", "%.0f ms" % room.clock.render_now(), Palette.TEXT)
	h.row("jitter (interarrival)", "%.1f ms" % room.clock.jitter(), Palette.TEXT)
	h.row("smoothed rtt", "%.0f ms" % room.clock.smoothed_rtt(), Palette.TEXT)
	h.row("patch interval", "%.0f ms" % room.clock.patch_interval(), Palette.TEXT)

	h.section("CONTROLS")
	h.key("WASD", "drive")
	h.note("Nothing to configure here — yank the latency preset with L and watch every " +
		"readout respond. The offset re-converges; the slew spike decays over ~250 ms. " +
		"The dot row marks each PATCH ARRIVAL on the local clock: add jitter and watch " +
		"the spacing get ragged.")

func unmount() -> void:
	_arrivals.clear()

func on_reconnect() -> void:
	_pacer.reset()
	_arrivals.clear()
	_last_patch_stamp = 0
	var st = state()
	if st != null and st.get("bots") is Dictionary:
		_bot = st.get("bots").get("bot1")
