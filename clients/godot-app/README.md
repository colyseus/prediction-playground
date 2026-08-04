# Prediction Playground — Godot (C#)

The full 12-lab playground on **Godot 4.6 (.NET)**, consuming the same
engine-agnostic C# SDK as unity-app — via a project reference to
`colyseus-unity-sdk/nuget/Colyseus.csproj` pinned to its `netstandard2.1`
flavor. First non-Unity consumer of that package: schema decode, the predict
layer (Reconciler, SimReconciler, events, spawns, clock) and the
`Connection.Dispatch`/`Transmit` injector seam all run unmodified.

What is genuinely Godot here is the shell: `LabManager` (Node2D, `_Process` =
netcode, `_Draw` = paint), `View`/`Hud` (the shared draw vocabulary over
CanvasItem), and `Kb` (Input + `_UnhandledInput` edge tracking, pointer in
viewport coords — already top-left, no Y flip). `Sim.cs`, `NetDelay.cs`,
`Series.cs`, `MoveLane.cs` and `scripts/schema/*` are **verbatim copies** from
`clients/unity-app` — none of them touch an engine API. Lab `Frame()` bodies
are unity-app's code verbatim; `Render()` differs only in `Rect2` /
`HorizontalAlignment` / mouse types.

## Run

```sh
pnpm dev --host 0.0.0.0        # from the repo root — the server, mandatory
/Applications/Godot_mono.app/Contents/MacOS/Godot --path clients/godot-app
```

Keys: `0-9` lab, `[` `]` prev/next, `L` latency preset, `D` drop transport,
`P` private-room toggle, per-lab keys on the HUD.

## Verification gates

```sh
# 1. compile
dotnet build clients/godot-app/PredictionPlayground.csproj

# 2. quick smoke: mounts all 12 labs headless, checks patches + decode thread
godot --headless --path clients/godot-app -- --smoke

# 3. the acceptance suite — the Godot twin of unity-app's PlayMode suite
godot --headless --path clients/godot-app res://Acceptance.tscn
```

(`godot` = the **mono** binary. All three need the dev server up.)

## Acceptance record (2026-08-04, Godot 4.6.1.mono, ACCEPT OK 15/15)

| check | measured |
|---|---|
| injector seam alloc | 0.41 B/message over 20k round trips |
| steady-state GC | 439 B/frame, 0 gen0 collections over 8 s |
| lab01 input→motion | 69 ms at 0 injected, 534 ms at 200 ms |
| lab03 drift ema | 1.5e-8 (float32 wire precision), impulse peak 4.75 → 0.0000 |
| lab00 lane separation | peak 19.9 u |
| lab04 speed CV | raw 2.60 · lerp 0.17 · damped 0.28 · extrapolate 0.53 |
| lab05 reckon↔lerp | 20.1 u gap; circle y sweep 22.9 u |
| lab06 lag comp | 6/6 hits, rewind error 0.89 u (renderDelay bound) |
| lab07 verdicts | predicted 2 = authoritative 2, 0 % mispredict |
| lab08 events | 2 confirmed / 4 rejected of 6, deny-rate driven |
| lab09 handoff | lead 269 ms measured, worst jump 2.28 u |
| lab10 composite | median correction 0.0000 over 224 reconciles, peak puck lead 20.5 u |
| lab11 RNG | 3.6e-8 rad seeded vs 3.1e-1 rad cheating |

## Notes

- Message dispatch rides Godot's main-thread `SynchronizationContext` — the
  transport captures it at connect, so patches decode on the main thread with
  no per-frame pump in the app (`--smoke` asserts this).
- The shell wires each lab's `OnReconnect` to the SDK's `Room.OnReconnect`
  via `LabBase.BindReconnect()` (`IRoom` doesn't carry the event; the base
  class knows the concrete room type).
- Inside a `Node2D` subclass the bare name `Draw` is the inherited
  `CanvasItem.Draw` event — the shell aliases `PDraw = Playground.Draw`.
  Labs are plain classes and use `Draw.` unqualified, same as unity-app.
