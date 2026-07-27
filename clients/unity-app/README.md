# unity-app — Prediction Playground on the Unity/C# SDK

The playground rebuilt against `colyseus-unity-sdk`, driven by the same server as
the web build. One scene, one MonoBehaviour: `Update()` advances the netcode,
`OnGUI()` draws the arena and the panel.

Status: **complete — all twelve labs (00–11)**, with a PlayMode acceptance suite
that replays APPS_PLAN §7's exit criteria against a live server.

## Running it

The server has to be up first — everything here talks to it, including the tests:

```sh
pnpm dev --host 0.0.0.0        # from the repo root; serves ws://localhost:5173
```

Then open `clients/unity-app` in Unity 6000.3 and press play, or run the
acceptance suite headless:

```sh
Unity -batchmode -runTests -testPlatform PlayMode \
      -projectPath clients/unity-app -testResults results.xml
```

The SDK is consumed as a local UPM package (`Packages/manifest.json` points at
`colyseus-unity-sdk/Assets/Colyseus`), so SDK edits show up on the next domain
reload with no copy step.

## Keys

| key | |
|---|---|
| `0`–`9` | switch lab (10 and 11 via the shell list) |
| `WASD` / arrows | drive |
| `L` | cycle the injected-latency preset |
| `D` | drop the socket (tests auto-reconnect) |
| `P` | private room ⇄ shared room |

Per-lab keys are listed in each lab's CONTROLS panel.

## Verification

`Assets/Tests/AcceptanceTest.cs` is the Unity twin of the native app's `--demo`
autopilot. It feeds the same `Kb` accessors a human does, so a lab cannot tell
whether a person or the harness is playing. PlayMode rather than EditMode: the
injector drains on a frame loop and the predict stack is driven per frame, so
both need real time to pass.

Last run, against a live server:

```
12 tests, 12 passed, 0 failed

OK lab00: peak lane separation 18.41 u
OK lab01: 87 ms at 0 injected, 521 ms at 200 ms
OK lab02: rtt 489 ms, patch 50 ms, jitter 1.2 ms
OK lab03 predicted: 9 in flight, drift ema 1.01E-008
OK lab03 impulse: peak 4.750, settled to 0.0000
OK lab04: raw 10.909, lerp 0.016, damped 0.187, extrapolate 0.219
OK lab05: peak reckon-lerp gap 12.62 u
OK lab06 comp ON: 6/6 hits, rewind error 0.97 u, view lag 8.7 u
OK lab07: predicted 1, authoritative 2, mispredict rate 0 %
OK lab08: 2 confirmed, 4 rejected of 6 predicted
OK lab09: fired 1, lead 247 ms, 3 confirmed
OK lab11 seeded: divergence 4.12E-008 rad over 3 fans
OK lab11 cheating: divergence 2.06E-001 rad
```

Two of those are worth reading twice. Lab 06 hits 6/6 with the server rewinding
to within 1 u of what we drew while the view itself lags 8.7 u — that gap is the
whole feature. And lab 11's seeded fan agrees with the server to 4e-8 rad but
diverges to 2e-1 the moment an unshared RNG is swapped in, which is what makes
the first number evidence rather than a tautology.

