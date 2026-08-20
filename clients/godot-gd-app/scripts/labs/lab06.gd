class_name Lab06
extends LabBase
## Lab 06 — Lag Compensation.
##
## The client's job is only to be HONEST about its display timeline:
##  - bots are DRAWN with lerp, REMOTE_INTERP_MS in the past;
##  - the server records bot history and, on a fire input, rewinds every
##    target to this client's render time — the instant the shooter aimed at;
##  - set_rewind_field("fire") stamps the render time ONLY on fire frames.
##
## Markers: blue = what you saw · green = the server's rewound read · red =
## the server's live position. With lag comp on they coincide.
## Port of labs/06-lag-comp/.

const MAX_SHOTS := 6
const SHOT_FADE_MS := 2600.0

var _predict = null
var _recon = null
var _input = null
var _me = null
var _bot = null
var _sid := ""

var _aim_x := 50.0
var _aim_y := 20.0
var _pending_fire := false
## Shots: [ox, oy, tx, ty, blue_x, blue_y, green_x, green_y, red_x, red_y,
##         answered, hit, t, predicted_hit]
var _shots: Array = []
var hits_on := 0
var shots_on := 0
var hits_off := 0
var shots_off := 0
## Shots this screen called a hit at the click, before any report.
var predicted_hits := 0

func _init() -> void:
	id = "06-lag-comp"
	num = 6
	title = "Lag Compensation"
	blurb = "The server rewinds targets to what you saw."

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
	# Bots ride the lerp timeline — the one the server rewinds to. Attach
	# BEFORE the reconciler is built: reconciler creation binds the input
	# handle's renderDelay from this Predict's lerp delay.
	var lerp_opts := { "mode": Colyseus.Predict.LERP, "delay": Sim.REMOTE_INTERP_MS }
	_predict.attach_all("bots", { "x": lerp_opts, "y": lerp_opts })
	_predict.attach_all("players", {
		"x": Colyseus.Predict.DAMPED, "y": Colyseus.Predict.DAMPED,
	}, _sid)

	room.message_received.connect(_on_message)

	_input = room.input()
	if _input == null: return false
	# Stamp the lag-comp render time on fire frames only.
	_input.set_rewind_field("fire")
	_build()
	app.set_latency_preset(2)   # lag comp says nothing on a 1 ms link
	return true

func _build() -> void:
	_recon = _predict.reconciler(_me, {
		"input": _input,
		"fields": ["x", "y", "vx", "vy"],
		"smooth_ms": 65.0,
		"step": func(ctx, s, cmd): Sim.step_entity(s, float(cmd.moveX), float(cmd.moveY), ctx.dt),
	})

## The server's shot report completes the oldest unanswered record.
func _on_message(type, msg) -> void:
	if type != "shot" or not (msg is Dictionary): return
	if msg.get("sid") != _sid: return
	var hit: bool = msg.get("hit", false) == true
	var lag_comp: bool = msg.get("lagComp", false) == true

	for s in _shots:
		if s[10]: continue
		s[10] = true
		s[11] = hit
		s[6] = float(msg.get("seenX", 0.0))
		s[7] = float(msg.get("seenY", 0.0))
		s[8] = float(msg.get("liveX", 0.0))
		s[9] = float(msg.get("liveY", 0.0))
		break
	if lag_comp:
		shots_on += 1
		if hit: hits_on += 1
	else:
		shots_off += 1
		if hit: hits_off += 1

func frame(app: App, now: float, _dt_ms: float) -> void:
	var v := app.view
	var mouse := Kb.mouse_pos
	var over_stage := mouse.x < app.stage.end.x
	if Kb.autopilot:
		# The acceptance script has no cursor — track the target it fires at.
		_aim_x = _predict.value(_bot, "x")
		_aim_y = _predict.value(_bot, "y")
	elif over_stage:
		_aim_x = v.wx(mouse.x)
		_aim_y = v.wy(mouse.y)
	if over_stage and Kb.mouse_down(): _pending_fire = true
	if Kb.key(KEY_SPACE): _pending_fire = true
	if Kb.key(KEY_C):
		room.send_message("lagcomp", { "on": not bool(state().get("lagComp", false)) })

	var steps: int = _predict.tick(now)
	for i in steps:
		_input.data.moveX = Kb.move_x()
		_input.data.moveY = Kb.move_y()
		_input.data.aimX = _aim_x
		_input.data.aimY = _aim_y
		_input.data.fire = 1.0 if _pending_fire else 0.0
		_input.send()
		if not _pending_fire: continue
		_record_shot(now)
		_pending_fire = false

