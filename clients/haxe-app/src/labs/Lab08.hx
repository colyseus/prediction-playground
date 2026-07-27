package labs;

import App.Kb;
import Gfx.Palette;
import io.colyseus.Room;
import io.colyseus.predict.Predict;
import io.colyseus.predict.PredictedEventChannel;
import lab.GoalState;

/**
 * Lab 08 — Optimistic Events.
 *
 * The GOAL banner fires the instant your PREDICTED square crosses the line, then
 * settles against the server:
 *
 *   predicted  ctx.predict() inside the reconciler step. Fires on the LIVE step
 *              only; rollback replays never re-fire it.
 *   confirmed  the server's "goal" broadcast -> channel.confirm().
 *   rejected   no confirmation by the time the server processed past the
 *              predicting input -> grace-tick auto-reject -> onReject.
 *
 * The zone gate itself is SHARED deterministic sim over a reconciled tick field:
 * whether you *entered* is never a misprediction — only the server's deny roll
 * can reject the event.
 *
 * Port of src/client/labs/08-optimistic-events/.
 */
class Lab08 implements Lab {
	public var id(default, null) = "08-optimistic-events";
	public var num(default, null) = 8;
	public var title(default, null) = "Optimistic Events";
	public var blurb(default, null) = "Instant feedback; confirm or reject.";
	public var ownArena(default, null) = false;
	public var roomName(default, null) = "lab-goal";

	public var records(default, null): Array<Record> = [];
	public var denyRate(default, null) = 0;

	var room: Room<GoalState>;
	var sid: String;
	var me: lab.GoalPlayer;
	var predict: Predict;
	var goals: PredictedEventChannel;
	var recon: Dynamic;
	var input: Dynamic;
	var cmd: Dynamic;
	var banner: String = null;
	var bannerColor = Palette.GOOD;
	var bannerT = -1e9;

	public function new() {}

	public function join(app: App, cb: (Dynamic, Dynamic) -> Void): Void {
		if (app.private_) app.client.create(roomName, [], GoalState, cb);
		else app.client.joinOrCreate(roomName, [], GoalState, cb);
	}

	public function ready(raw: Dynamic): Bool {
		var r: Room<GoalState> = cast raw;
		var state = r.state;
		return state != null && state.players != null
			&& state.players.items.get(r.sessionId) != null;
	}

	public function mount(app: App, raw: Dynamic): Bool {
		room = cast raw;
		sid = room.sessionId;
		me = room.state.players.items.get(sid);
		if (me == null) return false;
		denyRate = room.state.denyRate;

		predict = Predict.forRoom(room);
		predict.attachAll("players", { x: "damped", y: "damped" });

		goals = predict.defineEvent({
			onPredict: (_) -> { push(App.nowMs()); flash("GOAL!", Palette.GOOD); },
			onConfirm: (_) -> settle(1),
			onReject: (_) -> { settle(-1); flash("DENIED", Palette.BAD); },
		});

		room.onMessage("goal", function(message: Dynamic) {
			if (message.sid == sid) goals.confirm(null);
		});

		input = room.input({ type: lab.MoveInput });
		cmd = input.data;
		build();
		return true;
	}

	/** stepEntity + the shared score gate, with the sim-born optimistic event. */
	function build(): Void {
		var channel = goals;
		recon = predict.reconciler(me, {
			input: input,
			fields: ["x", "y", "vx", "vy", "scoreTicks"],
			smoothing: 15,
			step: (ctx, p, inp) -> {
				var e: Sim.Entity = { x: p.x, y: p.y, vx: p.vx, vy: p.vy };
				Sim.stepEntity(e, inp.moveX, inp.moveY, ctx.dt);
				p.x = e.x; p.y = e.y; p.vx = e.vx; p.vy = e.vy;

				// Live-only: ctx.predict is a no-op during rollback replay.
				var gate = Sim.stepScoreGate(p.x, p.y, p.scoreTicks);
				p.scoreTicks = gate.ticks;
				if (gate.scored) ctx.predict(channel, "goal");
			},
		});
	}

	function flash(text: String, color: Int): Void {
		banner = text;
		bannerColor = color;
		bannerT = App.nowMs();
	}

	function push(now: Float): Void {
		records.push({ predictedAt: now, settledAt: 0, outcome: 0 });
		if (records.length > 30) records.shift();
	}

	/** Settle the oldest still-pending record. */
	function settle(outcome: Int): Void {
		for (r in records) {
			if (r.outcome == 0) {
				r.outcome = outcome;
				r.settledAt = App.nowMs();
				return;
			}
		}
	}

