import App.Kb;
import Gfx.GfxNull;
import io.colyseus.Client;
import labs.Lab00;
import labs.Lab01;
import labs.Lab02;
import labs.Lab03;
import labs.Lab05;

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
	static function drive(lab: Lab, app: App, ms: Float, autoX: Int = 0, autoY: Int = 0) {
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
			Sys.sleep(0.008);
			Kb.pressed = new Map();
		}
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

		Sys.println("");
		Sys.println(failed == 0 ? "all checks passed" : '$failed check(s) FAILED');
		Sys.exit(failed == 0 ? 0 : 1);
	}
}
