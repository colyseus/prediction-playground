import { schema, t, type SchemaType } from "@colyseus/schema";
import { MoveInput, Player } from "./move.ts";

export { MoveInput, Player };

export const Bot = schema({
  x: t.number(),
  y: t.number(),
  vx: t.number(),
  vy: t.number(),
  /** "patrol" | "circle" | "wander" | "teleport" (shared/movers.ts). */
  kind: t.string(),
  minX: t.number(),
  maxX: t.number(),
  baseY: t.number(),
  phaseMs: t.number(),
  speed: t.number(),
  /** Teleporter warp schedule anchor — synced so clients predict the warp. */
  lastTeleport: t.number().default(0),
}, "Bot");
export type Bot = SchemaType<typeof Bot>;

export const BotsState = schema({
  players: t.map(Player),
  bots: t.map(Bot),
});
export type BotsState = SchemaType<typeof BotsState>;
