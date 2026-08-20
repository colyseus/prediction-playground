# Predict & Reconcile

Your square now moves the **same frame** you press a key — at any latency.
Push sim latency to 250 ms and drive: the solid square responds instantly,
while the **dashed ghost** (the raw server position) trails behind by a full
round trip. That gap is what prediction bought you.

How it works, in one loop:

- Each fixed tick the client sends one input **and** applies it locally with
  the shared `stepEntity` — the *same* function the server runs.
- Unacknowledged inputs stay buffered — the **pending** chips. More latency =
  more chips in flight.
- When a patch acks input N, the reconciler **rewinds** to the authoritative
  state and **replays** inputs N+1… If the server agrees with the prediction,
  the replay lands exactly where you already are — correction **0.000**.

Try to break it:

- **Force mispredict** makes the server shove you — something the client can't
  have predicted. Watch the red correction arrow and the drift spike, then
  watch `smoothMs` glide the error away. Set smoothMs to 0 to feel the raw
  snap.
- **Teleport** is a discontinuity. Smoothing a 50-unit correction looks like
  flying across the arena — that's why teleport-class jumps should **snap**:
  the auto-snap toggle calls `recon.reset()` when a correction exceeds the
  teleport threshold.
- **state vs value()**: `recon.state` is the exact predicted simulation state
  (use it for game logic); `recon.value("x")` adds render interpolation + the
  decaying correction offset (use it for drawing).

The drift badge classifies the rolling correction: **matched** (prediction
reproduces the server exactly), **jitter** (transient spikes that decay), or
**diverging** (persistent disagreement = a determinism bug in your step).
