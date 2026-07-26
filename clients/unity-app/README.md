# unity-app — Prediction Playground on the Unity/C# SDK

The playground rebuilt against `colyseus-unity-sdk`, driven by the same server as
the web build. One scene, one MonoBehaviour: `Update()` advances the netcode,
`OnGUI()` draws the arena and the panel.

Status: **M1 complete** — shell + labs 01, 02, 03, with a PlayMode acceptance
test that replays APPS_PLAN §7's M1 exit criteria against a live server.

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
| `1` `2` `3` | switch lab |
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
Passed  Sim_reproduces_the_reference_numbers            0.00s
Passed  Lab01_input_to_motion_tracks_the_round_trip     7.06s
Passed  Lab02_clock_readouts_respond_to_injected_latency 5.02s
Passed  Lab03_predicts_instantly_and_absorbs_a_mispredict 11.53s

OK lab01: 93 ms at 0 injected, 521 ms at 200 ms
OK lab02: rtt 469 ms, patch 50 ms, jitter 0.6 ms
OK lab03 predicted: 9 in flight, drift ema 9.28E-009
OK lab03 impulse: peak 4.823, settled to 0.0000
```

A drift EMA of 9.3e-9 is float32 wire precision: `Sim.StepEntity` reproduces the
server's math to the last representable bit, and the residual is only the schema
field rounding on the way down. (The C port shows exactly zero because it can
hold the server's f64 all the way through.)

## Notable ports

**The latency injector needs a seam the SDK didn't have.** On localhost labs
00/01/03 demonstrate nothing, so every non-web client needs its own delay/jitter.
Two upstream additions made it possible (`colyseus-unity-sdk@78ee668`):
`Client.ConnectionFactory`, so a room builds a `DelayedConnection` instead of a
plain one; and `virtual RaiseOpen/RaiseMessage/RaiseError/RaiseClose` on
`Connection`, so inbound frames can be intercepted *in front of* the room's
handler. Subscribing to `OnMessage` cannot work — a subscriber runs alongside the
room's handler, so it could not delay anything.

**Both directions queue and drain from `Update()`**, with each packet's
deliver-at clamped to ≥ the previous one's. The wire is a stream; TCP never
reorders, and neither may the injector.

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
