import type { Client, InputHandle } from "@colyseus/sdk";
import { Predict, type Reconciler, type StepContext } from "@colyseus/sdk/predict";
import { joinLab } from "../../framework/net.ts";
import { stepEntity } from "../../../shared/movement.ts";
import { stepBot } from "../../../shared/movers.ts";
import { stepBumpGate, collideBot, BUMP_COOLDOWN_TICKS } from "../../../shared/bump.ts";
import { BumpState, type MoveInput, type BumpPlayer } from "../../../server/schema/bump.ts";

export type BotReadMode = "reckonTime" | "stale";

/**
 * Lab 07 — "what you see is what you hit", by construction.
 *
 * The collision against the moving bot is predicted INSIDE the reconciler
 * step. Two ingredients make the client's verdict equal the server's:
 *
 *  1. `predict.valueAt(bot, "x", ctx.reckonTime)` — read the bot at the
 *     instant the server will REWIND this input to (its reckon timeline).
 *     Reading anything else (the stale snapshot, or the smoothed render pose)
 *     tests against a position the server never uses.
 *
 *  2. `ctx.memo(...)` — the verdict is NOT re-derivable on rollback replay
 *     (the client keeps no bot history; a later replay would read the bot
 *     reckoned from a NEWER snapshot and could flip the call). memo runs the
 *     test once on the live step and replays the outcome verbatim until the
 *     server acks that seq.
 */
export async function connect(client: Client) {
  const room = await joinLab<BumpState>(client, "lab-bump", BumpState);

  const predict = Predict.get(room, {
    mode: "reckon",
    step: stepBot,
    smoothMs: 40,
    name: "bots",
  });
  predict.attachAll("bots", { fields: ["x", "y"] });
  predict.attachAll("players", { mode: "damped", fields: ["x", "y"] });

  const input = room.input<MoveInput>({ mode: "reliable" });
  return { room, predict, input };
}

export interface WysiwygFlags {
  useValueAt: boolean;   // OFF = read the raw (stale) snapshot instead
  useMemo: boolean;      // OFF = re-derive the verdict on every replay
}

export function makeReconciler(
  predict: Predict<BumpState>,
  room: { state: BumpState; clock: { serverNow(): number } },
  self: BumpPlayer,
  input: InputHandle<MoveInput>,
  flags: WysiwygFlags,
  onBump: () => void,
): Reconciler<BumpPlayer, any> {
  const bots = room.state.bots;

  const testBots = (p: BumpPlayer, when: number) => {
    for (const [, bot] of bots) {
      const bx = flags.useValueAt ? predict.valueAt(bot, "x", when) : bot.x;
      const by = flags.useValueAt ? predict.valueAt(bot, "y", when) : bot.y;
      const hit = collideBot(p, bx, by);
      if (hit) return hit;
    }
    return null;
  };

  return predict.reconciler(self, {
    input,
    fields: ["x", "y", "vx", "vy", "bumpTicks"],
    smoothMs: 65,
    step: (ctx: StepContext, p: BumpPlayer, inp) => {
      stepBumpGate(p);                       // reconciled tick gate (both sides)
      stepEntity(p, inp, ctx.dt);
      // The server rewinds THIS input to ctx.reckonTime — test there.
      const when = ctx.reckonTime;
      const hit = flags.useMemo
        ? ctx.memo("bump", () => testBots(p, when))
        : testBots(p, when);
      if (hit) {
        p.vx = hit.vx;
        p.vy = hit.vy;
        p.bumpTicks = BUMP_COOLDOWN_TICKS;   // immunity rides adopt+replay
        if (!ctx.isReplay) onBump();         // FX/counters: live step only
      }
    },
  });
}
