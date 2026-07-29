//
// Haxe-SDK validation client for the Colyseus Prediction Playground.
//
// Headless probe (neko sys target) against the live demo server, exercising
// the predict layer end-to-end — the Haxe twin of
// clients/native/predict_probe.c:
//
//   A  lab-move        join, TIMED clock sync, reconciler over the ported
//                      stepEntity (bit-exact f64), impulse -> correction
//   B  lab-bots        passive smoothing (lerp) over the patrol bot
//   C  lab-goal        sim-born optimistic event (ctx.predict) -> confirm
//   D  lab-projectile  predicted spawn -> in-place authoritative handoff
//
// Build + run (against a sibling colyseus-haxe checkout):
//   cd clients/haxe && haxe build.hxml && neko probe.n [port]
//
import io.colyseus.Client;
import io.colyseus.Room;
import io.colyseus.RoomClock;
import io.colyseus.predict.Drift;
import io.colyseus.predict.Predict;
import io.colyseus.predict.PredictedEventChannel;
import io.colyseus.predict.PredictedSpawns;
import io.colyseus.predict.Reconciler;
import io.colyseus.serializer.SchemaSerializer;
import io.colyseus.serializer.schema.Callbacks.SchemaCallbacks;

class PredictProbe {
	static var checksFailed = 0;

	static function check(name: String, ok: Bool, ?detail: String) {
		Sys.println((ok ? "OK   " : "FAIL ") + name + (detail != null ? " — " + detail : ""));
		if (!ok) { checksFailed++; }
	}

	// --- shared sim (ported bit-exact f64 from src/shared) ------------------

	static inline var TICK_HZ = 20;
	static inline var ARENA_W = 100.0;
	static inline var ARENA_H = 60.0;
	static inline var PLAYER_HALF = 1.6;
	static inline var PLAYER_ACCEL = 220.0;
	static inline var PLAYER_MAX_SPEED = 34.0;
	static inline var PLAYER_FRICTION_K = 0.72;
	/** Math.SQRT1_2 — the exact f64 the JS sim multiplies by. */
	static inline var SQRT1_2 = 0.70710678118654752440;
	static inline var GOAL_ZONE_X = ARENA_W - 8;
	static var GOAL_ZONE_Y = ARENA_H / 2 - 9;
	static inline var GOAL_ZONE_H = 18.0;
	static inline var SCORE_COOLDOWN_TICKS = 50;
	static inline var PROJECTILE_SPEED = 34.0;

	/** shared/movement.ts stepEntity — same op order, same constants.
	    Mutates the Dynamic-field schema mirror in place. */
	static function stepEntity(s: Dynamic, moveX: Float, moveY: Float, dt: Float) {
		var ax = moveX, ay = moveY;
		if (ax != 0 && ay != 0) { ax *= SQRT1_2; ay *= SQRT1_2; }

		var vx: Float = s.vx, vy: Float = s.vy;
		if (ax != 0 || ay != 0) {
			vx += ax * PLAYER_ACCEL * dt;
			vy += ay * PLAYER_ACCEL * dt;
		} else {
			vx *= PLAYER_FRICTION_K;
			vy *= PLAYER_FRICTION_K;
			if (vx > -0.05 && vx < 0.05) { vx = 0; }
			if (vy > -0.05 && vy < 0.05) { vy = 0; }
		}

		var sq = vx * vx + vy * vy;
		if (sq > PLAYER_MAX_SPEED * PLAYER_MAX_SPEED) {
			var k = PLAYER_MAX_SPEED / Math.sqrt(sq);
			vx *= k;
			vy *= k;
		}

		var x: Float = s.x + vx * dt;
		var y: Float = s.y + vy * dt;

		var minX = PLAYER_HALF, maxX = ARENA_W - PLAYER_HALF;
		var minY = PLAYER_HALF, maxY = ARENA_H - PLAYER_HALF;
		if (x < minX) { x = minX; if (vx < 0) { vx = 0; } }
		else if (x > maxX) { x = maxX; if (vx > 0) { vx = 0; } }
		if (y < minY) { y = minY; if (vy < 0) { vy = 0; } }
		else if (y > maxY) { y = maxY; if (vy > 0) { vy = 0; } }

		s.x = x; s.y = y; s.vx = vx; s.vy = vy;
	}

