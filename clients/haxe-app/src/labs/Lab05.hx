package labs;

import App.Kb;
import App.Pacer;
import Gfx.Palette;
import io.colyseus.Room;
import io.colyseus.predict.Predict;
import lab.BotsState;

/**
 * Lab 05 — Dead Reckoning.
 *
 * Instead of drawing the PAST (lerp), forward-simulate the latest snapshot to
 * the PRESENT with the same step function the server runs. The reckon horizon is
 * exactly the snapshot age.
 *
 *   smoothing  glide applied to each snapshot REBASE (the small correction when
 *              a patch lands mid-glide).
 *   snap       rebases beyond this distance POP instead of gliding: a teleport
 *              is a cut, and smoothing across it looks like flying.
 *
 * Port of src/client/labs/05-dead-reckoning/.
 */
class Lab05 implements Lab {
	public var id(default, null) = "05-dead-reckoning";
	public var num(default, null) = 5;
	public var title(default, null) = "Dead Reckoning";
	public var blurb(default, null) = "Forward-simulate remotes to the present with the shared step.";
	public var ownArena(default, null) = false;
	public var roomName(default, null) = "lab-bots";

	static final PATTERNS = ["teleport", "patrol", "wander", "circle"];

	public var peakGap(default, null): Float = 0;
	public var reckon(default, null): Predict;
	public var bot(default, null): lab.Bot;

	var room: Room<BotsState>;
	var sid: String;
	var lerp: Predict;
	var input: Dynamic;
	var cmd: Dynamic;
	var pacer: Pacer;
	var smoothing = 25.0;
	var snap = 8.0;
	var pattern = 0;
	var dots: Array<Array<Float>> = [];
	var lastRawX = Math.NaN;
	var lastRawY = Math.NaN;
	var lastReckonX = Math.NaN;
	var warps = 0;
	var warpFlashT = -1e9;

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

		// The delayed baseline to compare against.
		lerp = Predict.forRoom(room);
		var lerpOpts = { mode: "lerp", delay: Sim.REMOTE_INTERP_MS };
		lerp.attach(bot, { x: lerpOpts, y: lerpOpts });

		attachReckon();

		input = room.input({ type: lab.MoveInput });
		cmd = input.data;
		pacer = new Pacer(1000.0 / Sim.TICK_HZ);

