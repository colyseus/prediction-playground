import { ARENA_W, ARENA_H } from "./constants.ts";

export const PADDLE_RADIUS = 2.2;
export const PUCK_RADIUS = 1.4;
/** Per-tick puck damping (dt is fixed — a literal constant, no Math.exp). */
export const PUCK_FRICTION_K = 0.985;
export const PUCK_RESTITUTION = 0.92;
export const PUCK_PUSH_MIN = 14;

export interface CircleBody { x: number; y: number; vx: number; vy: number; }

/** Session id of the server-driven paddle. Shared so the client can single it
 *  out of the players map and predict it (see {@link botTarget}). */
export const BOT_ID = "bot";

/**
 * The bot's steering target. A DECISION the server owns, but a pure function of
 * synced state — the puck it chases and `botEnabled` — so a predicting client
 * can derive it exactly.
 *
 * That is what makes the bot predictable and a human opponent not: a human's
 * next input is unknowable until it arrives, whereas this is just arithmetic
 * both sides can run. Freezing the bot at its last snapshot inside the
 * predicted step is what makes every bot-puck contact mispredict, and the bot
 * is in contact often because chasing the puck is its whole policy.
 */
export function botTarget(puck: CircleBody, botEnabled: boolean): { x: number; y: number } {
  const chase = botEnabled && puck.y < ARENA_H / 2;
  return chase
    ? { x: puck.x, y: puck.y }
    : { x: ARENA_W / 2, y: ARENA_H * 0.2 };
}

/** Quantize the bot's steering target into the same -1/0/1 move input a human
 *  sends, so both sides drive it through the identical `stepEntity`. */
export function botInput(
  bot: CircleBody, puck: CircleBody, botEnabled: boolean,
  out: { moveX: number; moveY: number },
): void {
  const t = botTarget(puck, botEnabled);
  out.moveX = t.x - bot.x > 1 ? 1 : t.x - bot.x < -1 ? -1 : 0;
  out.moveY = t.y - bot.y > 1 ? 1 : t.y - bot.y < -1 ? -1 : 0;
}

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
