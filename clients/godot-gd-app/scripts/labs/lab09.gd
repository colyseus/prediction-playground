class_name Lab09
extends LabBase
## Lab 09 — Predicted Spawns.
##
## Click-to-fire feels instant because the client spawns an OPTIMISTIC local
## projectile the same frame; when the server's authoritative entity arrives
## (~RTT later) the store CORRELATES the two into one logical entry — same
## id, same sprite, no visual seam.
##   owned       which server entities are mine to correlate.
##   spawn_time  measures each shot's exact input lead, so MY projectile
##               keeps flying the shooter's timeline through the handoff.
##   step        the SAME shared flight function the server integrates.
##   fields + reckon_step  ALSO reckon the CONFIRMED entities by that lead.
## Port of labs/09-predicted-spawns/.

var _predict = null
var _spawns = null     # Colyseus.Spawns
var _recon = null
var _input = null
var _me = null
var _sid := ""

# Per-entry presentation state, keyed on the STABLE entry id:
# id -> [was_pending, flash_t, x, y]
var _slots := {}

## Worst distance the sprite teleported across a handoff — see _sweep.
var max_handoff_jump := 0.0

var _aim_x := 50.0
var _aim_y := 20.0
var _pending_fire := false
var _optimistic := true
var last_lead_ms := NAN
var fired := 0
var pending_spawns := 0
var confirmed_spawns := 0
var _foreign := 0

func _init() -> void:
	id = "09-predicted-spawns"
	num = 9
	title = "Predicted Spawns"
	blurb = "Optimistic projectile -> authoritative handoff."

func mount(app: App) -> bool:
	room = await Shell.join_lab(app, "lab-projectile", func(r):
		var st = r.get_state()
		return st is Dictionary and st.get("players") is Dictionary \
			and st.get("players").has(r.get_session_id()))
	if room == null: return false
	_sid = room.get_session_id()
	var st = state()
	if st == null or not (st.get("players") is Dictionary): return false
	_me = st.get("players").get(_sid)
	if _me == null: return false

	_predict = Colyseus.Predict.of(room)
	_predict.attach_all("players", {
		"x": Colyseus.Predict.DAMPED, "y": Colyseus.Predict.DAMPED,
	}, _sid)

	_spawns = _predict.spawns("projectiles", {
		"owned": func(p): return p.owner == _sid,
		"spawn_time": func(p): return p.bornMs,
		"step": func(local: Dictionary, dt: float): Sim.step_projectile(local, dt),
		# Also reckon the CONFIRMED entities — same motion over the schema
		# scratch, forwarded by snapshot age + the measured input lead.
		"fields": ["x", "y"],
		"reckon_step": func(p, dt: float, _elapsed: float): Sim.step_projectile(p, dt),
	})
	if _spawns == null: return false

	_input = room.input()
	if _input == null: return false
	_build()
	return true

func _build() -> void:
	_recon = _predict.reconciler(_me, {
		"input": _input,
		"fields": ["x", "y", "vx", "vy"],
		"smooth_ms": 65.0,
		"step": func(ctx, s, cmd): Sim.step_entity(s, float(cmd.moveX), float(cmd.moveY), ctx.dt),
	})

func frame(app: App, now: float, _dt_ms: float) -> void:
	var v := app.view
	var mouse := Kb.mouse_pos
	var over_stage := mouse.x < app.stage.end.x
	if over_stage and not Kb.autopilot:   # the acceptance script aims for itself
		_aim_x = v.wx(mouse.x)
		_aim_y = v.wy(mouse.y)
	if over_stage and Kb.mouse_down(): _pending_fire = true
	if Kb.key(KEY_SPACE): _pending_fire = true
	if Kb.key(KEY_O): _optimistic = not _optimistic

	var steps: int = _predict.tick(now)
	for i in steps:
		_input.data.moveX = Kb.move_x()
		_input.data.moveY = Kb.move_y()
		_input.data.aimX = _aim_x
		_input.data.aimY = _aim_y
		_input.data.fire = 1.0 if _pending_fire else 0.0
		_input.send()
		if not _pending_fire: continue

		fired += 1
		if _optimistic: _fire_optimistic()
		_pending_fire = false

	_sweep(now)

## Fold the store's entries into presentation state: which are pending, which
## just crossed the handoff, and what lead the crossing measured. Lives in
## frame, not render — a headless run has the same numbers.
func _sweep(now: float) -> void:
	pending_spawns = 0
	confirmed_spawns = 0
	_foreign = 0
	var live := {}
	for e in _spawns.entries():
		var eid: int = e["id"]
		live[eid] = true
		var known := _slots.has(eid)
		var slot: Array = _slots.get(eid, [false, -INF, NAN, NAN])
		var x: float = _spawns.value(eid, "x")
		var y: float = _spawns.value(eid, "y")

		if not e["confirmed"]:
			if not e["has_local"]: continue
			pending_spawns += 1
			_slots[eid] = [true, slot[1], x, y]
			continue

		confirmed_spawns += 1
		if _spawns.server_string(eid, "owner") != _sid: _foreign += 1
		if slot[0]:
			# Crossed the handoff this sweep: measure lead + teleport distance.
			if e["lead_ms"] > 0: last_lead_ms = e["lead_ms"]
			# Un-reckoned, the confirmed entity renders at the last decoded
			# snapshot — (age + lead) x speed behind the prediction, which is
			# the visible snap-back.
			if known and not is_nan(slot[2]) and not is_nan(x):
				var dx: float = x - slot[2]
				var dy: float = y - slot[3]
				var d := sqrt(dx * dx + dy * dy)
				max_handoff_jump = maxf(max_handoff_jump, d)
			slot = [false, now, slot[2], slot[3]]
		_slots[eid] = [slot[0], slot[1], x, y]
	for eid in _slots.keys():
		if not live.has(eid): _slots.erase(eid)

