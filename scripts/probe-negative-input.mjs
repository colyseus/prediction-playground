// Does the SERVER apply moveX=-1 correctly when sent by the JS SDK?
import { Client } from "@colyseus/sdk";

const client = new Client("ws://localhost:5173");
const room = await client.joinOrCreate("lab-move");
await new Promise((r) => setTimeout(r, 300));
const me = room.state.players.get(room.sessionId);
const x0 = me.x;
const input = room.input({ mode: "reliable" });
const timer = setInterval(() => {
  input.data.moveX = -1;
  input.data.moveY = 0;
  input.send();
}, 50);
await new Promise((r) => setTimeout(r, 1500));
clearInterval(timer);
await new Promise((r) => setTimeout(r, 200));
console.log("x0:", x0.toFixed(2), "x1:", me.x.toFixed(2), "dx:", (me.x - x0).toFixed(2));
console.log(me.x < x0 ? "SERVER MOVED LEFT (correct)" : "SERVER MOVED RIGHT (bug)");
await room.leave();
process.exit(0);
