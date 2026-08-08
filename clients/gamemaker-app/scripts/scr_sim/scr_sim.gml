// =============================================================================
// Shared deterministic sim — transliterated from src/shared/*.ts (use
// clients/native-app/sim.h as the cross-check). f64 math with the exact op
// order; the uint32 RNG is arithmetic-only (mod/floor/16-bit halves) so the
// VM and HTML5 runners compute identical bits — see the RNG section header.
// =============================================================================

// constants.ts
#macro SIM_TICK_HZ 20
#macro SIM_ARENA_W 100
#macro SIM_ARENA_H 60
#macro SIM_PLAYER_HALF 1.6
#macro SIM_PLAYER_ACCEL 220
#macro SIM_PLAYER_MAX_SPEED 34
#macro SIM_PLAYER_FRICTION_K 0.72
#macro SIM_BOT_RADIUS 1.8
#macro SIM_TELEPORT_SNAP_DIST 8
#macro SIM_SQRT1_2 0.70710678118654752440
// hockey.ts
#macro SIM_PADDLE_RADIUS 2.2
#macro SIM_PUCK_RADIUS 1.4
#macro SIM_PUCK_FRICTION_K 0.985
#macro SIM_PUCK_RESTITUTION 0.92
#macro SIM_PUCK_PUSH_MIN 14
// projectile.ts
#macro SIM_PROJECTILE_SPEED 34
#macro SIM_PROJECTILE_TTL_MS 2600
#macro SIM_PROJECTILE_RADIUS 0.7
// goal.ts
#macro SIM_SCORE_COOLDOWN_TICKS 50
// spread.ts
#macro SIM_PELLETS 6
#macro SIM_SPREAD_RAD 0.38

/// movement.ts stepEntity — mutates the {x,y,vx,vy} struct in place.
function sim_step_entity(_e, _mx, _my, _dt) {
    var _ax = _mx, _ay = _my;
    if (_ax != 0 && _ay != 0) { _ax *= SIM_SQRT1_2; _ay *= SIM_SQRT1_2; }

    if (_ax != 0 || _ay != 0) {
        _e.vx += _ax * SIM_PLAYER_ACCEL * _dt;
        _e.vy += _ay * SIM_PLAYER_ACCEL * _dt;
    } else {
        _e.vx *= SIM_PLAYER_FRICTION_K;
        _e.vy *= SIM_PLAYER_FRICTION_K;
        if (_e.vx > -0.05 && _e.vx < 0.05) _e.vx = 0;
        if (_e.vy > -0.05 && _e.vy < 0.05) _e.vy = 0;
    }

    var _sq = _e.vx * _e.vx + _e.vy * _e.vy;
    if (_sq > SIM_PLAYER_MAX_SPEED * SIM_PLAYER_MAX_SPEED) {
        var _s = SIM_PLAYER_MAX_SPEED / sqrt(_sq);
        _e.vx *= _s;
        _e.vy *= _s;
    }

    _e.x += _e.vx * _dt;
    _e.y += _e.vy * _dt;

    var _min_x = SIM_PLAYER_HALF, _max_x = SIM_ARENA_W - SIM_PLAYER_HALF;
    var _min_y = SIM_PLAYER_HALF, _max_y = SIM_ARENA_H - SIM_PLAYER_HALF;
    if (_e.x < _min_x) { _e.x = _min_x; if (_e.vx < 0) _e.vx = 0; }
    else if (_e.x > _max_x) { _e.x = _max_x; if (_e.vx > 0) _e.vx = 0; }
    if (_e.y < _min_y) { _e.y = _min_y; if (_e.vy < 0) _e.vy = 0; }
    else if (_e.y > _max_y) { _e.y = _max_y; if (_e.vy > 0) _e.vy = 0; }
}

/// stepEntity over a reconciler mirror (anything with get/set). The shared
/// body of every lab's step function; the scratch struct is reused so a
/// replay burst allocates nothing.
function sim_step_mirror(_s, _mx, _my, _dt) {
    static _e = { x: 0, y: 0, vx: 0, vy: 0 };
    _e.x = _s.get("x");   _e.y = _s.get("y");
    _e.vx = _s.get("vx"); _e.vy = _s.get("vy");
    sim_step_entity(_e, _mx, _my, _dt);
    _s.set("x", _e.x);   _s.set("y", _e.y);
    _s.set("vx", _e.vx); _s.set("vy", _e.vy);
}

