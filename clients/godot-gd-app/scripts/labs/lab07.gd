class_name Lab07
extends LabBase
## Lab 07 — WYSIWYG Collision.
##
## The collision against the moving bot is predicted INSIDE the reconciler
## step. Two ingredients make the client's verdict equal the server's:
##
##  1. value_at(bot, "x", ctx.reckon_time) — read the bot at the instant the
##     server will REWIND this input to.
##  2. ctx.memo_vec(...) — the verdict is NOT re-derivable on rollback replay
##     (a later replay would read the bot reckoned from a NEWER snapshot and
##     could flip the call). Memo runs the test once on the live step and
##     replays the outcome verbatim.
##
## The verdict is a VECTOR ([hit, vx, vy]) memoized under one key, so all
## components replay together. Port of labs/07-wysiwyg/.

var _predict = null
var _recon = null
var _input = null
var _me = null
var _bot = null
var _sid := ""

var _use_value_at := true
var _use_memo := true
var bumps_predicted := 0
var _last_bump_at := -INF
var _bump_flash_t := -INF
var _mispredicts := 0
var _last_reconcile_seq := 0
## Fresh per-frame kind for the reckon step (the scratch carries scalars only).
var _bot_kind := ""

func _init() -> void:
	id = "07-wysiwyg"
	num = 7
	title = "WYSIWYG Collision"
	blurb = "value_at(reckon_time) + ctx.memo."

func mount(app: App) -> bool:
	room = await Shell.join_lab(app, "lab-bump", func(r):
		var st = r.get_state()
		return st is Dictionary and st.get("players") is Dictionary \
			and st.get("players").has(r.get_session_id()) \
			and st.get("bots") is Dictionary and st.get("bots").has("bot1"))
	if room == null: return false
	_sid = room.get_session_id()
	var st = state()
	if st == null: return false
	_me = st.get("players").get(_sid)
	_bot = st.get("bots").get("bot1")
	if _me == null or _bot == null: return false

	_predict = Colyseus.Predict.of(room)
	# Bots are DEAD-RECKONED through the shared step — the timeline the
	# collision test below reads at ctx.reckon_time.
	_predict.attach_all_reckon("bots", ["x", "y"],
		func(b, dt: float, elapsed_ms: float): Sim.step_bot(b, dt, elapsed_ms, _bot_kind),
		{ "smooth_ms": 40.0 })
	_predict.attach_all("players", {
		"x": Colyseus.Predict.DAMPED, "y": Colyseus.Predict.DAMPED,
	}, _sid)

	_input = room.input()
	if _input == null: return false
	_build()
	app.set_latency_preset(2)   # a knife-edge verdict needs a real RTT
	return true

func _build() -> void:
	_recon = _predict.reconciler(_me, {
		"input": _input,
		"fields": ["x", "y", "vx", "vy", "bumpTicks"],
		"smooth_ms": 65.0,
		"step": _step,
	})
	_last_reconcile_seq = 0

func _step(ctx, p, cmd) -> void:
	p.bumpTicks = float(Sim.step_bump_gate(int(p.bumpTicks)))   # reconciled tick gate
	Sim.step_entity(p, float(cmd.moveX), float(cmd.moveY), ctx.dt)

	var px: float = p.x
	var py: float = p.y
	var when: float = ctx.reckon_time
	var gate := int(p.bumpTicks)
	var knock: Array
	if _use_memo:
		knock = ctx.memo_vec("bump", func(): return _test_bots(px, py, gate, when))
		if knock.is_empty(): knock = [0.0, 0.0, 0.0]
	else:
		knock = _test_bots(px, py, gate, when)

	if knock[0] == 0.0: return
	p.vx = knock[1]
	p.vy = knock[2]
	p.bumpTicks = float(Sim.BUMP_COOLDOWN_TICKS)   # immunity rides adopt+replay
	if ctx.is_replay: return                       # FX/counters: live step only
	bumps_predicted += 1
	_last_bump_at = float(Time.get_ticks_usec()) / 1000.0
	_bump_flash_t = _last_bump_at

## The verdict as a memo-able tuple: [hit 0/1, vx, vy].
func _test_bots(px: float, py: float, gate: int, when: float) -> Array:
	var st = state()
	if st == null or not (st.get("bots") is Dictionary): return [0.0, 0.0, 0.0]
	var bots = st.get("bots")
	for k in bots:
		var bot = bots[k]
		# The server rewinds THIS input to reckon_time — test there. With the
		# toggle off we read the raw snapshot instead: ~RTT/2 behind where
		# the server tests, which is the whole point of the lab.
		var bx: float = _predict.value_at(bot, "x", when) if _use_value_at else bot.get("x", 0.0)
		var by: float = _predict.value_at(bot, "y", when) if _use_value_at else bot.get("y", 0.0)
		var r := Sim.collide_bot(px, py, gate, bx, by)
		if r[0]: return [1.0, r[1], r[2]]
	return [0.0, 0.0, 0.0]

