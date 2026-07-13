import { Room, type Client, type StepContext } from "@colyseus/core";
import { MoveState, Player, MoveInput } from "../schema/move.ts";
import { stepEntity } from "../../shared/movement.ts";
import { TICK_HZ, ARENA_W, ARENA_H } from "../../shared/constants.ts";

/** Velocity kick applied by the "impulse" scenario (forces a misprediction). */
const IMPULSE_SPEED = 55;

/**
 * The simplest possible authoritative room: WASD squares in an arena.
 * Serves Labs 1 (no prediction), 2 (clocks) and 3 (predict & reconcile) —
 * the server is identical for all three; the technique is a client-side choice.
 */
export class MoveRoom extends Room<{ state: MoveState; input: MoveInput }> {
  state = new MoveState();
  maxClients = 8;

  inputs = this.defineInput(MoveInput, {
    bufferMaxSize: 64,
    sanitize: { moveX: [-1, 1], moveY: [-1, 1] },
  });

  private joinCount = 0;
  private impulseCount = 0;

  messages = {
    /** Server-side shove — the client can't see it coming, so it MUST mispredict. */
    impulse: (client: Client) => {
      const p = this.state.players.get(client.sessionId);
      if (!p) return;
      // Toward the arena center (never into a wall the clamp would eat), with a
      // deterministic golden-angle tilt so repeated shoves vary direction.
      const a = Math.atan2(ARENA_H / 2 - p.y, ARENA_W / 2 - p.x)
        + (this.impulseCount++ % 3 - 1) * 0.6;
      p.vx += Math.cos(a) * IMPULSE_SPEED;
      p.vy += Math.sin(a) * IMPULSE_SPEED;
    },
    /** Teleport across the arena — a discontinuity the reconciler must snap, not glide. */
    teleport: (client: Client) => {
      const p = this.state.players.get(client.sessionId);
      if (!p) return;
      p.x = ARENA_W - p.x;
      p.y = ARENA_H - p.y;
      p.vx = 0;
      p.vy = 0;
    },
  };

  onCreate() {
    this.setFixedTimestep((ctx) => this.step(ctx), TICK_HZ);
  }

  onJoin(client: Client) {
    const n = this.joinCount++;
    this.state.players.set(client.sessionId, new Player({
      // Deterministic spawn ring around the arena center.
      x: ARENA_W / 2 + Math.cos(n * 2.399963) * 12,
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
    // One shared stepEntity per received input: predicted set == applied set.
    // An empty tick advances nothing (a silent client freezes in place).
    for (const [sid, p] of this.state.players) {
      const channel = this.inputs.get(sid);
      if (!channel) continue;
      for (const inp of channel) stepEntity(p, inp, ctx.dt);
    }
  }
}
