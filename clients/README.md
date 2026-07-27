# Cross-SDK validation clients

> Full **interactive** ports of the playground per SDK are landing alongside
> these probes — plan in [APPS_PLAN.md](./APPS_PLAN.md).
> First one up: [`native-app/`](./native-app) (C + raylib) — **complete**:
> shell, latency injector, and all twelve labs (M1 + M2 + M3), with an
> autopilot that replays the plan's exit criteria and exits non-zero on
> failure. Unity / Defold / Haxe next.

Headless probes that run **every Colyseus SDK's predict layer against this
playground's live server** — the cross-language twin of `scripts/probe-*.mjs`.
Each client executes the same four scenarios and prints `OK`/`FAIL` per check
(exit code 0 = all green):

| | Scenario | Predict surface |
|---|---|---|
| A | `lab-move` | join, TIMED clock sync, reconciler over the shared `stepEntity`, `impulse` → correction → recovery |
| B | `lab-bots` | passive smoothing (lerp) over the server-driven patrol bot |
| C | `lab-goal` | sim-born optimistic event (`ctx.predict`) → server `"goal"` broadcast → confirm |
| D | `lab-projectile` | predicted spawn → in-place authoritative handoff (stable id, measured input lead), foreign turret entries |

The load-bearing assertion is **determinism**: each client ports the shared sim
(`src/shared/movement.ts`, `goal.ts`, `projectile.ts`) natively, and the f64
ports (native C, Defold Lua, Haxe) assert steady-state reconcile corrections of
**exactly zero** — live rollback-replay reproducing the server's float math
bit-for-bit. The C# port steps in float32 (schema `number` fields) and asserts
wire-precision corrections instead.

All probes expect the sibling SDK checkouts next to this repo and the server on
`0.0.0.0` (native transports resolve IPv4 — Vite binds `::1` by default):

```
pnpm dev --host 0.0.0.0
```

## native (C)

Compiled by `native-sdk/build.zig` when the repos are siblings:

```
cd ../native-sdk && zig build && ./zig-out/bin/predict_probe [port]
```

Schema headers are `schema-codegen --c` output (checked in under
`native/schema/`).

## unity (C#)

net8.0 console app referencing `colyseus-unity-sdk/nuget/Colyseus.csproj`:

```
dotnet run --project clients/unity [-- port]
```

## defold (Lua)

Plain `luajit` — no Defold engine: `defold_shim.lua` supplies the engine APIs
(`websocket`/`http`/`timer`/`sys`/`json`) over an FFI TCP layer with a pure-Lua
RFC 6455 client. State AND input schemas come from the reflection handshake.

```
cd clients/defold && luajit predict_probe.lua [port]
```

## haxe (neko)

```
cd clients/haxe && haxe build.hxml && neko probe.n [port]
```

On sys targets the websocket thread decodes while the main thread reconciles;
the assertions tolerate (and count) the resulting rare one-tick race blips.

## Bugs these probes have caught

- **colyseus 0.18 core**: the input sanitizer floor-clamped never-transmitted
  fields (`undefined`) to the range minimum — driving with only `moveX`
  assigned made the server walk diagonally (phantom `moveY = -1`). Fixed by
  skipping undefined in sanitize + seeding input instances with wire-neutral
  zero values. Regression probe: `scripts/probe-negative-input.mjs`.
- **colyseus-haxe**: `Predict.create`'s dynamic adapter called optional-arg
  callbacks with too few args — "Invalid call" on neko when wiring collections.
- **native-sdk**: no `SO_NOSIGPIPE`/`SIGPIPE` handling — headless clients must
  `signal(SIGPIPE, SIG_IGN)` themselves (pinned in `predict_probe.c`).
- **colyseus-unity-sdk**: `Connection.Send` lost its `virtual` when the four
  `Raise*` hooks collapsed into one `Dispatch`/`Transmit` seam, so three test
  stubs that override it stopped compiling (`CS0506` ×3). Unnoticed because the
  Unity batch compile only covers `Assets/` — `nuget/tests` needs
  `dotnet test`. The stubs now drive the seam instead of subclassing.
- **all four ports**: no `dispose()` before respawning a controller on a
  smoothing change, where `10-composite-sim/index.ts` does exactly that. The
  old controller kept ticking against the same input handle. Invisible until
  the bound overlay made two controllers contend for the same slots.

## What lab 10's acceptance check taught us

`drift.ema < 0.05` looked like a determinism guarantee and was satisfied only by
a DEAD simulation. The EMA decays toward zero when the world stops moving, so an
autopilot that pinned the puck against a wall — where the contact re-ejects it
out of bounds every tick and nothing moves again — scored 1e-9 and passed, while
honest play failed. Three of the four ports had it (native asserts the
prediction LEADS its ghost, which a frozen world cannot do).

Three habits came out of it, and they generalise past this lab:

- **Near-zero error is a symptom, not a result.** Three separate times a
  reassuring number turned out to mean the sim had stopped. Check liveness
  alongside accuracy, or the accuracy figure is unfalsifiable.
- **Pick the statistic to match the claim.** A contested touch mispredicts BY
  DESIGN here, so the honest claim is about the typical reconcile: the MEDIAN
  ignores that tail while still catching a trend. An end-of-run EMA answers a
  question nobody asked.
- **Mutation-test a threshold before trusting it.** 0.5 is measured — honest
  play 0.0000-0.1527, wrong puck friction (0.900 vs 0.985) 1.7751. The same
  exercise showed the check CANNOT see a 0.1 % constant slip (0.0593), which is
  the startup canary's job. Knowing what a check misses is half of knowing what
  it proves.