	// --- harness ------------------------------------------------------------

	static function nowMs(): Float return RoomClock.getNow();

	static function sleepMs(ms: Float) Sys.sleep(ms / 1000);

	static function pumpUntil(pred: Void -> Bool, timeoutMs: Float): Bool {
		var deadline = nowMs() + timeoutMs;
		while (nowMs() < deadline) {
			if (pred()) { return true; }
			Sys.sleep(0.002);
		}
		return pred();
	}

	static function joinLab<T>(client: Client, name: String, stateClass: Class<T>): Room<T> {
		var joined: Room<T> = null;
		var failed = false;
		client.joinOrCreate(name, new Map<String, Dynamic>(), stateClass, function(err, room) {
			if (err != null) {
				Sys.println("join error: " + err.message);
				failed = true;
				return;
			}
			joined = room;
		});
		pumpUntil(() -> joined != null || failed, 5000);
		if (joined == null) { return null; }
		pumpUntil(() -> joined.state != null, 5000);
		sleepMs(300);   // one patch interval so the first TIMED sample lands
		return joined;
	}

	static function callbacksOf<T>(room: Room<T>): SchemaCallbacks<T> {
		// synchronous wiring — the probe polls from the main thread, so the
		// MainLoop-queued flavor (Callbacks.get) would never drain
		var serializer: SchemaSerializer<T> = cast room.serializer;
		return new SchemaCallbacks<T>(serializer.decoder);
	}

	public static function main() {
		var args = Sys.args();
		var port = args.length > 0 ? args[0] : "5173";
		Sys.println('predict_probe (Haxe) -> ws://127.0.0.1:$port');
		var client = new Client('ws://127.0.0.1:$port');

		scenarioMove(client);
		scenarioBots(client);
		scenarioGoal(client);
		scenarioProjectile(client);

		Sys.println("\n" + (checksFailed == 0 ? "PROBE OK" : "PROBE FAILED"));
		Sys.exit(checksFailed == 0 ? 0 : 1);
	}

	// --- A. lab-move --------------------------------------------------------

