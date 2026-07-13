# Clocks & Timelines

Every technique in this playground stands on one shared clock. When the server
room declares `defineInput()`, each input round-trip carries a timing prefix,
and the SDK distills it into `room.clock` — three distinct timelines:

- `now()` — the raw local clock. Use it for self-relative things (your own
  cooldown animations). It has no relationship to the server.
- `serverNow()` — the best estimate of the server's *current* time: clock
  offset smoothed by an EMA, samples gated by a windowed-minimum RTT filter
  (NTP-style — high-RTT samples are noise). It converges within a couple of
  seconds of joining, then **wobbles slightly** as each new sample nudges the
  EMA. Lag-comp stamps and server-issued deadlines live on this timeline.
- `renderNow()` — `serverNow` with a slew limiter (τ ≈ 250 ms). The wobble
  above is *velocity noise* if you draw moving entities against it — so the
  drawing timeline glides through offset corrections instead of stepping.
  Dead-reckoned entities (Lab 05) are drawn on this one.

What to watch here:

- **patch age** saws between 0 and the patch interval (~50 ms) — it's the
  freshness of what you're rendering, and exactly the reckon horizon of Lab 05.
- **offset convergence**: reload the lab and watch `serverNow − now` settle.
- **the slew in action**: yank the debug panel's latency slider up by 200 ms. `rtt`
  steps immediately; the offset estimate re-converges over a few samples; and
  `serverNow − renderNow` spikes then decays back to ~0 — that decay IS the
  slew limiter protecting your rendering from the step.
- **jitter**: add sim jitter and watch the interarrival estimate track it.
