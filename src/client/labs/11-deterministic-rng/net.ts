import type { Client, InputHandle } from "@colyseus/sdk";
import { Predict, type Reconciler } from "@colyseus/sdk/predict";
import { joinLab } from "../../framework/net.ts";
import { stepEntity } from "../../../shared/movement.ts";
import { spreadAngles, PELLETS, SPREAD_RAD } from "../../../shared/spread.ts";
import { REMOTE_INTERP_MS } from "../../../shared/constants.ts";
import { RangeState, type RangeInput, type RangePlayer } from "../../../server/schema/range.ts";

/**
 * Lab 11 — deterministic randomness: the shotgun fan is "random", yet the
 * client predicts every pellet EXACTLY — because the randomness is a pure
 * function of data both sides already share:
 *
 *   seed = splitmix32(input seq ⊕ room salt)  →  mulberry32 pellet stream
 *
 * The seq is the engine's own input counter (`input.send()` returns it; the
 * server reads `channel.consumedCount`). The salt is synced room state,
 * rolled per room. NOTHING about the pellets rides the wire — the server's
 * broadcast here carries its angles only so this lab can overlay and compare.
 */
export async function connect(client: Client) {
  const room = await joinLab<RangeState>(client, "lab-range", RangeState);

  const predict = Predict.get(room, { name: "rng" });
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

/** The client's half of the derivation — identical to the server's. */
export function clientFan(
  baseAngle: number, seq: number, salt: number,
  cheatWithMathRandom: boolean,
  out: number[],
): number[] {
  if (cheatWithMathRandom) {
    // The broken version: a local RNG the server can't reproduce.
    for (let i = 0; i < PELLETS; i++) out[i] = baseAngle + (Math.random() - 0.5) * SPREAD_RAD;
    out.length = PELLETS;
    return out;
  }
  return spreadAngles(baseAngle, seq, salt, out);
}

export function makeReconciler(
  predict: Predict<RangeState>,
  self: RangePlayer,
  input: InputHandle<RangeInput>,
): Reconciler<RangePlayer, any> {
  return predict.reconciler(self, {
    input,
    fields: ["x", "y", "vx", "vy"],
    smoothMs: 65,
    step: (ctx, p, inp) => stepEntity(p, inp, ctx.dt),
  });
}
