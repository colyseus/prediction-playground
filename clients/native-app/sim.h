/*
 * The playground's shared simulation, ported to C.
 *
 * Bit-exact f64 transliteration of src/shared/*.ts: same op order, same
 * constants. Determinism across the wire is the whole contract — the server
 * runs the TypeScript original, this file runs on the client, and steady-state
 * reconcile corrections must be exactly zero.
 *
 * Header-only (static inline): the app is a single translation unit.
 */
#ifndef PLAYGROUND_SIM_H
#define PLAYGROUND_SIM_H

#include <math.h>
#include <stdio.h>

/* ------------------------------------------------ shared/constants.ts */

#define TICK_HZ 20
#define ARENA_W 100.0
#define ARENA_H 60.0
#define PLAYER_HALF 1.6
#define PLAYER_ACCEL 220.0
#define PLAYER_MAX_SPEED 34.0
#define PLAYER_FRICTION_K 0.72
#define BOT_RADIUS 1.8
#define REMOTE_INTERP_MS 100.0
#define TELEPORT_SNAP_DIST 8.0

/* Math.SQRT1_2 — the exact f64 the JS sim multiplies by. */
#define SQRT1_2 0.70710678118654752440

typedef struct { double x, y, vx, vy; } entity_state_t;

/*
 * shared/movement.ts stepEntity — the single deterministic movement step, run
 * identically by the server (once per received input) and by the reconciler
 * (predict + rollback replay). sqrt/mul/add only.
 */
static inline void step_entity(entity_state_t* e, double move_x, double move_y, double dt) {
    double ax = move_x, ay = move_y;
    if (ax != 0 && ay != 0) { ax *= SQRT1_2; ay *= SQRT1_2; }

    if (ax != 0 || ay != 0) {
        e->vx += ax * PLAYER_ACCEL * dt;
        e->vy += ay * PLAYER_ACCEL * dt;
    } else {
        e->vx *= PLAYER_FRICTION_K;
        e->vy *= PLAYER_FRICTION_K;
        if (e->vx > -0.05 && e->vx < 0.05) { e->vx = 0; }
        if (e->vy > -0.05 && e->vy < 0.05) { e->vy = 0; }
    }

    double sq = e->vx * e->vx + e->vy * e->vy;
    if (sq > PLAYER_MAX_SPEED * PLAYER_MAX_SPEED) {
        double s = PLAYER_MAX_SPEED / sqrt(sq);
        e->vx *= s;
        e->vy *= s;
    }

    e->x += e->vx * dt;
    e->y += e->vy * dt;

    double min_x = PLAYER_HALF, max_x = ARENA_W - PLAYER_HALF;
    double min_y = PLAYER_HALF, max_y = ARENA_H - PLAYER_HALF;
    if (e->x < min_x) { e->x = min_x; if (e->vx < 0) { e->vx = 0; } }
    else if (e->x > max_x) { e->x = max_x; if (e->vx > 0) { e->vx = 0; } }
    if (e->y < min_y) { e->y = min_y; if (e->vy < 0) { e->vy = 0; } }
    else if (e->y > max_y) { e->y = max_y; if (e->vy > 0) { e->vy = 0; } }
}

/* ---------------------------------------------------- startup canary */

/*
 * Cheap self-check that the port still reproduces the reference numbers (the
 * probes' encode-canary idea, applied to the sim). Returns the number of
 * FAILED checks; `--selfcheck` prints and exits on the count.
 *
 * Expected values come from running the TypeScript stepEntity with the same
 * inputs; they are pinned here so a constant typo can never ship silently.
 */
static inline int sim_selfcheck(int verbose) {
    int failed = 0;
    const double dt = 1.0 / TICK_HZ;

    /* 5 steps of pure-right acceleration from rest at the arena centre.
     * Reference: node src/shared/movement.ts -> x 56.7000000000000028422,
     * vx saturated at PLAYER_MAX_SPEED on step 4. */
    entity_state_t e = { 50.0, 30.0, 0.0, 0.0 };
    for (int i = 0; i < 5; i++) { step_entity(&e, 1, 0, dt); }
    int ok_v = e.vx == PLAYER_MAX_SPEED && e.vy == 0.0;
    int ok_x = fabs(e.x - 56.7) < 1e-12;
    if (verbose) {
        printf("  sim: 5x right  -> x=%.15f vx=%.15f (want 56.7 / 34)\n", e.x, e.vx);
    }
    if (!ok_v || !ok_x) { failed++; }

    /* Diagonal: the SQRT1_2 constant must match Math.SQRT1_2 exactly.
     * Reference: vx = vy = 7.77817459305202341113. */
    entity_state_t d = { 50.0, 30.0, 0.0, 0.0 };
    step_entity(&d, 1, 1, dt);
    int ok_diag = d.vx == d.vy && fabs(d.vx - 7.77817459305202341113) < 1e-15;
    if (verbose) { printf("  sim: diagonal  -> vx=%.15f vy=%.15f\n", d.vx, d.vy); }
    if (!ok_diag) { failed++; }

    /* Wall clamp kills the outward velocity component. */
    entity_state_t w = { PLAYER_HALF + 0.1, 30.0, -30.0, 0.0 };
    step_entity(&w, 0, 0, dt);
    int ok_wall = fabs(w.x - PLAYER_HALF) < 1e-12 && w.vx == 0.0;
    if (verbose) { printf("  sim: wall      -> x=%.15f vx=%.15f\n", w.x, w.vx); }
    if (!ok_wall) { failed++; }

    /* Friction deadzone snaps to a hard zero (no denormal drift). */
    entity_state_t f = { 50.0, 30.0, 0.06, 0.0 };
    step_entity(&f, 0, 0, dt);
    int ok_fric = f.vx == 0.0;
    if (verbose) { printf("  sim: friction  -> vx=%.15f (want exactly 0)\n", f.vx); }
    if (!ok_fric) { failed++; }

    return failed;
}

#endif /* PLAYGROUND_SIM_H */
