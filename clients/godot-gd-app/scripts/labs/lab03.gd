class_name Lab03
extends LabBase
## Lab 03 — Predict & Reconcile. The reconciler OBSERVES the input handle:
## every send() is predicted locally the same instant and buffered. When the
## server's next patch acks input N, it rewinds to the authoritative state and
## REPLAYS inputs N+1.. through the same shared step. Port of labs/03-reconcile/.

## The lane, for the acceptance harness to read telemetry off.
var lane := MoveLane.new()

var _render_smoothed := true
var _show_ghost := true
var _drift_spark := Spark.new()
var _spark_gate := 0.0

func _init() -> void:
	id = "03-reconcile"
	num = 3
	title = "Predict & Reconcile"
	blurb = "Rollback to the ack, replay pending inputs, smooth the error."

func mount(app: App) -> bool:
	if not await lane.join(app): return false
	room = lane.room
	return true

func frame(_app: App, now: float, dt_ms: float) -> void:
	if Kb.key(KEY_I): room.send_message("impulse", null)
	if Kb.key(KEY_T): room.send_message("teleport", null)
	if Kb.key(KEY_V): _render_smoothed = not _render_smoothed
	if Kb.key(KEY_G): _show_ghost = not _show_ghost
	if Kb.key(KEY_N): lane.auto_snap = not lane.auto_snap
	var smooth_step := 5 if Kb.key(KEY_EQUAL) else (-5 if Kb.key(KEY_MINUS) else 0)
	if smooth_step != 0:
		lane.build(clampf(lane.smoothing + smooth_step, 0, 40))

	lane.drive(now, Kb.move_x(), Kb.move_y())

	_spark_gate += dt_ms
	if _spark_gate >= 100:
		_spark_gate = 0
		_drift_spark.push(lane.recon.drift_ema)

func render(app: App) -> void:
	var v := app.view
	var me = lane.me
	var st = state()
	if st != null and st.get("players") is Dictionary:
		var players = st.get("players")
		for k in players:
			if k == lane.sid: continue
			var p = players[k]
			Draw.square(v, lane.remote_x(p), lane.remote_y(p), Sim.PLAYER_HALF,
				Palette.hue(int(p.get("hue", 0)), 0.45))

	# Server ghost: the raw authoritative pose — it trails by ~RTT.
	if _show_ghost:
		Draw.ghost_square(v, me.get("x", 0.0), me.get("y", 0.0), Sim.PLAYER_HALF,
			Palette.a(Palette.TEXT, 0.75))
		Draw.label(v, me.get("x", 0.0), me.get("y", 0.0), "server",
			Palette.a(Palette.TEXT, 0.55), 11, v.s(Sim.PLAYER_HALF) + 4)

	var px: float = lane.x() if _render_smoothed else lane.recon.state.x
	var py: float = lane.y() if _render_smoothed else lane.recon.state.y
	Draw.square(v, px, py, Sim.PLAYER_HALF, Palette.hue(int(me.get("hue", 0))))
	Draw.square_outline(v, px, py, Sim.PLAYER_HALF, Palette.TEXT)
	Draw.label(v, px, py, "you (predicted)", Palette.TEXT, 11, -v.s(Sim.PLAYER_HALF) - 18)

	var recon = lane.recon
	var ema: float = recon.drift_ema
	var status := "matched" if ema < 0.05 else ("jitter" if ema < 1.0 else "diverging")
	var h := app.hud
	h.section("TELEMETRY")
	h.chips("pending inputs (unacked)", recon.pending_count)
	h.row("drift status", status,
		Palette.GOOD if status == "matched" else (Palette.WARN if status == "jitter" else Palette.BAD))
	h.spark(_drift_spark, "drift ema", "%.4f" % ema, Palette.ACCENT)
	h.row("last correction", "%.3f" % recon.last_correction_mag, Palette.TEXT)
	h.row("corrections seen", str(lane.corrections), Palette.TEXT)
	h.row("reconciles", str(recon.reconcile_seq), Palette.TEXT)

	h.section("CONTROLS")
	h.key("WASD", "drive")
	h.key("I", "force mispredict (impulse)")
	h.key("T", "teleport")
	h.key("- / =", "smoothing %.0f /s" % lane.smoothing)
	h.key("V", "render: value() smoothed" if _render_smoothed else "render: state (exact)")
	h.key("G", "server ghost: on" if _show_ghost else "server ghost: off")
	h.key("N", "snap on teleport: on" if lane.auto_snap else "snap on teleport: off")
	h.note("Corrections beyond 8u call reset() — a cut, not a cross-arena glide. " +
		"Turn it off with N and teleport to see why.")

func unmount() -> void:
	lane.dispose()

func on_reconnect() -> void:
	lane.rebind()
