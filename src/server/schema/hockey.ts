import { schema, t, type SchemaType } from "@colyseus/schema";
import { MoveInput, Player } from "./move.ts";

export { MoveInput, Player };

export const Puck = schema({
  x: t.number(),
  y: t.number(),
  vx: t.number(),
  vy: t.number(),
}, "Puck");
export type Puck = SchemaType<typeof Puck>;

export const HockeyState = schema({
  players: t.map(Player),
  puck: Puck,
  /** The AI paddle chases the puck when enabled (contested-touch demos). */
  botEnabled: t.boolean().default(true),
});
export type HockeyState = SchemaType<typeof HockeyState>;
