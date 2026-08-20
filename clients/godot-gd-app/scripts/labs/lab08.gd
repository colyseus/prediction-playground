class_name Lab08
extends LabBase
## Lab 08 — Optimistic Events.
##
## The GOAL banner fires the instant your PREDICTED square crosses the line,
## then settles against the server:
##   predicted  ctx.predict() inside the reconciler step (LIVE step only).
##   confirmed  the server's "goal" broadcast -> confirm().
##   rejected   grace-tick auto-reject -> on_reject.
## The zone gate itself is SHARED deterministic sim over a reconciled tick
## field: whether you *entered* is never a misprediction — only the server's
## deny roll can reject the event. Port of labs/08-optimistic-events/.

const MAX_RECORDS := 30

var _predict = null
var _goals = null      # Colyseus.EventChannel
var _recon = null
var _input = null
var _me = null
var _sid := ""

var _records: Array = []      # [predicted_at, settled_at, outcome 0/1/-1]
var _banner := ""
var _banner_color := Color.WHITE
var _banner_t := -INF
var _deny_rate := 0

func _init() -> void:
	id = "08-optimistic-events"
	num = 8
	title = "Optimistic Events"
	blurb = "Instant feedback; confirm or reject."

func mount(app: App) -> bool:
	room = await Shell.join_lab(app, "lab-goal", func(r):
		var st = r.get_state()
		return st is Dictionary and st.get("players") is Dictionary \
			and st.get("players").has(r.get_session_id()))
	if room == null: return false
	_sid = room.get_session_id()
	var st = state()
	if st == null or not (st.get("players") is Dictionary): return false
	_me = st.get("players").get(_sid)
	if _me == null: return false
	_deny_rate = int(st.get("denyRate", 0))

	_predict = Colyseus.Predict.of(room)
	_predict.attach_all("players", {
		"x": Colyseus.Predict.DAMPED, "y": Colyseus.Predict.DAMPED,
	}, _sid)

	_goals = _predict.define_event({
		"on_predict": func(_key):
			_push(float(Time.get_ticks_usec()) / 1000.0)
			_show_banner("GOAL!", Palette.GOOD),
		"on_confirm": func(_key): _settle(1),
		"on_reject": func(_key):
			_settle(-1)
			_show_banner("DENIED", Palette.BAD),
	})

	room.message_received.connect(func(type, data):
		if type == "goal" and data is Dictionary and data.get("sid") == _sid:
			_goals.confirm())

	_input = room.input()
	if _input == null: return false
	_build()
	return true

## stepEntity + the shared score gate, with the sim-born event.
func _step(ctx, s, cmd) -> void:
	Sim.step_entity(s, float(cmd.moveX), float(cmd.moveY), ctx.dt)
	# Live-only: ctx.predict is a no-op during rollback replay.
	var gate := Sim.step_score_gate(s.x, s.y, int(s.scoreTicks))
	if gate[0]: ctx.predict(_goals, "goal")
	s.scoreTicks = float(gate[1])

func _build() -> void:
	_recon = _predict.reconciler(_me, {
		"input": _input,
		"fields": ["x", "y", "vx", "vy", "scoreTicks"],
		"smooth_ms": 65.0,
		"step": _step,
	})

func _show_banner(text: String, color: Color) -> void:
	_banner = text
	_banner_color = color
	_banner_t = float(Time.get_ticks_usec()) / 1000.0

func _push(now: float) -> void:
	if _records.size() == MAX_RECORDS: _records.pop_front()
	_records.append([now, 0.0, 0])

## Settle the oldest still-pending record.
func _settle(outcome: int) -> void:
	for r in _records:
		if r[2] != 0: continue
		r[2] = outcome
		r[1] = float(Time.get_ticks_usec()) / 1000.0
		return

func frame(_app: App, now: float, _dt_ms: float) -> void:
	# The deny rate is room-wide, like the web slider.
	var deny_step := 25 if Kb.key(KEY_EQUAL) else (-25 if Kb.key(KEY_MINUS) else 0)
	if deny_step != 0:
		_deny_rate = clampi(_deny_rate + deny_step, 0, 100)
		room.send_message("denyRate", { "rate": _deny_rate })

	var steps: int = _predict.tick(now)
	for i in steps:
		_input.data.moveX = Kb.move_x()
		_input.data.moveY = Kb.move_y()
		_input.send()