A drift EMA of ~1e-8 is float32 wire precision: `Sim.StepEntity` reproduces the
server's math to the last representable bit, and the residual is only the schema
field rounding on the way down. (The C port shows exactly zero because it can
hold the server's f64 all the way through.)

## Notable ports

**The latency injector needs a seam the SDK didn't have.** On localhost labs
00/01/03 demonstrate nothing, so every non-web client needs its own delay/jitter.
Subscribing to `OnMessage` cannot work — a subscriber runs *alongside* the room's
handler, so it could not delay anything. You have to be in front of it.

The first attempt gave `Connection` four `protected virtual Raise*` methods and
added a global `Client.ConnectionFactory` so a `DelayedConnection` subclass could
be built in the first place: six moving parts, one of them a static that changes
behaviour for every `Client` in the process.

The Lua client needed exactly one. `Connection` there is an EventEmitter, so
replacing `emit` puts you in front of every listener at once — and you wrap the
instance you already have, after the room joined. C# now has the same shape:
`Connection.Dispatch` (one delegate carrying a `ConnectionEvent`) and its
outbound twin `Transmit`. Capture the previous value, queue, call it when the
packet comes due. The subclass, the four virtuals and the static factory are all
gone, and the injector is per-room instead of per-process.

Wrapping *after* the join has a second benefit worth naming: the handshake rides
an undelayed link, so awaiting a join can no longer deadlock on a queue nobody is
draining yet — which is exactly the bug described below.

**Both directions queue and drain from `Update()`**, with each packet's
deliver-at clamped to ≥ the previous one's. The wire is a stream; TCP never
reorders, and neither may the injector.

**The seam costs nothing per message.** `ConnectionEvent` is a readonly struct
and `Action<ConnectionEvent>` doesn't box it, so the SDK side is allocation-free
by construction — but the *wrapper* is where that is easy to lose, and the first
version did: a `() => inner(e)` closure per packet plus a `Live.ToArray()` per
frame. `Connection_seam_allocates_nothing_per_message` pushes 20 000 synthetic
round trips through the seam and weighs the heap:

```
OK gc seam: 0.00 B/message over 20000 round trips
OK gc:      1144.0 KiB over 8.0s / 26375 frames (44 B/frame), 71 gen0 collections
```

The second line is the whole frame under lab 03's steady state and is dominated
by the SDK's receive-and-decode path, not by the injector. It is measured **per
frame, not per second**: this harness has run anywhere from 200 to 3300 fps, so a
per-second budget tracks the frame rate rather than the code — a lesson learned
when the same unchanged code reported 19 KiB/s on one run and 154 KiB/s on
another.

## Found while building this

**`Connection.Connect()` returns on close, not on open.** It awaits
`socket.Connect()`, which runs the receive loop for the socket's whole life. A
join therefore resolves on the *inbound* `JOIN_ROOM` frame — which the injector
is holding. Any code that awaits a join without pumping deadlocks at any nonzero
latency. `LabManager.Update()` pumps every frame so the app was fine; the first
version of the acceptance harness did not, and hung indefinitely rather than
failing. `Await()` now pumps, and every wait has a timeout that reports how many
packets are still in the injector.

**`Room.State` is instantiated at join; its collections are not.** Generated
schema declares `public MapSchema<Player> players = null;`, so waiting for
`State != null` — as `Shell.JoinLab` originally did — returns a room whose maps
are still null, and the lab mounts on nothing. The web build's `waitFor` and the
native app's retrying `attach` both wait for the actual entry. `JoinLab` now
takes a readiness predicate and each lab names what it needs decoded.

**`Room<T>` is invariant, so there is no generic way to hand the shell a room.**
`room as Room<Schema>` is always null, which under `?.` fails silently: the
status bar would never find a clock and a lab switch would never leave the old
room. `ILab` now exposes a type-erased `IRoom Room` and a `RoomClock Clock`
alongside the typed `RoomOf<T>()`.

**`Predict` had no teardown at all.** `AttachAll` returns an unsubscribe the
caller is unlikely to hold, and driven children were never disposed — so every
lab unmount left handlers registered against a room that was about to go away.
`Predict` now implements `IDisposable` and releases tracked fields, reckon sims,
AttachAll wiring and driven children together; disposing it is the only teardown
a lab needs. (The C SDK had the same hole, where it showed up as a crash.)

**`InputHandle.RenderDelay` was settable only at construction, and nothing set
it.** A lag-compensating server rewinds to `serverNow − (renderDelay + rtt/2)`,
so leaving it at zero makes every rewound read land one full render-delay early
— shots miss by exactly that much and nothing in the logs says so.
`Predict.MakeReconciler` now binds it from the lerp delay already attached, which
is what makes lab 06 land 6/6 instead of missing by the view lag. This is the
same trap the C port hit, and it is worth stating plainly for the two SDKs still
to come: **if a client draws the past, it has to say so.**

**Two conveniences worth having:** `Predict.For(room)` replaces
`new Predict(new PredictCallbacks<T>(Callbacks.Get(room)), room.Clock)` — the
same two collaborators every time, and no decision the caller is better placed to
make. `AttachAllReckon` is the reckon twin of `AttachAll`, for a collection whose
members should be forward-simulated rather than smoothed toward the past (lab
07's bots).
