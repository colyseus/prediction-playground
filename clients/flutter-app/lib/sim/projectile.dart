import 'constants.dart';
import 'movement.dart';

const double projectileSpeed = 34.0;
const double projectileTtlMs = 2600.0;
const double projectileRadius = 0.7;

/// TS declares its own `ProjectileLike` structural type; it is field-for-field
/// [EntityState], so Dart aliases it rather than duplicating the interface.
typedef ProjectileLike = EntityState;

/// Constant-velocity flight with wall bounces — shared by the server
/// integrator AND the client's predicted/reckoned flight (pending locals and
/// confirmed entities step through the same function).
void stepProjectile(ProjectileLike p, double dt) {
  p.x += p.vx * dt;
  p.y += p.vy * dt;
  if (p.x < 0) {
    p.x = 0;
    p.vx = p.vx.abs();
  } else if (p.x > arenaW) {
    p.x = arenaW;
    p.vx = -p.vx.abs();
  }
  if (p.y < 0) {
    p.y = 0;
    p.vy = p.vy.abs();
  } else if (p.y > arenaH) {
    p.y = arenaH;
    p.vy = -p.vy.abs();
  }
}
