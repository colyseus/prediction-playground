import 'dart:math' as math;

import 'constants.dart';
import 'movement.dart';

const double paddleRadius = 2.2;
const double puckRadius = 1.4;

/// Per-tick puck damping (dt is fixed — a literal constant, no `exp()`).
const double puckFrictionK = 0.985;
const double puckRestitution = 0.92;
const double puckPushMin = 14.0;

/// TS declares its own `CircleBody` structural type; it is field-for-field
/// [EntityState], so Dart aliases it rather than duplicating the interface.
typedef CircleBody = EntityState;

/// Session id of the server-driven paddle. Shared so the client can single it
/// out of the players map and predict it (see [botTarget]).
const String botId = 'bot';

/// The bot's steering target. A DECISION the server owns, but a pure function of
/// synced state — the puck it chases and [botEnabled] — so a predicting client
/// can derive it exactly.
///
/// That is what makes the bot predictable and a human opponent not: a human's
/// next input is unknowable until it arrives, whereas this is just arithmetic
/// both sides can run. Freezing the bot at its last snapshot inside the
/// predicted step is what makes every bot-puck contact mispredict, and the bot
/// is in contact often because chasing the puck is its whole policy.
({double x, double y}) botTarget(CircleBody puck, bool botEnabled) {
  final chase = botEnabled && puck.y < arenaH / 2;
  return chase ? (x: puck.x, y: puck.y) : (x: arenaW / 2, y: arenaH * 0.2);
}

/// Quantize the bot's steering target into the same -1/0/1 move input a human
/// sends, so both sides drive it through the identical `stepEntity`.
void botInput(
  CircleBody bot,
  CircleBody puck,
  bool botEnabled,
  MoveInputLike out,
) {
  final t = botTarget(puck, botEnabled);
  out.moveX = t.x - bot.x > 1 ? 1 : (t.x - bot.x < -1 ? -1 : 0);
  out.moveY = t.y - bot.y > 1 ? 1 : (t.y - bot.y < -1 ? -1 : 0);
}

/// Puck free flight: integrate, bounce off the arena walls, bleed speed.
void stepPuck(CircleBody puck, double dt) {
  puck.vx *= puckFrictionK;
  puck.vy *= puckFrictionK;
  puck.x += puck.vx * dt;
  puck.y += puck.vy * dt;
  const min = puckRadius,
      maxX = arenaW - puckRadius,
      maxY = arenaH - puckRadius;
  if (puck.x < min) {
    puck.x = min;
    puck.vx = puck.vx.abs() * puckRestitution;
  } else if (puck.x > maxX) {
    puck.x = maxX;
    puck.vx = -puck.vx.abs() * puckRestitution;
  }
  if (puck.y < min) {
    puck.y = min;
    puck.vy = puck.vy.abs() * puckRestitution;
  } else if (puck.y > maxY) {
    puck.y = maxY;
    puck.vy = -puck.vy.abs() * puckRestitution;
  }
}

/// Paddle-puck contact: push the puck out of penetration along the contact
/// normal and give it the paddle's velocity plus a minimum separation speed.
///
/// The push-out then resolves against the arena walls (same rule as
/// [stepPuck]), so a puck squeezed between a paddle and a wall stays inside the
/// arena instead of being ejected past it.
///
/// Deterministic (sqrt/mul/add only) and order-dependent — BOTH sides must
/// resolve paddles in the same order (the players-map iteration order).
bool collidePaddlePuck(CircleBody paddle, CircleBody puck) {
  final dx = puck.x - paddle.x, dy = puck.y - paddle.y;
  const r = paddleRadius + puckRadius;
  final d2 = dx * dx + dy * dy;
  if (d2 >= r * r) return false;
  var d = math.sqrt(d2);
  if (d == 0) d = 1e-6; // JS `|| 1e-6`
  final nx = dx / d, ny = dy / d;
  puck.x = paddle.x + nx * r;
  puck.y = paddle.y + ny * r;
  // Outgoing speed: at least puckPushMin along the normal, plus whatever the
  // paddle carries into the contact.
  final paddleAlong = paddle.vx * nx + paddle.vy * ny;
  final speed = paddleAlong > puckPushMin ? paddleAlong : puckPushMin;
  puck.vx = nx * speed + paddle.vx * 0.35;
  puck.vy = ny * speed + paddle.vy * 0.35;
  const min = puckRadius,
      maxX = arenaW - puckRadius,
      maxY = arenaH - puckRadius;
  if (puck.x < min) {
    puck.x = min;
    puck.vx = puck.vx.abs() * puckRestitution;
  } else if (puck.x > maxX) {
    puck.x = maxX;
    puck.vx = -puck.vx.abs() * puckRestitution;
  }
  if (puck.y < min) {
    puck.y = min;
    puck.vy = puck.vy.abs() * puckRestitution;
  } else if (puck.y > maxY) {
    puck.y = maxY;
    puck.vy = -puck.vy.abs() * puckRestitution;
  }
  return true;
}
