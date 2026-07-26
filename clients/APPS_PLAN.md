# Plan: full interactive clients for every SDK

Goal: rebuild the **playable, visual** Prediction Playground experience on each
Colyseus SDK — real rendering, keyboard input, telemetry HUD, latency knobs —
against the same server (`pnpm dev --host 0.0.0.0`). This is the step beyond
`clients/{native,unity,defold,haxe}` (the headless probes): the probes verify
*correctness*; the apps verify the *developer experience and feel* of the
predict API on each engine, and give each SDK a flagship demo.

This document is self-contained for a fresh session. Read it top to bottom
before writing code. Companion docs: `clients/README.md` (probe suite + the
bugs it caught), `colyseus-0.18/PORTING/sdk-ports-predict-layer.md` (predict
algorithm contract), `PORTING.md` in colyseus-0.18 (ported-surface manifest).

## 0. Ground truth from the probe sessions (do not rediscover)

- Server: `pnpm dev --host 0.0.0.0` — **`--host` is mandatory**; Vite binds
  `::1` only and every non-JS transport resolves IPv4.
- All four SDK predict layers are live-validated (PROBE OK). f64 SDKs
  (C/Lua/Haxe) reproduce the shared sim bit-exactly; C# schema `number` fields
  are float32 (wire-precision corrections ~4e-6 — invisible on screen).
- native: headless/desktop binaries must `signal(SIGPIPE, SIG_IGN)`.
- Haxe sys targets: the websocket thread decodes while the main thread runs —
  reconciles can race one tick (~1.7 units, rare). An app should either accept
  the blip or add a main-thread decode pump (see §6 Haxe).
- **neko ints are 31-bit — lab 11's mulberry32/splitmix32 uint32 math breaks
  on neko.** The Haxe app must target **HashLink (hl) or js**, not neko.
- Unity's nuget test assembly ships GLOBAL-namespace fixture types (`Player`
  with only x/y) that shadow imports — reference lab schemas via a namespace
  alias (`using Lab = ...;`). (A Unity-editor app referencing `Assets/` does
  not have this problem — it exists only when referencing the nuget csproj.)
- schema-codegen: `--csharp --namespace X.Y`, `--haxe --namespace lab`,
  `--lua`, `--c` all work on the demo's functional-API schemas. A C# namespace
  must NOT end in `.Schema` (shadows the base class).
- The demo consumes **published** `@colyseus/*` from the registry. The
  phantom-input fix (colyseus-0.18 `b26a448`) is currently hand-overlaid into
  this repo's node_modules — **republish (or re-overlay after installs) before
  app work**, or every non-JS client walks diagonally again
  (`scripts/probe-negative-input.mjs` verifies in ~5s).

## 1. What the web client actually is (port target)

`src/client/` splits into a small engine-agnostic core and a web-only shell:

**Port this (the lab experience):**
- `WorldView` — 100×60 world-unit arena letterboxed into the viewport
  (`fit/sx/sy/s/wx/wy`), grid + border (`drawArena`), shape helpers
  (squares/circles/rays with fill/stroke/dash/alpha), `hueColor(hue)` =
  `hsl(hue/256*360, 72%, 62%)`, `Trail` (fading position history).
- `Keyboard` — WASD/arrows → `moveX/moveY` ∈ {−1,0,1}, plus per-lab keys;
  mouse/pointer → world coords via `view.wx/wy` (aim + fire).
- `ControlsPanel` — sliders / toggles / buttons / segmented pickers /
  readouts. Labs use 1–4 controls each (03: smoothing+snap+impulse+teleport;
  10: smoothing+latency; 04: per-mode delay sliders).
- `TelemetryHUD` — labelled rows (with good/warn/bad coloring), sparklines
  (corrections, pending), chip counters (pending inputs).
- `NetHud` — rtt / jitter / patch-age readouts off `room.clock` (all ported
  clocks expose smoothedRtt/jitter/lastServerTime/serverNow).
