/** Right-panel telemetry: labeled readout rows, sparklines, pending-input chips. */

export interface HudRow { set(text: string, cls?: "good" | "warn" | "bad" | ""): void; }
export interface HudSpark { push(v: number): void; setLabel(text: string): void; }
export interface HudChips { set(n: number): void; }

const SPARK_SAMPLES = 140;

export class TelemetryHUD {
  constructor(private root: HTMLElement) {}

  clear(): void { this.root.innerHTML = ""; }

  row(label: string): HudRow {
    const el = document.createElement("div");
    el.className = "hudrow";
    el.innerHTML = `<span class="lbl"></span><span class="val">—</span>`;
    (el.querySelector(".lbl") as HTMLElement).textContent = label;
    const val = el.querySelector(".val") as HTMLElement;
    this.root.appendChild(el);
    return {
      set(text, cls = "") { val.textContent = text; val.className = `val ${cls}`; },
    };
  }

  /**
   * Rolling sparkline. Auto-scales to the window max unless a fixed `max` is
   * given; the current value is printed next to the label.
   */
  spark(label: string, opts: { max?: number; format?: (v: number) => string; color?: string } = {}): HudSpark {
    const el = document.createElement("div");
    el.className = "hudspark";
    el.innerHTML = `<div class="head"><span class="lbl"></span><span class="val">—</span></div>`;
    (el.querySelector(".lbl") as HTMLElement).textContent = label;
    const val = el.querySelector(".val") as HTMLElement;
    const canvas = document.createElement("canvas");
    el.appendChild(canvas);
    this.root.appendChild(el);

    const data = new Float64Array(SPARK_SAMPLES);
    let head = 0, count = 0;
    const fmt = opts.format ?? ((v: number) => v.toFixed(3));
    const color = opts.color ?? "#ffd36b";

    const draw = () => {
      const dpr = window.devicePixelRatio || 1;
      const w = canvas.clientWidth, h = canvas.clientHeight;
      if (w === 0) return;
      if (canvas.width !== w * dpr) { canvas.width = w * dpr; canvas.height = h * dpr; }
      const g = canvas.getContext("2d")!;
      g.setTransform(dpr, 0, 0, dpr, 0, 0);
      g.clearRect(0, 0, w, h);
      if (count < 2) return;
      let max = opts.max ?? 0;
      if (opts.max === undefined) {
        for (let i = 0; i < count; i++) max = Math.max(max, data[i]);
        if (max <= 0) max = 1e-6;
      }
      g.strokeStyle = color;
      g.lineWidth = 1;
      g.beginPath();
      const start = (head - count + SPARK_SAMPLES * 2) % SPARK_SAMPLES;
      for (let i = 0; i < count; i++) {
        const x = (i / (SPARK_SAMPLES - 1)) * w;
        const value = data[(start + i) % SPARK_SAMPLES];
        const y = h - 2 - Math.min(1, value / max) * (h - 4);
        if (i === 0) g.moveTo(x, y); else g.lineTo(x, y);
      }
      g.stroke();
    };

    return {
      push(v: number) {
        data[head] = v;
        head = (head + 1) % SPARK_SAMPLES;
        if (count < SPARK_SAMPLES) count++;
        val.textContent = fmt(v);
        draw();
      },
      setLabel(text: string) { val.textContent = text; },
    };
  }

  /** One chip per pending (unacked) input — the row drains as acks land. */
  chips(label: string, max = 48): HudChips {
    const el = document.createElement("div");
    el.className = "hudchips";
    el.innerHTML = `<div class="head"><span class="lbl"></span><span class="val">0</span></div><div class="chips"></div>`;
    (el.querySelector(".lbl") as HTMLElement).textContent = label;
    const val = el.querySelector(".val") as HTMLElement;
    const box = el.querySelector(".chips") as HTMLElement;
    this.root.appendChild(el);
    let shown = -1;
    return {
      set(n: number) {
        if (n === shown) return;
        shown = n;
        val.textContent = String(n);
        const want = Math.min(n, max);
        while (box.children.length > want) box.removeChild(box.lastChild!);
        while (box.children.length < want) {
          const c = document.createElement("div");
          c.className = "chip";
          box.appendChild(c);
        }
      },
    };
  }
}
