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
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

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

/* ------------------------------------------------------ shared/goal.ts */

/* The goal zone: a strip on the right edge of the arena. */
#define GOAL_ZONE_X (ARENA_W - 8.0)
#define GOAL_ZONE_Y (ARENA_H / 2.0 - 9.0)
#define GOAL_ZONE_W 8.0
#define GOAL_ZONE_H 18.0
/* Re-entry lockout (fixed steps) — reconciled tick state on both sides. */
#define SCORE_COOLDOWN_TICKS 50

/*
 * shared/goal.ts stepScoreGate. Pure function of predicted state, so it is
 * deterministic under rollback replay: returns true on the entry EDGE (the
 * step that crossed into the zone with the gate open). Whether the goal is
 * AWARDED stays server-only — the gate itself never mispredicts.
 */
static inline bool score_gate(double x, double y, int* score_ticks) {
    if (*score_ticks > 0) { (*score_ticks)--; return false; }
    if (x >= GOAL_ZONE_X && y >= GOAL_ZONE_Y && y <= GOAL_ZONE_Y + GOAL_ZONE_H) {
        *score_ticks = SCORE_COOLDOWN_TICKS;
        return true;
    }
    return false;
}

/* ------------------------------------------------ shared/projectile.ts */

#define PROJECTILE_SPEED 34.0
#define PROJECTILE_RADIUS 0.7

/* Constant-velocity flight with wall bounces. */
static inline void step_projectile(entity_state_t* p, double dt) {
    p->x += p->vx * dt;
    p->y += p->vy * dt;
    if (p->x < 0) { p->x = 0; p->vx = fabs(p->vx); }
    else if (p->x > ARENA_W) { p->x = ARENA_W; p->vx = -fabs(p->vx); }
    if (p->y < 0) { p->y = 0; p->vy = fabs(p->vy); }
    else if (p->y > ARENA_H) { p->y = ARENA_H; p->vy = -fabs(p->vy); }
}

/* ---------------------------------------------------- shared/movers.ts */

/** Teleporter warp period (ms, on the shared server-clock timeline). */
#define TELEPORT_PERIOD_MS 3000.0
/** Wander bots pick a new (server-secret) heading this often. */
#define WANDER_TURN_MS 900.0

/* Structural bot state — the reckon scratch is a full copy of the entity, so
 * non-attached fields (kind, minX, ...) are readable inside the step. */
typedef struct {
    double x, y, vx, vy;
    const char* kind;
    double min_x, max_x, base_y, phase_ms, speed, last_teleport;
} bot_sim_t;

/** Horizontal ping-pong between min_x and max_x at |vx| = speed. */
static inline void bot_patrol(bot_sim_t* b, double dt) {
    b->x += b->vx * dt;
    b->y = b->base_y;
    if (b->x < b->min_x) { b->x = b->min_x; b->vx = fabs(b->vx); }
    else if (b->x > b->max_x) { b->x = b->max_x; b->vx = -fabs(b->vx); }
}

/*
 * shared/movers.ts stepBot — run by the server each fixed tick AND by the
 * client's reckon mode to forward-simulate from the latest snapshot to the
 * present. `elapsed_ms` is the shared server-clock timeline, which makes
 * time-sampled motion (circle, teleport schedule) evaluable at ANY instant.
 *
 * "wander" is deliberately only PARTLY predictable: it integrates velocity,
 * but heading changes are a server-side secret. That error is the lesson.
 */
