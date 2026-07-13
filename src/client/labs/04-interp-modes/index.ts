import docs from "./docs.md?raw";
import source from "./net.ts?raw";
import { connect, makeOverlay, type OverlayMode } from "./net.ts";
import type { LabDescriptor, LabContext, LabInstance } from "../../framework/lab.ts";
import { waitFor } from "../../framework/lab.ts";
import { Keyboard } from "../../framework/input.ts";
import { FixedStepPacer } from "../../framework/pacer.ts";
import { drawSquare, drawCircle, hueColor, drawLabel } from "../../framework/draw.ts";
import { TICK_HZ, PLAYER_HALF, BOT_RADIUS } from "../../../shared/constants.ts";

const MODES: Array<{ mode: OverlayMode; color: string; opts: { delay?: number; damping?: number; maxExtrapolate?: number } }> = [
  { mode: "raw", color: "#d8e2f0", opts: {} },
  { mode: "lerp", color: "#6db3ff", opts: { delay: 100 } },
  { mode: "damped", color: "#7be08a", opts: { damping: 12 } },
  { mode: "extrapolate", color: "#ffb454", opts: { maxExtrapolate: 250 } },
];

const STRIP_SPAN_MS = 2500;
const TRACE_CAP = 400;

/** Per-mode rendered-value trace + received-sample ring for the timeline strip. */
class Series {
  t = new Float64Array(TRACE_CAP);
  v = new Float64Array(TRACE_CAP);
  head = 0; count = 0;
  push(t: number, v: number) {
    this.t[this.head] = t; this.v[this.head] = v;
    this.head = (this.head + 1) % TRACE_CAP;
    if (this.count < TRACE_CAP) this.count++;
  }
  *points(): Generator<[number, number]> {
    const start = (this.head - this.count + TRACE_CAP * 2) % TRACE_CAP;
    for (let i = 0; i < this.count; i++) {
      const idx = (start + i) % TRACE_CAP;
      yield [this.t[idx], this.v[idx]];
    }
  }
}

/** Coefficient of variation of rendered per-frame speed — the "limp" metric. */
class Smoothness {
  private speeds: number[] = [];
  private lastX = NaN; private lastY = NaN;
  sample(x: number, y: number, dtMs: number): void {
    if (!Number.isNaN(this.lastX) && dtMs > 0) {
      this.speeds.push(Math.hypot(x - this.lastX, y - this.lastY) / dtMs * 1000);
      if (this.speeds.length > 120) this.speeds.shift();
    }
    this.lastX = x; this.lastY = y;
  }
  cv(): number {
    const n = this.speeds.length;
    if (n < 20) return NaN;
    let mean = 0;
    for (const s of this.speeds) mean += s;
    mean /= n;
    if (mean < 0.5) return NaN; // standing still — CV is meaningless
    let varSum = 0;
    for (const s of this.speeds) varSum += (s - mean) ** 2;
    return Math.sqrt(varSum / n) / mean;
  }
}

export const lab: LabDescriptor = {
  id: "04-interp-modes",
  num: 4,
  title: "Remote Interpolation",
  blurb: "lerp / damped / extrapolate / raw, side by side.",
  phase: 1,
  docs,
  source,

  async mount(ctx: LabContext): Promise<LabInstance> {
    const { room, input } = await connect(ctx.client);
    const bot = await waitFor(() => room.state.bots.get("bot1"));
    const me = await waitFor(() => room.state.players.get(room.sessionId));

    const overlays = MODES.map((m) => ({
      ...m,
      overlay: makeOverlay(room, m.mode, { ...m.opts }),
      visible: true,
      trace: new Series(),
      smooth: new Smoothness(),
      cvRow: ctx.hud.row(`${m.mode} smoothness CV`),
    }));

    const kb = new Keyboard();
    const pacer = new FixedStepPacer(1000 / TICK_HZ);
    const samples = new Series();
    let lastRawX = NaN, lastRawY = NaN;
    let cvUpdateAt = 0;

    ctx.controls.radio<string>({
      label: "Bot pattern (room-wide)",
      value: "patrol",
      options: [
        { value: "patrol", label: "patrol" },
        { value: "circle", label: "circle" },
        { value: "wander", label: "wander" },
      ],
      onChange: (kind) => room.send("pattern", { kind }),
    });
    for (const o of overlays) {
      ctx.controls.toggle({
        label: `show ${o.mode}`,
        value: true,
        onChange: (v) => { o.visible = v; },
      });
    }
    ctx.controls.note("Tune each mode in ITS OWN Predict card (top left): lerp's delay, damped's damping, extrapolate's cap — all live, per mode. This panel only picks what the server does and what's drawn.");
    ctx.controls.note("WASD drives your own square (rendered raw). The strip below plots the bot's x: white dots = received samples, colored traces = what each mode rendered.");

    return {
      room,
      frame(now: number, dtMs: number) {
        const steps = pacer.steps(now);
        const d = input.data;
        for (let i = 0; i < steps; i++) {
          d.moveX = kb.moveX();
          d.moveY = kb.moveY();
          input.send();
        }
        for (const o of overlays) o.overlay.predict.tick(now);

        const g = ctx.g, v = ctx.view;
        const clock = (room as any).clock;
        const sNow = clock.serverNow();

        // Record received samples (the raw decoded value changes on each patch).
        if (bot.x !== lastRawX || bot.y !== lastRawY) {
          lastRawX = bot.x; lastRawY = bot.y;
          samples.push(clock.lastServerTime(), bot.x);
        }

        // Players (raw, dim — not the subject here).
        for (const [sid, p] of room.state.players) {
          drawSquare(g, v, p.x, p.y, PLAYER_HALF, {
            fill: hueColor(p.hue, sid === room.sessionId ? 0.9 : 0.4),
          });
        }

        // The bot, once per visible mode.
        for (const o of overlays) {
          const x = o.overlay.predict.value(bot, "x");
          const y = o.overlay.predict.value(bot, "y");
          o.trace.push(sNow, x);
          o.smooth.sample(x, y, dtMs);
          if (!o.visible) continue;
          if (o.mode === "raw") {
            drawCircle(g, v, x, y, BOT_RADIUS, { stroke: o.color, dash: [4, 3], lineWidth: 1.5 });
          } else {
            drawCircle(g, v, x, y, BOT_RADIUS, { stroke: o.color, lineWidth: 2, alpha: 0.95 });
          }
          drawLabel(g, v, x, y, o.mode, { dy: -v.s(BOT_RADIUS) - 5, color: o.color, size: 10 });
        }

        drawStrip(g, ctx, samples, overlays, sNow, clock.lastServerTime());

        if (now > cvUpdateAt) {
          cvUpdateAt = now + 500;
          for (const o of overlays) {
            const cv = o.smooth.cv();
            o.cvRow.set(Number.isNaN(cv) ? "—" : `${(cv * 100).toFixed(0)} %`,
              Number.isNaN(cv) ? "" : cv < 0.15 ? "good" : cv < 0.5 ? "warn" : "bad");
          }
        }
        kb.drainEdges();
      },
      unmount() {
        for (const o of overlays) o.overlay.dispose();
        kb.dispose();
      },
      debug() {
        const out: Record<string, unknown> = { sampleCount: samples.count };
        for (const o of overlays) {
          out[`${o.mode}X`] = o.overlay.predict.value(bot, "x");
          out[`${o.mode}CV`] = o.smooth.cv();
        }
        out.rawX = bot.x;
        return out;
      },
    };
  },
};

