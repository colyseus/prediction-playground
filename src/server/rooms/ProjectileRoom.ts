import { Room, type Client, type StepContext } from "@colyseus/core";
import type { Data } from "@colyseus/schema";
import { ProjectileState, Projectile, Player, RangeInput } from "../schema/projectile.ts";
import { stepEntity } from "../../shared/movement.ts";
import { stepProjectile, PROJECTILE_SPEED, PROJECTILE_TTL_MS } from "../../shared/projectile.ts";
import { TICK_HZ, ARENA_W, ARENA_H } from "../../shared/constants.ts";

const TURRET_X = ARENA_W / 2;
const TURRET_Y = 8;
const TURRET_PERIOD_MS = 1600;

/**
 * Predicted spawns (Lab 09): a fire input spawns an authoritative projectile;
 * the client already spawned an optimistic local one the instant you clicked.
 * The turret provides FOREIGN projectiles (no local prediction to correlate).
 */
export class ProjectileRoom extends Room<{ state: ProjectileState; input: RangeInput }> {
  state = new ProjectileState();
  maxClients = 8;

  inputs = this.defineInput(RangeInput, {
    bufferMaxSize: 64,
    sanitize: {
      moveX: [-1, 1], moveY: [-1, 1],
      aimX: [0, ARENA_W], aimY: [0, ARENA_H],
    },
  });

  private joinCount = 0;
  private spawnSeq = 0;
  private bornAt = new Map<string, number>();
  private nextTurretAt = 0;

  onCreate() {
    this.setFixedTimestep((ctx) => this.step(ctx), TICK_HZ);
  }

  onJoin(client: Client) {
    const n = this.joinCount++;
    this.state.players.set(client.sessionId, new Player({
      x: ARENA_W / 2 + Math.cos(n * 2.399963) * 14,
      y: ARENA_H * 0.7 + Math.sin(n * 2.399963) * 6,
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

  private fire(owner: string, x: number, y: number, tx: number, ty: number): void {
    let dx = tx - x, dy = ty - y;
    const len = Math.sqrt(dx * dx + dy * dy);
    if (len < 1e-6) return;
    dx /= len; dy /= len;
    const id = `p${this.spawnSeq++}`;
    const born = this.clock.elapsedTime;
    this.state.projectiles.set(id, new Projectile({
      x, y,
      vx: dx * PROJECTILE_SPEED,
      vy: dy * PROJECTILE_SPEED,
      owner,
      bornMs: born,
    }));
    this.bornAt.set(id, born);
  }

  private step(ctx: StepContext) {
    for (const [sid, p] of this.state.players) {
      const channel = this.inputs.get(sid);
      if (!channel) continue;
      for (const inp of channel as Iterable<Data<RangeInput>>) {
        stepEntity(p, inp, ctx.dt);
        if (inp.fire) this.fire(sid, p.x, p.y, inp.aimX, inp.aimY);
      }
    }

    const elapsed = this.clock.elapsedTime;

    // The turret fires at the nearest player — FOREIGN projectiles.
    if (elapsed >= this.nextTurretAt && this.state.players.size > 0) {
      this.nextTurretAt = elapsed + TURRET_PERIOD_MS;
      let best: Player | null = null;
      let bestD = Infinity;
      for (const [, p] of this.state.players) {
        const d = (p.x - TURRET_X) ** 2 + (p.y - TURRET_Y) ** 2;
        if (d < bestD) { bestD = d; best = p; }
      }
      if (best) this.fire("turret", TURRET_X, TURRET_Y, best.x, best.y);
    }

    for (const [id, pr] of this.state.projectiles) {
      stepProjectile(pr, ctx.dt);
      if (elapsed - (this.bornAt.get(id) ?? 0) > PROJECTILE_TTL_MS) {
        this.state.projectiles.delete(id);
        this.bornAt.delete(id);
      }
    }
  }
}
