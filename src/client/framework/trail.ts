import type { WorldView } from "./draw.ts";

/** Ring-buffer position trail, drawn as a fading polyline. */
export class Trail {
  private xs: Float64Array;
  private ys: Float64Array;
  private head = 0;
  private count = 0;

  constructor(private capacity = 120) {
    this.xs = new Float64Array(capacity);
    this.ys = new Float64Array(capacity);
  }

  push(x: number, y: number): void {
    this.xs[this.head] = x;
    this.ys[this.head] = y;
    this.head = (this.head + 1) % this.capacity;
    if (this.count < this.capacity) this.count++;
  }

  clear(): void { this.count = 0; this.head = 0; }

  draw(g: CanvasRenderingContext2D, v: WorldView, color: string, width = 1.5, maxAlpha = 0.5): void {
    if (this.count < 2) return;
    g.save();
    g.strokeStyle = color;
    g.lineWidth = width;
    const n = this.count;
    const start = (this.head - n + this.capacity * 2) % this.capacity;
    let px = v.sx(this.xs[start]), py = v.sy(this.ys[start]);
    for (let i = 1; i < n; i++) {
      const idx = (start + i) % this.capacity;
      const nx = v.sx(this.xs[idx]), ny = v.sy(this.ys[idx]);
      g.globalAlpha = (i / n) * maxAlpha;
      g.beginPath();
      g.moveTo(px, py);
      g.lineTo(nx, ny);
      g.stroke();
      px = nx; py = ny;
    }
    g.restore();
  }
}