- `FixedStepPacer` — send pacing for labs WITHOUT a reconciler (predict.tick's
  budget only paces once a reconciler adopts the step). Cap 5 steps/frame.
- The **lab contract**: `mount(ctx) -> { frame(now, dt), unmount(),
  onReconnect() }`, one shared render loop, labs never leave the room
  themselves. `onReconnect` MUST `reset()` reconcilers (post-reconnect input
  seqs restart at zero).
- **Latency injection** — in the web build this comes from the JS SDK's debug
  panel (`__net(delay, jitter)`), NOT the demo. Every app must implement its
  own injector (§3) or labs 00/01/03… demonstrate nothing on localhost.

**Skip (web-only shell):** labNav sidebar, docsPanel + markdown + highlight
(the `?raw` source display), registry deep-links, devicePixelRatio handling.
Replace with the simplest native equivalent: a lab-select keybind (`[`/`]` or
digits) + a title line. Docs live in the repo; apps don't render them.

## 2. Shared-sim porting matrix

The probes already ported the first three per language — **extract those into
a reusable `sim` module per app** instead of copying again. All ports are
straight f64 transliterations; keep op order and constants byte-identical
(`SQRT1_2 = 0.70710678118654752440`).

| Module | Used by labs | C | C# | Lua | Haxe |
|---|---|---|---|---|---|
| `movement.ts` stepEntity | 00,01,03,06,07,08,09,10 | ✅ probe | ✅ probe | ✅ probe | ✅ probe |
| `goal.ts` stepScoreGate | 08 | ✅ probe | ✅ probe | ✅ probe | ✅ probe |
| `projectile.ts` stepProjectile | 09 | ✅ probe | ✅ probe | ✅ probe | ✅ probe |
| `movers.ts` stepBot (patrol/circle/wander/teleport) | 04,05 (client reckon) | ✅ app | ⬜ | ⬜ | ⬜ |
| `hockey.ts` stepPuck + collidePaddlePuck | 10 | ✅ app | ⬜ | ⬜ | ⬜ |
| `bump.ts` stepBumpGate + collideBot | 07 | ✅ app | ⬜ | ⬜ | ⬜ |
| `random.ts` splitmix32/mulberry32/shotSeed | 11 | ✅ app | ⬜ | ⬜ | ⬜ |
| `spread.ts` spreadAngles | 11 | ✅ app | ⬜ | ⬜ | ⬜ |
| `hitscan.ts` rayCircle | 06,07,11 | ✅ app | ⬜ | ⬜ | ⬜ |

The native column landed as `clients/native-app/sim.h`, every entry with a
canary pinned to values produced by the TypeScript original (`--selfcheck`).

