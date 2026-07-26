# native-app — Prediction Playground on the C SDK (raylib)

The **interactive** twin of [`clients/native`](../native) (the headless probe).
The probe proves the native predict layer is *correct*; this proves it is
*usable* — real rendering, keyboard input, a telemetry HUD, and a latency
injector, against the same server as the web playground.

Plan: [`clients/APPS_PLAN.md`](../APPS_PLAN.md). Milestone status: **M1 + M2
done** — shell, latency injector, and labs 00 / 01 / 02 / 03 / 04 / 05 / 08 / 09.
M3 (SimReconciler port + labs 06 / 07 / 10 / 11) is still open.

```
pnpm dev --host 0.0.0.0                     # --host is mandatory (native = IPv4)
brew install raylib
cd ../native-sdk && zig build
./zig-out/bin/predict_playground [port]     # default 5173
```

The exe is registered in `native-sdk/build.zig` and only appears when this repo
sits next to `native-sdk` **and** pkg-config can find raylib. `zig build
run-playground -- 5173` works too.

![Lab 03 — predict & reconcile at 200 ms injected latency](../../media/native-app/03-reconcile.png)

## Labs

| | Lab | What it shows |
|---|---|---|
| 0 | Lag vs Prediction | lab 3's netcode behind a split screen: raw server echo on top, predicted below |
| 1 | Feel the Lag | no prediction — the input→motion meter tracks the round trip |
| 2 | Clocks & Timelines | `serverNow` / `renderNow` / rtt / jitter / patch-arrival strip |
| 3 | Predict & Reconcile | reconciler over the shared `step_entity`, server ghost, correction arrows, drift telemetry |
| 4 | Remote Interpolation | raw / lerp / damped / extrapolate over one bot + a sample-vs-render timeline strip |
| 5 | Dead Reckoning | `track_reckon` over the shared `step_bot`, against a lerp ghost |
| 8 | Optimistic Events | sim-born `step_predict` → confirm / grace-tick reject, with a deny-rate control |
| 9 | Predicted Spawns | optimistic projectile → authoritative handoff, measured input lead |

## Keys

| Key | |
|---|---|
| `WASD` / arrows | drive |
| digits, `[` `]` | switch lab (by lab number) |
| `L` | cycle latency preset — off / 80+10 / 200 / 200+80 / 400+60 ms |
| `D` | drop the transport (unclean) — exercises auto-reconnect |
| `P` | private room ↔ shared room (rejoin) |
| `F12` | screenshot to `media/native-app/manual.png` |
| `I` `T` | (3) force mispredict / teleport |
| `V` `G` `N` | (3) value()/state · server ghost · snap-on-teleport |
| `B` | (4, 5) cycle the room-wide bot pattern |
| `F1`–`F4` | (4) show/hide one interpolation mode |
| `,` `.` | (5) reckon snap threshold |
| `-` `=` | (3) smoothing · (1) damping · (5) rebase smoothing · (8) server deny rate |
| mouse / `SPACE` | (9) aim / fire |
| `O` | (9) toggle the optimistic spawn |

## Notable ports

- **`net_delay.h` — the latency injector** (APPS_PLAN §3). A wrapper transport
  handed to `colyseus_client_create_with_transport`, so the room rebuilds it on
  every reconnect for free. Both directions are queued; each packet's deliver-at
  is clamped to ≥ the previous one's, so jitter never reorders the stream. It
  aliases the inner websocket's `impl_data` because
  `colyseus_websocket_connect_with_settings()` writes TLS config straight
  through `transport->impl_data` before calling `connect`.

  Side benefit worth keeping even at 0 ms: inbound frames are delivered from
  `nd_pump()` on the **main thread**, so every schema decode happens there and
  labs read state without a mutex.

- **`sim.h`** — `stepEntity`, `stepBot` (patrol / circle / wander / teleport),
  `stepScoreGate` and `stepProjectile` as bit-exact f64 transliterations, plus a
  startup canary pinned to values produced by the TypeScript original.

