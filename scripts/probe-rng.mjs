// Lab 11 core claim, CI-checkable: the client-derived pellet fan and the
// server-derived fan are IDENTICAL (seq+salt seeded, nothing on the wire) —
// and Math.random() breaks it. Usage: node scripts/probe-rng.mjs [port]
import puppeteer from "puppeteer";

const port = process.argv[2] ?? process.env.PORT ?? "5173";
const browser = await puppeteer.launch({ headless: "shell" });
const page = await browser.newPage();
const errors = [];
page.on("pageerror", (err) => errors.push(String(err)));

await page.goto(`http://localhost:${port}/?private=1#11-deterministic-rng`, { waitUntil: "networkidle2" });
await page.waitForFunction(() => window.__lab?.id === "11-deterministic-rng", { timeout: 15000 });
await page.evaluate(() => window.__net(200, 0));
await new Promise((r) => setTimeout(r, 1200));

let fail = 0;
const check = (name, ok, detail) => {
  console.log(`${ok ? "OK  " : "FAIL"} ${name}${detail ? ` — ${detail}` : ""}`);
  if (!ok) fail++;
};

// Deterministic fans: 3 shots, every one must match to float precision.
let worst = 0;
for (let i = 0; i < 3; i++) {
  await page.evaluate(() => window.__lab.telemetry.fire(50, 14));
  await new Promise((r) => setTimeout(r, 900));
  const d = await page.evaluate(() => window.__lab.telemetry.maxDivergence);
  worst = Math.max(worst, d ?? Infinity);
}
check("client fan == server fan (seq+salt seeded)", worst < 1e-9, `worst divergence=${worst} rad`);

// Math.random fans: must diverge.
await page.evaluate(() => window.__lab.telemetry.setCheat(true));
await page.evaluate(() => window.__lab.telemetry.fire(50, 14));
await new Promise((r) => setTimeout(r, 900));
const cheatDiv = await page.evaluate(() => window.__lab.telemetry.maxDivergence);
check("Math.random() fan visibly diverges", cheatDiv > 0.005, `divergence=${cheatDiv?.toFixed?.(4)} rad`);

check("no page errors", errors.length === 0, errors[0]);

await browser.close();
console.log(fail === 0 ? "\nPROBE OK" : `\nPROBE FAILED (${fail})`);
process.exit(fail === 0 ? 0 : 1);
