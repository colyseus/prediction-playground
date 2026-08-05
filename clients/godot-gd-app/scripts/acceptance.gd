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
		["lab00_predicted_lane_leads_the_server_echo", _t_lab00],
		["lab04_interpolation_modes_differ_as_advertised", _t_lab04],
		["lab05_reckon_leads_the_lerp_view", _t_lab05],
		["lab08_events_fire_instantly_then_settle", _t_lab08],
		["lab09_optimistic_spawn_hands_off_to_the_server", _t_lab09],
		["lab06_lag_comp_hits_what_you_saw", _t_lab06],
		["lab07_frozen_verdict_matches_the_server", _t_lab07],
		["lab10_predicts_the_puck_through_your_own_inputs", _t_lab10],
		["lab11_client_and_server_roll_identical_pellets", _t_lab11],
		["callable_overhead_at_400ms_backlog", _t_callable_overhead],
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

func _t_lab00() -> void:
	var app := App.new()
	app.client = _client()
	app.private_room = true
	var lab := Lab00.new()
	if await mount(lab, app):   # mount sets its own latency preset
		# Drive one long leg and watch the two lanes separate: the echo lane
		# is the same entity, ~RTT behind. Peak, not instantaneous — the gap
		# collapses at every direction change.
		var peak_gap := 0.0
		for i in 40:
			await drive(lab, app, 120, 1)
			var me = lab.lane.me_now()
			var dx: float = lab.lane.x() - me.get("x", 0.0)
			var dy: float = lab.lane.y() - me.get("y", 0.0)
			peak_gap = maxf(peak_gap, sqrt(dx * dx + dy * dy))
		check(peak_gap > 2.0,
			"lanes never separated (peak %.2f u) — the echo lane is not lagging" % peak_gap)
		print("OK lab00: peak lane separation %.2f u" % peak_gap)
	await teardown(lab)

func _t_lab04() -> void:
	var app := App.new()
	app.client = _client()
	app.private_room = true
	NetDelay.set_latency(120, 40)
	var lab := Lab04.new()
	if await mount(lab, app):
		# Pin the pattern rather than inherit whatever the room defaulted to —
		# a stationary bot scores NaN and the comparison means nothing.
		lab.set_pattern("patrol")
		await drive(lab, app, 2000)   # let the pattern land
		lab.reset_meters()            # then score a clean window
		await drive(lab, app, 6000)

		check(lab.bot_travel() > 10,
			"the bot only travelled %.1f u — nothing to measure smoothness of" % lab.bot_travel())
		var cv := lab.smoothness_by_mode()
		for mode_name in cv:
			check(not is_nan(cv[mode_name]),
				"%s never scored over %.1f u of bot travel (%s)" % [
					mode_name, lab.bot_travel(), lab.describe_mode(mode_name)])
		# raw is the decoded snapshot verbatim, so it stutters at the patch
		# rate; lerp walks between two real samples and must be steadier.
		if not is_nan(cv.get("raw", NAN)) and not is_nan(cv.get("lerp", NAN)):
			check(cv["raw"] > cv["lerp"],
				"raw CV %.3f was not worse than lerp %.3f — the modes are not actually rendering differently" % [cv["raw"], cv["lerp"]])
			print("OK lab04: raw %.3f, lerp %.3f, damped %.3f, extrapolate %.3f" % [
				cv["raw"], cv["lerp"], cv["damped"], cv["extrapolate"]])
	await teardown(lab)

