import { schema, t, type SchemaType } from "@colyseus/schema";
import { Player } from "./move.ts";
import { RangeInput } from "./range.ts";

export { Player, RangeInput };

export const Projectile = schema({
  x: t.number(),
  y: t.number(),
  vx: t.number(),
  vy: t.number(),
  /** Session id of the shooter ("turret" for the bot). */
  owner: t.string(),
  /** Server-clock spawn instant — the client's spawns store measures each
   *  shot's exact input lead from it (`spawnTime: r => r.bornMs`). */
  bornMs: t.number(),
}, "Projectile");
export type Projectile = SchemaType<typeof Projectile>;

export const ProjectileState = schema({
  players: t.map(Player),
  projectiles: t.map(Projectile),
});
export type ProjectileState = SchemaType<typeof ProjectileState>;
