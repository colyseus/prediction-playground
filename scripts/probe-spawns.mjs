// Behavioral probe for Labs 09 (predicted spawns) and 10 (composite sim),
// under 200 ms simulated latency. Usage: node scripts/probe-spawns.mjs [port]
import puppeteer from "puppeteer";

const port = process.argv[2] ?? process.env.PORT ?? "5173";
const browser = await puppeteer.launch({ headless: "shell" });
const page = await browser.newPage();
const errors = [];
page.on("pageerror", (err) => errors.push(String(err)));

let fail = 0;
const check = (name, ok, detail) => {
  console.log(`${ok ? "OK  " : "FAIL"} ${name}${detail ? ` — ${detail}` : ""}`);
  if (!ok) fail++;
};
const telemetry = () => page.evaluate(() => {
  const { fire, ...data } = window.__lab.telemetry;
  return data;
});

// ---- Lab 09 -----------------------------------------------------------------
await page.goto(`http://localhost:${port}/?private=1#09-predicted-spawns`, { waitUntil: "networkidle2" });
await page.waitForFunction(() => window.__lab?.id === "09-predicted-spawns", { timeout: 15000 });
await page.evaluate(() => window.__net(200, 0));
await new Promise((r) => setTimeout(r, 1200));

await page.evaluate(() => window.__lab.telemetry.fire(50, 10));
await new Promise((r) => setTimeout(r, 130)); // < one-way trip
const early = await telemetry();
check("lab09: optimistic local exists before the server can know",
  early.nPending >= 1, `pending=${early.nPending} at 130ms after click (RTT=400ms simulated... 200)`);

await new Promise((r) => setTimeout(r, 1200));
const later = await telemetry();
check("lab09: pending correlated into a confirmed entity",
  later.nPending === 0 && later.nConfirmed >= 1,
  `pending=${later.nPending} confirmed=${later.nConfirmed}`);
check("lab09: measured input lead > 0", later.lastLeadMs > 20, `lead=${later.lastLeadMs?.toFixed?.(0)} ms`);

await new Promise((r) => setTimeout(r, 2200));
const withTurret = await telemetry();
check("lab09: foreign (turret) projectiles arrive un-predicted",
  withTurret.nForeign >= 1, `foreign=${withTurret.nForeign}`);

// ---- Lab 10 -----------------------------------------------------------------
await page.goto(`http://localhost:${port}/?private=1#10-composite-sim`, { waitUntil: "networkidle2" });
await page.waitForFunction(() => window.__lab?.id === "10-composite-sim", { timeout: 15000 });
await page.evaluate(() => window.__net(200, 0));
await page.evaluate(() => window.__lab.room.send("bot", { on: false }));
await page.evaluate(() => window.__lab.room.send("resetPuck"));
await new Promise((r) => setTimeout(r, 1000));

// Skate INTO the puck — steer toward it by telemetry.
const t0 = await telemetry();
let puckMovedAt = 0;
const start = Date.now();
while (Date.now() - start < 6000) {
  const t = await telemetry();
  if (Math.hypot(t.puckX - t0.puckX, t.puckY - t0.puckY) > 1) { puckMovedAt = Date.now(); break; }
  const dx = t.puckX - t.paddleX, dy = t.puckY - t.paddleY;
  if (dy < -0.5) { await page.keyboard.up("KeyS"); await page.keyboard.down("KeyW"); }
  else if (dy > 0.5) { await page.keyboard.up("KeyW"); await page.keyboard.down("KeyS"); }
  if (dx < -0.5) { await page.keyboard.up("KeyD"); await page.keyboard.down("KeyA"); }
  else if (dx > 0.5) { await page.keyboard.up("KeyA"); await page.keyboard.down("KeyD"); }
  await new Promise((r) => setTimeout(r, 60));
}
for (const k of ["KeyW", "KeyA", "KeyS", "KeyD"]) await page.keyboard.up(k);
check("lab10: predicted puck responds to the hit", puckMovedAt > 0);