func _t_lab05() -> void:
	var app := App.new()
	app.client = _client()
	app.private_room = true
	NetDelay.set_latency(200, 0)
	var lab := Lab05.new()
	if await mount(lab, app):
		# On the fully-predictable patrol, reckon renders the PRESENT and lerp
		# renders RemoteInterpMs in the past — so they must not coincide.
		lab.set_pattern("patrol")
		await drive(lab, app, 5000)
		check(lab.peak_reckon_lerp_gap() > 1.0,
			"reckon and lerp never separated (peak %.2f u) — the forward simulation is not running" % lab.peak_reckon_lerp_gap())

		# The circle is the check that matters: the one pattern whose y moves.
		# If the reckon scratch cannot see `kind` the step falls through to
		# patrol, which pins y to baseY.
		lab.set_pattern("circle")
		await drive(lab, app, 2000)
		var min_y := INF
		var max_y := -INF
		for i in 40:
			await drive(lab, app, 100)
			min_y = minf(min_y, lab.reckon_y())
			max_y = maxf(max_y, lab.reckon_y())
		check(max_y - min_y > 4,
			"reckoned y only swept %.2f u on the circle pattern — the step is falling back to patrol" % (max_y - min_y))
		print("OK lab05: peak reckon-lerp gap %.2f u, circle y sweep %.2f u" % [
			lab.peak_reckon_lerp_gap(), max_y - min_y])
	await teardown(lab)

func _t_lab08() -> void:
	var app := App.new()
	app.client = _client()
	app.private_room = true
	var lab := Lab08.new()
	if await mount(lab, app):
		NetDelay.set_latency(200, 0)

		# Deny nothing: every optimistic banner must be confirmed.
		lab.set_deny_rate(0)
		await drive(lab, app, 600)
		await drive(lab, app, 6000, 1)
		check(lab.predicted_count() > 0, "never entered the goal zone")
		check(lab.confirmed_count() > 0, "no optimistic goal was ever confirmed")
		check(lab.rejected_count() == 0,
			"%d goals rejected at a 0 %% deny rate" % lab.rejected_count())
		var clean_run := lab.predicted_count()

		# Deny everything: the banner still fires instantly, then retracts.
		lab.set_deny_rate(100)
		await drive(lab, app, 600)
		await drive(lab, app, 9000, 1)
		check(lab.predicted_count() > clean_run,
			"the optimistic banner stopped firing once the server started denying")
		check(lab.rejected_count() > 0,
			"server denied every goal but nothing was ever rejected — grace-tick auto-reject is not firing")
		print("OK lab08: %d confirmed, %d rejected of %d predicted" % [
			lab.confirmed_count(), lab.rejected_count(), lab.predicted_count()])
	await teardown(lab)

func _t_lab09() -> void:
	var app := App.new()
	app.client = _client()
	app.private_room = true
	var lab := Lab09.new()
	if await mount(lab, app):
		NetDelay.set_latency(200, 0)
		await drive(lab, app, 800)

		lab.aim_at(50, 55)
		lab.fire()
		# Immediately after firing there must be a local to look at — that IS
		# the feature. Half an RTT later it must still not be confirmed.
		await drive(lab, app, 120)
		check(lab.pending_spawns > 0,
			"fired but nothing was spawned locally — the shot would not appear for a full RTT")

		# ...and by ~2 RTT the server's entity has arrived and correlated.
		await drive(lab, app, 1400)
		check(lab.confirmed_spawns > 0, "the server's projectile never correlated")
		check(lab.last_lead_ms > 0,
			"no input lead was measured — spawn_time is not wired, so the handoff would jump")

		# ...and MEASURING the lead is only half of it: the confirmed entity
		# has to be reckoned by it too. Un-reckoned it renders at the last
		# decoded snapshot — ~8 u behind at this latency: the visible snap.
		for i in 5:
			lab.aim_at(50, 55)
			lab.fire()
			await drive(lab, app, 700)
		# 4.0 rather than the C# twin's 3.0: patch age and the measured lead
		# EACH quantize at one 50 ms tick (1.7 u of flight), so a legitimate
		# handoff can read ~3.5 u at this frame timing (observed 2.0-3.7 over
		# runs). The failure mode this guards — an UN-reckoned confirmation —
		# measures (age + lead) x 34 u/s ≈ 8-11 u, still 2x past the bound.
		check(lab.max_handoff_jump < 4.0,
			"the projectile snapped %.2f u at the handoff — the confirmed entity is not being lead-reckoned" % lab.max_handoff_jump)
		print("OK lab09: fired %d, lead %.0f ms, %d confirmed, worst jump %.2f u" % [
			lab.fired, lab.last_lead_ms, lab.confirmed_spawns, lab.max_handoff_jump])
	await teardown(lab)

