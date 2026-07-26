/*
 * Lab 05 — Dead Reckoning.
 *
 * Instead of drawing the PAST (lerp), forward-simulate the latest snapshot to
 * the PRESENT with the same step function the server runs. The reckon horizon
 * is exactly the snapshot age.
 *
 *   smoothing  glide applied to each snapshot REBASE (the small correction
 *              when a patch lands mid-glide).
 *   snap       rebases beyond this distance POP instead of gliding: a teleport
 *              is a cut, and smoothing across it looks like flying.
 *
 * Port of src/client/labs/05-dead-reckoning/.
 */

#define L05_MAX_DOTS 40

static const char* const L05_PATTERNS[] = { "teleport", "patrol", "wander", "circle" };

static struct {
    colyseus_room_t* room;
    colyseus_room_clock_t* clock;
    colyseus_callbacks_t* callbacks;
    colyseus_predict_t* lerp;
    colyseus_predict_t* reckon;
    colyseus_input_handle_t* input;
    move_input_t* cmd;
    bots_state_t* state;
    const char* sid;
    bot_t* bot;

    pacer_t pacer;
    double smoothing, snap;
    int pattern;

    struct { double x, y, t; } dots[L05_MAX_DOTS];
    int dot_count;
    double last_raw_x, last_raw_y;
    double last_reckon_x;
    int warps;
    double warp_flash_t;
} l05;

/*
 * The reckon step, called by the SDK with a scratch copy of the bot instance.
 * `elapsed_ms` is the absolute server-time at the end of the substep, which is
 * what makes the circle's closed form and the teleport schedule evaluable at
 * any instant — the same property the server relies on.
 */
static void l05_reckon_step(colyseus_schema_t* state, double dt, double elapsed_ms, void* userdata) {
    (void)userdata;
    bot_t* b = (bot_t*)state;
    bot_sim_t s = {
        b->x, b->y, b->vx, b->vy, b->kind,
        b->minX, b->maxX, b->baseY, b->phaseMs, b->speed, b->lastTeleport,
    };
    step_bot(&s, dt, elapsed_ms);
    b->x = s.x; b->y = s.y; b->vx = s.vx; b->vy = s.vy;
    /* Scratch mutation only persists within one forward pass — exactly right:
     * multiple teleport periods chain, but nothing leaks into the snapshot. */
    b->lastTeleport = s.last_teleport;
}

static bool l05_attach_reckon(void) {
    static const char* const FIELDS[] = { "x", "y" };
    l05.reckon = colyseus_predict_create(l05.callbacks, l05.clock);
    return colyseus_predict_track_reckon(l05.reckon, (colyseus_schema_t*)l05.bot, &bot_vtable,
        FIELDS, 2, l05_reckon_step, l05.smoothing, 0, l05.snap, NULL) == 0;
}

static void l05_send_pattern(void) {
    colyseus_message_t* m = colyseus_message_map_create();
    colyseus_message_map_put_str(m, "kind", L05_PATTERNS[l05.pattern]);
    colyseus_room_send(l05.room, "pattern", m);
    colyseus_message_free(m);
}

