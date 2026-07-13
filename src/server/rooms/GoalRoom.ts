import { Room, type Client, type StepContext } from "@colyseus/core";
import { GoalState, GoalPlayer, MoveInput } from "../schema/goal.ts";
import { stepEntity } from "../../shared/movement.ts";
import { stepScoreGate } from "../../shared/goal.ts";
import { TICK_HZ, ARENA_W, ARENA_H } from "../../shared/constants.ts";

/**
 * Optimistic events (Lab 08): run into the goal zone. The GATE (did this step
 * cross into the zone?) is shared deterministic sim — both sides agree. The
 * AWARD is server-only: score++, plus a "goal" broadcast the client uses to
 * confirm its optimistic banner. `denyRate` manufactures rejections so the
 * client's onReject path is demonstrable.
 */
export class GoalRoom extends Room<{ state: GoalState; input: MoveInput }> {
  state = new GoalState();
  maxClients = 8;

  inputs = this.defineInput(MoveInput, {
    bufferMaxSize: 64,
    sanitize: { moveX: [-1, 1], moveY: [-1, 1] },
  });

  private joinCount = 0;

  messages = {
    denyRate: (_client: Client, msg: unknown) => {
      const rate = Number((msg as { rate?: number })?.rate);
      if (Number.isFinite(rate)) this.state.denyRate = Math.max(0, Math.min(100, Math.round(rate)));
    },
  };

  onCreate() {
    this.setFixedTimestep((ctx) => this.step(ctx), TICK_HZ);
  }

  onJoin(client: Client) {
    const n = this.joinCount++;
    this.state.players.set(client.sessionId, new GoalPlayer({
      x: ARENA_W * 0.25 + Math.cos(n * 2.399963) * 8,
      y: ARENA_H / 2 + Math.sin(n * 2.399963) * 8,
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
      for (const inp of channel) {
        stepEntity(p, inp, ctx.dt);
        if (stepScoreGate(p)) {
          // The gate fired on both sides; only the AWARD rolls the dice.
          // (Server-only randomness is fine — it's authority, not prediction.)
          if (Math.random() * 100 >= this.state.denyRate) {
            p.score++;
            this.broadcast("goal", { sid });
          }
        }
      }
    }
  }
}
