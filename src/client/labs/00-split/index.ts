import docs from "./docs.md?raw";
import source from "./net.ts?raw";
import { connect, makeReconciler } from "./net.ts";
import type { LabDescriptor, LabContext, LabInstance } from "../../framework/lab.ts";
import { waitFor } from "../../framework/lab.ts";
import { Keyboard } from "../../framework/input.ts";
import { Trail } from "../../framework/trail.ts";
import { WorldView, drawArena, drawSquare, drawLabel, hueColor } from "../../framework/draw.ts";
import { ARENA_W, ARENA_H, PLAYER_HALF } from "../../../shared/constants.ts";

// Reversal-heavy autopilot legs [dx, dy, ms] — reversals are where the echo
// lane visibly keeps going the wrong way for a full round trip.
type Tri = -1 | 0 | 1;
const SCRIPT: Array<[Tri, Tri, number]> = [
  [1, 0, 850], [-1, 0, 700], [1, 0, 550], [0, 1, 650], [0, -1, 700],
  [1, 1, 600], [-1, -1, 750], [-1, 0, 550], [1, 0, 800], [0, -1, 500],
];

export const lab: LabDescriptor = {
  id: "00-split",
  num: 0,
  title: "Lag vs Prediction",
  blurb: "Same input, same server — the top lane waits, the bottom predicts.",
  phase: 1,
  docs,
  source,
  autoExpandDocs: false,
  ownArena: true,

  async mount(ctx: LabContext): Promise<LabInstance> {
    const { room, predict, input } = await connect(ctx.client);
    const me = await waitFor(() => room.state.players.get(room.sessionId));

    // Join at the visitor's real RTT (fast cold start), THEN make the point:
    // 200 ms through the SDK's own network simulator — the panel slider
    // (top-right) reflects it, and it deliberately stays on across labs.
    (globalThis as any).__net?.(200, 20);

    const recon = makeReconciler(predict, me, input, 15);
    const kb = new Keyboard();
    const topView = new WorldView();
    const botView = new WorldView();
    const topTrail = new Trail(120);
    const botTrail = new Trail(120);

    let userDrove = false;
    let frames = 0;

    // Autopilot: scripted strides, steered back when a leg would hug a wall.
    let legIdx = 0, legUntil = 0;
    let legX: Tri = 1, legY: Tri = 0;
    function autopilot(now: number, x: number, y: number): void {
      if (now < legUntil) return;
      const [dx, dy, ms] = SCRIPT[legIdx % SCRIPT.length];
      legIdx++;
      legX = dx; legY = dy;
      if (x > ARENA_W * 0.72 && legX > 0) legX = -1;
      else if (x < ARENA_W * 0.28 && legX < 0) legX = 1;
      if (y > ARENA_H * 0.72 && legY > 0) legY = -1;
      else if (y < ARENA_H * 0.28 && legY < 0) legY = 1;
      legUntil = now + ms;
    }

    ctx.controls.radio<"0" | "200" | "400">({
      label: "Injected latency",
      value: "200",
      options: [
        { value: "0", label: "0 ms" },
        { value: "200", label: "200 ms" },
        { value: "400", label: "400 ms" },
      ],
      onChange: (v) => (globalThis as any).__net?.(Number(v), Number(v) ? 20 : 0),
      note: "A shortcut into the SDK network simulator — fine tuning lives in the Colyseus panel (top-right). The setting stays on while you explore the other labs.",
    });
    ctx.controls.buttons([
      { label: "⊞ Browse all labs", onClick: () => window.dispatchEvent(new CustomEvent("pp:open-grid")), title: "The full curriculum" },
    ]);
    ctx.controls.note("Render-only split: both lanes are the same entity in the same room. ℹ About shows the code — it is Lab 03's, verbatim.");

    const rttRow = ctx.hud.row("round trip");
    const gapRow = ctx.hud.row("echo trails you by");
    const chips = ctx.hud.chips("pending inputs (unacked)");

    const clock = (room as any).clock;

    // Titles sit INSIDE the arena — above it the topbar/Predict cards occlude.
    function laneTitle(g: CanvasRenderingContext2D, v: WorldView, main: string, sub: string, color: string): void {
      const x = v.sx(0) + 10, y = v.sy(0) + 18;
      g.save();
      g.textAlign = "left";
      g.font = "700 12px -apple-system, system-ui, sans-serif";
      g.fillStyle = color;
      g.fillText(main, x, y);
      const mw = g.measureText(main).width;
      g.font = "11px -apple-system, system-ui, sans-serif";
      g.fillStyle = "rgba(138,160,192,0.75)";
      g.fillText(sub, x + mw + 12, y);
      g.restore();
    }

    return {
      room,
      frame(now: number) {
        frames++;
        const steps = predict.tick(now);

        if (!userDrove && kb.anyMove) userDrove = true;
        if (!userDrove) autopilot(now, recon.state.x, recon.state.y);

        const d = input.data;
        for (let i = 0; i < steps; i++) {
          d.moveX = userDrove ? kb.moveX() : legX;
          d.moveY = userDrove ? kb.moveY() : legY;
          input.send();
        }

        const g = ctx.g;
        const cssW = ctx.canvas.clientWidth, cssH = ctx.canvas.clientHeight;
        const laneH = cssH / 2;
        const lanePad = 26; // clears the floating topbar above / caption+strip below
        topView.fit(cssW, laneH - lanePad, 34);
        botView.fit(cssW, laneH - lanePad, 34);

        const px = recon.value("x"), py = recon.value("y");

        // ---- Top lane: raw server echo (Lab 01's rendering) ----
        g.save();
        g.translate(0, lanePad);
        drawArena(g, topView);
        laneTitle(g, topView, "SERVER ECHO", "every move waits the full round trip", "rgba(216,226,240,0.85)");
        for (const [sid, p] of room.state.players) {
          if (sid === room.sessionId) continue;
          drawSquare(g, topView, p.x, p.y, PLAYER_HALF, { fill: hueColor(p.hue, 0.4) });
        }
        topTrail.push(me.x, me.y);
        topTrail.draw(g, topView, "rgba(216,226,240,0.8)", 1.5, 0.35);
        drawSquare(g, topView, me.x, me.y, PLAYER_HALF, { fill: hueColor(me.hue, 0.8), stroke: "rgba(255,255,255,0.5)", lineWidth: 1 });
        drawLabel(g, topView, me.x, me.y, "you (server)", { dy: -topView.s(PLAYER_HALF) - 6, color: "rgba(216,226,240,0.6)" });
        g.restore();

        // ---- Bottom lane: predicted (Lab 03's rendering) ----
        g.save();
        g.translate(0, laneH);
        drawArena(g, botView);
        laneTitle(g, botView, "PREDICTED", "instant — reconciled against the same server", "#7be08a");
        for (const [sid, p] of room.state.players) {
          if (sid === room.sessionId) continue;
          drawSquare(g, botView, predict.value(p, "x"), predict.value(p, "y"), PLAYER_HALF, { fill: hueColor(p.hue, 0.4) });
        }
        botTrail.push(px, py);
        botTrail.draw(g, botView, hueColor(me.hue, 1), 1.5, 0.45);
        drawSquare(g, botView, px, py, PLAYER_HALF, { fill: hueColor(me.hue, 1), stroke: "#fff", lineWidth: 1 });
        drawLabel(g, botView, px, py, "you (predicted)", { dy: -botView.s(PLAYER_HALF) - 6 });
        g.restore();

        // ---- Divider readout ----
        const rtt = clock?.smoothedRtt?.() ?? 0;
        const readout = `ROUND TRIP ≈ ${rtt.toFixed(0)} ms`;
        g.save();
        g.font = "700 13px -apple-system, system-ui, sans-serif";
        const tw = g.measureText(readout).width;
        g.strokeStyle = "rgba(138,160,192,0.25)";
        g.lineWidth = 1;
        g.beginPath();
        g.moveTo(24, laneH); g.lineTo(cssW / 2 - tw / 2 - 18, laneH);
        g.moveTo(cssW / 2 + tw / 2 + 18, laneH); g.lineTo(cssW - 24, laneH);
        g.stroke();
        g.textAlign = "center";
        g.fillStyle = "#ffd36b";
        g.fillText(readout, cssW / 2, laneH + 4.5);
        g.restore();

        // ---- Caption (above the lab strip) ----
        g.save();
        g.textAlign = "center";
        g.font = "12px -apple-system, system-ui, sans-serif";
        g.fillStyle = "rgba(138,160,192,0.85)";
        g.fillText(
          userDrove
            ? "Same keys, same server — the top lane waits, the bottom predicts."
            : "▶ autopilot — press WASD / arrows (or drag) to take over",
          cssW / 2, cssH - 52,
        );
        g.restore();

        // ---- HUD ----
        rttRow.set(`${rtt.toFixed(0)} ms`, rtt > 300 ? "bad" : rtt > 120 ? "warn" : "good");
        const gap = Math.sqrt((px - me.x) ** 2 + (py - me.y) ** 2);
        gapRow.set(`${gap.toFixed(1)} units`);
        chips.set(recon.pendingCount);

        kb.drainEdges();
      },
      unmount() {
        recon.dispose();
        predict.dispose();
        kb.dispose();
      },
      onReconnect() {
        recon.reset();
        topTrail.clear();
        botTrail.clear();
      },
      debug() {
        return {
          frames,
          autopilot: !userDrove,
          rtt: clock?.smoothedRtt?.() ?? 0,
          pending: recon.pendingCount,
          predictedX: recon.state.x,
          predictedY: recon.state.y,
          serverX: me.x,
          serverY: me.y,
        };
      },
    };
  },
};