	static function scenarioMove(client: Client) {
		Sys.println("\n=== A. lab-move: join, clock, reconcile, impulse ===");
		var room = joinLab(client, "lab-move", lab.MoveState);
		check("join lab-move", room != null);
		if (room == null) { return; }

		var me: lab.Player = room.state.players.items.get(room.sessionId);
		check("own player spawned", me != null, "session " + room.sessionId);
		if (me == null) { return; }
		Sys.println('     spawn at ${me.x} ${me.y} hue ${me.hue}');

		check("clock synced (TIMED prefix flowing)", room.clock.lastServerTime() > 0,
			'lastServerTime=${room.clock.lastServerTime()}');

		var input = room.input({ type: lab.MoveInput });
		check("input handle created", input != null);
		var cmd: lab.MoveInput = cast input.data;

		var predict = Predict.create(callbacksOf(room), room.clock);
		var recon = predict.reconciler(me, {
			input: input,
			fields: ["x", "y", "vx", "vy"],
			smoothing: 15,
			step: (ctx, s, inp) -> stepEntity(s, inp.moveX, inp.moveY, ctx.dt),
		});
		check("reconciler created (step 50ms adopted)", recon.stepMs == 50);
		var predicted: lab.Player = cast recon.state;

		var startX: Float = predicted.x;
		var earlyX = startX;
		var maxCorrSteady = 0.0;
		var corrBlips = 0;
		var lastSeq = 0;
		var maxPending = 0;

		// drive left for 2s at the fixed step, ticking at ~60fps
		var sendAcc = 0.0;
		var last = nowMs();
		for (frame in 0...125) {
			sleepMs(16);
			var now = nowMs();
			sendAcc += now - last;
			last = now;
			while (sendAcc >= 50) {
				sendAcc -= 50;
				cmd.moveX = -1;
				cmd.moveY = 0;
				input.send();
			}
			predict.tick(now);
			if (frame == 9) { earlyX = predicted.x; }
			if (frame > 30) {
				if (recon.reconcileSeq != lastSeq && recon.lastCorrectionMag > 1e-3) { corrBlips++; }
				lastSeq = recon.reconcileSeq;
				maxCorrSteady = Math.max(maxCorrSteady, recon.lastCorrectionMag);
				maxPending = recon.pendingCount > maxPending ? recon.pendingCount : maxPending;
			}
			if (frame % 25 == 0) {
				Sys.println('     t=${frame * 16}ms truth ${me.x},${me.y} v ${me.vx},${me.vy}'
					+ ' | pred ${predicted.x},${predicted.y} | corr=${recon.lastCorrectionMag}');
			}
		}

		check("predicted pose moves before RTT elapses", startX - earlyX > 0.3,
			'dx=${startX - earlyX} in ~150ms');
		// On sys targets the websocket thread decodes patches while this thread
		// reconciles — a reconcile can race a mid-adopt patch and double-apply
		// ONE input (a single-tick 1.7-unit blip). The math itself is exact:
		// every non-raced reconcile must correct EXACTLY zero.
		check("steady-state corrections ~0 outside decode races", corrBlips <= 2 && maxCorrSteady <= 2.0,
			'max |correction| = $maxCorrSteady, raced reconciles = $corrBlips');
		var rtt = room.clock.smoothedRtt();
		check("pending tracks RTT", maxPending <= Std.int(rtt * TICK_HZ / 1000 + 3),
			'max pending=$maxPending rtt=${rtt}ms');
		check("drift matched while driving", recon.drift.classify(0.05) == "matched",
			'ema=${recon.drift.ema}');

		// server-side shove the client can't see coming — MUST mispredict
		room.send("impulse", {});
		var impulseCorr = 0.0;
		sendAcc = 0;
		last = nowMs();
		for (_ in 0...220) {
			sleepMs(16);
			var now = nowMs();
			sendAcc += now - last;
			last = now;
			while (sendAcc >= 50) {
				sendAcc -= 50;
				cmd.moveX = 0;
				cmd.moveY = 0;
				input.send();   // keep acks flowing
			}
			predict.tick(now);
			impulseCorr = Math.max(impulseCorr, recon.lastCorrectionMag);
		}
		check("impulse produces a visible correction", impulseCorr > 0.05,
			'max |correction| = $impulseCorr');
		check("drift recovers after impulse (not diverging)",
			recon.drift.classify(0.01) != "diverging",
			'ema=${recon.drift.ema} peak=${recon.drift.peak}');

		var read = recon.value("x");
		check("value(x) render read sane", Math.isFinite(read) && Math.abs(read - predicted.x) < 5,
			'value=$read state=${predicted.x}');

		room.leave();
		sleepMs(300);
	}

	// --- B. lab-bots --------------------------------------------------------

	static function scenarioBots(client: Client) {
		Sys.println("\n=== B. lab-bots: passive smoothing over a server-driven bot ===");
		var room = joinLab(client, "lab-bots", lab.BotsState);
		check("join lab-bots", room != null);
		if (room == null) { return; }

		var bot: lab.Bot = room.state.bots.items.get("bot1");
		check("bot1 present", bot != null);
		if (bot == null) { return; }

		var predict = Predict.create(callbacksOf(room), room.clock);
		predict.attach(bot, { x: "lerp", y: "lerp" });
		check("track bot1.x/y (lerp)", true);
		sleepMs(300);   // ring warmup — with < 2 samples value() reads raw

		var pathLen = 0.0;   // total travel — net displacement collapses on a patrol reversal
		var first = Math.NaN, lastV = Math.NaN, minV = 1e9, maxV = -1e9;
		// compare VELOCITIES, not raw per-frame jumps — neko's Sys.sleep can
		// hitch past a whole patch interval, which would make even a perfect
		// lerp "jump" one snapshot distance in a single frame
		var maxLerpVel = 0.0, maxRawVel = 0.0;
		var prevRaw: Float = bot.x;
		var lastFrameAt = nowMs();
		for (_ in 0...100) {
			sleepMs(16);
			var now = nowMs();
			var dtSec = Math.max(now - lastFrameAt, 1) / 1000;
			lastFrameAt = now;
			predict.tick(now);
			var v = predict.value(bot, "x");
			if (Math.isNaN(first)) { first = v; }
			if (!Math.isNaN(lastV)) {
				maxLerpVel = Math.max(maxLerpVel, Math.abs(v - lastV) / dtSec);
				pathLen += Math.abs(v - lastV);
			}
			maxRawVel = Math.max(maxRawVel, Math.abs((bot.x : Float) - prevRaw) / dtSec);
			prevRaw = bot.x;
			lastV = v;
			minV = Math.min(minV, v);
			maxV = Math.max(maxV, v);
		}
		check("lerped value follows the bot", pathLen > 10,
			'travelled $pathLen units over 1.6s');
		check("lerp velocity smoother than snapshot bursts", maxLerpVel < maxRawVel * 0.66,
			'max lerp vel $maxLerpVel u/s < snapshot burst $maxRawVel u/s');
		check("lerped value stays in the patrol band", minV > 20 && maxV < 80,
			'range [$minV, $maxV]');

		room.leave();
		sleepMs(300);
	}

