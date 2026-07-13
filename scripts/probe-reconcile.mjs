// Probe Lab 03 under simulated latency:
//  - local motion is immediate (predicted pose moves within ~2 frames of keydown)
//  - pending inputs ≈ RTT × TICK_HZ / 1000 while driving
//  - drift stays "matched" in steady state (shared step is deterministic)
//  - an impulse forces a correction; drift recovers afterwards
// Usage: node scripts/probe-reconcile.mjs [port]
import puppeteer from "puppeteer";

const port = process.argv[2] ?? process.env.PORT ?? "5173";
const LATENCY = 200;

const browser = await puppeteer.launch({ headless: "shell" });
const page = await browser.newPage();
await page.setViewport({ width: 1280, height: 800 });
const errors = [];
page.on("pageerror", (err) => errors.push(String(err)));

await page.goto(`http://localhost:${port}/?private=1#03-reconcile`, { waitUntil: "networkidle2" });
await page.waitForFunction(() => window.__lab?.id === "03-reconcile", { timeout: 15000 });
await new Promise((r) => setTimeout(r, 800));

// Expose telemetry from the page: reach the room + reconciler via __lab.
const read = () => page.evaluate(() => {
  const room = window.__lab.room;
  const me = room.state.players.get(room.sessionId);
  const t = window.__lab.telemetry ?? null;
  return {
    x: me.x, y: me.y,
    rtt: room.clock.smoothedRtt(),
    pending: t?.pending, driftEma: t?.driftEma, status: t?.status,
    predictedX: t?.predictedX,
  };
});

// Apply simulated latency through the debug hook.
await page.evaluate((ms) => window.__net(ms, 0), LATENCY);
await new Promise((r) => setTimeout(r, 1200));

let fail = 0;
const check = (name, ok, detail) => {
  console.log(`${ok ? "OK  " : "FAIL"} ${name}${detail ? ` — ${detail}` : ""}`);
  if (!ok) fail++;
};

// 1. Immediate local motion.
const before = await read();
await page.keyboard.down("KeyD");
await new Promise((r) => setTimeout(r, 120)); // ~7 frames, far below RTT
const early = await read();
check("predicted pose moves before RTT elapses",
  early.predictedX - before.predictedX > 0.3,
  `Δx=${(early.predictedX - before.predictedX).toFixed(2)} in 120ms at rtt=${early.rtt.toFixed(0)}ms`);

// 2. Pending inputs scale with RTT while driving.
await new Promise((r) => setTimeout(r, 1500));
const mid = await read();
const expected = (mid.rtt * 20) / 1000;
check("pending ≈ RTT × tickrate",
  mid.pending >= expected * 0.5 && mid.pending <= expected * 2 + 2,
  `pending=${mid.pending} expected≈${expected.toFixed(1)} (rtt=${mid.rtt.toFixed(0)}ms)`);

// 3. Deterministic steady state.
check("drift matched while driving", mid.status === "matched", `status=${mid.status} ema=${mid.driftEma}`);
await page.keyboard.up("KeyD");

// 4. Impulse → correction → recovery. A single shove is a one-off spike (the
// drift EMA barely moves by design) — poll the per-reconcile correction instead.
await new Promise((r) => setTimeout(r, 600));
const beforeImpulse = await page.evaluate(() => window.__lab.telemetry.corrections);
await page.evaluate(() => window.__lab.room.send("impulse"));
await new Promise((r) => setTimeout(r, 1500));
const afterImpulse = await page.evaluate(() => ({
  corrections: window.__lab.telemetry.corrections,
  maxCorrMag: window.__lab.telemetry.maxCorrMag,
}));
check("impulse produces a visible correction",
  afterImpulse.corrections > beforeImpulse && afterImpulse.maxCorrMag > 0.05,
  `corrections ${beforeImpulse}→${afterImpulse.corrections}, max mag=${afterImpulse.maxCorrMag.toFixed(3)}`);
await new Promise((r) => setTimeout(r, 2500));
const recovered = await read();
// "jitter" = spikes that decay without persisting — the correct verdict for a
// one-off shove. Only "diverging" (persistent ema) would mean a determinism bug.
check("drift recovers after impulse", recovered.status !== "diverging", `status=${recovered.status} ema=${recovered.driftEma}`);

check("no page errors", errors.length === 0, errors[0]);

await browser.close();
console.log(fail === 0 ? "\nPROBE OK" : `\nPROBE FAILED (${fail})`);
process.exit(fail === 0 ? 0 : 1);
