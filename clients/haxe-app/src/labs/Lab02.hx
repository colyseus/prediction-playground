package labs;

import App.Kb;
import App.Pacer;
import Gfx.Palette;
import io.colyseus.Room;
import lab.BotsState;

/**
 * Lab 02 — Clocks & Timelines.
 *
 * There is no clock "API call" to make: the moment the server declares
 * defineInput(), every input round-trip carries a TIMED prefix and the SDK
 * maintains room.clock. This lab just reads it — now / serverNow / renderNow /
 * rtt / smoothedRtt / jitter / lastServerTime.
 *
 * Port of src/client/labs/02-clocks/.
 */
class Lab02 implements Lab {
	public var id(default, null) = "02-clocks";
	public var num(default, null) = 2;
	public var title(default, null) = "Clocks & Timelines";
	public var blurb(default, null) = "serverNow / renderNow / RTT / jitter.";
	public var ownArena(default, null) = false;
	public var roomName(default, null) = "lab-bots";

	public var arrivals(default, null): Array<Float> = [];

	var room: Room<BotsState>;
	var sid: String;
	var bot: lab.Bot;
	var input: Dynamic;
	var cmd: Dynamic;
	var pacer: Pacer;
	var lastPatchStamp: Float = 0;

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
		// Inputs feed the clock: one send per fixed tick = one RTT/offset sample.
		input = room.input({ type: lab.MoveInput });
		cmd = input.data;
		pacer = new Pacer(1000.0 / Sim.TICK_HZ);
		return true;
	}

	public function frame(app: App, now: Float, dtMs: Float): Void {
		var steps = pacer.steps(now);
		for (_ in 0...steps) {
			cmd.moveX = Kb.moveX();
			cmd.moveY = Kb.moveY();
			input.send();
		}

		// A patch arrival = the server stamp changing.
		var stamp = room.clock.lastServerTime();
		if (stamp != lastPatchStamp) {
			lastPatchStamp = stamp;
			arrivals.push(now);
			if (arrivals.length > 128) arrivals.shift();
		}
	}

	public function render(g: Gfx): Void {
		var clock = room.clock;
		var state = room.state;
		for (key in state.players.items.keys()) {
			var p = state.players.items.get(key);
			g.square(p.x, p.y, Sim.PLAYER_HALF, Palette.hue(p.hue, key == sid ? 0.9 : 0.4));
		}

		g.circleOutline(bot.x, bot.y, Sim.BOT_RADIUS, Palette.TEXT, true);
		g.label(bot.x, bot.y, "raw snapshots (patch rate)",
			Palette.a(Palette.TEXT, 0.6), 10, -18);

		g.hudSection("TELEMETRY");
		g.hudRow("rtt", '${Math.round(clock.rtt())} ms', Palette.BLUE);
		g.hudRow("smoothed rtt", '${Math.round(clock.smoothedRtt())} ms', Palette.TEXT);
		g.hudRow("patch age (sawtooth)",
			'${Math.round(Math.max(0, clock.serverNow() - clock.lastServerTime()))} ms', Palette.GOOD);
		g.hudRow("|serverNow - renderNow| (slew)",
			'${Math.round(Math.abs(clock.serverNow() - clock.renderNow()))} ms', Palette.WARN);
		g.hudRow("jitter (interarrival)", '${Math.round(clock.jitter())} ms', Palette.TEXT);
		g.hudRow("patch interval", '${Math.round(clock.patchInterval())} ms', Palette.TEXT);
		g.hudRow("patch arrivals buffered", Std.string(arrivals.length), Palette.TEXT);

		g.hudSection("CONTROLS");
		g.hudKey("WASD", "drive");
		g.hudNote("Nothing to configure here — yank the latency preset with L and "
			+ "watch every readout respond. The offset re-converges; the slew spike "
			+ "decays over ~250 ms.");
	}

	public function unmount(): Void { arrivals = []; }

	public function onReconnect(): Void {
		pacer.reset();
		arrivals = [];
		lastPatchStamp = 0;
		bot = room.state.bots.items.get("bot1");
	}

	public function roomRef(): Dynamic return room;
}
