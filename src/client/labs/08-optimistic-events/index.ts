import docs from "./docs.md?raw";
import source from "./net.ts?raw";
import { connect, makeReconciler } from "./net.ts";
import type { LabDescriptor, LabContext, LabInstance } from "../../framework/lab.ts";
import { waitFor } from "../../framework/lab.ts";
import { Keyboard } from "../../framework/input.ts";
import { drawSquare, drawGhostSquare, drawLabel, hueColor } from "../../framework/draw.ts";
import { PLAYER_HALF } from "../../../shared/constants.ts";
import { GOAL_ZONE } from "../../../shared/goal.ts";

interface EventRecord {
  predictedAt: number;
  settledAt?: number;
  outcome?: "confirmed" | "rejected";
}

export const lab: LabDescriptor = {
  id: "08-optimistic-events",
  num: 8,
  title: "Optimistic Events",
  blurb: "Instant feedback; confirm or reject.",
  phase: 2,
  docs,
  source,

  async mount(ctx: LabContext): Promise<LabInstance> {
    const records: EventRecord[] = [];
    let banner: { text: string; color: string; t: number } | null = null;

    const { room, predict, goals, input } = await connect(ctx.client, {
      onPredict: () => {
        records.push({ predictedAt: performance.now() });
        if (records.length > 30) records.shift();
        banner = { text: "GOAL!", color: "#7be08a", t: performance.now() };
      },
      onReject: () => {
        const rec = records.find((r) => !r.outcome);
        if (rec) { rec.outcome = "rejected"; rec.settledAt = performance.now(); }
        banner = { text: "DENIED", color: "#ff6688", t: performance.now() };
      },
    });
    const me = await waitFor(() => room.state.players.get(room.sessionId));
    const recon = makeReconciler(predict, me, input, goals);

    // Confirmations ride the same broadcast that calls goals.confirm() —
    // record the settle here (net.ts owns the confirm call itself).
    const offGoal = room.onMessage("goal", (msg: any) => {
      if (msg.sid !== room.sessionId) return;
      const rec = records.find((r) => !r.outcome);
      if (rec) { rec.outcome = "confirmed"; rec.settledAt = performance.now(); }
    });

    const kb = new Keyboard();

    ctx.controls.slider({
      label: "Server deny rate (room-wide)",
      min: 0, max: 100, step: 10, value: room.state.denyRate, unit: " %",
      onChange: (v) => room.send("denyRate", { rate: v }),
      note: "Manufactures rejections: the banner goes up instantly, then retracts when the server stays silent.",
    });
    ctx.controls.note("Run into the goal zone on the right. The banner is optimistic — score is authoritative.");

    const scoreRow = ctx.hud.row("score (authoritative)");
    const predictedRow = ctx.hud.row("events predicted");
    const confirmedRow = ctx.hud.row("confirmed (avg Δ)");
    const rejectedRow = ctx.hud.row("rejected");
    const logRows = Array.from({ length: 5 }, (_, i) => ctx.hud.row(`event ${i + 1}`));

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

        const g = ctx.g, v = ctx.view;

        // Goal zone.
        g.save();
        g.fillStyle = "rgba(123, 224, 138, 0.12)";
        g.strokeStyle = "rgba(123, 224, 138, 0.5)";
        g.lineWidth = 1.5;
        g.fillRect(v.sx(GOAL_ZONE.x), v.sy(GOAL_ZONE.y), v.s(GOAL_ZONE.w), v.s(GOAL_ZONE.h));
        g.strokeRect(v.sx(GOAL_ZONE.x), v.sy(GOAL_ZONE.y), v.s(GOAL_ZONE.w), v.s(GOAL_ZONE.h));
        g.restore();
        drawLabel(g, v, GOAL_ZONE.x + GOAL_ZONE.w / 2, GOAL_ZONE.y - 2, "GOAL", { color: "rgba(123,224,138,0.7)", size: 10 });

        for (const [sid, p] of room.state.players) {
          if (sid === room.sessionId) continue;
          drawSquare(g, v, predict.value(p, "x"), predict.value(p, "y"), PLAYER_HALF, {
            fill: hueColor(p.hue, 0.4),
          });
        }
        drawGhostSquare(g, v, me.x, me.y, PLAYER_HALF, "rgba(216,226,240,0.4)");
        drawSquare(g, v, recon.value("x"), recon.value("y"), PLAYER_HALF, {
          fill: hueColor(me.hue, 1), stroke: "#fff", lineWidth: 1,
        });

        // Banner.
        if (banner && now - banner.t < 1400) {
          const a = Math.min(1, 3 * (1 - (now - banner.t) / 1400));
          g.save();
          g.globalAlpha = a;
          g.fillStyle = banner.color;
          g.font = "700 42px -apple-system, system-ui, sans-serif";
          g.textAlign = "center";
          g.fillText(banner.text, ctx.view.width / 2, 90);
          g.restore();
        }

        // HUD.
        scoreRow.set(String(me.score));
        const confirmed = records.filter((r) => r.outcome === "confirmed");
        const rejected = records.filter((r) => r.outcome === "rejected");
        predictedRow.set(String(records.length));
        const avg = confirmed.length
          ? confirmed.reduce((s, r) => s + (r.settledAt! - r.predictedAt), 0) / confirmed.length
          : NaN;
        confirmedRow.set(confirmed.length ? `${confirmed.length} (${avg.toFixed(0)} ms)` : "0", "good");
        rejectedRow.set(String(rejected.length), rejected.length ? "bad" : "");
        const recent = records.slice(-5).reverse();
        for (let i = 0; i < logRows.length; i++) {
          const r = recent[i];
          if (!r) { logRows[i].set("—"); continue; }
          if (!r.outcome) logRows[i].set("pending…", "warn");
          else logRows[i].set(`${r.outcome} +${(r.settledAt! - r.predictedAt).toFixed(0)} ms`,
            r.outcome === "confirmed" ? "good" : "bad");
        }
        kb.drainEdges();
      },
      unmount() {
        offGoal();
        recon.dispose();
        predict.dispose();
        kb.dispose();
      },
      onReconnect() {
        recon.reset();
      },
      debug() {
        return {
          score: me.score,
          predicted: records.length,
          confirmed: records.filter((r) => r.outcome === "confirmed").length,
          rejected: records.filter((r) => r.outcome === "rejected").length,
          pending: records.filter((r) => !r.outcome).length,
          scoreTicks: recon.state.scoreTicks,
        };
      },
    };
  },
};
