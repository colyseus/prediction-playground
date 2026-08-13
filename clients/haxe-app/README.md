# haxe-app — Prediction Playground on the Haxe SDK

The playground rebuilt against `colyseus-haxe`, driven by the same server as the
web build. Heaps for the window; the netcode is verified headless.

Status: **all 12 labs**, 38 acceptance checks green against a live server.
Lab 10 (composite sim) rides the SDK's `SimReconciler` port (`predict.sim`) and
predicts the puck AND the AI paddle through your own inputs, like the web build.

## The one structural decision

**Labs touch no Heaps API.** They draw through the `Gfx` they are handed and read
input through `App.Kb`. That is what lets the acceptance harness run the *real*
lab modules with `GfxNull` and no window — what gets tested is byte-for-byte what
the windowed build runs.

`GfxHeaps` is one `h2d.Graphics` cleared per frame plus a pool of `h2d.Text`, so
the client needs no assets at all. The arena's y points down, which matches
Heaps' screen space, so unlike the Defold backend there is no flip.

A lab also does its own **typed join**, because the SDK's join is generic over
the state class and only the lab knows that type.

## Running it

The server has to be up first — the app and the tests both talk to it:

```sh
pnpm dev --host 0.0.0.0        # from the repo root; serves ws://localhost:5173
```

```sh
cd clients/haxe-app

# the netcode, against a live server — 38 checks across 12 labs
haxe acceptance.hxml && neko bin/acceptance.n

# the windowed client (HL/C — see the toolchain note below)
./build-hlc.sh && ./bin/hlc-playground
```

**Two targets on purpose.** The harness is neko: the SDK is proven on that target
by `clients/haxe/PredictProbe`, and the shared-sim canary passes there bit for
bit. The window is hl, because Heaps targets hl or js only — neither neko nor cpp
can run it. Both are compiled on every change, and the hl build is the stricter
type-check of the two (it caught a `null` compared against an `Array<Float>`
element, which neko accepts).

> **Toolchain note.** HashLink's JIT has no arm64 backend, so `hl
> playground.hl` cannot run on Apple Silicon (and Homebrew's `hashlink` ships
> headers + lib only, no JIT binary). `build-hlc.sh` sidesteps the JIT: Haxe
> emits C (`build-hlc.hxml`), and clang links it against the arm64 `libhl` and
> `.hdll` natives Homebrew ships — that native binary is the windowed client.
> `haxe build.hxml` (the bytecode target) is still compiled on every change as
> the stricter type-check.

## Verification

Last run (`neko bin/acceptance.n`):

```
OK  lab01 input->motion 89 ms at 0 injected -> 481 ms at 200 ms each way
OK  lab02 smoothed rtt 481 ms, patch 50 ms, 79 arrivals buffered
OK  lab00 lanes separate by a peak of 34.41 u
OK  lab05 reckon leads lerp by 9.02 u; circle y sweep 22.82 u
OK  lab03 9 unacked, drift ema 0, impulse 4.750 -> settled 0
OK  lab04 raw CV 1.95 vs lerp 0.05
OK  lab08 2 confirmed / 0 rejected at 0 % deny; 6 predicted / 4 rejected at 100 %
OK  lab09 a local exists the same frame it fires, lead 371 ms
OK  lab06 6/6 hits, rewind error 0.76 u while the view lags 9.5 u
OK  lab07 predicted 2, authoritative 2, mispredict rate 0 %
OK  lab11 divergence 4.07e-08 rad seeded, 2.27e-01 with an unshared RNG
OK  lab10 median correction 0 over 224 reconciles; struck puck leads its ghost by 21.31 u peak over 7 touches
```

**Drift of exactly zero**, matching the C and Lua ports: Haxe `Float` is f64 all
the way from the schema through `stepEntity` and back. Only the C# client shows a
residual (~1e-8), because its schema `number` fields are float32.

## The lab 11 seed bug, and why the canary missed it

Lab 11's seeded fan disagreed with the server on roughly one shot in three. The
assertion was right and the client was wrong; the cause was in this port's own
`Sim`, not the SDK.

`splitmix32` returned the seed as an *unsigned* value in a `Float`, and
`spreadAngles` then did `new Rng(Std.int(shotSeed(...)))`. Half of all seeds
exceed 2³¹, and `Std.int` cannot represent those on a 32-bit-`Int` target — it
collapses them, so unrelated shots silently shared one RNG stream. Against the
TypeScript reference for salt 3004265928:

```
seq  JS reference          Haxe (before)         Haxe (after)
50   0.5586675314931199    0.473057273640297     0.55866753149312
51   0.5097583230119198    0.473057273640297     0.50975832301192
52   0.3740800889488309    0.374080088948831     0.374080088948831
53   0.5387157244700930    0.473057273640297     0.538715724470094
```

The repeated constant is the collapse: every seed ≥ 2³¹ became the same number.
Seeds that happened to land under 2³¹ (seq 52 here) were fine, which is exactly
why it looked intermittent — roughly half of shots.

`splitmix32` and `shotSeed` now return the raw 32-bit **pattern** as an `Int`,
which may be negative, and the unsigned conversion happens only where a
magnitude is actually wanted (`Rng.next`'s division, and the canary's
comparisons).

**The canary missed it because both its vectors were too small.** `splitmix32(1)`
= 1580013426 and `shotSeed(7, 12345)` = 1994071465 are both under 2³¹, so they
exercised the one half of the input space that worked. It now also pins a real
`(seq, salt)` pair whose seed exceeds 2³¹ — `spreadAngles(0.5, 50, salt)` for the
salt above — which fails loudly against the old code.

The wider lesson for the other ports: a reference vector that never crosses a
representation boundary does not test the boundary. The C, C# and Lua canaries
carry the same two small vectors, and while their languages make this particular
mistake harder, none of them proves the wide-seed case either.

## Found while building this

**`Room.state` is a property with a getter.** Read through `Dynamic` on a sys
target, Haxe looks up a *field* — which does not exist — and quietly yields null.
The room joins, the session id is right, and the state simply never appears.
Every room reference here is cast to its concrete type for that reason.

**neko's dynamic dispatch matches on EXACT arity.** `room.leave()` and
`room.send("impulse")` are calls that do not exist when the signatures have
optional parameters. The SDK already documents this for its own callbacks; it
bites app code identically.

**Capturing a dynamic function as a value can drop its `this`**, so the original
`Connection.send` found a null socket. `Reflect.field` + `Reflect.callMethod`
binds it explicitly.

**`Callbacks.get(room)` queues onto Heaps' MainLoop**, which never drains on a
headless sys target — the harness would silently see no callbacks at all.
`Predict.get(room)` uses the immediate `SchemaCallbacks(decoder)` flavour
instead, which is correct in both builds because prediction is driven from the
caller's own loop. That trap belongs in the SDK rather than in every app that
hits it, which is why the helper moved out of `App`.

**The reckon scratch was dropping string fields** (`colyseus-haxe`, fixed).
`shared/movers.ts` documents it as a full copy of the entity, but strings were
excluded alongside ref/array/map — so the bot reckon ran `patrol` for *every*
pattern. This is the third SDK with that bug; it was caught here by an assertion
written for the second one, on its first run.

**`Connection.send` is now `dynamic`**, matching `onMessage`. `onMessage` was
already the inbound seam, but there was no outbound equivalent, so a decorator
could intercept one direction and not the other.

**Three DX gaps closed to match the other SDKs** (`colyseus-haxe`):
`predict.dispose()`, `renderDelay` bound from the attached lerp delay inside
`reconciler()`, and `attachAllReckon`.
