class_name Lab10
extends LabBase
## Lab 10 — Composite Sim (SimReconciler).
##
## The flat reconciler (lab 03) mirrors fields of ONE instance. Here the puck
## is a separate entity — yet your shots must feel instant, so the puck is
## predicted THROUGH your own inputs: every predicted paddle step also steps
## the puck and resolves the contact, in the server's exact order. The AI
## paddle is predicted in full too: its steering is a pure function of synced
## state (Sim.bot_input). Remote HUMAN paddles enter as zero-delta colliders
## at their latest snapshot. Port of labs/10-composite-sim/.

var _predict = null
var sim = null        # Colyseus.Reconciler (composite face)
var _input = null
var _me = null        # predict handles (stable __ref_id)
var _puck = null
var _bot = null
var _sid := ""

var _smoothing := 15.0
var _show_ghosts := true
var _puck_trail := Trail.new(120)
var _drift_spark := Spark.new()
var _spark_gate := 0.0
var touches := 0
var _touched_last_step := false
var _retreat_ticks := 0

## Fixed steps the autopilot spends heading home after a strike (20Hz -> ~0.6s).
const RETREAT_TICKS := 12

## PEAK, not instantaneous: the lead is largest right after a strike and
## collapses between them.
var max_puck_lead := 0.0

## Cost of the last predict.tick() in usec (Callable-overhead readout).
var tick_us := 0

## Per-frame snapshot for the step: rebuilding the full state Dictionary per
## substep (get_state() converts the whole tree) would swamp a replay burst.
## Decoded truth is constant within a frame anyway — same as the C# twin.
var _players_snap = null
var _bot_enabled := false

func _init() -> void:
	id = "10-composite-sim"
	num = 10
	title = "Composite Sim"
	blurb = "One rollback over a world of parts: paddle and puck together."

func mount(app: App) -> bool:
	room = await Shell.join_lab(app, "lab-hockey", func(r):
		var st = r.get_state()
		return st is Dictionary and st.get("players") is Dictionary \
			and st.get("players").has(r.get_session_id()) \
			and st.get("puck") is Dictionary \
			and st.get("players").has(Sim.BOT_ID))
	if room == null: return false
	_sid = room.get_session_id()
	var st = state()
	if st == null: return false
	_me = st.get("players").get(_sid)
	_puck = st.get("puck")
	_bot = st.get("players").get(Sim.BOT_ID)
	if _me == null or _puck == null or _bot == null: return false

	_predict = Colyseus.Predict.of(room)
	# Remote paddles: damped toward the latest snapshot. They enter the sim
	# as colliders, not as predicted parts.
	_predict.attach_all("players", {
		"x": Colyseus.Predict.DAMPED, "y": Colyseus.Predict.DAMPED,
	}, _sid)

	_input = room.input()
	if _input == null: return false
	_build()
	app.set_latency_preset(2)   # a predicted shot says nothing on a 1 ms link
	return true

func _build() -> void:
	sim = null   # drop before respawning: the old controller keeps observing
	sim = _predict.sim({
		"input": _input,
		"world": { "paddle": _me, "puck": _puck, "bot": _bot },
		"smoothing": _smoothing,
		"step": _step,
	})

## The server's step order, reproduced: paddles (mine AND the bot's, the bot
## from the PRE-step puck) -> puck -> contacts in players-map order.
func _step(ctx, w, cmd) -> void:
	var paddle = w.paddle
	var puck = w.puck
	var bot = w.bot

	var pre_px: float = puck.x
	var pre_py: float = puck.y

	Sim.step_entity(paddle, float(cmd.moveX), float(cmd.moveY), ctx.dt)

	var bmove := Sim.bot_input(bot.x, bot.y, pre_px, pre_py, _bot_enabled)
	Sim.step_entity(bot, float(bmove[0]), float(bmove[1]), ctx.dt)

	Sim.step_puck(puck, ctx.dt)

	# Contacts resolve in players-map iteration order — the server's order.
	# Mine and the bot's come from the PREDICTED mirrors; remote HUMANS are
	# zero-delta colliders at their last-known snapshot.
	var touched := false
	if _players_snap is Dictionary:
		var players = _players_snap
		for k in players:
			if k == _sid:
				if Sim.collide_paddle_puck(paddle.x, paddle.y, paddle.vx, paddle.vy, puck):
					touched = true
			elif k == Sim.BOT_ID:
				if Sim.collide_paddle_puck(bot.x, bot.y, bot.vx, bot.vy, puck):
					touched = true
			else:
				var p = players[k]
				if Sim.collide_paddle_puck(p.get("x", 0.0), p.get("y", 0.0),
						p.get("vx", 0.0), p.get("vy", 0.0), puck):
					touched = true
	if touched and not ctx.is_replay: _touched_last_step = true