`random.ts` is **uint32 integer math** — use `uint32_t` (C), `uint` (C#),
LuaJIT `bit` ops (Lua), `haxe.Int32`/`>>> ` on hl/js (Haxe). Validate against
JS: `mulberry32(0xB07B07)()` first three outputs, `shotSeed(7, 12345)` — put
these in a tiny self-check the app runs at startup (like the probes' encode
canary).

Schemas: codegen exists for all four languages (probe dirs). Add `hockey.ts`
and any missing state (HockeyState, BumpState, RangeState already generated
for C/C#/Haxe; Defold needs none — reflection builds everything).

## 3. Latency injector (required, per SDK)

Inject at the transport seam, both directions, delay + jitter, with a "drop"
button (kill transport uncleanly → exercises auto-reconnect + `onReconnect`):

- **native**: wrap `room->transport->send` and `transport->events.on_message`
  (fn-pointer swap — the probe's debug interposer shows the seam). Queue
  `{deliver_at, bytes}`; drain due entries from the app loop. Timestamp with
  `colyseus_room_clock_now`.
- **Unity**: decorate the transport at `Room.Connection` (check the seam:
  `Client` builds Connection; a `DelayedConnection : Connection` override or a
  send/receive queue inside a custom transport factory). Drain from `Update()`.
- **Defold**: wrap `room.connection` — replace `connection:send` and re-emit
  delayed `"message"` events via `timer.delay`. Pure Lua, engine timers.
- **Haxe**: wrap `Connection.send` + `onMessage` with `haxe.Timer.delay`
  queues (hl/js both have timers).

Jitter: `delay + rand()*jitter` per packet, but **never reorder** — clamp each
packet's deliver-at to ≥ the previous packet's (the wire is a stream; the JS
debug panel does the same).

## 4. Lab-by-lab feasibility

| Lab | Needs beyond §2/§3 | Status in ported SDKs |
|---|---|---|
| 01 feel-the-lag | input handle only, FixedStepPacer | ✅ ready |
| 02 clocks | room.clock readouts (now/serverNow/renderNow, rtt, jitter) | ✅ ready |
| 03 reconcile | Reconciler + smoothing/snap knobs, impulse/teleport buttons, drift HUD | ✅ ready (probe-proven) |
| 00 split | = lab 03 mounted twice (echo lane vs predicted lane), same room | ✅ ready |
| 04 interp-modes | track/attachAll modes lerp/damped/extrapolate/raw side by side; timeline strip of samples vs outputs | ✅ ready; per-field options map on attachAll is JS-only sugar — call `track` per field |
| 05 dead-reckoning | `mode:"reckon"` with ported stepBot; pattern-switch message | ✅ engine ready; needs movers port |
| 08 optimistic-events | defineEvent + ctx.predict + deny-rate slider | ✅ ready (probe-proven) |
| 09 predicted-spawns | spawns store + fire input + lead readout | ✅ ready (probe-proven) |
| 06 lag-comp | allowRewind fire-gate, lerp-delayed bots, hit/miss markers (server broadcasts) | ✅ ready; needs hitscan port for the client-side aim ray |
| 07 wysiwyg | `valueAt(ctx.reckonTime)` + `ctx.memo` frozen verdicts | ✅ ready; **C memo stores doubles only** — encode the verdict as a number |
| 11 deterministic-rng | random+spread ports; overlay client fan vs server fan | ✅ engine-free; watch integer width (§2) |
| 10 composite-sim | SimReconciler (`predict.sim`) | ✅ native (ported, §5); ⬜ Unity/Defold/Haxe |

## 5. SimReconciler port (prerequisite for lab 10)

**native: DONE** (`native-sdk` `predict: SimReconciler …`). C has no
inheritance, so rather than duplicate the ~200-line rollback algorithm the
composite face lives in `reconciler.c` behind a `sim` pointer on the same
struct: the engine (catchUp, reconcile, error rebase, snap, drift, memos, epoch
follow) is shared verbatim and only the four subclass hooks branch —
`adopt_truth` / `run_step` / `truth_matches_at` / `cur_value`. A part with a
`source` is auto-bound to a mirror and contributes `"<part>.<field>"` pose keys;
a part without one is opaque and only ever restored by the app's `adopt`.
`tests/test_predict.zig` `sim_reconciler_bound` mirrors scenario C. Unity /
Defold / Haxe still to do — the same decomposition should transfer.

Contract:
`colyseus-0.18/PORTING/sdk-ports-predict-layer.md` §5 (auto-binding, adopt
order, refreshPose/pose memoization, value() overlay) — plus scenario C in
`PORTING/generate-predict-fixtures.cts` (`sim_reconciler_bound`: paddle+puck,
expected `value("paddle.x")=0.1`, `value("puck.px")=1`, ack-1 noise `<1e-6`).

Port order (same as Phase 4): **native → Unity → Defold → Haxe**, one commit
per SDK, fixture test per SDK mirroring scenario C. Design notes per SDK:
- All ports subclass the existing RollbackController — the hooks are already
  there (`adoptTruth`/`applyStep`/`refreshRender`/`markDirty`; SimReconciler
  inherits `truthMatchesAt=false`, always adopts).
- The JS "world with bound schema entries replaced by mirrors IN PLACE" maps
  to: C = struct of user pointers + a bound-entry descriptor array; C#/Haxe =
  `Dictionary<string, object>`/`Dynamic` world with per-binding field lists;
  Lua = table world. Keep pose keys `"part.field"` strings everywhere.
- Skip (per manifest): custom `interpolate` can ship later; `boundRegistrations`
  overlay into Predict.value is optional — apps read `sim.value("puck.kx")`.

If timeboxing bites: ship lab 10 last, or compose paddle-prediction-only via
the flat Reconciler (puck rendered damped) with an honest "partial" label.

## 6. Per-SDK app architecture

All apps live in this repo (keeps them next to the server + shared sim
reference). Suggested layout: `clients/<sdk>-app/`. Each app: one window,
lab switch via number keys, `L` cycles latency presets (0/80/200/400ms +
jitter), `D` = drop transport, `P` = private-room toggle (rejoin).

### native-app (C + raylib)
- **Stack**: raylib (`brew install raylib`, pkg-config). Single-threaded
  render loop at 60fps; SDK callbacks fire on transport thread — copy decoded
  values into render structs once per frame (the probes' access pattern), or
  add a mutex around state reads. `signal(SIGPIPE, SIG_IGN)` first line.
- **Build**: extend native-sdk/build.zig with a gated `predict_playground`
  exe (same `.cwd_relative` pattern as `predict_probe`), linking raylib via
  system lib; OR a plain Makefile in the app dir compiling against
  `native-sdk/zig-out/lib` — build.zig route proved simpler, reuse it.
- WorldView = 30-line struct; drawArena = raylib DrawLine/DrawRectangleLines;
  HUD = DrawText; controls = keyboard-only (sliders as +/- keybinds shown
  on-screen). No immediate-mode GUI dependency needed.

### unity-app (Unity editor project)
- **Stack**: a real Unity project (2022 LTS) referencing the SDK from
  `colyseus-unity-sdk/Assets/Colyseus` via a local package/folder reference —
  NOT the nuget csproj (avoids the global-namespace fixture shadowing and
  actually exercises the Unity runtime path: NativeWebSocket main-thread
  dispatch removes the decode-race concern entirely).
- Arena = lines via `GL`/LineRenderer or a single quad grid texture; entities
  = SpriteRenderer squares/circles tinted with `Color.HSVToRGB(hue/256,·,·)`;
  HUD/controls = uGUI or IMGUI (`OnGUI` sliders are fine for a lab tool).
- One scene, `LabManager` MonoBehaviour = shell; each lab a class implementing
  a C# `ILab` mirroring the web lab contract. `Update()` = frame(); pacing via
  `predict.Tick(RoomClock.GetNow())` budget.
- Schemas: reuse `clients/unity/Schema/*.cs` (copy or asmdef-share).

### defold-app (Defold project)
- **Stack**: real Defold project with `colyseus-defold` as a game.project
  dependency (local path/zip). This is the FIRST validation of the SDK on the
  actual engine websocket (the probe used the FFI shim) — expect and budget
  for engine-integration surprises (main-loop callback timing, timer wheel).
- Render script or `draw_line` messages for arena/rays; GO factories with a
  quad sprite for entities (tint via `go.set("...", "tint")`); GUI scene for
  HUD/controls; labs as Lua modules returning the lab contract table.
- Everything decodes from reflection — no generated schemas at all.

### haxe-app (Heaps + HashLink)
- **Stack**: Heaps (`haxelib install heaps`) on **hl** (NOT neko: 31-bit
  ints, worse timers). `h2d.Graphics` for arena/shapes, `h2d.Text` HUD,
  keyboard via `hxd.Key`. js+canvas is the fallback target if hl+haxe-ws
  websocket proves unstable — same code, different mainloop shim.
- The sys-target decode race (probe finding): add the simple fix at app level
  — queue `connection.onMessage` bytes and drain+decode them from the render
  loop (main thread). ~20 lines, kills the race, and is the pattern to later
  upstream into the SDK.
- Schemas: reuse `clients/haxe/lab/*.hx`.

## 7. Milestones (per SDK, in order native → Unity → Defold → Haxe)

- **M1 — skeleton + core loop**: window, arena, WorldView, keyboard, NetHud,
  latency injector, lab switcher; labs **01, 02, 03**. Exit: at 200ms injected
  latency, lab 01 visibly rubber-bands, lab 03 is instant with matched drift;
  impulse button shows a correction that decays; `D` drop auto-reconnects and
  the reconciler resets cleanly.
- **M2 — prediction tour**: labs **00, 04, 05, 08, 09** (+ movers port).
  Exit: split-screen lanes visibly diverge by ~RTT; 04 shows 4 modes
  side-by-side with the raw square stepping and lerp gliding; 05 reckon
  tracks patrol/circle exactly and breaks honestly on wander; 08 banner is
  instant, deny-slider produces visible rejects; 09 shot has no handoff seam.
- **M3 — advanced**: SimReconciler port (§5) then labs **06, 07, 10, 11**
  (+ hockey/bump/random/spread/hitscan ports). Exit: 06 dead-on hits at
  200ms with lag comp on, misses when off; 07 verdict markers frozen across
  replays; 10 predicted puck responds instantly to your own shots, dashed
  server ghost trails; 11 client/server fans match to the pixel until the
  "break it" button swaps in engine RNG.

Ship each milestone as one commit per SDK app; keep the probes green
throughout (`predict_probe` etc. are the regression gate — run before/after).

## 8. Validation protocol (for the executing session)

1. Republish/overlay check: `node scripts/probe-negative-input.mjs` → LEFT.
2. All four headless probes → PROBE OK (they share the server with the apps).
3. Per-lab acceptance checklist (§7 exit criteria) at latency presets 0 /
   200ms / 200ms+80 jitter — record a one-line pass note per lab per SDK in
   the app's README as it lands.
4. **Cross-SDK multiplayer smoke**: open the web demo and 2+ SDK apps in the
   SAME lab-move room (no private flag) — every client sees every other as a
   smooth remote square; one client's impulse never disturbs others' drift.
   This is the highest-value demo artifact — capture a gif for the README.
5. Where cheap, add a `--selfcheck` CLI flag (native/haxe) that runs the
   startup canaries (sim constants, RNG vectors) and exits — CI-able without
   graphics.

## 9. Known future-work seams (explicitly out of scope)

**Port the app-facing surface, not just the algorithm.** Writing twelve labs
against the raw C predict API surfaced the same boilerplate over and over; the
fixes landed in native-sdk (`predict: make the app-facing surface do the
boilerplate`) and the Unity / Defold / Haxe ports should carry the same shapes
rather than rediscover them:

- `predict.tick()` must RETURN the fixed input steps due this frame — it is the
  input-pacing source, and a port that returns void makes every call site
  hand-roll the accumulator (11 of 12 labs did).
- `tick()` drives the Predict's children (reconcilers, event channels, spawn
  stores): one call per frame, not four.
- A room owns ONE decode-callback layer; a Predict borrows it. Anything the
  Predict registers on it must be removed when the Predict dies, or a patch
  decoded after a teardown calls into freed state.
- `attachAll` / `attachAllReckon` / `bindSpawns` — the "every entry of this
  collection, now and later" case is the common one.
- Reconcilers are born FROM a Predict, which is what binds the input handle's
  lag-comp `renderDelay` to the Predict's lerp delay. Skipping that binding cost
  the C lab 06 exactly the lerp delay in rewind error: 3/6 hits and 99 ms off
  without it, 6/6 and ~65 ms with.
- A vector `memo` (a tuple under one key) — splitting one verdict across several
  scalar memos re-runs the derivation per component.
- `value()` on a field that doesn't exist should be NAN, not 0.

- Upstreaming the Haxe main-thread decode pump into the SDK proper.
- native SO_NOSIGPIPE inside the transport (workaround pinned in apps).
- attachAll per-field-options map parity (JS sugar; `track` covers it).
- Predict bound-overlay (`value()` reading the reconciler for self) — apps
  read `recon.value()/state` directly, matching the ports' idiom.
- Docs panel / source display / sidebar — web-only, stays web-only.
