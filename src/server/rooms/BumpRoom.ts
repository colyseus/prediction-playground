import { Room, type Client, type StepContext } from "@colyseus/core";
import { BumpState, BumpPlayer, Bot, MoveInput } from "../schema/bump.ts";
import { stepEntity } from "../../shared/movement.ts";
import { stepBot } from "../../shared/movers.ts";
import { stepBumpGate, collideBot, BUMP_COOLDOWN_TICKS } from "../../shared/bump.ts";
import { TICK_HZ, ARENA_W, ARENA_H, MAX_REWIND_MS } from "../../shared/constants.ts";

/**
 * WYSIWYG collision (Lab 07): drive into a patrolling bot and the shove is
 * PREDICTED — because both sides evaluate the collision against the SAME bot
 * position:
 *   client — reckons the bot to the input's `ctx.reckonTime` (valueAt)
 *   server — rewinds the bot to that same instant (`mode: "reckon"` +
 *            per-input `lastSeenBy`)
 * Same instant, same shared stepBot ⇒ same verdict, by construction.
 */
export class BumpRoom extends Room<{ state: BumpState; input: MoveInput }> {
  state = new BumpState();
  maxClients = 8;

  inputs = this.defineInput(MoveInput, {
    bufferMaxSize: 64,
    sanitize: { moveX: [-1, 1], moveY: [-1, 1] },
  });

  private rewind = this.allowRewindState({ maxRewindMs: MAX_REWIND_MS });
  private joinCount = 0;
  private seenScratch = { x: 0, y: 0 };

  onCreate() {
    this.state.bots.set("bot1", new Bot({
      x: 50, y: 30, vx: 20, vy: 0, kind: "patrol",
      minX: 25, maxX: 75, baseY: 30, phaseMs: 0, speed: 20,
      lastTeleport: 0,
    }));
    // mode:"reckon": the client DISPLAYS this bot dead-reckoned to the
    // present, so the rewind aims at the client's reckonTime (its serverNow).
    this.rewind.attachAll(this.state.bots, { fields: ["x", "y"], mode: "reckon" });

    this.setFixedTimestep((ctx) => this.step(ctx), TICK_HZ);
  }

  onJoin(client: Client) {
    const n = this.joinCount++;
    this.state.players.set(client.sessionId, new BumpPlayer({
      x: ARENA_W / 2 + Math.cos(n * 2.399963) * 16,
      y: ARENA_H * 0.75, vx: 0, vy: 0,
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
      // Per-input processing: each input is hit-tested at ITS OWN rewind
      // instant, so a burst at high RTT can't skip the pose that overlapped.
      for (const inp of channel) {
        stepBumpGate(p);
        stepEntity(p, inp, ctx.dt);
        const seen = this.rewind.lastSeenBy(sid);
        for (const [, bot] of this.state.bots) {
          const pos = seen.read(bot, ["x", "y"], this.seenScratch);
          const hit = collideBot(p, pos.x, pos.y);
          if (hit) {
            p.vx = hit.vx;
            p.vy = hit.vy;
            p.bumpTicks = BUMP_COOLDOWN_TICKS;
            p.bumps++;
          }
        }
      }
    }
    const elapsed = this.clock.elapsedTime;
    for (const [, bot] of this.state.bots) stepBot(bot, ctx.dt, elapsed);
  }
}
