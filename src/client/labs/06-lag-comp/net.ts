import type { Client, InputHandle } from "@colyseus/sdk";
import { Predict, type Reconciler } from "@colyseus/sdk/predict";
import { joinLab } from "../../framework/net.ts";
import { stepEntity } from "../../../shared/movement.ts";
import { REMOTE_INTERP_MS } from "../../../shared/constants.ts";
import { RangeState, type RangeInput, type RangePlayer } from "../../../server/schema/range.ts";

/**
 * Lab 06 — server-side lag compensation.
 *
 * The client's job is only to be HONEST about its display timeline:
 *  - bots are DRAWN with lerp, `REMOTE_INTERP_MS` in the past;
 *  - the server records bot history and, on a fire input, rewinds every
 *    target to this client's render time (`rewind.lastSeenBy(sessionId)`) —
 *    the same instant the shooter aimed at. See src/server/rooms/RangeRoom.ts.
 *  - `allowRewind: (d) => d.fire` stamps the render time ONLY on fire frames
 *    (movement inputs don't need the extra wire byte).
 */
export async function connect(client: Client) {
  const room = await joinLab<RangeState>(client, "lab-range", RangeState);

  const predict = Predict.get(room, { name: "range" });
  // Bots on the lerp timeline — the timeline the server rewinds to
  // (rewind mode:"snapshot" pairs with an interpolated display).
  predict.attachAll("bots", {
    x: { mode: "lerp", delay: REMOTE_INTERP_MS },
    y: { mode: "lerp", delay: REMOTE_INTERP_MS },
  });
  predict.attachAll("players", { mode: "damped", fields: ["x", "y"] });

  const input = room.input<RangeInput>({
    mode: "reliable",
    allowRewind: (d) => d.fire,
  });

  return { room, predict, input };
}

/** Own movement predicted exactly as in Lab 03. */
export function makeReconciler(
  predict: Predict<RangeState>,
  self: RangePlayer,
  input: InputHandle<RangeInput>,
): Reconciler<RangePlayer, any> {
  return predict.reconciler(self, {
    input,
    fields: ["x", "y", "vx", "vy"],
    smoothMs: 65,
    step: (ctx, predicted, inp) => stepEntity(predicted, inp, ctx.dt),
  });
}
