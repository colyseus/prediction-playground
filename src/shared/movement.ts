import {
  ARENA_W, ARENA_H, PLAYER_HALF,
  PLAYER_ACCEL, PLAYER_MAX_SPEED, PLAYER_FRICTION_K,
} from "./constants.ts";

/**
 * Structural types so the same step runs on a server Schema instance AND the
 * reconciler's plain predicted copy — no schema runtime in the shared sim.
 */
export interface EntityState { x: number; y: number; vx: number; vy: number; }
export interface MoveInputLike { moveX: number; moveY: number; }

/**
 * The single deterministic movement step, run identically by the server (once
 * per received input) and the client reconciler (predict + rollback replay).
 * Pure function of (state, input, dt): no clocks, no RNG, no reads outside its
 * arguments. sqrt/mul/add only — cross-engine determinism.
 */
export function stepEntity(e: EntityState, inp: MoveInputLike, dt: number): void {
  let ax = inp.moveX, ay = inp.moveY;
  if (ax !== 0 && ay !== 0) { ax *= Math.SQRT1_2; ay *= Math.SQRT1_2; }

  if (ax !== 0 || ay !== 0) {
    e.vx += ax * PLAYER_ACCEL * dt;
    e.vy += ay * PLAYER_ACCEL * dt;
  } else {
    e.vx *= PLAYER_FRICTION_K;
    e.vy *= PLAYER_FRICTION_K;
    if (e.vx > -0.05 && e.vx < 0.05) e.vx = 0;
    if (e.vy > -0.05 && e.vy < 0.05) e.vy = 0;
  }

  const sq = e.vx * e.vx + e.vy * e.vy;
  if (sq > PLAYER_MAX_SPEED * PLAYER_MAX_SPEED) {
    const s = PLAYER_MAX_SPEED / Math.sqrt(sq);
    e.vx *= s; e.vy *= s;
  }

  e.x += e.vx * dt;
  e.y += e.vy * dt;

  // Arena walls: clamp + kill the outward velocity component.
  const minX = PLAYER_HALF, maxX = ARENA_W - PLAYER_HALF;
  const minY = PLAYER_HALF, maxY = ARENA_H - PLAYER_HALF;
  if (e.x < minX) { e.x = minX; if (e.vx < 0) e.vx = 0; }
  else if (e.x > maxX) { e.x = maxX; if (e.vx > 0) e.vx = 0; }
  if (e.y < minY) { e.y = minY; if (e.vy < 0) e.vy = 0; }
  else if (e.y > maxY) { e.y = maxY; if (e.vy > 0) e.vy = 0; }
}
