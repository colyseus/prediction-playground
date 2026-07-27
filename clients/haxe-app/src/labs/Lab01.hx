package labs;

import App.Kb;
import App.Pacer;
import Gfx.GfxNull;
import Gfx.Palette;

import io.colyseus.Room;
import lab.MoveState;

/**
 * Lab 01 — Feel the Lag.
 *
 * No prediction at all: send one input per fixed server tick, render the player
 * straight from decoded state. Every key press waits a full round trip, so the
 * `L` latency presets are what make this lab say anything.
 *
 * Port of src/client/labs/01-feel-the-lag/.
 */
class Lab01 implements Lab {
	public var id(default, null) = "01-feel-the-lag";
	public var num(default, null) = 1;
	public var title(default, null) = "Feel the Lag";
	public var blurb(default, null) = "No prediction: every key press waits a full round trip.";
	public var ownArena(default, null) = false;
	public var roomName(default, null) = "lab-move";

	/** Last input->motion reading, in ms. 0 until the meter fires. */
	public var measured(default, null): Float = 0;

	// `Room.state` is a property with a getter, and Dynamic field access on a sys
	// target reads the FIELD — which does not exist — and quietly yields null.
	// Every room reference here is cast to its concrete type for that reason.
	var room: Room<MoveState>;
	var sid: String;
	var input: Dynamic;
	var cmd: Dynamic;
	var pacer: Pacer;

	var damped = false;
	var damping = 12.0;
	var smooth: Map<String, { x: Float, y: Float }> = new Map();

	var phase = "idle";                 // idle | armed | shown
	var armT = 0.0;
	var armX = 0.0;
	var armY = 0.0;

	public function new() {}

	public function join(app: App, cb: (Dynamic, Dynamic) -> Void): Void {
		if (app.private_) app.client.create(roomName, [], lab.MoveState, cb);
		else app.client.joinOrCreate(roomName, [], lab.MoveState, cb);
	}

	public function ready(raw: Dynamic): Bool {
		var r: Room<MoveState> = cast raw;
		var state = r.state;
		return state != null && state.players != null
			&& state.players.items.get(r.sessionId) != null;
	}

	public function mount(app: App, raw: Dynamic): Bool {
		this.room = cast raw;
		this.sid = room.sessionId;
		this.input = room.input({ type: lab.MoveInput });
		this.cmd = input.data;
		this.pacer = new Pacer(1000.0 / Sim.TICK_HZ);
		return true;
	}

	public function frame(app: App, now: Float, dtMs: Float): Void {
		if (Kb.key("r")) damped = !damped;
		if (Kb.key("minus") && damping > 4) damping -= 2;
		if (Kb.key("equals") && damping < 30) damping += 2;

		// One input per fixed server tick — no reconciler here, so a local
		// accumulator paces the sends.
		var steps = pacer.steps(now);
		for (_ in 0...steps) {
			cmd.moveX = Kb.moveX();
			cmd.moveY = Kb.moveY();
			input.send();
		}

		var state = room.state;
		var dt = Math.min(0.1, dtMs / 1000.0);
		var k = 1 - Math.exp(-damping * dt);
		for (key in state.players.items.keys()) {
			var p = state.players.items.get(key);
			var sm = smooth.get(key);
			if (sm == null) { sm = { x: p.x, y: p.y }; smooth.set(key, sm); }
			sm.x += (p.x - sm.x) * k;
			sm.y += (p.y - sm.y) * k;
		}

		// input->photon meter: arm on a key press while at rest, measure when the
		// RENDERED position first moves.
		var me = state.players.items.get(sid);
		if (me == null) return;
		var speed = Math.abs(me.vx) + Math.abs(me.vy);
		if (phase != "armed" && Kb.anyMove() && speed < 0.01) {
			phase = "armed"; armT = now; armX = me.x; armY = me.y;
		} else if (phase == "armed") {
			if (Math.abs(me.x - armX) > 0.03 || Math.abs(me.y - armY) > 0.03) {
				measured = now - armT;
				phase = "shown";
			} else if (!Kb.anyMove() && now - armT > 2000) {
				phase = "idle";
			}
		} else if (phase == "shown" && !Kb.anyMove() && speed < 0.01) {
			phase = "idle";
		}
	}

	public function render(g: Gfx): Void {
		var state = room.state;
		for (key in state.players.items.keys()) {
			var p = state.players.items.get(key);
			var isMe = key == sid;
			var x = p.x, y = p.y;
			if (damped) {
				var sm = smooth.get(key);
				if (sm != null) { x = sm.x; y = sm.y; }
			}
			g.square(x, y, Sim.PLAYER_HALF, Palette.hue(p.hue, isMe ? 1 : 0.45));
			if (isMe) {
				g.squareOutline(x, y, Sim.PLAYER_HALF, Palette.TEXT);
				g.label(x, y, "you", Palette.TEXT, 11, -18);
			}
		}

		g.hudSection("TELEMETRY");
		g.hudRow("input -> motion", measured > 0 ? '${Math.round(measured)} ms' : "--",
			measured > 0 ? Palette.BAD : Palette.TEXT_FAINT);
		g.hudRow("meter state", phase,
			phase == "armed" ? Palette.WARN : phase == "shown" ? Palette.GOOD : Palette.TEXT_DIM);
		g.hudRow("render strategy", damped ? "damped" : "raw", Palette.TEXT);
		g.hudRow("damping", '${Math.round(damping)} /s', Palette.TEXT);

		g.hudSection("CONTROLS");
		g.hudKey("WASD", "drive");
		g.hudKey("R", "raw <-> damped");
		g.hudKey("- / =", "damping");
		g.hudNote("raw = decoded server state verbatim. damped = smooth toward it "
			+ "(even laggier). predicted = Lab 03. Raise the latency preset with L "
			+ "and feel the difference.");
	}

	public function unmount(): Void { smooth = new Map(); }

	public function onReconnect(): Void {
		pacer.reset();
		phase = "idle";
	}

	public function roomRef(): Dynamic return room;
}
