/*
 * Native-SDK validation client for the Colyseus Prediction Playground.
 *
 * Headless probe against the demo server (pnpm dev, port 5173) exercising the
 * predict layer end-to-end against live rooms — the C twin of
 * scripts/probe-*.mjs:
 *
 *   A  lab-move        join, clock sync, reconciler determinism (the shared
 *                      stepEntity ported bit-exact), impulse -> correction ->
 *                      recovery
 *   B  lab-bots        passive smoothing (lerp) over a server-driven bot
 *   C  lab-goal        sim-born optimistic event (colyseus_step_predict) ->
 *                      server "goal" broadcast -> confirm
 *   D  lab-projectile  predicted spawn -> authoritative correlation (stable
 *                      id, measured input lead), foreign turret entries
 *
 * Build: registered as `predict_probe` in native-sdk/build.zig (present only
 * when this repo sits next to native-sdk). Run:
 *   cd native-sdk && zig build && ./zig-out/bin/predict_probe [port]
 */
#include <math.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "colyseus/client.h"
#include "colyseus/schema.h"
#include "colyseus/room.h"
#include "colyseus/room_clock.h"
#include "colyseus/input_handle.h"
#include "colyseus/schema/callbacks.h"
#include "colyseus/schema/collections.h"
#include "colyseus/schema/input_encoder.h"
#include "colyseus/predict/reconciler.h"
#include "colyseus/predict/predict.h"
#include "colyseus/predict/events.h"
#include "colyseus/predict/spawns.h"

#include "schema/move_state.h"
#include "schema/move_input.h"
#include "schema/bots_state.h"
#include "schema/goal_state.h"
#include "schema/projectile_state.h"
#include "schema/range_input.h"

/* ---------------------------------------------------------------- harness */

static int checks_failed = 0;

static void check(const char* name, bool ok, const char* fmt, ...) {
    printf("%s %s", ok ? "OK  " : "FAIL", name);
    if (fmt != NULL) {
        va_list args;
        printf(" — ");
        va_start(args, fmt);
        vprintf(fmt, args);
        va_end(args);
    }
    printf("\n");
    if (!ok) { checks_failed++; }
}

static void sleep_ms(int ms) { usleep(ms * 1000); }

/* one frame of the render loop (~60fps) */
#define FRAME_MS 16

/* -------------------------------------------------- shared sim (ported) */

/* shared/constants.ts */
#define TICK_HZ 20
#define ARENA_W 100.0
#define ARENA_H 60.0
#define PLAYER_HALF 1.6
#define PLAYER_ACCEL 220.0
#define PLAYER_MAX_SPEED 34.0
#define PLAYER_FRICTION_K 0.72
/* Math.SQRT1_2 — the exact f64 the JS sim multiplies by */
#define SQRT1_2 0.70710678118654752440

/* shared/goal.ts */
#define GOAL_ZONE_X (ARENA_W - 8.0)
#define GOAL_ZONE_Y (ARENA_H / 2.0 - 9.0)
#define GOAL_ZONE_H 18.0
#define SCORE_COOLDOWN_TICKS 50

/* shared/projectile.ts */
#define PROJECTILE_SPEED 34.0

typedef struct { double x, y, vx, vy; } entity_state_t;

/*
 * shared/movement.ts stepEntity — the deterministic step the server runs per
 * received input. Bit-exact f64 port: same op order, same constants.
 */