// bump.ts
#macro SIM_BUMP_COOLDOWN_TICKS 12
#macro SIM_BUMP_SPEED 48

/// hitscan.ts rayCircle — nearest intersection t along a unit ray, or -1.
function sim_ray_circle(_ox, _oy, _dx, _dy, _cx, _cy, _r, _max_dist) {
    var _mx = _ox - _cx, _my = _oy - _cy;
    var _b = _mx * _dx + _my * _dy;
    var _c = _mx * _mx + _my * _my - _r * _r;
    if (_c > 0 && _b > 0) return -1;
    var _disc = _b * _b - _c;
    if (_disc < 0) return -1;
    var _t = -_b - sqrt(_disc);
    var _hit = _t < 0 ? 0 : _t;
    return _hit <= _max_dist ? _hit : -1;
}

// ── uint32 RNG (random.ts) ─────────────────────────────────────────────
//
// ARITHMETIC-ONLY uint32 emulation: the HTML5 runner lowers GML bitwise ops
// to JavaScript int32 semantics (sign-extended shifts, 32-bit coercion),
// which silently diverges from the VM's int64 behavior. Shifts become
// floor-division, masks become mod, and xor/or work on 16-bit halves —
// every intermediate stays in safe integer range on BOTH runners, so the
// canaries pin the same bits everywhere.

/// x mod 2^32 (x non-negative, < 2^53)
function sim_u32(_x) {
    return _x - floor(_x / 4294967296) * 4294967296;
}

/// logical right shift for x in [0, 2^32)
function sim_shr(_x, _n) {
    return floor(_x / power(2, _n));
}

/// bitwise XOR of two uint32s via 16-bit halves (int32-safe on every runner)
function sim_xor32(_a, _b) {
    // floor, not `div`: the HTML5 runner lowers `div` as ROUNDED division
    var _ah = floor(_a / 65536), _al = _a mod 65536;
    var _bh = floor(_b / 65536), _bl = _b mod 65536;
    return (_ah ^ _bh) * 65536 + (_al ^ _bl);
}

/// bitwise OR of two uint32s via 16-bit halves
function sim_or32(_a, _b) {
    var _ah = floor(_a / 65536), _al = _a mod 65536;
    var _bh = floor(_b / 65536), _bl = _b mod 65536;
    return (_ah | _bh) * 65536 + (_al | _bl);
}

/// Math.imul with uint32 result — split-16, no products past 2^49.
function sim_imul(_a, _b) {
    _a = sim_u32(_a);
    _b = sim_u32(_b);
    var _al = _a mod 65536;
    var _ah = floor(_a / 65536) mod 65536;
    return sim_u32(_al * _b + ((_ah * _b) mod 65536) * 65536);
}

/// splitmix32 — one-shot avalanche of a 32-bit seed.
function sim_splitmix32(_a) {
    _a = sim_u32(_a + 2654435769);                       // 0x9E3779B9
    var _t = sim_xor32(_a, sim_shr(_a, 16));
    _t = sim_imul(_t, 569420461);                        // 0x21F0AAAD
    _t = sim_xor32(_t, sim_shr(_t, 15));
    _t = sim_imul(_t, 1935289751);                       // 0x735A2D97
    return sim_xor32(_t, sim_shr(_t, 15));
}

/// mulberry32 — seeded PRNG as plain functions + a state struct.
function sim_mulberry32_create(_seed) {
    return { a: sim_u32(_seed) };
}
function sim_mulberry32_next(_state) {
    _state.a = sim_u32(_state.a + 1831565813);           // 0x6D2B79F5
    var _a = _state.a;
    var _t = sim_imul(sim_xor32(_a, sim_shr(_a, 15)), sim_or32(1, _a));
    _t = sim_xor32(sim_u32(_t + sim_imul(sim_xor32(_t, sim_shr(_t, 7)), sim_or32(61, _t))), _t);
    var _r = sim_xor32(_t, sim_shr(_t, 14));
    // /65536 twice, never /4294967296: HTML5 emits the big literal as an
    // int64 Long (even via power(2,32) constant-folding) and Long division
    // is INTEGER division -> always 0. Power-of-two chain is bit-exact.
    return (_r / 65536) / 65536;
}

