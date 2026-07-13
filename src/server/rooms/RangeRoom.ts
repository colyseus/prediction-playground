import { Room, type Client, type StepContext } from "@colyseus/core";
import type { Data } from "@colyseus/schema";
import { RangeState, RangePlayer, Bot, RangeInput } from "../schema/range.ts";
import { stepEntity } from "../../shared/movement.ts";
import { stepBot } from "../../shared/movers.ts";
import { rayCircle } from "../../shared/hitscan.ts";
import { spreadAngles, PELLETS } from "../../shared/spread.ts";
import { TICK_HZ, ARENA_W, ARENA_H, BOT_RADIUS, MAX_REWIND_MS } from "../../shared/constants.ts";

const SHOT_RANGE = 200;

/**
 * The shooting range — server-side lag compensation (Lab 06, also Lab 11).
 *
 * Bot positions are RECORDED per tick (`rewind.attachAll`); when an input
 * frame carries `fire`, the hit test reads every target through
 * `rewind.lastSeenBy(sessionId)` — the positions as they were on the
 * shooter's screen (renderTime = its lerp display timeline), NOT where they
 * are now. "Shoot what you see."
 */
export class RangeRoom extends Room<{ state: RangeState; input: RangeInput }> {
  state = new RangeState();
  maxClients = 8;

  inputs = this.defineInput(RangeInput, {
    bufferMaxSize: 64,
    sanitize: {
      moveX: [-1, 1], moveY: [-1, 1],
      aimX: [0, ARENA_W], aimY: [0, ARENA_H],
    },
  });

  private rewind = this.allowRewindState({ maxRewindMs: MAX_REWIND_MS });
  private joinCount = 0;
  private seenScratch = { x: 0, y: 0 };

  messages = {
    /** Room-wide lag-comp switch (labs surface that it affects everyone). */
    lagcomp: (_client: Client, msg: unknown) => {
      this.state.lagComp = !!(msg as { on?: boolean })?.on;
    },
  };

  onCreate() {
    // The spread salt: rolled once per room (server randomness is fine — it
    // syncs as state; only the per-shot derivation must be shared).
    this.state.salt = (Math.random() * 0xffffffff) >>> 0;

    this.state.bots.set("bot1", new Bot({
      x: 50, y: 14, vx: 22, vy: 0, kind: "patrol",
      minX: 24, maxX: 76, baseY: 14, phaseMs: 0, speed: 22,
      lastTeleport: 0,
    }));
    // Record bot x/y per tick. mode:"snapshot" rewinds to the shooter's
    // renderTime — pairs with the client DISPLAYING bots via lerp/damped.
    // (A reckon-displayed target would pair with mode:"reckon" instead —
    // the display timeline and the rewind timeline must be the same one.)
    this.rewind.attachAll(this.state.bots, { fields: ["x", "y"], mode: "snapshot" });

    this.setFixedTimestep((ctx) => this.step(ctx), TICK_HZ);
  }

  onJoin(client: Client) {
    const n = this.joinCount++;
    this.state.players.set(client.sessionId, new RangePlayer({
      x: ARENA_W / 2 + Math.cos(n * 2.399963) * 14,
      y: ARENA_H * 0.75 + Math.sin(n * 2.399963) * 5,
      vx: 0, vy: 0,
      hue: (n * 67) % 256,
    }));
  }

  onDrop(client: Client) {
    // Hold the seat through a transport drop (the debug panel's "Drop" button,
    // a network blip): the SDK auto-reconnects and the lab re-seeds its
    // predictor in room.onReconnect.
    this.allowReconnection(client, 10);
  }

  onLeave(client: Client) {
    this.state.players.delete(client.sessionId);
  }

  private step(ctx: StepContext) {
    for (const [sid, p] of this.state.players) {
      const channel = this.inputs.get(sid);
      if (!channel) continue;
      // Per-input hit testing: the shot resolves against the exact pose this
      // input stepped to, and the rewind reads this input's own stamp.
      for (const inp of channel) {
        stepEntity(p, inp, ctx.dt);
        if (inp.fire) {
          if (inp.spread) this.resolveSpread(sid, p, inp, channel.consumedCount);
          else this.resolveShot(sid, p, inp);
        }
      }
    }
    const elapsed = this.clock.elapsedTime;
    for (const [, bot] of this.state.bots) stepBot(bot, ctx.dt, elapsed);
  }

  private resolveShot(sid: string, p: RangePlayer, inp: Data<RangeInput>): void {
    p.shots++;
    const ox = p.x, oy = p.y;
    let dx = inp.aimX - ox, dy = inp.aimY - oy;
    const len = Math.sqrt(dx * dx + dy * dy);
    if (len < 1e-6) return;
    dx /= len; dy /= len;

    // THE lag-comp line: targets read AS THE SHOOTER SAW THEM.
    const seen = this.state.lagComp ? this.rewind.lastSeenBy(sid) : null;

    let hitId: string | null = null;
    let bestT = Infinity;
    for (const [id, bot] of this.state.bots) {
      const pos = seen ? seen.read(bot, ["x", "y"], this.seenScratch) : bot;
      const t = rayCircle(ox, oy, dx, dy, pos.x, pos.y, BOT_RADIUS, SHOT_RANGE);
      if (t >= 0 && t < bestT) { bestT = t; hitId = id; }
    }
    if (hitId) p.hits++;

    // Shot report for the client-side markers: where the server REWOUND the
    // bot to (should overlap what the shooter saw) vs where it LIVE-was
    // (ahead by ~RTT/2 + interp delay, in units of bot travel).
    const bot = this.state.bots.get("bot1")!;
    const seenPos = seen ? seen.read(bot, ["x", "y"], this.seenScratch) : { x: bot.x, y: bot.y };
    this.broadcast("shot", {
      sid, ox, oy, dx, dy,
      hit: hitId !== null,
      seenX: seenPos.x, seenY: seenPos.y,
      liveX: bot.x, liveY: bot.y,
      lagComp: this.state.lagComp,
    });
  }

  private spreadScratch: number[] = [];

  /**
   * Lab 11: the shotgun fan. The pellet angles derive from (input seq, room
   * salt) through the SAME shared function the client runs — the broadcast
   * carries the server's angles only so the client can OVERLAY and compare.
   */
  private resolveSpread(sid: string, p: RangePlayer, inp: Data<RangeInput>, seq: number): void {
    p.shots++;
    const ox = p.x, oy = p.y;
    const base = Math.atan2(inp.aimY - oy, inp.aimX - ox);
    const angles = spreadAngles(base, seq, this.state.salt, this.spreadScratch);

    const seen = this.state.lagComp ? this.rewind.lastSeenBy(sid) : null;
    let hits = 0;
    for (let i = 0; i < PELLETS; i++) {
      const dx = Math.cos(angles[i]), dy = Math.sin(angles[i]);
      for (const [, bot] of this.state.bots) {
        const pos = seen ? seen.read(bot, ["x", "y"], this.seenScratch) : bot;
        if (rayCircle(ox, oy, dx, dy, pos.x, pos.y, BOT_RADIUS, SHOT_RANGE) >= 0) { hits++; break; }
      }
    }
    if (hits > 0) p.hits++;

    this.broadcast("spread", { sid, seq, ox, oy, angles: [...angles], hits });
  }
}
