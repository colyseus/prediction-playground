import { mulberry32, shotSeed } from "./random.ts";

export const PELLETS = 6;
export const SPREAD_RAD = 0.38;

/**
 * The shotgun fan — SAME derivation on both sides, nothing random on the
 * wire: the seed is (input seq, synced per-room salt), so client and server
 * roll identical pellets for the same shot. The FPS demo's weapon-spread
 * pattern, minimized.
 */
export function spreadAngles(baseAngle: number, seq: number, salt: number, out: number[]): number[] {
  const rng = mulberry32(shotSeed(seq, salt));
  for (let i = 0; i < PELLETS; i++) {
    out[i] = baseAngle + (rng() - 0.5) * SPREAD_RAD;
  }
  out.length = PELLETS;
  return out;
}
