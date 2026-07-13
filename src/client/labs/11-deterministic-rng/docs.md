# Deterministic Randomness

Prediction needs determinism — but games need randomness. The trick: make the
randomness a **pure function of data both sides already share**, so nothing
random ever rides the wire.

Each shotgun blast here seeds its pellet fan from two integers:

- the **input sequence number** — the engine's own input counter (the client
  gets it from `input.send()`, the server from `channel.consumedCount`; they
  are the same number for the same input, by construction), and
- a **per-room salt** — synced state, rolled once by the server.

`splitmix32(seq ⊕ salt)` seeds a `mulberry32` stream; six draws make six
pellet angles. The client draws its fan the frame you click (amber). The
server derives its own fan when the input arrives and reports it (white).
**They overlap to the last bit** — check the "fan divergence" readout: 0.0000
radians, at any latency.

Now flip **"cheat with Math.random"**: the client draws pellets the server
can't reproduce. The fans visibly disagree, and every hit judgment along with
them. This is exactly why `Math.random()` (and wall clocks) are banned from
predicted code paths in all of the demos — and why the FPS demo derives its
weapon spread this way.

Why the salt? Without it, the pellet sequence would be knowable for all future
shots from the seq alone (scriptable no-spread aimbots). The salt keeps the
stream unpredictable *across rooms* while staying exactly reproducible
*within* one.
