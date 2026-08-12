# Lag Compensation

Everything you aim at is rendered **in the past** (lerp, ~100 ms behind — Lab
04). Without help, a hit registered on the server would need you to *lead* the
target by RTT/2 + interpolation delay. Lag compensation moves that burden to
the server: it records target history each tick and, when your fire input
arrives, **rewinds every target to what your screen showed** at that instant —
`rewind.lastSeenBy(sessionId)`. You shoot what you see.

Aim with the mouse, click to fire at the strafing bot. Every shot drops three
markers:

- **blue** — where the bot was *on your screen* when you clicked.
- **green** — where the server *rewound* it to for the hit test. With lag comp
  on, green lands on blue: the server reconstructed your view.
- **red** — where the bot *actually* was on the server, ahead of your view by
  ~(RTT/2 + interp delay) × its speed.

The ray itself carries a fourth reading. At the click the client runs the
server's own `rayCircle` against the blue pose and draws its verdict
immediately, faint; when the report lands the server's verdict replaces it at
full strength. Agreement is the whole point — **a ray that changes colour is a
shot the rewind resolved differently than your screen did.**

Experiments:

- Crank sim latency to 250 ms. With **lag comp on**, aiming dead-on keeps
  hitting — watch green track blue while red runs away, and the ray hold the
  colour it was drawn with. Toggle **lag comp off** (room-wide!) and the same
  crosshair aim starts missing: every ray now flashes green and resolves red,
  because the server is testing against a bot you were never shown. You must
  lead the target by the red-blue gap.
- The rewind is capped (`maxRewindMs: 500`) — a hard bound on how far into the
  past any client can drag the server, which also bounds the "shot around the
  corner" effect this technique famously inflicts on the *victim*.
- The wire cost is one render-time stamp per fire input —
  `allowRewind: (d) => d.fire` skips it on plain movement frames.

Pairing rule: the server rewinds to the timeline the client *displays*.
Lerp/damped display ↔ `mode: "snapshot"` (used here). A dead-reckoned display
(Lab 05) pairs with `mode: "reckon"` — that combination is Lab 07.
