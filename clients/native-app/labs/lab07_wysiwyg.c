/*
 * Lab 07 — WYSIWYG Collision.
 *
 * The collision against the moving bot is predicted INSIDE the reconciler
 * step. Two ingredients make the client's verdict equal the server's:
 *
 *  1. predict_value_at(bot, "x", ctx->reckon_time) — read the bot at the
 *     instant the server will REWIND this input to. Reading anything else
 *     (the stale snapshot, or the smoothed render pose) tests against a
 *     position the server never uses.
 *
 *  2. colyseus_step_memo(...) — the verdict is NOT re-derivable on rollback
 *     replay (the client keeps no bot history; a later replay would read the
 *     bot reckoned from a NEWER snapshot and could flip the call). memo runs
 *     the test once on the live step and replays the outcome verbatim.
 *
 * The verdict is a VECTOR (the knockback vx/vy), so it rides one
 * colyseus_step_memo_vec: the collision test runs exactly once on the live step
 * and both components replay together. Encoding it as an angle would round
 * through atan2/cos and reintroduce the drift this lab exists to eliminate.
 *
 * Port of src/client/labs/07-wysiwyg/.
 */

static struct {
    colyseus_room_t* room;
    bump_state_t* state;
    const char* sid;

    colyseus_predict_t* predict;
    colyseus_input_handle_t* input;
    move_input_t* cmd;

    bump_player_t* me;
    colyseus_reconciler_t* recon;
    bump_player_t* predicted;
    bool rebind;

    bot_t* bot;
    bool use_value_at;
    bool use_memo;

    int bumps_predicted;
    double last_bump_at, bump_flash_t;
    int mispredicts;
    int last_reconcile_seq;
} l07;

/* --------------------------------------------------- the bump verdict */

typedef struct {
    double px, py;
    int bump_ticks;
    double when;
} l07_probe_t;

typedef struct { const l07_probe_t* probe; bool hit; double vx, vy; } l07_scan_t;

static void l07_scan_bot(const char* key, void* value, void* userdata) {
    (void)key;
    l07_scan_t* s = (l07_scan_t*)userdata;
    if (s->hit) { return; }
    colyseus_schema_t* bot = (colyseus_schema_t*)value;
    double bx, by;
    if (l07.use_value_at) {
        /* The server rewinds THIS input to reckon_time — test there. */
        bx = colyseus_predict_value_at(l07.predict, bot, "x", s->probe->when);
        by = colyseus_predict_value_at(l07.predict, bot, "y", s->probe->when);
    } else {
        bx = ((bot_t*)bot)->x;   /* the wrong read: ~RTT/2 behind the server */
        by = ((bot_t*)bot)->y;
    }
    s->hit = collide_bot(s->probe->px, s->probe->py, s->probe->bump_ticks,
        bx, by, &s->vx, &s->vy);
}

/* Writes the knockback into out[0..1]; returns 0 for "no bump this step". */
static int l07_test_bots(double* out, void* userdata) {
    const l07_probe_t* probe = (const l07_probe_t*)userdata;
    l07_scan_t scan = { probe, false, 0, 0 };
    colyseus_map_schema_foreach(l07.state->bots, l07_scan_bot, &scan);
    if (!scan.hit) { return 0; }
    out[0] = scan.vx;
    out[1] = scan.vy;
    return 2;
}

static void l07_step(const colyseus_step_ctx_t* ctx, colyseus_schema_t* state,
    const colyseus_schema_t* command, void* userdata) {
    (void)userdata;
    bump_player_t* p = (bump_player_t*)state;
    const move_input_t* inp = (const move_input_t*)command;

    int ticks = p->bumpTicks;
    step_bump_gate(&ticks);            /* reconciled tick gate (both sides) */
    p->bumpTicks = (uint8_t)ticks;

    entity_state_t e = { p->x, p->y, p->vx, p->vy };
    step_entity(&e, (double)inp->moveX, (double)inp->moveY, ctx->dt);
    p->x = e.x; p->y = e.y; p->vx = e.vx; p->vy = e.vy;

    l07_probe_t probe = { p->x, p->y, p->bumpTicks, ctx->reckon_time };
    double knock[COLYSEUS_MEMO_VEC_MAX];
    int hit = l07.use_memo
        ? colyseus_step_memo_vec(ctx, "bump", l07_test_bots, &probe, knock)
        : l07_test_bots(knock, &probe);

    if (hit == 2) {
        p->vx = knock[0];
        p->vy = knock[1];
        p->bumpTicks = BUMP_COOLDOWN_TICKS;   /* immunity rides adopt+replay */
        if (!ctx->is_replay) {                /* FX/counters: live step only */
            l07.bumps_predicted++;
            l07.last_bump_at = nd_now();
            l07.bump_flash_t = l07.last_bump_at;
        }
    }
}

/* ------------------------------------------------------------- setup */

