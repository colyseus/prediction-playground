import 'dart:math' as math;

import 'constants.dart';

/// Teleporter warp period (ms, on the shared server-clock timeline).
const double teleportPeriodMs = 3000.0;

/// Wander bots pick a new (server-secret) heading this often.
const double wanderTurnMs = 900.0;

/// The `kind` strings [stepBot] dispatches on. Anything unrecognized patrols.
abstract final class BotKind {
  static const String patrol = 'patrol';
  static const String circle = 'circle';
  static const String wander = 'wander';
  static const String teleport = 'teleport';
}

/// Structural bot state — satisfied by the server Schema instance AND the
/// client reckon scratch (a full copy of the entity, so non-attached fields
/// like `kind`/`minX` are readable here).
///
/// Only the fields the step MUTATES declare a setter; the tuning fields are
/// read-only so a cheap projection over decoded state can implement this.
abstract class BotState {
  double get x;
  set x(double value);
  double get y;
  set y(double value);
  double get vx;
  set vx(double value);
  double get vy;
  set vy(double value);
  String get kind;
  double get minX;
  double get maxX;
  double get baseY;
  double get phaseMs;
  double get speed;

  /// Teleporter: server-clock ms of the last warp (synced, drives prediction).
  double get lastTeleport;
  set lastTeleport(double value);
}

/// The shared bot step: run by the server each fixed tick AND by the client's
/// reckon mode to forward-simulate the bot from the latest snapshot to the
/// present.
///
/// [elapsedMs] is the shared server-clock timeline (server: `clock.elapsedTime`;
/// client: `serverNow()`/`renderNow()`), which makes time-sampled motion
/// (circle, teleport schedule) evaluable at ANY instant.
///
/// `wander` is deliberately only PARTLY predictable: it integrates velocity,
/// but the heading changes are a server-side secret — dead reckoning
/// extrapolates straight through every turn and gets corrected. That error is
/// the lesson, not a bug.
///
/// [kindOverride] exists for reckon scratches that carry scalar fields only:
/// pass the kind read off freshly decoded state instead of the scratch's empty
/// one.
///
/// One caveat, shared with the C and GDScript ports: `circle` is the only step
/// that is not bit-identical to the server. `dart:math`'s sin/cos are the
/// platform libm, and V8's differ from libm by up to 2 ULP — sampled over
/// random states the divergence never exceeds that. Everything else here is
/// exact.
void stepBot(BotState b, double dt, double elapsedMs, {String? kindOverride}) {
  final kind = (kindOverride != null && kindOverride.isNotEmpty)
      ? kindOverride
      : b.kind;
  switch (kind) {
    case BotKind.circle:
      final cx = (b.minX + b.maxX) / 2;
      final rx = (b.maxX - b.minX) / 2;
      final ry = math.min(12.0, arenaH / 2 - botRadius - 2);
      final w = b.speed / rx; // rad/s
      final t = (elapsedMs + b.phaseMs) / 1000;
      b.x = cx + rx * math.cos(w * t);
      b.y = b.baseY + ry * math.sin(w * t);
      b.vx = -rx * w * math.sin(w * t);
      b.vy = ry * w * math.cos(w * t);
      return;

    case BotKind.teleport:
      _patrol(b, dt);
      // Predict the warp from the synced schedule: jump half the patrol span
      // (wrapping) every teleportPeriodMs — a constant, always-visible cut.
      // Client scratch mutations only persist within one forward pass —
      // exactly right (multiple periods chain).
      while (b.lastTeleport > 0 &&
          elapsedMs - b.lastTeleport >= teleportPeriodMs) {
        final span = b.maxX - b.minX;
        // `remainder`, not `%`: JS/C truncate toward zero, Dart's `%` is
        // Euclidean.
        b.x = b.minX + ((b.x - b.minX) + span / 2).remainder(span);
        b.lastTeleport += teleportPeriodMs;
      }
      return;

    case BotKind.wander:
      b.x += b.vx * dt;
      b.y += b.vy * dt;
      // Reflect off the arena bounds (deterministic on both sides).
      const min = botRadius,
          maxX = arenaW - botRadius,
          maxY = arenaH - botRadius;
      if (b.x < min) {
        b.x = min;
        b.vx = b.vx.abs();
      } else if (b.x > maxX) {
        b.x = maxX;
        b.vx = -b.vx.abs();
      }
      if (b.y < min) {
        b.y = min;
        b.vy = b.vy.abs();
      } else if (b.y > maxY) {
        b.y = maxY;
        b.vy = -b.vy.abs();
      }
      return;

    default:
      _patrol(b, dt);
  }
}

/// Horizontal ping-pong between minX and maxX at |vx| = speed.
void _patrol(BotState b, double dt) {
  b.x += b.vx * dt;
  b.y = b.baseY;
  if (b.x < b.minX) {
    b.x = b.minX;
    b.vx = b.vx.abs();
  } else if (b.x > b.maxX) {
    b.x = b.maxX;
    b.vx = -b.vx.abs();
  }
}
