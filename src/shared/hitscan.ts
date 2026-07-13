/**
 * 2D hitscan: ray vs circle. Returns the ray parameter t (distance along the
 * unit direction) of the nearest intersection, or -1 on a miss. Pure math —
 * shared so client-side shot preview and server-side resolution can't drift.
 */
export function rayCircle(
  ox: number, oy: number,
  dx: number, dy: number,
  cx: number, cy: number,
  r: number,
  maxDist: number,
): number {
  const mx = ox - cx, my = oy - cy;
  const b = mx * dx + my * dy;
  const c = mx * mx + my * my - r * r;
  if (c > 0 && b > 0) return -1;          // outside, pointing away
  const disc = b * b - c;
  if (disc < 0) return -1;
  const t = -b - Math.sqrt(disc);
  const hit = t < 0 ? 0 : t;              // inside the circle counts as t=0
  return hit <= maxDist ? hit : -1;
}
