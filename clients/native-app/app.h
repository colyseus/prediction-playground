/*
 * Shell contract + the services every lab shares: keyboard axes, the
 * fixed-step send pacer, and the async join helper.
 *
 * Port of src/client/framework/lab.ts + input.ts + pacer.ts. The web shell
 * owns the room and hands it to the lab; so does this one — labs never join
 * and never leave.
 */
#ifndef PLAYGROUND_APP_H
#define PLAYGROUND_APP_H

#include <stdbool.h>
#include <string.h>

#include "raylib.h"
#include "colyseus/client.h"
#include "colyseus/room.h"
#include "colyseus/schema.h"
#include "colyseus/predict/predict.h"

#include "sim.h"

#include "hud.h"
#include "sim.h"
#include "view.h"

typedef struct app app_t;

struct app {
    colyseus_client_t* client;
    colyseus_settings_t* settings;

    /* The active lab's room — shell-owned; the lab only reads it. */
    colyseus_room_t* room;
    bool private_room;

    world_view_t view;   /* arena, fitted to the stage rect each frame */
    hud_t hud;           /* right panel, rewound each frame */
    /* The stage rect the arena was fitted into — for screen-space overlays. */
    float stage_x, stage_y, stage_w, stage_h;

    double now;          /* monotonic ms */
    double dt;           /* ms since the previous frame */
};

/**
 * A lab: mounted by the shell once its room's first state has decoded.
 * `attach` may return false to be retried next frame — the standard way to
 * wait for a state entry that the initial full sync hasn't produced yet
 * (the web build's `waitFor`).
 */
typedef struct {
    const char* id;
    int num;
    const char* title;
    const char* blurb;
    const char* room_name;
    const colyseus_schema_vtable_t* state_vtable;

    /* The lab paints its own background — the shell skips the shared arena. */
    bool own_arena;

    bool (*attach)(app_t* app, colyseus_room_t* room);
    void (*frame)(app_t* app, double now, double dt);
    void (*detach)(app_t* app);
    /*
     * After the SDK auto-reconnects a dropped transport. The reconnected room
     * counts inputs from ZERO — reconcilers MUST reset here, or every
     * reconcile replays the stale pre-drop backlog.
     */
    void (*on_reconnect)(app_t* app);
} lab_def_t;

/* Implemented by the shell (main.c): a lab may ask for a latency preset on
 * mount — lab 00 makes no point at all on a 1 ms localhost link. */
static void app_set_latency_preset(int index);

/* The field pair every lab smooths on entities it does not control. */
static const char* const SMOOTHED_XY[] = { "x", "y" };

/* Shared attach configs. The per-field array is what the reference expresses as
 * a map literal; C has no such literal, so the common homogeneous cases live
 * here rather than being retyped at every mount. */
static const colyseus_predict_field_options_t OPT_DAMPED = {
    .mode = COLYSEUS_PREDICT_DAMPED,
};
static const colyseus_predict_field_options_t OPT_LERP_REMOTE = {
    .mode = COLYSEUS_PREDICT_LERP, .delay = REMOTE_INTERP_MS,
};
static const colyseus_attach_field_t ATTACH_XY_DAMPED[] = {
    { "x", &OPT_DAMPED }, { "y", &OPT_DAMPED },
};
static const colyseus_attach_field_t ATTACH_XY_LERP_REMOTE[] = {
    { "x", &OPT_LERP_REMOTE }, { "y", &OPT_LERP_REMOTE },
};

/* ---------------------------------------------------------- keyboard */

/*
 * `--demo` drives the app with no hands on the keyboard (see main.c): it feeds
 * axes and one-shot key edges through these same accessors, so labs never learn
 * whether a human or the acceptance script is playing.
 */
static bool g_autopilot = false;
static int g_auto_x = 0, g_auto_y = 0;
static int g_synth_key = 0;

/** One-shot key edge, real or synthesized. Labs use this, never IsKeyPressed. */
static bool app_key(int key) {
    if (g_synth_key == key) { g_synth_key = 0; return true; }
    return IsKeyPressed(key);
}

/* WASD / arrows -> tri-state axes, exactly like framework/input.ts. */
static int kb_move_x(void) {
    if (g_autopilot) { return g_auto_x; }
    int l = IsKeyDown(KEY_A) || IsKeyDown(KEY_LEFT);
    int r = IsKeyDown(KEY_D) || IsKeyDown(KEY_RIGHT);
    return r != l ? (r ? 1 : -1) : 0;
}

static int kb_move_y(void) {
    if (g_autopilot) { return g_auto_y; }
    int u = IsKeyDown(KEY_W) || IsKeyDown(KEY_UP);
    int d = IsKeyDown(KEY_S) || IsKeyDown(KEY_DOWN);
    return d != u ? (d ? 1 : -1) : 0;
}

static bool kb_any_move(void) { return kb_move_x() != 0 || kb_move_y() != 0; }

/* ------------------------------------------------------------- pacer */

/*
 * Fixed-step accumulator for labs WITHOUT a reconciler: predict.tick() only
 * paces once a reconciler adopts the fixed step, but a prediction-free client
 * still has to send one input per server tick.
 */
typedef struct {
    double acc;
    double last;
    double step_ms;
    bool started;
} pacer_t;

static void pacer_init(pacer_t* p, double step_ms) {
    memset(p, 0, sizeof(*p));
    p->step_ms = step_ms;
}

static void pacer_reset(pacer_t* p) { p->acc = 0; p->started = false; }

static int pacer_steps(pacer_t* p, double now) {
    if (!p->started) { p->started = true; p->last = now; return 0; }
    p->acc += now - p->last;
    p->last = now;
    int n = (int)(p->acc / p->step_ms);
    if (n > 5) { n = 5; p->acc = 0; }        /* hitch: drop the backlog */
    else { p->acc -= n * p->step_ms; }
    return n;
}

/* -------------------------------------------------------- join glue */

typedef struct {
    colyseus_room_t* room;
    const colyseus_schema_vtable_t* state_vtable;
    volatile bool joined;
    volatile bool errored;
    char error[192];
} join_req_t;

static void join_on_room_error(int code, const char* message, void* userdata) {
    join_req_t* j = (join_req_t*)userdata;
    snprintf(j->error, sizeof(j->error), "room error %d: %s", code, message ? message : "");
    j->errored = true;
}

static void join_on_joined(void* userdata) { ((join_req_t*)userdata)->joined = true; }

static void join_on_success(colyseus_room_t* room, void* userdata) {
    join_req_t* j = (join_req_t*)userdata;
    colyseus_room_set_state_type(room, j->state_vtable);
    colyseus_room_on_join(room, join_on_joined, j);
    colyseus_room_on_error(room, join_on_room_error, j);
    j->room = room;
}

static void join_on_error(int code, const char* message, void* userdata) {
    join_req_t* j = (join_req_t*)userdata;
    snprintf(j->error, sizeof(j->error), "join error %d: %s", code, message ? message : "");
    j->errored = true;
}

#endif /* PLAYGROUND_APP_H */
