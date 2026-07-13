import { ARENA_W, ARENA_H } from "./constants.ts";

export const PROJECTILE_SPEED = 34;
export const PROJECTILE_TTL_MS = 2600;
export const PROJECTILE_RADIUS = 0.7;

export interface ProjectileLike { x: number; y: number; vx: number; vy: number; }

/**
 * Constant-velocity flight with wall bounces — shared by the server
 * integrator AND the client's predicted/reckoned flight (pending locals and
 * confirmed entities step through the same function).
 */
export function stepProjectile(p: ProjectileLike, dt: number): void {
  p.x += p.vx * dt;
  p.y += p.vy * dt;
  if (p.x < 0) { p.x = 0; p.vx = Math.abs(p.vx); }
  else if (p.x > ARENA_W) { p.x = ARENA_W; p.vx = -Math.abs(p.vx); }
  if (p.y < 0) { p.y = 0; p.vy = Math.abs(p.vy); }
  else if (p.y > ARENA_H) { p.y = ARENA_H; p.vy = -Math.abs(p.vy); }
}
