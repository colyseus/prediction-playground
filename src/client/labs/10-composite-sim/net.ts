import type { Client, InputHandle, Room } from "@colyseus/sdk";
import { Predict, type SimReconciler } from "@colyseus/sdk/predict";
import { joinLab } from "../../framework/net.ts";
import { stepEntity } from "../../../shared/movement.ts";
import { stepPuck, collidePaddlePuck, botInput, BOT_ID, type CircleBody } from "../../../shared/hockey.ts";
import { HockeyState, type MoveInput } from "../../../server/schema/hockey.ts";

/** The composite predicted world: my paddle, the puck, AND the bot. */
export interface HockeyWorld {
  paddle: CircleBody;
  puck: CircleBody;
  bot: CircleBody;
}

export async function connect(client: Client) {
  const room = await joinLab<HockeyState>(client, "lab-hockey", HockeyState);
  const predict = Predict.get(room, { name: "hockey" });
  // lerp, not damped: a remote paddle is a COLLIDER in the step below as well
  // as a sprite, and damped's lag varies with velocity — it rubber-bands on
  // every reversal, and the gap between the pose you see and the raw snapshot
  // the step collides against breathes with it. Lerp's delay is constant
  // (SDK default 100 ms, the same buffer the air-hockey demo uses).
  predict.attachAll("players", { mode: "lerp", fields: ["x", "y"] });
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
 * Remote HUMAN paddles enter the prediction as COLLIDERS at their latest
 * snapshot — their next input is unknowable until it arrives, so a contested
 * touch is the honest misprediction to watch for.
 *
 * The BOT is different and is predicted in full: its policy is a pure function
 * of synced state (`botTarget` — the puck it chases and `botEnabled`), so the
 * client can run the server's own decision. Left frozen it mispredicted on
 * nearly every touch, because chasing the puck is its entire policy — the
 * lesson is that "remote" and "unpredictable" are not the same thing.
 */
export function makeSim(
  predict: Predict<HockeyState>,
  room: Room<HockeyState> & { sessionId: string },
  input: InputHandle<MoveInput>,
  smoothMs: number,
): SimReconciler<any, {
  px: number; py: number; kx: number; ky: number; bx: number; by: number;
}, HockeyWorld> {
  const me = () => room.state.players.get(room.sessionId)!;
  const bot = () => room.state.players.get(BOT_ID);
  const scratch: CircleBody = { x: 0, y: 0, vx: 0, vy: 0 };
  const botCmd = { moveX: 0, moveY: 0 };

  return predict.sim({
    input,
    world: {
      paddle: { x: me().x, y: me().y, vx: me().vx, vy: me().vy },
      puck: { x: room.state.puck.x, y: room.state.puck.y, vx: room.state.puck.vx, vy: room.state.puck.vy },
      bot: { x: bot()?.x ?? 0, y: bot()?.y ?? 0, vx: bot()?.vx ?? 0, vy: bot()?.vy ?? 0 },
    } satisfies HockeyWorld,
    smoothMs,

    // What "diverging" MEANS for this world. Unset, the classifier falls back to
    // its float-noise floor of 1e-3 — the right cut for a flat reconciler, which
    // replays the server bit-exactly and corrects by 0. A composite sim cannot
    // reach that: it re-adopts an entire world every ack (`truthMatchesAt` is
    // false by design), and a remote HUMAN is a frozen collider whose next input
    // is unknowable, so a contested touch mispredicts and no amount of correct
    // code changes that. Left unset the panel therefore reads "diverging"
    // permanently and stops carrying information.
    //
    // 0.5 from measurement, not taste. With the server consuming ONE input per
    // tick (the composite-sim contract — see HockeyRoom.step), solo and bot-on
    // play replay bit-exactly down to the float32 wire floor: 30 s of pursuit
    // strikes measured ema 0.000, max correction 0.004. What 0.5 guards is the
    // honest tail — a contested HUMAN touch (a second human in the arena read
    // 0.17 pre-pacing) and client frame hitches (~1.5 u transients) — while a
    // real determinism bug sits far above: freezing the bot instead of
    // predicting it measured 2.06.
    warnOnDivergence: 0.5,

    // The server's step order, reproduced: paddles → puck → contacts.
    step: (ctx, w, cmd) => {
      stepEntity(w.paddle, cmd, ctx.dt);
      // The bot steps from the PRE-step puck, exactly as the server does — its
      // paddle loop runs before stepPuck.
      botInput(w.bot, w.puck, room.state.botEnabled, botCmd);
      stepEntity(w.bot, botCmd, ctx.dt);
      stepPuck(w.puck, ctx.dt);
      for (const [sid, p] of room.state.players) {
        if (sid === room.sessionId) {
          collidePaddlePuck(w.paddle, w.puck);
        } else if (sid === BOT_ID) {
          collidePaddlePuck(w.bot, w.puck);
        } else {
          // Remote HUMAN as a zero-delta collider at its last-known pose.
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
      const b = bot();
      if (b) { w.bot.x = b.x; w.bot.y = b.y; w.bot.vx = b.vx; w.bot.vy = b.vy; }
    },

    pose: (w) => ({
      px: w.paddle.x, py: w.paddle.y, kx: w.puck.x, ky: w.puck.y,
      bx: w.bot.x, by: w.bot.y,
    }),
  });
}
