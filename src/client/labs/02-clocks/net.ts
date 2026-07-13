import type { Client } from "@colyseus/sdk";
import { joinLab } from "../../framework/net.ts";
import { BotsState, type MoveInput } from "../../../server/schema/bots.ts";

/**
 * Lab 02 — the room clock. There is no clock "API call" to make: the moment
 * the server room declares `defineInput()`, every input round-trip carries a
 * TIMED prefix and the SDK maintains `room.clock` for you:
 *
 *   room.clock.now()          — the raw local clock (self-relative cooldowns)
 *   room.clock.serverNow()    — estimated CURRENT server time (offset-EMA,
 *                               RTT-gated NTP-style; wobbles ~a little per patch)
 *   room.clock.renderNow()    — serverNow with a SLEW LIMIT (τ≈250 ms): offset
 *                               corrections glide instead of stepping — the
 *                               timeline remote entities are DRAWN on
 *   room.clock.rtt() / smoothedRtt() / jitter() / lastServerTime()
 */
export async function connect(client: Client) {
  const room = await joinLab<BotsState>(client, "lab-bots", BotsState);
  // Inputs feed the clock: one send per fixed tick = one RTT/offset sample.
  const input = room.input<MoveInput>({ mode: "reliable" });
  return { room, input };
}
