extends Node
## The GDScript twin of godot-app's Acceptance.cs: APPS_PLAN §7's exit
## criteria replayed against the LIVE server with no hands on the keyboard.
## Needs `pnpm dev --host 0.0.0.0` running.
##
##   godot --headless --path clients/godot-gd-app res://Acceptance.tscn
##
## Same checks, same thresholds, same failure messages as the C# twin. No
## exceptions in GDScript, so `check()` records the FIRST failure per test
## and the runner reads `_fail_msg`. Exits 0 on green.

const ENDPOINT := "ws://127.0.0.1:5173"
const TEST_TIMEOUT_MS := 120000.0

var _passed := 0
var _total := 0
var _failures: Array[String] = []
var _fail_msg := ""
var _test_deadline := 0.0

## Callable-overhead measurement (M3 deliverable) — filled by its test,
## quoted in the README.
var _tick_report := ""

static func now_ms() -> float:
	return float(Time.get_ticks_usec()) / 1000.0

func check(cond: bool, msg: String) -> bool:
	if not cond and _fail_msg == "":
		_fail_msg = msg
	return cond

func _client() -> Colyseus.Client:
	return Colyseus.Client.new(ENDPOINT)

func _ready() -> void:
	_run_all()

func _run_all() -> void:
	await get_tree().process_frame   # let the tree settle before the first join

	var tests := [
		["sim_reproduces_the_reference_numbers", _t_selfcheck],
		["lab01_input_to_motion_tracks_the_round_trip", _t_lab01],
		["lab02_clock_readouts_respond_to_injected_latency", _t_lab02],
		["lab03_predicts_instantly_and_absorbs_a_mispredict", _t_lab03],
	]
	_total = tests.size()

	for t in tests:
		NetDelay.reset()
		Kb.autopilot = true
		Kb.auto_x = 0
		Kb.auto_y = 0
		_fail_msg = ""
		_test_deadline = now_ms() + TEST_TIMEOUT_MS
		await t[1].call()
		if _fail_msg == "":
			_passed += 1
			print("PASS %s" % t[0])
		else:
			_failures.append("%s: %s" % [t[0], _fail_msg])
			printerr("FAIL %s: %s" % [t[0], _fail_msg])

	Kb.autopilot = false
	print("ACCEPT OK %d/%d" % [_passed, _total] if _failures.is_empty()
		else "ACCEPT FAIL %d/%d" % [_passed, _total])
	for f in _failures:
		print("  " + f)
	get_tree().quit(0 if _failures.is_empty() else 1)

# --------------------------------------------------------------- plumbing

## Pump the injector + a lab for `ms`, exactly like _process does.
func drive(lab: LabBase, app: App, ms: float, ax := 0, ay := 0, on_frame := Callable()) -> void:
	Kb.autopilot = true
	Kb.auto_x = ax
	Kb.auto_y = ay
	var start := now_ms()
	var last := start
	while now_ms() - start < ms:
		if now_ms() > _test_deadline:
			check(false, "watchdog: test exceeded %.0f ms" % TEST_TIMEOUT_MS)
			return
		Colyseus.poll()
		NetDelay.pump_all()
		var n := now_ms()
		if lab != null:
			lab.frame(app, n, n - last)
		last = n
		if on_frame.is_valid():
			on_frame.call(n - start)
		await get_tree().process_frame

func mount(lab: LabBase, app: App) -> bool:
	print("[acceptance] mounting %s" % lab.id)
	var ok: bool = await lab.mount(app)
	if not check(ok, "%s mount failed / state never arrived" % lab.id):
		return false
	print("[acceptance] mounted %s" % lab.id)
	return true

func teardown(lab: LabBase) -> void:
	lab.unmount()
	if lab.room == null:
		return
	lab.room.leave()
	var deadline := now_ms() + 5000.0
	while lab.room.connected and now_ms() < deadline:
		Colyseus.poll()
		NetDelay.pump_all()
		await get_tree().process_frame

# ------------------------------------------------------------------ tests

func _t_selfcheck() -> void:
	# The canary the app runs at startup: a constant typo can never ship.
	check(Sim.selfcheck() == 0, "shared-sim port diverged from the TypeScript original")

func _t_lab01() -> void:
	var app := App.new()
	app.client = _client()
	app.private_room = true
	NetDelay.set_latency(0, 0)
	var lab := Lab01.new()
	if await mount(lab, app):
		# At rest first: the meter arms on a key press from a standstill.
		await drive(lab, app, 800)
		await drive(lab, app, 1600, 1)
		var at_zero := lab.measured
		check(at_zero > 0, "meter never armed at 0 injected latency")
		check(at_zero < 250, "input->motion %.0f ms at 0 injected — expected ~one patch interval" % at_zero)

		# Now with 200 ms each way; no prediction, so it must track the round trip.
		await drive(lab, app, 900)
		NetDelay.set_latency(200, 0)
		await drive(lab, app, 1200)
		await drive(lab, app, 2000, -1)
		var at200 := lab.measured
		check(at200 > 300, "input->motion %.0f ms at 200 ms injected — latency not felt" % at200)
		print("OK lab01: %.0f ms at 0 injected, %.0f ms at 200 ms" % [at_zero, at200])
	await teardown(lab)

func _t_lab02() -> void:
	var app := App.new()
	app.client = _client()
	app.private_room = true
	NetDelay.set_latency(200, 0)
	var lab := Lab02.new()
	if await mount(lab, app):
		await drive(lab, app, 4000, 1)
		var clock = lab.clock()
		check(clock.smoothed_rtt() > 350,
			"smoothed rtt %.0f ms — the injector is not in the path" % clock.smoothed_rtt())
		check(clock.last_server_time() > 0, "no TIMED prefix: the clock never synced")
		check(clock.patch_interval() > 0, "patch cadence never advertised")
		print("OK lab02: rtt %.0f ms, patch %.0f ms, jitter %.1f ms" % [
			clock.smoothed_rtt(), clock.patch_interval(), clock.jitter()])
	await teardown(lab)

func _t_lab03() -> void:
	var app := App.new()
	app.client = _client()
	app.private_room = true
	NetDelay.set_latency(200, 0)
	var lab := Lab03.new()
	if await mount(lab, app):
		var recon = lab.lane.recon
		await drive(lab, app, 4000, -1)

		# Predicted while ~RTT worth of inputs are still unacked, and the
		# shared step reproduces the server's math to wire precision.
		check(recon.pending_count > 0, "nothing in flight — inputs are not being predicted")
		check(recon.drift_ema < 0.01,
			"drift ema %f — the client's step disagrees with the server's" % recon.drift_ema)
		print("OK lab03 predicted: %d in flight, drift ema %f" % [recon.pending_count, recon.drift_ema])

		# A server-side shove the client cannot see coming MUST mispredict...
		lab.room.send_message("impulse", null)
		await drive(lab, app, 1500)
		var peak := lab.lane.max_correction_mag
		check(peak > 0.05, "the impulse produced no visible correction")

		# ...and then decay back to steady state.
		await drive(lab, app, 5000, 1)
		check(recon.last_correction_mag < 0.05,
			"corrections still %.3f after 5 s — not converging" % recon.last_correction_mag)
		print("OK lab03 impulse: peak %.3f, settled to %.4f" % [peak, recon.last_correction_mag])
	await teardown(lab)