static void l07_reckon_step(colyseus_schema_t* state, double dt, double elapsed_ms, void* userdata) {
    (void)userdata;
    bot_t* b = (bot_t*)state;
    bot_sim_t s = {
        b->x, b->y, b->vx, b->vy, b->kind,
        b->minX, b->maxX, b->baseY, b->phaseMs, b->speed, b->lastTeleport,
    };
    step_bot(&s, dt, elapsed_ms);
    b->x = s.x; b->y = s.y; b->vx = s.vx; b->vy = s.vy;
    b->lastTeleport = s.last_teleport;
}

static bool l07_make_reconciler(void) {
    static const char* const FIELDS[] = { "x", "y", "vx", "vy", "bumpTicks" };
    colyseus_reconciler_options_t opts = { 0 };
    opts.smooth_ms = 65;
    opts.fields = FIELDS;
    opts.field_count = 5;
    l07.recon = colyseus_predict_reconciler(l07.predict, (colyseus_schema_t*)l07.me,
        &bump_player_vtable, l07.input, l07_step, &opts);
    if (!l07.recon) { return false; }
    l07.predicted = (bump_player_t*)colyseus_reconciler_state(l07.recon);
    l07.last_reconcile_seq = 0;
    return true;
}

static bool lab07_attach(app_t* app, colyseus_room_t* room) {
    bump_state_t* state = (bump_state_t*)colyseus_room_get_state(room);
    if (!state || !state->players || !state->bots) { return false; }
    const char* sid = colyseus_room_get_session_id(room);
    bump_player_t* me = (bump_player_t*)colyseus_map_schema_get(state->players, sid);
    bot_t* bot = (bot_t*)colyseus_map_schema_get(state->bots, "bot1");
    if (!me || !bot) { return false; }

    memset(&l07, 0, sizeof(l07));
    l07.room = room;
    l07.state = state;
    l07.sid = sid;
    l07.me = me;
    l07.bot = bot;
    l07.use_value_at = true;
    l07.use_memo = true;
    l07.last_bump_at = -1e9;
    l07.bump_flash_t = -1e9;

    l07.predict = colyseus_predict_for_room(room);
    /* Bots are DEAD-RECKONED through the shared step — the timeline the
     * collision test below reads at ctx->reckon_time. */
    colyseus_predict_attach_all_reckon(l07.predict, (colyseus_schema_t*)state, "bots",
        &bot_vtable, SMOOTHED_XY, 2, l07_reckon_step, 25, 0, 0, NULL);
    colyseus_predict_attach_all(l07.predict, (colyseus_schema_t*)state, "players",
        ATTACH_XY_DAMPED, 2, sid, NULL);

    l07.input = colyseus_room_input(room, &move_input_vtable, NULL);
    if (!l07.input) { return false; }
    l07.cmd = (move_input_t*)colyseus_input_handle_data(l07.input);
    (void)app;
    if (!l07_make_reconciler()) { return false; }
    app_set_latency_preset(2);   /* a knife-edge verdict needs a real RTT */
    return true;
}

static void l07_draw_remote(const char* sid, void* value, void* userdata) {
    app_t* app = (app_t*)userdata;
    if (strcmp(sid, l07.sid) == 0) { return; }
    bump_player_t* p = (bump_player_t*)value;
    draw_square(&app->view,
        colyseus_predict_value(l07.predict, (colyseus_schema_t*)p, "x"),
        colyseus_predict_value(l07.predict, (colyseus_schema_t*)p, "y"),
        PLAYER_HALF, hue_color(p->hue, 0.4));
}

