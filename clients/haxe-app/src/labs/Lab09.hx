package labs;

import App.Kb;
import Gfx.Palette;
import io.colyseus.Room;
import io.colyseus.predict.Predict;
import io.colyseus.predict.PredictedSpawns;
import lab.ProjectileState;

/**
 * Lab 09 — Predicted Spawns.
 *
 * Click-to-fire feels instant because the client spawns an OPTIMISTIC local
 * projectile the same frame; when the server's authoritative entity arrives
 * (~RTT later) the store CORRELATES the two into one logical entry — same id,
 * same sprite, no visual seam.
 *
 *   owned      which server entities are mine to correlate (owner == me).
 *              Foreign ones (the turret's) surface as server-only entries.
 *   spawnTime  measures each shot's exact input lead (bornMs - predictedAt), so
 *              MY projectile keeps flying the shooter's timeline through the
 *              handoff instead of snapping back by lead x velocity.
 *   step       the SAME shared flight function the server integrates.
 *
 * Port of src/client/labs/09-predicted-spawns/.
 */
class Lab09 implements Lab {
	public var id(default, null) = "09-predicted-spawns";
	public var num(default, null) = 9;
	public var title(default, null) = "Predicted Spawns";
	public var blurb(default, null) = "Optimistic projectile -> authoritative handoff.";
	public var ownArena(default, null) = false;
	public var roomName(default, null) = "lab-projectile";

	public var fired(default, null) = 0;
	public var lastLeadMs(default, null) = Math.NaN;
	public var pending(default, null) = 0;
	public var confirmed(default, null) = 0;
	public var foreign(default, null) = 0;
	public var optimistic = true;

	var room: Room<ProjectileState>;
	var sid: String;
	var me: lab.Player;
	var predict: Predict;
	var spawns: PredictedSpawns;
	var recon: Dynamic;
	var input: Dynamic;
	var cmd: Dynamic;
	var aimX = 50.0;
	var aimY = 20.0;
	var pendingFire = false;
	// Per-entry presentation state, keyed on the STABLE entry id.
	var slots: Map<Int, { wasPending: Bool, flashT: Float }> = new Map();

	public function new() {}

	public function join(app: App, cb: (Dynamic, Dynamic) -> Void): Void {
		if (app.private_) app.client.create(roomName, [], ProjectileState, cb);
		else app.client.joinOrCreate(roomName, [], ProjectileState, cb);
	}

	public function ready(raw: Dynamic): Bool {
		var r: Room<ProjectileState> = cast raw;
		var state = r.state;
		return state != null && state.players != null
			&& state.players.items.get(r.sessionId) != null;
	}

