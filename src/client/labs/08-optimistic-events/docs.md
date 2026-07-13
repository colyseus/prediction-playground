# Optimistic Events

Discrete moments — a goal, a kill, a pickup — deserve **instant feedback**,
but their truth belongs to the server. The optimistic-event channel owns that
whole lifecycle:

- **predicted** — `ctx.predict(goals, …)` inside the reconciler step fires
  `onPredict` the moment your *predicted* square crosses the line: banner up,
  sound plays, zero latency. It fires on the live step only — rollback
  replays re-run the sim but never re-fire the feedback.
- **confirmed** — the server's `goal` broadcast arrives ~RTT later and calls
  `goals.confirm()`. The banner was already up; nothing visible changes. The
  lifecycle log shows the measured predict→confirm gap.
- **rejected** — if the server processes past your predicting input *without*
  confirming, the channel auto-rejects and `onReject` runs the undo: banner
  retracts, red flash. Crank the **deny rate** slider to manufacture these.

Two design points worth stealing:

- The zone **gate** (`stepScoreGate`) is shared deterministic sim over a
  reconciled tick field (`scoreTicks`) — *whether you entered* is never a
  misprediction, at any latency. Only the award can be denied.
- Score itself stays authoritative (`player.score` is adopted, never
  predicted) — the optimistic layer is *feedback only*, so a rejection never
  needs game-state surgery.

Watch the lifecycle log at 250 ms sim latency: predicted → confirmed gaps sit
around your RTT. Set deny to 100% and every banner retracts after about the
same interval — that's the auto-reject anchor: "the server has answered past
my input and stayed silent."
