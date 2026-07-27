import App.Kb;
import io.colyseus.Room;
import io.colyseus.predict.Predict;
import io.colyseus.predict.Reconciler;
import lab.MoveState;
import lab.Player;

/**
 * The reconciled `lab-move` lane: join, predict, reconcile, send.
 *
 * Labs 00 and 03 are the SAME netcode behind different renderers — the split
 * screen is a render-layer choice over one entity in one room, not a second
 * protocol — so the lane lives here and neither lab owns it.
 */
class MoveLane {
	public var room: Room<MoveState>;
	public var predict: Predict;
	public var recon: Reconciler;
	/** The raw authoritative pose — it trails by ~RTT. */
	public var me: Player;
	public var sid: String;

	/** Corrections past the noise floor, and the largest seen. */
	public var corrections: Int = 0;
	public var maxCorrectionMag: Float = 0;
	/** reset() on a teleport-class correction: a cut, not a glide. */
	public var autoSnap: Bool = true;
	public var smoothing: Float = 15;

	var input: Dynamic;
	var cmd: Dynamic;
	var lastReconcileSeq: Int = 0;

	public function new() {}

	/** What must be decoded before the lane can wire up. */
	// `Room.state` is a property with a getter, and Dynamic field access on a sys
	// target reads the FIELD — which does not exist — and quietly yields null.
	// Every room reference here is cast to its concrete type for that reason.
	public static function isReady(raw: Dynamic): Bool {
		var room: Room<MoveState> = cast raw;
		var state = room.state;
		return state != null && state.players != null
			&& state.players.items.get(room.sessionId) != null;
	}

	public function attach(raw: Dynamic): Bool {
		this.room = cast raw;
		this.sid = room.sessionId;
		this.me = room.state.players.items.get(sid);
		if (me == null) return false;

		this.input = room.input({ type: lab.MoveInput });
		this.cmd = input.data;
		this.predict = Predict.forRoom(room);
		// Remote squares: damped toward the latest snapshot. Their inputs are not
		// ours to predict — lab 04 explores the modes.
		predict.attachAll("players", { x: "damped", y: "damped" });
		build(smoothing);
		return true;
	}

	/** Rebuild the reconciler — smoothing is taken at construction. */
	public function build(smoothing: Float): Void {
		this.smoothing = smoothing;
		this.recon = predict.reconciler(me, {
			input: input,
			fields: ["x", "y", "vx", "vy"],
			smoothing: smoothing,
			// The SAME function the server runs — determinism is the contract.
			step: (ctx, s, inp) -> {
				var e: Sim.Entity = { x: s.x, y: s.y, vx: s.vx, vy: s.vy };
				Sim.stepEntity(e, inp.moveX, inp.moveY, ctx.dt);
				s.x = e.x; s.y = e.y; s.vx = e.vx; s.vy = e.vy;
			},
		});
		lastReconcileSeq = 0;
	}

	/**
	 * One frame of netcode: advance the stack, send the inputs it says are due,
	 * and fold in whatever the latest reconcile reported.
	 */
	public function drive(now: Float, moveX: Int, moveY: Int): Void {
		var steps = predict.tick(now);
		for (_ in 0...steps) {
			cmd.moveX = moveX;
			cmd.moveY = moveY;
			input.send();
		}

		if (recon.reconcileSeq == lastReconcileSeq) return;
		lastReconcileSeq = recon.reconcileSeq;
		var mag = recon.lastCorrectionMag;
		if (mag > 0.02) {
			corrections++;
			if (mag > maxCorrectionMag) maxCorrectionMag = mag;
		}
		if (autoSnap && mag > Sim.TELEPORT_SNAP_DIST) recon.reset();
	}

	/** The predicted pose: what the local player should be looking at. */
	public function x(): Float return recon.value("x");
	public function y(): Float return recon.value("y");

	/** The predicted pose of a remote square (damped, not reconciled). */
	public function remoteX(p: Dynamic): Float return predict.value(p, "x");
	public function remoteY(p: Dynamic): Float return predict.value(p, "y");

	/**
	 * After a reconnect. The reconnected room counts inputs from ZERO, so a
	 * reconciler carrying the pre-drop backlog would replay it on every reconcile
	 * — rebind to the fresh entity and start the buffer over.
	 */
	public function rebind(): Void {
		var fresh = room.state.players.items.get(sid);
		if (fresh != null) me = fresh;
		build(smoothing);
	}

	public function dispose(): Void {
		if (predict != null) predict.dispose();
	}
}