	public function setDenyRate(rate: Int): Void {
		denyRate = Std.int(Math.max(0, Math.min(100, rate)));
		room.send("denyRate", { rate: denyRate });
	}

	/** confirmed, rejected, pending, total settle time — for the HUD and harness. */
	public function counts(): { confirmed: Int, rejected: Int, pending: Int, settleSum: Float } {
		var c = 0, r = 0, p = 0, sum = 0.0;
		for (rec in records) {
			if (rec.outcome == 1) { c++; sum += rec.settledAt - rec.predictedAt; }
			else if (rec.outcome == -1) r++;
			else p++;
		}
		return { confirmed: c, rejected: r, pending: p, settleSum: sum };
	}

	public function frame(app: App, now: Float, dtMs: Float): Void {
		// The deny rate is room-wide, like the web slider.
		var step = Kb.key("equals") ? 25 : Kb.key("minus") ? -25 : 0;
		if (step != 0) setDenyRate(denyRate + step);

		var steps = predict.tick(now);
		for (_ in 0...steps) {
			cmd.moveX = Kb.moveX();
			cmd.moveY = Kb.moveY();
			input.send();
		}
	}

	public function render(g: Gfx): Void {
		g.zone(Sim.GOAL_ZONE_X, Sim.GOAL_ZONE_Y, Sim.GOAL_ZONE_W, Sim.GOAL_ZONE_H,
			Palette.a(Palette.GOOD, 0.12), Palette.a(Palette.GOOD, 0.5));
		g.label(Sim.GOAL_ZONE_X + Sim.GOAL_ZONE_W / 2, Sim.GOAL_ZONE_Y, "GOAL",
			Palette.a(Palette.GOOD, 0.7), 10, -14);

		var state = room.state;
		for (key in state.players.items.keys()) {
			if (key == sid) continue;
			var p = state.players.items.get(key);
			g.square(predict.value(p, "x"), predict.value(p, "y"),
				Sim.PLAYER_HALF, Palette.hue(p.hue, 0.4));
		}

		g.ghostSquare(me.x, me.y, Sim.PLAYER_HALF, Palette.a(Palette.TEXT, 0.4));
		var px = recon.value("x"), py = recon.value("y");
		g.square(px, py, Sim.PLAYER_HALF, Palette.hue(me.hue));
		g.squareOutline(px, py, Sim.PLAYER_HALF, Palette.TEXT);

		var age = App.nowMs() - bannerT;
		if (banner != null && age < 1400) {
			g.caption(banner, Palette.a(bannerColor, Math.min(1, 3 * (1 - age / 1400))), 42);
		}

		var c = counts();
		g.hudSection("TELEMETRY");
		g.hudRow("score (authoritative)", Std.string(me.score), Palette.TEXT);
		g.hudRow("events predicted", Std.string(records.length), Palette.TEXT);
		g.hudRow("confirmed (avg settle)",
			c.confirmed > 0 ? '${c.confirmed} (${Math.round(c.settleSum / c.confirmed)} ms)' : "0",
			c.confirmed > 0 ? Palette.GOOD : Palette.TEXT_FAINT);
		g.hudRow("rejected", Std.string(c.rejected), c.rejected > 0 ? Palette.BAD : Palette.TEXT);
		g.hudRow("pending", Std.string(c.pending), c.pending > 0 ? Palette.WARN : Palette.TEXT);

		g.hudSection("RECENT EVENTS");
		for (i in 0...5) {
			var idx = records.length - 1 - i;
			if (idx < 0) { g.hudRow('event ${i + 1}', "--", Palette.TEXT_FAINT); continue; }
			var r = records[idx];
			if (r.outcome == 0) g.hudRow('event ${i + 1}', "pending...", Palette.WARN);
			else g.hudRow('event ${i + 1}',
				(r.outcome == 1 ? "confirmed" : "rejected")
					+ ' +${Math.round(r.settledAt - r.predictedAt)} ms',
				r.outcome == 1 ? Palette.GOOD : Palette.BAD);
		}

		g.hudSection("CONTROLS");
		g.hudKey("WASD", "run into the goal zone on the right");
		g.hudKey("- / =", 'server deny rate  $denyRate %');
		g.hudNote("The banner is optimistic — score is authoritative. Raise the deny "
			+ "rate and the banner goes up instantly, then retracts when the server "
			+ "stays silent.");
	}

	public function unmount(): Void predict.dispose();

	public function onReconnect(): Void {
		me = room.state.players.items.get(sid);
		if (me == null) return;
		goals.clear();
		build();
	}

	public function roomRef(): Dynamic return room;
}

/** One optimistic event and how it settled. */
typedef Record = { predictedAt: Float, settledAt: Float, outcome: Int };
