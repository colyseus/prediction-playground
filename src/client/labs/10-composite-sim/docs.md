# Composite World — `predict.sim`

Lab 03's reconciler mirrors *fields of one instance*. But hit a puck and the
thing that must respond instantly isn't you — it's the **puck**, an entity
your inputs only influence through contact. `predict.sim` predicts a
**composite world**: your paddle *and* the puck, stepped together through your
own inputs.

- **step** applies one input to the whole world in the server's exact order:
  paddle moves → puck integrates → contacts resolve. Your shot leaves the
  paddle the frame you swing.
- **adopt** re-seeds the *entire* world from authoritative state on every ack
  (the whole patch decodes before the ack, so paddle + puck come from the same
  server tick). Unacked inputs replay on top — your predicted shot is
  re-derived from truth ~20× a second. If the server agrees, the replay lands
  where the puck already is: correction 0.
- **pose** exposes the render view; `smoothMs` glides whatever corrections
  remain.

Watch the dashed **server ghost puck** trail your predicted puck by ~RTT after
a clean shot — then converge as acks land. That gap is what the composite sim
bought you.

Where it honestly breaks: the **bot's paddle**. Remote paddles enter your
prediction as colliders frozen at their latest snapshot — their inputs aren't
yours to predict. A *contested* touch (you and the bot reaching the puck
together) predicts against a stale opponent and gets corrected — watch the
correction sparkline spike exactly then, and only then. Toggle the bot off
and the world is fully yours: corrections flatline at any latency.