static bool lab05_attach(app_t* app, colyseus_room_t* room) {
    bots_state_t* state = (bots_state_t*)colyseus_room_get_state(room);
    if (!state || !state->bots || !state->players) { return false; }
    const char* sid = colyseus_room_get_session_id(room);
    bot_t* bot = (bot_t*)colyseus_map_schema_get(state->bots, "bot1");
    if (!bot || !colyseus_map_schema_get(state->players, sid)) { return false; }

    memset(&l05, 0, sizeof(l05));
    l05.room = room;
    l05.state = state;
    l05.sid = sid;
    l05.bot = bot;
    l05.clock = colyseus_room_get_clock(room);
    l05.smoothing = 25;
    l05.snap = 8;
    l05.last_raw_x = NAN;
    l05.last_raw_y = NAN;
    l05.last_reckon_x = NAN;
    l05.warp_flash_t = -1e9;
    l05.callbacks = colyseus_room_callbacks(room);   /* room-owned, shared by the overlays */

    /* The delayed baseline to compare against. */
    l05.lerp = colyseus_predict_create(l05.callbacks, l05.clock);
    colyseus_predict_field_options_t lerp_opts = { 0 };
    lerp_opts.mode = COLYSEUS_PREDICT_LERP;
    lerp_opts.delay = REMOTE_INTERP_MS;
    colyseus_predict_track(l05.lerp, (colyseus_schema_t*)bot, "x", &lerp_opts);
    colyseus_predict_track(l05.lerp, (colyseus_schema_t*)bot, "y", &lerp_opts);

    if (!l05_attach_reckon()) { return false; }

    l05.input = colyseus_room_input(room, &move_input_vtable, NULL);
    if (!l05.input) { return false; }
    l05.cmd = (move_input_t*)colyseus_input_handle_data(l05.input);
    pacer_init(&l05.pacer, 1000.0 / TICK_HZ);

    l05_send_pattern();   /* the teleporter is the most legible default */
    (void)app;
    return true;
}

static void l05_draw_player(const char* sid, void* value, void* userdata) {
    app_t* app = (app_t*)userdata;
    player_t* p = (player_t*)value;
    draw_square(&app->view, p->x, p->y, PLAYER_HALF,
        hue_color(p->hue, strcmp(sid, l05.sid) == 0 ? 0.9 : 0.4));
}

static void l05_rebuild(void) {
    colyseus_predict_free(l05.reckon);
    l05_attach_reckon();
}

