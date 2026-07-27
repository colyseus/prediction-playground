package labs;

import App.Kb;
import App.Pacer;
import Gfx.Palette;
import io.colyseus.Room;
import io.colyseus.predict.Predict;
import lab.BotsState;

/**
 * Lab 04 — Remote Interpolation.
 *
 * The SAME bot rendered through four Predict instances, one per mode:
 *
 *   raw          the decoded snapshot verbatim: stutters at patch rate.
 *   lerp         render `delay` ms in the PAST, between two real samples.
 *                Never wrong, always late.
 *   damped       exponential chase of the newest sample: lags by construction
 *                and rounds corners.
 *   extrapolate  project the trend FORWARD. Present-time, but overshoots
 *                whenever the bot turns.
 *
 * Port of src/client/labs/04-interp-modes/.
 */
class Lab04 implements Lab {
	public var id(default, null) = "04-interp-modes";
	public var num(default, null) = 4;
	public var title(default, null) = "Remote Interpolation";
	public var blurb(default, null) = "lerp / damped / extrapolate / raw, side by side.";
	public var ownArena(default, null) = false;
	public var roomName(default, null) = "lab-bots";

	static final PATTERNS = ["patrol", "circle", "wander"];

	/** How far the raw bot has travelled — a stationary bot scores NaN. */
	public var botTravel(default, null): Float = 0;

	var room: Room<BotsState>;
	var sid: String;
	var bot: lab.Bot;
	var input: Dynamic;
	var cmd: Dynamic;
	var pacer: Pacer;
	var modes: Array<Mode>;
	var pattern = 0;
	var lastRawX = Math.NaN;
	var lastRawY = Math.NaN;

	public function new() {}

	public function join(app: App, cb: (Dynamic, Dynamic) -> Void): Void {
		if (app.private_) app.client.create(roomName, [], BotsState, cb);
		else app.client.joinOrCreate(roomName, [], BotsState, cb);
	}

	public function ready(raw: Dynamic): Bool {
		var r: Room<BotsState> = cast raw;
		var state = r.state;
		return state != null && state.bots != null && state.bots.items.get("bot1") != null;
	}

	public function mount(app: App, raw: Dynamic): Bool {
		room = cast raw;
		sid = room.sessionId;
		bot = room.state.bots.items.get("bot1");
		if (bot == null) return false;

		input = room.input({ type: lab.MoveInput });
		cmd = input.data;
		pacer = new Pacer(1000.0 / Sim.TICK_HZ);

		modes = [
			new Mode("raw", Palette.TEXT, null),
			new Mode("lerp", Palette.BLUE, attach({ mode: "lerp", delay: Sim.REMOTE_INTERP_MS })),
			new Mode("damped", Palette.GOOD, attach({ mode: "damped", damping: 12 })),
			new Mode("extrapolate", Palette.WARN, attach({ mode: "extrapolate", maxExtrapolate: 250 })),
		];
		return true;
	}

	/** One Predict per mode — same entity, same fields, different smoothing. */
	function attach(opts: Dynamic): Predict {
		var p = Predict.create(App.callbacks(room), room.clock);
		p.track(bot, "x", opts);
		p.track(bot, "y", opts);
		return p;
	}

	function value(m: Mode, field: String): Float {
		if (m.predict == null) return (field == "x") ? bot.x : bot.y;   // raw
		return m.predict.value(bot, field);
	}

	public function setPattern(kind: String): Void {
		var i = PATTERNS.indexOf(kind);
		if (i < 0) return;
		pattern = i;
		room.send("pattern", { kind: kind });
	}

	/** Start a clean measurement window once a pattern change has landed. */
	public function resetMeters(): Void {
		for (m in modes) m.smooth.clear();
		botTravel = 0;
	}

	/** Per-mode speed CV, for the acceptance harness. NaN = never scored. */
	public function smoothnessByMode(): Map<String, Float> {
		var out = new Map<String, Float>();
		for (m in modes) out.set(m.name, m.smooth.cv());
		return out;
	}

