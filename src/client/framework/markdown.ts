/**
 * Tiny markdown-subset renderer for the lab docs panels: headings, paragraphs,
 * unordered lists, fenced code blocks (syntax-highlighted), `code`, **bold**,
 * *italic*, links. No dependency; input is our own docs.md files (not user
 * content), but everything is escaped at emission anyway.
 */

import { highlightCode } from "./highlight.ts";

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function inline(s: string): string {
  return esc(s)
    .replace(/`([^`]+)`/g, (_, c) => `<code>${c}</code>`)
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/\*([^*]+)\*/g, "<em>$1</em>")
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, `<a href="$2" target="_blank" rel="noopener">$1</a>`);
}

export function renderMarkdown(md: string): string {
  const out: string[] = [];
  const lines = md.split("\n");
  let i = 0;
  let inList = false;
  const closeList = () => { if (inList) { out.push("</ul>"); inList = false; } };

  while (i < lines.length) {
    const line = lines[i];

    if (line.startsWith("```")) {
      closeList();
      const code: string[] = [];
      i++;
      while (i < lines.length && !lines[i].startsWith("```")) code.push(lines[i++]);
      i++; // closing fence
      out.push(`<pre><code>${highlightCode(code.join("\n"))}</code></pre>`);
      continue;
    }

    const h = line.match(/^(#{1,3})\s+(.*)$/);
    if (h) {
      closeList();
      const level = h[1].length;
      out.push(`<h${level}>${inline(h[2])}</h${level}>`);
      i++;
      continue;
    }

    const li = line.match(/^[-*]\s+(.*)$/);
    if (li) {
      if (!inList) { out.push("<ul>"); inList = true; }
      // Consume indented / plain continuation lines into the same item.
      const item = [li[1]];
      i++;
      while (i < lines.length && lines[i].trim() !== "" &&
             !/^[-*]\s/.test(lines[i]) && !/^#{1,3}\s/.test(lines[i]) && !lines[i].startsWith("```")) {
        item.push(lines[i++].trim());
      }
      out.push(`<li>${inline(item.join(" "))}</li>`);
      continue;
    }

    if (line.trim() === "") { closeList(); i++; continue; }

    // Paragraph: consume consecutive non-empty, non-special lines.
    closeList();
    const para: string[] = [line];
    i++;
    while (i < lines.length && lines[i].trim() !== "" &&
           !lines[i].startsWith("```") && !/^#{1,3}\s/.test(lines[i]) && !/^[-*]\s/.test(lines[i])) {
      para.push(lines[i++]);
    }
    out.push(`<p>${inline(para.join(" "))}</p>`);
  }
  closeList();
  return out.join("\n");
}
