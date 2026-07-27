package labs;

import App.Kb;
import Gfx.Palette;
import io.colyseus.Room;
import lab.MoveState;

/**
 * Lab 00 — Lag vs Prediction (the hero).
 *
 * Runs lab 03's netcode VERBATIM — same room, same reconciler, same entity, via
 * the shared MoveLane. The split screen is a RENDER-layer choice, not a
 * different protocol: the top lane draws the raw decoded server state (what lab
 * 01 draws), the bottom lane draws the reconciler's predicted pose (what lab 03
 * draws). Prediction is a client-side choice over the same authority.
 *
 * Port of src/client/labs/00-split/.
 */
class Lab00 implements Lab {
	public var id(default, null) = "00-split";
	public var num(default, null) = 0;
	public var title(default, null) = "Lag vs Prediction";
	public var blurb(default, null) = "Same input, same server — the top lane waits, the bottom predicts.";
	/** This lab paints two arenas of its own. */
	public var ownArena(default, null) = true;
	public var roomName(default, null) = "lab-move";

	public var lane(default, null) = new MoveLane();
	/** Peak, not instantaneous: the gap collapses at every direction change. */
	public var peakGap(default, null): Float = 0;
	public var userDrove(default, null) = false;

	/**
	 * Reversal-heavy autopilot legs — reversals are where the echo lane visibly
	 * keeps going the wrong way for a full round trip.
	 */
	static final SCRIPT = [
		[1, 0, 850], [-1, 0, 700], [1, 0, 550], [0, 1, 650], [0, -1, 700],
		[1, 1, 600], [-1, -1, 750], [-1, 0, 550], [1, 0, 800], [0, -1, 500],
	];

	var room: Room<MoveState>;
	var legIndex = 0;
	var legX = 1;
	var legY = 0;
	var legUntil = 0.0;
	var topTrail: Array<Array<Float>> = [];
	var botTrail: Array<Array<Float>> = [];

	public function new() {}

	public function join(app: App, cb: (Dynamic, Dynamic) -> Void): Void {
		if (app.private_) app.client.create(roomName, [], MoveState, cb);
		else app.client.joinOrCreate(roomName, [], MoveState, cb);
	}

	public function ready(raw: Dynamic): Bool return MoveLane.isReady(raw);

	public function mount(app: App, raw: Dynamic): Bool {
		room = cast raw;
		if (!lane.attach(raw)) return false;
		// The point of this lab is invisible on a 1 ms localhost link.
		app.setLatencyPreset(4);
		return true;
	}

	/** Scripted strides, steered away from a wall when a leg would hug one. */
	function autopilot(now: Float, x: Float, y: Float): Void {
		if (now < legUntil) return;
		var leg = SCRIPT[legIndex++ % SCRIPT.length];
		legX = leg[0];
		legY = leg[1];
		if (x > Sim.ARENA_W * 0.72 && legX > 0) legX = -1;
		else if (x < Sim.ARENA_W * 0.28 && legX < 0) legX = 1;
		if (y > Sim.ARENA_H * 0.72 && legY > 0) legY = -1;
		else if (y < Sim.ARENA_H * 0.28 && legY < 0) legY = 1;
		legUntil = now + leg[2];
	}

	static function pushTrail(trail: Array<Array<Float>>, x: Float, y: Float) {
		trail.push([x, y]);
		if (trail.length > 120) trail.shift();
	}

	public function frame(app: App, now: Float, dtMs: Float): Void {
		if (!userDrove && Kb.anyMove()) userDrove = true;
		if (!userDrove) autopilot(now, lane.x(), lane.y());

		lane.drive(now, userDrove ? Kb.moveX() : legX, userDrove ? Kb.moveY() : legY);

		pushTrail(topTrail, lane.me.x, lane.me.y);
		pushTrail(botTrail, lane.x(), lane.y());

		var dx = lane.x() - lane.me.x, dy = lane.y() - lane.me.y;
		var gap = Math.sqrt(dx * dx + dy * dy);
		if (gap > peakGap) peakGap = gap;
	}

	static function drawTrail(g: Gfx, trail: Array<Array<Float>>, color: Int, maxAlpha: Float) {
		for (i in 1...trail.length) {
			var a = trail[i - 1], b = trail[i];
			g.line(a[0], a[1], b[0], b[1], Palette.a(color, maxAlpha * i / trail.length), 1.5);
		}
	}

	public function render(g: Gfx): Void {
		var state = room.state;
		var me = lane.me;
		var px = lane.x(), py = lane.y();

		// Two lanes stacked in the stage. The backend maps lane 1/2 onto its own
		// half of the viewport; a lab never learns the pixel geometry.
		g.lane(1);
		g.arena();
		g.laneTitle("SERVER ECHO", "every move waits the full round trip",
			Palette.a(Palette.TEXT, 0.85));
		for (key in state.players.items.keys()) {
			if (key == lane.sid) continue;
			var p = state.players.items.get(key);
			g.square(p.x, p.y, Sim.PLAYER_HALF, Palette.hue(p.hue, 0.4));
		}
		drawTrail(g, topTrail, Palette.TEXT, 0.35);
		g.square(me.x, me.y, Sim.PLAYER_HALF, Palette.hue(me.hue, 0.8));
		g.squareOutline(me.x, me.y, Sim.PLAYER_HALF, Palette.a(Palette.TEXT, 0.5));
		g.label(me.x, me.y, "you (server)", Palette.a(Palette.TEXT, 0.6), 11, -15);

		g.lane(2);
		g.arena();
		g.laneTitle("PREDICTED", "instant — reconciled against the same server", Palette.GOOD);
		for (key in state.players.items.keys()) {
			if (key == lane.sid) continue;
			var p = state.players.items.get(key);
			g.square(lane.remoteX(p), lane.remoteY(p), Sim.PLAYER_HALF, Palette.hue(p.hue, 0.4));
		}
		drawTrail(g, botTrail, Palette.hue(me.hue), 0.45);
		g.square(px, py, Sim.PLAYER_HALF, Palette.hue(me.hue));
		g.squareOutline(px, py, Sim.PLAYER_HALF, Palette.TEXT);
		g.label(px, py, "you (predicted)", Palette.TEXT, 11, -15);
		g.lane(0);

		var rtt = room.clock.smoothedRtt();
		g.caption('ROUND TRIP ~ ${Math.round(rtt)} ms', Palette.ACCENT, 13);
		g.caption(userDrove
			? "Same keys, same server — the top lane waits, the bottom predicts."
			: "> autopilot — press WASD / arrows to take over",
			Palette.a(Palette.TEXT_DIM, 0.85));

		g.hudSection("TELEMETRY");
		g.hudRow("round trip", '${Math.round(rtt)} ms',
			rtt > 300 ? Palette.BAD : rtt > 120 ? Palette.WARN : Palette.GOOD);
		var dx = px - me.x, dy = py - me.y;
		g.hudRow("echo trails you by", '${Math.round(Math.sqrt(dx * dx + dy * dy) * 10) / 10} units',
			Palette.TEXT);
		g.hudChips("pending inputs (unacked)", lane.recon.pendingCount);

		g.hudSection("CONTROLS");
		g.hudKey("WASD", userDrove ? "drive (autopilot off)" : "take over from the autopilot");
		g.hudKey("L", "injected latency");
		g.hudNote("Render-only split: both lanes are the same entity in the same "
			+ "room, running lab 03's netcode verbatim.");
	}

	public function unmount(): Void lane.dispose();

	public function onReconnect(): Void {
		lane.rebind();
		topTrail = [];
		botTrail = [];
	}

	public function roomRef(): Dynamic return room;
}
