package labs;

import App.Kb;
import Gfx.Palette;
import io.colyseus.Room;
import io.colyseus.predict.Predict;
import lab.RangeState;

/**
 * Lab 11 — Deterministic Randomness.
 *
 * The shotgun fan is "random", yet the client predicts every pellet EXACTLY —
 * because the randomness is a pure function of data both sides already share:
 *
 *   seed = splitmix32(input seq ^ room salt)  ->  mulberry32 pellet stream
 *
 * The seq is the engine's own input counter (input.send() returns it; the server
 * reads channel.consumedCount). The salt is synced room state. NOTHING about the
 * pellets rides the wire — the server's broadcast here carries its angles only
 * so this lab can overlay and compare.
 *
 * Port of src/client/labs/11-deterministic-rng/.
 */
class Lab11 implements Lab {
	public var id(default, null) = "11-deterministic-rng";
	public var num(default, null) = 11;
	public var title(default, null) = "Deterministic Randomness";
	public var blurb(default, null) = "Same seed both sides, nothing on the wire.";
	public var ownArena(default, null) = false;
	public var roomName(default, null) = "lab-range";

	/** Worst client/server pellet disagreement, in radians. NaN until answered. */
	public var maxDivergence(default, null) = Math.NaN;
	public var cheat = false;

	static inline var FAN_LEN = 40.0;
	static inline var FAN_FADE_MS = 2400;

	var room: Room<RangeState>;
	var sid: String;
	var me: lab.RangePlayer;
	var bot: lab.Bot;
	var predict: Predict;
	var recon: Dynamic;
	var input: Dynamic;
	var cmd: Dynamic;
	var aimX = 50.0;
	var aimY = 20.0;
	var pendingFire = false;
	var cheatRng = new Sim.Rng(0x1234567);
	var fans: Array<Fan> = [];

	public function new() {}

	public function join(app: App, cb: (Dynamic, Dynamic) -> Void): Void {
		if (app.private_) app.client.create(roomName, [], RangeState, cb);
		else app.client.joinOrCreate(roomName, [], RangeState, cb);
	}

	public function ready(raw: Dynamic): Bool {
		var r: Room<RangeState> = cast raw;
		var state = r.state;
		return state != null && state.players != null && state.bots != null
			&& state.players.items.get(r.sessionId) != null
			&& state.bots.items.get("bot1") != null;
	}

	public function mount(app: App, raw: Dynamic): Bool {
		room = cast raw;
		sid = room.sessionId;
		me = room.state.players.items.get(sid);
		bot = room.state.bots.items.get("bot1");
		if (me == null || bot == null) return false;

		predict = Predict.create(App.callbacks(room), room.clock);
		// Bots ride the lerp timeline — the one the server rewinds to.
		predict.attachAll("bots", ["x", "y"], { mode: "lerp", delay: Sim.REMOTE_INTERP_MS });
		predict.attachAll("players", ["x", "y"], { mode: "damped" });

		room.onMessage("spread", function(m: Dynamic) onSpread(m));

		input = room.input({ type: lab.RangeInput, allowRewind: (d: Dynamic) -> d.fire });
		cmd = input.data;
		build();
		return true;
	}

	function build(): Void {
		recon = predict.makeReconciler(me, {
			input: input,
			fields: ["x", "y", "vx", "vy"],
			smoothing: 15,
			step: (ctx, p, inp) -> {
				var e: Sim.Entity = { x: p.x, y: p.y, vx: p.vx, vy: p.vy };
				Sim.stepEntity(e, inp.moveX, inp.moveY, ctx.dt);
				p.x = e.x; p.y = e.y; p.vx = e.vx; p.vy = e.vy;
			},
		});
	}

	/** The client's half of the derivation — identical to the server's. */
	function clientFan(baseAngle: Float, seq: Int, salt: Int): Array<Float> {
		if (!cheat) return Sim.spreadAngles(baseAngle, seq, salt);
		// The broken version: a local RNG the server cannot reproduce.
		var out = [];
		for (_ in 0...Sim.PELLETS) out.push(baseAngle + (cheatRng.next() - 0.5) * Sim.SPREAD_RAD);
		return out;
	}

	/** The server's fan for the same (seq, salt) — for overlay only. */
	function onSpread(m: Dynamic): Void {
		if (m.sid != sid || m.seq == null) return;
		var seq: Int = m.seq;
		for (f in fans) {
			if (f.seq != seq) continue;
			var angles: Array<Dynamic> = m.angles;
			var worst = 0.0;
			var n = angles.length < Sim.PELLETS ? angles.length : Sim.PELLETS;
			for (i in 0...n) {
				f.server[i] = angles[i];
				var d = Math.abs(f.client[i] - f.server[i]);
				if (d > worst) worst = d;
			}
			f.hits = (m.hits != null) ? m.hits : 0;
			f.answered = true;
			maxDivergence = worst;
			return;
		}
	}

	public function fire(): Void pendingFire = true;

	public function answeredFans(): Int {
		var n = 0;
		for (f in fans) if (f.answered) n++;
		return n;
	}

