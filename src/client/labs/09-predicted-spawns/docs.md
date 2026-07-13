# Predicted Spawns

Click to fire. The projectile leaves your square the **same frame** — yet the
authoritative entity won't exist on the server until your fire input arrives,
half an RTT later. The spawns store owns that gap:

- **pending** (amber) — your optimistic local, spawned inside the input step
  and flown forward by the shared `stepProjectile` every frame.
- **confirmed** — the server's entity arrives and is **correlated** with your
  pending local into one logical entry: same `id`, same sprite. The tint flips
  to white — that flip is the only visible trace of the handoff, and the gap
  you can measure on it is your uplink (`leadMs`, shown in telemetry).
- **foreign** (red) — the turret's shots. Nobody predicted them, so they
  appear a full one-way trip late and dead-reckon to server-present. Compare
  how far a foreign projectile "starts ahead" vs your own.

Why `spawnTime` matters: a confirmed entity rendered at *server-present* would
snap **back** by `lead × velocity` at the handoff (the server spawned it later
than you did) — the store instead keeps owned entries flying the shooter's
timeline, forward by the measured per-shot lead. Toggle **optimistic spawn**
off and fire: same server behavior, but now your own shot appears a full RTT
late — that's the feel you paid for.

Also worth noticing: if the server had *refused* the shot (out of ammo, dead),
no entity would ever correlate — the pending local expires after ~2×RTT and
disappears. Optimism with a built-in undo.
