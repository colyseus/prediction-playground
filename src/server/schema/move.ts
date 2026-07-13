import { schema, t, type SchemaType } from "@colyseus/schema";

/**
 * Per-client input frame consumed by `Room.defineInput()`. Flat primitives
 * only. No `seq` (the engine's input counter is the sequence), no `dt` (fixed
 * timestep — one input advances exactly one shared tick on both sides), no
 * `renderTime` (the SDK stamps lag-comp timestamps on the wire envelope).
 */
export const MoveInput = schema({
  moveX: t.int8<-1 | 0 | 1>(),
  moveY: t.int8<-1 | 0 | 1>(),
});
export type MoveInput = SchemaType<typeof MoveInput>;

export const Player = schema({
  x: t.number(),
  y: t.number(),
  vx: t.number(),
  vy: t.number(),
  /** Render color (assigned by the server on join). */
  hue: t.uint8(),
});
export type Player = SchemaType<typeof Player>;

export const MoveState = schema({
  players: t.map(Player),
});
export type MoveState = SchemaType<typeof MoveState>;
