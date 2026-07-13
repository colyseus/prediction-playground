import { schema, t, type SchemaType } from "@colyseus/schema";
import { Bot } from "./bots.ts";
import { MoveInput } from "./move.ts";

export { Bot, MoveInput };

export const BumpPlayer = schema({
  x: t.number(),
  y: t.number(),
  vx: t.number(),
  vy: t.number(),
  hue: t.uint8(),
  /** Post-bump immunity countdown — SYNCED reconciled tick state. */
  bumpTicks: t.uint8().default(0),
  bumps: t.uint16().default(0),
});
export type BumpPlayer = SchemaType<typeof BumpPlayer>;

export const BumpState = schema({
  players: t.map(BumpPlayer),
  bots: t.map(Bot),
});
export type BumpState = SchemaType<typeof BumpState>;
