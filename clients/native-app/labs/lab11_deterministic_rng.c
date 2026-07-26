/*
 * Lab 11 — Deterministic Randomness.
 *
 * The shotgun fan is "random", yet the client predicts every pellet EXACTLY —
 * because the randomness is a pure function of data both sides already share:
 *
 *   seed = splitmix32(input seq ^ room salt)  ->  mulberry32 pellet stream
 *
 * The seq is the engine's own input counter (input_handle_send() returns it;
 * the server reads channel.consumedCount). The salt is synced room state.
 * NOTHING about the pellets rides the wire — the server's broadcast here
 * carries its angles only so this lab can overlay and compare.
 *
 * Port of src/client/labs/11-deterministic-rng/.
 */

#define L11_FAN_LEN 40.0
#define L11_MAX_FANS 4

typedef struct {
    int seq;
    double ox, oy;
    double client_angles[PELLETS];
    double server_angles[PELLETS];
    bool answered;
    int hits;
    double t;
} l11_fan_t;

static struct {
    colyseus_room_t* room;
    range_state_t* state;
    const char* sid;

    colyseus_callbacks_t* callbacks;
    colyseus_predict_t* predict;
    colyseus_input_handle_t* input;
    range_input_t* cmd;

    range_player_t* me;
    colyseus_reconciler_t* recon;
    range_player_t* predicted;
    pacer_t send_pacer;
    bool rebind;

    bot_t* bot;
    double aim_x, aim_y;
    bool pending_fire;
    bool cheat;

    l11_fan_t fans[L11_MAX_FANS];
    int fan_count;
    double max_divergence;
    bool has_divergence;
    uint32_t cheat_state;
} l11;

/* The client's half of the derivation — identical to the server's. */
static void l11_client_fan(double base_angle, int seq, uint32_t salt, double* out) {
    if (l11.cheat) {
        /* The broken version: a local RNG the server cannot reproduce. */
        for (int i = 0; i < PELLETS; i++) {
            out[i] = base_angle + (mulberry32_next(&l11.cheat_state) - 0.5) * SPREAD_RAD;
        }
        return;
    }
    spread_angles(base_angle, seq, salt, out);
}

static bool l11_allow_rewind(void* data, void* userdata) {
    (void)userdata;
    return ((range_input_t*)data)->fire;
}

static void l11_step(const colyseus_step_ctx_t* ctx, colyseus_schema_t* state,
    const colyseus_schema_t* command, void* userdata) {
    (void)userdata;
    range_player_t* p = (range_player_t*)state;
    const range_input_t* inp = (const range_input_t*)command;
    entity_state_t e = { p->x, p->y, p->vx, p->vy };
    step_entity(&e, (double)inp->moveX, (double)inp->moveY, ctx->dt);
    p->x = e.x; p->y = e.y; p->vx = e.vx; p->vy = e.vy;
}

static bool l11_make_reconciler(void) {
    static const char* const FIELDS[] = { "x", "y", "vx", "vy" };
    colyseus_reconciler_options_t opts = { 0 };
    opts.smoothing = 15;
    opts.fields = FIELDS;
    opts.field_count = 4;
    l11.recon = colyseus_reconciler_create((colyseus_schema_t*)l11.me, &range_player_vtable,
        l11.input, colyseus_room_get_clock(l11.room), l11_step, &opts);
    if (!l11.recon) { return false; }
    l11.predicted = (range_player_t*)colyseus_reconciler_state(l11.recon);
    pacer_init(&l11.send_pacer, colyseus_reconciler_step_ms(l11.recon));
    return true;
}

static void l11_on_bot_add(void* value, void* key, void* userdata) {
    (void)key; (void)userdata;
    colyseus_predict_field_options_t lerp = { 0 };
    lerp.mode = COLYSEUS_PREDICT_LERP;
    lerp.delay = REMOTE_INTERP_MS;
    colyseus_predict_track(l11.predict, (colyseus_schema_t*)value, "x", &lerp);
    colyseus_predict_track(l11.predict, (colyseus_schema_t*)value, "y", &lerp);
}