	public function frame(app: App, now: Float, dtMs: Float): Void {
		if (Kb.key("b")) setPattern(PATTERNS[(pattern + 1) % PATTERNS.length]);
		for (i in 0...4) if (Kb.key('f${i + 1}')) modes[i].visible = !modes[i].visible;

		var steps = pacer.steps(now);
		for (_ in 0...steps) {
			cmd.moveX = Kb.moveX();
			cmd.moveY = Kb.moveY();
			input.send();
		}
		for (m in modes) if (m.predict != null) m.predict.tick(now);

		if (!Math.isNaN(lastRawX) && (bot.x != lastRawX || bot.y != lastRawY)) {
			var dx = bot.x - lastRawX, dy = bot.y - lastRawY;
			botTravel += Math.sqrt(dx * dx + dy * dy);
		}
		lastRawX = bot.x;
		lastRawY = bot.y;

		for (m in modes) m.smooth.sample(value(m, "x"), value(m, "y"), dtMs);
	}

	public function render(g: Gfx): Void {
		var state = room.state;
		for (key in state.players.items.keys()) {
			var p = state.players.items.get(key);
			g.square(p.x, p.y, Sim.PLAYER_HALF, Palette.hue(p.hue, key == sid ? 0.9 : 0.4));
		}

		for (i in 0...modes.length) {
			var m = modes[i];
			if (!m.visible) continue;
			var x = value(m, "x"), y = value(m, "y");
			g.circleOutline(x, y, Sim.BOT_RADIUS, m.color, i == 0);
			// Stagger the labels: the four modes sit within a bot radius of each
			// other most of the time, so a shared baseline is unreadable.
			g.label(x, y, m.name, m.color, 10, -14 - i * 11);
		}

		g.hudSection("SMOOTHNESS (speed CV)");
		for (m in modes) {
			var cv = m.smooth.cv();
			if (Math.isNaN(cv)) g.hudRow(m.name, "--", Palette.TEXT_FAINT);
			else g.hudRow(m.name, '${Math.round(cv * 100)} %',
				cv < 0.15 ? Palette.GOOD : cv < 0.5 ? Palette.WARN : Palette.BAD);
		}
		g.hudRow("bot travel", '${Math.round(botTravel)} u', Palette.TEXT);

		g.hudSection("CONTROLS");
		g.hudKey("WASD", "drive your own square");
		g.hudKey("B", 'bot pattern: ${PATTERNS[pattern]}');
		for (i in 0...modes.length)
			g.hudKey('F${i + 1}', (modes[i].visible ? "hide " : "show ") + modes[i].name);
		g.hudNote("Lower CV = smoother render. raw stutters at the patch rate; lerp "
			+ "is smooth but late; damped rounds corners; extrapolate is present-time "
			+ "but overshoots every turn — press B and watch it on circle.");
	}

	public function unmount(): Void {
		for (m in modes) if (m.predict != null) m.predict.dispose();
	}

	public function onReconnect(): Void {
		pacer.reset();
		bot = room.state.bots.items.get("bot1");
	}

	public function roomRef(): Dynamic return room;
}

/** One render mode: its Predict (null = raw), visibility, and metric. */
private class Mode {
	public var name: String;
	public var color: Int;
	public var predict: Predict;
	public var visible = true;
	public var smooth = new Smoothness();

	public function new(name: String, color: Int, predict: Predict) {
		this.name = name;
		this.color = color;
		this.predict = predict;
	}
}

/**
 * Coefficient of variation of rendered per-frame speed — the "limp" metric lab
 * 04 scores its interpolation modes with. Constant speed scores 0; a mode that
 * stutters between stalls and jumps scores high.
 */
private class Smoothness {
	static inline var CAP = 120;

	var speeds: Array<Float> = [];
	var head = 0;
	var count = 0;
	var lastX = 0.0;
	var lastY = 0.0;
	var seeded = false;

	public function new() {}

	public function clear(): Void {
		speeds = [];
		head = 0;
		count = 0;
		seeded = false;
	}

	public function sample(x: Float, y: Float, dtMs: Float): Void {
		if (seeded && dtMs > 0) {
			var dx = x - lastX, dy = y - lastY;
			speeds[head] = Math.sqrt(dx * dx + dy * dy) / dtMs * 1000.0;
			head = (head + 1) % CAP;
			if (count < CAP) count++;
		}
		lastX = x;
		lastY = y;
		seeded = true;
	}

	/** NaN when there isn't enough motion for the ratio to mean anything. */
	public function cv(): Float {
		if (count < 20) return Math.NaN;
		var mean = 0.0;
		for (i in 0...count) mean += speeds[i];
		mean /= count;
		if (mean < 0.5) return Math.NaN;
		var v = 0.0;
		for (i in 0...count) { var d = speeds[i] - mean; v += d * d; }
		return Math.sqrt(v / count) / mean;
	}
}
