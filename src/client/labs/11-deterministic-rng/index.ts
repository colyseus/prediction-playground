import docs from "./docs.md?raw";
import source from "./net.ts?raw";
import { connect, makeReconciler, clientFan } from "./net.ts";
import type { LabDescriptor, LabContext, LabInstance } from "../../framework/lab.ts";
import { waitFor } from "../../framework/lab.ts";
import { Keyboard } from "../../framework/input.ts";
import { drawSquare, drawCircle, drawLine, drawMarker, drawLabel, hueColor } from "../../framework/draw.ts";
import { PLAYER_HALF, BOT_RADIUS } from "../../../shared/constants.ts";

const FAN_LEN = 40;

interface FanViz {
  seq: number;
  ox: number; oy: number;
  clientAngles: number[];
  serverAngles?: number[];
  hits?: number;
  t: number;
}

export const lab: LabDescriptor = {
  id: "11-deterministic-rng",
  num: 11,
  title: "Deterministic Randomness",
  blurb: "Same seed both sides, nothing on the wire.",
  phase: 2,
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
    let cheat = false;
    const fans: FanViz[] = [];
    let maxDivergence: number | null = null;

    const onMouseMove = (e: MouseEvent) => {
      const r = ctx.canvas.getBoundingClientRect();
      aimX = ctx.view.wx(e.clientX - r.left);
      aimY = ctx.view.wy(e.clientY - r.top);
    };
    const onMouseDown = (e: MouseEvent) => { if (e.button === 0) pendingFire = true; };
    ctx.canvas.addEventListener("mousemove", onMouseMove);
    ctx.canvas.addEventListener("mousedown", onMouseDown);

    const offSpread = room.onMessage("spread", (msg: any) => {
      if (msg.sid !== room.sessionId) return;
      const fan = fans.find((f) => f.seq === msg.seq);
      if (!fan) return;
      fan.serverAngles = msg.angles;
      fan.hits = msg.hits;
      let d = 0;
      for (let i = 0; i < fan.clientAngles.length; i++) {
        d = Math.max(d, Math.abs(fan.clientAngles[i] - msg.angles[i]));
      }
      maxDivergence = d;
    });

    ctx.controls.toggle({
      label: "Cheat with Math.random()",
      value: false,
      onChange: (v) => { cheat = v; },
      note: "The broken version: pellets the server cannot reproduce. Watch the fans disagree.",
    });
    ctx.controls.note("Click to fire a 6-pellet fan at the strafing bot. Amber = the fan your client derived at the click. White = the fan the server derived from the same (seq, salt). They should be identical.");

    const divRow = ctx.hud.row("fan divergence (last shot)");
    const hitsRow = ctx.hud.row("pellets hit (last shot)");
    const saltRow = ctx.hud.row("room salt");

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
          d.spread = true;
          const seq = input.send();
          if (pendingFire) {
            const px = recon.state.x, py = recon.state.y;
            const base = Math.atan2(aimY - py, aimX - px);
            const angles = clientFan(base, seq, room.state.salt, cheat, []);
            fans.push({ seq, ox: px, oy: py, clientAngles: [...angles], t: now });
            if (fans.length > 4) fans.shift();
            pendingFire = false;
          }
        }

        const g = ctx.g, v = ctx.view;

        for (const [sid, p] of room.state.players) {
          if (sid === room.sessionId) continue;
          drawSquare(g, v, predict.value(p, "x"), predict.value(p, "y"), PLAYER_HALF, { fill: hueColor(p.hue, 0.4) });
        }
        drawSquare(g, v, recon.value("x"), recon.value("y"), PLAYER_HALF, { fill: hueColor(me.hue, 1), stroke: "#fff", lineWidth: 1 });

        const bx = predict.value(bot, "x"), by = predict.value(bot, "y");
        drawCircle(g, v, bx, by, BOT_RADIUS, { fill: "rgba(109,179,255,0.25)", stroke: "#6db3ff", lineWidth: 2 });
        drawMarker(g, v, aimX, aimY, 0.9, "rgba(216,226,240,0.7)");

        for (let i = fans.length - 1; i >= 0; i--) {
          const f = fans[i];
          const age = now - f.t;
          if (age > 2400) { fans.splice(i, 1); continue; }
          const a = Math.max(0, 1 - age / 2400);
          for (const ang of f.clientAngles) {
            drawLine(g, v, f.ox, f.oy, f.ox + Math.cos(ang) * FAN_LEN, f.oy + Math.sin(ang) * FAN_LEN, "#ffb454", 1.2, undefined, a * 0.75);
          }
          if (f.serverAngles) {
            for (const ang of f.serverAngles) {
              drawLine(g, v, f.ox, f.oy, f.ox + Math.cos(ang) * FAN_LEN, f.oy + Math.sin(ang) * FAN_LEN, "rgba(255,255,255,0.9)", 0.7, [4, 3], a * 0.9);
            }
          }
        }
        if (fans.length) {
          drawLabel(g, v, fans[fans.length - 1].ox, fans[fans.length - 1].oy, "amber = client · white = server", { dy: v.s(PLAYER_HALF) + 14, size: 9, color: "rgba(216,226,240,0.5)" });
        }

        divRow.set(
          maxDivergence === null ? "—" : `${maxDivergence.toFixed(5)} rad`,
          maxDivergence === null ? "" : maxDivergence < 1e-6 ? "good" : "bad",
        );
        const lastAnswered = [...fans].reverse().find((f) => f.hits !== undefined);
        hitsRow.set(lastAnswered ? `${lastAnswered.hits} / ${lastAnswered.clientAngles.length}` : "—");
        saltRow.set(String(room.state.salt));
        kb.drainEdges();
      },
      unmount() {
        offSpread();
        recon.dispose();
        predict.dispose();
        kb.dispose();
        ctx.canvas.removeEventListener("mousemove", onMouseMove);
        ctx.canvas.removeEventListener("mousedown", onMouseDown);
      },
      onReconnect() {
        recon.reset();
      },
      debug() {
        return {
          maxDivergence,
          shots: fans.length,
          cheat,
          salt: room.state.salt,
          fire: (wx: number, wy: number) => { aimX = wx; aimY = wy; pendingFire = true; },
          setCheat: (v: boolean) => { cheat = v; },
        };
      },
    };
  },
};
