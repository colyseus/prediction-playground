import docs from "./docs.md?raw";
import source from "./net.ts?raw";
import { connect, makeReconciler, type WysiwygFlags } from "./net.ts";
import type { LabDescriptor, LabContext, LabInstance } from "../../framework/lab.ts";
import { waitFor } from "../../framework/lab.ts";
import { Keyboard } from "../../framework/input.ts";
import { drawSquare, drawCircle, drawGhostSquare, drawLabel, hueColor } from "../../framework/draw.ts";
import { PLAYER_HALF, BOT_RADIUS } from "../../../shared/constants.ts";

export const lab: LabDescriptor = {
  id: "07-wysiwyg",
  num: 7,
  title: "WYSIWYG Collision",
  blurb: "valueAt(reckonTime) + ctx.memo.",
  phase: 2,
  docs,
  source,

  async mount(ctx: LabContext): Promise<LabInstance> {
    const { room, predict, input } = await connect(ctx.client);
    const me = await waitFor(() => room.state.players.get(room.sessionId));
    const bot = await waitFor(() => room.state.bots.get("bot1"));

    const flags: WysiwygFlags = { useValueAt: true, useMemo: true };
    let bumpsPredicted = 0;
    let lastBumpAt = -Infinity;
    let bumpFlashT = -Infinity;
    let mispredicts = 0;
    let lastReconcileSeq = 0;

    const kb = new Keyboard();
    let recon = makeReconciler(predict, room as any, me, input, flags, () => {
      bumpsPredicted++;
      lastBumpAt = performance.now();
      bumpFlashT = lastBumpAt;
    });
    const rebuild = () => {
      recon.dispose();
      lastReconcileSeq = 0;
      recon = makeReconciler(predict, room as any, me, input, flags, () => {
        bumpsPredicted++;
        lastBumpAt = performance.now();
        bumpFlashT = lastBumpAt;
      });
    };

    ctx.controls.toggle({
      label: "Read bot at ctx.reckonTime (valueAt)",
      value: true,
      onChange: (v) => { flags.useValueAt = v; rebuild(); },
      note: "OFF = test against the raw stale snapshot — ~RTT/2 behind where the server tests.",
    });
    ctx.controls.toggle({
      label: "Freeze verdict with ctx.memo",
      value: true,
      onChange: (v) => { flags.useMemo = v; rebuild(); },
      note: "OFF = replays re-derive the verdict against newer bot data and flip knife-edge calls.",
    });
    ctx.controls.note("Add 150+ ms sim latency and graze the bot's patrol path repeatedly. Both toggles OFF at once is maximally wrong.");

    const bumpsRow = ctx.hud.row("bumps predicted");
    const misRow = ctx.hud.row("mispredicts (corrections ≤500ms after a bump)");
    const rateRow = ctx.hud.row("mispredict rate");
    const gateRow = ctx.hud.row("bump immunity (ticks)");

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

        // Attribute LARGE corrections near a predicted bump to a flipped
        // verdict. Small post-bump corrections (< ~2u) are knockback-direction
        // epsilon (the two sides read the bot a hair apart near patrol
        // bounces); a genuinely flipped verdict diverges by many units — the
        // 48 u/s shove either happened or it didn't.
        if (recon.reconcileSeq !== lastReconcileSeq) {
          lastReconcileSeq = recon.reconcileSeq;
          if (recon.lastCorrectionMag > 3 && now - lastBumpAt < 700) mispredicts++;
        }

        const g = ctx.g, v = ctx.view;

        for (const [sid, p] of room.state.players) {
          if (sid === room.sessionId) continue;
          drawSquare(g, v, predict.value(p, "x"), predict.value(p, "y"), PLAYER_HALF, {
            fill: hueColor(p.hue, 0.4),
          });
        }

        // The bot: reckon display (what you touch) + its hit-test ghost at the
        // NEXT input's reckon instant (≈ the same thing — they overlap; the
        // stale snapshot is drawn dashed so the "wrong read" is visible).
        const bx = predict.value(bot, "x"), by = predict.value(bot, "y");
        drawCircle(g, v, bx, by, BOT_RADIUS, { fill: "rgba(255,180,84,0.3)", stroke: "#ffb454", lineWidth: 2 });
        drawLabel(g, v, bx, by, "bot (reckon = hit position)", { dy: -v.s(BOT_RADIUS) - 6, color: "#ffb454", size: 10 });
        drawCircle(g, v, bot.x, bot.y, BOT_RADIUS, { stroke: "rgba(216,226,240,0.45)", dash: [3, 3], lineWidth: 1 });
        drawLabel(g, v, bot.x, bot.y, "stale snapshot", { dy: v.s(BOT_RADIUS) + 12, color: "rgba(216,226,240,0.45)", size: 9 });

        // Ghost + own square.
        drawGhostSquare(g, v, me.x, me.y, PLAYER_HALF, "rgba(216,226,240,0.5)");
        const flash = now - bumpFlashT < 300;
        drawSquare(g, v, recon.value("x"), recon.value("y"), PLAYER_HALF, {
          fill: flash ? "#ff6688" : hueColor(me.hue, 1),
          stroke: "#fff",
          lineWidth: flash ? 2.5 : 1,
        });

        bumpsRow.set(String(bumpsPredicted));
        misRow.set(String(mispredicts), mispredicts > 0 ? "warn" : "good");
        const rate = bumpsPredicted ? (mispredicts / bumpsPredicted) * 100 : 0;
        rateRow.set(bumpsPredicted ? `${rate.toFixed(0)} %` : "—", rate < 10 ? "good" : rate < 40 ? "warn" : "bad");
        gateRow.set(String(recon.state.bumpTicks));
        kb.drainEdges();
      },
      unmount() {
        recon.dispose();
        predict.dispose();
        kb.dispose();
      },
      onReconnect() {
        recon.reset();
      },
      debug() {
        return {
          bumpsPredicted,
          mispredicts,
          driftEma: recon.drift.ema,
          serverBumps: me.bumps,
          bumpTicks: recon.state.bumpTicks,
          useValueAt: flags.useValueAt,
          useMemo: flags.useMemo,
          x: recon.state.x,
          y: recon.state.y,
          botX: predict.value(bot, "x"),
          botY: predict.value(bot, "y"),
        };
      },
    };
  },
};
