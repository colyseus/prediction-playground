/*
 * Lab 10 — Composite Sim (`predict.sim` / SimReconciler).
 *
 * The flat reconciler (lab 03) mirrors fields of ONE instance. Here the puck is
 * a separate entity — yet your shots must feel instant, so the puck is
 * predicted THROUGH your own inputs: every predicted paddle step also steps the
 * puck and resolves the contact, in the server's exact order. On each ack, both
 * bound mirrors are re-seeded from authoritative state and the unacked inputs
 * replay on top — a predicted shot is re-derived from truth every reconcile.
 *
 * Remote HUMAN paddles enter the prediction as COLLIDERS at their latest
 * snapshot — their next input is unknowable until it arrives — so a contested
 * touch is the honest misprediction to watch for. The AI paddle is different
 * and is predicted in full: its steering is a pure function of synced state
 * (`bot_input`), so the client runs the server's own decision.
 *
 * Port of src/client/labs/10-composite-sim/. Where the JS version uses opaque
 * plain objects plus a custom `pose`, the C port BINDS the parts to their
 * decoded instances — the store mirrors them and derives "paddle.x" / "puck.x"
 * pose keys itself, which is the auto-binding path the fixture pins.
 */

static struct {
    colyseus_room_t* room;
    hockey_state_t* state;
    const char* sid;

    colyseus_predict_t* predict;
    colyseus_input_handle_t* input;
    move_input_t* cmd;

    player_t* me;
    player_t* bot;                   /* the AI paddle — a bound, PREDICTED part */
    colyseus_reconciler_t* sim;      /* the composite face */
    colyseus_sim_world_t* world;
    bool rebind;

    double smoothing;
    bool show_ghosts;
    trail_t puck_trail;
    spark_t drift_spark;
    double spark_gate;
    int touches;
    bool touched_last_step;
    double last_touch_t;
    /* Peak separation between the predicted puck and its server ghost — the
     * lead is transient (largest right after a strike), so a spot reading at
     * an arbitrary instant says nothing. */
    double max_puck_lead;

    /* Every reconcile's correction magnitude, for the acceptance MEDIAN. The
     * drift ema is a decaying average sampled at one instant: it falls toward
     * zero whenever the world goes quiet, which flatters exactly the runs that
     * deserve scrutiny. The median ignores the contested-HUMAN-touch tail —
     * remote humans enter the prediction at their last snapshot, so those
     * mispredict by design (the AI is predicted and does not) — while still
     * catching a step that genuinely diverged. */
    double mags[1024];
    int mag_count;
    int last_recon_seq;
} l10;

/* The server's step order, reproduced: my paddle -> puck -> contacts. */
static void l10_step(const colyseus_step_ctx_t* ctx, colyseus_sim_world_t* world,
    const colyseus_schema_t* command, void* userdata);

typedef struct {
    entity_state_t* puck;
    const entity_state_t* pad;       /* my PREDICTED paddle */
    const entity_state_t* bot;       /* the PREDICTED AI paddle */
    bool touched;
} l10_contact_ctx_t;

/* Contacts resolve in players-map iteration order — the server's order. Mine
 * and the bot's come from the PREDICTED mirrors; remote HUMANS are zero-delta
 * colliders at their last-known snapshot. */
static void l10_collide_player(const char* sid, void* value, void* userdata) {
    l10_contact_ctx_t* c = (l10_contact_ctx_t*)userdata;
    if (strcmp(sid, l10.sid) == 0) {
        if (collide_paddle_puck(c->pad->x, c->pad->y, c->pad->vx, c->pad->vy, c->puck)) {
            c->touched = true;
        }
        return;
    }
    if (strcmp(sid, HOCKEY_BOT_ID) == 0) {
        if (collide_paddle_puck(c->bot->x, c->bot->y, c->bot->vx, c->bot->vy, c->puck)) {
            c->touched = true;
        }
        return;
    }
    player_t* p = (player_t*)value;
    if (collide_paddle_puck(p->x, p->y, p->vx, p->vy, c->puck)) { c->touched = true; }
}