static void lab05_frame(app_t* app, double now, double dt) {
    (void)dt;
    /* --- controls ---------------------------------------------------- */
    if (app_key(KEY_B)) {
        l05.pattern = (l05.pattern + 1) % 4;
        l05_send_pattern();
        l05.warps = 0;
    }
    int smooth_step = app_key(KEY_EQUAL) ? 5 : app_key(KEY_MINUS) ? -5 : 0;
    if (smooth_step) {
        l05.smoothing += smooth_step;
        if (l05.smoothing < 0) { l05.smoothing = 0; }
        if (l05.smoothing > 50) { l05.smoothing = 50; }
        l05_rebuild();
    }
    int snap_step = app_key(KEY_PERIOD) ? 6 : app_key(KEY_COMMA) ? -6 : 0;
    if (snap_step) {
        l05.snap += snap_step;
        if (l05.snap < 1) { l05.snap = 1; }
        if (l05.snap > 60) { l05.snap = 60; }
        l05_rebuild();
    }

    int steps = pacer_steps(&l05.pacer, now);
    for (int i = 0; i < steps; i++) {
        l05.cmd->moveX = (int8_t)kb_move_x();
        l05.cmd->moveY = (int8_t)kb_move_y();
        colyseus_input_handle_send(l05.input);
    }
    colyseus_predict_tick(l05.lerp, now);
    colyseus_predict_tick(l05.reckon, now);

    double s_now = colyseus_room_clock_server_now(l05.clock);
    double age = fmax(0, s_now - colyseus_room_clock_last_server_time(l05.clock));
    const world_view_t* v = &app->view;

    /* Raw snapshot dots. */
    if (l05.bot->x != l05.last_raw_x || l05.bot->y != l05.last_raw_y) {
        l05.last_raw_x = l05.bot->x;
        l05.last_raw_y = l05.bot->y;
        if (l05.dot_count == L05_MAX_DOTS) {
            memmove(l05.dots, l05.dots + 1, sizeof(l05.dots[0]) * (L05_MAX_DOTS - 1));
            l05.dot_count--;
        }
        l05.dots[l05.dot_count].x = l05.bot->x;
        l05.dots[l05.dot_count].y = l05.bot->y;
        l05.dots[l05.dot_count].t = now;
        l05.dot_count++;
    }

    colyseus_map_schema_foreach(l05.state->players, l05_draw_player, app);

    for (int i = 0; i < l05.dot_count; i++) {
        double a = 1 - (now - l05.dots[i].t) / 1500.0;
        if (a <= 0) { continue; }
        draw_circle_world(v, l05.dots[i].x, l05.dots[i].y, 0.4, with_alpha(COL_TEXT, a * 0.5));
    }

    double lx = colyseus_predict_value(l05.lerp, (colyseus_schema_t*)l05.bot, "x");
    double ly = colyseus_predict_value(l05.lerp, (colyseus_schema_t*)l05.bot, "y");
    double rx = colyseus_predict_value(l05.reckon, (colyseus_schema_t*)l05.bot, "x");
    double ry = colyseus_predict_value(l05.reckon, (colyseus_schema_t*)l05.bot, "y");

    if (!isnan(l05.last_reckon_x) && fabs(rx - l05.last_reckon_x) > 15) {
        l05.warps++;
        l05.warp_flash_t = now;
    }
    l05.last_reckon_x = rx;

    /* The reckon horizon: newest snapshot -> forward-simulated present. */
    draw_dashed_world(v, l05.bot->x, l05.bot->y, rx, ry, with_alpha(COL_WARN, 0.8), 1.2f);
    draw_circle_world(v, l05.bot->x, l05.bot->y, 0.7, with_alpha(COL_TEXT, 0.9));

    draw_circle_outline_world(v, lx, ly, BOT_RADIUS, COL_BLUE);
    draw_label_world(v, lx, ly, "lerp (past)", COL_BLUE, 10, vs(v, BOT_RADIUS) + 4);
    draw_circle_world(v, rx, ry, BOT_RADIUS, with_alpha(COL_WARN, 0.25));
    draw_circle_outline_world(v, rx, ry, BOT_RADIUS, COL_WARN);
    draw_label_world(v, rx, ry, "reckon (present)", COL_WARN, 10, -vs(v, BOT_RADIUS) - 14);

    if (now - l05.warp_flash_t < 500) {
        draw_label_world(v, rx, ry, "WARP", COL_BAD, 13, -vs(v, BOT_RADIUS) - 30);
    }

    /* --- HUD --------------------------------------------------------- */
    hud_t* h = &app->hud;
    hud_section(h, "TELEMETRY");
    hud_row(h, "reckon horizon (snapshot age)", COL_TEXT, "%.0f ms", age);
    hud_row(h, "reckon vs lerp gap", COL_TEXT, "%.1f u",
        sqrt((rx - lx) * (rx - lx) + (ry - ly) * (ry - ly)));
    hud_row(h, "warps seen", COL_TEXT, "%d", l05.warps);

    hud_section(h, "CONTROLS");
    hud_key(h, "WASD", "drive your own square");
    hud_key(h, "B", TextFormat("bot pattern: %s", L05_PATTERNS[l05.pattern]));
    hud_key(h, "- / =", TextFormat("rebase smoothing  %.0f /s", l05.smoothing));
    hud_key(h, ", / .", TextFormat("snap threshold  %.0f u", l05.snap));
    hud_note(h, "patrol = fully predictable - wander = server-secret turns, so reckon "
        "extrapolates straight through every one and gets corrected - teleport = a "
        "scheduled discontinuity. Raise the snap threshold above the warp distance and "
        "watch the teleport smear across the arena.");
}

static void lab05_detach(app_t* app) {
    (void)app;
    if (l05.reckon) { colyseus_predict_free(l05.reckon); }
    if (l05.lerp) { colyseus_predict_free(l05.lerp); }
    memset(&l05, 0, sizeof(l05));
}

static void lab05_on_reconnect(app_t* app) {
    (void)app;
    pacer_reset(&l05.pacer);
    l05.bot = (bot_t*)colyseus_map_schema_get(l05.state->bots, "bot1");
    l05.dot_count = 0;
}

static const lab_def_t LAB_05 = {
    .id = "05-dead-reckoning",
    .num = 5,
    .title = "Dead Reckoning",
    .blurb = "Forward-simulate remotes to the present with the shared step.",
    .room_name = "lab-bots",
    .state_vtable = &bots_state_vtable,
    .attach = lab05_attach,
    .frame = lab05_frame,
    .detach = lab05_detach,
    .on_reconnect = lab05_on_reconnect,
};
