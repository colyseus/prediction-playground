import type { Client } from "@colyseus/sdk";

/**
 * Join a lab room. Multiple tabs land in the SAME room by default (multiplayer
 * is free — a second tab shows up as a remote square); `?private=1` forces a
 * solo room (probes use it so CI runs never collide with an open dev tab).
 */
export async function joinLab<S>(client: Client, name: string, rootSchema: any) {
  const params = new URLSearchParams(location.search);
  return params.has("private")
    ? client.create<S>(name, {}, rootSchema)
    : client.joinOrCreate<S>(name, {}, rootSchema);
}
