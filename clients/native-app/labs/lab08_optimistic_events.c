/*
 * Lab 08 — Optimistic Events.
 *
 * The GOAL banner fires the instant your PREDICTED square crosses the line,
 * then settles against the server:
 *
 *   predicted  colyseus_step_predict() inside the reconciler step. Fires on
 *              the LIVE step only; rollback replays never re-fire it.
 *   confirmed  the server's "goal" broadcast -> event_channel_confirm().
 *   rejected   no confirmation by the time the server processed past the
 *              predicting input -> grace-tick auto-reject -> on_reject.
 *
 * The zone gate itself is SHARED deterministic sim over a reconciled tick
 * field: whether you *entered* is never a misprediction — only the server's
 * deny roll can reject the event.
 *
 * Port of src/client/labs/08-optimistic-events/.
 */

#define L08_MAX_RECORDS 30

typedef struct {
    double predicted_at, settled_at;
    int outcome;   /* 0 pending, 1 confirmed, -1 rejected */
} l08_record_t;

static struct {
    colyseus_room_t* room;
    goal_state_t* state;
    const char* sid;

    colyseus_callbacks_t* callbacks;
    colyseus_predict_t* predict;
    colyseus_event_channel_t* goals;
    colyseus_input_handle_t* input;
    move_input_t* cmd;

    goal_player_t* me;
    colyseus_reconciler_t* recon;
    goal_player_t* predicted;
    pacer_t send_pacer;
    bool rebind;

    l08_record_t records[L08_MAX_RECORDS];
    int record_count;

    const char* banner;
    Color banner_color;
    double banner_t;
    int deny_rate;
} l08;

static void l08_push_record(double now) {
    if (l08.record_count == L08_MAX_RECORDS) {
        memmove(l08.records, l08.records + 1, sizeof(l08_record_t) * (L08_MAX_RECORDS - 1));
        l08.record_count--;
    }
    l08.records[l08.record_count].predicted_at = now;
    l08.records[l08.record_count].settled_at = 0;
    l08.records[l08.record_count].outcome = 0;
    l08.record_count++;
}

/* Settle the oldest still-pending record. */
static void l08_settle(int outcome) {
    for (int i = 0; i < l08.record_count; i++) {
        if (l08.records[i].outcome == 0) {
            l08.records[i].outcome = outcome;
            l08.records[i].settled_at = nd_now();
            return;
        }
    }
}

static void l08_on_predict(void* payload, void* userdata) {
    (void)payload; (void)userdata;
    l08_push_record(nd_now());
    l08.banner = "GOAL!";
    l08.banner_color = COL_GOOD;
    l08.banner_t = nd_now();
}

static void l08_on_confirm(void* payload, void* userdata) {
    (void)payload; (void)userdata;
    l08_settle(1);
}

static void l08_on_reject(void* payload, void* userdata) {
    (void)payload; (void)userdata;
    l08_settle(-1);
    l08.banner = "DENIED";
    l08.banner_color = COL_BAD;
    l08.banner_t = nd_now();
}

/* stepEntity + the shared score gate, with the sim-born optimistic event. */
static void l08_step(const colyseus_step_ctx_t* ctx, colyseus_schema_t* state,
    const colyseus_schema_t* command, void* userdata) {
    (void)userdata;
    goal_player_t* p = (goal_player_t*)state;
    const move_input_t* inp = (const move_input_t*)command;
    entity_state_t e = { p->x, p->y, p->vx, p->vy };
    step_entity(&e, (double)inp->moveX, (double)inp->moveY, ctx->dt);
    p->x = e.x; p->y = e.y; p->vx = e.vx; p->vy = e.vy;

    int ticks = p->scoreTicks;
    if (score_gate(p->x, p->y, &ticks)) {
        colyseus_step_predict(ctx, l08.goals, "goal", NULL);   /* live-only */
    }
    p->scoreTicks = (uint8_t)ticks;
}

static void l08_on_goal_message(colyseus_message_reader_t* reader, void* userdata) {
    (void)userdata;
    const char* sid = NULL;
    size_t len = 0;
    if (colyseus_message_reader_map_get_str(reader, "sid", &sid, &len)
        && strncmp(sid, l08.sid, len) == 0 && l08.sid[len] == '\0') {
        colyseus_event_channel_confirm(l08.goals, NULL);
    }
}

static bool l08_make_reconciler(void) {
    static const char* const FIELDS[] = { "x", "y", "vx", "vy", "scoreTicks" };
    colyseus_reconciler_options_t opts = { 0 };
    opts.smoothing = 15;
    opts.fields = FIELDS;
    opts.field_count = 5;
    l08.recon = colyseus_reconciler_create((colyseus_schema_t*)l08.me, &goal_player_vtable,
        l08.input, colyseus_room_get_clock(l08.room), l08_step, &opts);
    if (!l08.recon) { return false; }
    l08.predicted = (goal_player_t*)colyseus_reconciler_state(l08.recon);
    pacer_init(&l08.send_pacer, colyseus_reconciler_step_ms(l08.recon));
    return true;
}

