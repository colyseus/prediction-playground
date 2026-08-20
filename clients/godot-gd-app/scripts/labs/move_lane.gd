class_name MoveLane
extends RefCounted
## The reconciled `lab-move` lane: join, predict, reconcile, send.
##
## Labs 00 and 03 are the SAME netcode behind different renderers — the split
## screen is a render-layer choice over one entity in one room — so the lane
## lives here and neither lab owns it.

var room = null            # Colyseus.Room
var predict = null         # Colyseus.Predict
var recon = null           # Colyseus.Reconciler
## The raw authoritative pose (decoded Dictionary) — it trails by ~RTT.
var me = null
var sid := ""

## Corrections past the noise floor, and the largest seen.
var corrections := 0
var max_correction_mag := 0.0

## reset() on a teleport-class correction: a cut, not a glide.
var auto_snap := true
var smooth_ms := 65.0

## Cost of the last predict.tick() call in usec — the Callable-overhead
## readout the acceptance run records at 400 ms injected latency.
var tick_us := 0

var _input = null
var _last_reconcile_seq := 0

## The predicted pose: what the local player should be looking at.
func x() -> float: return recon.value("x")
func y() -> float: return recon.value("y")

func join(app: App) -> bool:
	room = await Shell.join_lab(app, "lab-move", func(r):
		var st = r.get_state()
		return st is Dictionary and st.get("players") is Dictionary \
			and st.get("players").has(r.get_session_id()))
	if room == null: return false
	sid = room.get_session_id()
	var st = room.get_state()
	if not (st is Dictionary) or not (st.get("players") is Dictionary): return false
	me = st.get("players").get(sid)
	if me == null: return false

	_input = room.input()
	if _input == null: return false
	predict = Colyseus.Predict.of(room)
	# Remote squares: damped toward the latest snapshot. Their inputs are not
	# ours to predict — lab 04 explores the modes.
	predict.attach_all("players", {
		"x": Colyseus.Predict.DAMPED, "y": Colyseus.Predict.DAMPED,
	}, sid)
	build(smooth_ms)
	return true

## Rebuild the reconciler — smoothing is taken at construction.
func build(s: float) -> void:
	smooth_ms = s
	recon = predict.reconciler(me, {
		"input": _input,
		"fields": ["x", "y", "vx", "vy"],
		"smooth_ms": s,
		# The SAME function the server runs — determinism is the contract.
		"step": _step,
	})
	_last_reconcile_seq = 0

func _step(ctx, s, cmd) -> void:
	Sim.step_entity(s, float(cmd.moveX), float(cmd.moveY), ctx.dt)

## One frame of netcode: advance the stack, send the inputs it says are due,
## and fold in whatever the latest reconcile reported.
func drive(now: float, move_x: int, move_y: int) -> void:
	var t0 := Time.get_ticks_usec()
	var steps: int = predict.tick(now)
	tick_us = Time.get_ticks_usec() - t0
	for i in steps:
		_input.data.moveX = move_x
		_input.data.moveY = move_y
		_input.send()

	if recon.reconcile_seq == _last_reconcile_seq: return
	_last_reconcile_seq = recon.reconcile_seq
	var mag: float = recon.last_correction_mag
	if mag > 0.02:
		corrections += 1
		max_correction_mag = maxf(max_correction_mag, mag)
	if auto_snap and mag > Sim.TELEPORT_SNAP_DIST: recon.reset()

## The predicted pose of a remote square (damped, not reconciled).
func remote_x(p) -> float: return predict.value(p, "x")
func remote_y(p) -> float: return predict.value(p, "y")

## The LATEST decoded pose of our own player. get_state() returns a fresh
## snapshot Dictionary per call, so the mount-time `me` freezes — raw echo
## reads must re-fetch. `me` itself stays valid as the predict/build handle
## (instances resolve by __ref_id, which is stable).
func me_now():
	var st = room.get_state()
	if st is Dictionary and st.get("players") is Dictionary:
		var m = st.get("players").get(sid)
		if m != null: return m
	return me

## After a reconnect: rebind to the fresh entity and start the buffer over.
func rebind() -> void:
	var st = room.get_state()
	if st is Dictionary and st.get("players") is Dictionary \
			and st.get("players").has(sid):
		me = st.get("players").get(sid)
	build(smooth_ms)

func dispose() -> void:
	recon = null
	predict = null
