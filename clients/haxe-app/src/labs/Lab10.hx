package labs;

import App.Kb;
import Gfx.Palette;
import io.colyseus.Room;
import io.colyseus.predict.Predict;
import io.colyseus.predict.SimReconciler;
import lab.HockeyState;

/**
 * The simulated world. Both fields hold decoded instances at construction and
 * are replaced in place by mirrors, so the step writes `w.paddle.x` against a
 * real typed instance and the poses come out as "paddle.x" / "puck.x".
 *
 * A typed class rather than an anonymous structure on purpose: `w.paddle` is
 * then a real field access. Dynamic field access on a sys target silently
 * yields null for anything that turns out to be a property — the failure that
 * cost this client a session on `Room.state` — so it is worth designing out.
 */
class HockeyWorld {
	public var paddle: lab.Player;
	public var puck: lab.Puck;

	public function new(paddle: lab.Player, puck: lab.Puck) {
		this.paddle = paddle;
		this.puck = puck;
	}
}

/**
 * Lab 10 — Composite Sim (SimReconciler).
 *
 * The flat reconciler (lab 03) mirrors fields of ONE instance. Here the puck is
 * a separate entity — yet your shots must feel instant, so the puck is predicted
 * THROUGH your own inputs: every predicted paddle step also steps the puck and
 * resolves the contact, in the server's exact order. On each ack both bound
 * mirrors are re-seeded from authoritative state and the unacked inputs replay
 * on top, so a predicted shot is re-derived from truth every reconcile.
 *
 * Remote paddles enter the prediction as COLLIDERS at their latest snapshot
 * (their inputs aren't ours to predict), so a contested touch is the honest
 * misprediction to watch for.
 *
 * Port of src/client/labs/10-composite-sim/.
 */
class Lab10 implements Lab {
	public var id(default, null) = "10-composite-sim";
	public var num(default, null) = 10;
	public var title(default, null) = "Composite Sim";
	public var blurb(default, null) = "One rollback over a world of parts: paddle and puck together.";
	public var ownArena(default, null) = false;
	public var roomName(default, null) = "lab-hockey";

	/**
	 * PEAK, not instantaneous: the lead is largest right after a strike and
	 * collapses between them, so a spot reading says nothing.
	 */
	public var maxPuckLead(default, null): Float = 0;
	public var touches(default, null) = 0;
	public var sim(default, null): SimReconciler<HockeyWorld, lab.MoveInput>;

	var room: Room<HockeyState>;
	var sid: String;
	var me: lab.Player;
	var predict: Predict;
	var input: Dynamic;
	var cmd: Dynamic;
	var smoothing = 15.0;
	var showGhosts = true;
	var touchedLastStep = false;
	var trail: Array<Array<Float>> = [];

	public function new() {}

	public function join(app: App, cb: (Dynamic, Dynamic) -> Void): Void {
		if (app.private_) app.client.create(roomName, [], HockeyState, cb);
		else app.client.joinOrCreate(roomName, [], HockeyState, cb);
	}

	public function ready(raw: Dynamic): Bool {
		var r: Room<HockeyState> = cast raw;
		var state = r.state;
		return state != null && state.players != null && state.puck != null
			&& state.players.items.get(r.sessionId) != null;
	}

	public function mount(app: App, raw: Dynamic): Bool {
		room = cast raw;
		sid = room.sessionId;
		me = room.state.players.items.get(sid);
		if (me == null || room.state.puck == null) return false;

		predict = Predict.forRoom(room);
		// Remote paddles: damped toward the latest snapshot. They enter the sim
		// as colliders, not as predicted parts.
		predict.attachAll("players", ["x", "y"], { mode: "damped" });

		input = room.input({ type: lab.MoveInput });
		cmd = input.data;
		build();
		app.setLatencyPreset(2);     // a predicted shot says nothing on a 1 ms link
		return true;
	}

	function build(): Void {
		sim = predict.sim({
			input: input,
			smoothing: smoothing,
			world: new HockeyWorld(me, room.state.puck),
			step: step,
		});
	}

	/** The server's step order, reproduced: my paddle → puck → contacts. */
	function step(ctx: io.colyseus.predict.RollbackController.StepContext, w: HockeyWorld, inp: lab.MoveInput): Void {
		var pad: Sim.Entity = { x: w.paddle.x, y: w.paddle.y, vx: w.paddle.vx, vy: w.paddle.vy };
		Sim.stepEntity(pad, inp.moveX, inp.moveY, ctx.dt);
		w.paddle.x = pad.x; w.paddle.y = pad.y; w.paddle.vx = pad.vx; w.paddle.vy = pad.vy;

		var pk: Sim.Entity = { x: w.puck.x, y: w.puck.y, vx: w.puck.vx, vy: w.puck.vy };
		Sim.stepPuck(pk, ctx.dt);

		var touched = Sim.collidePaddlePuck(pad.x, pad.y, pad.vx, pad.vy, pk);
		// Remote paddles (and the AI) are colliders at their last-known pose; my
		// own paddle is resolved from the PREDICTED mirror above. The order is the
		// players-map iteration order, which the server shares.
		for (key in room.state.players.items.keys()) {
			if (key == sid) continue;
			var p = room.state.players.items.get(key);
			if (Sim.collidePaddlePuck(p.x, p.y, p.vx, p.vy, pk)) touched = true;
		}

		w.puck.x = pk.x; w.puck.y = pk.y; w.puck.vx = pk.vx; w.puck.vy = pk.vy;
		if (touched && !ctx.isReplay) touchedLastStep = true;
	}

