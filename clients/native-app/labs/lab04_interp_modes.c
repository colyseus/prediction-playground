/*
 * Lab 04 — Remote Interpolation.
 *
 * The SAME bot rendered through four Predict instances, one per mode:
 *
 *   raw         the decoded snapshot verbatim: stutters at patch rate.
 *   lerp        render `delay` ms in the PAST, between two real samples.
 *               Never wrong, always late.
 *   damped      exponential chase of the newest sample: lags by construction
 *               and rounds corners.
 *   extrapolate project the trend FORWARD. Present-time, but overshoots
 *               whenever the bot turns.
 *
 * The strip along the bottom plots the bot's x over time: white dots are
 * received samples, the coloured traces are what each mode rendered.
 *
 * Port of src/client/labs/04-interp-modes/. The JS `attachAll` per-field
 * options map is sugar over `track` — the C port calls track per field.
 */

#define L04_TRACE_CAP 400
#define L04_STRIP_SPAN 2500.0
#define L04_SPEEDS 120

typedef struct {
    double t[L04_TRACE_CAP], v[L04_TRACE_CAP];
    int head, count;
} l04_series_t;

static void l04_series_push(l04_series_t* s, double t, double v) {
    s->t[s->head] = t;
    s->v[s->head] = v;
    s->head = (s->head + 1) % L04_TRACE_CAP;
    if (s->count < L04_TRACE_CAP) { s->count++; }
}

/* Coefficient of variation of rendered per-frame speed — the "limp" metric. */
typedef struct {
    double speeds[L04_SPEEDS];
    int head, count;
    double last_x, last_y;
    bool seeded;
} l04_smoothness_t;

static void l04_smooth_sample(l04_smoothness_t* s, double x, double y, double dt_ms) {
    if (s->seeded && dt_ms > 0) {
        double dx = x - s->last_x, dy = y - s->last_y;
        s->speeds[s->head] = sqrt(dx * dx + dy * dy) / dt_ms * 1000.0;
        s->head = (s->head + 1) % L04_SPEEDS;
        if (s->count < L04_SPEEDS) { s->count++; }
    }
    s->last_x = x;
    s->last_y = y;
    s->seeded = true;
}

/* NAN when there isn't enough motion for the ratio to mean anything. */
static double l04_smooth_cv(const l04_smoothness_t* s) {
    if (s->count < 20) { return NAN; }
    double mean = 0;
    for (int i = 0; i < s->count; i++) { mean += s->speeds[i]; }
    mean /= s->count;
    if (mean < 0.5) { return NAN; }
    double var = 0;
    for (int i = 0; i < s->count; i++) { var += (s->speeds[i] - mean) * (s->speeds[i] - mean); }
    return sqrt(var / s->count) / mean;
}

typedef struct {
    const char* name;
    Color color;
    colyseus_predict_t* predict;   /* NULL for "raw" — read the instance */
    bool visible;
    l04_series_t trace;
    l04_smoothness_t smooth;
} l04_mode_t;

static const char* const L04_PATTERNS[] = { "patrol", "circle", "wander" };

static struct {
    colyseus_room_t* room;
    colyseus_room_clock_t* clock;
    colyseus_callbacks_t* callbacks;
    colyseus_input_handle_t* input;
    move_input_t* cmd;
    bots_state_t* state;
    const char* sid;
    bot_t* bot;

    pacer_t pacer;
    l04_mode_t modes[4];
    l04_series_t samples;
    double last_raw_x, last_raw_y;
    int pattern;
} l04;

static double l04_value(const l04_mode_t* m, const char* field) {
    if (!m->predict) {
        return strcmp(field, "x") == 0 ? l04.bot->x : l04.bot->y;
    }
    return colyseus_predict_value(m->predict, (colyseus_schema_t*)l04.bot, field);
}

