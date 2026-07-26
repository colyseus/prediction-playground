/*
 * Lab 01 — Feel the Lag.
 *
 * No prediction at all: send one input per fixed server tick, render the
 * player straight from decoded state. Every key press waits a full round trip,
 * so the `L` latency presets are what make this lab say anything.
 *
 * Port of src/client/labs/01-feel-the-lag/.
 */

#define L01_MAX_DAMPED 32

typedef enum { L01_RAW, L01_DAMPED } l01_strategy_t;

typedef struct {
    char sid[64];
    double x, y;
    bool used;
} l01_damped_t;

static struct {
    colyseus_room_t* room;
    colyseus_input_handle_t* input;
    move_input_t* cmd;
    move_state_t* state;
    const char* sid;

    pacer_t pacer;
    trail_t trail;

    l01_strategy_t strategy;
    double damping;

    l01_damped_t damped[L01_MAX_DAMPED];

    /* input->photon meter: arm on a key press while at rest, measure when the
     * RENDERED position first moves. */
    enum { L01_IDLE, L01_ARMED, L01_SHOWN } phase;
    double arm_t, arm_x, arm_y, measured;
} l01;

static l01_damped_t* l01_damped_for(const char* sid, double x, double y) {
    l01_damped_t* free_slot = NULL;
    for (int i = 0; i < L01_MAX_DAMPED; i++) {
        if (l01.damped[i].used && strcmp(l01.damped[i].sid, sid) == 0) { return &l01.damped[i]; }
        if (!l01.damped[i].used && !free_slot) { free_slot = &l01.damped[i]; }
    }
    if (!free_slot) { return NULL; }
    snprintf(free_slot->sid, sizeof(free_slot->sid), "%s", sid);
    free_slot->x = x;
    free_slot->y = y;
    free_slot->used = true;
    return free_slot;
}

static bool lab01_attach(app_t* app, colyseus_room_t* room) {
    move_state_t* state = (move_state_t*)colyseus_room_get_state(room);
    if (!state || !state->players) { return false; }
    const char* sid = colyseus_room_get_session_id(room);
    if (!colyseus_map_schema_get(state->players, sid)) { return false; }

    memset(&l01, 0, sizeof(l01));
    l01.room = room;
    l01.state = state;
    l01.sid = sid;
    l01.input = colyseus_room_input(room, &move_input_vtable, NULL);
    if (!l01.input) { return false; }
    l01.cmd = (move_input_t*)colyseus_input_handle_data(l01.input);
    pacer_init(&l01.pacer, 1000.0 / TICK_HZ);
    trail_init(&l01.trail, 150);
    l01.strategy = L01_RAW;
    l01.damping = 12;
    (void)app;
    return true;
}

typedef struct { app_t* app; double dt_s; } l01_draw_ctx_t;

static void l01_draw_player(const char* sid, void* value, void* userdata) {
    l01_draw_ctx_t* c = (l01_draw_ctx_t*)userdata;
    player_t* p = (player_t*)value;
    bool is_me = strcmp(sid, l01.sid) == 0;

    l01_damped_t* dm = l01_damped_for(sid, p->x, p->y);
    if (dm) {
        double k = 1 - exp(-l01.damping * c->dt_s);
        dm->x += (p->x - dm->x) * k;
        dm->y += (p->y - dm->y) * k;
    }
    double rx = (l01.strategy == L01_RAW || !dm) ? p->x : dm->x;
    double ry = (l01.strategy == L01_RAW || !dm) ? p->y : dm->y;

    const world_view_t* v = &c->app->view;
    if (is_me) {
        trail_push(&l01.trail, rx, ry);
        trail_draw(&l01.trail, v, hue_color(p->hue, 1), 1.5f, 0.45);
    }
    draw_square(v, rx, ry, PLAYER_HALF, hue_color(p->hue, is_me ? 1.0 : 0.45));
    if (is_me) {
        draw_square_outline(v, rx, ry, PLAYER_HALF, COL_TEXT, 1.0f);
        draw_label_world(v, rx, ry, "you", COL_TEXT, 11, -vs(v, PLAYER_HALF) - 15);
    }
}

/* Drop damped entries for players who left. */
static void l01_mark_seen(const char* sid, void* value, void* userdata) {
    (void)value;
    bool* seen = (bool*)userdata;
    for (int i = 0; i < L01_MAX_DAMPED; i++) {
        if (l01.damped[i].used && strcmp(l01.damped[i].sid, sid) == 0) { seen[i] = true; }
    }
}

