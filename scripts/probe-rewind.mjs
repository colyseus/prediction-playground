// The lag-comp core claim, CI-checkable: at 250 ms simulated latency, aiming
// EXACTLY at the on-screen (lerp-delayed) bot...
//   - hits with lag compensation ON  (server rewinds to what the shooter saw)
//   - mostly misses with lag comp OFF (the live bot is ~7-8 u ahead of the view)
// Usage: node scripts/probe-rewind.mjs [port]
import puppeteer from "puppeteer";

const port = process.argv[2] ?? process.env.PORT ?? "5173";
const LATENCY = 250;
const SHOTS = 8;

const browser = await puppeteer.launch({ headless: "shell" });
const page = await browser.newPage();
const errors = [];
page.on("pageerror", (err) => errors.push(String(err)));

await page.goto(`http://localhost:${port}/?private=1#06-lag-comp`, { waitUntil: "networkidle2" });
await page.waitForFunction(() => window.__lab?.id === "06-lag-comp", { timeout: 15000 });
await page.evaluate((ms) => window.__net(ms, 0), LATENCY);
await new Promise((r) => setTimeout(r, 1500));

async function volley() {
  for (let i = 0; i < SHOTS; i++) {
    await page.evaluate(() => {
      const t = window.__lab.telemetry;
      t.fire(t.botLerpX, t.botLerpY); // aim dead-on at the on-screen bot
    });
    await new Promise((r) => setTimeout(r, 450));
  }
  await new Promise((r) => setTimeout(r, 800)); // let the last report land
  return page.evaluate(() => {
    const t = window.__lab.telemetry;
    return { on: [t.hitsOn, t.shotsOn], off: [t.hitsOff, t.shotsOff], predicted: t.predictedHits };
  });
}

let fail = 0;
const check = (name, ok, detail) => {
  console.log(`${ok ? "OK  " : "FAIL"} ${name}${detail ? ` — ${detail}` : ""}`);
  if (!ok) fail++;
};

// Volley 1: lag comp ON (default).
const t1 = await volley();
check("shots registered (lag comp ON)", t1.on[1] >= SHOTS - 1, `shots=${t1.on[1]}`);
check("aiming at what you SEE hits with lag comp ON",
  t1.on[0] / Math.max(1, t1.on[1]) >= 0.75,
  `${t1.on[0]}/${t1.on[1]} at ${LATENCY}ms`);
// The ray is drawn from the client's own verdict at the click, then redrawn
// from the server's. Aiming dead-on, the client must call every shot a hit —
// so with lag comp ON the two agree, and the ray keeps its colour.
check("the client calls every dead-on shot a hit (lag comp ON)",
  t1.predicted >= SHOTS - 1, `predicted ${t1.predicted}/${SHOTS}`);

// Volley 2: lag comp OFF.
await page.evaluate(() => window.__lab.room.send("lagcomp", { on: false }));
await new Promise((r) => setTimeout(r, 800));
const t2 = await volley();
const offHits = t2.off[0], offShots = t2.off[1];
check("shots registered (lag comp OFF)", offShots >= SHOTS - 1, `shots=${offShots}`);
check("the same aim mostly MISSES with lag comp OFF",
  offHits / Math.max(1, offShots) <= 0.4,
  `${offHits}/${offShots} at ${LATENCY}ms`);
// Same dead-on aim, so the client still calls them all hits while the server
// mostly misses: the ray flashes green at the click and resolves red.
const predictedOff = t2.predicted - t1.predicted;
check("client says hit, server says miss with lag comp OFF",
  predictedOff >= SHOTS - 1 && offHits < predictedOff,
  `predicted ${predictedOff}/${SHOTS}, server ${offHits}/${offShots}`);

// The marker geometry: server's rewound read (green) ≈ what the shooter saw (blue).
await page.evaluate(() => window.__lab.room.send("lagcomp", { on: true }));
await new Promise((r) => setTimeout(r, 800));
await page.evaluate(() => {
  const t = window.__lab.telemetry;
  t.fire(t.botLerpX, t.botLerpY);
});
await new Promise((r) => setTimeout(r, 900));
const s = await page.evaluate(() => window.__lab.telemetry.latestShot);
check("rewound read lands on what the shooter saw",
  s && Math.abs(s.greenX - s.blueX) < 1.5,
  s ? `|green-blue|=${Math.abs(s.greenX - s.blueX).toFixed(2)}u, |red-blue|=${Math.abs(s.redX - s.blueX).toFixed(2)}u` : "no shot report");
check("live position is visibly ahead of the view",
  s && Math.abs(s.redX - s.blueX) > 2.5,
  s ? `gap=${Math.abs(s.redX - s.blueX).toFixed(2)}u` : "");

check("no page errors", errors.length === 0, errors[0]);

await browser.close();
console.log(fail === 0 ? "\nPROBE OK" : `\nPROBE FAILED (${fail})`);
process.exit(fail === 0 ? 0 : 1);
