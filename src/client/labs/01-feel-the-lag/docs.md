# Feel the Lag

This lab has **no prediction at all**. Your input goes to the server, the server
moves your square, and the new position comes back in a state patch. What you
feel between the key press and the movement is the **full round trip** — plus
up to one patch interval.

Try it:

- Drive with **WASD**. At 0 ms simulated latency (same machine) it feels fine.
- Push the **latency slider** in the Colyseus debug panel (the logo panel in
  the top-right corner) to 150–250 ms. Now every key press takes that long to
  matter. This delay is what client-side prediction removes — for your *own*
  entity only.
- Watch the **input → motion** readout: it measures the real photon delay from
  your key press to the first rendered movement.

Two render strategies:

- **raw** — draw `player.x/y` exactly as decoded. It stutters, because patches
  arrive at the patch rate (~20 Hz), not your display's frame rate. The trail
  shows the stair-stepping.
- **damped** — exponentially smooth toward the latest server position. Smooth,
  but *even laggier*: smoothing trades responsiveness for continuity.

The third strategy — **predicted** — is Lab 03.
