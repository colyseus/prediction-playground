import { PLAYER_HALF, BOT_RADIUS } from "./constants.ts";

/** Post-bump immunity (fixed steps) — a RECONCILED tick gate: both sides run
 *  the identical countdown, so "can I be bumped?" is never a misprediction. */
export const BUMP_COOLDOWN_TICKS = 12;
export const BUMP_SPEED = 48;

export interface BumpableState { x: number; y: number; vx: number; vy: number; bumpTicks: number; }

/** Per-step cooldown countdown — run BEFORE the movement step on both sides. */
export function stepBumpGate(p: { bumpTicks: number }): void {
  if (p.bumpTicks > 0) p.bumpTicks--;
}

/**
 * Player-vs-bot bump test at an agreed bot position. Returns the knockback
 * velocity, or null. The caller applies it AND re-arms `bumpTicks` — on the
 * client that happens inside the reconciler step so the whole outcome
 * (velocity + immunity window) rides adopt+replay.
 */
export function collideBot(
  p: BumpableState,
  botX: number,
  botY: number,
): { vx: number; vy: number } | null {
  if (p.bumpTicks > 0) return null;
  const dx = p.x - botX, dy = p.y - botY;
  const r = PLAYER_HALF + BOT_RADIUS;
  const d2 = dx * dx + dy * dy;
  if (d2 >= r * r) return null;
  const d = Math.sqrt(d2) || 1e-6;
  return { vx: (dx / d) * BUMP_SPEED, vy: (dy / d) * BUMP_SPEED };
}
