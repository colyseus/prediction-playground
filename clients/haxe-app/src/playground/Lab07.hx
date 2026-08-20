package playground;

import App.Kb;
import Gfx.Palette;
import io.colyseus.Room;
import io.colyseus.predict.Predict;
import lab.BumpState;

/**
 * Lab 07 — WYSIWYG Collision.
 *
 * The collision against the moving bot is predicted INSIDE the reconciler step.
 * Two ingredients make the client's verdict equal the server's:
 *
 *  1. predict.valueAt(bot, "x", ctx.reckonTime) — read the bot at the instant
 *     the server will REWIND this input to. Reading anything else (the stale
 *     snapshot, or the smoothed render pose) tests against a position the server
 *     never uses.
 *
 *  2. ctx.memo(...) — the verdict is NOT re-derivable on rollback replay (the
 *     client keeps no bot history; a later replay would read the bot reckoned
 *     from a NEWER snapshot and could flip the call). memo runs the test once on
 *     the live step and replays the outcome verbatim.
 *
 * The verdict is a VECTOR (the knockback vx/vy) memoized as one value, so both
 * components replay together. Encoding it as an angle would round through
 * atan2/cos and reintroduce the drift this lab exists to eliminate.
 *
 * Port of src/client/labs/07-wysiwyg/.
 */
class Lab07 implements Lab {
	public var id(default, null) = "07-wysiwyg";
	public var num(default, null) = 7;
	public var title(default, null) = "WYSIWYG Collision";
	public var blurb(default, null) = "valueAt(reckonTime) + ctx.memo.";
	public var ownArena(default, null) = false;
	public var roomName(default, null) = "lab-bump";

	public var bumpsPredicted(default, null) = 0;
	public var mispredicts(default, null) = 0;
	public var useValueAt = true;
	public var useMemo = true;

	var room: Room<BumpState>;
	var sid: String;
	var me: lab.BumpPlayer;
	var bot: lab.Bot;
	var predict: Predict;
	var recon: Dynamic;
	var input: Dynamic;
	var cmd: Dynamic;
	var lastBumpAt = -1e9;
	var bumpFlashT = -1e9;
	var lastReconcileSeq = 0;

	public function new() {}

	public function join(app: App, cb: (Dynamic, Dynamic) -> Void): Void {
		if (app.private_) app.client.create(roomName, [], BumpState, cb);
		else app.client.joinOrCreate(roomName, [], BumpState, cb);
	}

	public function ready(raw: Dynamic): Bool {
		var r: Room<BumpState> = cast raw;
		var state = r.state;
		return state != null && state.players != null && state.bots != null
			&& state.players.items.get(r.sessionId) != null
			&& state.bots.items.get("bot1") != null;
	}

	/** The server's own count — the only verdict that settles it. */
	public function bumpsAuthoritative(): Int return me.bumps;

	public function mispredictRate(): Float {
		return bumpsPredicted == 0 ? 0 : mispredicts / bumpsPredicted * 100;
	}

	public function mount(app: App, raw: Dynamic): Bool {
		room = cast raw;
		sid = room.sessionId;
		me = room.state.players.items.get(sid);
		bot = room.state.bots.items.get("bot1");
		if (me == null || bot == null) return false;

		predict = Predict.get(room);
		// Bots are DEAD-RECKONED through the shared step — the timeline the
		// collision test below reads at ctx.reckonTime.
		predict.attachAll("bots", {
			mode: "reckon",
			fields: ["x", "y"],
			smoothMs: 40,
			step: (b, dt, elapsedMs) -> {
				var s: Sim.BotState = {
					x: b.x, y: b.y, vx: b.vx, vy: b.vy, kind: b.kind,
					minX: b.minX, maxX: b.maxX, baseY: b.baseY,
					phaseMs: b.phaseMs, speed: b.speed, lastTeleport: b.lastTeleport,
				};
				Sim.stepBot(s, dt, elapsedMs);
				b.x = s.x; b.y = s.y; b.vx = s.vx; b.vy = s.vy;
				b.lastTeleport = s.lastTeleport;
			},
		});
		predict.attachAll("players", { x: "damped", y: "damped" });

		input = room.input({ type: lab.MoveInput });
		cmd = input.data;
		build();
		app.setLatencyPreset(2);     // a knife-edge verdict needs a real RTT
		return true;
	}

	/** Writes the knockback, or null for "no bump this step". */
	function testBots(px: Float, py: Float, gate: Int, when: Float): Null<Sim.Knock> {
		var hit: Null<Sim.Knock> = null;
		var bots = room.state.bots;
		for (key in bots.items.keys()) {
			if (hit != null) break;
			var b = bots.items.get(key);
			// The server rewinds THIS input to reckonTime — test there. With the
			// toggle off we read the raw snapshot instead: ~RTT/2 behind where the
			// server tests, which is the whole point of the lab.
			var bx = useValueAt ? predict.valueAt(b, "x", when) : b.x;
			var by = useValueAt ? predict.valueAt(b, "y", when) : b.y;
			hit = Sim.collideBot(px, py, gate, bx, by);
		}
		return hit;
	}

