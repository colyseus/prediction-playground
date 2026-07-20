import { isPending, type LabEntry } from "./lab.ts";

/**
 * Lab discovery chrome: a persistent bottom-center progress strip (prev/next
 * arrows + one dot per lab) and an on-demand card-grid overlay. Both navigate
 * by setting location.hash — the same channel the top-bar <select> and the
 * probes use. The grid is user-initiated only; it never auto-opens, so it
 * cannot compete with the docs panel's first-visit auto-expand.
 */
export class LabNav {
  private strip = document.getElementById("labstrip")!;
  private grid = document.getElementById("labgrid")!;
  private dots = new Map<string, HTMLButtonElement>();
  private cards = new Map<string, HTMLButtonElement>();
  private label!: HTMLButtonElement;
  private activeId: string | null = null;

  constructor(private labs: LabEntry[]) {
    this.buildStrip();
    this.buildGrid();
    window.addEventListener("pp:open-grid", () => this.openGrid());
    window.addEventListener("keydown", (e) => {
      if (e.code === "Escape" && this.grid.classList.contains("open")) this.closeGrid();
    });
  }

  /** Called by the shell on every lab activation. */
  setActive(id: string): void {
    this.activeId = id;
    const entry = this.labs.find((l) => l.id === id);
    const maxNum = Math.max(...this.labs.map((l) => l.num));
    if (entry) this.label.textContent = `⊞ ${String(entry.num).padStart(2, "0")} / ${maxNum}`;
    this.refresh();
  }

  private visited(id: string): boolean {
    return !!localStorage.getItem(`pp-docs-seen:${id}`);
  }

  private refresh(): void {
    for (const [id, dot] of this.dots) {
      dot.classList.toggle("current", id === this.activeId);
      dot.classList.toggle("visited", id !== this.activeId && this.visited(id));
    }
    for (const [id, card] of this.cards) {
      card.classList.toggle("current", id === this.activeId);
      const check = card.querySelector(".check") as HTMLElement;
      check.textContent = this.visited(id) ? "✓" : "";
    }
  }

  private step(dir: -1 | 1): void {
    const enabled = this.labs.filter((l) => !isPending(l));
    const i = enabled.findIndex((l) => l.id === this.activeId);
    const next = enabled[(i + dir + enabled.length) % enabled.length];
    location.hash = next.id;
  }

  private buildStrip(): void {
    const nav = (text: string, title: string, onClick: () => void) => {
      const b = document.createElement("button");
      b.className = "nav";
      b.textContent = text;
      b.title = title;
      b.addEventListener("click", onClick);
      return b;
    };
    this.strip.appendChild(nav("‹", "Previous lab", () => this.step(-1)));

    const dots = document.createElement("div");
    dots.className = "dots";
    for (const entry of this.labs) {
      const dot = document.createElement("button");
      dot.className = "dot" + (isPending(entry) ? " pending" : "");
      dot.title = `${String(entry.num).padStart(2, "0")} · ${entry.title}` + (isPending(entry) ? " (soon)" : "");
      if (!isPending(entry)) dot.addEventListener("click", () => { location.hash = entry.id; });
      dots.appendChild(dot);
      this.dots.set(entry.id, dot);
    }
    this.strip.appendChild(dots);

    this.strip.appendChild(nav("›", "Next lab", () => this.step(1)));

    this.label = document.createElement("button");
    this.label.className = "grid-open";
    this.label.title = "Browse all labs";
    this.label.textContent = "⊞";
    this.label.addEventListener("click", () => this.openGrid());
    this.strip.appendChild(this.label);
  }

  private buildGrid(): void {
    const backdrop = document.createElement("div");
    backdrop.className = "backdrop";
    backdrop.addEventListener("click", () => this.closeGrid());
    this.grid.appendChild(backdrop);

    const sheet = document.createElement("div");
    sheet.className = "sheet";
    let cardsEl: HTMLElement | null = null;
    let lastPhase = 0;
    for (const entry of this.labs) {
      if (entry.phase !== lastPhase) {
        lastPhase = entry.phase;
        const h = document.createElement("h2");
        h.textContent = entry.phase === 1 ? "Fundamentals" : "Advanced";
        sheet.appendChild(h);
        cardsEl = document.createElement("div");
        cardsEl.className = "cards";
        sheet.appendChild(cardsEl);
      }
      const card = document.createElement("button");
      card.className = "labcard" + (isPending(entry) ? " pending" : "");
      const num = document.createElement("span");
      num.className = "num";
      num.textContent = String(entry.num).padStart(2, "0");
      const body = document.createElement("div");
      const t = document.createElement("div");
      t.className = "t";
      t.textContent = entry.title + (isPending(entry) ? " (soon)" : "");
      const b = document.createElement("div");
      b.className = "b";
      b.textContent = entry.blurb;
      body.append(t, b);
      const check = document.createElement("span");
      check.className = "check";
      card.append(num, body, check);
      if (!isPending(entry)) {
        card.addEventListener("click", () => {
          this.closeGrid();
          location.hash = entry.id;
        });
      }
      cardsEl!.appendChild(card);
      this.cards.set(entry.id, card);
    }
    this.grid.appendChild(sheet);
  }

  openGrid(): void {
    this.refresh();
    this.grid.classList.add("open");
  }

  closeGrid(): void {
    this.grid.classList.remove("open");
  }
}
