/**
 * Deterministic off-wire RNG (Lab 11 pattern, lifted from the FPS demo's
 * weapon spread): both sides derive the SAME seed from (seq, salt) — the
 * stream itself never goes on the wire.
 */

/** splitmix32 — one-shot avalanche of a 32-bit seed into a well-mixed word. */
export function splitmix32(a: number): number {
  a |= 0;
  a = (a + 0x9e3779b9) | 0;
  let t = a ^ (a >>> 16);
  t = Math.imul(t, 0x21f0aaad);
  t = t ^ (t >>> 15);
  t = Math.imul(t, 0x735a2d97);
  return (t ^ (t >>> 15)) >>> 0;
}

/** mulberry32 — tiny seeded PRNG; returns a () => [0,1) stream. */
export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Per-shot seed from the input sequence + a synced per-round salt. */
export function shotSeed(seq: number, salt: number): number {
  return splitmix32((seq ^ Math.imul(salt, 0x85ebca6b)) | 0);
}
