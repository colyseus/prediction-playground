/** WASD/arrow-key tri-state axes + latched action edges. */
export class Keyboard {
  private down = new Set<string>();
  private edges = new Set<string>();

  private onKeyDown = (e: KeyboardEvent) => {
    if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;
    if (!e.repeat) this.edges.add(e.code);
    this.down.add(e.code);
  };
  private onKeyUp = (e: KeyboardEvent) => { this.down.delete(e.code); };
  private onBlur = () => { this.down.clear(); };

  constructor() {
    window.addEventListener("keydown", this.onKeyDown);
    window.addEventListener("keyup", this.onKeyUp);
    window.addEventListener("blur", this.onBlur);
  }

  moveX(): -1 | 0 | 1 {
    const l = this.down.has("KeyA") || this.down.has("ArrowLeft");
    const r = this.down.has("KeyD") || this.down.has("ArrowRight");
    return r === l ? 0 : r ? 1 : -1;
  }

  moveY(): -1 | 0 | 1 {
    const u = this.down.has("KeyW") || this.down.has("ArrowUp");
    const d = this.down.has("KeyS") || this.down.has("ArrowDown");
    return d === u ? 0 : d ? 1 : -1;
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
  }
}
