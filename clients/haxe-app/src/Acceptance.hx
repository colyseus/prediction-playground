import App.Kb;
import Gfx.GfxNull;
import io.colyseus.Client;
import playground.Lab00;
import playground.Lab01;
import playground.Lab02;
import playground.Lab03;
import playground.Lab04;
import playground.Lab05;
import playground.Lab06;
import playground.Lab07;
import playground.Lab08;
import playground.Lab09;
import playground.Lab10;
import playground.Lab11;

/**
 * The haxe-app's acceptance harness — the twin of the native app's `--demo`, the
 * Unity PlayMode suite and the Defold headless run.
 *
 * It runs the REAL lab modules: same mount, same frame(), same `Kb` accessors a
 * human drives, with `GfxNull` swapped in so nothing needs a window. That is the
 * point of labs drawing only through `Gfx` — the netcode under test is
 * byte-for-byte what the windowed build runs.
 *
 * Needs `pnpm dev --host 0.0.0.0` on :5173.
 *
 *   haxe acceptance.hxml && neko bin/acceptance.n [port]
 */
class Acceptance {
	static var failed = 0;
	static var gfx = new GfxNull();

	static function check(name: String, ok: Bool, ?detail: String) {
		Sys.println((ok ? "OK   " : "FAIL ") + name + (detail != null ? " — " + detail : ""));
		if (!ok) failed++;
	}

	static function nowMs(): Float return haxe.Timer.stamp() * 1000;

	/** Pump the injector + a lab for `ms`, exactly like the shell's update does. */
	/**
	 * `onFrame(elapsedMs)`, when given, runs after each frame — for checks that
	 * need the shape of a run rather than one end-of-run reading.
	 */
	static function drive(lab: Lab, app: App, ms: Float, autoX: Int = 0, autoY: Int = 0,
			?onFrame: Float -> Void) {
		Kb.autopilot = true;
		Kb.autoX = autoX;
		Kb.autoY = autoY;
		var start = nowMs(), last = start;
		while (nowMs() - start < ms) {
			NetDelay.pump(nowMs());
			var now = nowMs();
			lab.frame(app, now, now - last);
			lab.render(gfx);          // no-op visually, but it exercises the draw path
			last = now;
			if (onFrame != null) onFrame(now - start);
			Sys.sleep(0.008);
			Kb.pressed = new Map();
		}
	}

	/** Median of a numeric list (sorts in place). */
	static function median(values: Array<Float>): Float {
		if (values.length == 0) return -1;
		values.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
		return values[Math.ceil(values.length / 2) - 1];
	}

	/** Join and wait for the lab's own readiness predicate. Fails loudly. */
	static function mount(lab: Lab, app: App, timeoutMs: Float = 15000): Dynamic {
		var joined: Dynamic = null;
		var err: String = null;
		var handler = function(e: Dynamic, room: Dynamic) {
			if (e != null) { err = Std.string(e.message); return; }
			joined = room;
			// In front of the room's own listeners, but only now that it has
			// joined: the handshake rides an undelayed link, gameplay does not.
			NetDelay.wrap(room, nowMs);
		};
		lab.join(app, handler);

		var deadline = nowMs() + timeoutMs;
		while (nowMs() < deadline) {
			NetDelay.pump(nowMs());
			if (err != null) throw '${lab.id}: join failed — $err';
			// The lab owns the readiness question because only it knows the state
			// type — and reading `room.state` from here through Dynamic would read
			// a property's backing field that does not exist.
			if (joined != null && lab.ready(joined)) {
				if (!lab.mount(app, joined)) throw '${lab.id}: mount refused the room';
				return joined;
			}
			Sys.sleep(0.008);
		}
		throw '${lab.id}: never became ready (${NetDelay.inFlight()} pkt in the injector)';
	}