	function build(): Void {
		recon = predict.reconciler(me, {
			input: input,
			fields: ["x", "y", "vx", "vy", "bumpTicks"],
			smoothMs: 65,
			step: (ctx, p, inp) -> {
				p.bumpTicks = Sim.stepBumpGate(p.bumpTicks);   // reconciled tick gate
				var e: Sim.Entity = { x: p.x, y: p.y, vx: p.vx, vy: p.vy };
				Sim.stepEntity(e, inp.moveX, inp.moveY, ctx.dt);
				p.x = e.x; p.y = e.y; p.vx = e.vx; p.vy = e.vy;

				var px: Float = p.x, py: Float = p.y;
				var gate: Int = p.bumpTicks;
				var when: Float = ctx.reckonTime;
				var knock: Null<Sim.Knock> = useMemo
					? ctx.memo("bump", () -> testBots(px, py, gate, when))
					: testBots(px, py, gate, when);

				if (knock == null) return;
				p.vx = knock.vx;
				p.vy = knock.vy;
				p.bumpTicks = Sim.BUMP_COOLDOWN_TICKS;    // immunity rides adopt+replay
				if (ctx.isReplay) return;                 // FX/counters: live step only
				bumpsPredicted++;
				lastBumpAt = App.nowMs();
				bumpFlashT = lastBumpAt;
			},
		});
		lastReconcileSeq = 0;
	}

	public function frame(app: App, now: Float, dtMs: Float): Void {
		// Both toggles rebuild nothing — the step reads them live.
		if (Kb.key("v")) useValueAt = !useValueAt;
		if (Kb.key("m")) useMemo = !useMemo;

		// The acceptance script can't hand-steer into a moving bot; when it drives,
		// seek the bot's lane and let the patrol sweep do the rest.
		var moveX = Kb.moveX(), moveY = Kb.moveY();
		if (Kb.autopilot) {
			var st: Dynamic = recon.state;
			var dy = predict.value(bot, "y") - (st.y : Float);
			moveX = 0;
			moveY = dy > 1.0 ? 1 : dy < -1.0 ? -1 : 0;
		}

		var steps = predict.tick(now);
		for (_ in 0...steps) {
			cmd.moveX = moveX;
			cmd.moveY = moveY;
			input.send();
		}

		// Attribute LARGE corrections near a predicted bump to a flipped verdict.
		// Small post-bump corrections (< ~3u) are knockback-direction epsilon; a
		// genuinely flipped verdict diverges by many units — the 48 u/s shove
		// either happened or it didn't.
		if (recon.reconcileSeq != lastReconcileSeq) {
			lastReconcileSeq = recon.reconcileSeq;
			if (recon.lastCorrectionMag > 3 && App.nowMs() - lastBumpAt < 700) mispredicts++;
		}
	}

	public function render(g: Gfx): Void {
		var state = room.state;
		for (key in state.players.items.keys()) {
			if (key == sid) continue;
			var p = state.players.items.get(key);
			g.square(predict.value(p, "x"), predict.value(p, "y"),
				Sim.PLAYER_HALF, Palette.hue(p.hue, 0.4));
		}

		var bx = predict.value(bot, "x"), by = predict.value(bot, "y");
		g.circle(bx, by, Sim.BOT_RADIUS, Palette.a(Palette.WARN, 0.3));
		g.circleOutline(bx, by, Sim.BOT_RADIUS, Palette.WARN);
		g.label(bx, by, "bot (reckon = hit position)", Palette.WARN, 10, -14);
		g.circleOutline(bot.x, bot.y, Sim.BOT_RADIUS, Palette.a(Palette.TEXT, 0.45), true);
		g.label(bot.x, bot.y, "stale snapshot", Palette.a(Palette.TEXT, 0.45), 9, 14);

		g.ghostSquare(me.x, me.y, Sim.PLAYER_HALF, Palette.a(Palette.TEXT, 0.5));
		var flash = App.nowMs() - bumpFlashT < 300;
		var px = recon.value("x"), py = recon.value("y");
		g.square(px, py, Sim.PLAYER_HALF, flash ? Palette.BAD : Palette.hue(me.hue));
		g.squareOutline(px, py, Sim.PLAYER_HALF, Palette.TEXT, flash ? 2.5 : 1);

		var rate = mispredictRate();
		var st: Dynamic = recon.state;
		g.hudSection("TELEMETRY");
		g.hudRow("bumps predicted", Std.string(bumpsPredicted), Palette.TEXT);
		g.hudRow("bumps (authoritative)", Std.string(me.bumps), Palette.TEXT);
		g.hudRow("mispredicts", Std.string(mispredicts),
			mispredicts > 0 ? Palette.WARN : Palette.GOOD);
		g.hudRow("mispredict rate", bumpsPredicted > 0 ? '${Math.round(rate)} %' : "--",
			bumpsPredicted == 0 ? Palette.TEXT_FAINT
				: (rate < 10 ? Palette.GOOD : rate < 40 ? Palette.WARN : Palette.BAD));
		g.hudRow("bump immunity (ticks)", Std.string(st.bumpTicks), Palette.TEXT);

		g.hudSection("CONTROLS");
		g.hudKey("WASD", "graze the bot's patrol path");
		g.hudKey("V", useValueAt ? "read bot at ctx.reckonTime" : "read the STALE snapshot");
		g.hudKey("M", useMemo ? "verdict frozen with memo" : "verdict RE-DERIVED on replay");
		g.hudNote("Raise the latency preset and graze the bot repeatedly. V off "
			+ "tests against a position ~RTT/2 behind where the server tests; M off "
			+ "lets replays re-derive the verdict against newer bot data and flip "
			+ "knife-edge calls. Both off is maximally wrong.");
	}

	public function unmount(): Void predict.dispose();

	public function onReconnect(): Void {
		me = room.state.players.items.get(sid);
		bot = room.state.bots.items.get("bot1");
		if (me == null) return;
		build();
	}

	public function roomRef(): Dynamic return room;
}