## Record what THIS screen showed at the moment of the shot.
func _record_shot(now: float) -> void:
	var px: float = _recon.state.x
	var py: float = _recon.state.y
	var dx := _aim_x - px
	var dy := _aim_y - py
	var len := sqrt(dx * dx + dy * dy)
	if len < 1e-9: len = 1.0
	dx /= len
	dy /= len
	var bx: float = _predict.value(_bot, "x")
	var by: float = _predict.value(_bot, "y")
	# The server's own hit test, run against the pose THIS screen was showing.
	# Available immediately, and it agrees with the server whenever the rewind
	# lands where it should.
	var predicted: bool = Sim.ray_circle(px, py, dx, dy, bx, by, Sim.BOT_RADIUS, Sim.SHOT_RANGE) >= 0.0
	if predicted: predicted_hits += 1
	if _shots.size() == MAX_SHOTS: _shots.pop_front()
	_shots.append([px, py, px + dx * 120, py + dy * 120,
		bx, by,
		0.0, 0.0, 0.0, 0.0, false, false, now, predicted])

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
	Draw.label(v, bx, by, "target (lerp view)", Palette.BLUE, 10, -v.s(Sim.BOT_RADIUS) - 14)

	Draw.dashed_world(v, px, py, _aim_x, _aim_y, Palette.a(Palette.TEXT, 0.18))
	Draw.circle_outline(v, _aim_x, _aim_y, 0.9, Palette.a(Palette.TEXT, 0.7))

	for i in range(_shots.size() - 1, -1, -1):
		var s: Array = _shots[i]
		var age: float = now - s[12]
		if age > SHOT_FADE_MS:
			_shots.remove_at(i)
			continue
		var a := 1.0 - age / SHOT_FADE_MS
		# Until the report lands the ray wears this screen's own verdict, faint;
		# the server's answer replaces it at full strength. A ray that flips
		# colour is the rewind disagreeing with what you saw.
		var verdict: bool = s[11] if s[10] else s[13]
		var ray: Color = Palette.a(Palette.GOOD if verdict else Palette.BAD,
			a * (0.7 if s[10] else 0.3))
		Draw.line(Vector2(v.sx(s[0]), v.sy(s[1])), Vector2(v.sx(s[2]), v.sy(s[3])), ray, 1.2)
		Draw.circle_outline(v, s[4], s[5], Sim.BOT_RADIUS * 0.7, Palette.a(Palette.BLUE, a))
		if not s[10]: continue
		Draw.circle_outline(v, s[6], s[7], Sim.BOT_RADIUS * 0.85, Palette.a(Palette.GOOD, a))
		Draw.circle_outline(v, s[8], s[9], Sim.BOT_RADIUS, Palette.a(Palette.BAD, a))

	var h := app.hud
	h.section("TELEMETRY")
	h.row("hits (lag comp ON)", "%d / %d" % [hits_on, shots_on],
		Palette.GOOD if shots_on > 0 and hits_on * 10 > shots_on * 7 else Palette.TEXT)
	h.row("hits (lag comp OFF)", "%d / %d" % [hits_off, shots_off],
		Palette.BAD if shots_off > 0 and hits_off * 2 < shots_off else Palette.TEXT)
	var gap := view_lag()
	h.row("view lag (red<->blue gap)", "%.1f u" % gap if gap >= 0 else "--",
		Palette.TEXT if gap >= 0 else Palette.TEXT_FAINT)

	h.section("CONTROLS")
	h.key("WASD", "drive (predicted)")
	h.key("mouse", "aim")
	h.key("click / SPACE", "fire")
	h.key("C", "lag comp: ON (room-wide)" if bool(st.get("lagComp", false)) else "lag comp: OFF (room-wide)")
	h.note("blue = what you saw — green = the server's rewound read — red = the " +
		"server live. The ray shows your own verdict faintly at the click, then " +
		"the server's at full strength. Turn lag comp off at 200 ms and you have " +
		"to lead the target by exactly the red-to-blue gap.")

# ------------------------------------------------------- harness accessors

## Newest answered shot's red-blue distance; -1 if none yet.
func view_lag() -> float:
	for i in range(_shots.size() - 1, -1, -1):
		var s: Array = _shots[i]
		if not s[10]: continue
		var dx: float = s[8] - s[4]
		var dy: float = s[9] - s[5]
		return sqrt(dx * dx + dy * dy)
	return -1.0

## The rewind error the server actually made (green vs blue), in world units.
func rewind_error_u() -> float:
	for i in range(_shots.size() - 1, -1, -1):
		var s: Array = _shots[i]
		if not s[10]: continue
		var dx: float = s[6] - s[4]
		var dy: float = s[7] - s[5]
		return sqrt(dx * dx + dy * dy)
	return -1.0

## Fire from the acceptance harness, exactly as a click would.
func fire() -> void:
	_pending_fire = true

func set_lag_comp(on: bool) -> void:
	room.send_message("lagcomp", { "on": on })

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
