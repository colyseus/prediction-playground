// Browser smoke: iterate every built lab (via the top bar's lab select), wait
// for frames, assert no console errors and that window.__lab.id matches.
// Usage: node scripts/browser-smoke.mjs [port]
import puppeteer from "puppeteer";

const port = process.argv[2] ?? process.env.PORT ?? "5173";
const base = `http://localhost:${port}`;
const shot = process.env.SHOT; // optional screenshot dir

const browser = await puppeteer.launch({ headless: "shell" });
const page = await browser.newPage();
await page.setViewport({ width: 1440, height: 900 });

const errors = [];
page.on("console", (msg) => { if (msg.type() === "error") errors.push(msg.text()); });
page.on("pageerror", (err) => errors.push(String(err)));

await page.goto(`${base}/?private=1`, { waitUntil: "networkidle2" });
await page.waitForFunction(() => window.__lab?.id, { timeout: 15000 });

// Built lab ids = the select's enabled options.
const ids = await page.evaluate(() =>
  [...document.querySelectorAll("#lab-select option")]
    .filter((o) => !o.disabled)
    .map((o) => o.value)
);
let failures = 0;

for (const id of ids) {
  await page.evaluate((labId) => { location.hash = labId; }, id);
  await new Promise((r) => setTimeout(r, 2500));
  const labId = await page.evaluate(() => window.__lab?.id);
  const selected = await page.evaluate(() => document.getElementById("lab-select").value);
  const ok = labId === id && selected === id;
  console.log(`${ok ? "OK  " : "FAIL"} lab=${labId} selected=${selected}`);
  if (!ok) failures++;
  if (shot) await page.screenshot({ path: `${shot}/lab-${labId}.png` });
}

if (errors.length) {
  console.error(`\n${errors.length} console error(s):`);
  for (const e of errors.slice(0, 10)) console.error(" -", e.slice(0, 300));
  failures++;
}

await browser.close();
console.log(failures === 0 ? "\nSMOKE OK" : `\nSMOKE FAILED (${failures})`);
process.exit(failures === 0 ? 0 : 1);
