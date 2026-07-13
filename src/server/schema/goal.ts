import { schema, t, type SchemaType } from "@colyseus/schema";
import { MoveInput } from "./move.ts";

export { MoveInput };

export const GoalPlayer = schema({
  x: t.number(),
  y: t.number(),
  vx: t.number(),
  vy: t.number(),
  hue: t.uint8(),
  score: t.uint16().default(0),
  /** Zone re-entry lockout — SYNCED reconciled tick state (shared stepScoreGate). */
  scoreTicks: t.uint8().default(0),
});
export type GoalPlayer = SchemaType<typeof GoalPlayer>;

export const GoalState = schema({
  players: t.map(GoalPlayer),
  /** Percent of goals the server DENIES (manufactures rejections for the lab). */
  denyRate: t.uint8().default(0),
});
export type GoalState = SchemaType<typeof GoalState>;
