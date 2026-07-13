# Remote Interpolation Modes

You cannot predict entities driven by *someone else's* inputs — you can only
choose **how to draw the samples you receive**. This lab renders one bot four
ways at once, each through its own `Predict` instance:

- **raw** (dashed) — the decoded snapshot verbatim. It teleports ~20× a second
  (the patch rate). This is what interpolation fixes.
- **lerp** — draw `delay` ms in the past, always *between* two real samples.
  Never invents positions, so it's never wrong — but everything you see already
  happened. Classic snapshot interpolation.
- **damped** — exponentially chase the newest sample. Smooth and cheap, cuts
  corners on direction changes, lag scales with the damping constant.
- **extrapolate** — project the recent trend into the future. Present-time and
  smooth on straight lines, but it **overshoots on every turn** — watch the
  orange ghost shoot past the patrol endpoints.

The **timeline strip** at the bottom is the whole lesson in one picture: white
dots are the actual received samples of the bot's x position; each colored
trace is what that mode *rendered*. See how lerp reproduces the dots shifted
right by `delay`, damped rounds them off, and extrapolate overshoots reversals.

Every mode's parameters live in **its own Predict card** (top left) — that's
the SDK's built-in tuning surface, not something this lab added. Things to try
with them:

- Raise sim latency: the *dots* arrive later, but the spacing stays the same —
  interpolation hides latency's jitter, not the latency itself.
- Switch the bot to **wander**: extrapolation gets worse (unpredictable turns).
- In the lerp card, drop `delay` below one patch interval (~50 ms) and watch it
  run out of buffered samples.
- In the extrapolate card, raise `maxExtrapolate` and watch the overshoot at
  patrol reversals grow with it.