static bool lab04_attach(app_t* app, colyseus_room_t* room) {
    bots_state_t* state = (bots_state_t*)colyseus_room_get_state(room);
    if (!state || !state->bots || !state->players) { return false; }
    const char* sid = colyseus_room_get_session_id(room);
    bot_t* bot = (bot_t*)colyseus_map_schema_get(state->bots, "bot1");
    if (!bot || !colyseus_map_schema_get(state->players, sid)) { return false; }

    memset(&l04, 0, sizeof(l04));
    l04.room = room;
    l04.state = state;
    l04.sid = sid;
    l04.bot = bot;
    l04.clock = colyseus_room_get_clock(room);
    l04.last_raw_x = NAN;
    l04.last_raw_y = NAN;
    l04.callbacks = colyseus_room_callbacks(room);   /* room-owned, shared by the overlays */

    l04.input = colyseus_room_input(room, &move_input_vtable, NULL);
    if (!l04.input) { return false; }
    l04.cmd = (move_input_t*)colyseus_input_handle_data(l04.input);
    pacer_init(&l04.pacer, 1000.0 / TICK_HZ);

    struct { const char* name; Color color; colyseus_predict_mode_t mode;
             double delay, damping, max_extrapolate; } spec[4] = {
        { "raw",         COL_TEXT, COLYSEUS_PREDICT_RAW,         0,   0,  0 },
        { "lerp",        COL_BLUE, COLYSEUS_PREDICT_LERP,        100, 0,  0 },
        { "damped",      COL_GOOD, COLYSEUS_PREDICT_DAMPED,      0,   12, 0 },
        { "extrapolate", COL_WARN, COLYSEUS_PREDICT_EXTRAPOLATE, 0,   0,  250 },
    };
    for (int i = 0; i < 4; i++) {
        l04_mode_t* m = &l04.modes[i];
        m->name = spec[i].name;
        m->color = spec[i].color;
        m->visible = true;
        if (i == 0) { continue; }   /* raw needs no attach at all */
        m->predict = colyseus_predict_create(l04.callbacks, l04.clock);
        colyseus_predict_field_options_t opts = { 0 };
        opts.mode = spec[i].mode;
        opts.delay = spec[i].delay;
        opts.damping = spec[i].damping;
        opts.max_extrapolate = spec[i].max_extrapolate;
        colyseus_predict_track(m->predict, (colyseus_schema_t*)bot, "x", &opts);
        colyseus_predict_track(m->predict, (colyseus_schema_t*)bot, "y", &opts);
    }
    (void)app;
    return true;
}

static void l04_draw_player(const char* sid, void* value, void* userdata) {
    app_t* app = (app_t*)userdata;
    player_t* p = (player_t*)value;
    draw_square(&app->view, p->x, p->y, PLAYER_HALF,
        hue_color(p->hue, strcmp(sid, l04.sid) == 0 ? 0.9 : 0.4));
}

/* The buffer-timeline strip: received samples vs per-mode rendered traces. */
static void l04_draw_strip(app_t* app, double s_now, double last_patch) {
    const float h = 118, pad = 10;
    float x0 = app->stage_x + 24, x1 = app->stage_x + app->stage_w - 16;
    float y0 = app->stage_y + app->stage_h - h - 10, y1 = y0 + h;
    if (x1 - x0 < 200) { return; }

    DrawRectangleRounded((Rectangle){ x0, y0, x1 - x0, h }, 0.1f, 6, with_alpha(COL_PANEL, 0.9));
    DrawRectangleRoundedLines((Rectangle){ x0, y0, x1 - x0, h }, 0.1f, 6, COL_BORDER);

    double t_min = s_now - L04_STRIP_SPAN, t_max = s_now + 150;
    /* Value axis: bot x spans ~[20,80]; leave headroom for overshoot. */
    const double v_min = 12, v_max = 88;
    #define TX(t) (x0 + pad + (float)(((t) - t_min) / (t_max - t_min)) * (x1 - x0 - pad * 2))
    #define TY(v) (y1 - pad - (float)(((v) - v_min) / (v_max - v_min)) * (h - pad * 2 - 14))

    /* Time cursors: newest patch + server-now. */
    const double cursors[2] = { last_patch, s_now };
    const char* cursor_labels[2] = { "newest patch", "now" };
    for (int i = 0; i < 2; i++) {
        float x = TX(cursors[i]);
        if (x < x0 || x > x1) { continue; }
        draw_dashed_screen((Vector2){ x, y0 + 4 }, (Vector2){ x, y1 - 4 },
            with_alpha(COL_TEXT, 0.25), 1.0f, 3, 3);
        DrawText(cursor_labels[i], (int)(x - MeasureText(cursor_labels[i], 9) / 2), (int)y0 + 8, 9,
            with_alpha(COL_TEXT, 0.5));
    }

    /* Received samples (white dots). */
    int start = (l04.samples.head - l04.samples.count + L04_TRACE_CAP * 2) % L04_TRACE_CAP;
    for (int i = 0; i < l04.samples.count; i++) {
        int k = (start + i) % L04_TRACE_CAP;
        double t = l04.samples.t[k];
        if (t < t_min || t > t_max) { continue; }
        DrawCircleV((Vector2){ TX(t), TY(l04.samples.v[k]) }, 1.6f, with_alpha(COL_TEXT, 0.85));
    }

    /* Per-mode rendered traces. */
    for (int mi = 1; mi < 4; mi++) {
        l04_mode_t* m = &l04.modes[mi];
        if (!m->visible) { continue; }
        int s = (m->trace.head - m->trace.count + L04_TRACE_CAP * 2) % L04_TRACE_CAP;
        bool started = false;
        Vector2 prev = { 0, 0 };
        for (int i = 0; i < m->trace.count; i++) {
            int k = (s + i) % L04_TRACE_CAP;
            double t = m->trace.t[k];
            if (t < t_min || t > t_max) { started = false; continue; }
            Vector2 pt = { TX(t), TY(m->trace.v[k]) };
            if (started) { DrawLineEx(prev, pt, 1.2f, with_alpha(m->color, 0.9)); }
            prev = pt;
            started = true;
        }
    }
    #undef TX
    #undef TY
}

