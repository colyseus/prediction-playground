import 'dart:math' as math;

/// 2D hitscan: ray vs circle.
///
/// Returns the ray parameter t (distance along the unit direction) of the
/// nearest intersection, or -1 on a miss. Pure math — shared so client-side
/// shot preview and server-side resolution can't drift.
double rayCircle(
  double ox,
  double oy,
  double dx,
  double dy,
  double cx,
  double cy,
  double r,
  double maxDist,
) {
  final mx = ox - cx, my = oy - cy;
  final b = mx * dx + my * dy;
  final c = mx * mx + my * my - r * r;
  if (c > 0 && b > 0) return -1; // outside, pointing away
  final disc = b * b - c;
  if (disc < 0) return -1;
  final t = -b - math.sqrt(disc);
  final hit = t < 0 ? 0.0 : t; // inside the circle counts as t=0
  return hit <= maxDist ? hit : -1;
}
