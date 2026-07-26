/*
 * Lab 06 — Lag Compensation.
 *
 * The client's job is only to be HONEST about its display timeline:
 *  - bots are DRAWN with lerp, REMOTE_INTERP_MS in the past;
 *  - the server records bot history and, on a fire input, rewinds every target
 *    to this client's render time — the same instant the shooter aimed at;
 *  - `allow_rewind` stamps the render time ONLY on fire frames (movement
 *    inputs don't need the extra wire byte).
 *
 * Markers: blue = what you saw · green = the server's rewound read · red = the
 * server's live position. With lag comp on they coincide; with it off, the
 * red↔blue gap is exactly how far you must lead.
 *
 * Port of src/client/labs/06-lag-comp/.
 */

#define L06_MAX_SHOTS 6

typedef struct {
    double ox, oy, tx, ty;        /* ray origin + drawn endpoint */
    double blue_x, blue_y;        /* what the shooter saw at click time */
    double green_x, green_y;      /* server's rewound read */
    double red_x, red_y;          /* server's live position */
    bool answered, hit;
    double t;
} l06_shot_t;

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

    l06_shot_t shots[L06_MAX_SHOTS];
    int shot_count;
    int hits_on, shots_on, hits_off, shots_off;
} l06;

/* Only fire frames carry the lag-comp stamp. */
static bool l06_allow_rewind(void* data, void* userdata) {
    (void)userdata;
    return ((range_input_t*)data)->fire;
}

static void l06_step(const colyseus_step_ctx_t* ctx, colyseus_schema_t* state,
    const colyseus_schema_t* command, void* userdata) {
    (void)userdata;
    range_player_t* p = (range_player_t*)state;
    const range_input_t* inp = (const range_input_t*)command;
    entity_state_t e = { p->x, p->y, p->vx, p->vy };
    step_entity(&e, (double)inp->moveX, (double)inp->moveY, ctx->dt);
    p->x = e.x; p->y = e.y; p->vx = e.vx; p->vy = e.vy;
}

static bool l06_make_reconciler(void) {
    static const char* const FIELDS[] = { "x", "y", "vx", "vy" };
    colyseus_reconciler_options_t opts = { 0 };
    opts.smoothing = 15;
    opts.fields = FIELDS;
    opts.field_count = 4;
    l06.recon = colyseus_reconciler_create((colyseus_schema_t*)l06.me, &range_player_vtable,
        l06.input, colyseus_room_get_clock(l06.room), l06_step, &opts);
    if (!l06.recon) { return false; }
    l06.predicted = (range_player_t*)colyseus_reconciler_state(l06.recon);
    pacer_init(&l06.send_pacer, colyseus_reconciler_step_ms(l06.recon));
    return true;
}

/* Bots ride the lerp timeline — the one the server rewinds to. */
static void l06_on_bot_add(void* value, void* key, void* userdata) {
    (void)key; (void)userdata;
    colyseus_predict_field_options_t lerp = { 0 };
    lerp.mode = COLYSEUS_PREDICT_LERP;
    lerp.delay = REMOTE_INTERP_MS;
    colyseus_predict_track(l06.predict, (colyseus_schema_t*)value, "x", &lerp);
    colyseus_predict_track(l06.predict, (colyseus_schema_t*)value, "y", &lerp);
}

static void l06_on_player_add(void* value, void* key, void* userdata) {
    (void)userdata;
    const char* sid = (const char*)key;
    if (sid && strcmp(sid, l06.sid) == 0) { return; }
    colyseus_predict_field_options_t damped = { 0 };
    damped.mode = COLYSEUS_PREDICT_DAMPED;
    colyseus_predict_track(l06.predict, (colyseus_schema_t*)value, "x", &damped);
    colyseus_predict_track(l06.predict, (colyseus_schema_t*)value, "y", &damped);
}

static void l06_on_entity_remove(void* value, void* key, void* userdata) {
    (void)key; (void)userdata;
    colyseus_predict_detach(l06.predict, (colyseus_schema_t*)value);
}

