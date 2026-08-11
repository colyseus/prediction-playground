/// Deterministic off-wire RNG (Lab 11 pattern, lifted from the FPS demo's
/// weapon spread): both sides derive the SAME seed from (seq, salt) — the
/// stream itself never goes on the wire.
///
/// This is the one module that is NOT a straight f64 transliteration: JS runs
/// it on uint32 (`Math.imul`, `| 0`, `>>> 0`), so every operation here masks
/// back to 32 bits. Values stay in `[0, 2^32)`, which makes `>>` a logical
/// shift and keeps `int` non-negative throughout.
library;

/// `Math.imul` over two uint32 operands.
///
/// Splits one operand into 16-bit halves so no intermediate product exceeds
/// 2^49 — exact on the 64-bit VM and, unlike a full 32x32 product, still exact
/// when `int` is a JS double.
int imul32(int a, int b) {
  a &= 0xFFFFFFFF;
  b &= 0xFFFFFFFF;
  final alo = a & 0xFFFF;
  final ahi = a >> 16;
  return (alo * b + (((ahi * b) & 0xFFFF) << 16)) & 0xFFFFFFFF;
}

/// splitmix32 — one-shot avalanche of a 32-bit seed into a well-mixed word.
int splitmix32(int a) {
  a = ((a & 0xFFFFFFFF) + 0x9e3779b9) & 0xFFFFFFFF;
  var t = a ^ (a >> 16);
  t = imul32(t, 0x21f0aaad);
  t = t ^ (t >> 15);
  t = imul32(t, 0x735a2d97);
  return (t ^ (t >> 15)) & 0xFFFFFFFF;
}

/// mulberry32 — tiny seeded PRNG; returns a `() => [0,1)` stream.
///
/// The closure owns its state, exactly like the TypeScript original: two
/// streams built from the same seed produce the same sequence independently.
double Function() mulberry32(int seed) {
  var a = seed & 0xFFFFFFFF;
  return () {
    a = (a + 0x6d2b79f5) & 0xFFFFFFFF;
    var t = imul32(a ^ (a >> 15), 1 | a);
    t = ((t + imul32(t ^ (t >> 7), 61 | t)) ^ t) & 0xFFFFFFFF;
    return (t ^ (t >> 14)) / 4294967296.0;
  };
}

/// Per-shot seed from the input sequence + a synced per-round salt.
///
/// [salt] is a full uint32: room salts are uniform over the whole range, so
/// half of all real shots exceed 2^31.
int shotSeed(int seq, int salt) =>
    splitmix32((seq ^ imul32(salt, 0x85ebca6b)) & 0xFFFFFFFF);
