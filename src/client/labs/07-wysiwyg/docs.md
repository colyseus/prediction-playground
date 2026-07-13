# WYSIWYG Collision

Drive into the patrolling bot: the knockback lands the **same frame** you
touch it — a *predicted collision against a moving entity you don't control*.
That takes two tools beyond Lab 03's reconciler:

- **`valueAt(bot, "x", ctx.reckonTime)`** — inside the step, the bot is read
  at the exact instant the server will rewind this input to (the room attaches
  bots with rewind `mode: "reckon"`, and displays them dead-reckoned — Lab
  05's pairing). Same instant + same shared `stepBot` ⇒ client and server
  evaluate the collision against the *same* bot position, by construction.
- **`ctx.memo(...)`** — the verdict can't be re-derived on rollback replay:
  the client keeps no bot history, so a replay would reckon the bot from a
  *newer* snapshot and could flip a knife-edge call. `memo` freezes the live
  outcome per input and replays it verbatim until that input is acked.

The immunity window (`bumpTicks`) is a **reconciled tick gate** (Lab 03's
dash-gate pattern): synced state, counted down in the shared step on both
sides — so "can I be bumped right now?" is never itself a misprediction.

Break it on purpose (at 150+ ms sim latency). Head-on hits are forgiving —
staleness only shifts the bump a tick. The failure needs a **graze**: park
just at the edge of the patrol path (the dashed "stale snapshot" ghost shows
you the ~RTT/2 gap) and let the bot sweep past you repeatedly.

- **Read the stale snapshot** instead of `valueAt`: the client now tests
  against a bot position a few units behind where the server tests — grazes
  flip: phantom bumps (client yes, server no) and missed bumps (server yes)
  both appear as large corrections.
- **Disable `ctx.memo`**: every reconcile re-runs the test with fresher bot
  data — verdicts flip mid-flight and corrections pop even when the original
  call was right.

The mispredict rate row = corrections that arrive within half a second of a
predicted bump, over total predicted bumps.
