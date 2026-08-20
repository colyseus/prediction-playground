import type { Client, InputHandle } from "@colyseus/sdk";
import { Predict, type Reconciler } from "@colyseus/sdk/predict";
import { joinLab } from "../../framework/net.ts";
import { stepEntity } from "../../../shared/movement.ts";
import { stepProjectile } from "../../../shared/projectile.ts";
import { ProjectileState, type RangeInput, type Player } from "../../../server/schema/projectile.ts";

/** The predicted-local projectile shape (what we spawn before the server knows). */
export interface LocalProjectile { x: number; y: number; vx: number; vy: number; }

/**
 * Lab 09 — predicted spawns: click-to-fire feels instant because the client
 * spawns an OPTIMISTIC local projectile the same frame; when the server's
 * authoritative entity arrives (~RTT later) the store CORRELATES the two into
 * one logical entry — same id, same sprite, no visual seam.
 *
 *   owned     — which server entities are mine to correlate (owner === me).
 *               Foreign ones (the turret's) surface as server-only entries.
 *   spawnTime — measures each shot's exact input lead (bornMs − predictedAt),
 *               so MY projectile keeps flying the shooter's timeline through
 *               the handoff instead of snapping back by lead × velocity.
 *   step      — the SAME shared flight function the server integrates;
 *               pending locals and confirmed entities both step through it.
 */
export async function connect(client: Client) {
  const room = await joinLab<ProjectileState>(client, "lab-projectile", ProjectileState);

  const predict = Predict.get(room, { name: "projectiles" });
  predict.attachAll("players", { mode: "damped", fields: ["x", "y"] });

  const projectiles = predict.spawns("projectiles", {
    owned: (p) => p.owner === room.sessionId,
    spawnTime: (p) => p.bornMs,
    step: stepProjectile,
    fields: ["x", "y"],
  });

  const input = room.input<RangeInput>({ mode: "reliable" });
  return { room, predict, projectiles, input };
}

export function makeReconciler(
  predict: Predict<ProjectileState>,
  self: Player,
  input: InputHandle<RangeInput>,
): Reconciler<Player, any> {
  return predict.reconciler(self, {
    input,
    fields: ["x", "y", "vx", "vy"],
    smoothMs: 65,
    step: (ctx, p, inp) => stepEntity(p, inp, ctx.dt),
  });
}
