import docs from "./docs.md?raw";
import source from "./net.ts?raw";
import { connect, makeReckon } from "./net.ts";
import type { LabDescriptor, LabContext, LabInstance } from "../../framework/lab.ts";
import { waitFor } from "../../framework/lab.ts";
import { Keyboard } from "../../framework/input.ts";
import { FixedStepPacer } from "../../framework/pacer.ts";
import { drawSquare, drawCircle, drawLine, drawLabel, hueColor } from "../../framework/draw.ts";
import { TICK_HZ, PLAYER_HALF, BOT_RADIUS } from "../../../shared/constants.ts";

export const lab: LabDescriptor = {
  id: "05-dead-reckoning",
  num: 5,
  title: "Dead Reckoning",
  blurb: "Forward-simulate remotes to the present with the shared step.",
  phase: 1,
  docs,
  source,

  async mount(ctx: LabContext): Promise<LabInstance> {
    const { room, input, lerp, disposeLerp } = await connect(ctx.client);
    const bot = await waitFor(() => room.state.bots.get("bot1"));
    const me = await waitFor(() => room.state.players.get(room.sessionId));

    let smoothMs = 40;
    let snap = 8;
    let reckon = makeReckon(room, { smoothMs, snap });
    const rebuild = () => {
      reckon.dispose();
      reckon = makeReckon(room, { smoothMs, snap });
    };

    const kb = new Keyboard();
    const pacer = new FixedStepPacer(1000 / TICK_HZ);

    // Raw snapshot dots (short history) + warp flash detection.
    const rawDots: Array<{ x: number; y: number; t: number }> = [];
    let lastRawX = NaN, lastRawY = NaN;
    let lastReckonX = NaN;
    let warps = 0;
    let warpFlashT = -Infinity;

    room.send("pattern", { kind: "teleport" });

    ctx.controls.radio<string>({
      label: "Bot pattern (room-wide)",
      value: "teleport",
      options: [
        { value: "patrol", label: "patrol" },
        { value: "wander", label: "wander" },
        { value: "teleport", label: "teleport" },
      ],
      onChange: (kind) => room.send("pattern", { kind }),
      note: "patrol = fully predictable · wander = server-secret turns (reckon corrects) · teleport = a scheduled discontinuity",
    });
    ctx.controls.slider({
      label: "Rebase smoothing", min: 0, max: 200, value: smoothMs, unit: " ms",
      onCommit: true,
      onChange: (v) => { smoothMs = v; rebuild(); },
      note: "How long a snapshot-rebase correction takes to glide out. (Reckon params are attach options, not panel profiles — unlike Lab 04's modes, so these sliders rebuild the attach.)",
    });
    ctx.controls.slider({
      label: "Snap threshold", min: 1, max: 60, value: snap, unit: " u",
      onCommit: true,
      onChange: (v) => { snap = v; rebuild(); },
      note: "Rebases beyond this POP instead of gliding. Raise it above the warp distance and watch the teleport smear across the arena.",
    });

    const horizonRow = ctx.hud.row("reckon horizon (snapshot age)");
    const gapRow = ctx.hud.row("reckon vs lerp gap");
    const warpsRow = ctx.hud.row("warps seen");

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
        lerp.tick(now);
        reckon.predict.tick(now);

        const g = ctx.g, v = ctx.view;
        const clock = (room as any).clock;
        const sNow = clock.serverNow();
        const age = Math.max(0, sNow - clock.lastServerTime());

        // Record raw snapshot dots.
        if (bot.x !== lastRawX || bot.y !== lastRawY) {
          lastRawX = bot.x; lastRawY = bot.y;
          rawDots.push({ x: bot.x, y: bot.y, t: now });
          if (rawDots.length > 40) rawDots.shift();
        }

        // Players.
        for (const [sid, p] of room.state.players) {
          drawSquare(g, v, p.x, p.y, PLAYER_HALF, {
            fill: hueColor(p.hue, sid === room.sessionId ? 0.9 : 0.4),
          });
        }

        // Raw snapshot dots (fading).
        for (const dot of rawDots) {
          const a = Math.max(0, 1 - (now - dot.t) / 1500);
          if (a <= 0) continue;
          drawCircle(g, v, dot.x, dot.y, 0.4, { fill: `rgba(255,255,255,${a * 0.5})` });
        }

        const lx = lerp.value(bot, "x"), ly = lerp.value(bot, "y");
        const rx = reckon.predict.value(bot, "x"), ry = reckon.predict.value(bot, "y");

        // Warp detection on the reckon output (display flash + counter).
        if (!Number.isNaN(lastReckonX) && Math.abs(rx - lastReckonX) > 15) {
          warps++;
          warpFlashT = now;
        }
        lastReckonX = rx;

        // The reckon horizon: newest snapshot → forward-simulated present.
        drawLine(g, v, bot.x, bot.y, rx, ry, "#ffb454", 1.2, [3, 3], 0.8);
        drawCircle(g, v, bot.x, bot.y, 0.7, { fill: "rgba(255,255,255,0.9)" });

        // lerp ghost (the delayed baseline) and the reckon bot.
        drawCircle(g, v, lx, ly, BOT_RADIUS, { stroke: "#6db3ff", lineWidth: 2, alpha: 0.9 });
        drawLabel(g, v, lx, ly, "lerp (past)", { dy: v.s(BOT_RADIUS) + 12, color: "#6db3ff", size: 10 });
        drawCircle(g, v, rx, ry, BOT_RADIUS, { fill: "rgba(255,180,84,0.25)", stroke: "#ffb454", lineWidth: 2 });
        drawLabel(g, v, rx, ry, "reckon (present)", { dy: -v.s(BOT_RADIUS) - 6, color: "#ffb454", size: 10 });

        if (now - warpFlashT < 500) {
          drawLabel(g, v, rx, ry, "WARP", { dy: -v.s(BOT_RADIUS) - 20, color: "#ff6688", size: 13 });
        }

        horizonRow.set(`${age.toFixed(0)} ms`);
        gapRow.set(`${Math.hypot(rx - lx, ry - ly).toFixed(1)} u`);
        warpsRow.set(String(warps));
        kb.drainEdges();
      },
      unmount() {
        reckon.dispose();
        disposeLerp();
        kb.dispose();
      },
      debug() {
        return {
          rawX: bot.x,
          lerpX: lerp.value(bot, "x"),
          reckonX: reckon.predict.value(bot, "x"),
          horizonMs: Math.max(0, (room as any).clock.serverNow() - (room as any).clock.lastServerTime()),
          warps,
        };
      },
    };
  },
};