static inline void step_bot(bot_sim_t* b, double dt, double elapsed_ms) {
    if (b->kind && strcmp(b->kind, "circle") == 0) {
        double cx = (b->min_x + b->max_x) / 2;
        double rx = (b->max_x - b->min_x) / 2;
        double ry = fmin(12.0, ARENA_H / 2 - BOT_RADIUS - 2);
        double w = b->speed / rx;                    /* rad/s */
        double t = (elapsed_ms + b->phase_ms) / 1000.0;
        b->x = cx + rx * cos(w * t);
        b->y = b->base_y + ry * sin(w * t);
        b->vx = -rx * w * sin(w * t);
        b->vy = ry * w * cos(w * t);
        return;
    }
    if (b->kind && strcmp(b->kind, "teleport") == 0) {
        bot_patrol(b, dt);
        /* Predict the warp from the synced schedule: jump half the patrol span
         * (wrapping) every TELEPORT_PERIOD_MS — a constant, visible cut. */
        while (b->last_teleport > 0 && elapsed_ms - b->last_teleport >= TELEPORT_PERIOD_MS) {
            double span = b->max_x - b->min_x;
            b->x = b->min_x + fmod((b->x - b->min_x) + span / 2, span);
            b->last_teleport += TELEPORT_PERIOD_MS;
        }
        return;
    }
    if (b->kind && strcmp(b->kind, "wander") == 0) {
        b->x += b->vx * dt;
        b->y += b->vy * dt;
        double min = BOT_RADIUS, max_x = ARENA_W - BOT_RADIUS, max_y = ARENA_H - BOT_RADIUS;
        if (b->x < min) { b->x = min; b->vx = fabs(b->vx); }
        else if (b->x > max_x) { b->x = max_x; b->vx = -fabs(b->vx); }
        if (b->y < min) { b->y = min; b->vy = fabs(b->vy); }
        else if (b->y > max_y) { b->y = max_y; b->vy = -fabs(b->vy); }
        return;
    }
    bot_patrol(b, dt);
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

    /* Circle bot: the closed form must be evaluable at an arbitrary instant.
     * Reference: x 69.6422100736938887167, y 26.5519448209259039118. */
    bot_sim_t c = { 50, 18, 18, 0, "circle", 22, 78, 18, 0, 18, 0 };
    step_bot(&c, dt, 1234);
    int ok_circle = fabs(c.x - 69.6422100736938887167) < 1e-12
        && fabs(c.y - 26.5519448209259039118) < 1e-12;
    if (verbose) { printf("  sim: circle    -> x=%.15f y=%.15f\n", c.x, c.y); }
    if (!ok_circle) { failed++; }

    /* Teleporter: the warp schedule chains within one forward pass.
     * Reference: x 70.9000000000000056843, lastTeleport 7000. */
    bot_sim_t tp = { 70, 18, 18, 0, "teleport", 22, 78, 18, 0, 18, 1000 };
    step_bot(&tp, dt, 7100);
    int ok_tp = fabs(tp.x - 70.9) < 1e-12 && tp.last_teleport == 7000;
    if (verbose) {
        printf("  sim: teleport  -> x=%.15f lastTeleport=%.0f\n", tp.x, tp.last_teleport);
    }
    if (!ok_tp) { failed++; }

    /* Projectile wall bounce flips the sign, not the magnitude. */
    entity_state_t pj = { 99, 30, 34, 0 };
    step_projectile(&pj, dt);
    int ok_proj = pj.x == ARENA_W && pj.vx == -34.0;
    if (verbose) { printf("  sim: bounce    -> x=%.15f vx=%.15f\n", pj.x, pj.vx); }
    if (!ok_proj) { failed++; }

    /* Score gate: edge-triggered, then locked out for the cooldown. */
    int ticks = 0;
    bool first = score_gate(GOAL_ZONE_X + 1, ARENA_H / 2, &ticks);
    bool second = score_gate(GOAL_ZONE_X + 1, ARENA_H / 2, &ticks);
    int ok_gate = first && !second && ticks == SCORE_COOLDOWN_TICKS - 1;
    if (verbose) { printf("  sim: goal gate -> edge=%d repeat=%d ticks=%d\n", first, second, ticks); }
    if (!ok_gate) { failed++; }

    return failed;
}

#endif /* PLAYGROUND_SIM_H */