static void l08_on_player_add(void* value, void* key, void* userdata) {
    (void)userdata;
    const char* sid = (const char*)key;
    if (sid && strcmp(sid, l08.sid) == 0) { return; }
    colyseus_predict_field_options_t damped = { 0 };
    damped.mode = COLYSEUS_PREDICT_DAMPED;
    colyseus_predict_track(l08.predict, (colyseus_schema_t*)value, "x", &damped);
    colyseus_predict_track(l08.predict, (colyseus_schema_t*)value, "y", &damped);
}

static void l08_on_player_remove(void* value, void* key, void* userdata) {
    (void)key; (void)userdata;
    colyseus_predict_detach(l08.predict, (colyseus_schema_t*)value);
}

static bool lab08_attach(app_t* app, colyseus_room_t* room) {
    goal_state_t* state = (goal_state_t*)colyseus_room_get_state(room);
    if (!state || !state->players) { return false; }
    const char* sid = colyseus_room_get_session_id(room);
    goal_player_t* me = (goal_player_t*)colyseus_map_schema_get(state->players, sid);
    if (!me) { return false; }

    memset(&l08, 0, sizeof(l08));
    l08.room = room;
    l08.state = state;
    l08.sid = sid;
    l08.me = me;
    l08.deny_rate = state->denyRate;

    l08.callbacks = colyseus_callbacks_create(room->serializer->decoder);
    l08.predict = colyseus_predict_create(l08.callbacks, colyseus_room_get_clock(room));
    colyseus_callbacks_on_add(l08.callbacks, state, "players", l08_on_player_add, NULL, true);
    colyseus_callbacks_on_remove(l08.callbacks, state, "players", l08_on_player_remove, NULL);

    colyseus_event_channel_options_t ch = { 0 };
    ch.on_predict = l08_on_predict;
    ch.on_confirm = l08_on_confirm;
    ch.on_reject = l08_on_reject;
    l08.goals = colyseus_event_channel_create(&ch, colyseus_room_get_clock(room));
    colyseus_room_on_message(room, "goal", l08_on_goal_message, NULL);

    l08.input = colyseus_room_input(room, &move_input_vtable, NULL);
    if (!l08.input) { return false; }
    l08.cmd = (move_input_t*)colyseus_input_handle_data(l08.input);
    (void)app;
    return l08_make_reconciler();
}

static void l08_draw_remote(const char* sid, void* value, void* userdata) {
    app_t* app = (app_t*)userdata;
    if (strcmp(sid, l08.sid) == 0) { return; }
    goal_player_t* p = (goal_player_t*)value;
    draw_square(&app->view,
        colyseus_predict_value(l08.predict, (colyseus_schema_t*)p, "x"),
        colyseus_predict_value(l08.predict, (colyseus_schema_t*)p, "y"),
        PLAYER_HALF, hue_color(p->hue, 0.4));
}

