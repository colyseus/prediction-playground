# defold-app — Prediction Playground on the Defold/Lua SDK

The playground rebuilt against `colyseus-defold`, driven by the same server as
the web build. One game object, one script: `update()` advances the netcode and
then the draw pass, `on_input()` only fills the shared `kb` table.

Status: **11 labs (00–09, 11)**, all verified against a live server by a headless
acceptance run. Lab 10 (composite sim) is not here: the Lua SDK has no
`SimReconciler`, so the lab has no API to bind to.

## Running it

The server has to be up first — the app and the tests both talk to it:

```sh
pnpm dev --host 0.0.0.0        # from the repo root; serves ws://localhost:5173
```

Then open `clients/defold-app` in the Defold editor and press play.

`colyseus` is a symlink to `../../../../colyseus-defold/colyseus`, so the app
runs against the working copy of the SDK with no copy step. The websocket native
extension comes from `game.project`'s dependency list.

> **Write Lua 5.1 only.** The headless gates run under `luajit`, which accepts
> LuaJIT-only grammar (`goto` / `::labels::`) — but the Defold editor validates
> scripts as plain Lua 5.1 and rejects it as a build error. The gate that
> mirrors the editor is the bob build below.

## The one structural decision

**Labs touch no Defold API.** They draw through the `gfx` table the shell hands
them, and read input through `app.kb`. That is what lets the acceptance harness
run the *real* lab modules under plain `luajit` with a no-op backend — what gets
tested is byte-for-byte what the engine build runs, not a reimplementation.

It matters more here than on the other clients, because Defold has no headless
test runner to fall back on. The two backends are `gfx_defold.lua` (built-in
render-script `draw_line` / `draw_debug_text` messages — no atlas, no material,
no game objects) and `gfx_null.lua`, which doubles as the written contract.

Two coordinate facts live in the backend and nowhere else: the 100×60 arena is
letterboxed into the window, and the arena's y points *down* (it is a canvas
port) while Defold's screen y points *up*.

## Verification

```sh
# the netcode, against a live server — 35 checks across 12 labs
cd clients/defold-app && luajit headless/acceptance.lua

# the engine build (bob needs the Defold editor's bundled JDK 25 — the 21
# beside it is too old for the jar, and there is no java on PATH)
JDK=/Applications/Defold.app/Contents/Resources/packages/jdk-25+36/bin/java
$JDK -cp /Applications/Defold.app/Contents/Resources/packages/defold-*.jar \
     com.dynamo.bob.Bob resolve build
```

Last run:

```
OK  lab01 input->motion 95 ms at 0 injected -> 495 ms at 200 ms each way
OK  lab02 smoothed rtt 483 ms, patch 50 ms, 79 arrivals buffered
OK  lab00 lanes separate by a peak of 21.65 u
OK  lab05 reckon leads lerp by 9.02 u; circle y sweep 22.92 u
OK  lab03 9 unacked, drift ema 0.000e+00, impulse 4.823 -> settled 0.0000
OK  lab08 2 confirmed / 0 rejected at 0 % deny; 6 predicted / 4 rejected at 100 %
OK  lab09 a local exists the same frame it fires, lead 364 ms
OK  lab06 6/6 hits, rewind error 0.68 u while the view lags 10.8 u
OK  lab07 predicted 2, authoritative 2, mispredict rate 0 %
OK  lab11 divergence 3.623e-08 rad seeded, 2.436e-01 with an unshared RNG
```

**Drift of exactly zero** is the number to notice. Lua carries f64 from the
schema through `step_entity` and back, so like the C port this client reproduces
the server's math with no residual at all; the C# client sits at ~1e-8 because
its schema `number` fields are float32.

## Found while building this

**`bit.tobit(a * b)` is not `Math.imul`.** Both operands reach 2³², so the
product reaches 2⁶⁴ and the double has already dropped the low bits by the time
`tobit` truncates. `mulberry32` returned 0.806 where the reference says 0.00976.
Splitting one operand into 16-bit halves keeps every partial product under 2⁴⁸,
where a double is still exact. This is the module `APPS_PLAN` §2 predicted would
break, and it breaks *silently* — nothing about a wrong pellet angle looks wrong
until you compare it with the server's.

**Lua has the cleanest injector seam of the four SDKs.** `Connection` is an
EventEmitter, so replacing `emit` puts the injector in front of every listener at
once, including ones registered later, on the instance you already hold. The C
port needed a wrapper transport and the C# port needed new upstream hooks to
reach the same place — and the C# SDK has since been reshaped to match this one
(`Connection.Dispatch`).

**The reckon scratch was dropping string fields.** `shared/movers.ts` documents
it as "a full copy of the entity, so non-attached fields like `kind`/`minX` are
readable here", but strings were excluded alongside ref/array/map — so the bot
reckon ran `patrol` for *every* pattern, in both this client and the Unity one,
with nothing reporting a problem. Fixed in both SDKs; both suites now assert that
`circle` makes the reckoned y sweep, because circle is the only pattern that
moves in y.

**Four DX gaps, closed to match the C and C# SDKs** (`colyseus-defold@31dbb45`):
`predict:dispose()` (there was no teardown at all, so anything outliving its
screen kept firing callbacks into freed state), `render_delay` bound from the
attached lerp delay inside `:reconciler()` (without it every rewound read lands
one full render-delay early and shots miss by exactly that much),
`Predict.get(room)`, and `attach_all_reckon`.
