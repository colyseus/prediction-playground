import docs from "./docs.md?raw";
import source from "./net.ts?raw";
import { connect, makeReconciler } from "./net.ts";
import { classifyDrift } from "@colyseus/sdk/predict";
import type { LabDescriptor, LabContext, LabInstance } from "../../framework/lab.ts";
import { waitFor } from "../../framework/lab.ts";
import { Keyboard } from "../../framework/input.ts";
import { Trail } from "../../framework/trail.ts";
import { drawSquare, drawGhostSquare, drawArrow, drawLabel, hueColor } from "../../framework/draw.ts";
import { PLAYER_HALF, TELEPORT_SNAP_DIST } from "../../../shared/constants.ts";

interface CorrectionArrow { x0: number; y0: number; x1: number; y1: number; t: number; }

export const lab: LabDescriptor = {
  id: "03-reconcile",
  num: 3,
  title: "Predict & Reconcile",
  blurb: "Rollback to the ack, replay pending inputs, smooth the error.",
  phase: 1,
  docs,
  source,

  async mount(ctx: LabContext): Promise<LabInstance> {
    const { room, predict, input } = await connect(ctx.client);
    const me = await waitFor(() => room.state.players.get(room.sessionId));

    const kb = new Keyboard();
    const predictedTrail = new Trail(150);
    const serverTrail = new Trail(150);
    const arrows: CorrectionArrow[] = [];

    let smoothMs = 65;
    let recon = makeReconciler(predict, me, input, smoothMs);
    let renderSmoothed = true;
    let showGhost = true;
    let autoSnap = true;
    let lastReconcileSeq = 0;
    // Monotonic counters for probes: lastCorrectionMag is overwritten by the
    // next clean reconcile (~every patch), so a poller would miss the spike.
    let corrections = 0;
    let maxCorrMag = 0;
    let frames = 0;
    let stepsTotal = 0;

    ctx.controls.buttons([
      { label: "⚡ Force mispredict", onClick: () => room.send("impulse"), title: "Server-side shove the client can't predict" },
      { label: "⤳ Teleport", onClick: () => room.send("teleport"), title: "Discontinuity: mirror across the arena" },
    ], "Scenarios");
    ctx.controls.slider({
      label: "Correction smoothing",
      min: 0, max: 200, value: smoothMs, unit: " ms",
      onCommit: true,
      onChange: (v) => {
        smoothMs = v;
        recon.dispose();
        recon = makeReconciler(predict, me, input, smoothMs);
        lastReconcileSeq = 0;
      },
      note: "0 = corrections snap instantly. Higher = the error lingers longer (fades ~63% per smoothMs).",
    });
    ctx.controls.radio<"value" | "state">({
      label: "Render the local square from",
      value: "value",
      options: [
        { value: "value", label: "value() smoothed" },
        { value: "state", label: "state (exact)" },
      ],
      onChange: (v) => { renderSmoothed = v === "value"; },
    });
    ctx.controls.toggle({
      label: "Show server ghost",
      value: showGhost,
      onChange: (v) => { showGhost = v; },
    });
    ctx.controls.toggle({
      label: "Snap on teleport-size corrections",
      value: autoSnap,
      onChange: (v) => { autoSnap = v; },
      note: `Corrections beyond ${TELEPORT_SNAP_DIST}u call recon.reset() — a cut, not a cross-arena glide. Turn it off and teleport to see why.`,
    });

    const chips = ctx.hud.chips("pending inputs (unacked)");
    const statusRow = ctx.hud.row("drift status");
    const driftSpark = ctx.hud.spark("drift ema", { format: (v) => v.toFixed(4) });
    const corrRow = ctx.hud.row("last correction");
    const reconciles = ctx.hud.row("reconciles");

    return {
      room,
      frame(now: number) {
        // 1. Drive the whole prediction stack; returns due fixed steps.
        const steps = predict.tick(now);
        frames++;
        stepsTotal += steps;

        // 2. One input per step — mutate the handle, send; the reconciler
        //    observes each send and predicts it immediately.
        const d = input.data;
        for (let i = 0; i < steps; i++) {
          d.moveX = kb.moveX();
          d.moveY = kb.moveY();
          input.send();
        }

        // 3. Reconcile telemetry (a fresh reconcile bumps reconcileSeq).
        if (recon.reconcileSeq !== lastReconcileSeq) {
          lastReconcileSeq = recon.reconcileSeq;
          const mag = recon.lastCorrectionMag;
          if (mag > 0.02) {
            corrections++;
            if (mag > maxCorrMag) maxCorrMag = mag;
            const corr = recon.lastCorrection;
            const cx = corr.x ?? 0, cy = corr.y ?? 0;
            const s = recon.state;
            arrows.push({ x0: s.x - cx, y0: s.y - cy, x1: s.x, y1: s.y, t: now });
            if (arrows.length > 8) arrows.shift();
          }
          if (autoSnap && mag > TELEPORT_SNAP_DIST) {
            recon.reset();
            predictedTrail.clear();
            serverTrail.clear();
          }
        }

        const g = ctx.g, v = ctx.view;

        // Remote players (damped via Predict).
        for (const [sid, p] of room.state.players) {
          if (sid === room.sessionId) continue;
          drawSquare(g, v, predict.value(p, "x"), predict.value(p, "y"), PLAYER_HALF, {
            fill: hueColor(p.hue, 0.45),
          });
        }

        // Server ghost: the raw authoritative pose — it trails by ~RTT.
        if (showGhost) {
          serverTrail.push(me.x, me.y);
          serverTrail.draw(g, v, "rgba(216,226,240,0.5)", 1, 0.3);
          drawGhostSquare(g, v, me.x, me.y, PLAYER_HALF, "rgba(216,226,240,0.75)");
          drawLabel(g, v, me.x, me.y, "server", { dy: v.s(PLAYER_HALF) + 14, color: "rgba(216,226,240,0.55)" });
        }

        // The predicted square.
        const px = renderSmoothed ? recon.value("x") : recon.state.x;
        const py = renderSmoothed ? recon.value("y") : recon.state.y;
        predictedTrail.push(px, py);
        predictedTrail.draw(g, v, hueColor(me.hue, 1), 1.5, 0.45);
        drawSquare(g, v, px, py, PLAYER_HALF, { fill: hueColor(me.hue, 1), stroke: "#fff", lineWidth: 1 });
        drawLabel(g, v, px, py, "you (predicted)", { dy: -v.s(PLAYER_HALF) - 6 });

        // Correction arrows: fade out over 900 ms.
        for (let i = arrows.length - 1; i >= 0; i--) {
          const a = arrows[i];
          const age = now - a.t;
          if (age > 900) { arrows.splice(i, 1); continue; }
          drawArrow(g, v, a.x0, a.y0, a.x1, a.y1, "#ff6688", 2, 1 - age / 900);
        }

        // HUD.
        chips.set(recon.pendingCount);
        const status = classifyDrift(recon.drift);
        statusRow.set(status, status === "matched" ? "good" : status === "jitter" ? "warn" : "bad");
        driftSpark.push(recon.drift.ema);
        corrRow.set(recon.lastCorrectionMag.toFixed(3));
        reconciles.set(String(recon.reconcileSeq));

        kb.drainEdges();
      },
      unmount() {
        recon.dispose();
        predict.dispose();
        kb.dispose();
      },
      onReconnect() {
        // Fresh connection = fresh input counter: drop the stale prediction
        // backlog and re-seed from authoritative state.
        recon.reset();
        predictedTrail.clear();
        serverTrail.clear();
      },
      debug() {
        return {
          frames,
          stepsTotal,
          sent: (input as any).sentCount,
          acked: (input as any).lastProcessed,
          pending: recon.pendingCount,
          driftEma: recon.drift.ema,
          driftPeak: recon.drift.peak,
          status: classifyDrift(recon.drift),
          lastCorrectionMag: recon.lastCorrectionMag,
          corrections,
          maxCorrMag,
          reconcileSeq: recon.reconcileSeq,
          predictedX: recon.state.x,
          predictedY: recon.state.y,
        };
      },
    };
  },
};
