# native-app — Prediction Playground on the C SDK (raylib)

The **interactive** twin of [`clients/native`](../native) (the headless probe).
The probe proves the native predict layer is *correct*; this proves it is
*usable* — real rendering, keyboard input, a telemetry HUD, and a latency
injector, against the same server as the web playground.

Plan: [`clients/APPS_PLAN.md`](../APPS_PLAN.md). Milestone status: **M1 done**
(shell + labs 01 / 02 / 03).

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
| 1 | Feel the Lag | no prediction — the input→motion meter tracks the round trip |
| 2 | Clocks & Timelines | `serverNow` / `renderNow` / rtt / jitter / patch-arrival strip |
| 3 | Predict & Reconcile | reconciler over the shared `step_entity`, server ghost, correction arrows, drift telemetry |

## Keys

| Key | |
|---|---|
| `WASD` / arrows | drive |
| `1` `2` `3`, `[` `]` | switch lab |
| `L` | cycle latency preset — off / 80+10 / 200 / 200+80 / 400+60 ms |
| `D` | drop the transport (unclean) — exercises auto-reconnect |
| `P` | private room ↔ shared room (rejoin) |
| `F12` | screenshot to `media/native-app/manual.png` |
| `I` `T` | (lab 3) force mispredict / teleport |
| `-` `=` | (lab 3) correction smoothing · (lab 1) damping |
| `V` `G` `N` | (lab 3) value()/state · server ghost · snap-on-teleport |

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

- **`sim.h`** — `stepEntity` as a bit-exact f64 transliteration, plus a startup
  canary pinned to values produced by the TypeScript original.

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
OK   lab01-latency-off      input->motion 85 ms at 0 injected (rtt 104) — one patch interval
OK   lab01-latency-200      input->motion 488 ms at 200 ms injected (rtt 508) — no prediction, so it tracks the round trip
OK   lab02-clock            smoothed rtt 505 ms, patch stamp flowing, jitter 4.0
OK   lab03-predicted        drift matched (ema 0.00e+00), 10 pending inputs at rtt 503 ms, 0 corrections
OK   lab03-impulse          max |correction| 4.338 after the server-side shove
OK   lab03-recovered        live |correction| 0.0000 (peak was 4.338), drift ema 0.0000 peak 0.0000 — decayed
OK   lab03-reconnected      1 reconnect(s), reconciler rebound, drift ema 0.0000, 119 reconciles
M1 ACCEPTANCE OK
```

That covers the APPS_PLAN §7 M1 exit criteria: lab 01 visibly rubber-bands at
200 ms; lab 03 is instant with matched drift (corrections exactly 0 — the C f64
port reproduces the server's float math bit-for-bit while ~10 inputs are in
flight); the impulse produces a correction that decays; `D` auto-reconnects and
the reconciler rebinds cleanly.

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