static void l11_on_player_add(void* value, void* key, void* userdata) {
    (void)userdata;
    const char* sid = (const char*)key;
    if (sid && strcmp(sid, l11.sid) == 0) { return; }
    colyseus_predict_field_options_t damped = { 0 };
    damped.mode = COLYSEUS_PREDICT_DAMPED;
    colyseus_predict_track(l11.predict, (colyseus_schema_t*)value, "x", &damped);
    colyseus_predict_track(l11.predict, (colyseus_schema_t*)value, "y", &damped);
}

static void l11_on_player_remove(void* value, void* key, void* userdata) {
    (void)key; (void)userdata;
    colyseus_predict_detach(l11.predict, (colyseus_schema_t*)value);
}

/* The server's fan for the same (seq, salt) — for overlay only. */
static void l11_on_spread(colyseus_message_reader_t* reader, void* userdata) {
    (void)userdata;
    const char* sid = NULL;
    size_t len = 0;
    if (!colyseus_message_reader_map_get_str(reader, "sid", &sid, &len)
        || strncmp(sid, l11.sid, len) != 0 || l11.sid[len] != '\0') { return; }

    int64_t seq = 0;
    if (!colyseus_message_reader_map_get_int(reader, "seq", &seq)) { return; }
    l11_fan_t* fan = NULL;
    for (int i = 0; i < l11.fan_count; i++) {
        if (l11.fans[i].seq == (int)seq) { fan = &l11.fans[i]; break; }
    }
    if (!fan) { return; }

    colyseus_message_reader_t* angles = colyseus_message_reader_map_get(reader, "angles");
    if (!angles) { return; }
    size_t n = colyseus_message_reader_get_array_size(angles);
    if (n > PELLETS) { n = PELLETS; }
    double worst = 0;
    for (size_t i = 0; i < n; i++) {
        colyseus_message_reader_t* el = colyseus_message_reader_get_array_element(angles, i);
        if (!el) { continue; }
        fan->server_angles[i] = colyseus_message_reader_get_float(el);
        double d = fabs(fan->client_angles[i] - fan->server_angles[i]);
        if (d > worst) { worst = d; }
        colyseus_message_reader_free(el);
    }
    colyseus_message_reader_free(angles);

    int64_t hits = 0;
    colyseus_message_reader_map_get_int(reader, "hits", &hits);
    fan->hits = (int)hits;
    fan->answered = true;
    l11.max_divergence = worst;
    l11.has_divergence = true;
}

static bool lab11_attach(app_t* app, colyseus_room_t* room) {
    range_state_t* state = (range_state_t*)colyseus_room_get_state(room);
    if (!state || !state->players || !state->bots) { return false; }
    const char* sid = colyseus_room_get_session_id(room);
    range_player_t* me = (range_player_t*)colyseus_map_schema_get(state->players, sid);
    bot_t* bot = (bot_t*)colyseus_map_schema_get(state->bots, "bot1");
    if (!me || !bot) { return false; }

    memset(&l11, 0, sizeof(l11));
    l11.room = room;
    l11.state = state;
    l11.sid = sid;
    l11.me = me;
    l11.bot = bot;
    l11.aim_x = 50;
    l11.aim_y = 20;
    l11.cheat_state = 0x1234567u;

    l11.callbacks = colyseus_callbacks_create(room->serializer->decoder);
    l11.predict = colyseus_predict_create(l11.callbacks, colyseus_room_get_clock(room));
    colyseus_callbacks_on_add(l11.callbacks, state, "bots", l11_on_bot_add, NULL, true);
    colyseus_callbacks_on_add(l11.callbacks, state, "players", l11_on_player_add, NULL, true);
    colyseus_callbacks_on_remove(l11.callbacks, state, "players", l11_on_player_remove, NULL);
    colyseus_room_on_message(room, "spread", l11_on_spread, NULL);

    colyseus_input_options_t in_opts = { 0 };
    in_opts.allow_rewind = l11_allow_rewind;
    in_opts.render_delay = REMOTE_INTERP_MS;   /* see the note in lab 06 */
    l11.input = colyseus_room_input(room, &range_input_vtable, &in_opts);
    if (!l11.input) { return false; }
    l11.cmd = (range_input_t*)colyseus_input_handle_data(l11.input);
    (void)app;
    return l11_make_reconciler();
}

