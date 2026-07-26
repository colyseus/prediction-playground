/*
 * Lab 03 — Predict & Reconcile.
 *
 * The reconciler OBSERVES the input handle: every send is predicted locally the
 * same instant (zero latency) and buffered. When the server's next patch acks
 * input N, the reconciler rewinds to the authoritative state and REPLAYS inputs
 * N+1.. through the same shared step_entity — so the predicted pose stays
 * consistent with everything the server hasn't seen yet.
 *
 * Port of src/client/labs/03-reconcile/.
 */

#define L03_MAX_ARROWS 8

typedef struct { double x0, y0, x1, y1, t; } l03_arrow_t;

typedef struct {
    colyseus_room_t* room;
    move_state_t* state;
    const char* sid;

    colyseus_callbacks_t* callbacks;
    colyseus_predict_t* predict;
    colyseus_input_handle_t* input;
    move_input_t* cmd;

    player_t* me;               /* authoritative instance (the "ghost") */
    colyseus_reconciler_t* recon;
    player_t* predicted;        /* the reconciler's mirror */

    double smoothing;
    bool render_smoothed;
    bool show_ghost;
    bool auto_snap;

    int last_reconcile_seq;
    int corrections;
    double max_corr_mag;

    l03_arrow_t arrows[L03_MAX_ARROWS];
    int arrow_count;

    trail_t predicted_trail, server_trail;
    spark_t drift_spark;
    double spark_gate;

    /* colyseus_reconciler_tick() doesn't report due steps the way the JS
     * predict.tick() does, so sends are paced locally on the adopted step. */
    pacer_t send_pacer;

    bool rebind;                /* re-resolve `me` + rebuild after a reconnect */
} recon_lane_t;

static recon_lane_t l03;

/* The SAME function the server runs — determinism is the whole contract. */
static void l03_step(const colyseus_step_ctx_t* ctx, colyseus_schema_t* state,
    const colyseus_schema_t* command, void* userdata) {
    (void)userdata;
    player_t* p = (player_t*)state;
    const move_input_t* inp = (const move_input_t*)command;
    entity_state_t e = { p->x, p->y, p->vx, p->vy };
    step_entity(&e, (double)inp->moveX, (double)inp->moveY, ctx->dt);
    p->x = e.x; p->y = e.y; p->vx = e.vx; p->vy = e.vy;
}

static bool l03_make_reconciler(recon_lane_t* l) {
    static const char* const FIELDS[] = { "x", "y", "vx", "vy" };
    colyseus_reconciler_options_t opts = { 0 };
    opts.smoothing = l->smoothing;
    opts.fields = FIELDS;
    opts.field_count = 4;
    l->recon = colyseus_reconciler_create((colyseus_schema_t*)l->me, &player_vtable,
        l->input, colyseus_room_get_clock(l->room), l03_step, &opts);
    if (!l->recon) { return false; }
    l->predicted = (player_t*)colyseus_reconciler_state(l->recon);
    l->last_reconcile_seq = 0;
    pacer_init(&l->send_pacer, colyseus_reconciler_step_ms(l->recon));
    return true;
}

/* Remote squares: damped toward the latest snapshot (their inputs are not ours
 * to predict — Lab 04 explores these modes). */
static void l03_on_player_add(void* value, void* key, void* userdata) {
    recon_lane_t* l = (recon_lane_t*)userdata;
    const char* sid = (const char*)key;
    if (sid && strcmp(sid, l->sid) == 0) { return; }
    colyseus_predict_field_options_t damped = { 0 };
    damped.mode = COLYSEUS_PREDICT_DAMPED;
    colyseus_predict_track(l->predict, (colyseus_schema_t*)value, "x", &damped);
    colyseus_predict_track(l->predict, (colyseus_schema_t*)value, "y", &damped);
}

static void l03_on_player_remove(void* value, void* key, void* userdata) {
    (void)key;
    colyseus_predict_detach(((recon_lane_t*)userdata)->predict, (colyseus_schema_t*)value);
}

static bool lab03_attach(app_t* app, colyseus_room_t* room) {
    move_state_t* state = (move_state_t*)colyseus_room_get_state(room);
    if (!state || !state->players) { return false; }
    const char* sid = colyseus_room_get_session_id(room);
    player_t* me = (player_t*)colyseus_map_schema_get(state->players, sid);
    if (!me) { return false; }

    memset(&l03, 0, sizeof(l03));
    recon_lane_t* l = &l03;
    l->room = room;
    l->state = state;
    l->sid = sid;
    l->me = me;
    l->smoothing = 15;
    l->render_smoothed = true;
    l->show_ghost = true;
    l->auto_snap = true;
    trail_init(&l->predicted_trail, 150);
    trail_init(&l->server_trail, 150);
    spark_init(&l->drift_spark);

    l->callbacks = colyseus_callbacks_create(room->serializer->decoder);
    l->predict = colyseus_predict_create(l->callbacks, colyseus_room_get_clock(room));
    colyseus_callbacks_on_add(l->callbacks, state, "players", l03_on_player_add, l, true);
    colyseus_callbacks_on_remove(l->callbacks, state, "players", l03_on_player_remove, l);

    l->input = colyseus_room_input(room, &move_input_vtable, NULL);
    if (!l->input) { return false; }
    l->cmd = (move_input_t*)colyseus_input_handle_data(l->input);

    (void)app;
    return l03_make_reconciler(l);
}

