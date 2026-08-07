# Prediction Playground — Godot (GDScript)

The full 12-lab playground on **Godot 4.6 (GDScript)**, on the native-sdk
**GDExtension** (`native-sdk/platforms/godot`) — the SDK's flagship Godot
lane. Everything the labs use is the GDScript surface in
`addons/colyseus/colyseus.gd`: reflection-decoded state (no schema classes
declared anywhere), `room.input()` synthesized from the handshake's
INPUT_REFLECTION, `Colyseus.Predict` (attach/attach_all/attach_reckon/
reconciler/sim/define_event/spawns), `room.clock`, and the SDK's C-side
latency injector (`room.set_latency` + `room.net_pump`).

The C# twin (`clients/godot-app`) is the structural blueprint: same shell
contract, same lab numbering and keys, same acceptance checks and
thresholds. `scripts/sim.gd` is the shared-sim port (f64 bit-exact club,
canaries pinned to the TypeScript originals; the RNG canary pins the
*integer* stream because Godot's tokenizer parses 21-digit float literals
one ulp off).

## Run

```sh
pnpm dev --host 0.0.0.0        # from the repo root — the server, mandatory
/Applications/Godot.app/Contents/MacOS/Godot --path clients/godot-gd-app
```

Keys: `0-9` lab, `[` `]` prev/next, `L` latency preset, `K` drop the
transport uncleanly (the SDK auto-reconnects, the lab rebinds, the latency
preset re-applies), `P` private-room toggle, per-lab keys on the HUD.

`addons/colyseus` is a symlink into `native-sdk/platforms/godot/addons/
colyseus` — rebuild the extension with `cd native-sdk/platforms/godot &&
zig build` after touching its C sources.

## Verification gates

```sh
GODOT=/Applications/Godot.app/Contents/MacOS/Godot   # the NON-mono binary

# 1. shared-sim canaries (16 checks pinned to the TypeScript originals)
$GODOT --headless --path clients/godot-gd-app -- --selfcheck

# 2. quick smoke: mounts all 12 labs headless, counts patches per lab
$GODOT --headless --path clients/godot-gd-app -- --smoke

# 3. the acceptance suite — the C# twin's checks + the Callable-overhead
#    measurement, replayed against the live server
$GODOT --headless --path clients/godot-gd-app res://Acceptance.tscn
```

All three need the dev server up. After adding scripts, run
`$GODOT --headless --path clients/godot-gd-app --import` once so the global
class cache picks up new `class_name`s.

## Acceptance record (2026-08-05, Godot 4.6.1, ACCEPT OK 14/14)

| check | measured |
|---|---|
| sim selfcheck | 16/16 canaries (integer-stream RNG vectors) |
| lab01 input→motion | 97 ms at 0 injected, 568 ms at 200 ms |
| lab02 clocks @200 ms | rtt 500 ms, patch 50 ms, jitter 7.1 ms |
| lab03 reconcile | drift ema 0.000000 (f64 mirrors), impulse peak 4.82 → 0.0000 |
| lab00 lane separation | peak 19.0 u |
| lab04 speed CV | raw 2.62 · lerp 0.21 · damped 0.27 · extrapolate 0.63 |
| lab05 reckon | reckon↔lerp gap 21.4 u; circle y sweep 22.4 u |
| lab06 lag comp | 6/6 hits, rewind error 0.96 u, view lag 6.4 u |
| lab07 verdicts | predicted 2 = authoritative 2, 0 % mispredict |
| lab08 events | 2 confirmed / 4 rejected of 6, deny-rate driven |
| lab09 handoff | lead 274 ms measured, worst jump 2.04 u (bound 4.0 — see below) |
| lab10 composite | peak puck lead 23.4 u, median correction 0.0009 over 218 reconciles |
| lab11 RNG | 4.7e-9 rad seeded vs 2.3e-1 rad cheating |
| Callable overhead @400 ms+60 j | predict.tick median 0.01 ms, p99 0.06 ms, worst 0.28 ms (19 pending) |

The lab09 bound is 4.0 u where the C# twin uses 3.0: patch age and the
measured lead each quantize at one 50 ms tick (1.7 u of flight), so a
legitimate handoff occasionally reads ~3.5 u here (observed 2.0-3.7 across
runs); the un-reckoned failure mode this check exists to catch measures
8-11 u. The Callable-overhead row is the P2 plan's owed measurement: a
reconcile burst at a 400 ms backlog (~10 pending inputs replayed through a
GDScript step Callable per reconcile) costs well under a millisecond —
StringName `_get`/`_set` dispatch does NOT dominate, so no field-index
accessor fallback is needed.

## GDExtension facts the labs are built on

- **`get_state()` returns a fresh snapshot Dictionary on every call** — the
  whole tree is converted per call, so a cached entry is FROZEN. Labs
  re-fetch state each frame for raw reads. Predict handles stay valid across
  time: instances resolve by `__ref_id`, which is stable.
- **The reckon scratch carries scalar fields only** — string fields (the
  bot's `kind`) never reach it, so reckon steps take the kind as an argument
  read off fresh decoded state (`Sim.step_bot(b, dt, t, kind)`).
- **Step callables mutate C storage directly**: `s.x += s.vx * ctx.dt` on the
  mirror/scratch views lands in the reconciler's native state — sim.gd's
  steps run identically over those views and plain Dictionaries (the
  spawn-store locals and the selfcheck).
- **Sends stage floats**: `input.data.fire = 1.0` (the InputData `_set`
  coerces through float; the encoder writes the schema type).
- Labs 06/11 gate the lag-comp stamp with `input.set_rewind_field("fire")`;
  lab 09 arms confirmed-entity dead reckoning with the `fields` +
  `reckon_step` options of `Predict.spawns` — both bindings added for this
  app (uncommitted in native-sdk alongside the netdelay close-path fix).