## Where the predicted puck is relative to the predicted paddle — the harness
## steers by this, backing off to its own half after each strike (chasing
## without release pins the puck against a wall; a frozen world reads as
## perfect agreement and proves nothing).
func _seek_puck() -> Array:
	var tx: float = _predict.value(_puck, "x")
	var ty: float = _predict.value(_puck, "y")
	if _retreat_ticks > 0:
		tx = Sim.ARENA_W / 2.0
		ty = Sim.ARENA_H * 0.75
	var dx: float = tx - _predict.value(_me, "x")
	var dy: float = ty - _predict.value(_me, "y")
	return [1 if dx > 0.4 else (-1 if dx < -0.4 else 0),
		1 if dy > 0.4 else (-1 if dy < -0.4 else 0)]

func frame(_app: App, now: float, dt_ms: float) -> void:
	if Kb.key(KEY_G): _show_ghosts = not _show_ghosts
	var smooth_step := 5 if Kb.key(KEY_EQUAL) else (-5 if Kb.key(KEY_MINUS) else 0)
	if smooth_step != 0:
		_smoothing = clampf(_smoothing + smooth_step, 0, 40)
		_build()

	var move_x := Kb.move_x()
	var move_y := Kb.move_y()
	if Kb.autopilot:
		var m := _seek_puck()
		move_x = m[0]
		move_y = m[1]

	var snap = state()
	if snap != null:
		_players_snap = snap.get("players")
		_bot_enabled = bool(snap.get("botEnabled", false))

	var t0 := Time.get_ticks_usec()
	var steps: int = _predict.tick(now)
	tick_us = Time.get_ticks_usec() - t0
	for i in steps:
		_input.data.moveX = move_x
		_input.data.moveY = move_y
		_input.send()
		if _retreat_ticks > 0: _retreat_ticks -= 1
		if _touched_last_step:
			touches += 1
			_touched_last_step = false
			_retreat_ticks = RETREAT_TICKS

	# How far the predicted puck leads the authoritative one.
	var sp := server_puck()
	var dx: float = _predict.value(_puck, "x") - sp[0]
	var dy: float = _predict.value(_puck, "y") - sp[1]
	max_puck_lead = maxf(max_puck_lead, sqrt(dx * dx + dy * dy))

	_puck_trail.push(_predict.value(_puck, "x"), _predict.value(_puck, "y"))
	_spark_gate += dt_ms
	if _spark_gate >= 100:
		_spark_gate = 0
		_drift_spark.push(sim.drift_ema)

