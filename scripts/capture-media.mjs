// Reproducible showcase media: screencast clips of the visual-star labs into
// GIFs (two-pass ffmpeg palette encode) plus the 1200×630 og image.
// Re-run whenever the labs change so README media never goes stale.
// Requires a running dev server and ffmpeg on PATH.
// Usage: node scripts/capture-media.mjs [port]     → writes into media/
import puppeteer from "puppeteer";
import { execFileSync } from "node:child_process";
import { mkdirSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const port = process.argv[2] ?? process.env.PORT ?? "5173";
const base = `http://localhost:${port}`;
const MEDIA = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "media");
const WORK = path.join(MEDIA, ".work");
mkdirSync(WORK, { recursive: true });

const VIEW = { width: 1440, height: 900 };
const STAGE = { x: 0, y: 0, width: 1144, height: 900 }; // canvas sans the 296px right panel

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const browser = await puppeteer.launch({ headless: "shell" });

async function openLab(labId, { latency = null, viewport = VIEW } = {}) {
  const page = await browser.newPage();
  await page.setViewport(viewport);
  page.on("pageerror", (err) => console.error(`[${labId}] pageerror:`, String(err).slice(0, 200)));
  await page.goto(`${base}/?private=1#${labId}`, { waitUntil: "networkidle2" });
  await page.waitForFunction((id) => window.__lab?.id === id, { timeout: 20000 }, labId);
  // Fresh browser = first visit — collapse the auto-expanded docs panel.
  await page.evaluate(() => document.getElementById("docs").classList.add("collapsed"));
  if (latency !== null) await page.evaluate((ms) => window.__net(ms, 30), latency);
  await sleep(1800); // let clocks/Predicts settle at the new RTT
  return page;
}

async function record(page, name, driver, crop = STAGE) {
  const webm = path.join(WORK, `${name}.webm`);
  const t0 = Date.now();
  const rec = await page.screencast({ path: webm, crop });
  await driver(page);
  await rec.stop();
  const wallSec = (Date.now() - t0) / 1000;

  // Headless delivers frames well below the recorder's nominal rate, so the
  // raw webm plays too fast — stretch PTS back to wall-clock duration.
  const probe = execFileSync("ffprobe", ["-v", "error", "-count_frames", "-select_streams", "v:0",
    "-show_entries", "stream=nb_read_frames,avg_frame_rate", "-of", "csv=p=0", webm]).toString().trim();
  const [rateStr, framesStr] = probe.split(",");
  const [num, den] = rateStr.split("/").map(Number);
  const nominalSec = Number(framesStr) / (num / (den || 1));
  const stretch = (wallSec / nominalSec).toFixed(4);

  const palette = path.join(WORK, `${name}-palette.png`);
  const gif = path.join(MEDIA, `${name}.gif`);
  const filters = `setpts=${stretch}*PTS,fps=14,scale=960:-1:flags=lanczos`;
  execFileSync("ffmpeg", ["-y", "-i", webm, "-vf", `${filters},palettegen`, palette], { stdio: "ignore" });
  execFileSync("ffmpeg", ["-y", "-i", webm, "-i", palette, "-lavfi",
    `${filters}[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=4`, gif], { stdio: "ignore" });
  console.log(`media/${name}.gif  ${(statSync(gif).size / 1e6).toFixed(1)} MB  (${wallSec.toFixed(1)}s)`);
}

// ---- hero: Lab 00's self-playing split screen (it injects its own 200 ms) --
{
  const page = await openLab("00-split");
  await sleep(1500); // autopilot lays down some trail first
  await record(page, "hero", () => sleep(9000));
  await page.close();
}

// ---- lab 06: aim at what you SEE — hits flip to misses when lag comp goes off
{
  const page = await openLab("06-lag-comp", { latency: 200 });
  await record(page, "lab-06-lagcomp", async (p) => {
    for (let i = 0; i < 8; i++) {
      await p.evaluate(() => {
        const t = window.__lab.telemetry;
        t.fire(t.botLerpX, t.botLerpY);
      });
      await sleep(650);
      if (i === 3) await p.evaluate(() => window.__lab.room.send("lagcomp", { on: false }));
    }
    await sleep(600);
  });
  await page.close();
}

// ---- lab 10: predicted air-hockey world, dashed server ghost trailing ------
{
  const page = await openLab("10-composite-sim", { latency: 200 });
  await record(page, "lab-10-hockey", async (p) => {
    const seq = [["KeyD", 1100], ["KeyW", 500], ["KeyA", 900], ["KeyS", 600],
                 ["KeyD", 1000], ["KeyA", 700], ["KeyD", 900], ["KeyW", 600]];
    for (const [code, ms] of seq) {
      await p.keyboard.down(code);
      await sleep(ms);
      await p.keyboard.up(code);
      await sleep(150);
    }
  });
  await page.close();
}

// ---- lab 11: identical pellet fans — until Math.random() breaks them ------
{
  const page = await openLab("11-deterministic-rng", { latency: 200 });
  await record(page, "lab-11-rng", async (p) => {
    for (const [x, y] of [[50, 14], [30, 40], [70, 40]]) {
      await p.evaluate((tx, ty) => window.__lab.telemetry.fire(tx, ty), x, y);
      await sleep(1100);
    }
    await p.evaluate(() => window.__lab.telemetry.setCheat(true));
    for (const [x, y] of [[50, 30], [40, 20]]) {
      await p.evaluate((tx, ty) => window.__lab.telemetry.fire(tx, ty), x, y);
      await sleep(1100);
    }
  });
  await page.close();
}

// ---- lab 04: one bot rendered four ways + the sample timeline strip --------
{
  const page = await openLab("04-interp-modes", { latency: 200 });
  await page.evaluate(() => window.__lab.room.send("pattern", { kind: "circle" }));
  await sleep(1200);
  await record(page, "lab-04-interp", () => sleep(8000));
  await page.close();
}

// ---- og image: the split screen + title card, 1200×630 --------------------
{
  const page = await openLab("00-split", { viewport: { width: 1200, height: 630 } });
  await page.evaluate(() => {
    // og is a poster, not the app: hide chrome, keep the SDK panels + canvas.
    for (const id of ["panel", "labstrip", "topbar", "docs"]) {
      const el = document.getElementById(id);
      if (el) el.style.display = "none";
    }
  });
  await sleep(2600); // autopilot draws the diverging trails
  await page.evaluate(() => {
    const el = document.createElement("div");
    el.style.cssText = "position:fixed;inset:0;z-index:100;pointer-events:none;display:flex;flex-direction:column;justify-content:flex-end;padding:34px 42px;background:linear-gradient(transparent 52%, rgba(5,8,15,0.92));font-family:-apple-system,system-ui,sans-serif;";
    el.innerHTML = `
      <div style="font-size:46px;font-weight:800;color:#d8e2f0;">
        <span style="color:#ffd36b;">⚡</span> Prediction Playground</div>
      <div style="font-size:21px;color:#8aa0c0;margin-top:10px;">
        11 interactive netcode labs — prediction · reconciliation · interpolation · lag compensation</div>`;
    document.body.appendChild(el);
  });
  const og = path.join(MEDIA, "og.png");
  await page.screenshot({ path: og });
  console.log(`media/og.png  ${(statSync(og).size / 1e3).toFixed(0)} KB`);
  await page.close();
}

await browser.close();
console.log("\nMEDIA DONE");