/// Per-shot seed from (input seq, synced per-room salt).
function sim_shot_seed(_seq, _salt) {
    return sim_splitmix32(sim_xor32(sim_u32(_seq), sim_imul(_salt, 2246822507)));  // 0x85EBCA6B
}

/// spread.ts — the deterministic 6-pellet fan.
function sim_spread_angles(_base, _seq, _salt) {
    var _rng = sim_mulberry32_create(sim_shot_seed(_seq, _salt));
    var _out = array_create(SIM_PELLETS);
    for (var _i = 0; _i < SIM_PELLETS; _i++) {
        _out[_i] = _base + (sim_mulberry32_next(_rng) - 0.5) * SIM_SPREAD_RAD;
    }
    return _out;
}

// ── determinism canaries ───────────────────────────────────────────────
// Pinned against the TypeScript originals (native-app/sim.h sim_selfcheck).
// The wide-seed case is the >2^31 tripwire that silently broke other ports.

/// Returns "" on success, else a description of the first failing canary.
function sim_selfcheck() {
    if (sim_splitmix32(1) != 1580013426) return "splitmix32(1)";
    if (sim_shot_seed(7, 12345) != 1994071465) return "shot_seed(7,12345)";
    if (sim_shot_seed(50, 3004265928) != 2712337003) return "shot_seed wide-seed";

    // integer-exact: sub-ulp float tolerances false-fail when a compiler
    // parses the decimal literals to a neighboring f64 (the HTML5 toolchain)
    var _rng = sim_mulberry32_create(0xB07B07);
    var _expect_raw = [41909008, 944980053, 1966572806];
    for (var _i = 0; _i < 3; _i++) {
        if (round(sim_mulberry32_next(_rng) * 65536 * 65536) != _expect_raw[_i]) return "mulberry32(0xB07B07)[" + string(_i) + "]";
    }

    var _fan = sim_spread_angles(0.5, 7, 12345);
    if (abs(_fan[0] - 0.599485442587174510720) > 0.000000000000001) return "spread_angles[0]";
    if (abs(_fan[1] - 0.672593814930878552971) > 0.000000000000001) return "spread_angles[1]";

    // hitscan: ray from (0,30) along +x at a circle (50,30) r=1.8 -> t = 48.2
    // (also keeps sim_ray_circle referenced: GameMaker's HTML5 emitter writes
    // a SYNTACTICALLY INVALID stub `function name{}` for unused functions)
    if (abs(sim_ray_circle(0, 30, 1, 0, 50, 30, 1.8, 100) - 48.2) > 0.000000000001) return "ray_circle";

    // movement: one step of diagonal accel from rest at fixed dt
    var _e = { x: 50, y: 30, vx: 0, vy: 0 };
    sim_step_entity(_e, 1, 1, 0.05);
    var _v = SIM_SQRT1_2 * SIM_PLAYER_ACCEL * 0.05;
    if (abs(_e.vx - _v) > 0.000000000001 || abs(_e.x - (50 + _v * 0.05)) > 0.000000000001) return "step_entity";

    // the mirror-shaped body every lab step uses (also keeps it referenced +
    // exercises its static scratch + struct-literal methods on this runner)
    var _fake = {
        s: { x: 50, y: 30, vx: 0, vy: 0 },
        get: function(_f) { return variable_struct_get(s, _f); },
        set: function(_f, _v2) { variable_struct_set(s, _f, _v2); },
    };
    sim_step_mirror(_fake, 1, 1, 0.05);
    if (abs(_fake.s.vx - _e.vx) > 0 || abs(_fake.s.x - _e.x) > 0) return "step_mirror";

    return "";
}
