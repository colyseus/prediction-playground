import { ARENA_W, ARENA_H } from "../../shared/constants.ts";

/**
 * World↔screen transform: the fixed logical arena (100×60 world units)
 * letterboxed into the canvas, in CSS pixels (the canvas context is
 * pre-scaled by devicePixelRatio in main.ts).
 */
export class WorldView {
  scale = 1;
  ox = 0;
  oy = 0;
  width = 0;
  height = 0;

  fit(cssW: number, cssH: number, margin = 28): void {
    this.width = cssW;
    this.height = cssH;
    this.scale = Math.min((cssW - margin * 2) / ARENA_W, (cssH - margin * 2) / ARENA_H);
    this.ox = (cssW - ARENA_W * this.scale) / 2;
    this.oy = (cssH - ARENA_H * this.scale) / 2;
  }

  sx(x: number): number { return this.ox + x * this.scale; }
  sy(y: number): number { return this.oy + y * this.scale; }
  s(len: number): number { return len * this.scale; }
  wx(px: number): number { return (px - this.ox) / this.scale; }
  wy(py: number): number { return (py - this.oy) / this.scale; }
}

/** Player color from the server-assigned hue byte. */
export function hueColor(hue: number, alpha = 1, light = 62): string {
  return `hsl(${(hue / 256) * 360}deg 72% ${light}% / ${alpha})`;
}

export function drawArena(g: CanvasRenderingContext2D, v: WorldView): void {
  g.save();
  // Grid every 10 world units.
  g.strokeStyle = "rgba(138, 160, 192, 0.07)";
  g.lineWidth = 1;
  g.beginPath();
  for (let x = 10; x < ARENA_W; x += 10) { g.moveTo(v.sx(x), v.sy(0)); g.lineTo(v.sx(x), v.sy(ARENA_H)); }
  for (let y = 10; y < ARENA_H; y += 10) { g.moveTo(v.sx(0), v.sy(y)); g.lineTo(v.sx(ARENA_W), v.sy(y)); }
  g.stroke();
  // Border.
  g.strokeStyle = "rgba(138, 160, 192, 0.35)";
  g.lineWidth = 1.5;
  g.strokeRect(v.sx(0), v.sy(0), v.s(ARENA_W), v.s(ARENA_H));
  g.restore();
}

export interface ShapeOpts {
  fill?: string;
  stroke?: string;
  lineWidth?: number;
  dash?: number[];
  alpha?: number;
}

export function drawSquare(
  g: CanvasRenderingContext2D, v: WorldView,
  x: number, y: number, half: number, opts: ShapeOpts,
): void {
  g.save();
  if (opts.alpha !== undefined) g.globalAlpha = opts.alpha;
  const s = v.s(half);
  if (opts.fill) { g.fillStyle = opts.fill; g.fillRect(v.sx(x) - s, v.sy(y) - s, s * 2, s * 2); }
  if (opts.stroke) {
    g.strokeStyle = opts.stroke;
    g.lineWidth = opts.lineWidth ?? 1.5;
    if (opts.dash) g.setLineDash(opts.dash);
    g.strokeRect(v.sx(x) - s, v.sy(y) - s, s * 2, s * 2);
  }
  g.restore();
}

export function drawCircle(
  g: CanvasRenderingContext2D, v: WorldView,
  x: number, y: number, r: number, opts: ShapeOpts,
): void {
  g.save();
  if (opts.alpha !== undefined) g.globalAlpha = opts.alpha;
  g.beginPath();
  g.arc(v.sx(x), v.sy(y), v.s(r), 0, Math.PI * 2);
  if (opts.fill) { g.fillStyle = opts.fill; g.fill(); }
  if (opts.stroke) {
    g.strokeStyle = opts.stroke;
    g.lineWidth = opts.lineWidth ?? 1.5;
    if (opts.dash) g.setLineDash(opts.dash);
    g.stroke();
  }
  g.restore();
}

/** Dashed outline "ghost" (the standard marker for a raw server position). */
export function drawGhostSquare(
  g: CanvasRenderingContext2D, v: WorldView,
  x: number, y: number, half: number, color: string,
): void {
  drawSquare(g, v, x, y, half, { stroke: color, dash: [4, 3], lineWidth: 1.5 });
}

export function drawArrow(
  g: CanvasRenderingContext2D, v: WorldView,
  x0: number, y0: number, x1: number, y1: number,
  color: string, width = 2, alpha = 1,
): void {
  const ax = v.sx(x0), ay = v.sy(y0), bx = v.sx(x1), by = v.sy(y1);
  const dx = bx - ax, dy = by - ay;
  const len = Math.sqrt(dx * dx + dy * dy);
  if (len < 2) return;
  g.save();
  g.globalAlpha = alpha;
  g.strokeStyle = color;
  g.fillStyle = color;
  g.lineWidth = width;
  g.beginPath();
  g.moveTo(ax, ay);
  g.lineTo(bx, by);
  g.stroke();
  const hs = Math.min(8, len * 0.4);
  const ux = dx / len, uy = dy / len;
  g.beginPath();
  g.moveTo(bx, by);
  g.lineTo(bx - ux * hs - uy * hs * 0.5, by - uy * hs + ux * hs * 0.5);
  g.lineTo(bx - ux * hs + uy * hs * 0.5, by - uy * hs - ux * hs * 0.5);
  g.closePath();
  g.fill();
  g.restore();
}

export function drawLabel(
  g: CanvasRenderingContext2D, v: WorldView,
  x: number, y: number, text: string,
  opts: { color?: string; size?: number; align?: CanvasTextAlign; dy?: number } = {},
): void {
  g.save();
  g.fillStyle = opts.color ?? "rgba(216, 226, 240, 0.8)";
  g.font = `${opts.size ?? 11}px -apple-system, system-ui, sans-serif`;
  g.textAlign = opts.align ?? "center";
  g.fillText(text, v.sx(x), v.sy(y) + (opts.dy ?? 0));
  g.restore();
}

/** Straight line in world coords. */
export function drawLine(
  g: CanvasRenderingContext2D, v: WorldView,
  x0: number, y0: number, x1: number, y1: number,
  color: string, width = 1.5, dash?: number[], alpha = 1,
): void {
  g.save();
  g.globalAlpha = alpha;
  g.strokeStyle = color;
  g.lineWidth = width;
  if (dash) g.setLineDash(dash);
  g.beginPath();
  g.moveTo(v.sx(x0), v.sy(y0));
  g.lineTo(v.sx(x1), v.sy(y1));
  g.stroke();
  g.restore();
}

/** Crosshair marker (shot-impact style). */
export function drawMarker(
  g: CanvasRenderingContext2D, v: WorldView,
  x: number, y: number, r: number, color: string, alpha = 1,
): void {
  g.save();
  g.globalAlpha = alpha;
  g.strokeStyle = color;
  g.lineWidth = 1.5;
  const px = v.sx(x), py = v.sy(y), pr = v.s(r);
  g.beginPath();
  g.arc(px, py, pr, 0, Math.PI * 2);
  g.moveTo(px - pr * 1.5, py); g.lineTo(px + pr * 1.5, py);
  g.moveTo(px, py - pr * 1.5); g.lineTo(px, py + pr * 1.5);
  g.stroke();
  g.restore();
}