func render(app: App) -> void:
	var v := app.view
	var zone := Rect2(v.sx(Sim.GOAL_ZONE_X), v.sy(Sim.GOAL_ZONE_Y),
		v.s(Sim.GOAL_ZONE_W), v.s(Sim.GOAL_ZONE_H))
	Draw.rect(zone, Palette.a(Palette.GOOD, 0.12))
	Draw.line(zone.position, Vector2(zone.end.x, zone.position.y), Palette.a(Palette.GOOD, 0.5), 1.5)
	Draw.line(Vector2(zone.position.x, zone.end.y), zone.end, Palette.a(Palette.GOOD, 0.5), 1.5)
	Draw.line(zone.position, Vector2(zone.position.x, zone.end.y), Palette.a(Palette.GOOD, 0.5), 1.5)
	Draw.label(v, Sim.GOAL_ZONE_X + Sim.GOAL_ZONE_W / 2, Sim.GOAL_ZONE_Y, "GOAL",
		Palette.a(Palette.GOOD, 0.7), 10, -14)

	var st = state()
	if st != null and st.get("players") is Dictionary:
		var players = st.get("players")
		for k in players:
			if k == _sid: continue
			var p = players[k]
			Draw.square(v, _predict.value(p, "x"), _predict.value(p, "y"),
				Sim.PLAYER_HALF, Palette.hue(int(p.get("hue", 0)), 0.4))

	var fm = _me_now()
	Draw.ghost_square(v, fm.get("x", 0.0), fm.get("y", 0.0), Sim.PLAYER_HALF,
		Palette.a(Palette.TEXT, 0.4))
	var px: float = _recon.value("x")
	var py: float = _recon.value("y")
	Draw.square(v, px, py, Sim.PLAYER_HALF, Palette.hue(int(_me.get("hue", 0))))
	Draw.square_outline(v, px, py, Sim.PLAYER_HALF, Palette.TEXT)

	var now := float(Time.get_ticks_usec()) / 1000.0
	var age := now - _banner_t
	if _banner != "" and age < 1400:
		var a := minf(1.0, 3.0 * (1.0 - age / 1400.0))
		Draw.text(app.stage.position.x, app.stage.position.y + 40, app.stage.size.x, _banner,
			Palette.a(_banner_color, a), 42, HORIZONTAL_ALIGNMENT_CENTER)

	var confirmed := 0
	var rejected := 0
	var pending := 0
	var settle_sum := 0.0
	for r in _records:
		if r[2] == 1:
			confirmed += 1
			settle_sum += r[1] - r[0]
		elif r[2] == -1: rejected += 1
		else: pending += 1

	var h := app.hud
	h.section("TELEMETRY")
	h.row("score (authoritative)", str(int(fm.get("score", 0))), Palette.TEXT)
	h.row("events predicted", str(_records.size()), Palette.TEXT)
	h.row("confirmed (avg settle)",
		"%d (%.0f ms)" % [confirmed, settle_sum / confirmed] if confirmed > 0 else "0",
		Palette.GOOD if confirmed > 0 else Palette.TEXT_FAINT)
	h.row("rejected", str(rejected), Palette.BAD if rejected > 0 else Palette.TEXT)
	h.row("pending", str(pending), Palette.WARN if pending > 0 else Palette.TEXT)

	h.section("RECENT EVENTS")
	for i in 5:
		var idx := _records.size() - 1 - i
		if idx < 0:
			h.row("event %d" % (i + 1), "--", Palette.TEXT_FAINT)
			continue
		var r = _records[idx]
		if r[2] == 0:
			h.row("event %d" % (i + 1), "pending...", Palette.WARN)
		else:
			h.row("event %d" % (i + 1),
				"%s +%.0f ms" % ["confirmed" if r[2] == 1 else "rejected", r[1] - r[0]],
				Palette.GOOD if r[2] == 1 else Palette.BAD)

	h.section("CONTROLS")
	h.key("WASD", "run into the goal zone on the right")
	h.key("- / =", "server deny rate  %d %%" % _deny_rate)
	h.note("The banner is optimistic — score is authoritative. Raise the deny rate " +
		"and the banner goes up instantly, then retracts when the server stays silent.")

# ------------------------------------------------------- harness accessors

## Fresh own-player snapshot (cached copies freeze).
func _me_now():
	var st = state()
	if st != null and st.get("players") is Dictionary:
		var m = st.get("players").get(_sid)
		if m != null: return m
	return _me

func predicted_count() -> int:
	return _records.size()

func confirmed_count() -> int:
	var n := 0
	for r in _records:
		if r[2] == 1: n += 1
	return n

func rejected_count() -> int:
	var n := 0
	for r in _records:
		if r[2] == -1: n += 1
	return n

func set_deny_rate(rate: int) -> void:
	_deny_rate = clampi(rate, 0, 100)
	room.send_message("denyRate", { "rate": _deny_rate })

func unmount() -> void:
	_recon = null
	_goals = null
	_predict = null

func on_reconnect() -> void:
	var st = state()
	if st == null or not (st.get("players") is Dictionary): return
	_me = st.get("players").get(_sid)
	if _goals != null: _goals.clear()
	_build()
