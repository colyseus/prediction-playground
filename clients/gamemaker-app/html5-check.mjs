// Serve a built HTML5 folder, open it, and require the positive signals the
// shell prints: the WASM module up, then PLAYGROUND READY (joined + lab
// attached). Silence is not success on a page that never booted, so a
// timeout, a canary failure or any page error fails the lane.
//
//   node html5-check.mjs <build-dir> [endpoint]
//
// A browser has no environment, so the endpoint rides the URL query, which
// GameMaker surfaces through parameter_string(). Unencoded on purpose: the
// runner hands the value over verbatim.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import puppeteer from "puppeteer";

const dir = process.argv[2] ?? "output/html5";
const endpoint = process.argv[3] ?? "http://127.0.0.1:5173";
const TIMEOUT_MS = 60_000;
const TYPES = {
  ".html": "text/html", ".js": "text/javascript", ".json": "application/json",
  ".png": "image/png", ".ico": "image/x-icon", ".wasm": "application/wasm",
};

const server = createServer(async (req, res) => {
  const rel = normalize(decodeURIComponent(req.url.split("?")[0])).replace(/^(\.\.[/\\])+/, "");
  const file = join(dir, rel === "/" ? "index.html" : rel);
  try {
    const body = await readFile(file);
    res.writeHead(200, { "Content-Type": TYPES[extname(file)] ?? "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404).end("not found");
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = `http://127.0.0.1:${server.address().port}/?--endpoint=${endpoint}`;
console.log(`[html5] serving ${dir} -> ${url}`);

const browser = await puppeteer.launch({ headless: "shell" });
const page = await browser.newPage();
const seen = { boot: "", ready: false, joined: "", errors: [] };
let settle;
const done = new Promise((r) => (settle = r));
page.on("console", (m) => {
  const t = m.text();
  if (t.startsWith("PLAYGROUND BOOT")) seen.boot = t;
  if (t.includes("[Colyseus WASM] Module initialized")) seen.ready = true;
  if (t.startsWith("PLAYGROUND READY")) { seen.joined = t; settle(); }
  if (t.startsWith("SIM CANARY FAILED")) { seen.errors.push(t); settle(); }
});
page.on("pageerror", (e) => { seen.errors.push("pageerror: " + e.message); settle(); });

await page.goto(url, { waitUntil: "domcontentloaded" });
await Promise.race([done, new Promise((r) => setTimeout(r, TIMEOUT_MS))]);
await browser.close();
server.close();

for (const e of seen.errors) console.error(`  ${e}`);
console.log(`  ${seen.boot || "(no boot line)"}`);
console.log(`  ${seen.joined || "(never joined)"}`);
const ok = seen.ready && seen.joined && seen.errors.length === 0;
console.log(ok ? "[html5] passed" : "[html5] failed");
process.exit(ok ? 0 : 1);