	/**
	 * Where the predicted puck is relative to the predicted paddle. An autopilot
	 * that just sweeps never reaches the puck, and a puck nobody touches makes
	 * the lab look broken while proving nothing.
	 */
	function seekPuck(): { x: Int, y: Int } {
		var dx = sim.value("puck.x") - sim.value("paddle.x");
		var dy = sim.value("puck.y") - sim.value("paddle.y");
		return {
			x: dx > 0.4 ? 1 : dx < -0.4 ? -1 : 0,
			y: dy > 0.4 ? 1 : dy < -0.4 ? -1 : 0,
		};
	}

	public function frame(app: App, now: Float, dtMs: Float): Void {
		if (Kb.key("g")) showGhosts = !showGhosts;
		var stepSize = Kb.key("equals") ? 5 : Kb.key("minus") ? -5 : 0;
		if (stepSize != 0) {
			smoothing = Math.max(0, Math.min(40, smoothing + stepSize));
			build();
		}

		var mx = Kb.moveX(), my = Kb.moveY();
		if (Kb.autopilot) { var s = seekPuck(); mx = s.x; my = s.y; }

		var steps = predict.tick(now);
		for (_ in 0...steps) {
			cmd.moveX = mx;
			cmd.moveY = my;
			input.send();
			if (touchedLastStep) { touches++; touchedLastStep = false; }
		}

		var dx = sim.value("puck.x") - room.state.puck.x;
		var dy = sim.value("puck.y") - room.state.puck.y;
		var lead = Math.sqrt(dx * dx + dy * dy);
		if (lead > maxPuckLead) maxPuckLead = lead;

		trail.push([sim.value("puck.x"), sim.value("puck.y")]);
		if (trail.length > 120) trail.shift();
	}

	public function render(g: Gfx): Void {
		var state = room.state;

		for (key in state.players.items.keys()) {
			if (key == sid) continue;
			var p = state.players.items.get(key);
			var x = predict.value(p, "x"), y = predict.value(p, "y");
			g.circle(x, y, Sim.PADDLE_RADIUS, Palette.hue(p.hue, 0.35));
			g.circleOutline(x, y, Sim.PADDLE_RADIUS, Palette.hue(p.hue, 0.8));
		}

		if (showGhosts) {
			g.circleOutline(me.x, me.y, Sim.PADDLE_RADIUS, Palette.a(Palette.TEXT, 0.35), true);
			g.circleOutline(state.puck.x, state.puck.y, Sim.PUCK_RADIUS,
				Palette.a(Palette.TEXT, 0.45), true);
			g.label(state.puck.x, state.puck.y, "server puck",
				Palette.a(Palette.TEXT, 0.45), 9, 14);
		}

		for (i in 1...trail.length) {
			var a = trail[i - 1], b = trail[i];
			g.line(a[0], a[1], b[0], b[1],
				Palette.a(Palette.ACCENT, 0.4 * i / trail.length), 1.5);
		}

		var px = sim.value("paddle.x"), py = sim.value("paddle.y");
		g.circle(px, py, Sim.PADDLE_RADIUS, Palette.hue(me.hue, 0.5));
		g.circleOutline(px, py, Sim.PADDLE_RADIUS, Palette.TEXT);
		g.label(px, py, "you (predicted)", Palette.TEXT, 11, -16);

		var kx = sim.value("puck.x"), ky = sim.value("puck.y");
		g.circle(kx, ky, Sim.PUCK_RADIUS, Palette.a(Palette.ACCENT, 0.9));
		g.circleOutline(kx, ky, Sim.PUCK_RADIUS, Palette.ACCENT);
		g.label(kx, ky, "puck (predicted)", Palette.ACCENT, 10, -14);

		g.hudSection("TELEMETRY");
		g.hudChips("pending inputs (unacked)", sim.pendingCount);
		g.hudRow("drift ema", Std.string(sim.drift.ema), Palette.ACCENT);
		g.hudRow("puck lead (peak)", '${Math.round(maxPuckLead * 100) / 100} u', Palette.TEXT);
		g.hudRow("last correction", Std.string(sim.lastCorrectionMag), Palette.TEXT);
		g.hudRow("touches predicted", Std.string(touches), Palette.TEXT);

		g.hudSection("CONTROLS");
		g.hudKey("WASD", "drive your paddle into the puck");
		g.hudKey("- / =", 'smoothing ${Math.round(smoothing)} /s');
		g.hudKey("G", showGhosts ? "server ghosts: on" : "server ghosts: off");
		g.hudNote("One rollback over TWO parts. Your paddle and the puck are "
			+ "predicted together, in the server's order, so a strike is instant — "
			+ "and re-derived from truth on every ack. Remote paddles are colliders "
			+ "at their last snapshot, so a contested touch is the honest "
			+ "misprediction.");
	}

	public function unmount(): Void predict.dispose();

	public function onReconnect(): Void {
		me = room.state.players.items.get(sid);
		if (me == null) return;
		build();
		trail = [];
	}

	public function roomRef(): Dynamic return room;
}
