# Dead Reckoning

Lerp renders the past. **Reckon renders the present** — by forward-simulating
the latest snapshot with the *same step function the server runs*
(`stepBot` from `src/shared/`). The distance between the two ghosts is the
delay you bought back.

The **reckon horizon** line stretches from the newest snapshot (raw dot) to
the forward-simulated present. Its length grows between patches and resets on
each arrival — it *is* the snapshot age. Raise sim latency and watch it grow.

Three motion types, three outcomes:

- **patrol** — fully predictable (the bounce is in the shared step). Reckon is
  essentially exact; the only corrections are tiny rebases when a patch lands.
- **wander** — the heading changes are a server-side secret. Reckon
  extrapolates straight through every turn and gets visibly corrected — the
  rebase glide (tune it with `smoothMs`).
- **teleport** — the warp schedule is synced state (`lastTeleport` +
  period), so reckon predicts even the discontinuity. The `snap` threshold
  handles whatever residual mismatch remains: below it, corrections glide;
  beyond it, they **pop** — because smoothing across a teleport draws the bot
  flying through space it never crossed.

Compare with Lab 04's lerp: same bot, same patches — the difference is purely
what the client chooses to draw. Reckon is also the timeline the server
rewinds to for lag compensation (`mode: "reckon"`) — that pairing is Lab 06.
