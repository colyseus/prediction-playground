import type { Client, Room } from "@colyseus/sdk";
import { Predict } from "@colyseus/sdk/predict";
import { joinLab } from "../../framework/net.ts";
import { stepBot } from "../../../shared/movers.ts";
import { BotsState, type MoveInput } from "../../../server/schema/bots.ts";

/**
 * Lab 05 — dead reckoning: instead of drawing the PAST (lerp), forward-
 * simulate the latest snapshot to the PRESENT with the same step function the
 * server runs. The reckon horizon is exactly the snapshot age.
 */
export async function connect(client: Client) {
  const room = await joinLab<BotsState>(client, "lab-bots", BotsState);
  const input = room.input<MoveInput>({ mode: "reliable" });

  // The delayed baseline to compare against.
  const lerp = Predict.get(room, { name: "lerp-ghost" });
  const detachLerp = lerp.attachAll("bots", {
    x: { mode: "lerp", delay: 100 },
    y: { mode: "lerp", delay: 100 },
  });

  return { room, input, lerp, disposeLerp: () => { detachLerp(); lerp.dispose(); } };
}

/**
 * The reckon overlay. `stepBot` is the SHARED mover: patrol bounces, the
 * circle's closed form, and the teleporter's warp schedule all replay
 * identically here — reading `elapsedMs` on the server-clock timeline makes
 * any forward instant evaluable.
 *
 *   smoothing — glide applied to each snapshot REBASE (the small correction
 *               when a patch lands mid-glide).
 *   snap      — rebases beyond this distance POP instead of gliding: a
 *               teleport is a cut; smoothing across it looks like flying.
 */
export function makeReckon(room: Room<BotsState>, opts: { smoothing: number; snap: number }) {
  const predict = Predict.get(room, {
    mode: "reckon",
    step: stepBot,
    smoothing: opts.smoothing,
    name: "reckon",
  });
  const detach = predict.attachAll("bots", {
    fields: ["x", "y"],
    smoothing: opts.smoothing,
    snap: opts.snap,
  });
  return { predict, dispose() { detach(); predict.dispose(); } };
}