/** The buffer-timeline strip: received samples vs per-mode rendered traces. */
function drawStrip(
  g: CanvasRenderingContext2D,
  ctx: LabContext,
  samples: Series,
  overlays: Array<{ mode: string; color: string; visible: boolean; trace: Series }>,
  sNow: number,
  lastPatch: number,
): void {
  const W = ctx.view.width, H = ctx.view.height;
  const h = 120, pad = 10;
  const x0 = 24, x1 = W - 16, y0 = H - h - 12, y1 = H - 12;
  if (x1 - x0 < 200) return;

  g.save();
  g.fillStyle = "rgba(14, 22, 38, 0.88)";
  g.strokeStyle = "#24304a";
  g.beginPath();
  (g as any).roundRect ? (g as any).roundRect(x0, y0, x1 - x0, y1 - y0, 8) : g.rect(x0, y0, x1 - x0, y1 - y0);
  g.fill();
  g.stroke();

  const tMin = sNow - STRIP_SPAN_MS, tMax = sNow + 150;
  const tx = (t: number) => x0 + pad + ((t - tMin) / (tMax - tMin)) * (x1 - x0 - pad * 2);
  // Value axis: bot x spans ~[20,80]; leave headroom for extrapolation overshoot.
  const vMin = 12, vMax = 88;
  const ty = (val: number) => y1 - pad - ((val - vMin) / (vMax - vMin)) * (h - pad * 2 - 14);

  // Time cursors: newest patch + server-now.
  g.strokeStyle = "rgba(216,226,240,0.25)";
  g.setLineDash([3, 3]);
  for (const [t, label] of [[lastPatch, "newest patch"], [sNow, "now"]] as Array<[number, string]>) {
    const x = tx(t);
    if (x < x0 || x > x1) continue;
    g.beginPath(); g.moveTo(x, y0 + 4); g.lineTo(x, y1 - 4); g.stroke();
    g.fillStyle = "rgba(216,226,240,0.5)";
    g.font = "9px system-ui, sans-serif";
    g.textAlign = "center";
    g.fillText(label, x, y0 + 12);
  }
  g.setLineDash([]);

  // Received samples (white dots).
  g.fillStyle = "rgba(255,255,255,0.85)";
  for (const [t, val] of samples.points()) {
    if (t < tMin || t > tMax) continue;
    g.beginPath();
    g.arc(tx(t), ty(val), 1.6, 0, Math.PI * 2);
    g.fill();
  }

  // Per-mode rendered traces.
  for (const o of overlays) {
    if (!o.visible || o.mode === "raw") continue;
    g.strokeStyle = o.color;
    g.globalAlpha = 0.9;
    g.lineWidth = 1.2;
    g.beginPath();
    let started = false;
    for (const [t, val] of o.trace.points()) {
      if (t < tMin || t > tMax) continue;
      const x = tx(t), y = ty(val);
      if (!started) { g.moveTo(x, y); started = true; } else g.lineTo(x, y);
    }
    g.stroke();
    g.globalAlpha = 1;
  }
  g.restore();
}
