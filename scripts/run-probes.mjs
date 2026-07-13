// Run every probe against a running dev server (pnpm dev).
// Usage: node scripts/run-probes.mjs [port]
import { spawnSync } from "node:child_process";

const port = process.argv[2] ?? process.env.PORT ?? "5173";
const probes = [
  "probe-join.mjs",
  "probe-bots.mjs",
  "probe-reconcile.mjs",
  "probe-rewind.mjs",
  "probe-events.mjs",
  "probe-spawns.mjs",
  "probe-rng.mjs",
  "probe-reconnect.mjs",
  "browser-smoke.mjs",
];

let failed = 0;
for (const p of probes) {
  console.log(`\n━━━ ${p} ━━━`);
  const res = spawnSync("node", [`scripts/${p}`, port], { stdio: "inherit" });
  if (res.status !== 0) failed++;
}
console.log(failed === 0 ? "\nALL PROBES OK" : `\n${failed} PROBE(S) FAILED`);
process.exit(failed === 0 ? 0 : 1);
