// Drop + reconnect (what the debug panel's "Drop" button does): close the
// transport with MAY_TRY_RECONNECT, let the SDK auto-reconnect into the seat
// the server held (onDrop → allowReconnection), and assert prediction still
// works — the lab must reset its reconciler (fresh input counter) or the pose
// freezes. Usage: node scripts/probe-reconnect.mjs [port]
import puppeteer from "puppeteer";

const port = process.argv[2] ?? process.env.PORT ?? "5173";
const MAY_TRY_RECONNECT = 4010;

const browser = await puppeteer.launch({ headless: "shell" });
const page = await browser.newPage();
const errors = [];
page.on("pageerror", (err) => errors.push(String(err)));

let fail = 0;
const check = (name, ok, detail) => {
  console.log(`${ok ? "OK  " : "FAIL"} ${name}${detail ? ` — ${detail}` : ""}`);
  if (!ok) fail++;
};

await page.goto(`http://localhost:${port}/?private=1#03-reconcile`, { waitUntil: "networkidle2" });
await page.waitForFunction(() => window.__lab?.id === "03-reconcile", { timeout: 15000 });

// The SDK refuses auto-reconnect inside its minUptime window (5 s default) —
// a drop that early is a terminal leave (the shell then rejoins fresh). Wait
// past it so this probe exercises the SEAT reconnection path.
await new Promise((r) => setTimeout(r, 5500));

// Drive a little so the pre-drop session has a prediction backlog.
await page.keyboard.down("KeyD");
await new Promise((r) => setTimeout(r, 700));
await page.keyboard.up("KeyD");

const sessionBefore = await page.evaluate(() => window.__lab.room.sessionId);

// Drop, exactly like the panel's button. On localhost the auto-reconnect can
// complete within ~100 ms, so poll fast for the transient status message —
// and accept "already reconnected" as a pass.
await page.evaluate((code) => window.__lab.room.connection.close(code), MAY_TRY_RECONNECT);
let sawStatus = false;
for (let i = 0; i < 25 && !sawStatus; i++) {
  sawStatus = await page.evaluate(() =>
    document.getElementById("stage-msg").style.display !== "none");
  await new Promise((r) => setTimeout(r, 20));
}
const alreadyBack = !sawStatus && await page.evaluate(
  (sid) => window.__lab.room.sessionId === sid &&
    document.getElementById("stage-msg").style.display === "none", sessionBefore);
check("drop surfaces the reconnecting status (or reconnects instantly)", sawStatus || alreadyBack,
  sawStatus ? "status shown" : "reconnected before the first poll");

// Wait for the auto-reconnect (SDK retries; the server holds the seat 10 s).
await page.waitForFunction(() =>
  document.getElementById("stage-msg").style.display === "none", { timeout: 12000 })
  .catch(() => {});
const sessionAfter = await page.evaluate(() => window.__lab.room.sessionId);
check("auto-reconnected into the held seat", sessionAfter === sessionBefore,
  `session ${sessionBefore} → ${sessionAfter}`);

// Prediction must still be alive: predicted pose responds, drift settles.
await new Promise((r) => setTimeout(r, 600));
const before = await page.evaluate(() => window.__lab.telemetry.predictedX);
await page.keyboard.down("KeyA");
await new Promise((r) => setTimeout(r, 500));
await page.keyboard.up("KeyA");
const after = await page.evaluate(() => window.__lab.telemetry);
check("prediction responsive after reconnect", Math.abs(after.predictedX - before) > 1,
  `Δx=${(after.predictedX - before).toFixed(2)}`);
// The reconnect instant itself can leave a sub-unit ema blip (inputs race the
// full-state resync); clean reconciles decay it — poll for the settle.
let settled = null;
for (let i = 0; i < 12; i++) {
  await new Promise((r) => setTimeout(r, 500));
  settled = await page.evaluate(() => window.__lab.telemetry);
  if (settled.status !== "diverging") break;
}
check("no stale-backlog divergence after reconnect", settled.status !== "diverging",
  `status=${settled.status} ema=${settled.driftEma}`);

check("no page errors", errors.length === 0, errors[0]);

await browser.close();
console.log(fail === 0 ? "\nPROBE OK" : `\nPROBE FAILED (${fail})`);
process.exit(fail === 0 ? 0 : 1);
