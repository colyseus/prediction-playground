// Browser runtime smoke for the web export (run-web.sh must be serving, or
// point SMOKE_URL elsewhere). Loads the page in headless Chrome, watches the
// console for the extension's own connect print, and screenshots the canvas.
//
//   node clients/godot-gd-app/web-smoke.mjs            (from repo root)
//
// Exit 0 = engine booted AND the colyseus side module opened its websocket.
// headless "shell" on purpose: "new" headless never fires rAF here, and the
// engine (and colyseus_ws_poll) only run inside the rAF loop.
import puppeteer from 'puppeteer';

const URL = process.env.SMOKE_URL || 'http://localhost:8060/index.html';
const SHOT = process.env.SMOKE_SHOT || '/tmp/godot-web-smoke.png';
const WAIT_MS = Number(process.env.SMOKE_WAIT || 60000);

const browser = await puppeteer.launch({
  headless: 'shell',
  // Godot needs WebGL2 — SwiftShader provides it without a GPU.
  args: ['--enable-unsafe-swiftshader', '--use-gl=angle', '--use-angle=swiftshader'],
});
const page = await browser.newPage();
await page.setViewport({ width: 1152, height: 648 });

const logs = [];
const note = (tag, text) => {
  logs.push(text);
  console.log(`[${tag}] ${text.slice(0, 300)}`);
};
page.on('console', (m) => note('console', m.text()));
page.on('pageerror', (e) => note('pageerror', String(e.message || e)));
page.on('requestfailed', (r) =>
  note('reqfail', `${r.url()} ${r.failure()?.errorText ?? ''}`));

const t0 = Date.now();
await page.goto(URL, { waitUntil: 'load', timeout: 60000 });

// Success signal: colyseus_ws_poll's printf lands in the console when the
// socket opens. Engine boot alone is not enough — the ws proves the side
// module loaded, linked, and ran.
const connectCount = () =>
  logs.filter((l) => l.includes('[WebSocket] Connected')).length;
let engineBooted = false;
while (Date.now() - t0 < WAIT_MS) {
  engineBooted ||= logs.some((l) => l.includes('Godot Engine v'));
  if (connectCount() >= 1) break;
  await new Promise((r) => setTimeout(r, 500));
}
const connected = connectCount() >= 1;

// Drop gate: X kills the socket uncleanly (close 4010) and the SDK's polled
// scheduler must reconnect on its own — a second connect print proves it.
// Default reconnection options gate on 5 s of room uptime, so wait it out.
let reconnected = false;
if (connected) {
  await new Promise((r) => setTimeout(r, 8000));
  await page.click('canvas').catch(() => {});
  await page.keyboard.down('KeyX');
  await new Promise((r) => setTimeout(r, 120));
  await page.keyboard.up('KeyX');
  const tDrop = Date.now();
  while (Date.now() - tDrop < 20000) {
    if (connectCount() >= 2) { reconnected = true; break; }
    await new Promise((r) => setTimeout(r, 500));
  }
}

// Let the app settle before the screenshot (SMOKE_SETTLE ms — raise it to
// watch the RTT estimator re-converge onto the re-applied latency preset).
await new Promise((r) => setTimeout(r, Number(process.env.SMOKE_SETTLE || 3000)));
await page.screenshot({ path: SHOT });
console.log(`screenshot: ${SHOT}`);

console.log(`engine booted: ${engineBooted}`);
console.log(connected
  ? `SMOKE WEB OK (connected after ${((Date.now() - t0) / 1000).toFixed(1)}s)`
  : 'SMOKE WEB FAIL (no websocket connect seen)');
console.log(reconnected
  ? 'DROP RECONNECT OK (second connect after D)'
  : 'DROP RECONNECT FAIL (no reconnect seen after D)');
await browser.close();
process.exit(connected && reconnected ? 0 : 1);