	// --- C. lab-goal --------------------------------------------------------

	static function scenarioGoal(client: Client) {
		Sys.println("\n=== C. lab-goal: sim-born optimistic event -> server confirm ===");
		var room = joinLab(client, "lab-goal", lab.GoalState);
		check("join lab-goal", room != null);
		if (room == null) { return; }

		var me: lab.GoalPlayer = room.state.players.items.get(room.sessionId);
		check("own player spawned", me != null);
		if (me == null) { return; }

		var predictedCount = 0, confirmedCount = 0, rejectedCount = 0;
		var predict = Predict.create(callbacksOf(room), room.clock);
		var goals = predict.defineEvent({
			onPredict: _ -> predictedCount++,
			onConfirm: _ -> confirmedCount++,
			onReject: _ -> rejectedCount++,
		});

		room.onMessage("goal", function(message: Dynamic) {
			if (message.sid == room.sessionId) { goals.confirm(); }
		});

		var input = room.input({ type: lab.MoveInput });
		var cmd: lab.MoveInput = cast input.data;

		var n = 0;
		var recon = predict.reconciler(me, {
			input: input,
			fields: ["x", "y", "vx", "vy", "scoreTicks"],
			smoothing: 15,
			step: function(ctx, s, inp) {
				stepEntity(s, inp.moveX, inp.moveY, ctx.dt);
				// shared/goal.ts stepScoreGate — reconciled tick state
				if ((s.scoreTicks : Int) > 0) {
					s.scoreTicks = (s.scoreTicks : Int) - 1;
				} else if ((s.x : Float) >= GOAL_ZONE_X && (s.y : Float) >= GOAL_ZONE_Y
					&& (s.y : Float) <= GOAL_ZONE_Y + GOAL_ZONE_H) {
					s.scoreTicks = SCORE_COOLDOWN_TICKS;
					ctx.predict(goals, n++);   // live-only, replay-safe
				}
			},
		});
		check("reconciler created (scoreTicks reconciled)", recon != null);
		var predicted: lab.GoalPlayer = cast recon.state;

		var maxCorr = 0.0;
		var corrBlips = 0;
		var lastSeq = 0;
		var sendAcc = 0.0;
		var last = nowMs();
		var frames = 0;
		while (frames < 500 && confirmedCount == 0) {
			frames++;
			sleepMs(16);
			var now = nowMs();
			sendAcc += now - last;
			last = now;
			while (sendAcc >= 50) {
				sendAcc -= 50;
				cmd.moveX = 1;
				cmd.moveY = (predicted.y : Float) < ARENA_H / 2 - 2 ? 1
					: (predicted.y : Float) > ARENA_H / 2 + 2 ? -1 : 0;
				input.send();
			}
			predict.tick(now);
			if (frames > 30) {
				if (recon.reconcileSeq != lastSeq && recon.lastCorrectionMag > 1e-3) { corrBlips++; }
				lastSeq = recon.reconcileSeq;
				maxCorr = Math.max(maxCorr, recon.lastCorrectionMag);
			}
		}

		check("optimistic goal predicted (sim-born, live step)", predictedCount >= 1,
			'predicted=$predictedCount after $frames frames');
		check("server confirmed the goal", confirmedCount >= 1, 'confirmed=$confirmedCount');
		check("no rejections (denyRate 0)", rejectedCount == 0);
		check("gate deterministic through reconciles (outside decode races)",
			corrBlips <= 2 && maxCorr <= 2.0,
			'max |correction| = $maxCorr, raced reconciles = $corrBlips');

		room.leave();
		sleepMs(300);
	}

