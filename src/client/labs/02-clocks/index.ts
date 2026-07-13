import docs from "./docs.md?raw";
import source from "./net.ts?raw";
import { connect } from "./net.ts";
import type { LabDescriptor, LabContext, LabInstance } from "../../framework/lab.ts";
import { waitFor } from "../../framework/lab.ts";
import { Keyboard } from "../../framework/input.ts";
import { FixedStepPacer } from "../../framework/pacer.ts";
import { drawSquare, drawCircle, hueColor, drawLabel } from "../../framework/draw.ts";
import { TICK_HZ, PLAYER_HALF, BOT_RADIUS } from "../../../shared/constants.ts";

/** Scrolling event strip: patch arrivals + input sends over the last 3 s. */
const STRIP_SPAN = 3000;

export const lab: LabDescriptor = {
  id: "02-clocks",
  num: 2,
  title: "Clocks & Timelines",
  blurb: "serverNow / renderNow / RTT / jitter.",
  phase: 1,
  docs,
  source,

  async mount(ctx: LabContext): Promise<LabInstance> {
    const { room, input } = await connect(ctx.client);
    const me = await waitFor(() => room.state.players.get(room.sessionId));
    const bot = await waitFor(() => room.state.bots.get("bot1"));

    const kb = new Keyboard();
    const pacer = new FixedStepPacer(1000 / TICK_HZ);
    const clock = (room as any).clock;

    const patchArrivals: number[] = [];   // local now() of each patch arrival
    let lastPatchStamp = 0;
    const joinedAt = performance.now();

    const rttSpark = ctx.hud.spark("rtt", { format: (v) => `${v.toFixed(0)} ms`, color: "#6db3ff" });
    const ageSpark = ctx.hud.spark("patch age (sawtooth)", { format: (v) => `${v.toFixed(0)} ms`, color: "#7be08a" });
    const slewSpark = ctx.hud.spark("serverNow − renderNow (slew)", { format: (v) => `${v.toFixed(1)} ms`, color: "#ffb454" });
    const offsetRow = ctx.hud.row("serverNow − now (offset)");
    const jitterRow = ctx.hud.row("jitter (interarrival)");
    const srttRow = ctx.hud.row("smoothed rtt");

    ctx.controls.note("Nothing to configure here — yank the latency slider in the Colyseus debug panel (top right) and watch every readout respond. The offset re-converges; the slew spike decays over ~250 ms.");
    ctx.controls.note("The dot row at the bottom marks each PATCH ARRIVAL on the local clock — add sim jitter and watch the spacing get ragged.");

    return {
      room,
      frame(now: number) {
        const steps = pacer.steps(now);
        const d = input.data;
        for (let i = 0; i < steps; i++) {
          d.moveX = kb.moveX();
          d.moveY = kb.moveY();
          input.send();
        }

        // Detect patch arrivals via the server-stamp changing.
        const stamp = clock.lastServerTime();
        if (stamp !== lastPatchStamp) {
          lastPatchStamp = stamp;
          patchArrivals.push(now);
          if (patchArrivals.length > 128) patchArrivals.shift();
        }

        const sNow = clock.serverNow();
        const rNow = clock.renderNow();

        const g = ctx.g, v = ctx.view;

        // The arena still works — drive around; the bot shows patch cadence.
        for (const [sid, p] of room.state.players) {
          drawSquare(g, v, p.x, p.y, PLAYER_HALF, {
            fill: hueColor(p.hue, sid === room.sessionId ? 0.9 : 0.4),
          });
        }
        drawCircle(g, v, bot.x, bot.y, BOT_RADIUS, { stroke: "#d8e2f0", dash: [4, 3], lineWidth: 1.5 });
        drawLabel(g, v, bot.x, bot.y, "raw snapshots (patch rate)", { dy: -v.s(BOT_RADIUS) - 6, size: 10, color: "rgba(216,226,240,0.6)" });

        // Patch-arrival strip along the bottom of the canvas.
        const W = ctx.view.width, H = ctx.view.height;
        const x0 = 24, x1 = W - 20, y = H - 40;
        if (x1 - x0 > 200) {
          g.save();
          g.strokeStyle = "rgba(138,160,192,0.3)";
          g.beginPath(); g.moveTo(x0, y); g.lineTo(x1, y); g.stroke();
          g.fillStyle = "#7be08a";
          for (const t of patchArrivals) {
            const age = now - t;
            if (age > STRIP_SPAN) continue;
            const x = x1 - (age / STRIP_SPAN) * (x1 - x0);
            g.beginPath(); g.arc(x, y, 2.5, 0, Math.PI * 2); g.fill();
          }
          g.fillStyle = "rgba(216,226,240,0.55)";
          g.font = "10px system-ui, sans-serif";
          g.textAlign = "left";
          g.fillText("patch arrivals (local clock, last 3 s) →", x0, y - 10);
          g.restore();
        }

        // HUD (throttle sparks to ~5 Hz so they read as trends, not noise).
        if ((now / 200 | 0) !== ((now - 16.7) / 200 | 0)) {
          rttSpark.push(clock.rtt());
          slewSpark.push(sNow - rNow);
        }
        ageSpark.push(Math.max(0, sNow - stamp));
        offsetRow.set(`${(sNow - now).toFixed(0)} ms`);
        jitterRow.set(`${clock.jitter().toFixed(1)} ms`);
        srttRow.set(`${clock.smoothedRtt().toFixed(0)} ms`);

        kb.drainEdges();
      },
      unmount() {
        kb.dispose();
      },
      debug() {
        return {
          rtt: clock.rtt(),
          smoothedRtt: clock.smoothedRtt(),
          jitter: clock.jitter(),
          offset: clock.serverNow() - performance.now(),
          slew: clock.serverNow() - clock.renderNow(),
          patchAge: Math.max(0, clock.serverNow() - clock.lastServerTime()),
          patchesSeen: patchArrivals.length,
          sinceJoinMs: performance.now() - joinedAt,
        };
      },
    };
  },
};
