import type { Client, Room } from "@colyseus/sdk";
import { Predict } from "@colyseus/sdk/predict";
import { joinLab } from "../../framework/net.ts";
import { BotsState, type MoveInput } from "../../../server/schema/bots.ts";

export type OverlayMode = "raw" | "lerp" | "damped" | "extrapolate";
export interface OverlayOpts { delay?: number; damping?: number; maxExtrapolate?: number; }

/**
 * Lab 04 — the SAME bot rendered through four different Predict instances,
 * one per interpolation mode (the FPS demo's ghost-overlay trick). Each
 * Predict gets its own debug-panel card, so panel tuning stays per-mode.
 *
 *   raw         — the decoded snapshot verbatim: stutters at patch rate.
 *   lerp        — render `delay` ms in the PAST, between two real samples.
 *                 Never wrong, always late.
 *   damped      — exponential chase of the newest sample. No added delay
 *                 setting, but it lags by construction and rounds corners.
 *   extrapolate — project the trend FORWARD. Present-time, but overshoots
 *                 whenever the bot turns.
 */
export async function connect(client: Client) {
  const room = await joinLab<BotsState>(client, "lab-bots", BotsState);
  // The input channel paces one send per fixed tick: it feeds the RTT/clock
  // sync AND lets you drive your own square around while you watch.
  const input = room.input<MoveInput>({ mode: "reliable" });
  return { room, input };
}

export function makeOverlay(room: Room<BotsState>, mode: OverlayMode, opts: OverlayOpts) {
  const predict = Predict.get(room, { name: mode });
  // "raw" needs NO attach: predict.value() falls through to the decoded field.
  // The opts here are just STARTING values — every parameter (delay, damping,
  // maxExtrapolate, tickInterval, snap) is live-tunable in this Predict's own
  // debug-panel card (top left), one card per mode.
  const detach = mode === "raw"
    ? () => {}
    : predict.attachAll("bots", {
        x: { mode, ...opts },
        y: { mode, ...opts },
      });
  return {
    predict,
    dispose() { detach(); predict.dispose(); },
  };
}
