// Smoke: join lab-move headlessly, confirm the player spawns, leave.
// Usage: node scripts/probe-join.mjs [port]
import { Client } from "@colyseus/sdk";

const port = process.argv[2] ?? process.env.PORT ?? "5173";
const client = new Client(`ws://localhost:${port}`);
const room = await client.joinOrCreate("lab-move");
console.log("joined:", room.roomId, "session:", room.sessionId);
await new Promise((r) => setTimeout(r, 500));
const me = room.state.players?.get?.(room.sessionId);
if (!me) { console.error("FAIL: no player in state"); process.exit(1); }
console.log("player spawned at", me.x.toFixed(1), me.y.toFixed(1), "hue", me.hue);
await room.leave();
console.log("OK");
process.exit(0);