func render(app: App) -> void:
	var v := app.view
	var st = state()
	if st == null: return

	# Remote paddles, smoothed.
	var players = st.get("players")
	if players is Dictionary:
		for k in players:
			if k == _sid: continue
			var p = players[k]
			var hue := int(p.get("hue", 0))
			Draw.circle(v, _predict.value(p, "x"), _predict.value(p, "y"),
				Sim.PADDLE_RADIUS, Palette.hue(hue, 0.35))
			Draw.circle_outline(v, _predict.value(p, "x"), _predict.value(p, "y"),
				Sim.PADDLE_RADIUS, Palette.hue(hue, 0.8))

	# The authoritative pair, for comparison (fresh snapshot reads).
	if _show_ghosts and players is Dictionary and players.has(_sid):
		var fm = players.get(_sid)
		var fp = st.get("puck")
		Draw.circle_outline(v, fm.get("x", 0.0), fm.get("y", 0.0), Sim.PADDLE_RADIUS,
			Palette.a(Palette.TEXT, 0.35), true)
		Draw.circle_outline(v, fp.get("x", 0.0), fp.get("y", 0.0), Sim.PUCK_RADIUS,
			Palette.a(Palette.TEXT, 0.45), true)
		Draw.label(v, fp.get("x", 0.0), fp.get("y", 0.0), "server puck",
			Palette.a(Palette.TEXT, 0.45), 9, v.s(Sim.PUCK_RADIUS) + 4)

	_puck_trail.render(v, Palette.ACCENT, 1.5, 0.4)

	var px: float = _predict.value(_me, "x")
	var py: float = _predict.value(_me, "y")
	var my_hue := 0
	if players is Dictionary and players.has(_sid):
		my_hue = int(players.get(_sid).get("hue", 0))
	Draw.circle(v, px, py, Sim.PADDLE_RADIUS, Palette.hue(my_hue, 0.5))
	Draw.circle_outline(v, px, py, Sim.PADDLE_RADIUS, Palette.TEXT)
	Draw.label(v, px, py, "you (predicted)", Palette.TEXT, 11, -v.s(Sim.PADDLE_RADIUS) - 16)

	var kx: float = _predict.value(_puck, "x")
	var ky: float = _predict.value(_puck, "y")
	Draw.circle(v, kx, ky, Sim.PUCK_RADIUS, Palette.a(Palette.ACCENT, 0.9))
	Draw.circle_outline(v, kx, ky, Sim.PUCK_RADIUS, Palette.ACCENT)
	Draw.label(v, kx, ky, "puck (predicted)", Palette.ACCENT, 10, -v.s(Sim.PUCK_RADIUS) - 14)

	var ema: float = sim.drift_ema
	var status := "matched" if ema < 0.05 else ("jitter" if ema < 1.0 else "diverging")
	var h := app.hud
	h.section("TELEMETRY")
	h.chips("pending inputs (unacked)", sim.pending_count)
	h.row("drift status", status,
		Palette.GOOD if status == "matched" else (Palette.WARN if status == "jitter" else Palette.BAD))
	h.spark(_drift_spark, "drift ema", "%.4f" % ema, Palette.ACCENT)
	h.row("puck lead (peak)", "%.2f u" % max_puck_lead, Palette.TEXT)
	h.row("last correction", "%.3f" % sim.last_correction_mag, Palette.TEXT)
	h.row("touches predicted", str(touches), Palette.TEXT)

	h.section("CONTROLS")
	h.key("WASD", "drive your paddle into the puck")
	h.key("- / =", "smoothing %.0f /s" % _smoothing)
	h.key("G", "server ghosts: on" if _show_ghosts else "server ghosts: off")
	h.note("One rollback over THREE parts. Your paddle, the puck AND the AI " +
		"paddle are predicted together, in the server's order, so a strike is " +
		"instant — and re-derived from truth on every ack. The AI is predictable " +
		"because its steering is a pure function of synced state; remote HUMANS " +
		"stay colliders at their last snapshot, so a contested human touch is " +
		"the honest misprediction.")

# ------------------------------------------------------- harness accessors

## Server-authoritative puck position — the harness's liveness probe.
func server_puck() -> Array:
	var st = state()
	if st != null and st.get("puck") is Dictionary:
		var p = st.get("puck")
		return [p.get("x", 0.0), p.get("y", 0.0)]
	return [0.0, 0.0]

## Raw values behind the lead, so a failure can explain itself.
func describe_puck() -> String:
	var sp := server_puck()
	return "predicted=(%.2f,%.2f) server=(%.2f,%.2f) paddle=(%.2f,%.2f)" % [
		_predict.value(_puck, "x"), _predict.value(_puck, "y"), sp[0], sp[1],
		_predict.value(_me, "x"), _predict.value(_me, "y")]

## Switch the server's AI paddle on/off. The acceptance run turns it OFF so
## the determinism check measures OUR step alone.
func set_bot(on: bool) -> void:
	room.send_message("bot", { "on": on })

func unmount() -> void:
	sim = null
	_predict = null

func on_reconnect() -> void:
	var st = state()
	if st == null or not (st.get("players") is Dictionary): return
	if not st.get("players").has(_sid) or not st.get("players").has(Sim.BOT_ID): return
	_me = st.get("players").get(_sid)
	_puck = st.get("puck")
	_bot = st.get("players").get(Sim.BOT_ID)
	_build()
	_puck_trail.clear()
