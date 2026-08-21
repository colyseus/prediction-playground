# defold-app — Prediction Playground on the Defold/Lua SDK

The playground rebuilt against `colyseus-defold`, driven by the same server as
the web build. One game object, one script: `update()` advances the netcode and
then the draw pass, `on_input()` only fills the shared `kb` table.

Status: **12 labs (00–11)**, all verified against a live server by a headless
acceptance run — 44 checks, all green. Lab 10 (composite sim) binds to the SDK's
`predict:sim()`.

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
# the netcode, against a live server — 44 checks across 12 labs
cd clients/defold-app && luajit headless/acceptance.lua

# the engine build (bob needs the Defold editor's bundled JDK 25 — the 21
# beside it is too old for the jar, and there is no java on PATH)
JDK=/Applications/Defold.app/Contents/Resources/packages/jdk-25+36/bin/java
$JDK -cp /Applications/Defold.app/Contents/Resources/packages/defold-*.jar \
     com.dynamo.bob.Bob resolve build
```

Last run:

```
OK  lab01 input->motion 95 ms at 0 injected -> 347 ms on a 200 ms round trip
OK  lab02 smoothed rtt 288 ms, patch 50 ms, 79 arrivals buffered
OK  lab00 lanes separate by a peak of 12.44 u
OK  lab04 raw stutters 2.06 vs lerp 0.04
OK  lab05 reckon leads lerp by 5.05 u; circle y sweep 22.43 u
OK  lab03 5 unacked, drift ema 0.000e+00, impulse 7.541 -> settled 0.0000
OK  lab08 2 confirmed / 0 rejected at 0 % deny; 6 predicted / 4 rejected at 100 %
OK  lab09 a local exists the same frame it fires, lead 200 ms
OK  lab06 6/6 hits, rewind error 0.01 u while the view lags 7.5 u
OK  lab07 predicted 2, authoritative 2, mispredict rate 0 %
OK  lab11 divergence 2.915e-08 rad seeded, 2.203e-01 with an unshared RNG
OK  lab10 median correction 0.0000 over 229 reconciles; puck leads by 13.83 u
OK  drop + reconnect: drift re-converges to 5.126e-07, no stale replay
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
one full render-delay early and shots miss by exactly that much), a room-taking
`Predict` factory, and a reckon flavour of `attach_all`.

The last two have been respelled since. The factory is `Predict.get(room,
options)`, whose options are the defaults every attach then inherits. Reckon
rides the ordinary `attach_all(collection, { mode = "reckon", fields = { ... },
step = ... })` — the declarative config landed in `af169c1` and made a separate
entry point redundant.