static void lab07_frame(app_t* app, double now, double dt) {
    (void)dt;
    if (l07.rebind) {
        bump_player_t* me = (bump_player_t*)colyseus_map_schema_get(l07.state->players, l07.sid);
        if (me) {
            if (l07.recon) { colyseus_reconciler_free(l07.recon); l07.recon = NULL; }
            l07.me = me;
            l07.bot = (bot_t*)colyseus_map_schema_get(l07.state->bots, "bot1");
            l07.rebind = !l07_make_reconciler();
        }
        if (!l07.recon) { return; }
    }

    /* Both toggles rebuild nothing — the step reads them live. */
    if (app_key(KEY_V)) { l07.use_value_at = !l07.use_value_at; }
    if (app_key(KEY_M)) { l07.use_memo = !l07.use_memo; }


    /* The acceptance script can't hand-steer into a moving bot; when it drives,
     * seek the bot's lane and let the patrol sweep do the rest. */
    int move_x = kb_move_x(), move_y = kb_move_y();
    if (g_autopilot) {
        double lane = colyseus_predict_value(l07.predict, (colyseus_schema_t*)l07.bot, "y");
        double dy = lane - l07.predicted->y;
        move_x = 0;
        move_y = dy > 1.0 ? 1 : dy < -1.0 ? -1 : 0;
    }

    int steps = colyseus_predict_tick(l07.predict, now);
    for (int i = 0; i < steps; i++) {
        l07.cmd->moveX = (int8_t)move_x;
        l07.cmd->moveY = (int8_t)move_y;
        colyseus_input_handle_send(l07.input);
    }

    /*
     * Attribute LARGE corrections near a predicted bump to a flipped verdict.
     * Small post-bump corrections (< ~3u) are knockback-direction epsilon; a
     * genuinely flipped verdict diverges by many units — the 48 u/s shove
     * either happened or it didn't.
     */
    int seq = colyseus_reconciler_reconcile_seq(l07.recon);
    if (seq != l07.last_reconcile_seq) {
        l07.last_reconcile_seq = seq;
        if (colyseus_reconciler_last_correction_mag(l07.recon) > 3
            && nd_now() - l07.last_bump_at < 700) { l07.mispredicts++; }
    }

    /* --- render ------------------------------------------------------ */
    const world_view_t* v = &app->view;
    colyseus_map_schema_foreach(l07.state->players, l07_draw_remote, app);

    double bx = colyseus_predict_value(l07.predict, (colyseus_schema_t*)l07.bot, "x");
    double by = colyseus_predict_value(l07.predict, (colyseus_schema_t*)l07.bot, "y");
    draw_circle_world(v, bx, by, BOT_RADIUS, with_alpha(COL_WARN, 0.3));
    draw_circle_outline_world(v, bx, by, BOT_RADIUS, COL_WARN);
    draw_label_world(v, bx, by, "bot (reckon = hit position)", COL_WARN, 10,
        -vs(v, BOT_RADIUS) - 14);
    draw_circle_dashed_world(v, l07.bot->x, l07.bot->y, BOT_RADIUS, with_alpha(COL_TEXT, 0.45));
    draw_label_world(v, l07.bot->x, l07.bot->y, "stale snapshot", with_alpha(COL_TEXT, 0.45), 9,
        vs(v, BOT_RADIUS) + 4);

    draw_ghost_square(v, l07.me->x, l07.me->y, PLAYER_HALF, with_alpha(COL_TEXT, 0.5));
    bool flash = nd_now() - l07.bump_flash_t < 300;
    double px = colyseus_reconciler_value(l07.recon, "x");
    double py = colyseus_reconciler_value(l07.recon, "y");
    draw_square(v, px, py, PLAYER_HALF, flash ? COL_BAD : hue_color(l07.me->hue, 1));
    draw_square_outline(v, px, py, PLAYER_HALF, COL_TEXT, flash ? 2.5f : 1.0f);

    /* --- HUD --------------------------------------------------------- */
    hud_t* h = &app->hud;
    hud_section(h, "TELEMETRY");
    hud_row(h, "bumps predicted", COL_TEXT, "%d", l07.bumps_predicted);
    hud_row(h, "bumps (authoritative)", COL_TEXT, "%d", l07.me->bumps);
    hud_row(h, "mispredicts", l07.mispredicts ? COL_WARN : COL_GOOD, "%d", l07.mispredicts);
    double rate = l07.bumps_predicted ? (double)l07.mispredicts / l07.bumps_predicted * 100 : 0;
    if (l07.bumps_predicted) {
        hud_row(h, "mispredict rate", rate < 10 ? COL_GOOD : rate < 40 ? COL_WARN : COL_BAD,
            "%.0f %%", rate);
    } else {
        hud_row(h, "mispredict rate", COL_TEXT_FAINT, "--");
    }
    hud_row(h, "bump immunity (ticks)", COL_TEXT, "%d", l07.predicted->bumpTicks);

    hud_section(h, "CONTROLS");
    hud_key(h, "WASD", "graze the bot's patrol path");
    hud_key(h, "V", l07.use_value_at ? "read bot at ctx.reckonTime" : "read the STALE snapshot");
    hud_key(h, "M", l07.use_memo ? "verdict frozen with memo" : "verdict RE-DERIVED on replay");
    hud_note(h, "Raise the latency preset and graze the bot repeatedly. V off tests against "
        "a position ~RTT/2 behind where the server tests; M off lets replays re-derive the "
        "verdict against newer bot data and flip knife-edge calls. Both off is maximally wrong.");
}

static void lab07_detach(app_t* app) {
    (void)app;
    if (l07.recon) { colyseus_reconciler_free(l07.recon); }
    if (l07.predict) { colyseus_predict_free(l07.predict); }
    memset(&l07, 0, sizeof(l07));
}

static void lab07_on_reconnect(app_t* app) { (void)app; l07.rebind = true; }

static const lab_def_t LAB_07 = {
    .id = "07-wysiwyg",
    .num = 7,
    .title = "WYSIWYG Collision",
    .blurb = "valueAt(reckonTime) + ctx.memo.",
    .room_name = "lab-bump",
    .state_vtable = &bump_state_vtable,
    .attach = lab07_attach,
    .frame = lab07_frame,
    .detach = lab07_detach,
    .on_reconnect = lab07_on_reconnect,
};
