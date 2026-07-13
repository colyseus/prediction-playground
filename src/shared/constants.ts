// Fixed simulation rate. The server advertises it via setFixedTimestep and
// predicting clients pace one input per step — dt never goes on the wire.
export const TICK_HZ = 20;

// World units. The arena is a fixed logical rectangle letterboxed into the canvas.
export const ARENA_W = 100;
export const ARENA_H = 60;

// Player squares (half-extent) and movement tuning.
export const PLAYER_HALF = 1.6;
export const PLAYER_ACCEL = 220;      // u/s²
export const PLAYER_MAX_SPEED = 34;   // u/s
// Per-tick friction multiplier when no input is held (dt is fixed, so friction
// is a literal constant — no Math.exp in the shared step; sqrt/mul/add only,
// for identical results across JS engines).
export const PLAYER_FRICTION_K = 0.72;

// Bots.
export const BOT_RADIUS = 1.8;

// Remote-entity interpolation buffer (Lab 4 default; per-mode sliders override).
export const REMOTE_INTERP_MS = 100;

// Server lag-comp rewind cap (~2× a high RTT; also bounds render-time spoofing).
export const MAX_REWIND_MS = 500;

// Teleport-class discontinuities render as a CUT, not a glide: attach `snap`
// thresholds and server-side rewound-read guards both key on this.
export const TELEPORT_SNAP_DIST = 8;