## Spawn the optimistic local at the PREDICTED pose — the same origin the
## server will use once this input arrives.
func _fire_optimistic() -> void:
	var px: float = _recon.state.x
	var py: float = _recon.state.y
	var dx := _aim_x - px
	var dy := _aim_y - py
	var len := sqrt(dx * dx + dy * dy)
	if len < 1e-9: len = 1.0
	_spawns.spawn({
		"x": px, "y": py,
		"vx": dx / len * Sim.PROJECTILE_SPEED,
		"vy": dy / len * Sim.PROJECTILE_SPEED,
	})

func render(app: App) -> void:
	var v := app.view
	var now := float(Time.get_ticks_usec()) / 1000.0

	Draw.square(v, 50, 8, 2, Palette.a(Palette.BAD, 0.3))
	Draw.square_outline(v, 50, 8, 2, Palette.BAD, 1.5)
	Draw.label(v, 50, 8, "turret (foreign shots)", Palette.BAD, 10, -v.s(2) - 16)

	var st = state()
	if st != null and st.get("players") is Dictionary:
		var players = st.get("players")
		for k in players:
			if k == _sid: continue
			var p = players[k]
			Draw.square(v, _predict.value(p, "x"), _predict.value(p, "y"),
				Sim.PLAYER_HALF, Palette.hue(int(p.get("hue", 0)), 0.4))

	var mx: float = _recon.value("x")
	var my: float = _recon.value("y")
	Draw.square(v, mx, my, Sim.PLAYER_HALF, Palette.hue(int(_me.get("hue", 0))))
	Draw.square_outline(v, mx, my, Sim.PLAYER_HALF, Palette.TEXT)
	Draw.circle_outline(v, _aim_x, _aim_y, 0.8, Palette.a(Palette.TEXT, 0.6))

	# One render path across the handoff, keyed on the stable entry id:
	# value() reads the stepped local while pending and the lead-aware reckon
	# once confirmed, so the same call covers both sides.
	for e in _spawns.entries():
		var eid: int = e["id"]
		var x: float = _spawns.value(eid, "x")
		var y: float = _spawns.value(eid, "y")
		if is_nan(x) or is_nan(y): continue
		if not e["confirmed"]:
			Draw.circle(v, x, y, Sim.PROJECTILE_RADIUS, Palette.a(Palette.WARN, 0.9))
			continue
		var slot: Array = _slots.get(eid, [false, -INF, NAN, NAN])
		var flashing: bool = now - slot[1] < 350
		var mine: bool = _spawns.server_string(eid, "owner") == _sid
		Draw.circle(v, x, y, Sim.PROJECTILE_RADIUS * (1.8 if flashing else 1.0),
			Palette.a(Palette.TEXT, 0.95) if mine else Palette.a(Palette.BAD, 0.9))

	var h := app.hud
	h.section("TELEMETRY")
	h.row("pending (mine, unconfirmed)", str(pending_spawns),
		Palette.WARN if pending_spawns > 0 else Palette.TEXT)
	h.row("confirmed entities", str(confirmed_spawns), Palette.TEXT)
	h.row("of those, foreign", str(_foreign), Palette.TEXT)
	h.row("last measured input lead",
		"--" if is_nan(last_lead_ms) else "%.0f ms" % last_lead_ms,
		Palette.TEXT_FAINT if is_nan(last_lead_ms) else Palette.GOOD)
	h.row("shots fired", str(fired), Palette.TEXT)

	h.section("CONTROLS")
	h.key("WASD", "drive")
	h.key("mouse", "aim")
	h.key("click / SPACE", "fire")
	h.key("O", "optimistic spawn: on" if _optimistic else "optimistic spawn: OFF")
	h.note("Amber = predicted local (pending) — white = confirmed (correlated) — " +
		"red = foreign (the turret's; nobody predicted them). Turn optimistic off " +
		"with O and your own shot only appears when the server's entity arrives, " +
		"~RTT late.")

# ------------------------------------------------------- harness accessors

## Aim and fire from the acceptance harness, exactly as a click would.
func aim_at(x: float, y: float) -> void:
	_aim_x = x
	_aim_y = y

func fire() -> void:
	_pending_fire = true

func unmount() -> void:
	_recon = null
	_spawns = null
	_predict = null

func on_reconnect() -> void:
	var st = state()
	if st == null or not (st.get("players") is Dictionary): return
	_me = st.get("players").get(_sid)
	if _spawns != null: _spawns.clear()
	_slots.clear()
	_build()