static void l03_draw_remote(const char* sid, void* value, void* userdata) {
    app_t* app = (app_t*)userdata;
    if (strcmp(sid, l03.sid) == 0) { return; }
    player_t* p = (player_t*)value;
    draw_square(&app->view,
        colyseus_predict_value(l03.predict, (colyseus_schema_t*)p, "x"),
        colyseus_predict_value(l03.predict, (colyseus_schema_t*)p, "y"),
        PLAYER_HALF, hue_color(p->hue, 0.45));
}

static void lab03_frame(app_t* app, double now, double dt) {
    recon_lane_t* l = &l03;

    /* A reconnect invalidates the truth instance and the input seq window. */
    if (l->rebind) {
        player_t* me = (player_t*)colyseus_map_schema_get(l->state->players, l->sid);
        if (me) {
            if (l->recon) { colyseus_reconciler_free(l->recon); l->recon = NULL; }
            l->me = me;
            l->rebind = !l03_make_reconciler(l);
            trail_clear(&l->predicted_trail);
            trail_clear(&l->server_trail);
            l->arrow_count = 0;
        }
        if (!l->recon) { return; }
    }

    /* --- controls ---------------------------------------------------- */
    if (app_key(KEY_I)) { colyseus_message_t* m = colyseus_message_map_create();
        colyseus_room_send(l->room, "impulse", m); colyseus_message_free(m); }
    if (app_key(KEY_T)) { colyseus_message_t* m = colyseus_message_map_create();
        colyseus_room_send(l->room, "teleport", m); colyseus_message_free(m); }
    if (app_key(KEY_V)) { l->render_smoothed = !l->render_smoothed; }
    if (app_key(KEY_G)) { l->show_ghost = !l->show_ghost; }
    if (app_key(KEY_N)) { l->auto_snap = !l->auto_snap; }
    int smoothing_step = app_key(KEY_EQUAL) ? 5 : app_key(KEY_MINUS) ? -5 : 0;
    if (smoothing_step != 0) {
        l->smoothing += smoothing_step;
        if (l->smoothing < 0) { l->smoothing = 0; }
        if (l->smoothing > 40) { l->smoothing = 40; }
        /* The reconciler takes smoothing at construction — rebuild it, exactly
         * like the web slider's onCommit. */
        colyseus_reconciler_free(l->recon);
        l03_make_reconciler(l);
    }

    /* 1. Drive the whole prediction stack; returns the due fixed steps. */
    colyseus_reconciler_tick(l->recon, now);
    colyseus_predict_tick(l->predict, now);

    /* 2. One input per step — mutate the handle, send; the reconciler observes
     *    each send and predicts it immediately. */
    int steps = pacer_steps(&l->send_pacer, now);
    for (int i = 0; i < steps; i++) {
        l->cmd->moveX = (int8_t)kb_move_x();
        l->cmd->moveY = (int8_t)kb_move_y();
        colyseus_input_handle_send(l->input);
    }

    /* 3. Reconcile telemetry (a fresh reconcile bumps reconcile_seq). */
    int seq = colyseus_reconciler_reconcile_seq(l->recon);
    if (seq != l->last_reconcile_seq) {
        l->last_reconcile_seq = seq;
        double mag = colyseus_reconciler_last_correction_mag(l->recon);
        if (mag > 0.02) {
            l->corrections++;
            if (mag > l->max_corr_mag) { l->max_corr_mag = mag; }
            double cx = colyseus_reconciler_last_correction(l->recon, "x");
            double cy = colyseus_reconciler_last_correction(l->recon, "y");
            if (l->arrow_count == L03_MAX_ARROWS) {
                memmove(l->arrows, l->arrows + 1, sizeof(l03_arrow_t) * (L03_MAX_ARROWS - 1));
                l->arrow_count--;
            }
            l->arrows[l->arrow_count++] = (l03_arrow_t){
                l->predicted->x - cx, l->predicted->y - cy,
                l->predicted->x, l->predicted->y, now };
        }
        if (l->auto_snap && mag > TELEPORT_SNAP_DIST) {
            colyseus_reconciler_reset(l->recon);
            trail_clear(&l->predicted_trail);
            trail_clear(&l->server_trail);
        }
    }

    /* --- render ------------------------------------------------------ */
    const world_view_t* v = &app->view;
    colyseus_map_schema_foreach(l->state->players, l03_draw_remote, app);

    /* Server ghost: the raw authoritative pose — it trails by ~RTT. */
    if (l->show_ghost) {
        trail_push(&l->server_trail, l->me->x, l->me->y);
        trail_draw(&l->server_trail, v, COL_TEXT, 1.0f, 0.3);
        draw_ghost_square(v, l->me->x, l->me->y, PLAYER_HALF, with_alpha(COL_TEXT, 0.75));
        draw_label_world(v, l->me->x, l->me->y, "server", with_alpha(COL_TEXT, 0.55), 11,
            vs(v, PLAYER_HALF) + 5);
    }

    double px = l->render_smoothed ? colyseus_reconciler_value(l->recon, "x") : l->predicted->x;
    double py = l->render_smoothed ? colyseus_reconciler_value(l->recon, "y") : l->predicted->y;
    trail_push(&l->predicted_trail, px, py);
    trail_draw(&l->predicted_trail, v, hue_color(l->me->hue, 1), 1.5f, 0.45);
    draw_square(v, px, py, PLAYER_HALF, hue_color(l->me->hue, 1));
    draw_square_outline(v, px, py, PLAYER_HALF, COL_TEXT, 1.0f);
    draw_label_world(v, px, py, "you (predicted)", COL_TEXT, 11, -vs(v, PLAYER_HALF) - 15);

    /* Correction arrows fade out over 900 ms. */
    for (int i = l->arrow_count - 1; i >= 0; i--) {
        double age = now - l->arrows[i].t;
        if (age > 900) {
            memmove(&l->arrows[i], &l->arrows[i + 1],
                sizeof(l03_arrow_t) * (size_t)(l->arrow_count - i - 1));
            l->arrow_count--;
            continue;
        }
        draw_arrow_world(v, l->arrows[i].x0, l->arrows[i].y0, l->arrows[i].x1, l->arrows[i].y1,
            with_alpha(COL_BAD, 1 - age / 900), 2);
    }

    /* --- HUD --------------------------------------------------------- */
    const colyseus_drift_t* drift = colyseus_reconciler_drift(l->recon);
    colyseus_drift_status_t status = colyseus_drift_classify(drift, 0);
    l->spark_gate += dt;
    if (l->spark_gate >= 100) { l->spark_gate = 0; spark_push(&l->drift_spark, drift->ema); }

    hud_t* h = &app->hud;
    char buf[64];
    hud_section(h, "TELEMETRY");
    hud_chips(h, "pending inputs (unacked)", colyseus_reconciler_pending_count(l->recon), 48);
    hud_row(h, "drift status",
        status == COLYSEUS_DRIFT_MATCHED ? COL_GOOD
            : status == COLYSEUS_DRIFT_JITTER ? COL_WARN : COL_BAD,
        status == COLYSEUS_DRIFT_MATCHED ? "matched"
            : status == COLYSEUS_DRIFT_JITTER ? "jitter" : "diverging");
    snprintf(buf, sizeof(buf), "%.4f", drift->ema);
    hud_spark(h, &l->drift_spark, "drift ema", buf, COL_ACCENT, 0);
    hud_row(h, "last correction", COL_TEXT, "%.3f",
        colyseus_reconciler_last_correction_mag(l->recon));
    hud_row(h, "corrections seen", COL_TEXT, "%d", l->corrections);
    hud_row(h, "reconciles", COL_TEXT, "%d", seq);

    hud_section(h, "CONTROLS");
    hud_key(h, "WASD", "drive");
    hud_key(h, "I", "force mispredict (impulse)");
    hud_key(h, "T", "teleport");
    hud_key(h, "- / =", TextFormat("smoothing  %.0f /s", l->smoothing));
    hud_key(h, "V", l->render_smoothed ? "render: value() smoothed" : "render: state (exact)");
    hud_key(h, "G", l->show_ghost ? "server ghost: on" : "server ghost: off");
    hud_key(h, "N", l->auto_snap ? "snap on teleport: on" : "snap on teleport: off");
    hud_note(h, "Corrections beyond 8u call reconciler_reset() - a cut, not a cross-arena "
        "glide. Turn it off with N and teleport to see why.");
}

static void lab03_detach(app_t* app) {
    (void)app;
    recon_lane_t* l = &l03;
    if (l->recon) { colyseus_reconciler_free(l->recon); }
    if (l->predict) { colyseus_predict_free(l->predict); }
    if (l->callbacks) { colyseus_callbacks_free(l->callbacks); }
    memset(l, 0, sizeof(*l));
}

static void lab03_on_reconnect(app_t* app) {
    (void)app;
    /* Fresh connection = fresh input counter: drop the stale prediction backlog
     * and re-seed from authoritative state (the truth instance may be new too). */
    l03.rebind = true;
}

static const lab_def_t LAB_03 = {
    .id = "03-reconcile",
    .num = 3,
    .title = "Predict & Reconcile",
    .blurb = "Rollback to the ack, replay pending inputs, smooth the error.",
    .room_name = "lab-move",
    .state_vtable = &move_state_vtable,
    .attach = lab03_attach,
    .frame = lab03_frame,
    .detach = lab03_detach,
    .on_reconnect = lab03_on_reconnect,
};