static void l11_draw_remote(const char* sid, void* value, void* userdata) {
    app_t* app = (app_t*)userdata;
    if (strcmp(sid, l11.sid) == 0) { return; }
    range_player_t* p = (range_player_t*)value;
    draw_square(&app->view,
        colyseus_predict_value(l11.predict, (colyseus_schema_t*)p, "x"),
        colyseus_predict_value(l11.predict, (colyseus_schema_t*)p, "y"),
        PLAYER_HALF, hue_color(p->hue, 0.4));
}

static void lab11_frame(app_t* app, double now, double dt) {
    (void)dt;
    if (l11.rebind) {
        range_player_t* me = (range_player_t*)colyseus_map_schema_get(l11.state->players, l11.sid);
        if (me) {
            if (l11.recon) { colyseus_reconciler_free(l11.recon); l11.recon = NULL; }
            l11.me = me;
            l11.bot = (bot_t*)colyseus_map_schema_get(l11.state->bots, "bot1");
            l11.rebind = !l11_make_reconciler();
        }
        if (!l11.recon) { return; }
    }

    const world_view_t* v = &app->view;
    Vector2 mouse = GetMousePosition();
    bool over_stage = mouse.x < app->stage_x + app->stage_w;
    if (g_autopilot) {
        l11.aim_x = colyseus_predict_value(l11.predict, (colyseus_schema_t*)l11.bot, "x");
        l11.aim_y = colyseus_predict_value(l11.predict, (colyseus_schema_t*)l11.bot, "y");
    } else if (over_stage) {
        l11.aim_x = vwx(v, mouse.x);
        l11.aim_y = vwy(v, mouse.y);
    }
    if (IsMouseButtonPressed(MOUSE_BUTTON_LEFT) && over_stage) { l11.pending_fire = true; }
    if (app_key(KEY_SPACE)) { l11.pending_fire = true; }
    if (app_key(KEY_X)) { l11.cheat = !l11.cheat; }

    colyseus_reconciler_tick(l11.recon, now);
    colyseus_predict_tick(l11.predict, now);

    int steps = pacer_steps(&l11.send_pacer, now);
    for (int i = 0; i < steps; i++) {
        l11.cmd->moveX = (int8_t)kb_move_x();
        l11.cmd->moveY = (int8_t)kb_move_y();
        l11.cmd->aimX = (float)l11.aim_x;
        l11.cmd->aimY = (float)l11.aim_y;
        l11.cmd->fire = l11.pending_fire;
        l11.cmd->spread = true;
        int seq = colyseus_input_handle_send(l11.input);
        if (l11.pending_fire && seq > 0) {
            double px = l11.predicted->x, py = l11.predicted->y;
            double base = atan2(l11.aim_y - py, l11.aim_x - px);
            if (l11.fan_count == L11_MAX_FANS) {
                memmove(l11.fans, l11.fans + 1, sizeof(l11_fan_t) * (L11_MAX_FANS - 1));
                l11.fan_count--;
            }
            l11_fan_t* f = &l11.fans[l11.fan_count++];
            memset(f, 0, sizeof(*f));
            f->seq = seq;
            f->ox = px;
            f->oy = py;
            f->t = now;
            l11_client_fan(base, seq, l11.state->salt, f->client_angles);
            l11.pending_fire = false;
        }
    }

    /* --- render ------------------------------------------------------ */
    colyseus_map_schema_foreach(l11.state->players, l11_draw_remote, app);
    double px = colyseus_reconciler_value(l11.recon, "x");
    double py = colyseus_reconciler_value(l11.recon, "y");
    draw_square(v, px, py, PLAYER_HALF, hue_color(l11.me->hue, 1));
    draw_square_outline(v, px, py, PLAYER_HALF, COL_TEXT, 1.0f);

    double bx = colyseus_predict_value(l11.predict, (colyseus_schema_t*)l11.bot, "x");
    double by = colyseus_predict_value(l11.predict, (colyseus_schema_t*)l11.bot, "y");
    draw_circle_world(v, bx, by, BOT_RADIUS, with_alpha(COL_BLUE, 0.25));
    draw_circle_outline_world(v, bx, by, BOT_RADIUS, COL_BLUE);
    draw_marker_world(v, l11.aim_x, l11.aim_y, 0.9, with_alpha(COL_TEXT, 0.7));

    for (int i = l11.fan_count - 1; i >= 0; i--) {
        l11_fan_t* f = &l11.fans[i];
        double age = now - f->t;
        if (age > 2400) {
            memmove(&l11.fans[i], &l11.fans[i + 1],
                sizeof(l11_fan_t) * (size_t)(l11.fan_count - i - 1));
            l11.fan_count--;
            continue;
        }
        double a = 1 - age / 2400;
        for (int p = 0; p < PELLETS; p++) {
            double ang = f->client_angles[p];
            draw_line_world(v, f->ox, f->oy, f->ox + cos(ang) * L11_FAN_LEN,
                f->oy + sin(ang) * L11_FAN_LEN, with_alpha(COL_WARN, a * 0.75), 1.2f);
        }
        if (f->answered) {
            for (int p = 0; p < PELLETS; p++) {
                double ang = f->server_angles[p];
                draw_dashed_world(v, f->ox, f->oy, f->ox + cos(ang) * L11_FAN_LEN,
                    f->oy + sin(ang) * L11_FAN_LEN, with_alpha(COL_TEXT, a * 0.9), 0.8f);
            }
        }
    }
    if (l11.fan_count) {
        l11_fan_t* last = &l11.fans[l11.fan_count - 1];
        draw_label_world(v, last->ox, last->oy, "amber = client - white = server",
            with_alpha(COL_TEXT, 0.5), 9, vs(v, PLAYER_HALF) + 4);
    }

    /* --- HUD --------------------------------------------------------- */
    hud_t* h = &app->hud;
    hud_section(h, "TELEMETRY");
    if (l11.has_divergence) {
        hud_row(h, "fan divergence (last shot)",
            l11.max_divergence < 1e-6 ? COL_GOOD : COL_BAD, "%.5f rad", l11.max_divergence);
    } else {
        hud_row(h, "fan divergence (last shot)", COL_TEXT_FAINT, "--");
    }
    int last_hits = -1, last_total = 0;
    for (int i = l11.fan_count - 1; i >= 0; i--) {
        if (l11.fans[i].answered) { last_hits = l11.fans[i].hits; last_total = PELLETS; break; }
    }
    if (last_hits >= 0) { hud_row(h, "pellets hit (last shot)", COL_TEXT, "%d / %d", last_hits, last_total); }
    else { hud_row(h, "pellets hit (last shot)", COL_TEXT_FAINT, "--"); }
    hud_row(h, "room salt", COL_TEXT, "%u", l11.state->salt);
    hud_row(h, "shots (authoritative)", COL_TEXT, "%d", l11.me->shots);

    hud_section(h, "CONTROLS");
    hud_key(h, "WASD", "drive");
    hud_key(h, "mouse", "aim");
    hud_key(h, "click / SPACE", "fire a 6-pellet fan");
    hud_key(h, "X", l11.cheat ? "CHEATING with a local RNG" : "seeded from (seq, salt)");
    hud_note(h, "Amber = the fan your client derived at the click. White dashes = the fan "
        "the server derived from the same (seq, salt). They should be identical to the "
        "pixel. Press X to swap in an unshared RNG and watch them disagree.");
}

static void lab11_detach(app_t* app) {
    (void)app;
    if (l11.recon) { colyseus_reconciler_free(l11.recon); }
    if (l11.predict) { colyseus_predict_free(l11.predict); }
    if (l11.callbacks) { colyseus_callbacks_free(l11.callbacks); }
    memset(&l11, 0, sizeof(l11));
}

static void lab11_on_reconnect(app_t* app) { (void)app; l11.rebind = true; }

static const lab_def_t LAB_11 = {
    .id = "11-deterministic-rng",
    .num = 11,
    .title = "Deterministic Randomness",
    .blurb = "Same seed both sides, nothing on the wire.",
    .room_name = "lab-range",
    .state_vtable = &range_state_vtable,
    .attach = lab11_attach,
    .frame = lab11_frame,
    .detach = lab11_detach,
    .on_reconnect = lab11_on_reconnect,
};
