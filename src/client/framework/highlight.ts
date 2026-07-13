/**
 * Tiny TypeScript/JavaScript syntax highlighter for the docs panel — one
 * regex pass, no dependency. Escapes as it emits, so it takes RAW source.
 * Good enough for the lab `net.ts` files and docs fences; it does not try to
 * handle regex literals or nested template-literal expressions.
 */

const TOKEN_RE =
  /(\/\/[^\n]*|\/\*[\s\S]*?\*\/)|("(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`(?:[^`\\]|\\[\s\S])*`)|\b(0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b|\b(import|export|from|const|let|var|function|return|if|else|for|while|do|switch|case|default|break|continue|new|class|extends|implements|interface|type|enum|async|await|yield|typeof|instanceof|in|of|as|satisfies|keyof|readonly|public|private|protected|static|this|super|null|undefined|true|false|void|never|any|unknown|number|string|boolean|throw|try|catch|finally)\b|\b([A-Z][A-Za-z0-9_$]*)\b|([a-z_$][A-Za-z0-9_$]*)(?=\s*\()/g;

const CLASSES = ["tok-com", "tok-str", "tok-num", "tok-kw", "tok-type", "tok-fn"];

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

export function highlightCode(src: string): string {
  let out = "";
  let last = 0;
  TOKEN_RE.lastIndex = 0;
  for (let m: RegExpExecArray | null; (m = TOKEN_RE.exec(src)); ) {
    out += esc(src.slice(last, m.index));
    let cls = "";
    for (let g = 1; g <= 6; g++) {
      if (m[g] !== undefined) { cls = CLASSES[g - 1]; break; }
    }
    out += `<span class="${cls}">${esc(m[0])}</span>`;
    last = m.index + m[0].length;
  }
  out += esc(src.slice(last));
  return out;
}
