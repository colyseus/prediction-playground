import docs from "./docs.md?raw";
import source from "./net.ts?raw";
import { connect } from "./net.ts";
import type { LabDescriptor, LabContext, LabInstance } from "../../framework/lab.ts";
import { waitFor } from "../../framework/lab.ts";
import { Keyboard } from "../../framework/input.ts";
import { FixedStepPacer } from "../../framework/pacer.ts";
import { Trail } from "../../framework/trail.ts";
import { drawSquare, hueColor, drawLabel } from "../../framework/draw.ts";
import { TICK_HZ, PLAYER_HALF } from "../../../shared/constants.ts";

type Strategy = "raw" | "damped";

export const lab: LabDescriptor = {
  id: "01-feel-the-lag",
  num: 1,
  title: "Feel the Lag",
  blurb: "No prediction: every key press waits a full round trip.",
  phase: 1,
  docs,
  source,

  async mount(ctx: LabContext): Promise<LabInstance> {
    const { room, input } = await connect(ctx.client);
    const me = await waitFor(() => room.state.players.get(room.sessionId));

    const kb = new Keyboard();
    const pacer = new FixedStepPacer(1000 / TICK_HZ);
    const trail = new Trail(150);

    let strategy: Strategy = "raw";
    let damping = 12;
    // Damped render state per player (client-side smoothing only — no netcode).
    const damped = new Map<string, { x: number; y: number }>();

    ctx.controls.radio<Strategy | "predicted">({
      label: "Render strategy",
      value: "raw",
      options: [
        { value: "raw", label: "raw" },
        { value: "damped", label: "damped" },
        { value: "predicted", label: "predicted", disabled: true, title: "→ Lab 03" },
      ],
      onChange: (v) => { if (v !== "predicted") { strategy = v; trail.clear(); } },
      note: "raw = decoded server state verbatim. damped = smooth toward it (even laggier). predicted = Lab 03.",
    });
    ctx.controls.slider({
      label: "Damping",
      min: 4, max: 30, value: damping, unit: "/s",
      onChange: (v) => { damping = v; },
    });
    ctx.controls.note("Drive with WASD / arrows. Raise the latency slider in the Colyseus debug panel (logo, top right) and feel the difference.");

    const meterRow = ctx.hud.row("input → motion");
    const stateRow = ctx.hud.row("meter state");

    // Input-to-photon meter: arm on a key press while at rest; measure when the
    // RENDERED position first moves.
    let phase: "idle" | "armed" | "shown" = "idle";
    let armT = 0, armX = 0, armY = 0;

    return {
      room,
      frame(now: number) {
        // Send exactly one input per fixed server tick (no reconciler here, so
        // a local accumulator paces the sends).
        const steps = pacer.steps(now);
        const d = input.data;
        for (let i = 0; i < steps; i++) {
          d.moveX = kb.moveX();
          d.moveY = kb.moveY();
          input.send();
        }

        const g = ctx.g, v = ctx.view;
        const dtClamped = Math.min(0.1, Math.max(0.001, 16 / 1000));

        for (const [sid, p] of room.state.players) {
          const isMe = sid === room.sessionId;
          let dm = damped.get(sid);
          if (!dm) { dm = { x: p.x, y: p.y }; damped.set(sid, dm); }
          const k = 1 - Math.exp(-damping * dtClamped);
          dm.x += (p.x - dm.x) * k;
          dm.y += (p.y - dm.y) * k;

          const rx = strategy === "raw" ? p.x : dm.x;
          const ry = strategy === "raw" ? p.y : dm.y;

          if (isMe) {
            trail.push(rx, ry);
            trail.draw(g, v, hueColor(p.hue, 1), 1.5, 0.45);
          }
          drawSquare(g, v, rx, ry, PLAYER_HALF, {
            fill: hueColor(p.hue, isMe ? 1 : 0.45),
            stroke: isMe ? "#fff" : undefined,
            lineWidth: 1,
          });
          if (isMe) drawLabel(g, v, rx, ry, "you", { dy: -v.s(PLAYER_HALF) - 6 });
        }
        for (const sid of damped.keys()) if (!room.state.players.has(sid)) damped.delete(sid);

        // --- input→motion meter -------------------------------------------------
        const speed = Math.abs(me.vx) + Math.abs(me.vy);
        if (phase !== "armed" && kb.anyMove && speed < 0.01) {
          phase = "armed"; armT = now; armX = me.x; armY = me.y;
          stateRow.set("armed…", "warn");
        } else if (phase === "armed") {
          if (Math.abs(me.x - armX) > 0.03 || Math.abs(me.y - armY) > 0.03) {
            meterRow.set(`${(now - armT).toFixed(0)} ms`, "bad");
            phase = "shown";
            stateRow.set("measured", "good");
          } else if (!kb.anyMove && now - armT > 2000) {
            phase = "idle"; stateRow.set("idle");
          }
        } else if (phase === "shown" && !kb.anyMove && speed < 0.01) {
          phase = "idle";
          stateRow.set("idle — press a key to measure");
        }

        kb.drainEdges();
      },
      unmount() {
        kb.dispose();
      },
    };
  },
};