static void step_entity(entity_state_t* e, double move_x, double move_y, double dt) {
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

/* ------------------------------------------------------------- join glue */

typedef struct {
    colyseus_room_t* room;
    bool joined;
    bool errored;
    const colyseus_schema_vtable_t* state_vtable;
} join_ctx_t;

static void on_room_error(int code, const char* message, void* userdata) {
    join_ctx_t* ctx = (join_ctx_t*)userdata;
    fprintf(stderr, "room error %d: %s\n", code, message ? message : "");
    ctx->errored = true;
}

static void on_joined(void* userdata) {
    ((join_ctx_t*)userdata)->joined = true;
}

static void on_room_success(colyseus_room_t* room, void* userdata) {
    join_ctx_t* ctx = (join_ctx_t*)userdata;
    colyseus_room_set_state_type(room, ctx->state_vtable);
    colyseus_room_on_join(room, on_joined, ctx);
    colyseus_room_on_error(room, on_room_error, ctx);
    ctx->room = room;
}

static void on_join_error(int code, const char* message, void* userdata) {
    join_ctx_t* ctx = (join_ctx_t*)userdata;
    fprintf(stderr, "join error %d: %s\n", code, message ? message : "");
    ctx->errored = true;
}

/* Join a lab room and wait for the first full state. NULL on failure. */
static colyseus_room_t* join_lab(colyseus_client_t* client, const char* name,
    const colyseus_schema_vtable_t* state_vtable) {
    join_ctx_t ctx = { 0 };
    ctx.state_vtable = state_vtable;
    colyseus_client_join_or_create(client, name, NULL, on_room_success, on_join_error, &ctx);
    for (int i = 0; i < 100 && !ctx.joined && !ctx.errored; i++) { sleep_ms(50); }
    if (!ctx.joined || ctx.errored) { return NULL; }
    for (int i = 0; i < 100 && colyseus_room_get_state(ctx.room) == NULL; i++) { sleep_ms(50); }
    return ctx.room;
}

static void leave_room(colyseus_room_t* room) {
    colyseus_room_leave(room, true);
    sleep_ms(300);
    colyseus_room_free(room);
}

static double clock_now(colyseus_room_t* room) {
    return colyseus_room_clock_now(colyseus_room_get_clock(room));
}

/* ------------------------------------------------- A. lab-move scenario */


static void recon_step(const colyseus_step_ctx_t* ctx, colyseus_schema_t* state,
    const colyseus_schema_t* command, void* userdata) {
    (void)userdata;
    player_t* p = (player_t*)state;
    const move_input_t* inp = (const move_input_t*)command;
    entity_state_t e = { p->x, p->y, p->vx, p->vy };
    step_entity(&e, (double)inp->moveX, (double)inp->moveY, ctx->dt);
    p->x = e.x; p->y = e.y; p->vx = e.vx; p->vy = e.vy;
}

static void scenario_move(colyseus_client_t* client) {
    printf("\n=== A. lab-move: join, clock, reconcile, impulse ===\n");
    colyseus_room_t* room = join_lab(client, "lab-move", &move_state_vtable);
    check("join lab-move", room != NULL, NULL);
    if (room == NULL) { return; }

    /* one patch interval so the first TIMED sample lands */
    sleep_ms(300);

    move_state_t* state = (move_state_t*)colyseus_room_get_state(room);
    const char* sid = colyseus_room_get_session_id(room);
    player_t* me = (player_t*)colyseus_map_schema_get(state->players, sid);
    check("own player spawned", me != NULL, "session %s", sid);
    if (me == NULL) { leave_room(room); return; }
    printf("     spawn at %.1f %.1f hue %d\n", me->x, me->y, me->hue);

    colyseus_room_clock_t* clock = colyseus_room_get_clock(room);
    check("clock synced (TIMED prefix flowing)",
        colyseus_room_clock_last_server_time(clock) > 0,
        "lastServerTime=%.0f", colyseus_room_clock_last_server_time(clock));
    check("tick rate advertised", room->input_tick_rate == TICK_HZ,
        "tickRate=%d", room->input_tick_rate);

    colyseus_input_handle_t* input = colyseus_room_input(room, &move_input_vtable, NULL);
    check("input handle created", input != NULL, NULL);
    if (input == NULL) { leave_room(room); return; }
    move_input_t* cmd = (move_input_t*)colyseus_input_handle_data(input);

    const char* fields[] = { "x", "y", "vx", "vy" };
    colyseus_reconciler_options_t opts = { 0 };
    opts.smooth_ms = 65;
    opts.fields = fields;
    opts.field_count = 4;
    colyseus_reconciler_t* recon = colyseus_reconciler_create(
        (colyseus_schema_t*)me, &player_vtable, input, clock, recon_step, &opts);
    check("reconciler created (step 50ms adopted)", recon != NULL
        && colyseus_reconciler_step_ms(recon) == 50.0, NULL);
    if (recon == NULL) { leave_room(room); return; }
    player_t* predicted = (player_t*)colyseus_reconciler_state(recon);

    double start_x = predicted->x;
    double early_x = start_x;
    double max_corr_steady = 0;
    int max_pending = 0;

    /* drive left for 2s at the fixed step, ticking at ~60fps */
    double send_acc = 0;
    double last = clock_now(room);
    for (int frame = 0; frame < 125; frame++) {
        sleep_ms(FRAME_MS);
        double now = clock_now(room);
        send_acc += now - last;
        last = now;
        while (send_acc >= 50.0) {
            send_acc -= 50.0;
            cmd->moveX = -1;
            cmd->moveY = 0;
            colyseus_input_handle_send(input);
        }
        colyseus_reconciler_tick(recon, now);
        if (frame % 25 == 0) {
            printf("     t=%4dms truth %6.2f,%6.2f v %6.2f,%6.2f | pred %6.2f,%6.2f v %6.2f,%6.2f | corr=%.3f\n",
                frame * FRAME_MS, me->x, me->y, me->vx, me->vy,
                predicted->x, predicted->y, predicted->vx, predicted->vy,
                colyseus_reconciler_last_correction_mag(recon));
        }
        if (frame == 9) { early_x = predicted->x; }        /* ~150ms in */
        if (frame > 30) {                                  /* past warmup */
            double mag = colyseus_reconciler_last_correction_mag(recon);
            if (mag > max_corr_steady) { max_corr_steady = mag; }
            int pending = colyseus_reconciler_pending_count(recon);
            if (pending > max_pending) { max_pending = pending; }
        }
    }

    check("predicted pose moves before RTT elapses", start_x - early_x > 0.3,
        "dx=%.2f in ~150ms", start_x - early_x);
    check("steady-state corrections ~0 (shared step deterministic)",
        max_corr_steady < 1e-3, "max |correction| = %.2e", max_corr_steady);
    double rtt = colyseus_room_clock_smoothed_rtt(clock);
    double expected_pending = rtt * TICK_HZ / 1000.0;
    check("pending tracks RTT", max_pending <= (int)(expected_pending + 3),
        "max pending=%d rtt=%.0fms", max_pending, rtt);
    const colyseus_drift_t* drift = colyseus_reconciler_drift(recon);
    check("drift matched while driving",
        colyseus_drift_classify(drift, 0) == COLYSEUS_DRIFT_MATCHED,
        "ema=%.2e", drift->ema);

    /* server-side shove the client can't see coming — MUST mispredict */
    int seq_before = colyseus_reconciler_reconcile_seq(recon);
    (void)seq_before;
    colyseus_message_t* impulse_msg = colyseus_message_map_create();
    colyseus_room_send(room, "impulse", impulse_msg);
    colyseus_message_free(impulse_msg);
    double impulse_corr = 0;
    send_acc = 0;
    last = clock_now(room);
    for (int frame = 0; frame < 220; frame++) {
        sleep_ms(FRAME_MS);
        double now = clock_now(room);
        send_acc += now - last;
        last = now;
        while (send_acc >= 50.0) {
            send_acc -= 50.0;
            cmd->moveX = 0;
            cmd->moveY = 0;
            colyseus_input_handle_send(input);   /* keep acks flowing */
        }
        colyseus_reconciler_tick(recon, now);
        double mag = colyseus_reconciler_last_correction_mag(recon);
        if (mag > impulse_corr) { impulse_corr = mag; }
    }
    check("impulse produces a visible correction", impulse_corr > 0.05,
        "max |correction| = %.3f", impulse_corr);
    check("drift recovers after impulse (not diverging)",
        colyseus_drift_classify(drift, 0.01) != COLYSEUS_DRIFT_DIVERGING,
        "ema=%.4f peak=%.4f", drift->ema, drift->peak);

    /* value() sanity: interpolated render read is finite and near the state */
    double vx_read = colyseus_reconciler_value(recon, "x");
    check("value(x) render read sane", isfinite(vx_read)
        && fabs(vx_read - predicted->x) < 5.0, "value=%.2f state=%.2f", vx_read, predicted->x);

    colyseus_reconciler_free(recon);
    leave_room(room);
}

/* ------------------------------------------------- B. lab-bots scenario */

static void scenario_bots(colyseus_client_t* client) {
    printf("\n=== B. lab-bots: passive smoothing over a server-driven bot ===\n");
    colyseus_room_t* room = join_lab(client, "lab-bots", &bots_state_vtable);
    check("join lab-bots", room != NULL, NULL);
    if (room == NULL) { return; }
    sleep_ms(300);

    bots_state_t* state = (bots_state_t*)colyseus_room_get_state(room);
    bot_t* bot = (bot_t*)colyseus_map_schema_get(state->bots, "bot1");
    check("bot1 present", bot != NULL, NULL);
    if (bot == NULL) { leave_room(room); return; }

    colyseus_callbacks_t* callbacks =
        colyseus_callbacks_create(room->serializer->decoder);
    colyseus_predict_t* predict =
        colyseus_predict_create(callbacks, colyseus_room_get_clock(room));

    colyseus_predict_field_options_t lerp = { 0 };
    lerp.mode = COLYSEUS_PREDICT_LERP;
    check("track bot1.x/y (lerp)",
        colyseus_predict_attach(predict, (colyseus_schema_t*)bot,
            (const colyseus_attach_field_t[]){ { "x", &lerp }, { "y", &lerp } }, 2) == 0, NULL);

    /* watch ~1.6s of patrol motion (speed 18 u/s) */
    double first = NAN, last_v = NAN, min_v = 1e9, max_v = -1e9;
    double max_frame_jump = 0, max_raw_jump = 0, prev_raw = bot->x;
    for (int frame = 0; frame < 100; frame++) {
        sleep_ms(FRAME_MS);
        double now = clock_now(room);
        colyseus_predict_tick(predict, now);
        double v = colyseus_predict_value(predict, (colyseus_schema_t*)bot, "x");
        if (isnan(first)) { first = v; }
        if (!isnan(last_v)) {
            double jump = fabs(v - last_v);
            if (jump > max_frame_jump) { max_frame_jump = jump; }
        }
        double raw_jump = fabs(bot->x - prev_raw);
        prev_raw = bot->x;
        if (raw_jump > max_raw_jump) { max_raw_jump = raw_jump; }
        last_v = v;
        if (v < min_v) { min_v = v; }
        if (v > max_v) { max_v = v; }
    }
    check("lerped value follows the bot", fabs(last_v - first) > 5.0,
        "moved %.1f units over 1.6s", fabs(last_v - first));
    check("lerp output smoother than snapshots", max_frame_jump < max_raw_jump,
        "max frame jump %.2f < max snapshot jump %.2f", max_frame_jump, max_raw_jump);
    check("lerped value stays in the patrol band",
        min_v > 22.0 - 2.0 && max_v < 78.0 + 2.0,
        "range [%.1f, %.1f]", min_v, max_v);

    colyseus_predict_free(predict);
    colyseus_callbacks_free(callbacks);
    leave_room(room);
}

/* ------------------------------------------------- C. lab-goal scenario */

typedef struct {
    colyseus_event_channel_t* goals;
    int predicted;
    int confirmed;
    int rejected;
    char my_sid[64];
    bool goal_msg_for_me;
} goal_ctx_t;

static void goal_on_predict(void* payload, void* userdata) {
    (void)payload;
    ((goal_ctx_t*)userdata)->predicted++;
}
static void goal_on_confirm(void* payload, void* userdata) {
    (void)payload;
    ((goal_ctx_t*)userdata)->confirmed++;
}
static void goal_on_reject(void* payload, void* userdata) {
    (void)payload;
    ((goal_ctx_t*)userdata)->rejected++;
}

/* stepEntity + the shared score gate, with the sim-born optimistic event */
static void goal_step(const colyseus_step_ctx_t* ctx, colyseus_schema_t* state,
    const colyseus_schema_t* command, void* userdata) {
    goal_ctx_t* g = (goal_ctx_t*)userdata;
    goal_player_t* p = (goal_player_t*)state;
    const move_input_t* inp = (const move_input_t*)command;
    entity_state_t e = { p->x, p->y, p->vx, p->vy };
    step_entity(&e, (double)inp->moveX, (double)inp->moveY, ctx->dt);
    p->x = e.x; p->y = e.y; p->vx = e.vx; p->vy = e.vy;

    /* shared/goal.ts stepScoreGate */
    if (p->scoreTicks > 0) {
        p->scoreTicks--;
    } else if (p->x >= GOAL_ZONE_X && p->y >= GOAL_ZONE_Y
        && p->y <= GOAL_ZONE_Y + GOAL_ZONE_H) {
        p->scoreTicks = SCORE_COOLDOWN_TICKS;
        colyseus_step_predict(ctx, g->goals, "goal", NULL);  /* live-only */
    }
}

static void on_goal_message(colyseus_message_reader_t* reader, void* userdata) {
    goal_ctx_t* g = (goal_ctx_t*)userdata;
    const char* sid = NULL;
    size_t len = 0;
    if (colyseus_message_reader_map_get_str(reader, "sid", &sid, &len)
        && strncmp(sid, g->my_sid, len) == 0 && g->my_sid[len] == '\0') {
        g->goal_msg_for_me = true;
        colyseus_event_channel_confirm(g->goals, NULL);
    }
}

static void scenario_goal(colyseus_client_t* client) {
    printf("\n=== C. lab-goal: sim-born optimistic event -> server confirm ===\n");
    colyseus_room_t* room = join_lab(client, "lab-goal", &goal_state_vtable);
    check("join lab-goal", room != NULL, NULL);
    if (room == NULL) { return; }
    sleep_ms(300);

    goal_state_t* state = (goal_state_t*)colyseus_room_get_state(room);
    const char* sid = colyseus_room_get_session_id(room);
    goal_player_t* me = (goal_player_t*)colyseus_map_schema_get(state->players, sid);
    check("own player spawned", me != NULL, NULL);
    if (me == NULL) { leave_room(room); return; }

    goal_ctx_t gctx = { 0 };
    snprintf(gctx.my_sid, sizeof(gctx.my_sid), "%s", sid);

    colyseus_event_channel_options_t ch_opts = { 0 };
    ch_opts.on_predict = goal_on_predict;
    ch_opts.on_confirm = goal_on_confirm;
    ch_opts.on_reject = goal_on_reject;
    ch_opts.userdata = &gctx;
    gctx.goals = colyseus_event_channel_create(&ch_opts,
        colyseus_room_get_clock(room));

    colyseus_room_on_message(room, "goal", on_goal_message, &gctx);

    colyseus_input_handle_t* input = colyseus_room_input(room, &move_input_vtable, NULL);
    move_input_t* cmd = (move_input_t*)colyseus_input_handle_data(input);

    const char* fields[] = { "x", "y", "vx", "vy", "scoreTicks" };
    colyseus_reconciler_options_t opts = { 0 };
    opts.smooth_ms = 65;
    opts.fields = fields;
    opts.field_count = 5;
    opts.userdata = &gctx;
    colyseus_reconciler_t* recon = colyseus_reconciler_create(
        (colyseus_schema_t*)me, &goal_player_vtable, input,
        colyseus_room_get_clock(room), goal_step, &opts);
    check("reconciler created (scoreTicks reconciled)", recon != NULL, NULL);
    if (recon == NULL) { leave_room(room); return; }
    goal_player_t* predicted = (goal_player_t*)colyseus_reconciler_state(recon);

    /* drive right into the goal zone (spawn x~25 -> zone at x>=92) */
    double max_corr = 0;
    double send_acc = 0;
    double last = clock_now(room);
    int frames = 0;
    for (; frames < 500; frames++) {   /* up to 8s */
        sleep_ms(FRAME_MS);
        double now = clock_now(room);
        send_acc += now - last;
        last = now;
        while (send_acc >= 50.0) {
            send_acc -= 50.0;
            cmd->moveX = 1;
            /* steer to the zone's vertical center */
            cmd->moveY = predicted->y < ARENA_H / 2 - 2 ? 1
                : predicted->y > ARENA_H / 2 + 2 ? -1 : 0;
            colyseus_input_handle_send(input);
        }
        colyseus_reconciler_tick(recon, now);
        colyseus_event_channel_prune(gctx.goals);
        double mag = colyseus_reconciler_last_correction_mag(recon);
        if (frames > 30 && mag > max_corr) { max_corr = mag; }
        if (gctx.confirmed > 0) { break; }
    }

    check("optimistic goal predicted (sim-born, live step)", gctx.predicted >= 1,
        "predicted=%d after %d frames", gctx.predicted, frames);
    check("server confirmed the goal", gctx.confirmed >= 1 && gctx.goal_msg_for_me,
        "confirmed=%d", gctx.confirmed);
    check("no rejections (denyRate 0)", gctx.rejected == 0, NULL);
    check("gate deterministic through reconciles (corrections ~0)",
        max_corr < 1e-3, "max |correction| = %.2e", max_corr);

    colyseus_reconciler_free(recon);
    colyseus_event_channel_free(gctx.goals);
    leave_room(room);
}

/* ------------------------------------------- D. lab-projectile scenario */

typedef struct {
    colyseus_spawns_t* store;
    char my_sid[64];
    int rejected;
    bool foreign_seen;
} spawn_ctx_t;

static bool projectile_owned(colyseus_schema_t* server, void* userdata) {
    spawn_ctx_t* s = (spawn_ctx_t*)userdata;
    projectile_t* p = (projectile_t*)server;
    return p->owner != NULL && strcmp(p->owner, s->my_sid) == 0;
}

static double projectile_spawn_time(colyseus_schema_t* server, void* userdata) {
    (void)userdata;
    return ((projectile_t*)server)->bornMs;
}

static void projectile_local_step(void* local, double dt, void* userdata) {
    (void)userdata;
    /* shared/projectile.ts stepProjectile over a plain double[4] local */
    entity_state_t* e = (entity_state_t*)local;
    e->x += e->vx * dt;
    e->y += e->vy * dt;
    if (e->x < 0) { e->x = 0; e->vx = fabs(e->vx); }
    else if (e->x > ARENA_W) { e->x = ARENA_W; e->vx = -fabs(e->vx); }
    if (e->y < 0) { e->y = 0; e->vy = fabs(e->vy); }
    else if (e->y > ARENA_H) { e->y = ARENA_H; e->vy = -fabs(e->vy); }
}

static void projectile_on_reject(void* local, int id, void* userdata) {
    (void)local; (void)id;
    ((spawn_ctx_t*)userdata)->rejected++;
}

static void spawns_on_add(void* value, void* key, void* userdata) {
    (void)key;
    spawn_ctx_t* s = (spawn_ctx_t*)userdata;
    colyseus_spawns_handle_add(s->store, (colyseus_schema_t*)value);
    projectile_t* pr = (projectile_t*)value;
    if (pr->owner != NULL && strcmp(pr->owner, "turret") == 0) {
        const colyseus_spawn_entry_t* fe =
            colyseus_spawns_entry_for(s->store, (colyseus_schema_t*)value);
        if (fe != NULL && fe->confirmed && fe->local == NULL) { s->foreign_seen = true; }
    }
}

static void spawns_on_remove(void* value, void* key, void* userdata) {
    (void)key;
    spawn_ctx_t* s = (spawn_ctx_t*)userdata;
    colyseus_spawns_handle_remove(s->store, (colyseus_schema_t*)value);
}

static void scenario_projectile(colyseus_client_t* client) {
    printf("\n=== D. lab-projectile: predicted spawn -> authoritative handoff ===\n");
    colyseus_room_t* room = join_lab(client, "lab-projectile", &projectile_state_vtable);
    check("join lab-projectile", room != NULL, NULL);
    if (room == NULL) { return; }
    sleep_ms(300);

    projectile_state_t* state = (projectile_state_t*)colyseus_room_get_state(room);
    const char* sid = colyseus_room_get_session_id(room);
    player_t* me = (player_t*)colyseus_map_schema_get(state->players, sid);
    check("own player spawned", me != NULL, NULL);
    if (me == NULL) { leave_room(room); return; }

    spawn_ctx_t sctx = { 0 };
    snprintf(sctx.my_sid, sizeof(sctx.my_sid), "%s", sid);

    colyseus_spawns_options_t sp_opts = { 0 };
    sp_opts.owned = projectile_owned;
    sp_opts.spawn_time = projectile_spawn_time;
    sp_opts.has_spawn_time = true;
    sp_opts.step = projectile_local_step;
    sp_opts.on_reject = projectile_on_reject;
    sp_opts.userdata = &sctx;
    sctx.store = colyseus_spawns_create(&sp_opts, colyseus_room_get_clock(room));

    colyseus_callbacks_t* callbacks =
        colyseus_callbacks_create(room->serializer->decoder);
    colyseus_callbacks_on_add(callbacks, state, "projectiles", spawns_on_add, &sctx, true);
    colyseus_callbacks_on_remove(callbacks, state, "projectiles", spawns_on_remove, &sctx);

    colyseus_input_handle_t* input = colyseus_room_input(room, &range_input_vtable, NULL);
    range_input_t* cmd = (range_input_t*)colyseus_input_handle_data(input);

    /* fire one shot at the turret (50, 8) and spawn the optimistic local */
    double aim_x = 50.0, aim_y = 8.0;
    double dx = aim_x - me->x, dy = aim_y - me->y;
    double len = sqrt(dx * dx + dy * dy);
    dx /= len; dy /= len;
    entity_state_t* local = malloc(sizeof(entity_state_t));
    local->x = me->x;
    local->y = me->y;
    local->vx = dx * PROJECTILE_SPEED;
    local->vy = dy * PROJECTILE_SPEED;

    cmd->aimX = (float)aim_x;
    cmd->aimY = (float)aim_y;
    cmd->fire = true;
    colyseus_input_handle_send(input);
    cmd->fire = false;
    int local_id = colyseus_spawns_spawn(sctx.store, local);

    const colyseus_spawn_entry_t* entry = colyseus_spawns_entry(sctx.store, local_id);
    check("optimistic local pending immediately",
        entry != NULL && !entry->confirmed && entry->local == local,
        "id=%d", local_id);

    /* pump until the authoritative projectile correlates (same id); the
     * turret fires every 1.6s, so the window also catches a foreign entry */
    bool confirmed = false;
    double lead_ms = 0;
    double send_acc = 0;
    double last = clock_now(room);
    for (int frame = 0; frame < 250 && !(confirmed && sctx.foreign_seen); frame++) {
        sleep_ms(FRAME_MS);
        double now = clock_now(room);
        send_acc += now - last;
        last = now;
        while (send_acc >= 50.0) {
            send_acc -= 50.0;
            colyseus_input_handle_send(input);  /* keep the input stream alive */
        }
        colyseus_spawns_tick(sctx.store, now);
        colyseus_spawns_prune(sctx.store);
        entry = colyseus_spawns_entry(sctx.store, local_id);
        if (entry != NULL && entry->confirmed && !confirmed) {
            confirmed = true;
            lead_ms = entry->lead_ms;
        }
    }

    check("authoritative projectile correlated IN PLACE (stable id)", confirmed,
        "id=%d", local_id);
    check("input lead measured", confirmed && lead_ms > 0 && lead_ms < 1000,
        "leadMs=%.0f", lead_ms);
    check("turret projectiles surface as foreign entries", sctx.foreign_seen, NULL);
    check("own prediction not TTL-rejected", sctx.rejected == 0,
        "rejected=%d", sctx.rejected);

    colyseus_spawns_free(sctx.store);
    colyseus_callbacks_free(callbacks);
    free(local);
    leave_room(room);
}

/* ------------------------------------------------------------------ main */

int main(int argc, char** argv) {
    /* macOS raises SIGPIPE on socket writes after peer close; the SDK's
     * transport does not set SO_NOSIGPIPE — a headless client must ignore it
     * (the zig test runner does this implicitly for the integration suite). */
    signal(SIGPIPE, SIG_IGN);
    setvbuf(stdout, NULL, _IONBF, 0);

    const char* port = argc > 1 ? argv[1] : "5173";

    /* wire canary: a negative int8 input must encode as [0x80|idx, 0xFF] */
    {
        move_input_t* probe_in = move_input_create();
        colyseus_input_encoder_t* enc = colyseus_input_encoder_create(
            (colyseus_schema_t*)probe_in, &move_input_vtable, false, 3);
        probe_in->moveX = -1;
        size_t len = 0;
        const uint8_t* bytes = colyseus_input_encoder_encode(enc, &len);
        printf("canary moveX=-1 frame:");
        for (size_t i = 0; i < len; i++) { printf(" %02x", bytes[i]); }
        printf("\n");
        check("negative int8 encodes as 0xFF", len == 2 && bytes[0] == 0x80 && bytes[1] == 0xFF, NULL);
        colyseus_input_encoder_free(enc);
        free(probe_in);
    }

    colyseus_schema_register_vtable(&player_vtable);
    colyseus_schema_register_vtable(&move_state_vtable);
    colyseus_schema_register_vtable(&move_input_vtable);
    colyseus_schema_register_vtable(&bot_vtable);
    colyseus_schema_register_vtable(&bots_state_vtable);
    colyseus_schema_register_vtable(&goal_player_vtable);
    colyseus_schema_register_vtable(&goal_state_vtable);
    colyseus_schema_register_vtable(&projectile_vtable);
    colyseus_schema_register_vtable(&projectile_state_vtable);
    colyseus_schema_register_vtable(&range_input_vtable);

    colyseus_settings_t* settings = colyseus_settings_create();
    colyseus_settings_set_address(settings, "127.0.0.1");
    colyseus_settings_set_port(settings, port);
    colyseus_settings_set_secure(settings, false);

    colyseus_client_t* client = colyseus_client_create(settings);
    printf("predict_probe -> ws://localhost:%s\n", port);

    scenario_move(client);
    scenario_bots(client);
    scenario_goal(client);
    scenario_projectile(client);

    colyseus_client_free(client);
    colyseus_settings_free(settings);

    printf("\n%s\n", checks_failed == 0 ? "PROBE OK" : "PROBE FAILED");
    return checks_failed == 0 ? 0 : 1;
}