	static function leave(lab: Lab, room: Dynamic) {
		lab.unmount();
		// Explicit `true`: neko's dynamic dispatch matches on EXACT arity, so
		// omitting an optional argument is a call that does not exist.
		room.leave(true);
		var deadline = nowMs() + 2000;
		while (nowMs() < deadline) { NetDelay.pump(nowMs()); Sys.sleep(0.008); }
	}

	static function main() {
		var port = (Sys.args().length > 0) ? Sys.args()[0] : "5173";
		Sys.println("prediction playground — haxe-app acceptance\n");

		check("shared sim reproduces the reference numbers", Sim.selfcheck() == 0);

		var app = new App(new Client('ws://127.0.0.1:$port'), true);

		{ // lab 01: with no prediction, input->motion IS the round trip
			var lab = new Lab01();
			NetDelay.reset();
			var room = mount(lab, app);

			drive(lab, app, 800);
			drive(lab, app, 1600, 1);
			var atZero = lab.measured;
			check("lab01 meter arms at 0 injected latency", atZero > 0);
			check("lab01 input->motion is ~one patch interval at 0 injected",
				atZero > 0 && atZero < 250, '${Math.round(atZero)} ms');

			drive(lab, app, 900);
			NetDelay.setLatency(200, 0);
			drive(lab, app, 1200);
			drive(lab, app, 2000, -1);
			var at200 = lab.measured;
			check("lab01 input->motion tracks the round trip at 200 ms each way",
				at200 > 300, '${Math.round(at200)} ms (was ${Math.round(atZero)} ms)');

			leave(lab, room);
		}

		{ // lab 03: predicted instantly, and a mispredict decays back to steady state
			var lab = new Lab03();
			NetDelay.reset();
			NetDelay.setLatency(200, 0);
			var room = mount(lab, app);
			var recon = lab.lane.recon;

			drive(lab, app, 4000, -1);
			check("lab03 predicts with inputs still in flight", recon.pendingCount > 0,
				'${recon.pendingCount} unacked');
			check("lab03 client step agrees with the server's",
				recon.drift.classify(0.01) != "diverging",
				'drift ema ${recon.drift.ema}');

			room.send("impulse", null);   // exact arity again
			drive(lab, app, 1500);
			check("lab03 impulse produces a visible correction",
				lab.lane.maxCorrectionMag > 0.05, 'peak ${lab.lane.maxCorrectionMag}');

			drive(lab, app, 5000, 1);
			check("lab03 corrections converge again", recon.lastCorrectionMag < 0.05,
				'settled to ${recon.lastCorrectionMag}');

			leave(lab, room);
		}

		{ // lab 02: every clock readout responds to the injected link
			var lab = new Lab02();
			NetDelay.reset();
			NetDelay.setLatency(200, 0);
			var room = mount(lab, app);

			drive(lab, app, 4000, 1);
			var clock: Dynamic = lab.roomRef().clock;
			check("lab02 smoothed rtt sees the injected latency", clock.smoothedRtt() > 350,
				'${Math.round(clock.smoothedRtt())} ms');
			check("lab02 clock synced from the TIMED prefix", clock.lastServerTime() > 0);
			check("lab02 patch cadence advertised", clock.patchInterval() > 0,
				'${Math.round(clock.patchInterval())} ms');
			check("lab02 saw patch arrivals", lab.arrivals.length > 10,
				'${lab.arrivals.length} buffered');

			leave(lab, room);
		}

		{ // lab 00: the predicted lane leads the server echo by ~RTT
			var lab = new Lab00();
			NetDelay.reset();
			var room = mount(lab, app);        // mount picks its own latency preset

			drive(lab, app, 6000);             // its autopilot drives itself
			check("lab00 lanes separate under latency", lab.peakGap > 2.0,
				'peak ${Math.round(lab.peakGap * 100) / 100} u');
			check("lab00 autopilot ran without a hand on the keyboard", !lab.userDrove);

			leave(lab, room);
		}

		{ // lab 05: reckon renders the present, and honours the bot's real pattern
			var lab = new Lab05();
			NetDelay.reset();
			NetDelay.setLatency(200, 0);
			var room = mount(lab, app);

			lab.setPattern("patrol");
			drive(lab, app, 5000);
			check("lab05 reckon leads the lerp view", lab.peakGap > 1.0,
				'peak ${Math.round(lab.peakGap * 100) / 100} u');

			// The circle is the check that matters: it is the one pattern whose y
			// moves. If the reckon step cannot see `kind` it falls through to
			// patrol, which pins y to baseY — a flat y means the scratch lost it.
			lab.setPattern("circle");
			drive(lab, app, 2000);
			var minY = 1e9, maxY = -1e9;
			for (_ in 0...40) {
				drive(lab, app, 100);
				var ry = lab.reckon.value(lab.bot, "y");
				if (ry < minY) minY = ry;
				if (ry > maxY) maxY = ry;
			}
			check("lab05 reckon follows the circle pattern, not a patrol fallback",
				maxY - minY > 4, 'y swept ${Math.round((maxY - minY) * 100) / 100} u');

			leave(lab, room);
		}

		{ // lab 04: the interpolation modes differ as advertised
			var lab = new Lab04();
			NetDelay.reset();
			NetDelay.setLatency(120, 40);
			var room = mount(lab, app);

			// Pin the pattern rather than inherit whatever the room defaulted to —
			// a stationary bot scores NaN and the comparison below means nothing.
			lab.setPattern("patrol");
			drive(lab, app, 2000);          // let the pattern land
			lab.resetMeters();              // then score a clean window
			drive(lab, app, 6000);

			check("lab04 the bot actually moved", lab.botTravel > 10,
				'${Math.round(lab.botTravel)} u travelled');
			var cv = lab.smoothnessByMode();
			var scored = true;
			for (name in cv.keys()) if (Math.isNaN(cv.get(name))) scored = false;
			check("lab04 every mode scored", scored);
			// raw is the decoded snapshot verbatim, so it stutters at the patch
			// rate; lerp walks between two real samples and must be steadier.
			check("lab04 raw stutters more than lerp", cv.get("raw") > cv.get("lerp"),
				'raw ${Math.round(cv.get("raw") * 100) / 100} vs lerp ${Math.round(cv.get("lerp") * 100) / 100}');

			leave(lab, room);
		}

		{ // lab 08: the optimistic banner fires instantly, then settles
			var lab = new Lab08();
			NetDelay.reset();
			NetDelay.setLatency(200, 0);
			var room = mount(lab, app);

			// Deny nothing: every optimistic banner must be confirmed.
			lab.setDenyRate(0);
			drive(lab, app, 600);
			drive(lab, app, 6000, 1);
			var c = lab.counts();
			check("lab08 entered the goal zone and predicted", lab.records.length > 0,
				'${lab.records.length} predicted');
			check("lab08 optimistic goals get confirmed at a 0 % deny rate",
				c.confirmed > 0 && c.rejected == 0,
				'${c.confirmed} confirmed, ${c.rejected} rejected');
			var cleanRun = lab.records.length;

			// Deny everything: the banner still fires instantly, then retracts.
			lab.setDenyRate(100);
			drive(lab, app, 600);
			drive(lab, app, 9000, 1);
			var c2 = lab.counts();
			check("lab08 keeps predicting once the server starts denying",
				lab.records.length > cleanRun, '${lab.records.length} total');
			check("lab08 grace-tick auto-reject retracts the unconfirmed banners",
				c2.rejected > 0, '${c2.rejected} rejected');

			leave(lab, room);
		}

		{ // lab 09: an optimistic spawn hands off to the authoritative entity
			var lab = new Lab09();
			NetDelay.reset();
			NetDelay.setLatency(200, 0);
			var room = mount(lab, app);
			drive(lab, app, 800);

			lab.aimAt(50, 55);
			lab.fire();
			// Immediately after firing there must be a local to look at — that IS
			// the feature; a full RTT later would be far too late.
			drive(lab, app, 150);
			check("lab09 spawns a local the same frame it fires", lab.pending > 0,
				'${lab.pending} pending');

			// ...and by ~2 RTT the server's entity has arrived and correlated.
			drive(lab, app, 1600);
			check("lab09 the server's projectile correlates", lab.confirmed > 0,
				'${lab.confirmed} confirmed');
			check("lab09 measures the input lead (else the handoff would jump)",
				!Math.isNaN(lab.lastLeadMs) && lab.lastLeadMs > 0,
				Math.isNaN(lab.lastLeadMs) ? "never measured" : '${Math.round(lab.lastLeadMs)} ms');

			// ...and MEASURING the lead is only half of it: the confirmed entity
			// has to be reckoned by it too. Un-reckoned it renders at the last
			// decoded snapshot, (snapshot age + lead) x 34 u/s behind the
			// prediction — ~8 u at this latency, which is what a player sees as
			// the shot snapping backwards.
			for (_ in 0...5) { lab.aimAt(50, 55); lab.fire(); drive(lab, app, 700); }
			check("lab09 the handoff doesn't snap the projectile back",
				lab.maxHandoffJump < 3.0,
				'worst jump ${Math.round(lab.maxHandoffJump * 100) / 100} u');

			leave(lab, room);
		}

		{ // lab 06: lag comp lands the shot where the shooter aimed
			var lab = new Lab06();
			NetDelay.reset();
			var room = mount(lab, app);      // mount picks its own latency preset
			drive(lab, app, 1500);

			lab.setLagComp(true);
			drive(lab, app, 800);
			for (_ in 0...6) { lab.fire(); drive(lab, app, 700); }
			check("lab06 the server reported the shots", lab.shotsOn > 0,
				'${lab.shotsOn} with comp on');
			check("lab06 lag comp hits what the shooter saw",
				lab.hitsOn * 10 > lab.shotsOn * 6, '${lab.hitsOn}/${lab.shotsOn} hits');
			// The assertion that catches an unbound renderDelay: the rewound read
			// has to coincide with our view, while the view lags well behind live.
			check("lab06 the rewound read coincides with our view",
				lab.rewindError() >= 0 && lab.rewindError() < 3.0,
				'rewind error ${Math.round(lab.rewindError() * 100) / 100} u, '
					+ 'view lag ${Math.round(lab.viewLag() * 10) / 10} u');

			leave(lab, room);
		}

		{ // lab 07: a frozen verdict agrees with the server's
			var lab = new Lab07();
			NetDelay.reset();
			var room = mount(lab, app);      // mount picks its own latency preset

			// The autopilot seeks the bot's lane and lets the patrol sweep hit it.
			drive(lab, app, 14000, 1);
			check("lab07 bumped the bot at all", lab.bumpsPredicted > 0,
				'${lab.bumpsPredicted} predicted');
			// The server's own counter is the only verdict that settles it: with
			// valueAt + memo the client's count must TRACK it, not merely be close.
			check("lab07 the client's verdict matches the server's",
				Math.abs(lab.bumpsPredicted - lab.bumpsAuthoritative()) <= 1,
				'predicted ${lab.bumpsPredicted}, authoritative ${lab.bumpsAuthoritative()}, '
					+ 'mispredict rate ${Math.round(lab.mispredictRate())} %');

			leave(lab, room);
		}

		{ // lab 11: client and server roll identical pellets from (seq, salt)
			var lab = new Lab11();
			NetDelay.reset();
			NetDelay.setLatency(200, 0);
			var room = mount(lab, app);
			// Warm up past the input channel's first consumption before firing: a
			// shot whose seq the server has not consumed yet derives from a
			// different (seq, salt) and the fans have nothing to do with each other.
			drive(lab, app, 2500);
			lab.resetDivergence();

			for (_ in 0...10) { lab.fire(); drive(lab, app, 700); }
			check("lab11 the server reported a fan", lab.answeredFans() > 0,
				'${lab.answeredFans()} answered');
			check("lab11 seeded from (seq, salt), both sides derive the same fan",
				!Math.isNaN(lab.worstDivergence) && lab.worstDivergence < 1e-6,
				'worst divergence ${lab.worstDivergence} rad over ${lab.answeredFans()} fans'
					+ (lab.disagreement == "" ? "" : ' — disagreement is ${lab.disagreement}-shaped'));

			// Swap in an unshared RNG and the SAME comparison must fail — otherwise
			// the check above proves nothing.
			lab.cheat = true;
			lab.resetDivergence();
			for (_ in 0...3) { lab.fire(); drive(lab, app, 700); }
			check("lab11 an unshared RNG visibly disagrees",
				!Math.isNaN(lab.maxDivergence) && lab.maxDivergence > 1e-6,
				'divergence ${lab.maxDivergence} rad');

			leave(lab, room);
		}

		{ // lab 10: the puck is predicted THROUGH our own inputs
			var lab = new Lab10();
			NetDelay.reset();
			var room = mount(lab, app);      // mount picks its own latency preset
			lab.setBot(false);               // isolate OUR step from a contested touch

			// The lab steers itself toward the puck under autopilot; a plain sweep
			// never reaches it, and a puck nobody touches proves nothing.
			//
			// Sample every reconcile as it happens, and how far the puck travels
			// late in the run. Reading drift.ema once at the end measures the wrong
			// thing twice over: it decays toward zero when the world stops moving,
			// so a puck pinned against a wall scores BETTER than honest play.
			var mags: Array<Float> = [];
			var seq = lab.sim.reconcileSeq;
			var latePath = 0.0;
			var px = Math.NaN, py = Math.NaN;
			drive(lab, app, 12000, 0, 0, function(elapsed) {
				if (lab.sim.reconcileSeq != seq) {
					seq = lab.sim.reconcileSeq;
					mags.push(lab.sim.lastCorrectionMag);
				}
				if (elapsed > 9000) {
					var puck = lab.serverPuck();
					if (!Math.isNaN(px)) {
						latePath += Math.sqrt((puck.x - px) * (puck.x - px)
							+ (puck.y - py) * (puck.y - py));
					}
					px = puck.x;
					py = puck.y;
				}
			});

			check("lab10 predicts with inputs still in flight", lab.sim.pendingCount > 0,
				'${lab.sim.pendingCount} unacked');
			check("lab10 the predicted puck leads the authoritative one",
				lab.maxPuckLead > 0.5,
				'peak ${Math.round(lab.maxPuckLead * 100) / 100} u over ${lab.touches} touches');

			// The MEDIAN reconcile, not the worst or the last. Remote HUMAN
			// paddles enter the prediction at their last snapshot, so a contested
			// human touch mispredicts by design — lab 10 exists to show that.
			// 0.5 is a gross-divergence ceiling: a client stepping the puck with
			// the wrong friction (0.900 vs 0.985) lands at 1.7751. Honest play
			// measured 0.0000-0.1527 before the server paced input consumption
			// to one per tick (2026-07-31); with pacing it sits at ~0.0000, so
			// the margin is now much wider. Bit-exactness stays the startup
			// canary's job.
			var mid = median(mags);
			check("lab10 the composite step agrees with the server's",
				mid >= 0 && mid < 0.5,
				'median correction ${Math.round(mid * 10000) / 10000} over ${mags.length} reconciles');

			// Guards the check above: a frozen world agrees with itself perfectly.
			check("lab10 the puck is still live at the end",
				latePath > 5,
				'${Math.round(latePath * 10) / 10} u travelled in the last 3s');

			leave(lab, room);
		}

		Sys.println("");
		Sys.println(failed == 0 ? "all checks passed" : '$failed check(s) FAILED');
		Sys.exit(failed == 0 ? 0 : 1);
	}
}
