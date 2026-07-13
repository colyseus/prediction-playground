import { renderMarkdown } from "./markdown.ts";
import { highlightCode } from "./highlight.ts";

/**
 * The collapsible per-lab explanation panel (bottom-left of the stage).
 * Shows the lab's docs.md plus, when provided, the lab's ACTUAL executed
 * netcode source (`net.ts?raw`) — shown code is executed code, permanently
 * in sync.
 */
export class DocsPanel {
  private root = document.getElementById("docs")!;
  private head = document.getElementById("docs-head")!;
  private title = this.head.querySelector(".t") as HTMLElement;
  private body = document.getElementById("docs-body")!;

  constructor() {
    this.head.addEventListener("click", () => this.root.classList.add("collapsed"));
  }

  /** Show/hide (wired to the top bar's About button). */
  toggle(): void {
    this.root.classList.toggle("collapsed");
  }

  set(labId: string, title: string, docsMd: string, source?: string): void {
    this.title.textContent = title;
    let html = renderMarkdown(docsMd);
    if (source) {
      html += `<details><summary>The code this lab runs</summary><pre><code>${highlightCode(source)}</code></pre></details>`;
    }
    this.body.innerHTML = html;
    this.body.scrollTop = 0;

    // Auto-expand on the first-ever visit of each lab; stay collapsed after.
    const key = `pp-docs-seen:${labId}`;
    if (!localStorage.getItem(key)) {
      localStorage.setItem(key, "1");
      this.root.classList.remove("collapsed");
    }
  }
}
