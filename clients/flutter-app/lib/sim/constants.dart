/// Port of `src/shared/constants.ts`.
///
/// Every value is transcribed literally — the server runs the TypeScript
/// original, so a constant that drifts here becomes a permanent reconcile
/// correction. Dart `double` is f64, same as a JS `number`.
///
/// Name mapping (TS `SCREAMING_SNAKE` -> Dart `lowerCamelCase`):
///
/// | TypeScript            | Dart                |
/// |-----------------------|---------------------|
/// | `TICK_HZ`             | [tickHz]            |
/// | `ARENA_W`             | [arenaW]            |
/// | `ARENA_H`             | [arenaH]            |
/// | `PLAYER_HALF`         | [playerHalf]        |
/// | `PLAYER_ACCEL`        | [playerAccel]       |
/// | `PLAYER_MAX_SPEED`    | [playerMaxSpeed]    |
/// | `PLAYER_FRICTION_K`   | [playerFrictionK]   |
/// | `BOT_RADIUS`          | [botRadius]         |
/// | `REMOTE_INTERP_MS`    | [remoteInterpMs]    |
/// | `MAX_REWIND_MS`       | [maxRewindMs]       |
/// | `TELEPORT_SNAP_DIST`  | [teleportSnapDist]  |
/// | `Math.SQRT1_2`        | [sqrtHalf]          |
library;

/// Fixed simulation rate. The server advertises it via `setFixedTimestep` and
/// predicting clients pace one input per step — dt never goes on the wire.
const int tickHz = 20;

/// World units. The arena is a fixed logical rectangle letterboxed into the
/// viewport.
const double arenaW = 100.0;
const double arenaH = 60.0;

/// Player squares (half-extent).
const double playerHalf = 1.6;

/// Player acceleration, u/s².
const double playerAccel = 220.0;

/// Player speed cap, u/s.
const double playerMaxSpeed = 34.0;

/// Per-tick friction multiplier when no input is held. dt is fixed, so
/// friction is a literal constant — no `exp()` in the shared step; sqrt/mul/add
/// only, for identical results across engines.
const double playerFrictionK = 0.72;

/// Bots.
const double botRadius = 1.8;

/// Remote-entity interpolation buffer (Lab 4 default; per-mode sliders
/// override).
const double remoteInterpMs = 100.0;

/// Server lag-comp rewind cap (~2x a high RTT; also bounds render-time
/// spoofing).
const double maxRewindMs = 500.0;

/// Teleport-class discontinuities render as a CUT, not a glide: `snap`
/// thresholds and server-side rewound-read guards both key on this.
const double teleportSnapDist = 8.0;

/// `Math.SQRT1_2` — the exact double the JS sim multiplies by for diagonal
/// input. Same bits as `dart:math`'s `sqrt1_2`; spelled out here so the
/// literal is auditable against the other ports.
const double sqrtHalf = 0.70710678118654752440;