static void l10_step(const colyseus_step_ctx_t* ctx, colyseus_sim_world_t* world,
    const colyseus_schema_t* command, void* userdata) {
    (void)userdata;
    player_t* paddle = (player_t*)colyseus_sim_world_part(world, "paddle");
    puck_t* puck = (puck_t*)colyseus_sim_world_part(world, "puck");
    player_t* bot = (player_t*)colyseus_sim_world_part(world, "bot");
    const move_input_t* inp = (const move_input_t*)command;

    entity_state_t pad = { paddle->x, paddle->y, paddle->vx, paddle->vy };
    step_entity(&pad, (double)inp->moveX, (double)inp->moveY, ctx->dt);
    paddle->x = pad.x; paddle->y = pad.y; paddle->vx = pad.vx; paddle->vy = pad.vy;

    /* The bot steps from the PRE-step puck, exactly as the server does — its
     * paddle loop runs before step_puck. */
    entity_state_t bt = { bot->x, bot->y, bot->vx, bot->vy };
    double bmx, bmy;
    bot_input(bt.x, bt.y, puck->x, puck->y, l10.state->botEnabled, &bmx, &bmy);
    step_entity(&bt, bmx, bmy, ctx->dt);
    bot->x = bt.x; bot->y = bt.y; bot->vx = bt.vx; bot->vy = bt.vy;

    entity_state_t pk = { puck->x, puck->y, puck->vx, puck->vy };
    step_puck(&pk, ctx->dt);

    l10_contact_ctx_t c = { &pk, &pad, &bt, false };
    colyseus_map_schema_foreach(l10.state->players, l10_collide_player, &c);

    puck->x = pk.x; puck->y = pk.y; puck->vx = pk.vx; puck->vy = pk.vy;
    if (c.touched && !ctx->is_replay) { l10.touched_last_step = true; }
}

static bool l10_make_sim(void) {
    colyseus_sim_part_t parts[3] = {
        { "paddle", (colyseus_schema_t*)l10.me, &player_vtable, NULL },
        { "puck", (colyseus_schema_t*)l10.state->puck, &puck_vtable, NULL },
        { "bot", (colyseus_schema_t*)l10.bot, &player_vtable, NULL },
    };
    colyseus_sim_reconciler_options_t opts = { 0 };
    opts.parts = parts;
    opts.part_count = 3;
    opts.smoothing = l10.smoothing;
    l10.sim = colyseus_predict_sim_reconciler(l10.predict, l10.input, l10_step, &opts);
    if (!l10.sim) { return false; }
    l10.world = colyseus_sim_reconciler_world(l10.sim);
    return true;
}

static bool lab10_attach(app_t* app, colyseus_room_t* room) {
    hockey_state_t* state = (hockey_state_t*)colyseus_room_get_state(room);
    if (!state || !state->players || !state->puck) { return false; }
    const char* sid = colyseus_room_get_session_id(room);
    player_t* me = (player_t*)colyseus_map_schema_get(state->players, sid);
    player_t* bot = (player_t*)colyseus_map_schema_get(state->players, HOCKEY_BOT_ID);
    if (!me || !bot) { return false; }

    memset(&l10, 0, sizeof(l10));
    l10.room = room;
    l10.state = state;
    l10.sid = sid;
    l10.me = me;
    l10.bot = bot;
    l10.smoothing = 15;
    l10.show_ghosts = true;
    l10.last_touch_t = -1e9;
    trail_init(&l10.puck_trail, 120);
    spark_init(&l10.drift_spark);

    l10.predict = colyseus_predict_for_room(room);
    colyseus_predict_attach_all(l10.predict, (colyseus_schema_t*)state, "players",
        ATTACH_XY_DAMPED, 2, sid, NULL);

    l10.input = colyseus_room_input(room, &move_input_vtable, NULL);
    if (!l10.input) { return false; }
    l10.cmd = (move_input_t*)colyseus_input_handle_data(l10.input);
    (void)app;
    if (!l10_make_sim()) { return false; }
    app_set_latency_preset(2);   /* a predicted shot says nothing on a 1 ms link */
    return true;
}

static void l10_draw_remote(const char* sid, void* value, void* userdata) {
    app_t* app = (app_t*)userdata;
    if (strcmp(sid, l10.sid) == 0) { return; }
    player_t* p = (player_t*)value;
    double x = colyseus_predict_value(l10.predict, (colyseus_schema_t*)p, "x");
    double y = colyseus_predict_value(l10.predict, (colyseus_schema_t*)p, "y");
    draw_circle_world(&app->view, x, y, PADDLE_RADIUS, hue_color(p->hue, 0.35));
    draw_circle_outline_world(&app->view, x, y, PADDLE_RADIUS, hue_color(p->hue, 0.8));
}

