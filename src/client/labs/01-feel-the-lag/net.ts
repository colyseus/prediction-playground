import type { Client } from "@colyseus/sdk";
import { joinLab } from "../../framework/net.ts";
import { MoveState, type MoveInput } from "../../../server/schema/move.ts";

/**
 * Lab 01 — NO prediction. This is everything the network layer does here:
 * join, open an input channel, and send one input per fixed server tick.
 * The player square renders straight from the server state — so every
 * movement waits a full round trip (plus the patch interval) to show up.
 */
export async function connect(client: Client) {
  const room = await joinLab<MoveState>(client, "lab-move", MoveState);

  // One reliable input channel. The server drains ONE input per fixed tick
  // and runs the shared stepEntity() on it — the engine's input counter is
  // the sequence; dt never goes on the wire.
  const input = room.input<MoveInput>({ mode: "reliable" });

  return { room, input };
}