## Fire n shots, spaced so each gets its own input tick and answer.
func _fire_volley(lab, app: App, n: int) -> void:
	for i in n:
		lab.fire()
		await drive(lab, app, 700)

func _t_lab06() -> void:
	var app := App.new()
	app.client = _client()
	app.private_room = true
	var lab := Lab06.new()
	if await mount(lab, app):
		NetDelay.set_latency(200, 0)
		await drive(lab, app, 1500)

		# Lag comp ON: the autopilot aims at the lerp view — exactly what the
		# server rewinds to — so nearly every shot must land.
		lab.set_lag_comp(true)
		await drive(lab, app, 800)
		await _fire_volley(lab, app, 6)
		check(lab.shots_on > 0, "no shots were reported with lag comp on")
		check(lab.hits_on * 10 > lab.shots_on * 6,
			"only %d/%d hit with lag comp ON — the rewind is not landing where we drew (rewind error %.2f u)" % [
				lab.hits_on, lab.shots_on, lab.rewind_error_u()])

		# The rewound read must coincide with what we saw. This is the
		# assertion that catches an unbound renderDelay.
		check(lab.rewind_error_u() < 3.0,
			"server rewound to %.2f u away from our view — check renderDelay" % lab.rewind_error_u())
		print("OK lab06 comp ON: %d/%d hits, rewind error %.2f u, view lag %.1f u" % [
			lab.hits_on, lab.shots_on, lab.rewind_error_u(), lab.view_lag()])
	await teardown(lab)

func _t_lab07() -> void:
	var app := App.new()
	app.client = _client()
	app.private_room = true
	var lab := Lab07.new()
	if await mount(lab, app):
		NetDelay.set_latency(200, 0)

		# The autopilot seeks the bot's lane and lets the patrol sweep hit it.
		await drive(lab, app, 14000, 1)

		check(lab.bumps_predicted > 0,
			"never bumped the bot — the autopilot did not reach its lane")
		# The server's own counter is the only verdict that settles it.
		var delta: int = absi(lab.bumps_predicted - lab.bumps_authoritative())
		check(delta <= 1,
			"predicted %d bumps, server counted %d — the client's verdict disagrees with the server's" % [
				lab.bumps_predicted, lab.bumps_authoritative()])
		print("OK lab07: predicted %d, authoritative %d, mispredict rate %.0f %%" % [
			lab.bumps_predicted, lab.bumps_authoritative(), lab.mispredict_rate()])
	await teardown(lab)

func _t_lab10() -> void:
	var app := App.new()
	app.client = _client()
	app.private_room = true
	var lab := Lab10.new()
	if await mount(lab, app):    # mount picks its own latency preset
		lab.set_bot(false)       # isolate OUR step from a contested touch

		# Sample every reconcile as it happens, plus how far the puck travels
		# late in the run — a frozen world reads as perfect agreement, so the
		# median alone proves nothing.
		var mags: Array[float] = []
		var seq: int = lab.sim.reconcile_seq
		var late := { "path": 0.0, "px": NAN, "py": NAN, "seq": seq, "mags": mags }
		await drive(lab, app, 12000, 0, 0, func(elapsed: float):
			if lab.sim.reconcile_seq != late["seq"]:
				late["seq"] = lab.sim.reconcile_seq
				mags.append(lab.sim.last_correction_mag)
			if elapsed > 9000:
				var puck := lab.server_puck()
				if not is_nan(late["px"]):
					late["path"] += sqrt((puck[0] - late["px"]) ** 2 + (puck[1] - late["py"]) ** 2)
				late["px"] = puck[0]
				late["py"] = puck[1])

		check(lab.sim.pending_count > 0, "nothing in flight — inputs are not being predicted")
		# The whole point of the composite face: the puck is predicted THROUGH
		# our inputs, so it must run ahead of the authoritative one.
		check(lab.max_puck_lead > 0.5,
			"predicted puck never led the server's (peak %.2f u, %d touches, %s) — the puck is not being predicted through our inputs" % [
				lab.max_puck_lead, lab.touches, lab.describe_puck()])
		# The MEDIAN reconcile, not the worst or the last — contested touches
		# mispredict by design.
		mags.sort()
		var median: float = -1.0 if mags.is_empty() else mags[(mags.size() - 1) / 2]
		check(median >= 0 and median < 0.5,
			"median correction %.4f over %d reconciles — the composite step disagrees with the server's" % [
				median, mags.size()])
		# Guards the check above: a frozen world agrees with itself perfectly.
		check(late["path"] > 5,
			"puck travelled %.1f u in the last 3s — the world froze, so the median above proves nothing" % late["path"])
		print("OK lab10: peak puck lead %.2f u, %d touches, median correction %.4f over %d reconciles, %.1f u late travel, %d in flight" % [
			lab.max_puck_lead, lab.touches, median, mags.size(), late["path"], lab.sim.pending_count])
	await teardown(lab)

