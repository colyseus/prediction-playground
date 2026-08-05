class_name Lab11
extends LabBase
## Lab 11 — Deterministic Randomness.
##
## The shotgun fan is "random", yet the client predicts every pellet EXACTLY
## — because the randomness is a pure function of data both sides already
## share:  seed = splitmix32(input seq ^ room salt) -> mulberry32 stream.
## The seq is the engine's own input counter (send() returns it); the salt is
## synced room state. NOTHING about the pellets rides the wire — the server's
## broadcast carries its angles only so this lab can overlay and compare.
## Port of labs/11-deterministic-rng/.

const FAN_LEN := 40.0
const MAX_FANS := 4
const FAN_FADE_MS := 2400.0

var _predict = null
var _recon = null
var _input = null
var _me = null
var _bot = null
var _sid := ""

var _aim_x := 50.0
var _aim_y := 20.0
var _pending_fire := false
var cheat := false
var _cheat_rng := Sim.Rng.new(0x1234567)

## Fans: [seq, ox, oy, client: Array, server: Array, answered, hits, t]
var _fans: Array = []
var _max_divergence := 0.0
var _has_divergence := false

func _init() -> void:
	id = "11-deterministic-rng"
	num = 11
	title = "Deterministic Randomness"
	blurb = "Same seed both sides, nothing on the wire."