static void lab10_frame(app_t* app, double now, double dt) {
    if (l10.rebind) {
        player_t* me = (player_t*)colyseus_map_schema_get(l10.state->players, l10.sid);
        player_t* bot = (player_t*)colyseus_map_schema_get(l10.state->players, HOCKEY_BOT_ID);
        if (me && bot) {
            if (l10.sim) { colyseus_reconciler_free(l10.sim); l10.sim = NULL; }
            l10.me = me;
            l10.bot = bot;
            l10.rebind = !l10_make_sim();
            trail_clear(&l10.puck_trail);
        }
        if (!l10.sim) { return; }
    }

    if (app_key(KEY_G)) { l10.show_ghosts = !l10.show_ghosts; }
    int smoothing_step = app_key(KEY_EQUAL) ? 5 : app_key(KEY_MINUS) ? -5 : 0;
    if (smoothing_step) {
        l10.smoothing += smoothing_step;
        if (l10.smoothing < 0) { l10.smoothing = 0; }
        if (l10.smoothing > 40) { l10.smoothing = 40; }
        colyseus_reconciler_free(l10.sim);
        l10_make_sim();
    }
    if (app_key(KEY_B)) {
        colyseus_message_t* m = colyseus_message_map_create();
        colyseus_message_map_put_bool(m, "on", !l10.state->botEnabled);
        colyseus_room_send(l10.room, "bot", m);
        colyseus_message_free(m);
    }


    /*
     * The acceptance script strikes and retreats: parking on the puck pins it
     * (re-colliding every step), and a pinned puck can't demonstrate the thing
     * this lab is about — a struck puck flying ahead of its server ghost.
     */
    int move_x = kb_move_x(), move_y = kb_move_y();
    if (g_autopilot) {
        player_t* pad = (player_t*)colyseus_sim_world_part(l10.world, "paddle");
        puck_t* pk = (puck_t*)colyseus_sim_world_part(l10.world, "puck");
        double dx = pk->x - pad->x, dy = pk->y - pad->y;
        int sign = (now - l10.last_touch_t < 1600) ? -1 : 1;   /* back off after a hit */
        move_x = dx > 0.5 ? sign : dx < -0.5 ? -sign : 0;
        move_y = dy > 0.5 ? sign : dy < -0.5 ? -sign : 0;
    }

    int steps = colyseus_predict_tick(l10.predict, now);
    for (int i = 0; i < steps; i++) {
        l10.cmd->moveX = (int8_t)move_x;
        l10.cmd->moveY = (int8_t)move_y;
        colyseus_input_handle_send(l10.input);
    }
    if (l10.touched_last_step) {
        l10.touched_last_step = false;
        l10.touches++;
        l10.last_touch_t = now;
    }

    /* --- render ------------------------------------------------------ */
    const world_view_t* v = &app->view;
    /* Centre line — the AI defends the top half. */
    draw_dashed_world(v, 0, ARENA_H / 2, ARENA_W, ARENA_H / 2, with_alpha(COL_TEXT_DIM, 0.25), 1.0f);

    colyseus_map_schema_foreach(l10.state->players, l10_draw_remote, app);

    /* One read idiom: the same call that reads a passively-smoothed remote
       paddle above also reads the controller-predicted pair, because the sim
       registered these instances into predict's overlay. The composite pose
       key stays inside the SDK. */
    double px = colyseus_predict_value(l10.predict, (colyseus_schema_t*)l10.me, "x");
    double py = colyseus_predict_value(l10.predict, (colyseus_schema_t*)l10.me, "y");
    double kx = colyseus_predict_value(l10.predict, (colyseus_schema_t*)l10.state->puck, "x");
    double ky = colyseus_predict_value(l10.predict, (colyseus_schema_t*)l10.state->puck, "y");

    if (l10.show_ghosts) {
        draw_circle_dashed_world(v, l10.me->x, l10.me->y, PADDLE_RADIUS, with_alpha(COL_TEXT, 0.4));
        draw_circle_dashed_world(v, l10.state->puck->x, l10.state->puck->y, PUCK_RADIUS,
            with_alpha(COL_TEXT, 0.5));
        draw_label_world(v, l10.state->puck->x, l10.state->puck->y, "server puck",
            with_alpha(COL_TEXT, 0.5), 9, vs(v, PUCK_RADIUS) + 4);
    }

    trail_push(&l10.puck_trail, kx, ky);
    trail_draw(&l10.puck_trail, v, COL_ACCENT, 1.5f, 0.5);
    draw_circle_world(v, kx, ky, PUCK_RADIUS, COL_ACCENT);
    draw_label_world(v, kx, ky, "puck (predicted)", COL_ACCENT, 10, -vs(v, PUCK_RADIUS) - 14);

    draw_circle_world(v, px, py, PADDLE_RADIUS, hue_color(l10.me->hue, 1));
    draw_circle_outline_world(v, px, py, PADDLE_RADIUS, COL_TEXT);
    draw_label_world(v, px, py, "you (predicted)", COL_TEXT, 11, -vs(v, PADDLE_RADIUS) - 14);

    /* --- HUD --------------------------------------------------------- */
    const colyseus_drift_t* drift = colyseus_reconciler_drift(l10.sim);
    /* A composite world has a higher noise floor than a flat reconciler: it
     * always adopts (no wire-precision skip) and contacts resolve a hair apart
     * on the two sides, so classify with a tolerance instead of the 1e-3 floor. */
    colyseus_drift_status_t status = colyseus_drift_classify(drift, 0.5);
    l10.spark_gate += dt;
    if (l10.spark_gate >= 100) { l10.spark_gate = 0; spark_push(&l10.drift_spark, drift->ema); }

    double puck_gap = sqrt((kx - l10.state->puck->x) * (kx - l10.state->puck->x)
        + (ky - l10.state->puck->y) * (ky - l10.state->puck->y));
    if (puck_gap > l10.max_puck_lead) { l10.max_puck_lead = puck_gap; }

    int seq = colyseus_reconciler_reconcile_seq(l10.sim);
    if (seq != l10.last_recon_seq) {
        l10.last_recon_seq = seq;
        if (l10.mag_count < (int)(sizeof(l10.mags) / sizeof(l10.mags[0]))) {
            l10.mags[l10.mag_count++] = colyseus_reconciler_last_correction_mag(l10.sim);
        }
    }

    hud_t* h = &app->hud;
    char buf[64];
    hud_section(h, "TELEMETRY");
    hud_chips(h, "pending inputs (unacked)", colyseus_reconciler_pending_count(l10.sim), 48);
    hud_row(h, "puck: predicted vs server", COL_TEXT, "%.1f u (peak %.1f)",
        puck_gap, l10.max_puck_lead);
    hud_row(h, "drift status (tol 0.5u)",
        status == COLYSEUS_DRIFT_MATCHED ? COL_GOOD
            : status == COLYSEUS_DRIFT_JITTER ? COL_WARN : COL_BAD,
        status == COLYSEUS_DRIFT_MATCHED ? "matched"
            : status == COLYSEUS_DRIFT_JITTER ? "jitter" : "diverging");
    snprintf(buf, sizeof(buf), "%.4f", drift->ema);
    hud_spark(h, &l10.drift_spark, "drift ema (whole world)", buf, COL_ACCENT, 0);
    hud_row(h, "last correction", COL_TEXT, "%.3f",
        colyseus_reconciler_last_correction_mag(l10.sim));
    hud_row(h, "your touches", COL_TEXT, "%d", l10.touches);
    hud_row(h, "reconciles", COL_TEXT, "%d", colyseus_reconciler_reconcile_seq(l10.sim));

    hud_section(h, "CONTROLS");
    hud_key(h, "WASD", "drive your paddle");
    hud_key(h, "- / =", TextFormat("smoothing  %.0f /s", l10.smoothing));
    hud_key(h, "G", l10.show_ghosts ? "server ghosts: on" : "server ghosts: off");
    hud_key(h, "B", l10.state->botEnabled ? "AI paddle: on" : "AI paddle: off");
    hud_note(h, "The puck AND the AI paddle are predicted THROUGH your inputs: every "
        "predicted step also steps the bot (its steering is a pure function of synced "
        "state) and the puck, resolving contacts in the server's order. Remote HUMANS "
        "stay colliders at their last snapshot, so a contested human touch is the "
        "honest misprediction - watch the drift spike and the ghost separate.");
}

static void lab10_detach(app_t* app) {
    (void)app;
    if (l10.sim) { colyseus_reconciler_free(l10.sim); }
    if (l10.predict) { colyseus_predict_free(l10.predict); }
    memset(&l10, 0, sizeof(l10));
}

static void lab10_on_reconnect(app_t* app) { (void)app; l10.rebind = true; }

static const lab_def_t LAB_10 = {
    .id = "10-composite-sim",
    .num = 10,
    .title = "Composite Sim",
    .blurb = "Predict a world you only partly control: paddle AND puck.",
    .room_name = "lab-hockey",
    .state_vtable = &hockey_state_vtable,
    .attach = lab10_attach,
    .frame = lab10_frame,
    .detach = lab10_detach,
    .on_reconnect = lab10_on_reconnect,
};
