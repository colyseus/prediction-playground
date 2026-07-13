import type { Client, InputHandle } from "@colyseus/sdk";
import { Predict, type Reconciler } from "@colyseus/sdk/predict";
import { joinLab } from "../../framework/net.ts";
import { stepEntity } from "../../../shared/movement.ts";
import { MoveState, type MoveInput, type Player } from "../../../server/schema/move.ts";

/** The reconciled field set — position AND velocity: the replay needs both. */
export const PREDICTED_FIELDS = ["x", "y", "vx", "vy"] as const;

/**
 * Lab 03 — client-side prediction + server reconciliation.
 *
 * The reconciler OBSERVES the input handle: every `input.send()` is predicted
 * locally the same instant (zero latency) and buffered. When the server's next
 * patch acks input N, the reconciler rewinds to the authoritative state and
 * REPLAYS inputs N+1.. through the same shared `stepEntity` — so the predicted
 * pose stays consistent with everything the server hasn't seen yet.
 */
export async function connect(client: Client) {
  const room = await joinLab<MoveState>(client, "lab-move", MoveState);

  const predict = Predict.get(room, { name: "players" });
  // Remote squares: damped toward the latest snapshot (their inputs are not
  // ours to predict — Lab 04 explores these modes).
  predict.attachAll("players", { mode: "damped", fields: ["x", "y"] });

  const input = room.input<MoveInput>({ mode: "reliable" });
  return { room, predict, input };
}

export function makeReconciler(
  predict: Predict<MoveState>,
  self: Player,
  input: InputHandle<MoveInput>,
  smoothing: number,
): Reconciler<Player, any> {
  return predict.reconciler(self, {
    input,
    fields: [...PREDICTED_FIELDS],
    // Visual error-correction decay: on reconcile, the on-screen pose is kept
    // and the correction bleeds in exponentially (τ ≈ 1/smoothing s).
    smoothing,
    // The SAME function the server runs — determinism is the whole contract.
    step: (ctx, predicted, inp) => stepEntity(predicted, inp, ctx.dt),
  });
}
