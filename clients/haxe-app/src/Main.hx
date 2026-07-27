import App.Kb;
import Gfx.Palette;
import hxd.Key;
import io.colyseus.Client;
import labs.*;

/**
 * The windowed shell: one Heaps app. update() advances the active lab's netcode
 * and then its draw pass; the key table is filled here so a lab reads input the
 * same way whether a human or the acceptance harness is playing.
 *
 * Port of src/client/main.ts minus the web-only chrome (sidebar, docs panel,
 * deep links).
 */
class Main extends hxd.App {
	static inline var ENDPOINT = "ws://localhost:5173";
	static inline var PANEL_W = 360;

	/** Key edges last exactly one frame, like the web build's keydown handler. */
	static final KEYS: Array<{ name: String, code: Int }> = [
		{ name: "w", code: Key.W }, { name: "a", code: Key.A },
		{ name: "s", code: Key.S }, { name: "d", code: Key.D },
		{ name: "up", code: Key.UP }, { name: "down", code: Key.DOWN },
		{ name: "left", code: Key.LEFT }, { name: "right", code: Key.RIGHT },
		{ name: "space", code: Key.SPACE }, { name: "l", code: Key.L },
		{ name: "p", code: Key.P }, { name: "r", code: Key.R },
		{ name: "b", code: Key.B }, { name: "i", code: Key.I },
		{ name: "t", code: Key.T }, { name: "v", code: Key.V },
		{ name: "g", code: Key.G }, { name: "n", code: Key.N },
		{ name: "m", code: Key.M }, { name: "c", code: Key.C },
		{ name: "o", code: Key.O }, { name: "x", code: Key.X },
		{ name: "minus", code: Key.NUMPAD_SUB }, { name: "equals", code: Key.NUMPAD_ADD },
		{ name: "comma", code: Key.QWERTY_COMMA }, { name: "period", code: Key.QWERTY_PERIOD },
		{ name: "f1", code: Key.F1 }, { name: "f2", code: Key.F2 },
		{ name: "f3", code: Key.F3 }, { name: "f4", code: Key.F4 },
	];

	static final LAB_KEYS = [Key.NUMBER_0, Key.NUMBER_1, Key.NUMBER_2, Key.NUMBER_3,
		Key.NUMBER_4, Key.NUMBER_5, Key.NUMBER_6, Key.NUMBER_7, Key.NUMBER_8, Key.NUMBER_9];

	var gfx: GfxHeaps;
	var app: App;
	var labs: Array<Lab>;
	var labIndex = 0;
	var active: Lab;
	var mounting: Lab;
	var joined: Dynamic;
	var joinErr: String;
	var error: String;
	var lastNow: Float = -1;

	override function init() {
		engine.backgroundColor = Palette.BG & 0xFFFFFF;
		gfx = new GfxHeaps(s2d);

		if (Sim.selfcheck() != 0) trace("[playground] shared-sim port mismatch");

		app = new App(new Client(ENDPOINT), false);
		labs = [
			new Lab00(), new Lab01(), new Lab02(), new Lab03(), new Lab04(),
			new Lab05(), new Lab06(), new Lab07(), new Lab08(), new Lab09(), new Lab10(), new Lab11(),
		];
		switchTo(0);
	}

	function switchTo(index: Int): Void {
		if (mounting != null) return;              // a join is already in flight
		if (active != null) {
			active.unmount();
			var room: Dynamic = active.roomRef();
			if (room != null) room.leave(true);
			active = null;
		}
		error = null;
		labIndex = index;
		joined = null;
		joinErr = null;
		mounting = labs[index];
		mounting.join(app, function(e: Dynamic, room: Dynamic) {
			if (e != null) { joinErr = Std.string(e.message); return; }
			joined = room;
			// In front of the room's own listeners, but only now that it has
			// joined: the handshake rides an undelayed link, gameplay does not.
			NetDelay.wrap(room, App.nowMs);
		});
	}

	function pollJoin(): Void {
		if (joinErr != null) {
			error = joinErr;
			mounting = null;
			return;
		}
		if (joined == null || !mounting.ready(joined)) return;
		var lab = mounting;
		mounting = null;
		if (lab.mount(app, joined)) active = lab;
		else error = 'state never arrived for ${lab.id}';
	}

	function readKeys(): Void {
		Kb.pressed = new Map();
		for (k in KEYS) {
			if (Key.isDown(k.code)) Kb.down.set(k.name, true) else Kb.down.remove(k.name);
			if (Key.isPressed(k.code)) Kb.pressed.set(k.name, true);
		}
	}

	override function update(dt: Float) {
		// Deliver due packets first: the injector queues both directions and only
		// drains here, on the main loop.
		NetDelay.pump(App.nowMs());
		readKeys();

		if (mounting != null) pollJoin();

		var now = App.nowMs();
		var dtMs = (lastNow > 0) ? now - lastNow : 0;
		lastNow = now;

		if (Kb.key("l")) NetDelay.nextPreset();
		if (Kb.key("p")) { app.private_ = !app.private_; switchTo(labIndex); }
		for (i in 0...labs.length) {
			var n = labs[i].num;
			if (n < 10 && Key.isPressed(LAB_KEYS[n])) switchTo(i);
		}

		if (active != null) active.frame(app, now, dtMs);

		var w = s2d.width, h = s2d.height;
		var stageW = w - PANEL_W;
		gfx.beginFrame(0, 46, stageW, h - 46 - 40, stageW + 20, 60);

		var def = labs[labIndex];
		if (active != null) {
			if (!def.ownArena) gfx.arena();
			active.render(gfx);
		} else {
			gfx.caption(error != null ? error : "connecting...",
				error != null ? Palette.BAD : Palette.TEXT_DIM);
		}

		gfx.hudSection(StringTools.lpad(Std.string(def.num), "0", 2) + "  " + def.title);
		gfx.hudNote(def.blurb);
		gfx.hudSection("SHELL");
		gfx.hudKey("0-9", "switch lab");
		gfx.hudKey("L", 'injected latency: ${NetDelay.presetLabel()}');
		gfx.hudKey("P", app.private_ ? "room: private" : "room: shared");
		gfx.hudRow("in flight", '${NetDelay.inFlight()} pkt', Palette.TEXT_DIM);
		gfx.endFrame();
	}

	static function main() {
		new Main();
	}
}