	public function mount(app: App, raw: Dynamic): Bool {
		room = cast raw;
		sid = room.sessionId;
		me = room.state.players.items.get(sid);
		if (me == null) return false;

		predict = Predict.create(App.callbacks(room), room.clock);
		predict.attachAll("players", ["x", "y"], { mode: "damped" });

		var mySid = sid;
		spawns = predict.spawns("projectiles", {
			owned: (p) -> p.owner == mySid,
			spawnTime: (p) -> p.bornMs,
			step: (l, dt) -> Sim.stepProjectile(l, dt),
		});

		input = room.input({ type: lab.RangeInput });
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

	public function aimAt(x: Float, y: Float): Void { aimX = x; aimY = y; }
	public function fire(): Void pendingFire = true;

	/**
	 * Spawn the optimistic local at the PREDICTED pose — the same origin the
	 * server will use once this input arrives.
	 */
	function fireOptimistic(): Void {
		var st: Dynamic = recon.state;
		var px: Float = st.x, py: Float = st.y;
		var dx = aimX - px, dy = aimY - py;
		var len = Math.sqrt(dx * dx + dy * dy);
		if (len < 1e-9) len = 1;
		var shot: Sim.Entity = {
			x: px, y: py,
			vx: dx / len * Sim.PROJECTILE_SPEED,
			vy: dy / len * Sim.PROJECTILE_SPEED,
		};
		spawns.spawn(shot);
	}

	/**
	 * Fold the store's entries into presentation state: which are pending, which
	 * just crossed the handoff, and what lead the crossing measured. This lives in
	 * frame(), not render() — a headless run has the same numbers.
	 */
	function sweep(now: Float): Void {
		pending = 0;
		confirmed = 0;
		foreign = 0;
		var liveIds = new Map<Int, Bool>();
		for (e in spawns.entries()) {
			liveIds.set(e.id, true);
			var slot = slots.get(e.id);
			if (slot == null) slot = { wasPending: false, flashT: -1e9 };

			if (!e.confirmed) {
				if (e.local != null) { pending++; slot.wasPending = true; }
			} else {
				confirmed++;
				var srv: Dynamic = e.server;
				if (srv != null && srv.owner != sid) foreign++;
				if (slot.wasPending) {
					slot.wasPending = false;
					slot.flashT = now;
					if (e.leadMs > 0) lastLeadMs = e.leadMs;
				}
			}
			slots.set(e.id, slot);
		}
		for (id in slots.keys()) if (!liveIds.exists(id)) slots.remove(id);
	}

	public function frame(app: App, now: Float, dtMs: Float): Void {
		if (Kb.key("space")) pendingFire = true;
		if (Kb.key("o")) optimistic = !optimistic;

		var steps = predict.tick(now);
		for (_ in 0...steps) {
			cmd.moveX = Kb.moveX();
			cmd.moveY = Kb.moveY();
			cmd.aimX = aimX;
			cmd.aimY = aimY;
			cmd.fire = pendingFire;
			input.send();
			if (pendingFire) {
				fired++;
				if (optimistic) fireOptimistic();
				pendingFire = false;
			}
		}

		sweep(now);
	}

	public function render(g: Gfx): Void {
		var now = App.nowMs();

		g.square(50, 8, 2, Palette.a(Palette.BAD, 0.3));
		g.squareOutline(50, 8, 2, Palette.BAD, 1.5);
		g.label(50, 8, "turret (foreign shots)", Palette.BAD, 10, -16);

		var state = room.state;
		for (key in state.players.items.keys()) {
			if (key == sid) continue;
			var p = state.players.items.get(key);
			g.square(predict.value(p, "x"), predict.value(p, "y"),
				Sim.PLAYER_HALF, Palette.hue(p.hue, 0.4));
		}

		var mx = recon.value("x"), my = recon.value("y");
		g.square(mx, my, Sim.PLAYER_HALF, Palette.hue(me.hue));
		g.squareOutline(mx, my, Sim.PLAYER_HALF, Palette.TEXT);
		g.circleOutline(aimX, aimY, 0.8, Palette.a(Palette.TEXT, 0.6));

		// One render path across the handoff, keyed on the stable entry id.
		for (e in spawns.entries()) {
			if (!e.confirmed) {
				var loc: Dynamic = e.local;
				if (loc != null) g.circle(loc.x, loc.y, Sim.PROJECTILE_RADIUS,
					Palette.a(Palette.WARN, 0.9));
				continue;
			}
			var srv: Dynamic = e.server;
			if (srv == null) continue;
			var slot = slots.get(e.id);
			var flashing = slot != null && (now - slot.flashT) < 350;
			g.circle(srv.x, srv.y, Sim.PROJECTILE_RADIUS * (flashing ? 1.8 : 1.0),
				srv.owner == sid ? Palette.a(Palette.TEXT, 0.95) : Palette.a(Palette.BAD, 0.9));
		}

		g.hudSection("TELEMETRY");
		g.hudRow("pending (mine, unconfirmed)", Std.string(pending),
			pending > 0 ? Palette.WARN : Palette.TEXT);
		g.hudRow("confirmed entities", Std.string(confirmed), Palette.TEXT);
		g.hudRow("of those, foreign", Std.string(foreign), Palette.TEXT);
		g.hudRow("last measured input lead",
			Math.isNaN(lastLeadMs) ? "--" : '${Math.round(lastLeadMs)} ms',
			Math.isNaN(lastLeadMs) ? Palette.TEXT_FAINT : Palette.GOOD);
		g.hudRow("shots fired", Std.string(fired), Palette.TEXT);

		g.hudSection("CONTROLS");
		g.hudKey("WASD", "drive");
		g.hudKey("mouse", "aim");
		g.hudKey("click / SPACE", "fire");
		g.hudKey("O", optimistic ? "optimistic spawn: on" : "optimistic spawn: OFF");
		g.hudNote("Amber = predicted local (pending) — white = confirmed "
			+ "(correlated) — red = foreign (the turret's; nobody predicted them). "
			+ "Turn optimistic off with O and your own shot only appears when the "
			+ "server's entity arrives, ~RTT late.");
	}

	public function unmount(): Void predict.dispose();

	public function onReconnect(): Void {
		me = room.state.players.items.get(sid);
		if (me == null) return;
		spawns.clear();
		slots = new Map();
		build();
	}

	public function roomRef(): Dynamic return room;
}
