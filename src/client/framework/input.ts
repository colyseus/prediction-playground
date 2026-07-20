/**
 * WASD/arrow-key tri-state axes + latched action edges. On coarse-pointer
 * (touch) devices, a drag on the canvas doubles as a virtual stick quantized
 * to the same tri-state axes — every WASD lab gains touch from this one file.
 */
export class Keyboard {
  private down = new Set<string>();
  private edges = new Set<string>();

  // Virtual stick (touch only). The origin trails the pointer so sharp
  // reversals engage immediately instead of re-crossing the touch point.
  private touchX: -1 | 0 | 1 = 0;
  private touchY: -1 | 0 | 1 = 0;
  private pointerId: number | null = null;
  private originX = 0;
  private originY = 0;

  private onKeyDown = (e: KeyboardEvent) => {
    if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;
    if (!e.repeat) this.edges.add(e.code);
    this.down.add(e.code);
  };
  private onKeyUp = (e: KeyboardEvent) => { this.down.delete(e.code); };
  private onBlur = () => { this.down.clear(); };

  private onPointerDown = (e: PointerEvent) => {
    // Canvas only — taps on controls/topbar/strip must not drive.
    if (!(e.target instanceof HTMLCanvasElement) || this.pointerId !== null) return;
    this.pointerId = e.pointerId;
    this.originX = e.clientX;
    this.originY = e.clientY;
  };
  private onPointerMove = (e: PointerEvent) => {
    if (e.pointerId !== this.pointerId) return;
    const R = 40, dead = 14;
    let dx = e.clientX - this.originX, dy = e.clientY - this.originY;
    if (Math.abs(dx) > R) { this.originX = e.clientX - Math.sign(dx) * R; dx = Math.sign(dx) * R; }
    if (Math.abs(dy) > R) { this.originY = e.clientY - Math.sign(dy) * R; dy = Math.sign(dy) * R; }
    this.touchX = dx > dead ? 1 : dx < -dead ? -1 : 0;
    this.touchY = dy > dead ? 1 : dy < -dead ? -1 : 0;
  };
  private onPointerUp = (e: PointerEvent) => {
    if (e.pointerId !== this.pointerId) return;
    this.pointerId = null;
    this.touchX = this.touchY = 0;
  };

  private readonly touchEnabled = typeof matchMedia === "function" && matchMedia("(pointer: coarse)").matches;

  constructor() {
    window.addEventListener("keydown", this.onKeyDown);
    window.addEventListener("keyup", this.onKeyUp);
    window.addEventListener("blur", this.onBlur);
    if (this.touchEnabled) {
      window.addEventListener("pointerdown", this.onPointerDown);
      window.addEventListener("pointermove", this.onPointerMove);
      window.addEventListener("pointerup", this.onPointerUp);
      window.addEventListener("pointercancel", this.onPointerUp);
    }
  }

  moveX(): -1 | 0 | 1 {
    const l = this.down.has("KeyA") || this.down.has("ArrowLeft");
    const r = this.down.has("KeyD") || this.down.has("ArrowRight");
    if (r !== l) return r ? 1 : -1;
    return this.touchX;
  }

  moveY(): -1 | 0 | 1 {
    const u = this.down.has("KeyW") || this.down.has("ArrowUp");
    const d = this.down.has("KeyS") || this.down.has("ArrowDown");
    if (d !== u) return d ? 1 : -1;
    return this.touchY;
  }

  get anyMove(): boolean { return this.moveX() !== 0 || this.moveY() !== 0; }

  /** One-shot edge: true once per physical key press, then consumed. */
  edge(code: string): boolean {
    if (!this.edges.has(code)) return false;
    this.edges.delete(code);
    return true;
  }

  /** Drop edges not consumed this frame (call once per frame, after reads). */
  drainEdges(): void { this.edges.clear(); }

  dispose(): void {
    window.removeEventListener("keydown", this.onKeyDown);
    window.removeEventListener("keyup", this.onKeyUp);
    window.removeEventListener("blur", this.onBlur);
    if (this.touchEnabled) {
      window.removeEventListener("pointerdown", this.onPointerDown);
      window.removeEventListener("pointermove", this.onPointerMove);
      window.removeEventListener("pointerup", this.onPointerUp);
      window.removeEventListener("pointercancel", this.onPointerUp);
    }
  }
}