static void lab04_frame(app_t* app, double now, double dt) {
    /* --- controls ---------------------------------------------------- */
    if (app_key(KEY_B)) {
        l04.pattern = (l04.pattern + 1) % 3;
        colyseus_message_t* m = colyseus_message_map_create();
        colyseus_message_map_put_str(m, "kind", L04_PATTERNS[l04.pattern]);
        colyseus_room_send(l04.room, "pattern", m);
        colyseus_message_free(m);
    }
    for (int i = 0; i < 4; i++) {
        if (app_key(KEY_F1 + i)) { l04.modes[i].visible = !l04.modes[i].visible; }
    }

    int steps = pacer_steps(&l04.pacer, now);
    for (int i = 0; i < steps; i++) {
        l04.cmd->moveX = (int8_t)kb_move_x();
        l04.cmd->moveY = (int8_t)kb_move_y();
        colyseus_input_handle_send(l04.input);
    }
    for (int i = 1; i < 4; i++) { colyseus_predict_tick(l04.modes[i].predict, now); }

    double s_now = colyseus_room_clock_server_now(l04.clock);
    const world_view_t* v = &app->view;

    /* Record received samples (the decoded value changes once per patch). */
    if (l04.bot->x != l04.last_raw_x || l04.bot->y != l04.last_raw_y) {
        l04.last_raw_x = l04.bot->x;
        l04.last_raw_y = l04.bot->y;
        l04_series_push(&l04.samples, colyseus_room_clock_last_server_time(l04.clock), l04.bot->x);
    }

    colyseus_map_schema_foreach(l04.state->players, l04_draw_player, app);

    /* The bot, once per visible mode. */
    for (int i = 0; i < 4; i++) {
        l04_mode_t* m = &l04.modes[i];
        double x = l04_value(m, "x"), y = l04_value(m, "y");
        l04_series_push(&m->trace, s_now, x);
        l04_smooth_sample(&m->smooth, x, y, dt);
        if (!m->visible) { continue; }
        if (i == 0) { draw_circle_dashed_world(v, x, y, BOT_RADIUS, m->color); }
        else { draw_circle_outline_world(v, x, y, BOT_RADIUS, m->color); }
        /* Stagger the labels: the four modes sit within a bot radius of each
         * other most of the time, so a shared baseline is unreadable. */
        draw_label_world(v, x, y, m->name, m->color, 10, -vs(v, BOT_RADIUS) - 14 - i * 11);
    }

    l04_draw_strip(app, s_now, colyseus_room_clock_last_server_time(l04.clock));

    /* --- HUD --------------------------------------------------------- */
    hud_t* h = &app->hud;
    hud_section(h, "SMOOTHNESS (speed CV)");
    for (int i = 0; i < 4; i++) {
        double cv = l04_smooth_cv(&l04.modes[i].smooth);
        if (isnan(cv)) { hud_row(h, l04.modes[i].name, COL_TEXT_FAINT, "--"); }
        else {
            hud_row(h, l04.modes[i].name,
                cv < 0.15 ? COL_GOOD : cv < 0.5 ? COL_WARN : COL_BAD, "%.0f %%", cv * 100);
        }
    }
    hud_row(h, "samples buffered", COL_TEXT, "%d", l04.samples.count);

    hud_section(h, "CONTROLS");
    hud_key(h, "WASD", "drive your own square");
    hud_key(h, "B", TextFormat("bot pattern: %s", L04_PATTERNS[l04.pattern]));
    for (int i = 0; i < 4; i++) {
        hud_key(h, TextFormat("F%d", i + 1),
            TextFormat("%s %s", l04.modes[i].visible ? "hide" : "show", l04.modes[i].name));
    }
    hud_note(h, "Lower CV = smoother render. raw stutters at the patch rate; lerp is "
        "smooth but late; damped rounds corners; extrapolate is present-time but "
        "overshoots every turn - press B and watch it on circle.");
}

static void lab04_detach(app_t* app) {
    (void)app;
    for (int i = 1; i < 4; i++) {
        if (l04.modes[i].predict) { colyseus_predict_free(l04.modes[i].predict); }
    }
    memset(&l04, 0, sizeof(l04));
}

static void lab04_on_reconnect(app_t* app) {
    (void)app;
    pacer_reset(&l04.pacer);
    l04.bot = (bot_t*)colyseus_map_schema_get(l04.state->bots, "bot1");
}

static const lab_def_t LAB_04 = {
    .id = "04-interp-modes",
    .num = 4,
    .title = "Remote Interpolation",
    .blurb = "lerp / damped / extrapolate / raw, side by side.",
    .room_name = "lab-bots",
    .state_vtable = &bots_state_vtable,
    .attach = lab04_attach,
    .frame = lab04_frame,
    .detach = lab04_detach,
    .on_reconnect = lab04_on_reconnect,
};