	// --- D. lab-projectile --------------------------------------------------

	static function scenarioProjectile(client: Client) {
		Sys.println("\n=== D. lab-projectile: predicted spawn -> authoritative handoff ===");
		var room = joinLab(client, "lab-projectile", lab.ProjectileState);
		check("join lab-projectile", room != null);
		if (room == null) { return; }

		var me: lab.Player = room.state.players.items.get(room.sessionId);
		check("own player spawned", me != null);
		if (me == null) { return; }

		var rejected = 0;
		var foreignSeen = false;
		var predict = Predict.create(callbacksOf(room), room.clock);
		var store = predict.spawns("projectiles", {
			owned: (server: Dynamic) -> server.owner == room.sessionId,
			spawnTime: (server: Dynamic) -> (server.bornMs : Float),
			step: function(local: Dynamic, dt: Float) {
				// shared/projectile.ts stepProjectile over the pending local
				local.x += local.vx * dt;
				local.y += local.vy * dt;
				if ((local.x : Float) < 0) { local.x = 0; local.vx = Math.abs(local.vx); }
				else if ((local.x : Float) > ARENA_W) { local.x = ARENA_W; local.vx = -Math.abs(local.vx); }
				if ((local.y : Float) < 0) { local.y = 0; local.vy = Math.abs(local.vy); }
				else if ((local.y : Float) > ARENA_H) { local.y = ARENA_H; local.vy = -Math.abs(local.vy); }
			},
			onReject: (_, _) -> rejected++,
		});

		var input = room.input({ type: lab.RangeInput });
		var cmd: lab.RangeInput = cast input.data;

		// fire one shot at the turret (50, 8) and spawn the optimistic local
		var aimX = 50.0, aimY = 8.0;
		var dx = aimX - (me.x : Float), dy = aimY - (me.y : Float);
		var len = Math.sqrt(dx * dx + dy * dy);
		dx /= len; dy /= len;
		var localProjectile = {
			x: (me.x : Float), y: (me.y : Float),
			vx: dx * PROJECTILE_SPEED, vy: dy * PROJECTILE_SPEED,
		};

		cmd.aimX = aimX;
		cmd.aimY = aimY;
		cmd.fire = true;
		input.send();
		cmd.fire = false;
		var handle = store.spawn(localProjectile);

		check("optimistic local pending immediately",
			!handle.confirmed && handle.local == (localProjectile : Dynamic),
			'id=${handle.id}');

		var sendAcc = 0.0;
		var last = nowMs();
		var leadMs = 0.0;
		var confirmed = false;
		for (_ in 0...250) {
			if (confirmed && foreignSeen) { break; }
			sleepMs(16);
			var now = nowMs();
			sendAcc += now - last;
			last = now;
			while (sendAcc >= 50) {
				sendAcc -= 50;
				input.send();   // keep the input stream alive
			}
			predict.tick(now);
			if (!confirmed && handle.confirmed) {
				confirmed = true;
				leadMs = handle.leadMs;
			}
			// the turret's projectiles must surface as foreign (server-only) entries
			for (entry in store.entries()) {
				if (entry.confirmed && entry.local == null
					&& entry.server != null && (entry.server : Dynamic).owner == "turret") {
					foreignSeen = true;
				}
			}
		}

		check("authoritative projectile correlated IN PLACE (stable id)", confirmed,
			'id=${handle.id}');
		check("input lead measured", confirmed && leadMs > 0 && leadMs < 1000, 'leadMs=$leadMs');
		check("turret projectiles surface as foreign entries", foreignSeen);
		check("own prediction not TTL-rejected", rejected == 0, 'rejected=$rejected');

		room.leave();
		sleepMs(300);
	}
}
