import { Room, type Client, type StepContext } from "@colyseus/core";
import { HockeyState, Puck, Player, MoveInput } from "../schema/hockey.ts";
import { stepEntity } from "../../shared/movement.ts";
import { stepPuck, collidePaddlePuck } from "../../shared/hockey.ts";
import { TICK_HZ, ARENA_W, ARENA_H } from "../../shared/constants.ts";

const BOT_ID = "bot";

/**
 * Mini air-hockey (Lab 10 — composite-world prediction). The server's step
 * order is the CONTRACT the client's `predict.sim` reproduces:
 *   1. every paddle steps (players-map order),
 *   2. the puck integrates once,
 *   3. paddle↔puck contacts resolve (players-map order).
 */
export class HockeyRoom extends Room<{ state: HockeyState; input: MoveInput }> {
  state = new HockeyState({ puck: new Puck({ x: ARENA_W / 2, y: ARENA_H / 2, vx: 0, vy: 0 }) });
  maxClients = 8;

  inputs = this.defineInput(MoveInput, {
    bufferMaxSize: 64,
    sanitize: { moveX: [-1, 1], moveY: [-1, 1] },
  });

  private joinCount = 0;
  private botInput = { moveX: 0, moveY: 0 };

  messages = {
    bot: (_client: Client, msg: unknown) => {
      this.state.botEnabled = !!(msg as { on?: boolean })?.on;
    },
    resetPuck: () => {
      this.state.puck.x = ARENA_W / 2;
      this.state.puck.y = ARENA_H / 2;
      this.state.puck.vx = 0;
      this.state.puck.vy = 0;
    },
  };

  onCreate() {
    this.state.players.set(BOT_ID, new Player({
      x: ARENA_W / 2, y: ARENA_H * 0.2, vx: 0, vy: 0, hue: 190,
    }));
    this.setFixedTimestep((ctx) => this.step(ctx), TICK_HZ);
  }

  onJoin(client: Client) {
    const n = this.joinCount++;
    this.state.players.set(client.sessionId, new Player({
      x: ARENA_W / 2 + Math.cos(n * 2.399963) * 14,
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
    const puck = this.state.puck;

    for (const [sid, p] of this.state.players) {
      if (sid === BOT_ID) {
        // Chase the puck on its own half; drift home otherwise. Server-only
        // DECISION, but the resulting position syncs like any player's.
        const tx = this.state.botEnabled && puck.y < ARENA_H / 2 ? puck.x : ARENA_W / 2;
        const ty = this.state.botEnabled && puck.y < ARENA_H / 2 ? puck.y : ARENA_H * 0.2;
        this.botInput.moveX = tx - p.x > 1 ? 1 : tx - p.x < -1 ? -1 : 0;
        this.botInput.moveY = ty - p.y > 1 ? 1 : ty - p.y < -1 ? -1 : 0;
        stepEntity(p, this.botInput, ctx.dt);
        continue;
      }
      const channel = this.inputs.get(sid);
      if (!channel) continue;
      for (const inp of channel) stepEntity(p, inp, ctx.dt);
    }

    stepPuck(puck, ctx.dt);
    for (const [, p] of this.state.players) collidePaddlePuck(p, puck);
  }
}
