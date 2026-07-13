/**
 * Declarative right-panel knob builder. Each lab builds its controls on
 * mount; the shell clears the panel on lab switch.
 */
export class ControlsPanel {
  constructor(private root: HTMLElement) {}

  clear(): void { this.root.innerHTML = ""; }

  private box(): HTMLDivElement {
    const el = document.createElement("div");
    el.className = "ctl";
    this.root.appendChild(el);
    return el;
  }

  slider(opts: {
    label: string;
    min: number;
    max: number;
    step?: number;
    value: number;
    unit?: string;
    format?: (v: number) => string;
    onChange: (v: number) => void;
    /** Fire only on release (for expensive changes, e.g. reconciler rebuild). */
    onCommit?: boolean;
    note?: string;
  }): { get(): number; set(v: number): void } {
    const box = this.box();
    const fmt = opts.format ?? ((v: number) => `${v}${opts.unit ?? ""}`);
    box.innerHTML = `<div class="head"><span class="lbl"></span><span class="val"></span></div>`;
    (box.querySelector(".lbl") as HTMLElement).textContent = opts.label;
    const val = box.querySelector(".val") as HTMLElement;
    const input = document.createElement("input");
    input.type = "range";
    input.min = String(opts.min);
    input.max = String(opts.max);
    input.step = String(opts.step ?? 1);
    input.value = String(opts.value);
    val.textContent = fmt(opts.value);
    input.addEventListener("input", () => {
      val.textContent = fmt(Number(input.value));
      if (!opts.onCommit) opts.onChange(Number(input.value));
    });
    if (opts.onCommit) input.addEventListener("change", () => opts.onChange(Number(input.value)));
    box.appendChild(input);
    if (opts.note) this.addNote(box, opts.note);
    return {
      get: () => Number(input.value),
      set: (v) => { input.value = String(v); val.textContent = fmt(v); },
    };
  }

  toggle(opts: {
    label: string;
    value: boolean;
    onChange: (v: boolean) => void;
    note?: string;
  }): { get(): boolean; set(v: boolean): void } {
    const box = this.box();
    box.innerHTML = `<div class="toggle-row"><span class="lbl"></span><div class="switch"></div></div>`;
    (box.querySelector(".lbl") as HTMLElement).textContent = opts.label;
    const sw = box.querySelector(".switch") as HTMLElement;
    let on = opts.value;
    const render = () => sw.classList.toggle("on", on);
    render();
    sw.addEventListener("click", () => { on = !on; render(); opts.onChange(on); });
    if (opts.note) this.addNote(box, opts.note);
    return { get: () => on, set: (v) => { on = v; render(); } };
  }

  radio<T extends string>(opts: {
    label: string;
    options: Array<{ value: T; label: string; disabled?: boolean; title?: string }>;
    value: T;
    onChange: (v: T) => void;
    note?: string;
  }): { get(): T; set(v: T): void } {
    const box = this.box();
    box.innerHTML = `<div class="head"><span class="lbl"></span></div><div class="radio-row"></div>`;
    (box.querySelector(".lbl") as HTMLElement).textContent = opts.label;
    const row = box.querySelector(".radio-row") as HTMLElement;
    let current = opts.value;
    const buttons = new Map<T, HTMLButtonElement>();
    const render = () => buttons.forEach((b, v) => b.classList.toggle("on", v === current));
    for (const o of opts.options) {
      const b = document.createElement("button");
      b.className = "opt";
      b.textContent = o.label;
      if (o.title) b.title = o.title;
      if (o.disabled) { b.style.opacity = "0.35"; b.style.cursor = "default"; }
      else b.addEventListener("click", () => { current = o.value; render(); opts.onChange(o.value); });
      row.appendChild(b);
      buttons.set(o.value, b);
    }
    render();
    if (opts.note) this.addNote(box, opts.note);
    return { get: () => current, set: (v) => { current = v; render(); } };
  }

  buttons(items: Array<{ label: string; onClick: () => void; title?: string }>, label?: string): void {
    const box = this.box();
    if (label) {
      const head = document.createElement("div");
      head.className = "head";
      head.innerHTML = `<span class="lbl"></span>`;
      (head.querySelector(".lbl") as HTMLElement).textContent = label;
      box.appendChild(head);
    }
    const row = document.createElement("div");
    row.className = "btn-row";
    for (const it of items) {
      const b = document.createElement("button");
      b.className = "push";
      b.textContent = it.label;
      if (it.title) b.title = it.title;
      b.addEventListener("click", it.onClick);
      row.appendChild(b);
    }
    box.appendChild(row);
  }

  note(text: string): void {
    const box = this.box();
    this.addNote(box, text);
  }

  private addNote(box: HTMLElement, text: string): void {
    const n = document.createElement("div");
    n.className = "note";
    n.textContent = text;
    box.appendChild(n);
  }
}