func mount(app: App) -> bool:
	room = await Shell.join_lab(app, "lab-range", func(r):
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
	# Bots ride the lerp timeline — the one the server rewinds to.
	var lerp_opts := { "mode": Colyseus.Predict.LERP, "delay": Sim.REMOTE_INTERP_MS }
	_predict.attach_all("bots", { "x": lerp_opts, "y": lerp_opts })
	_predict.attach_all("players", {
		"x": Colyseus.Predict.DAMPED, "y": Colyseus.Predict.DAMPED,
	}, _sid)

	room.message_received.connect(_on_message)

	_input = room.input()
	if _input == null: return false
	_input.set_rewind_field("fire")
	_build()
	return true

func _build() -> void:
	_recon = _predict.reconciler(_me, {
		"input": _input,
		"fields": ["x", "y", "vx", "vy"],
		"smoothing": 15.0,
		"step": func(ctx, s, cmd): Sim.step_entity(s, float(cmd.moveX), float(cmd.moveY), ctx.dt),
	})

## The client's half of the derivation — identical to the server's.
func _client_fan(base_angle: float, seq: int, salt: int) -> Array:
	if not cheat:
		return Sim.spread_angles(base_angle, seq, salt)
	# The broken version: a local RNG the server cannot reproduce.
	var out := []
	for i in Sim.PELLETS:
		out.append(base_angle + (_cheat_rng.next() - 0.5) * Sim.SPREAD_RAD)
	return out

## The server's fan for the same (seq, salt) — for overlay only.
func _on_message(type, msg) -> void:
	if type != "spread" or not (msg is Dictionary): return
	if msg.get("sid") != _sid: return
	var seq := int(msg.get("seq", -1))
	var fan = null
	for f in _fans:
		if f[0] == seq:
			fan = f
			break
	if fan == null: return
	var angles = msg.get("angles")
	if not (angles is Array): return

	var worst := 0.0
	for i in mini(angles.size(), Sim.PELLETS):
		fan[4][i] = float(angles[i])
		worst = maxf(worst, absf(float(fan[3][i]) - float(fan[4][i])))
	if msg.has("hits"): fan[6] = int(msg.get("hits"))
	fan[5] = true
	_max_divergence = worst
	_has_divergence = true

func frame(app: App, now: float, _dt_ms: float) -> void:
	var v := app.view
	var mouse := Kb.mouse_pos
	var over_stage := mouse.x < app.stage.end.x
	if Kb.autopilot:
		_aim_x = _predict.value(_bot, "x")
		_aim_y = _predict.value(_bot, "y")
	elif over_stage:
		_aim_x = v.wx(mouse.x)
		_aim_y = v.wy(mouse.y)
	if over_stage and Kb.mouse_down(): _pending_fire = true
	if Kb.key(KEY_SPACE): _pending_fire = true
	if Kb.key(KEY_X): cheat = not cheat

	var salt := int(state().get("salt", 0)) if state() != null else 0

	var steps: int = _predict.tick(now)
	for i in steps:
		_input.data.moveX = Kb.move_x()
		_input.data.moveY = Kb.move_y()
		_input.data.aimX = _aim_x
		_input.data.aimY = _aim_y
		_input.data.fire = 1.0 if _pending_fire else 0.0
		_input.data.spread = 1.0
		var seq: int = _input.send()
		if not _pending_fire or seq <= 0: continue

		var px: float = _recon.state.x
		var py: float = _recon.state.y
		var client := _client_fan(atan2(_aim_y - py, _aim_x - px), seq, salt)
		var server := []
		server.resize(Sim.PELLETS)
		server.fill(0.0)
		if _fans.size() == MAX_FANS: _fans.pop_front()
		_fans.append([seq, px, py, client, server, false, -1, now])
		_pending_fire = false

func render(app: App) -> void:
	var v := app.view
	var now := float(Time.get_ticks_usec()) / 1000.0
	var st = state()
	if st != null and st.get("players") is Dictionary:
		var players = st.get("players")
		for k in players:
			if k == _sid: continue
			var p = players[k]
			Draw.square(v, _predict.value(p, "x"), _predict.value(p, "y"),
				Sim.PLAYER_HALF, Palette.hue(int(p.get("hue", 0)), 0.4))

	var px: float = _recon.value("x")
	var py: float = _recon.value("y")
	Draw.square(v, px, py, Sim.PLAYER_HALF, Palette.hue(int(_me.get("hue", 0))))
	Draw.square_outline(v, px, py, Sim.PLAYER_HALF, Palette.TEXT)

	var bx: float = _predict.value(_bot, "x")
	var by: float = _predict.value(_bot, "y")
	Draw.circle(v, bx, by, Sim.BOT_RADIUS, Palette.a(Palette.BLUE, 0.25))
	Draw.circle_outline(v, bx, by, Sim.BOT_RADIUS, Palette.BLUE)
	Draw.circle_outline(v, _aim_x, _aim_y, 0.9, Palette.a(Palette.TEXT, 0.7))

	for i in range(_fans.size() - 1, -1, -1):
		var f: Array = _fans[i]
		var age: float = now - f[7]
		if age > FAN_FADE_MS:
			_fans.remove_at(i)
			continue
		var a := 1.0 - age / FAN_FADE_MS
		for p in Sim.PELLETS:
			var ang: float = f[3][p]
			Draw.line(Vector2(v.sx(f[1]), v.sy(f[2])),
				Vector2(v.sx(f[1] + cos(ang) * FAN_LEN), v.sy(f[2] + sin(ang) * FAN_LEN)),
				Palette.a(Palette.WARN, a * 0.75), 1.2)
		if not f[5]: continue
		for p in Sim.PELLETS:
			var ang: float = f[4][p]
			Draw.dashed_world(v, f[1], f[2],
				f[1] + cos(ang) * FAN_LEN, f[2] + sin(ang) * FAN_LEN,
				Palette.a(Palette.TEXT, a * 0.9), 0.8)
	if _fans.size() > 0:
		var last: Array = _fans[-1]
		Draw.label(v, last[1], last[2], "amber = client — white = server",
			Palette.a(Palette.TEXT, 0.5), 9, v.s(Sim.PLAYER_HALF) + 4)

	var last_hits := -1
	for i in range(_fans.size() - 1, -1, -1):
		if _fans[i][5]:
			last_hits = _fans[i][6]
			break

	var h := app.hud
	h.section("TELEMETRY")
	h.row("fan divergence (last shot)",
		"%.5f rad" % _max_divergence if _has_divergence else "--",
		Palette.TEXT_FAINT if not _has_divergence
			else (Palette.GOOD if _max_divergence < 1e-6 else Palette.BAD))
	h.row("pellets hit (last shot)",
		"%d / %d" % [last_hits, Sim.PELLETS] if last_hits >= 0 else "--",
		Palette.TEXT if last_hits >= 0 else Palette.TEXT_FAINT)
	h.row("room salt", str(int(st.get("salt", 0))), Palette.TEXT)
	h.row("shots (authoritative)", str(int(_me_now().get("shots", 0))), Palette.TEXT)

	h.section("CONTROLS")
	h.key("WASD", "drive")
	h.key("mouse", "aim")
	h.key("click / SPACE", "fire a 6-pellet fan")
	h.key("X", "CHEATING with a local RNG" if cheat else "seeded from (seq, salt)")
	h.note("Amber = the fan your client derived at the click. White dashes = the fan " +
		"the server derived from the same (seq, salt). They should be identical to " +
		"the pixel. Press X to swap in an unshared RNG and watch them disagree.")

# ------------------------------------------------------- harness accessors

func _me_now():
	var st = state()
	if st != null and st.get("players") is Dictionary:
		var m = st.get("players").get(_sid)
		if m != null: return m
	return _me

## Fire from the acceptance harness, exactly as a click would.
func fire() -> void:
	_pending_fire = true

## Worst client-server pellet disagreement, in radians. NAN until answered.
func max_divergence() -> float:
	return _max_divergence if _has_divergence else NAN

func answered_fans() -> int:
	var n := 0
	for f in _fans:
		if f[5]: n += 1
	return n

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
