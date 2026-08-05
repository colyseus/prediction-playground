class_name Lab00
extends LabBase
## Lab 00 — Lag vs Prediction (the hero).
##
## Runs lab 03's netcode VERBATIM — same room, same reconciler, same entity,
## via the shared MoveLane. The split screen is a RENDER-layer choice: the top
## lane draws the raw decoded server state (what lab 01 draws), the bottom
## lane draws the reconciler's predicted pose (what lab 03 draws).
## Port of labs/00-split/.

## Reversal-heavy autopilot legs — reversals are where the echo lane visibly
## keeps going the wrong way for a full round trip.
const SCRIPT := [
	[1, 0, 850.0], [-1, 0, 700.0], [1, 0, 550.0], [0, 1, 650.0], [0, -1, 700.0],
	[1, 1, 600.0], [-1, -1, 750.0], [-1, 0, 550.0], [1, 0, 800.0], [0, -1, 500.0],
]

var lane := MoveLane.new()

var _top_trail := Trail.new(120)
var _bot_trail := Trail.new(120)
var _top := WorldView.new()
var _bot := WorldView.new()

var _user_drove := false
var _leg_index := 0
var _leg_x := 1
var _leg_y := 0
var _leg_until := 0.0

func _init() -> void:
	id = "00-split"
	num = 0
	title = "Lag vs Prediction"
	blurb = "Same input, same server — the top lane waits, the bottom predicts."
	own_arena = true   # the shell skips the shared arena: this lab paints two

func mount(app: App) -> bool:
	if not await lane.join(app): return false
	room = lane.room
	# The point of this lab is invisible on a 1 ms localhost link.
	app.set_latency_preset(3)
	return true

## Scripted strides, steered away from a wall when a leg would hug one.
func _autopilot(now: float, x: float, y: float) -> void:
	if now < _leg_until: return
	var leg: Array = SCRIPT[_leg_index % SCRIPT.size()]
	_leg_index += 1
	_leg_x = leg[0]
	_leg_y = leg[1]
	if x > Sim.ARENA_W * 0.72 and _leg_x > 0: _leg_x = -1
	elif x < Sim.ARENA_W * 0.28 and _leg_x < 0: _leg_x = 1
	if y > Sim.ARENA_H * 0.72 and _leg_y > 0: _leg_y = -1
	elif y < Sim.ARENA_H * 0.28 and _leg_y < 0: _leg_y = 1
	_leg_until = now + leg[2]

func frame(_app: App, now: float, _dt_ms: float) -> void:
	if not _user_drove and Kb.any_move(): _user_drove = true
	if not _user_drove: _autopilot(now, lane.x(), lane.y())

	lane.drive(now,
		Kb.move_x() if _user_drove else _leg_x,
		Kb.move_y() if _user_drove else _leg_y)

	var me_fresh = lane.me_now()
	_top_trail.push(me_fresh.get("x", 0.0), me_fresh.get("y", 0.0))
	_bot_trail.push(lane.x(), lane.y())