	public function frame(app: App, now: Float, dtMs: Float): Void {
		if (Kb.autopilot) {
			aimX = predict.value(bot, "x");
			aimY = predict.value(bot, "y");
		}
		if (Kb.key("space")) pendingFire = true;
		if (Kb.key("x")) cheat = !cheat;

		var steps = predict.tick(now);
		for (_ in 0...steps) {
			cmd.moveX = Kb.moveX();
			cmd.moveY = Kb.moveY();
			cmd.aimX = aimX;
			cmd.aimY = aimY;
			cmd.fire = pendingFire;
			cmd.spread = true;
			var seq: Int = input.send();
			if (pendingFire && seq > 0) {
				var st: Dynamic = recon.state;
				var px: Float = st.x, py: Float = st.y;
				var base = Math.atan2(aimY - py, aimX - px);
				fans.push({
					seq: seq, ox: px, oy: py, t: now, answered: false, hits: 0,
					client: clientFan(base, seq, room.state.salt), server: [],
				});
				if (fans.length > 4) fans.shift();
				pendingFire = false;
			}
		}
	}

	public function render(g: Gfx): Void {
		var now = App.nowMs();
		var state = room.state;

		for (key in state.players.items.keys()) {
			if (key == sid) continue;
			var p = state.players.items.get(key);
			g.square(predict.value(p, "x"), predict.value(p, "y"),
				Sim.PLAYER_HALF, Palette.hue(p.hue, 0.4));
		}

		var px = recon.value("x"), py = recon.value("y");
		g.square(px, py, Sim.PLAYER_HALF, Palette.hue(me.hue));
		g.squareOutline(px, py, Sim.PLAYER_HALF, Palette.TEXT);

		var bx = predict.value(bot, "x"), by = predict.value(bot, "y");
		g.circle(bx, by, Sim.BOT_RADIUS, Palette.a(Palette.BLUE, 0.25));
		g.circleOutline(bx, by, Sim.BOT_RADIUS, Palette.BLUE);
		g.circleOutline(aimX, aimY, 0.9, Palette.a(Palette.TEXT, 0.7));

		var i = fans.length - 1;
		while (i >= 0) {
			var f = fans[i];
			var age = now - f.t;
			if (age > FAN_FADE_MS) { fans.splice(i, 1); i--; continue; }
			var a = 1 - age / FAN_FADE_MS;
			for (p in 0...Sim.PELLETS) {
				var ang = f.client[p];
				g.line(f.ox, f.oy, f.ox + Math.cos(ang) * FAN_LEN, f.oy + Math.sin(ang) * FAN_LEN,
					Palette.a(Palette.WARN, a * 0.75), 1.2);
			}
			if (f.answered) {
				for (p in 0...Sim.PELLETS) {
					if (f.server[p] == null) continue;
					var ang = f.server[p];
					g.dashed(f.ox, f.oy, f.ox + Math.cos(ang) * FAN_LEN,
						f.oy + Math.sin(ang) * FAN_LEN, Palette.a(Palette.TEXT, a * 0.9), 0.8);
				}
			}
			i--;
		}
		if (fans.length > 0) {
			var last = fans[fans.length - 1];
			g.label(last.ox, last.oy, "amber = client — white = server",
				Palette.a(Palette.TEXT, 0.5), 9, 14);
		}

		var lastHits = -1;
		var j = fans.length - 1;
		while (j >= 0) { if (fans[j].answered) { lastHits = fans[j].hits; break; } j--; }

		g.hudSection("TELEMETRY");
		g.hudRow("fan divergence (last shot)",
			Math.isNaN(maxDivergence) ? "--" : Std.string(maxDivergence),
			Math.isNaN(maxDivergence) ? Palette.TEXT_FAINT
				: (maxDivergence < 1e-6 ? Palette.GOOD : Palette.BAD));
		g.hudRow("pellets hit (last shot)",
			lastHits >= 0 ? '$lastHits / ${Sim.PELLETS}' : "--",
			lastHits >= 0 ? Palette.TEXT : Palette.TEXT_FAINT);
		g.hudRow("room salt", Std.string(room.state.salt), Palette.TEXT);
		g.hudRow("shots (authoritative)", Std.string(me.shots), Palette.TEXT);

		g.hudSection("CONTROLS");
		g.hudKey("WASD", "drive");
		g.hudKey("mouse", "aim");
		g.hudKey("click / SPACE", "fire a 6-pellet fan");
		g.hudKey("X", cheat ? "CHEATING with a local RNG" : "seeded from (seq, salt)");
		g.hudNote("Amber = the fan your client derived at the click. White dashes = "
			+ "the fan the server derived from the same (seq, salt). They should be "
			+ "identical to the pixel. Press X to swap in an unshared RNG and watch "
			+ "them disagree.");
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

/** One fired fan: what we derived, and what the server did. */
typedef Fan = {
	seq: Int, ox: Float, oy: Float, t: Float,
	answered: Bool, hits: Int,
	client: Array<Float>, server: Array<Float>,
};