/* The server's shot report completes the newest unanswered record. */
static void l06_on_shot(colyseus_message_reader_t* reader, void* userdata) {
    (void)userdata;
    const char* sid = NULL;
    size_t len = 0;
    if (!colyseus_message_reader_map_get_str(reader, "sid", &sid, &len)
        || strncmp(sid, l06.sid, len) != 0 || l06.sid[len] != '\0') { return; }

    bool hit = false, lag_comp = false;
    double seen_x = 0, seen_y = 0, live_x = 0, live_y = 0;
    colyseus_message_reader_map_get_bool(reader, "hit", &hit);
    colyseus_message_reader_map_get_bool(reader, "lagComp", &lag_comp);
    colyseus_message_reader_map_get_float(reader, "seenX", &seen_x);
    colyseus_message_reader_map_get_float(reader, "seenY", &seen_y);
    colyseus_message_reader_map_get_float(reader, "liveX", &live_x);
    colyseus_message_reader_map_get_float(reader, "liveY", &live_y);

    for (int i = 0; i < l06.shot_count; i++) {
        if (!l06.shots[i].answered) {
            l06.shots[i].answered = true;
            l06.shots[i].hit = hit;
            l06.shots[i].green_x = seen_x;
            l06.shots[i].green_y = seen_y;
            l06.shots[i].red_x = live_x;
            l06.shots[i].red_y = live_y;
            break;
        }
    }
    if (lag_comp) { l06.shots_on++; if (hit) { l06.hits_on++; } }
    else { l06.shots_off++; if (hit) { l06.hits_off++; } }
}

static bool lab06_attach(app_t* app, colyseus_room_t* room) {
    range_state_t* state = (range_state_t*)colyseus_room_get_state(room);
    if (!state || !state->players || !state->bots) { return false; }
    const char* sid = colyseus_room_get_session_id(room);
    range_player_t* me = (range_player_t*)colyseus_map_schema_get(state->players, sid);
    bot_t* bot = (bot_t*)colyseus_map_schema_get(state->bots, "bot1");
    if (!me || !bot) { return false; }

    memset(&l06, 0, sizeof(l06));
    l06.room = room;
    l06.state = state;
    l06.sid = sid;
    l06.me = me;
    l06.bot = bot;
    l06.aim_x = 50;
    l06.aim_y = 20;

    l06.callbacks = colyseus_callbacks_create(room->serializer->decoder);
    l06.predict = colyseus_predict_create(l06.callbacks, colyseus_room_get_clock(room));
    colyseus_callbacks_on_add(l06.callbacks, state, "bots", l06_on_bot_add, NULL, true);
    colyseus_callbacks_on_add(l06.callbacks, state, "players", l06_on_player_add, NULL, true);
    colyseus_callbacks_on_remove(l06.callbacks, state, "players", l06_on_entity_remove, NULL);
    colyseus_room_on_message(room, "shot", l06_on_shot, NULL);

    colyseus_input_options_t in_opts = { 0 };
    in_opts.allow_rewind = l06_allow_rewind;
    /*
     * The stamp is serverNow - (render_delay + rtt/2), and the bots are DRAWN
     * REMOTE_INTERP_MS in the past — so render_delay must equal that lerp delay
     * or the server rewinds to an instant this client never displayed. In the
     * JS SDK `predict.reconciler()` binds this automatically from the Predict's
     * lerp delay; the C port has no such binding, so pass it explicitly.
     */
    in_opts.render_delay = REMOTE_INTERP_MS;
    l06.input = colyseus_room_input(room, &range_input_vtable, &in_opts);
    if (!l06.input) { return false; }
    l06.cmd = (range_input_t*)colyseus_input_handle_data(l06.input);
    (void)app;
    return l06_make_reconciler();
}

static void l06_draw_remote(const char* sid, void* value, void* userdata) {
    app_t* app = (app_t*)userdata;
    if (strcmp(sid, l06.sid) == 0) { return; }
    range_player_t* p = (range_player_t*)value;
    draw_square(&app->view,
        colyseus_predict_value(l06.predict, (colyseus_schema_t*)p, "x"),
        colyseus_predict_value(l06.predict, (colyseus_schema_t*)p, "y"),
        PLAYER_HALF, hue_color(p->hue, 0.4));
}