func frame(_app: App, now: float, _dt_ms: float) -> void:
	# Both toggles rebuild nothing — the step reads them live.
	if Kb.key(KEY_V): _use_value_at = not _use_value_at
	if Kb.key(KEY_M): _use_memo = not _use_memo

	var st = state()
	if st != null and st.get("bots") is Dictionary:
		var fresh_bot = st.get("bots").get("bot1")
		if fresh_bot != null: _bot_kind = str(fresh_bot.get("kind", ""))

	# The acceptance script can't hand-steer into a moving bot; when it
	# drives, seek the bot's lane and let the patrol sweep do the rest.
	var move_x := Kb.move_x()
	var move_y := Kb.move_y()
	if Kb.autopilot:
		var dy: float = _predict.value(_bot, "y") - _recon.state.y
		move_x = 0
		move_y = 1 if dy > 1.0 else (-1 if dy < -1.0 else 0)

	var steps: int = _predict.tick(now)
	for i in steps:
		_input.data.moveX = move_x
		_input.data.moveY = move_y
		_input.send()

	# Attribute LARGE corrections near a predicted bump to a flipped verdict.
	# Small post-bump corrections (< ~3u) are knockback-direction epsilon; a
	# genuinely flipped verdict diverges by many units.
	if _recon.reconcile_seq == _last_reconcile_seq: return
	_last_reconcile_seq = _recon.reconcile_seq
	if _recon.last_correction_mag > 3 \
			and float(Time.get_ticks_usec()) / 1000.0 - _last_bump_at < 700:
		_mispredicts += 1

func render(app: App) -> void:
	var v := app.view
	var st = state()
	if st != null and st.get("players") is Dictionary:
		var players = st.get("players")
		for k in players:
			if k == _sid: continue
			var p = players[k]
			Draw.square(v, _predict.value(p, "x"), _predict.value(p, "y"),
				Sim.PLAYER_HALF, Palette.hue(int(p.get("hue", 0)), 0.4))

	var bx: float = _predict.value(_bot, "x")
	var by: float = _predict.value(_bot, "y")
	Draw.circle(v, bx, by, Sim.BOT_RADIUS, Palette.a(Palette.WARN, 0.3))
	Draw.circle_outline(v, bx, by, Sim.BOT_RADIUS, Palette.WARN)
	Draw.label(v, bx, by, "bot (reckon = hit position)", Palette.WARN, 10,
		-v.s(Sim.BOT_RADIUS) - 14)
	var fb = st.get("bots").get("bot1") if st != null and st.get("bots") is Dictionary else _bot
	Draw.circle_outline(v, fb.get("x", 0.0), fb.get("y", 0.0), Sim.BOT_RADIUS,
		Palette.a(Palette.TEXT, 0.45), true)
	Draw.label(v, fb.get("x", 0.0), fb.get("y", 0.0), "stale snapshot",
		Palette.a(Palette.TEXT, 0.45), 9, v.s(Sim.BOT_RADIUS) + 4)

	var fm = _me_now()
	Draw.ghost_square(v, fm.get("x", 0.0), fm.get("y", 0.0), Sim.PLAYER_HALF,
		Palette.a(Palette.TEXT, 0.5))
	var flash: bool = float(Time.get_ticks_usec()) / 1000.0 - _bump_flash_t < 300
	var px: float = _recon.value("x")
	var py: float = _recon.value("y")
	Draw.square(v, px, py, Sim.PLAYER_HALF,
		Palette.BAD if flash else Palette.hue(int(_me.get("hue", 0))))
	Draw.square_outline(v, px, py, Sim.PLAYER_HALF, Palette.TEXT, 2.5 if flash else 1.0)

	var h := app.hud
	h.section("TELEMETRY")
	h.row("bumps predicted", str(bumps_predicted), Palette.TEXT)
	h.row("bumps (authoritative)", str(bumps_authoritative()), Palette.TEXT)
	h.row("mispredicts", str(_mispredicts),
		Palette.WARN if _mispredicts > 0 else Palette.GOOD)
	var rate := mispredict_rate()
	h.row("mispredict rate", "%.0f %%" % rate if bumps_predicted > 0 else "--",
		Palette.TEXT_FAINT if bumps_predicted == 0
			else (Palette.GOOD if rate < 10 else (Palette.WARN if rate < 40 else Palette.BAD)))
	h.row("bump immunity (ticks)", str(int(_recon.state.bumpTicks)), Palette.TEXT)

	h.section("CONTROLS")
	h.key("WASD", "graze the bot's patrol path")
	h.key("V", "read bot at ctx.reckon_time" if _use_value_at else "read the STALE snapshot")
	h.key("M", "verdict frozen with memo" if _use_memo else "verdict RE-DERIVED on replay")
	h.note("Raise the latency preset and graze the bot repeatedly. V off tests against " +
		"a position ~RTT/2 behind where the server tests; M off lets replays " +
		"re-derive the verdict against newer bot data and flip knife-edge calls. " +
		"Both off is maximally wrong.")

# ------------------------------------------------------- harness accessors

func mispredict_rate() -> float:
	return float(_mispredicts) / bumps_predicted * 100.0 if bumps_predicted > 0 else 0.0

## Fresh own-player snapshot (cached copies freeze — see move_lane.me_now).
func _me_now():
	var st = state()
	if st != null and st.get("players") is Dictionary:
		var m = st.get("players").get(_sid)
		if m != null: return m
	return _me

## The server's own count — the only verdict that settles it.
func bumps_authoritative() -> int:
	return int(_me_now().get("bumps", 0))

func unmount() -> void:
	_recon = null
	_predict = null

func on_reconnect() -> void:
	var st = state()
	if st == null: return
	if not (st.get("players") is Dictionary) or not st.get("players").has(_sid): return
	_me = st.get("players").get(_sid)
	if st.get("bots") is Dictionary: _bot = st.get("bots").get("bot1")
	_build()
