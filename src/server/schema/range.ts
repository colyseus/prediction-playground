import { schema, t, type SchemaType } from "@colyseus/schema";
import { Bot } from "./bots.ts";

export { Bot };

/**
 * Movement + aim + a fire EDGE in one flat input. The lag-comp render-time
 * stamp is NOT a field here — the SDK rides it on the wire envelope, and the
 * client's `allowRewind: (d) => d.fire` gates it to fire frames only.
 */
export const RangeInput = schema({
  moveX: t.int8<-1 | 0 | 1>(),
  moveY: t.int8<-1 | 0 | 1>(),
  aimX: t.float32(),
  aimY: t.float32(),
  fire: t.boolean(),
  /** Lab 11: fire a seeded shotgun fan instead of a single ray. */
  spread: t.boolean(),
});
export type RangeInput = SchemaType<typeof RangeInput>;

export const RangePlayer = schema({
  x: t.number(),
  y: t.number(),
  vx: t.number(),
  vy: t.number(),
  hue: t.uint8(),
  shots: t.uint16().default(0),
  hits: t.uint16().default(0),
});
export type RangePlayer = SchemaType<typeof RangePlayer>;

export const RangeState = schema({
  players: t.map(RangePlayer),
  bots: t.map(Bot),
  /** Room-wide lag-comp switch — synced so every client's toggle stays honest. */
  lagComp: t.boolean().default(true),
  /** Per-room spread salt (Lab 11): both sides seed pellet fans from
   *  (input seq, salt) — the pellet stream itself never rides the wire. */
  salt: t.uint32().default(0),
});
export type RangeState = SchemaType<typeof RangeState>;