if (puckMovedAt) {
  // Immediately after the hit the SERVER ghost must still be (nearly) at rest —
  // the response we saw was the prediction, not the round trip.
  const justAfter = await telemetry();
  const serverMoved = Math.abs(justAfter.serverPuckX - t0.puckX) > 1;
  check("lab10: server puck still behind at hit time (the response was predicted)",
    !serverMoved || Math.hypot(justAfter.puckX - justAfter.serverPuckX, 0) > 0.5,
    `predictedX=${justAfter.puckX.toFixed(1)} serverX=${justAfter.serverPuckX.toFixed(1)}`);
  // Convergence: while the puck flies, predicted-vs-truth gap ≈ v × RTT (the
  // prediction LEADING is the point) — the real agreement signal is the drift
  // ema staying ~0: every reconcile re-derives the shot from truth and lands
  // where the prediction already was.
  // (A few tenths of a unit while the puck passes remote colliders is
  // inherent: replays re-read remote paddles from fresher snapshots. It
  // decays to ~0 as the puck settles.)
  await new Promise((r) => setTimeout(r, 4000));
  const settled = await telemetry();
  check("lab10: replay agrees with the server (drift ema ~ 0)",
    settled.driftEma < 0.25,
    `driftEma=${settled.driftEma.toFixed(4)} gap=${Math.abs(settled.puckX - settled.serverPuckX).toFixed(2)}u`);
}

// ---- Lab 10, BOT ON ---------------------------------------------------------
// The checks above disable the bot to isolate our own step — which for a long
// time meant NOTHING covered the configuration the lab actually ships in. The
// bot chases the puck, so it contests nearly every touch; while it was frozen
// at its last snapshot inside the predicted step, each contest mispredicted and
// drift sat around 2.0 (measured) even though every test was green.
await page.evaluate(() => window.__lab.room.send("bot", { on: true }));
await page.evaluate(() => window.__lab.room.send("resetPuck"));
await new Promise((r) => setTimeout(r, 1500));
{
  let peak = 0, sum = 0, n = 0;
  const start = Date.now();
  while (Date.now() - start < 12000) {
    const t = await telemetry();
    const dx = t.puckX - t.paddleX, dy = t.puckY - t.paddleY;
    if (dy < -0.5) { await page.keyboard.up("KeyS"); await page.keyboard.down("KeyW"); }
    else if (dy > 0.5) { await page.keyboard.up("KeyW"); await page.keyboard.down("KeyS"); }
    if (dx < -0.5) { await page.keyboard.up("KeyD"); await page.keyboard.down("KeyA"); }
    else if (dx > 0.5) { await page.keyboard.up("KeyA"); await page.keyboard.down("KeyD"); }
    if (typeof t.driftEma === "number") { peak = Math.max(peak, t.driftEma); sum += t.driftEma; n++; }
    await new Promise((r) => setTimeout(r, 60));
  }
  for (const k of ["KeyW", "KeyA", "KeyS", "KeyD"]) await page.keyboard.up(k);
  // MEAN, not peak: a single contested bounce swings the peak (0.46 and 0.98 on
  // two runs of the fixed build), while the mean separated cleanly — 2.06 with
  // the bot frozen vs 0.05 predicted, measured back to back on this harness.
  // 0.5 sits an order of magnitude above the good case and 4x below the bad.
  const mean = n ? sum / n : Infinity;
  check("lab10: contesting the BOT still agrees with the server",
    mean < 0.5,
    `driftEma mean=${mean.toFixed(4)} peak=${peak.toFixed(4)} while the bot contested every touch`);
}

check("no page errors", errors.length === 0, errors[0]);

await browser.close();
console.log(fail === 0 ? "\nPROBE OK" : `\nPROBE FAILED (${fail})`);
process.exit(fail === 0 ? 0 : 1);
