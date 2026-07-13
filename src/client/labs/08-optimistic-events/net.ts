import type { Client, InputHandle } from "@colyseus/sdk";
import { Predict, type Reconciler, type PredictedEventChannel } from "@colyseus/sdk/predict";
import { joinLab } from "../../framework/net.ts";
import { stepEntity } from "../../../shared/movement.ts";
import { stepScoreGate } from "../../../shared/goal.ts";
import { GoalState, type MoveInput, type GoalPlayer } from "../../../server/schema/goal.ts";

/**
 * Lab 08 — optimistic events: the GOAL banner fires the instant your
 * PREDICTED square crosses the line, then settles against the server:
 *
 *   predicted — `ctx.predict(goals, ...)` inside the reconciler step. Fires
 *               on the LIVE step only; rollback replays never re-fire it.
 *   confirmed — the server's "goal" broadcast → `goals.confirm()`.
 *   rejected  — no confirmation by the time the server has processed past
 *               the predicting input → auto-reject → `onReject` (undo FX).
 *
 * The zone gate itself (`stepScoreGate`) is SHARED deterministic sim over a
 * reconciled tick field — whether you *entered* is never a misprediction;
 * only the server's deny roll can reject the event.
 */
export async function connect(client: Client, hooks: {
  onPredict: () => void;
  onReject: () => void;
}) {
  const room = await joinLab<GoalState>(client, "lab-goal", GoalState);

  const predict = Predict.get(room, { name: "goal" });
  predict.attachAll("players", { mode: "damped", fields: ["x", "y"] });

  const goals: PredictedEventChannel<number> = predict.defineEvent<number>({
    label: "goal",
    onPredict: hooks.onPredict,
    onReject: hooks.onReject,
  });

  // The authoritative signal: confirm the oldest pending prediction.
  room.onMessage("goal", (msg: any) => {
    if (msg.sid === room.sessionId) goals.confirm();
  });

  const input = room.input<MoveInput>({ mode: "reliable" });
  return { room, predict, goals, input };
}

export function makeReconciler(
  predict: Predict<GoalState>,
  self: GoalPlayer,
  input: InputHandle<MoveInput>,
  goals: PredictedEventChannel<number>,
): Reconciler<GoalPlayer, any> {
  let n = 0;
  return predict.reconciler(self, {
    input,
    fields: ["x", "y", "vx", "vy", "scoreTicks"],
    smoothing: 15,
    step: (ctx, p, inp) => {
      stepEntity(p, inp, ctx.dt);
      if (stepScoreGate(p)) ctx.predict(goals, n++);   // live-only, replay-safe
    },
  });
}
