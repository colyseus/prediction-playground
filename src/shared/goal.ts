import { ARENA_W, ARENA_H } from "./constants.ts";

/** The goal zone: a strip on the right edge of the arena. */
export const GOAL_ZONE = { x: ARENA_W - 8, y: ARENA_H / 2 - 9, w: 8, h: 18 };

/** Re-entry lockout (fixed steps) — reconciled tick state on both sides. */
export const SCORE_COOLDOWN_TICKS = 50;

export interface ScorerState { x: number; y: number; scoreTicks: number; }

/**
 * The scoring gate, run once per input step on BOTH sides. Pure function of
 * predicted state — deterministic under rollback replay. Returns true on the
 * entry EDGE (the step that crossed into the zone with the gate open).
 * Whether the goal is AWARDED stays server-only (the deny roll) — the gate
 * itself never mispredicts.
 */
export function stepScoreGate(p: ScorerState): boolean {
  if (p.scoreTicks > 0) { p.scoreTicks--; return false; }
  if (p.x >= GOAL_ZONE.x && p.y >= GOAL_ZONE.y && p.y <= GOAL_ZONE.y + GOAL_ZONE.h) {
    p.scoreTicks = SCORE_COOLDOWN_TICKS;
    return true;
  }
  return false;
}
