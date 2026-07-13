import { ARENA_W, ARENA_H } from "./constants.ts";

export const PADDLE_RADIUS = 2.2;
export const PUCK_RADIUS = 1.4;
/** Per-tick puck damping (dt is fixed — a literal constant, no Math.exp). */
export const PUCK_FRICTION_K = 0.985;
export const PUCK_RESTITUTION = 0.92;
export const PUCK_PUSH_MIN = 14;

export interface CircleBody { x: number; y: number; vx: number; vy: number; }

/** Puck free flight: integrate, bounce off the arena walls, bleed speed. */
export function stepPuck(puck: CircleBody, dt: number): void {
  puck.vx *= PUCK_FRICTION_K;
  puck.vy *= PUCK_FRICTION_K;
  puck.x += puck.vx * dt;
  puck.y += puck.vy * dt;
  const min = PUCK_RADIUS, maxX = ARENA_W - PUCK_RADIUS, maxY = ARENA_H - PUCK_RADIUS;
  if (puck.x < min) { puck.x = min; puck.vx = Math.abs(puck.vx) * PUCK_RESTITUTION; }
  else if (puck.x > maxX) { puck.x = maxX; puck.vx = -Math.abs(puck.vx) * PUCK_RESTITUTION; }
  if (puck.y < min) { puck.y = min; puck.vy = Math.abs(puck.vy) * PUCK_RESTITUTION; }
  else if (puck.y > maxY) { puck.y = maxY; puck.vy = -Math.abs(puck.vy) * PUCK_RESTITUTION; }
}

/**
 * Paddle↔puck contact: push the puck out of penetration along the contact
 * normal and give it the paddle's velocity plus a minimum separation speed.
 * Deterministic (sqrt/mul/add only) and order-dependent — BOTH sides must
 * resolve paddles in the same order (the players-map iteration order).
 */
export function collidePaddlePuck(paddle: CircleBody, puck: CircleBody): boolean {
  const dx = puck.x - paddle.x, dy = puck.y - paddle.y;
  const r = PADDLE_RADIUS + PUCK_RADIUS;
  const d2 = dx * dx + dy * dy;
  if (d2 >= r * r) return false;
  const d = Math.sqrt(d2) || 1e-6;
  const nx = dx / d, ny = dy / d;
  puck.x = paddle.x + nx * r;
  puck.y = paddle.y + ny * r;
  // Outgoing speed: at least PUCK_PUSH_MIN along the normal, plus whatever
  // the paddle carries into the contact.
  const paddleAlong = paddle.vx * nx + paddle.vy * ny;
  const speed = paddleAlong > PUCK_PUSH_MIN ? paddleAlong : PUCK_PUSH_MIN;
  puck.vx = nx * speed + paddle.vx * 0.35;
  puck.vy = ny * speed + paddle.vy * 0.35;
  return true;
}
