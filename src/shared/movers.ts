import { ARENA_W, ARENA_H, BOT_RADIUS } from "./constants.ts";

/** Teleporter warp period (ms, on the shared server-clock timeline). */
export const TELEPORT_PERIOD_MS = 3000;
/** Wander bots pick a new (server-secret) heading this often. */
export const WANDER_TURN_MS = 900;

export type BotKind = "patrol" | "circle" | "wander" | "teleport";

/**
 * Structural bot state — satisfied by the server Schema instance AND the
 * client reckon scratch (a full copy of the entity, so non-attached fields
 * like `kind`/`minX` are readable here).
 */
export interface BotState {
  x: number; y: number;
  vx: number; vy: number;
  kind: string;
  minX: number; maxX: number;
  baseY: number;
  phaseMs: number;
  speed: number;
  /** Teleporter: server-clock ms of the last warp (synced, drives prediction). */
  lastTeleport: number;
}

/**
 * The shared bot step: run by the server each fixed tick AND by the client's
 * reckon mode to forward-simulate the bot from the latest snapshot to the
 * present. `elapsedMs` is the shared server-clock timeline (server:
 * `clock.elapsedTime`; client: `serverNow()`/`renderNow()`), which makes
 * time-sampled motion (circle, teleport schedule) evaluable at ANY instant.
 *
 * "wander" is deliberately only PARTLY predictable: it integrates velocity,
 * but the heading changes are a server-side secret — dead reckoning
 * extrapolates straight through every turn and gets corrected. That error is
 * the lesson, not a bug.
 */
export function stepBot(b: BotState, dt: number, elapsedMs: number): void {
  switch (b.kind) {
    case "circle": {
      const cx = (b.minX + b.maxX) / 2;
      const rx = (b.maxX - b.minX) / 2;
      const ry = Math.min(12, ARENA_H / 2 - BOT_RADIUS - 2);
      const w = b.speed / rx; // rad/s
      const t = (elapsedMs + b.phaseMs) / 1000;
      b.x = cx + rx * Math.cos(w * t);
      b.y = b.baseY + ry * Math.sin(w * t);
      b.vx = -rx * w * Math.sin(w * t);
      b.vy = ry * w * Math.cos(w * t);
      return;
    }
    case "teleport": {
      patrol(b, dt);
      // Predict the warp from the synced schedule: jump half the patrol span
      // (wrapping) every TELEPORT_PERIOD_MS — a constant, always-visible cut.
      // Client scratch mutations only persist within one forward pass —
      // exactly right (multiple periods chain).
      while (b.lastTeleport > 0 && elapsedMs - b.lastTeleport >= TELEPORT_PERIOD_MS) {
        const span = b.maxX - b.minX;
        b.x = b.minX + (((b.x - b.minX) + span / 2) % span);
        b.lastTeleport += TELEPORT_PERIOD_MS;
      }
      return;
    }
    case "wander": {
      b.x += b.vx * dt;
      b.y += b.vy * dt;
      // Reflect off the arena bounds (deterministic on both sides).
      const min = BOT_RADIUS, maxX = ARENA_W - BOT_RADIUS, maxY = ARENA_H - BOT_RADIUS;
      if (b.x < min) { b.x = min; b.vx = Math.abs(b.vx); }
      else if (b.x > maxX) { b.x = maxX; b.vx = -Math.abs(b.vx); }
      if (b.y < min) { b.y = min; b.vy = Math.abs(b.vy); }
      else if (b.y > maxY) { b.y = maxY; b.vy = -Math.abs(b.vy); }
      return;
    }
    default:
      patrol(b, dt);
  }
}

/** Horizontal ping-pong between minX and maxX at |vx| = speed. */
function patrol(b: BotState, dt: number): void {
  b.x += b.vx * dt;
  b.y = b.baseY;
  if (b.x < b.minX) { b.x = b.minX; b.vx = Math.abs(b.vx); }
  else if (b.x > b.maxX) { b.x = b.maxX; b.vx = -Math.abs(b.vx); }
}
