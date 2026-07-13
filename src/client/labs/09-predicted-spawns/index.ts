import docs from "./docs.md?raw";
import source from "./net.ts?raw";
import { connect, makeReconciler, type LocalProjectile } from "./net.ts";
import type { LabDescriptor, LabContext, LabInstance } from "../../framework/lab.ts";
import { waitFor } from "../../framework/lab.ts";
import { Keyboard } from "../../framework/input.ts";
import { drawSquare, drawCircle, drawMarker, drawLabel, hueColor } from "../../framework/draw.ts";
import { PLAYER_HALF } from "../../../shared/constants.ts";
import { PROJECTILE_SPEED, PROJECTILE_RADIUS } from "../../../shared/projectile.ts";

export const lab: LabDescriptor = {
  id: "09-predicted-spawns",
  num: 9,
  title: "Predicted Spawns",
  blurb: "Optimistic projectile → authoritative handoff.",
  phase: 2,
  docs,
  source,

  async mount(ctx: LabContext): Promise<LabInstance> {
    const { room, predict, projectiles, input } = await connect(ctx.client);
    const me = await waitFor(() => room.state.players.get(room.sessionId));
    const recon = makeReconciler(predict, me, input);

    const kb = new Keyboard();
    let aimX = 50, aimY = 20;
    let pendingFire = false;
    let optimistic = true;
    let lastLeadMs: number | null = null;
    let fired = 0;
    // Handoff flash: entry id → flash time (state flipped pending→confirmed).
    const wasPending = new Set<number>();
    const flash = new Map<number, number>();

    const onMouseMove = (e: MouseEvent) => {
      const r = ctx.canvas.getBoundingClientRect();
      aimX = ctx.view.wx(e.clientX - r.left);
      aimY = ctx.view.wy(e.clientY - r.top);
    };
    const onMouseDown = (e: MouseEvent) => { if (e.button === 0) pendingFire = true; };
    ctx.canvas.addEventListener("mousemove", onMouseMove);
    ctx.canvas.addEventListener("mousedown", onMouseDown);

    ctx.controls.toggle({
      label: "Optimistic spawn",
      value: true,
      onChange: (v) => { optimistic = v; },
      note: "OFF = fire still works, but your own shot only appears when the server's entity arrives (~RTT late).",
    });
    ctx.controls.note("Click to fire. Amber = predicted local (pending) · white = confirmed (correlated) · red = foreign (the turret's — nobody predicted them).");

    const pendingRow = ctx.hud.row("pending (mine, unconfirmed)");
    const confirmedRow = ctx.hud.row("confirmed entities");
    const leadRow = ctx.hud.row("last measured input lead");
    const firedRow = ctx.hud.row("shots fired");

    return {
      room,
      frame(now: number) {
        const steps = predict.tick(now);
        const d = input.data;
        for (let i = 0; i < steps; i++) {
          d.moveX = kb.moveX();
          d.moveY = kb.moveY();
          d.aimX = aimX;
          d.aimY = aimY;
          d.fire = pendingFire;
          input.send();
          if (pendingFire) {
            fired++;
            if (optimistic) {
              // Spawn the optimistic local at the PREDICTED pose (the same
              // origin the server will use once this input arrives).
              const px = recon.state.x, py = recon.state.y;
              let dx = aimX - px, dy = aimY - py;
              const len = Math.hypot(dx, dy) || 1;
              projectiles.spawn({
                x: px, y: py,
                vx: (dx / len) * PROJECTILE_SPEED,
                vy: (dy / len) * PROJECTILE_SPEED,
              } satisfies LocalProjectile);
            }
            pendingFire = false;
          }
        }

        const g = ctx.g, v = ctx.view;

        // Turret.
        drawSquare(g, v, 50, 8, 2, { fill: "rgba(255,102,136,0.3)", stroke: "#ff6688", lineWidth: 1.5 });
        drawLabel(g, v, 50, 8, "turret (foreign shots)", { dy: -18, color: "#ff6688", size: 10 });

        // Players.
        for (const [sid, p] of room.state.players) {
          if (sid === room.sessionId) continue;
          drawSquare(g, v, predict.value(p, "x"), predict.value(p, "y"), PLAYER_HALF, { fill: hueColor(p.hue, 0.4) });
        }
        drawSquare(g, v, recon.value("x"), recon.value("y"), PLAYER_HALF, { fill: hueColor(me.hue, 1), stroke: "#fff", lineWidth: 1 });
        drawMarker(g, v, aimX, aimY, 0.8, "rgba(216,226,240,0.6)");

        // Projectiles — one render path across the handoff, keyed on entry id.
        let nPending = 0, nConfirmed = 0;
        for (const e of projectiles.entries()) {
          const x = projectiles.value(e, "x");
          const y = projectiles.value(e, "y");
          const mine = e.state === "pending" || (e.server && e.server.owner === room.sessionId);
          if (e.state === "pending") {
            nPending++;
            wasPending.add(e.id);
            drawCircle(g, v, x, y, PROJECTILE_RADIUS, { fill: "rgba(255,180,84,0.9)" });
          } else {
            nConfirmed++;
            if (wasPending.has(e.id)) {
              wasPending.delete(e.id);
              flash.set(e.id, now);
              if (e.leadMs > 0) lastLeadMs = e.leadMs;
            }
            const isFlashing = now - (flash.get(e.id) ?? -Infinity) < 350;
            const color = !mine ? "rgba(255,102,136,0.9)" : "rgba(255,255,255,0.95)";
            drawCircle(g, v, x, y, PROJECTILE_RADIUS * (isFlashing ? 1.8 : 1), { fill: color });
          }
        }

        pendingRow.set(String(nPending), nPending ? "warn" : "");
        confirmedRow.set(String(nConfirmed));
        leadRow.set(lastLeadMs === null ? "—" : `${lastLeadMs.toFixed(0)} ms`, "good");
        firedRow.set(String(fired));
        kb.drainEdges();
      },
      unmount() {
        recon.dispose();
        projectiles.dispose();
        predict.dispose();
        kb.dispose();
        ctx.canvas.removeEventListener("mousemove", onMouseMove);
        ctx.canvas.removeEventListener("mousedown", onMouseDown);
      },
      onReconnect() {
        recon.reset();
      },
      debug() {
        let nPending = 0, nConfirmed = 0, nForeign = 0;
        for (const e of projectiles.entries()) {
          if (e.state === "pending") nPending++;
          else {
            nConfirmed++;
            if (e.server && e.server.owner !== room.sessionId) nForeign++;
          }
        }
        return {
          fired, nPending, nConfirmed, nForeign, lastLeadMs,
          fire: (wx: number, wy: number) => { aimX = wx; aimY = wy; pendingFire = true; },
        };
      },
    };
  },
};