- **Lab 09 keeps its own entry list.** The C spawn store has no entry iterator
  and no `value()` overlay (the JS `projectiles.entries()` / `.value(e, "x")`),
  so the lab tracks ids from `spawns_spawn()` and the collection's `onAdd`, then
  reads the local struct while pending and the server instance once confirmed.
  Same render path, one lookup deeper.

- **Single translation unit.** schema-codegen emits `static` vtables per header,
  so one TU is what keeps every lab pointing at the *same* vtable object. `main.c`
  `#include`s the lab `.c` files.

## Verification

```
./zig-out/bin/predict_playground --selfcheck     # headless: shared-sim canary, no window
./zig-out/bin/predict_playground --demo          # M1 acceptance run (needs a display)
```

`--demo` is the autopilot: it switches labs, cycles latency presets, drives the
player, fires the impulse, drops the transport, writes a screenshot per
checkpoint to `media/native-app/`, and exits non-zero if any check fails. Last
run, against `pnpm dev --host 0.0.0.0`:

```
=== acceptance run: M1 + M2 (APPS_PLAN §7) ===
OK   lab01-latency-off      input->motion 101 ms at 0 injected (rtt 115) — one patch interval
OK   lab01-latency-200      input->motion 505 ms at 200 ms injected (rtt 504) — no prediction, so it tracks the round trip
OK   lab02-clock            smoothed rtt 498 ms, patch stamp flowing, jitter 2.7
OK   lab03-predicted        drift matched (ema 0.00e+00), 10 pending inputs at rtt 488 ms, 0 corrections
OK   lab03-impulse          max |correction| 4.750 after the server-side shove
OK   lab03-recovered        live |correction| 0.0000 (peak was 4.750), drift ema 0.0000 peak 0.0000 — decayed
OK   lab03-reconnected      1 reconnect(s), reconciler rebound, drift ema 0.0000, 123 reconciles
OK   lab00-split            echo lane trails the predicted lane by 5.5 u at rtt 574 ms (12 in flight)
OK   lab04-modes            speed CV raw 157% > lerp 25% (damped 38%, extrapolate 41%) — the raw square steps at the patch rate, lerp glides
OK   lab05-patrol           kind=patrol reckon x 34.49 vs lerp x 27.90 (gap 6.58 u over a 310 ms horizon)
OK   lab05-wander           kind=wander, reckon x 63.48 is 4.95 u past the newest snapshot — headings are a server secret, so it extrapolates straight through every turn and gets rebased
OK   lab08-confirmed        2 predicted, 2 confirmed at deny rate 0 % (score 2)
OK   lab08-denied           3 rejected at deny rate 100 % — the banner went up, then retracted
OK   lab09-spawn            1 fired, authoritative entity correlated in place, measured input lead 553 ms
ACCEPTANCE OK
```

That covers the APPS_PLAN §7 M1 and M2 exit criteria: lab 01 visibly
rubber-bands at 200 ms; lab 03 is instant with matched drift (corrections
exactly 0 — the C f64 port reproduces the server's float math bit-for-bit while
~10 inputs are in flight); the impulse produces a correction that decays; `D`
auto-reconnects and the reconciler rebinds cleanly; the split lanes diverge by
~RTT; the four interpolation modes separate on the smoothness metric; reckon
runs ahead of lerp on a predictable pattern and gets rebased on `wander`; the
goal banner is instant and the deny slider produces visible rejects; and a
predicted shot hands off to the authoritative entity with a measured lead.

## Found while building this

- **raylib + no display**: `InitWindow` failing leaves GLFW uninitialised, and
  every later `WaitTime`/`glfwGetTime` spins inside raylib's error logger
  (blocking forever when stdout is a pipe). The app now bails on
  `!IsWindowReady()`.
- **Transport teardown is not thread-safe against a render loop**: the SDK's
  reconnection worker calls `transport->destroy` from its own thread. The
  injector only *marks* there and reaps from `nd_pump()` on the main thread —
  otherwise the pump races the worker on the inner transport, and holding the
  registry lock across an SDK call inverts lock order against the worker's mutex.
