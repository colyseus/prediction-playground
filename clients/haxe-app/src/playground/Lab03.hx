package playground;

import App.Kb;
import App.Pacer;
import Gfx.GfxNull;
import Gfx.Palette;

import io.colyseus.predict.Drift;
import io.colyseus.Room;
import lab.MoveState;

/**
 * Lab 03 — Predict & Reconcile.
 *
 * The reconciler OBSERVES the input handle: every send() is predicted locally
 * the same instant and buffered. When the server's next patch acks input N, it
 * rewinds to the authoritative state and REPLAYS inputs N+1.. through the same
 * shared stepEntity — so the predicted pose stays consistent with everything the
 * server hasn't seen.
 *
 * Port of src/client/labs/03-reconcile/.
 */
class Lab03 implements Lab {
	public var id(default, null) = "03-reconcile";
	public var num(default, null) = 3;
	public var title(default, null) = "Predict & Reconcile";
	public var blurb(default, null) = "Rollback to the ack, replay pending inputs, smooth the error.";
	public var ownArena(default, null) = false;
	public var roomName(default, null) = "lab-move";

	public var lane(default, null) = new MoveLane();

	// `Room.state` is a property with a getter, and Dynamic field access on a sys
	// target reads the FIELD — which does not exist — and quietly yields null.
	// Every room reference here is cast to its concrete type for that reason.
	var room: Room<MoveState>;
	var renderSmoothed = true;
	var showGhost = true;

	public function new() {}

	public function join(app: App, cb: (Dynamic, Dynamic) -> Void): Void {
		if (app.private_) app.client.create(roomName, [], lab.MoveState, cb);
		else app.client.joinOrCreate(roomName, [], lab.MoveState, cb);
	}

	public function ready(room: Dynamic): Bool return MoveLane.isReady(room);

	public function mount(app: App, raw: Dynamic): Bool {
		this.room = cast raw;
		return lane.attach(room);
	}

	public function frame(app: App, now: Float, dtMs: Float): Void {
		if (Kb.key("i")) room.send("impulse");
		if (Kb.key("t")) room.send("teleport");
		if (Kb.key("v")) renderSmoothed = !renderSmoothed;
		if (Kb.key("g")) showGhost = !showGhost;
		if (Kb.key("n")) lane.autoSnap = !lane.autoSnap;
		var step = Kb.key("equals") ? 5 : Kb.key("minus") ? -5 : 0;
		if (step != 0) lane.build(Math.max(0, Math.min(40, lane.smoothing + step)));

		lane.drive(now, Kb.moveX(), Kb.moveY());
	}

	public function render(g: Gfx): Void {
		var state = room.state;
		var me = lane.me;

		for (key in state.players.items.keys()) {
			if (key == lane.sid) continue;
			var p = state.players.items.get(key);
			g.square(lane.remoteX(p), lane.remoteY(p), Sim.PLAYER_HALF, Palette.hue(p.hue, 0.45));
		}

		// Server ghost: the raw authoritative pose — it trails by ~RTT.
		if (showGhost) {
			g.ghostSquare(me.x, me.y, Sim.PLAYER_HALF, Palette.a(Palette.TEXT, 0.75));
			g.label(me.x, me.y, "server", Palette.a(Palette.TEXT, 0.55), 11, 14);
		}

		var exact: Dynamic = lane.recon.state;
		var px = renderSmoothed ? lane.x() : exact.x;
		var py = renderSmoothed ? lane.y() : exact.y;
		g.square(px, py, Sim.PLAYER_HALF, Palette.hue(me.hue));
		g.squareOutline(px, py, Sim.PLAYER_HALF, Palette.TEXT);
		g.label(px, py, "you (predicted)", Palette.TEXT, 11, -18);

		var recon = lane.recon;
		var status = recon.drift.classify(0);
		g.hudSection("TELEMETRY");
		g.hudChips("pending inputs (unacked)", recon.pendingCount);
		g.hudRow("drift status", status,
			status == "matched" ? Palette.GOOD : status == "jitter" ? Palette.WARN : Palette.BAD);
		g.hudRow("drift ema", Std.string(recon.drift.ema), Palette.ACCENT);
		g.hudRow("last correction", Std.string(recon.lastCorrectionMag), Palette.TEXT);
		g.hudRow("corrections seen", Std.string(lane.corrections), Palette.TEXT);
		g.hudRow("reconciles", Std.string(recon.reconcileSeq), Palette.TEXT);

		g.hudSection("CONTROLS");
		g.hudKey("WASD", "drive");
		g.hudKey("I", "force mispredict (impulse)");
		g.hudKey("T", "teleport");
		g.hudKey("- / =", 'smoothing ${Math.round(lane.smoothing)} /s');
		g.hudKey("V", renderSmoothed ? "render: value() smoothed" : "render: state (exact)");
		g.hudKey("G", showGhost ? "server ghost: on" : "server ghost: off");
		g.hudKey("N", lane.autoSnap ? "snap on teleport: on" : "snap on teleport: off");
		g.hudNote("Corrections beyond 8u call reset() — a cut, not a cross-arena "
			+ "glide. Turn it off with N and teleport to see why.");
	}

	public function unmount(): Void lane.dispose();
	public function onReconnect(): Void lane.rebind();
	public function roomRef(): Dynamic return room;
}