func render(app: App) -> void:
	# Two lanes stacked in the stage rect.
	var lane_h := app.stage.size.y / 2
	var lane_pad := 22.0
	_top.fit(Rect2(app.stage.position.x, app.stage.position.y + lane_pad,
		app.stage.size.x, lane_h - lane_pad), 26)
	_bot.fit(Rect2(app.stage.position.x, app.stage.position.y + lane_h,
		app.stage.size.x, lane_h - lane_pad), 26)

	var me = lane.me_now()
	var mex: float = me.get("x", 0.0)
	var mey: float = me.get("y", 0.0)
	var hue := int(me.get("hue", 0))
	var px := lane.x()
	var py := lane.y()

	Draw.arena(_top)
	_lane_title(_top, "SERVER ECHO", "every move waits the full round trip",
		Palette.a(Palette.TEXT, 0.85))
	_draw_remotes(_top, false)
	_top_trail.render(_top, Palette.a(Palette.TEXT, 1.0), 1.5, 0.35)
	Draw.square(_top, mex, mey, Sim.PLAYER_HALF, Palette.hue(hue, 0.8))
	Draw.square_outline(_top, mex, mey, Sim.PLAYER_HALF, Palette.a(Palette.TEXT, 0.5))
	Draw.label(_top, mex, mey, "you (server)", Palette.a(Palette.TEXT, 0.6), 11,
		-_top.s(Sim.PLAYER_HALF) - 15)

	Draw.arena(_bot)
	_lane_title(_bot, "PREDICTED", "instant — reconciled against the same server", Palette.GOOD)
	_draw_remotes(_bot, true)
	_bot_trail.render(_bot, Palette.hue(hue), 1.5, 0.45)
	Draw.square(_bot, px, py, Sim.PLAYER_HALF, Palette.hue(hue))
	Draw.square_outline(_bot, px, py, Sim.PLAYER_HALF, Palette.TEXT)
	Draw.label(_bot, px, py, "you (predicted)", Palette.TEXT, 11,
		-_bot.s(Sim.PLAYER_HALF) - 15)

	# Divider readout, with the rule broken around the text.
	var rtt: float = room.clock.smoothed_rtt()
	var divider_y := app.stage.position.y + lane_h
	var cx := app.stage.position.x + app.stage.size.x / 2
	var rule := Palette.a(Palette.TEXT_DIM, 0.25)
	Draw.line(Vector2(app.stage.position.x + 24, divider_y), Vector2(cx - 90, divider_y), rule)
	Draw.line(Vector2(cx + 90, divider_y), Vector2(app.stage.end.x - 24, divider_y), rule)
	Draw.text(cx - 90, divider_y - 9, 180, "ROUND TRIP ~ %.0f ms" % rtt, Palette.ACCENT, 13,
		HORIZONTAL_ALIGNMENT_CENTER)

	var caption := "Same keys, same server — the top lane waits, the bottom predicts." \
		if _user_drove else "> autopilot — press WASD / arrows to take over"
	Draw.text(app.stage.position.x, app.stage.end.y - 20, app.stage.size.x, caption,
		Palette.a(Palette.TEXT_DIM, 0.85), 12, HORIZONTAL_ALIGNMENT_CENTER)

	var h := app.hud
	h.section("TELEMETRY")
	h.row("round trip", "%.0f ms" % rtt,
		Palette.BAD if rtt > 300 else (Palette.WARN if rtt > 120 else Palette.GOOD))
	var gap := Vector2(px, py).distance_to(Vector2(mex, mey))
	h.row("echo trails you by", "%.1f units" % gap, Palette.TEXT)
	h.chips("pending inputs (unacked)", lane.recon.pending_count)

	h.section("CONTROLS")
	h.key("WASD", "drive (autopilot off)" if _user_drove else "take over from the autopilot")
	h.key("L", "injected latency")
	h.note("Render-only split: both lanes are the same entity in the same room, " +
		"running lab 03's netcode verbatim.")

## Titles sit INSIDE the arena — the lane above it is only padding.
static func _lane_title(v: WorldView, main: String, sub: String, c: Color) -> void:
	Draw.text(v.sx(0) + 10, v.sy(0) + 6, 200, main, c, 12)
	Draw.text(v.sx(0) + 10 + 110, v.sy(0) + 7, 340, sub, Palette.a(Palette.TEXT_DIM, 0.75), 11)

func _draw_remotes(v: WorldView, predicted: bool) -> void:
	var st = state()
	if st == null or not (st.get("players") is Dictionary): return
	var players = st.get("players")
	for k in players:
		if k == lane.sid: continue
		var p = players[k]
		var x: float = lane.remote_x(p) if predicted else p.get("x", 0.0)
		var y: float = lane.remote_y(p) if predicted else p.get("y", 0.0)
		Draw.square(v, x, y, Sim.PLAYER_HALF, Palette.hue(int(p.get("hue", 0)), 0.4))

func unmount() -> void:
	lane.dispose()

func on_reconnect() -> void:
	lane.rebind()
	_top_trail.clear()
	_bot_trail.clear()