static void lab06_frame(app_t* app, double now, double dt) {
    (void)dt;
    if (l06.rebind) {
        range_player_t* me = (range_player_t*)colyseus_map_schema_get(l06.state->players, l06.sid);
        if (me) {
            if (l06.recon) { colyseus_reconciler_free(l06.recon); l06.recon = NULL; }
            l06.me = me;
            l06.bot = (bot_t*)colyseus_map_schema_get(l06.state->bots, "bot1");
            l06.rebind = !l06_make_reconciler();
        }
        if (!l06.recon) { return; }
    }

    const world_view_t* v = &app->view;
    Vector2 mouse = GetMousePosition();
    bool over_stage = mouse.x < app->stage_x + app->stage_w;
    if (g_autopilot) {
        /* The acceptance script has no cursor — track the target it fires at. */
        l06.aim_x = colyseus_predict_value(l06.predict, (colyseus_schema_t*)l06.bot, "x");
        l06.aim_y = colyseus_predict_value(l06.predict, (colyseus_schema_t*)l06.bot, "y");
    } else if (over_stage) {
        l06.aim_x = vwx(v, mouse.x);
        l06.aim_y = vwy(v, mouse.y);
    }
    if (IsMouseButtonPressed(MOUSE_BUTTON_LEFT) && over_stage) { l06.pending_fire = true; }
    if (app_key(KEY_SPACE)) { l06.pending_fire = true; }
    if (app_key(KEY_C)) {
        colyseus_message_t* m = colyseus_message_map_create();
        colyseus_message_map_put_bool(m, "on", !l06.state->lagComp);
        colyseus_room_send(l06.room, "lagcomp", m);
        colyseus_message_free(m);
    }

    colyseus_reconciler_tick(l06.recon, now);
    colyseus_predict_tick(l06.predict, now);

    int steps = pacer_steps(&l06.send_pacer, now);
    for (int i = 0; i < steps; i++) {
        l06.cmd->moveX = (int8_t)kb_move_x();
        l06.cmd->moveY = (int8_t)kb_move_y();
        l06.cmd->aimX = (float)l06.aim_x;
        l06.cmd->aimY = (float)l06.aim_y;
        l06.cmd->fire = l06.pending_fire;
        colyseus_input_handle_send(l06.input);
        if (l06.pending_fire) {
            /* Record what THIS screen showed at the moment of the shot. */
            double bx = colyseus_predict_value(l06.predict, (colyseus_schema_t*)l06.bot, "x");
            double by = colyseus_predict_value(l06.predict, (colyseus_schema_t*)l06.bot, "y");
            double px = l06.predicted->x, py = l06.predicted->y;
            double dx = l06.aim_x - px, dy = l06.aim_y - py;
            double len = sqrt(dx * dx + dy * dy);
            if (len < 1e-9) { len = 1; }
            dx /= len; dy /= len;
            if (l06.shot_count == L06_MAX_SHOTS) {
                memmove(l06.shots, l06.shots + 1, sizeof(l06_shot_t) * (L06_MAX_SHOTS - 1));
                l06.shot_count--;
            }
            l06.shots[l06.shot_count] = (l06_shot_t){
                px, py, px + dx * 120, py + dy * 120, bx, by, 0, 0, 0, 0, false, false, now };
            l06.shot_count++;
            l06.pending_fire = false;
        }
    }

    /* --- render ------------------------------------------------------ */
    colyseus_map_schema_foreach(l06.state->players, l06_draw_remote, app);
    double px = colyseus_reconciler_value(l06.recon, "x");
    double py = colyseus_reconciler_value(l06.recon, "y");
    draw_square(v, px, py, PLAYER_HALF, hue_color(l06.me->hue, 1));
    draw_square_outline(v, px, py, PLAYER_HALF, COL_TEXT, 1.0f);

    double bx = colyseus_predict_value(l06.predict, (colyseus_schema_t*)l06.bot, "x");
    double by = colyseus_predict_value(l06.predict, (colyseus_schema_t*)l06.bot, "y");
    draw_circle_world(v, bx, by, BOT_RADIUS, with_alpha(COL_BLUE, 0.25));
    draw_circle_outline_world(v, bx, by, BOT_RADIUS, COL_BLUE);
    draw_label_world(v, bx, by, "target (lerp view)", COL_BLUE, 10, -vs(v, BOT_RADIUS) - 14);

    draw_dashed_world(v, px, py, l06.aim_x, l06.aim_y, with_alpha(COL_TEXT, 0.18), 1.0f);
    draw_marker_world(v, l06.aim_x, l06.aim_y, 0.9, with_alpha(COL_TEXT, 0.7));

    for (int i = l06.shot_count - 1; i >= 0; i--) {
        l06_shot_t* s = &l06.shots[i];
        double age = now - s->t;
        if (age > 2600) {
            memmove(&l06.shots[i], &l06.shots[i + 1],
                sizeof(l06_shot_t) * (size_t)(l06.shot_count - i - 1));
            l06.shot_count--;
            continue;
        }
        double a = 1 - age / 2600;
        Color ray = !s->answered ? with_alpha(COL_TEXT, a * 0.5)
            : with_alpha(s->hit ? COL_GOOD : COL_BAD, a * 0.7);
        draw_line_world(v, s->ox, s->oy, s->tx, s->ty, ray, 1.2f);
        draw_marker_world(v, s->blue_x, s->blue_y, BOT_RADIUS * 0.7, with_alpha(COL_BLUE, a));
        if (s->answered) {
            draw_marker_world(v, s->green_x, s->green_y, BOT_RADIUS * 0.85, with_alpha(COL_GOOD, a));
            draw_marker_world(v, s->red_x, s->red_y, BOT_RADIUS, with_alpha(COL_BAD, a));
        }
    }

    /* --- HUD --------------------------------------------------------- */
    hud_t* h = &app->hud;
    hud_section(h, "TELEMETRY");
    hud_row(h, "hits (lag comp ON)",
        l06.shots_on && l06.hits_on * 10 > l06.shots_on * 7 ? COL_GOOD : COL_TEXT,
        "%d / %d", l06.hits_on, l06.shots_on);
    hud_row(h, "hits (lag comp OFF)",
        l06.shots_off && l06.hits_off * 2 < l06.shots_off ? COL_BAD : COL_TEXT,
        "%d / %d", l06.hits_off, l06.shots_off);
    double gap = -1;
    for (int i = l06.shot_count - 1; i >= 0; i--) {
        if (l06.shots[i].answered) {
            gap = sqrt((l06.shots[i].red_x - l06.shots[i].blue_x)
                    * (l06.shots[i].red_x - l06.shots[i].blue_x)
                + (l06.shots[i].red_y - l06.shots[i].blue_y)
                    * (l06.shots[i].red_y - l06.shots[i].blue_y));
            break;
        }
    }
    if (gap >= 0) { hud_row(h, "view lag (red<->blue gap)", COL_TEXT, "%.1f u", gap); }
    else { hud_row(h, "view lag (red<->blue gap)", COL_TEXT_FAINT, "--"); }

    hud_section(h, "CONTROLS");
    hud_key(h, "WASD", "drive (predicted)");
    hud_key(h, "mouse", "aim");
    hud_key(h, "click / SPACE", "fire");
    hud_key(h, "C", l06.state->lagComp ? "lag comp: ON (room-wide)" : "lag comp: OFF (room-wide)");
    hud_note(h, "blue = what you saw - green = the server's rewound read - red = the "
        "server live. Turn lag comp off at 200 ms and you have to lead the target by "
        "exactly the red-to-blue gap.");
}

static void lab06_detach(app_t* app) {
    (void)app;
    if (l06.recon) { colyseus_reconciler_free(l06.recon); }
    if (l06.predict) { colyseus_predict_free(l06.predict); }
    if (l06.callbacks) { colyseus_callbacks_free(l06.callbacks); }
    memset(&l06, 0, sizeof(l06));
}

static void lab06_on_reconnect(app_t* app) { (void)app; l06.rebind = true; }

static const lab_def_t LAB_06 = {
    .id = "06-lag-comp",
    .num = 6,
    .title = "Lag Compensation",
    .blurb = "The server rewinds targets to what you saw.",
    .room_name = "lab-range",
    .state_vtable = &range_state_vtable,
    .attach = lab06_attach,
    .frame = lab06_frame,
    .detach = lab06_detach,
    .on_reconnect = lab06_on_reconnect,
};
