# The split screen

Both lanes show **the same entity in the same room** — the split is purely a
render choice:

- **Top — server echo.** Drawn straight from the decoded server state. Every
  key press travels to the server, moves the authoritative square, and comes
  back — you see it a full round trip late. This is Lab 01.
- **Bottom — predicted.** The same keys are applied locally the instant you
  press them; when the server's ack arrives, the reconciler rewinds and
  replays anything still in flight. This is Lab 03.

This lab injects **200 ms of simulated latency** after joining (the SDK's
network simulator — the Colyseus panel top-right owns the slider). It stays on
while you explore: every lab here is designed to be felt at 150–250 ms.

**Try it:**

- Drive with WASD / arrows — taking over stops the autopilot.
- Reverse direction sharply: the top square keeps going the wrong way for a
  full round trip; the bottom one turns instantly.
- Set injected latency to 0 ms and watch the lanes converge; 400 ms tears
  them apart.
- Open a second tab: remote squares get no prediction (their inputs aren't
  yours to predict) — Labs 04–05 are about them.

From here the curriculum builds the bottom lane from scratch: **01** makes you
feel the raw echo, **02** explains the clocks, **03** builds the reconciler.
