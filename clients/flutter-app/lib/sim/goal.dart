import 'constants.dart';

/// The goal zone: a strip on the right edge of the arena.
///
/// TS exports these as one `GOAL_ZONE` object literal; Dart splits them into
/// four compile-time constants so they stay usable in `const` contexts.
const double goalZoneX = arenaW - 8.0;
const double goalZoneY = arenaH / 2 - 9.0;
const double goalZoneW = 8.0;
const double goalZoneH = 18.0;

/// Re-entry lockout (fixed steps) — reconciled tick state on both sides.
const int scoreCooldownTicks = 50;

/// What the scoring gate reads and writes.
abstract class ScorerState {
  double get x;
  double get y;
  int get scoreTicks;
  set scoreTicks(int value);
}

/// The scoring gate, run once per input step on BOTH sides.
///
/// Pure function of predicted state — deterministic under rollback replay.
/// Returns true on the entry EDGE (the step that crossed into the zone with the
/// gate open). Whether the goal is AWARDED stays server-only (the deny roll) —
/// the gate itself never mispredicts.
bool stepScoreGate(ScorerState p) {
  if (p.scoreTicks > 0) {
    p.scoreTicks--;
    return false;
  }
  if (p.x >= goalZoneX && p.y >= goalZoneY && p.y <= goalZoneY + goalZoneH) {
    p.scoreTicks = scoreCooldownTicks;
    return true;
  }
  return false;
}
