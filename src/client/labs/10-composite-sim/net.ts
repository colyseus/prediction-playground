import type { Client, InputHandle, Room } from "@colyseus/sdk";
import { Predict, type SimReconciler } from "@colyseus/sdk/predict";
import { joinLab } from "../../framework/net.ts";
import { stepEntity } from "../../../shared/movement.ts";
import { stepPuck, collidePaddlePuck, type CircleBody } from "../../../shared/hockey.ts";
import { HockeyState, type MoveInput } from "../../../server/schema/hockey.ts";

/** The composite predicted world: my paddle AND the puck. */
export interface HockeyWorld {
  paddle: CircleBody;
  puck: CircleBody;
}

export async function connect(client: Client) {
  const room = await joinLab<HockeyState>(client, "lab-hockey", HockeyState);
  const predict = Predict.get(room, { name: "hockey" });
  predict.attachAll("players", { mode: "damped", fields: ["x", "y"] });
  const input = room.input<MoveInput>({ mode: "reliable" });
  return { room, predict, input };
}

/**
 * Lab 10 — `predict.sim`: predicting a world you only PARTLY control.
 *
 * The flat reconciler (Lab 03) mirrors fields of one instance. Here the puck
 * is a separate entity — yet your shots must feel instant, so the puck is
 * predicted THROUGH your own inputs: every predicted paddle step also steps
 * the puck and resolves the contact, in the server's exact order. On each
 * ack, `adopt` re-seeds the whole composite world from authoritative state
 * and the unacked inputs replay on top — a predicted shot is re-derived from
 * truth every reconcile.
 *
 * Remote paddles enter the prediction as COLLIDERS at their latest snapshot
 * (their inputs aren't ours to predict) — a contested touch is therefore the
 * honest misprediction to watch for.
 */
export function makeSim(
  predict: Predict<HockeyState>,
  room: Room<HockeyState> & { sessionId: string },
  input: InputHandle<MoveInput>,
  smoothing: number,
): SimReconciler<any, { px: number; py: number; kx: number; ky: number }, HockeyWorld> {
  const me = () => room.state.players.get(room.sessionId)!;
  const scratch: CircleBody = { x: 0, y: 0, vx: 0, vy: 0 };

  return predict.sim({
    input,
    world: {
      paddle: { x: me().x, y: me().y, vx: me().vx, vy: me().vy },
      puck: { x: room.state.puck.x, y: room.state.puck.y, vx: room.state.puck.vx, vy: room.state.puck.vy },
    } satisfies HockeyWorld,
    smoothing,

    // The server's step order, reproduced: paddles → puck → contacts.
    step: (ctx, w, cmd) => {
      stepEntity(w.paddle, cmd, ctx.dt);
      stepPuck(w.puck, ctx.dt);
      for (const [sid, p] of room.state.players) {
        if (sid === room.sessionId) {
          collidePaddlePuck(w.paddle, w.puck);
        } else {
          // Remote paddle as a zero-delta collider at its last-known pose.
          scratch.x = p.x; scratch.y = p.y; scratch.vx = p.vx; scratch.vy = p.vy;
          collidePaddlePuck(scratch, w.puck);
        }
      }
    },

    // Re-seed the WHOLE composite world from the same server tick.
    adopt: (w) => {
      const self = me();
      w.paddle.x = self.x; w.paddle.y = self.y; w.paddle.vx = self.vx; w.paddle.vy = self.vy;
      const puck = room.state.puck;
      w.puck.x = puck.x; w.puck.y = puck.y; w.puck.vx = puck.vx; w.puck.vy = puck.vy;
    },

    pose: (w) => ({ px: w.paddle.x, py: w.paddle.y, kx: w.puck.x, ky: w.puck.y }),
  });
}
