package playground;

import App.Kb;
import Gfx.Palette;
import io.colyseus.Room;
import io.colyseus.predict.Predict;
import lab.RangeState;

/**
 * Lab 06 — Lag Compensation.
 *
 * The client's job is only to be HONEST about its display timeline:
 *  - bots are DRAWN with lerp, REMOTE_INTERP_MS in the past;
 *  - the server records bot history and, on a fire input, rewinds every target
 *    to this client's render time — the instant the shooter aimed at;
 *  - allowRewind stamps the render time ONLY on fire frames (movement inputs
 *    don't need the extra wire bytes).
 *
 * Markers: blue = what you saw, green = the server's rewound read, red = the
 * server's live position. With lag comp on they coincide; with it off, the
 * red/blue gap is exactly how far you must lead.
 *
 * Port of src/client/labs/06-lag-comp/.
 */
class Lab06 implements Lab {
	public var id(default, null) = "06-lag-comp";
	public var num(default, null) = 6;
	public var title(default, null) = "Lag Compensation";
	public var blurb(default, null) = "The server rewinds targets to what you saw.";
	public var ownArena(default, null) = false;
	public var roomName(default, null) = "lab-range";

	public var hitsOn(default, null) = 0;
	public var shotsOn(default, null) = 0;
	public var hitsOff(default, null) = 0;
	public var shotsOff(default, null) = 0;
	/** Shots this screen called a hit at the click, before any report. */
	public var predictedHits(default, null) = 0;

	static inline var SHOT_FADE_MS = 2600;

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
	var shots: Array<Shot> = [];

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

		predict = Predict.forRoom(room);
		// Bots ride the lerp timeline — the one the server rewinds to.
		predict.attachAll("bots", {
			x: { mode: "lerp", delay: Sim.REMOTE_INTERP_MS },
			y: { mode: "lerp", delay: Sim.REMOTE_INTERP_MS },
		});
		predict.attachAll("players", { x: "damped", y: "damped" });

		room.onMessage("shot", function(m: Dynamic) onShot(m));

