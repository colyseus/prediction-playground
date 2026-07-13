import docs from "./docs.md?raw";
import source from "./net.ts?raw";
import { connect, makeSim } from "./net.ts";
import type { LabDescriptor, LabContext, LabInstance } from "../../framework/lab.ts";
import { waitFor } from "../../framework/lab.ts";
import { Keyboard } from "../../framework/input.ts";
import { drawCircle, drawGhostSquare, drawLabel, hueColor } from "../../framework/draw.ts";
import { Trail } from "../../framework/trail.ts";
import { PADDLE_RADIUS, PUCK_RADIUS } from "../../../shared/hockey.ts";

export const lab: LabDescriptor = {
  id: "10-composite-sim",
  num: 10,
  title: "Composite World",
  blurb: "predict.sim: a world you only partly control.",
  phase: 2,
  docs,
  source,

  async mount(ctx: LabContext): Promise<LabInstance> {
    const { room, predict, input } = await connect(ctx.client);
    const me = await waitFor(() => room.state.players.get(room.sessionId));
    await waitFor(() => room.state.puck);

    let smoothing = 15;
    let sim = makeSim(predict, room as any, input, smoothing);

    const kb = new Keyboard();
    const puckTrail = new Trail(120);

    const botToggle = ctx.controls.toggle({
      label: "Opponent bot (room-wide)",
      value: room.state.botEnabled,
      onChange: (v) => room.send("bot", { on: v }),
      note: "Off = the world is fully yours; corrections flatline. On = contested touches mispredict.",
    });
    ctx.controls.slider({
      label: "Correction smoothing",
      min: 0, max: 40, value: smoothing, unit: "/s",
      onCommit: true,
      onChange: (v) => {
        smoothing = v;
        sim.dispose();
        sim = makeSim(predict, room as any, input, smoothing);
      },
    });
    ctx.controls.buttons([
      { label: "⟲ Reset puck", onClick: () => room.send("resetPuck") },
    ]);
    ctx.controls.note("WASD to skate. Hit the puck — it responds the same frame, at any latency: the puck is predicted through YOUR inputs.");

    const corrSpark = ctx.hud.spark("correction magnitude", { format: (v) => v.toFixed(2), color: "#ff6688" });
    const pendingRow = ctx.hud.row("pending inputs");
    const puckGapRow = ctx.hud.row("predicted puck vs server ghost");
    let lastReconcileSeq = 0;
    let lastCorr = 0;

    return {
      room,
      frame(now: number) {
        const steps = predict.tick(now);
        const d = input.data;
        for (let i = 0; i < steps; i++) {
          d.moveX = kb.moveX();
          d.moveY = kb.moveY();
          input.send();
        }
        if (botToggle.get() !== room.state.botEnabled) botToggle.set(room.state.botEnabled);

        const g = ctx.g, v = ctx.view;
        const pose = sim.pose();

        // Remote paddles (damped).
        for (const [sid, p] of room.state.players) {
          if (sid === room.sessionId) continue;
          const isBot = sid === "bot";
          drawCircle(g, v, predict.value(p, "x"), predict.value(p, "y"), PADDLE_RADIUS, {
            fill: hueColor(p.hue, isBot ? 0.7 : 0.4),
            stroke: isBot ? "#6db3ff" : undefined,
          });
          if (isBot) drawLabel(g, v, predict.value(p, "x"), predict.value(p, "y"), "bot", { dy: -v.s(PADDLE_RADIUS) - 5, size: 10, color: "#6db3ff" });
        }

        // Server ghost puck (raw truth — trails by ~RTT) + predicted puck.
        const sp = room.state.puck;
        drawCircle(g, v, sp.x, sp.y, PUCK_RADIUS, { stroke: "rgba(216,226,240,0.55)", dash: [3, 3], lineWidth: 1.2 });
        puckTrail.push(pose.kx, pose.ky);
        puckTrail.draw(g, v, "#ffd36b", 1.2, 0.4);
        drawCircle(g, v, pose.kx, pose.ky, PUCK_RADIUS, { fill: "#ffd36b" });
        drawLabel(g, v, pose.kx, pose.ky, "puck (predicted)", { dy: -v.s(PUCK_RADIUS) - 6, size: 10, color: "#ffd36b" });

        // My paddle: predicted pose; ghost at raw server pos.
        drawGhostSquare(g, v, me.x, me.y, PADDLE_RADIUS, "rgba(216,226,240,0.4)");
        drawCircle(g, v, pose.px, pose.py, PADDLE_RADIUS, { fill: hueColor(me.hue, 1), stroke: "#fff", lineWidth: 1 });

        if (sim.reconcileSeq !== lastReconcileSeq) {
          lastReconcileSeq = sim.reconcileSeq;
          lastCorr = sim.lastCorrectionMag;
        }
        corrSpark.push(lastCorr);
        pendingRow.set(String(sim.pendingCount));
        puckGapRow.set(`${Math.hypot(pose.kx - sp.x, pose.ky - sp.y).toFixed(1)} u`);
        kb.drainEdges();
      },
      unmount() {
        sim.dispose();
        predict.dispose();
        kb.dispose();
      },
      onReconnect() {
        sim.reset();
        puckTrail.clear();
      },
      debug() {
        const pose = sim.pose();
        return {
          pending: sim.pendingCount,
          lastCorrectionMag: sim.lastCorrectionMag,
          driftEma: sim.drift.ema,
          puckX: pose.kx, puckY: pose.ky,
          serverPuckX: room.state.puck.x,
          paddleX: pose.px, paddleY: pose.py,
          botEnabled: room.state.botEnabled,
        };
      },
    };
  },
};