static void lab08_frame(app_t* app, double now, double dt) {
    (void)dt;
    if (l08.rebind) {
        goal_player_t* me = (goal_player_t*)colyseus_map_schema_get(l08.state->players, l08.sid);
        if (me) {
            if (l08.recon) { colyseus_reconciler_free(l08.recon); l08.recon = NULL; }
            colyseus_event_channel_clear(l08.goals);
            l08.me = me;
            l08.rebind = !l08_make_reconciler();
        }
        if (!l08.recon) { return; }
    }

    /* --- controls: the deny rate is room-wide, like the web slider ----- */
    int deny_step = app_key(KEY_EQUAL) ? 25 : app_key(KEY_MINUS) ? -25 : 0;
    if (deny_step) {
        l08.deny_rate += deny_step;
        if (l08.deny_rate < 0) { l08.deny_rate = 0; }
        if (l08.deny_rate > 100) { l08.deny_rate = 100; }
        colyseus_message_t* m = colyseus_message_map_create();
        colyseus_message_map_put_int(m, "rate", l08.deny_rate);
        colyseus_room_send(l08.room, "denyRate", m);
        colyseus_message_free(m);
    }

    colyseus_reconciler_tick(l08.recon, now);
    colyseus_predict_tick(l08.predict, now);
    colyseus_event_channel_prune(l08.goals);

    int steps = pacer_steps(&l08.send_pacer, now);
    for (int i = 0; i < steps; i++) {
        l08.cmd->moveX = (int8_t)kb_move_x();
        l08.cmd->moveY = (int8_t)kb_move_y();
        colyseus_input_handle_send(l08.input);
    }

    /* --- render ------------------------------------------------------ */
    const world_view_t* v = &app->view;
    DrawRectangleV((Vector2){ vsx(v, GOAL_ZONE_X), vsy(v, GOAL_ZONE_Y) },
        (Vector2){ vs(v, GOAL_ZONE_W), vs(v, GOAL_ZONE_H) }, with_alpha(COL_GOOD, 0.12));
    DrawRectangleLinesEx((Rectangle){ vsx(v, GOAL_ZONE_X), vsy(v, GOAL_ZONE_Y),
        vs(v, GOAL_ZONE_W), vs(v, GOAL_ZONE_H) }, 1.5f, with_alpha(COL_GOOD, 0.5));
    draw_label_world(v, GOAL_ZONE_X + GOAL_ZONE_W / 2, GOAL_ZONE_Y, "GOAL",
        with_alpha(COL_GOOD, 0.7), 10, -14);

    colyseus_map_schema_foreach(l08.state->players, l08_draw_remote, app);
    draw_ghost_square(v, l08.me->x, l08.me->y, PLAYER_HALF, with_alpha(COL_TEXT, 0.4));
    double px = colyseus_reconciler_value(l08.recon, "x");
    double py = colyseus_reconciler_value(l08.recon, "y");
    draw_square(v, px, py, PLAYER_HALF, hue_color(l08.me->hue, 1));
    draw_square_outline(v, px, py, PLAYER_HALF, COL_TEXT, 1.0f);

    if (l08.banner && nd_now() - l08.banner_t < 1400) {
        double a = 3 * (1 - (nd_now() - l08.banner_t) / 1400);
        if (a > 1) { a = 1; }
        int fw = MeasureText(l08.banner, 42);
        DrawText(l08.banner, (int)(app->stage_x + (app->stage_w - fw) / 2),
            (int)(app->stage_y + 40), 42, with_alpha(l08.banner_color, a));
    }

    /* --- HUD --------------------------------------------------------- */
    int confirmed = 0, rejected = 0, pending = 0;
    double settle_sum = 0;
    for (int i = 0; i < l08.record_count; i++) {
        if (l08.records[i].outcome == 1) {
            confirmed++;
            settle_sum += l08.records[i].settled_at - l08.records[i].predicted_at;
        } else if (l08.records[i].outcome == -1) { rejected++; }
        else { pending++; }
    }

    hud_t* h = &app->hud;
    hud_section(h, "TELEMETRY");
    hud_row(h, "score (authoritative)", COL_TEXT, "%d", l08.me->score);
    hud_row(h, "events predicted", COL_TEXT, "%d", l08.record_count);
    if (confirmed) {
        hud_row(h, "confirmed (avg settle)", COL_GOOD, "%d (%.0f ms)",
            confirmed, settle_sum / confirmed);
    } else {
        hud_row(h, "confirmed (avg settle)", COL_TEXT_FAINT, "0");
    }
    hud_row(h, "rejected", rejected ? COL_BAD : COL_TEXT, "%d", rejected);
    hud_row(h, "pending", pending ? COL_WARN : COL_TEXT, "%d", pending);

    hud_section(h, "RECENT EVENTS");
    for (int i = 0; i < 5; i++) {
        int idx = l08.record_count - 1 - i;
        if (idx < 0) { hud_row(h, TextFormat("event %d", i + 1), COL_TEXT_FAINT, "--"); continue; }
        l08_record_t* r = &l08.records[idx];
        if (r->outcome == 0) { hud_row(h, TextFormat("event %d", i + 1), COL_WARN, "pending..."); }
        else {
            hud_row(h, TextFormat("event %d", i + 1), r->outcome == 1 ? COL_GOOD : COL_BAD,
                "%s +%.0f ms", r->outcome == 1 ? "confirmed" : "rejected",
                r->settled_at - r->predicted_at);
        }
    }

    hud_section(h, "CONTROLS");
    hud_key(h, "WASD", "run into the goal zone on the right");
    hud_key(h, "- / =", TextFormat("server deny rate  %d %%", l08.deny_rate));
    hud_note(h, "The banner is optimistic - score is authoritative. Raise the deny rate "
        "and the banner goes up instantly, then retracts when the server stays silent.");
}

static void lab08_detach(app_t* app) {
    (void)app;
    if (l08.recon) { colyseus_reconciler_free(l08.recon); }
    if (l08.goals) { colyseus_event_channel_free(l08.goals); }
    if (l08.predict) { colyseus_predict_free(l08.predict); }
    if (l08.callbacks) { colyseus_callbacks_free(l08.callbacks); }
    memset(&l08, 0, sizeof(l08));
}

static void lab08_on_reconnect(app_t* app) { (void)app; l08.rebind = true; }

static const lab_def_t LAB_08 = {
    .id = "08-optimistic-events",
    .num = 8,
    .title = "Optimistic Events",
    .blurb = "Instant feedback; confirm or reject.",
    .room_name = "lab-goal",
    .state_vtable = &goal_state_vtable,
    .attach = lab08_attach,
    .frame = lab08_frame,
    .detach = lab08_detach,
    .on_reconnect = lab08_on_reconnect,
};