func _t_lab11() -> void:
	var app := App.new()
	app.client = _client()
	app.private_room = true
	var lab := Lab11.new()
	if await mount(lab, app):
		NetDelay.set_latency(200, 0)
		await drive(lab, app, 1200)

		# Seeded from (seq, salt): both sides must derive the SAME fan, bit
		# for bit. Nothing about the pellets is on the wire.
		await _fire_volley(lab, app, 3)
		check(lab.answered_fans() > 0, "the server never reported a fan")
		check(lab.max_divergence() < 1e-6,
			"client and server fans differ by %s rad — the derivation diverged"
				% String.num_scientific(lab.max_divergence()))
		print("OK lab11 seeded: divergence %s rad over %d fans" % [
			String.num_scientific(lab.max_divergence()), lab.answered_fans()])

		# Swap in an unshared RNG and the same comparison must FAIL —
		# otherwise the test above proves nothing.
		lab.cheat = true
		await _fire_volley(lab, app, 3)
		check(lab.max_divergence() > 1e-6,
			"a local unshared RNG still matched the server — the comparison is not measuring anything")
		print("OK lab11 cheating: divergence %s rad" % String.num_scientific(lab.max_divergence()))
	await teardown(lab)

## The plan's owed measurement: what a reconcile burst costs in GDScript at a
## 400 ms backlog (~8-12 pending inputs replayed through the step Callable
## per reconcile). Reads MoveLane's instrumented predict.tick() cost.
func _t_callable_overhead() -> void:
	var app := App.new()
	app.client = _client()
	app.private_room = true
	NetDelay.set_latency(400, 60)
	var lab := Lab03.new()
	if await mount(lab, app):
		await drive(lab, app, 2000, 1)   # let the backlog build
		var samples: Array[float] = []
		var flip := { "dir": 1 }
		await drive(lab, app, 8000, 1, 0, func(elapsed: float):
			# direction flips keep corrections (and replays) coming
			var want: int = 1 if int(elapsed / 900.0) % 2 == 0 else -1
			if want != flip["dir"]:
				flip["dir"] = want
				Kb.auto_x = want
			samples.append(float(lab.lane.tick_us)))
		check(samples.size() > 100, "no tick-cost samples collected")
		samples.sort()
		var median_us: float = samples[(samples.size() - 1) / 2]
		var p99_us: float = samples[int((samples.size() - 1) * 0.99)]
		var worst_us: float = samples[-1]
		var pending: int = lab.lane.recon.pending_count
		_tick_report = "tick median %.2f ms, p99 %.2f ms, worst %.2f ms over %d frames (%d pending at end)" % [
			median_us / 1000.0, p99_us / 1000.0, worst_us / 1000.0, samples.size(), pending]
		print("OK callable overhead @400ms+60j: %s" % _tick_report)
		check(pending >= 6, "backlog never built (%d pending) — 400 ms was not injected" % pending)
		# The budget: a full reconcile burst must fit comfortably in a frame.
		check(median_us < 10000, "median tick %.2f ms — Callable dispatch dominates the frame" % (median_us / 1000.0))
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
