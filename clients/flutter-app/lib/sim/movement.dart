import 'dart:math' as math;

import 'constants.dart';

/// The four fields every moving body exposes. Declared as an interface (not a
/// concrete class) so the same step runs over a plain Dart object AND over an
/// SDK-backed view that reads/writes through the reconciler's storage — the
/// Dart stand-in for the TypeScript structural type.
abstract class EntityState {
  double get x;
  set x(double value);
  double get y;
  set y(double value);
  double get vx;
  set vx(double value);
  double get vy;
  set vy(double value);
}

/// One tick of intent, on the -1/0/1 axes the wire carries.
abstract class MoveInputLike {
  double get moveX;
  set moveX(double value);
  double get moveY;
  set moveY(double value);
}

/// A plain, reusable [MoveInputLike]. Mutate and re-submit rather than
/// allocating one per replayed step.
class MoveInput implements MoveInputLike {
  @override
  double moveX;
  @override
  double moveY;

  MoveInput([this.moveX = 0.0, this.moveY = 0.0]);
}

/// The single deterministic movement step, run identically by the server (once
/// per received input) and the client reconciler (predict + rollback replay).
///
/// Pure function of (state, input, dt): no clocks, no RNG, no reads outside its
/// arguments. sqrt/mul/add only — cross-engine determinism.
void stepEntity(EntityState e, MoveInputLike inp, double dt) {
  var ax = inp.moveX;
  var ay = inp.moveY;
  if (ax != 0 && ay != 0) {
    ax *= sqrtHalf;
    ay *= sqrtHalf;
  }

  if (ax != 0 || ay != 0) {
    e.vx += ax * playerAccel * dt;
    e.vy += ay * playerAccel * dt;
  } else {
    e.vx *= playerFrictionK;
    e.vy *= playerFrictionK;
    if (e.vx > -0.05 && e.vx < 0.05) e.vx = 0;
    if (e.vy > -0.05 && e.vy < 0.05) e.vy = 0;
  }

  final sq = e.vx * e.vx + e.vy * e.vy;
  if (sq > playerMaxSpeed * playerMaxSpeed) {
    final s = playerMaxSpeed / math.sqrt(sq);
    e.vx *= s;
    e.vy *= s;
  }

  e.x += e.vx * dt;
  e.y += e.vy * dt;

  // Arena walls: clamp + kill the outward velocity component.
  const minX = playerHalf, maxX = arenaW - playerHalf;
  const minY = playerHalf, maxY = arenaH - playerHalf;
  if (e.x < minX) {
    e.x = minX;
    if (e.vx < 0) e.vx = 0;
  } else if (e.x > maxX) {
    e.x = maxX;
    if (e.vx > 0) e.vx = 0;
  }
  if (e.y < minY) {
    e.y = minY;
    if (e.vy < 0) e.vy = 0;
  } else if (e.y > maxY) {
    e.y = maxY;
    if (e.vy > 0) e.vy = 0;
  }
}
