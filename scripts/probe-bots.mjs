// Server bot regression: the pattern bot moves, and pattern switching works.
// (Client-side determinism is covered by probe-reconcile: drift ema == 0.)
// Usage: node scripts/probe-bots.mjs [port]
import { Client } from "@colyseus/sdk";

const port = process.argv[2] ?? process.env.PORT ?? "5173";
const client = new Client(`ws://localhost:${port}`);
const room = await client.create("lab-bots");
await new Promise((r) => setTimeout(r, 400));

let fail = 0;
const check = (name, ok, detail) => {
  console.log(`${ok ? "OK  " : "FAIL"} ${name}${detail ? ` — ${detail}` : ""}`);
  if (!ok) fail++;
};

const bot = room.state.bots.get("bot1");
check("bot exists", !!bot);

const x0 = bot.x, y0 = bot.y;
await new Promise((r) => setTimeout(r, 800));
check("patrol: x advances", Math.abs(bot.x - x0) > 3, `Δx=${(bot.x - x0).toFixed(1)}`);
check("patrol: y fixed", Math.abs(bot.y - y0) < 0.01, `Δy=${(bot.y - y0).toFixed(3)}`);

room.send("pattern", { kind: "circle" });
await new Promise((r) => setTimeout(r, 500));
// Sample ≥2 s — a 1 s window near the sine extremum has almost no y motion.
const ys = [];
for (let i = 0; i < 22; i++) { ys.push(bot.y); await new Promise((r) => setTimeout(r, 100)); }
check("circle: y varies", Math.max(...ys) - Math.min(...ys) > 2, `y span=${(Math.max(...ys) - Math.min(...ys)).toFixed(1)}`);

room.send("pattern", { kind: "teleport" });
await new Promise((r) => setTimeout(r, 200));
const seenX = new Set();
let warpSeen = false;
let prevX = bot.x;
for (let i = 0; i < 45; i++) {
  await new Promise((r) => setTimeout(r, 100));
  if (Math.abs(bot.x - prevX) > 10) warpSeen = true;
  prevX = bot.x;
}
check("teleport: warp observed within 4.5s", warpSeen);

room.send("pattern", { kind: "nonsense" });
await new Promise((r) => setTimeout(r, 200));
check("invalid pattern ignored", ["patrol", "circle", "wander", "teleport"].includes(bot.kind), `kind=${bot.kind}`);

await room.leave();
console.log(fail === 0 ? "\nPROBE OK" : `\nPROBE FAILED (${fail})`);
process.exit(fail === 0 ? 0 : 1);