		// renderDelay is bound for us: reconciler() pushes this Predict's lerp
		// delay onto the handle, so the server rewinds to exactly the instant we
		// drew. Passing it here would only override that.
		input = room.input({ type: lab.RangeInput, allowRewind: (d: Dynamic) -> d.fire });
		cmd = input.data;
		build();
		app.setLatencyPreset(2);     // lag comp says nothing on a 1 ms link
		return true;
	}

	function build(): Void {
		recon = predict.reconciler(me, {
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

	/** The server's shot report completes the oldest unanswered record. */
	function onShot(m: Dynamic): Void {
		if (m.sid != sid) return;
		var hit: Bool = m.hit == true;
		for (s in shots) {
			if (s.answered) continue;
			s.answered = true;
			s.hit = hit;
			s.greenX = m.seenX; s.greenY = m.seenY;
			s.redX = m.liveX; s.redY = m.liveY;
			break;
		}
		if (m.lagComp == true) { shotsOn++; if (hit) hitsOn++; }
		else { shotsOff++; if (hit) hitsOff++; }
	}

	public function fire(): Void pendingFire = true;
	public function setLagComp(on: Bool): Void room.send("lagcomp", { on: on });

	/** Record what THIS screen showed at the moment of the shot. */
	function recordShot(now: Float): Void {
		var st: Dynamic = recon.state;
		var px: Float = st.x, py: Float = st.y;
		var dx = aimX - px, dy = aimY - py;
		var len = Math.sqrt(dx * dx + dy * dy);
		if (len < 1e-9) len = 1;
		dx /= len; dy /= len;
		var bx = predict.value(bot, "x"), by = predict.value(bot, "y");
		// The server's own hit test, run against the pose THIS screen was
		// showing. Available immediately, and it agrees with the server
		// whenever the rewind lands where it should.
		var predicted = Sim.rayCircle(px, py, dx, dy, bx, by, Sim.BOT_RADIUS, Sim.SHOT_RANGE) >= 0;
		if (predicted) predictedHits++;
		shots.push({
			ox: px, oy: py, tx: px + dx * 120, ty: py + dy * 120,
			blueX: bx, blueY: by,
			predictedHit: predicted,
			greenX: 0, greenY: 0, redX: 0, redY: 0,
			answered: false, hit: false, t: now,
		});
		if (shots.length > 6) shots.shift();
	}

	/** Newest answered shot's red/blue distance — how far the view lags. -1 if none. */
	public function viewLag(): Float {
		var i = shots.length - 1;
		while (i >= 0) {
			var s = shots[i];
			if (s.answered) {
				var dx = s.redX - s.blueX, dy = s.redY - s.blueY;
				return Math.sqrt(dx * dx + dy * dy);
			}
			i--;
		}
		return -1;
	}

	/**
	 * How far the server's rewound read landed from what we drew. This is the
	 * number that exposes an unbound renderDelay: it grows to exactly the lerp
	 * delay's worth of bot travel, and nothing else in the lab says so.
	 */
	public function rewindError(): Float {
		var i = shots.length - 1;
		while (i >= 0) {
			var s = shots[i];
			if (s.answered) {
				var dx = s.greenX - s.blueX, dy = s.greenY - s.blueY;
				return Math.sqrt(dx * dx + dy * dy);
			}
			i--;
		}
		return -1;
	}

	public function frame(app: App, now: Float, dtMs: Float): Void {
		if (Kb.autopilot) {
			// The acceptance script has no cursor — track the target it fires at.
			aimX = predict.value(bot, "x");
			aimY = predict.value(bot, "y");
		}
		if (Kb.key("space")) pendingFire = true;
		if (Kb.key("c")) setLagComp(!room.state.lagComp);

		var steps = predict.tick(now);
		for (_ in 0...steps) {
			cmd.moveX = Kb.moveX();
			cmd.moveY = Kb.moveY();
			cmd.aimX = aimX;
			cmd.aimY = aimY;
			cmd.fire = pendingFire;
			input.send();
			if (pendingFire) { recordShot(now); pendingFire = false; }
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
		g.label(bx, by, "target (lerp view)", Palette.BLUE, 10, -14);

		g.dashed(px, py, aimX, aimY, Palette.a(Palette.TEXT, 0.18));
		g.circleOutline(aimX, aimY, 0.9, Palette.a(Palette.TEXT, 0.7));

		var i = shots.length - 1;
		while (i >= 0) {
			var s = shots[i];
			var age = now - s.t;
			if (age > SHOT_FADE_MS) { shots.splice(i, 1); i--; continue; }
			var a = 1 - age / SHOT_FADE_MS;
			// Until the report lands the ray wears this screen's own verdict,
			// faint; the server's answer replaces it at full strength. A ray
			// that flips colour is the rewind disagreeing with what you saw.
			var ray = Palette.a((s.answered ? s.hit : s.predictedHit) ? Palette.GOOD : Palette.BAD,
				a * (s.answered ? 0.7 : 0.3));
			g.line(s.ox, s.oy, s.tx, s.ty, ray, 1.2);
			g.circleOutline(s.blueX, s.blueY, Sim.BOT_RADIUS * 0.7, Palette.a(Palette.BLUE, a));
			if (s.answered) {
				g.circleOutline(s.greenX, s.greenY, Sim.BOT_RADIUS * 0.85, Palette.a(Palette.GOOD, a));
				g.circleOutline(s.redX, s.redY, Sim.BOT_RADIUS, Palette.a(Palette.BAD, a));
			}
			i--;
		}

		var gap = viewLag();
		g.hudSection("TELEMETRY");
		g.hudRow("hits (lag comp ON)", '$hitsOn / $shotsOn',
			(shotsOn > 0 && hitsOn * 10 > shotsOn * 7) ? Palette.GOOD : Palette.TEXT);
		g.hudRow("hits (lag comp OFF)", '$hitsOff / $shotsOff',
			(shotsOff > 0 && hitsOff * 2 < shotsOff) ? Palette.BAD : Palette.TEXT);
		g.hudRow("view lag (red<->blue gap)",
			gap >= 0 ? '${Math.round(gap * 10) / 10} u' : "--",
			gap >= 0 ? Palette.TEXT : Palette.TEXT_FAINT);

		g.hudSection("CONTROLS");
		g.hudKey("WASD", "drive (predicted)");
		g.hudKey("mouse", "aim");
		g.hudKey("click / SPACE", "fire");
		g.hudKey("C", room.state.lagComp ? "lag comp: ON (room-wide)" : "lag comp: OFF (room-wide)");
		g.hudNote("blue = what you saw — green = the server's rewound read — red = "
			+ "the server live. The ray shows your own verdict faintly at the click, "
			+ "then the server's at full strength. Turn lag comp off at 200 ms and you "
			+ "have to lead the target by exactly the red-to-blue gap.");
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

/** One fired ray and the three answers it gets back. */
typedef Shot = {
	ox: Float, oy: Float, tx: Float, ty: Float,
	blueX: Float, blueY: Float,      // what the shooter saw at click time
	predictedHit: Bool,              // this screen's own verdict, at click time
	greenX: Float, greenY: Float,    // server's rewound read
	redX: Float, redY: Float,        // server's live position
	answered: Bool, hit: Bool, t: Float,
};
