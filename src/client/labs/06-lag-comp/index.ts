import docs from "./docs.md?raw";
import source from "./net.ts?raw";
import { connect, makeReconciler } from "./net.ts";
import type { LabDescriptor, LabContext, LabInstance } from "../../framework/lab.ts";
import { waitFor } from "../../framework/lab.ts";
import { Keyboard } from "../../framework/input.ts";
import { drawSquare, drawCircle, drawLine, drawMarker, drawLabel, hueColor } from "../../framework/draw.ts";
import { PLAYER_HALF, BOT_RADIUS } from "../../../shared/constants.ts";

interface ShotViz {
  ox: number; oy: number;
  tx: number; ty: number;         // ray endpoint (aim dir × range, for drawing)
  blueX: number; blueY: number;   // what the shooter saw at click time
  greenX?: number; greenY?: number; // server's rewound read
  redX?: number; redY?: number;     // server's live position
  hit?: boolean;
  t: number;
}

export const lab: LabDescriptor = {
  id: "06-lag-comp",
  num: 6,
  title: "Lag Compensation",
  blurb: "The server rewinds targets to what you saw.",
  phase: 1,
  docs,
  source,

  async mount(ctx: LabContext): Promise<LabInstance> {
    const { room, predict, input } = await connect(ctx.client);
    const me = await waitFor(() => room.state.players.get(room.sessionId));
    const bot = await waitFor(() => room.state.bots.get("bot1"));
    const recon = makeReconciler(predict, me, input);

    const kb = new Keyboard();
    let aimX = 50, aimY = 20;
    let pendingFire = false;
    const shots: ShotViz[] = [];
    let hitsOn = 0, shotsOn = 0, hitsOff = 0, shotsOff = 0;

    const onMouseMove = (e: MouseEvent) => {
      const r = ctx.canvas.getBoundingClientRect();
      aimX = ctx.view.wx(e.clientX - r.left);
      aimY = ctx.view.wy(e.clientY - r.top);
    };
    const onMouseDown = (e: MouseEvent) => {
      if (e.button === 0) pendingFire = true;
    };
    ctx.canvas.addEventListener("mousemove", onMouseMove);
    ctx.canvas.addEventListener("mousedown", onMouseDown);

    // Server shot report → complete the newest un-answered shot record.
    const offShot = room.onMessage("shot", (msg: any) => {
      if (msg.sid !== room.sessionId) return;
      const shot = shots.find((s) => s.greenX === undefined);
      if (shot) {
        shot.greenX = msg.seenX; shot.greenY = msg.seenY;
        shot.redX = msg.liveX; shot.redY = msg.liveY;
        shot.hit = msg.hit;
      }
      if (msg.lagComp) { shotsOn++; if (msg.hit) hitsOn++; }
      else { shotsOff++; if (msg.hit) hitsOff++; }
    });

    const lagToggle = ctx.controls.toggle({
      label: "Lag compensation (room-wide)",
      value: room.state.lagComp,
      onChange: (v) => room.send("lagcomp", { on: v }),
      note: "OFF at high latency = you must lead the target by the red↔blue gap.",
    });
    ctx.controls.note("Aim with the mouse, click to fire. WASD moves you (predicted, Lab 03 style). Markers: blue = what you saw · green = server's rewound read · red = server live.");

    const tallyOn = ctx.hud.row("hits (lag comp ON)");
    const tallyOff = ctx.hud.row("hits (lag comp OFF)");
    const gapRow = ctx.hud.row("view lag (red↔blue gap)");

    return {
      room,
      frame(now: number) {
        // Keep the toggle honest if a peer flips it.
        if (lagToggle.get() !== room.state.lagComp) lagToggle.set(room.state.lagComp);

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
            // Record what THIS screen showed at the moment of the shot.
            const bx = predict.value(bot, "x"), by = predict.value(bot, "y");
            const px = recon.state.x, py = recon.state.y;
            let dx = aimX - px, dy = aimY - py;
            const len = Math.hypot(dx, dy) || 1;
            dx /= len; dy /= len;
            shots.push({
              ox: px, oy: py,
              tx: px + dx * 120, ty: py + dy * 120,
              blueX: bx, blueY: by,
              t: now,
            });
            if (shots.length > 6) shots.shift();
            pendingFire = false;
          }
        }

        const g = ctx.g, v = ctx.view;

        // Remote players + own predicted square.
        for (const [sid, p] of room.state.players) {
          if (sid === room.sessionId) continue;
          drawSquare(g, v, predict.value(p, "x"), predict.value(p, "y"), PLAYER_HALF, {
            fill: hueColor(p.hue, 0.4),
          });
        }
        const px = recon.value("x"), py = recon.value("y");
        drawSquare(g, v, px, py, PLAYER_HALF, { fill: hueColor(me.hue, 1), stroke: "#fff", lineWidth: 1 });

        // The bot on its lerp timeline (what you aim at).
        const bx = predict.value(bot, "x"), by = predict.value(bot, "y");
        drawCircle(g, v, bx, by, BOT_RADIUS, { fill: "rgba(109,179,255,0.25)", stroke: "#6db3ff", lineWidth: 2 });
        drawLabel(g, v, bx, by, "target (lerp view)", { dy: -v.s(BOT_RADIUS) - 6, color: "#6db3ff", size: 10 });

        // Crosshair + aim line.
        drawLine(g, v, px, py, aimX, aimY, "rgba(216,226,240,0.18)", 1, [2, 4]);
        drawMarker(g, v, aimX, aimY, 0.9, "rgba(216,226,240,0.7)");

        // Shot records.
        for (let i = shots.length - 1; i >= 0; i--) {
          const s = shots[i];
          const age = now - s.t;
          if (age > 2600) { shots.splice(i, 1); continue; }
          const a = Math.max(0, 1 - age / 2600);
          drawLine(g, v, s.ox, s.oy, s.tx, s.ty, s.hit === undefined ? "rgba(255,255,255,0.5)" : s.hit ? "#7be08a" : "#ff6688", 1.2, undefined, a * 0.7);
          drawMarker(g, v, s.blueX, s.blueY, BOT_RADIUS * 0.7, "#6db3ff", a);
          if (s.greenX !== undefined) {
            drawMarker(g, v, s.greenX!, s.greenY!, BOT_RADIUS * 0.85, "#7be08a", a);
            drawMarker(g, v, s.redX!, s.redY!, BOT_RADIUS, "#ff6688", a);
          }
        }

        // HUD.
        tallyOn.set(`${hitsOn} / ${shotsOn}`, shotsOn && hitsOn / shotsOn > 0.7 ? "good" : "");
        tallyOff.set(`${hitsOff} / ${shotsOff}`, shotsOff && hitsOff / shotsOff < 0.5 ? "bad" : "");
        const latest = shots.find((s) => s.redX !== undefined);
        if (latest) {
          gapRow.set(`${Math.hypot(latest.redX! - latest.blueX, latest.redY! - latest.blueY).toFixed(1)} u`);
        }
        kb.drainEdges();
      },
      unmount() {
        recon.dispose();
        predict.dispose();
        kb.dispose();
        offShot();
        ctx.canvas.removeEventListener("mousemove", onMouseMove);
        ctx.canvas.removeEventListener("mousedown", onMouseDown);
      },
      onReconnect() {
        recon.reset();
      },
      debug() {
        const latest = [...shots].reverse().find((s) => s.redX !== undefined);
        return {
          shotsOn, hitsOn, shotsOff, hitsOff,
          lagComp: room.state.lagComp,
          latestShot: latest ? {
            blueX: latest.blueX, greenX: latest.greenX, redX: latest.redX, hit: latest.hit,
          } : null,
          botLerpX: predict.value(bot, "x"),
          botLerpY: predict.value(bot, "y"),
          botRawX: bot.x,
          // Probe hook: aim at exact world coords and fire on the next step.
          fire: (wx: number, wy: number) => { aimX = wx; aimY = wy; pendingFire = true; },
        };
      },
    };
  },
};
