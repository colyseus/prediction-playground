import 'dart:math' as math;

import 'constants.dart';
import 'movement.dart';

/// Post-bump immunity (fixed steps) — a RECONCILED tick gate: both sides run
/// the identical countdown, so "can I be bumped?" is never a misprediction.
const int bumpCooldownTicks = 12;
const double bumpSpeed = 48.0;

/// Just the immunity counter, so [stepBumpGate] can run over anything carrying
/// one.
abstract class BumpGateState {
  int get bumpTicks;
  set bumpTicks(int value);
}

/// A body that can be knocked back.
abstract class BumpableState implements EntityState, BumpGateState {}

/// Per-step cooldown countdown — run BEFORE the movement step on both sides.
void stepBumpGate(BumpGateState p) {
  if (p.bumpTicks > 0) p.bumpTicks--;
}

/// Player-vs-bot bump test at an agreed bot position. Returns the knockback
/// velocity, or null.
///
/// The caller applies it AND re-arms `bumpTicks` — on the client that happens
/// inside the reconciler step so the whole outcome (velocity + immunity window)
/// rides adopt+replay.
({double vx, double vy})? collideBot(
  BumpableState p,
  double botX,
  double botY,
) {
  if (p.bumpTicks > 0) return null;
  final dx = p.x - botX, dy = p.y - botY;
  const r = playerHalf + botRadius;
  final d2 = dx * dx + dy * dy;
  if (d2 >= r * r) return null;
  var d = math.sqrt(d2);
  if (d == 0) d = 1e-6; // JS `|| 1e-6`
  return (vx: (dx / d) * bumpSpeed, vy: (dy / d) * bumpSpeed);
}
