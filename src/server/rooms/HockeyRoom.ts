import { Room, type Client, type StepContext } from "@colyseus/core";
import { HockeyState, Puck, Player, MoveInput } from "../schema/hockey.ts";
import { stepEntity } from "../../shared/movement.ts";
import { stepPuck, collidePaddlePuck, botInput, BOT_ID } from "../../shared/hockey.ts";
import { TICK_HZ, ARENA_W, ARENA_H } from "../../shared/constants.ts";

/**
 * Mini air-hockey (Lab 10 — composite-world prediction). The server's step
 * order is the CONTRACT the client's `predict.sim` reproduces:
 *   1. every paddle steps (players-map order), ONE buffered input each,
 *   2. the puck integrates once,
 *   3. paddle↔puck contacts resolve (players-map order).
 * "One input each" is part of the contract: the predicting client interleaves
 * paddle/puck/contacts 1:1 per input, and it can only reproduce ticks that do
 * the same (see the pacing note in step()).
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
        // Chase the puck on its own half; drift home otherwise. A server-owned
        // DECISION, but derived from synced state only — so the predicting
        // client runs this very function and predicts bot contacts too.
        botInput(p, puck, this.state.botEnabled, this.botInput);
        stepEntity(p, this.botInput, ctx.dt);
        continue;
      }
      const channel = this.inputs.get(sid);
      if (!channel) continue;
      // ONE input per tick — the composite-sim contract (1 input = 1 world
      // tick). Draining every arrival would step this paddle N times against a
      // single puck step + one contact pass, so a bursty arrival (frame hitch,
      // jitter phase wrap) mispredicts any touch in the window — a big enough
      // batch tunnels the paddle straight through the puck. The buffer is the
      // jitter buffer; fold one extra per tick only while a backlog drains.
      let inp = channel.next();
      if (inp !== undefined) stepEntity(p, inp, ctx.dt);
      if (channel.size > 1 && (inp = channel.next()) !== undefined) {
        stepEntity(p, inp, ctx.dt);
      }
    }

    stepPuck(puck, ctx.dt);
    for (const [, p] of this.state.players) collidePaddlePuck(p, puck);
  }
}