static void lab01_frame(app_t* app, double now, double dt) {
    /* --- controls ---------------------------------------------------- */
    if (app_key(KEY_R)) {
        l01.strategy = l01.strategy == L01_RAW ? L01_DAMPED : L01_RAW;
        trail_clear(&l01.trail);
    }
    if (app_key(KEY_MINUS) && l01.damping > 4) { l01.damping -= 2; }
    if (app_key(KEY_EQUAL) && l01.damping < 30) { l01.damping += 2; }

    /* --- one input per fixed server tick (no reconciler here) --------- */
    int steps = pacer_steps(&l01.pacer, now);
    for (int i = 0; i < steps; i++) {
        l01.cmd->moveX = (int8_t)kb_move_x();
        l01.cmd->moveY = (int8_t)kb_move_y();
        colyseus_input_handle_send(l01.input);
    }

    /* --- render ------------------------------------------------------ */
    l01_draw_ctx_t ctx = { app, dt / 1000.0 };
    if (ctx.dt_s > 0.1) { ctx.dt_s = 0.1; }
    colyseus_map_schema_foreach(l01.state->players, l01_draw_player, &ctx);

    bool seen[L01_MAX_DAMPED] = { 0 };
    colyseus_map_schema_foreach(l01.state->players, l01_mark_seen, seen);
    for (int i = 0; i < L01_MAX_DAMPED; i++) { if (!seen[i]) { l01.damped[i].used = false; } }

    /* --- input -> motion meter --------------------------------------- */
    player_t* me = (player_t*)colyseus_map_schema_get(l01.state->players, l01.sid);
    if (me) {
        double speed = fabs(me->vx) + fabs(me->vy);
        if (l01.phase != L01_ARMED && kb_any_move() && speed < 0.01) {
            l01.phase = L01_ARMED;
            l01.arm_t = now; l01.arm_x = me->x; l01.arm_y = me->y;
        } else if (l01.phase == L01_ARMED) {
            if (fabs(me->x - l01.arm_x) > 0.03 || fabs(me->y - l01.arm_y) > 0.03) {
                l01.measured = now - l01.arm_t;
                l01.phase = L01_SHOWN;
            } else if (!kb_any_move() && now - l01.arm_t > 2000) {
                l01.phase = L01_IDLE;
            }
        } else if (l01.phase == L01_SHOWN && !kb_any_move() && speed < 0.01) {
            l01.phase = L01_IDLE;
        }
    }

    /* --- HUD --------------------------------------------------------- */
    hud_t* h = &app->hud;
    hud_section(h, "TELEMETRY");
    if (l01.measured > 0) {
        hud_row(h, "input -> motion", COL_BAD, "%.0f ms", l01.measured);
    } else {
        hud_row(h, "input -> motion", COL_TEXT_FAINT, "--");
    }
    hud_row(h, "meter state", l01.phase == L01_ARMED ? COL_WARN
        : l01.phase == L01_SHOWN ? COL_GOOD : COL_TEXT_DIM,
        l01.phase == L01_ARMED ? "armed..." : l01.phase == L01_SHOWN ? "measured" : "idle");
    hud_row(h, "render strategy", COL_TEXT, l01.strategy == L01_RAW ? "raw" : "damped");
    hud_row(h, "damping", COL_TEXT, "%.0f /s", l01.damping);

    hud_section(h, "CONTROLS");
    hud_key(h, "WASD", "drive");
    hud_key(h, "R", "raw <-> damped");
    hud_key(h, "- / =", "damping");
    hud_note(h, "raw = decoded server state verbatim. damped = smooth toward it "
        "(even laggier). predicted = Lab 03. Raise the latency preset with L and "
        "feel the difference.");
}

static void lab01_detach(app_t* app) { (void)app; memset(&l01, 0, sizeof(l01)); }

static void lab01_on_reconnect(app_t* app) {
    (void)app;
    pacer_reset(&l01.pacer);
    trail_clear(&l01.trail);
    l01.phase = L01_IDLE;
}

static const lab_def_t LAB_01 = {
    .id = "01-feel-the-lag",
    .num = 1,
    .title = "Feel the Lag",
    .blurb = "No prediction: every key press waits a full round trip.",
    .room_name = "lab-move",
    .state_vtable = &move_state_vtable,
    .attach = lab01_attach,
    .frame = lab01_frame,
    .detach = lab01_detach,
    .on_reconnect = lab01_on_reconnect,
};