		setPattern(PATTERNS[0]);     // the teleporter is the most legible default
		return true;
	}

	/**
	 * The reckon step, called by the SDK with a scratch COPY of the bot.
	 * `elapsedMs` is absolute server-time at the end of the substep, which is what
	 * makes the circle's closed form and the teleport schedule evaluable at any
	 * instant — the same property the server relies on.
	 */
	function attachReckon(): Void {
		reckon = Predict.forRoom(room);
		reckon.attach(bot, {
			mode: "reckon",
			fields: ["x", "y"],
			smoothing: smoothing,
			snap: snap,
			step: (b, dt, elapsedMs) -> {
				// The scratch is a FULL copy, so `kind` and the patrol bounds are
				// readable straight off it.
				var s: Sim.BotState = {
					x: b.x, y: b.y, vx: b.vx, vy: b.vy, kind: b.kind,
					minX: b.minX, maxX: b.maxX, baseY: b.baseY,
					phaseMs: b.phaseMs, speed: b.speed, lastTeleport: b.lastTeleport,
				};
				Sim.stepBot(s, dt, elapsedMs);
				b.x = s.x; b.y = s.y; b.vx = s.vx; b.vy = s.vy;
				// Scratch mutation only persists within one forward pass — exactly
				// right: periods chain, nothing leaks into the snapshot.
				b.lastTeleport = s.lastTeleport;
			},
		});
	}

	function rebuild(): Void {
		reckon.dispose();
		attachReckon();
	}

	public function setPattern(kind: String): Void {
		var i = PATTERNS.indexOf(kind);
		if (i < 0) return;
		pattern = i;
		room.send("pattern", { kind: kind });
		warps = 0;
		peakGap = 0;
	}

	public function frame(app: App, now: Float, dtMs: Float): Void {
		if (Kb.key("b")) setPattern(PATTERNS[(pattern + 1) % PATTERNS.length]);
		var smoothStep = Kb.key("equals") ? 5 : Kb.key("minus") ? -5 : 0;
		if (smoothStep != 0) { smoothing = Math.max(0, Math.min(50, smoothing + smoothStep)); rebuild(); }
		var snapStep = Kb.key("period") ? 6 : Kb.key("comma") ? -6 : 0;
		if (snapStep != 0) { snap = Math.max(1, Math.min(60, snap + snapStep)); rebuild(); }

		var steps = pacer.steps(now);
		for (_ in 0...steps) {
			cmd.moveX = Kb.moveX();
			cmd.moveY = Kb.moveY();
			input.send();
		}
		lerp.tick(now);
		reckon.tick(now);

		if (bot.x != lastRawX || bot.y != lastRawY) {
			lastRawX = bot.x;
			lastRawY = bot.y;
			dots.push([bot.x, bot.y, now]);
			if (dots.length > 40) dots.shift();
		}

		var rx = reckon.value(bot, "x"), ry = reckon.value(bot, "y");
		if (!Math.isNaN(lastReckonX) && Math.abs(rx - lastReckonX) > 15) {
			warps++;
			warpFlashT = now;
		}
		lastReckonX = rx;

		var gx = rx - lerp.value(bot, "x"), gy = ry - lerp.value(bot, "y");
		var gap = Math.sqrt(gx * gx + gy * gy);
		if (gap > peakGap) peakGap = gap;
	}

	public function render(g: Gfx): Void {
		var now = App.nowMs();
		var clock = room.clock;
		var age = Math.max(0, clock.serverNow() - clock.lastServerTime());
		var state = room.state;

		for (key in state.players.items.keys()) {
			var p = state.players.items.get(key);
			g.square(p.x, p.y, Sim.PLAYER_HALF, Palette.hue(p.hue, key == sid ? 0.9 : 0.4));
		}

		// Raw snapshot dots, fading over 1.5 s — the samples reckon starts from.
		for (d in dots) {
			var a = 1 - (now - d[2]) / 1500.0;
			if (a > 0) g.circle(d[0], d[1], 0.4, Palette.a(Palette.TEXT, a * 0.5));
		}

		var lx = lerp.value(bot, "x"), ly = lerp.value(bot, "y");
		var rx = reckon.value(bot, "x"), ry = reckon.value(bot, "y");

		// The reckon horizon: newest snapshot -> forward-simulated present.
		g.dashed(bot.x, bot.y, rx, ry, Palette.a(Palette.WARN, 0.8), 1.2);
		g.circle(bot.x, bot.y, 0.7, Palette.a(Palette.TEXT, 0.9));

		g.circleOutline(lx, ly, Sim.BOT_RADIUS, Palette.BLUE);
		g.label(lx, ly, "lerp (past)", Palette.BLUE, 10, 14);
		g.circle(rx, ry, Sim.BOT_RADIUS, Palette.a(Palette.WARN, 0.25));
		g.circleOutline(rx, ry, Sim.BOT_RADIUS, Palette.WARN);
		g.label(rx, ry, "reckon (present)", Palette.WARN, 10, -14);

		if (now - warpFlashT < 500) g.label(rx, ry, "WARP", Palette.BAD, 13, -30);

		var dx = rx - lx, dy = ry - ly;
		g.hudSection("TELEMETRY");
		g.hudRow("reckon horizon (snapshot age)", '${Math.round(age)} ms', Palette.TEXT);
		g.hudRow("reckon vs lerp gap",
			'${Math.round(Math.sqrt(dx * dx + dy * dy) * 10) / 10} u', Palette.TEXT);
		g.hudRow("warps seen", Std.string(warps), Palette.TEXT);

		g.hudSection("CONTROLS");
		g.hudKey("WASD", "drive your own square");
		g.hudKey("B", 'bot pattern: ${PATTERNS[pattern]}');
		g.hudKey("- / =", 'rebase smoothing  ${Math.round(smoothing)} /s');
		g.hudKey(", / .", 'snap threshold  ${Math.round(snap)} u');
		g.hudNote("patrol = fully predictable — wander = server-secret turns, so "
			+ "reckon extrapolates straight through every one and gets corrected — "
			+ "teleport = a scheduled discontinuity. Raise the snap threshold above "
			+ "the warp distance and watch the teleport smear across the arena.");
	}

	public function unmount(): Void {
		if (reckon != null) reckon.dispose();
		if (lerp != null) lerp.dispose();
	}

	public function onReconnect(): Void {
		pacer.reset();
		bot = room.state.bots.items.get("bot1");
		dots = [];
	}

	public function roomRef(): Dynamic return room;
}
