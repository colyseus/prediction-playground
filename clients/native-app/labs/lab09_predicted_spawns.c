/*
 * Lab 09 — Predicted Spawns.
 *
 * Click-to-fire feels instant because the client spawns an OPTIMISTIC local
 * projectile the same frame; when the server's authoritative entity arrives
 * (~RTT later) the store CORRELATES the two into one logical entry — same id,
 * same sprite, no visual seam.
 *
 *   owned      which server entities are mine to correlate (owner == me).
 *              Foreign ones (the turret's) surface as server-only entries.
 *   spawn_time measures each shot's exact input lead (bornMs - predictedAt),
 *              so MY projectile keeps flying the shooter's timeline through
 *              the handoff instead of snapping back by lead x velocity.
 *   step       the SAME shared flight function the server integrates.
 *
 * Port of src/client/labs/09-predicted-spawns/.
 *
 * One porting note: the C spawn store exposes no entry ITERATOR and no
 * value() overlay (the JS `projectiles.entries()` / `.value(e, "x")`), so the
 * app keeps its own id list — fed by spawn() and by the collection's onAdd —
 * and reads the local struct while pending, the server instance once
 * confirmed. Same render path, one lookup deeper.
 */

#define L09_MAX_ENTRIES 128

typedef struct { int id; bool was_pending; double flash_t; } l09_slot_t;

static struct {
    colyseus_room_t* room;
    projectile_state_t* state;
    const char* sid;

    colyseus_callbacks_t* callbacks;
    colyseus_predict_t* predict;
    colyseus_spawns_t* spawns;
    colyseus_input_handle_t* input;
    range_input_t* cmd;

    player_t* me;
    colyseus_reconciler_t* recon;
    player_t* predicted;
    pacer_t send_pacer;
    bool rebind;

    l09_slot_t slots[L09_MAX_ENTRIES];
    int slot_count;

    double aim_x, aim_y;
    bool pending_fire;
    bool optimistic;
    double last_lead_ms;
    int fired;
} l09;

static void l09_track(int id) {
    if (id <= 0) { return; }
    for (int i = 0; i < l09.slot_count; i++) { if (l09.slots[i].id == id) { return; } }
    if (l09.slot_count == L09_MAX_ENTRIES) { return; }
    l09.slots[l09.slot_count].id = id;
    l09.slots[l09.slot_count].was_pending = false;
    l09.slots[l09.slot_count].flash_t = -1e9;
    l09.slot_count++;
}

static bool l09_owned(colyseus_schema_t* server, void* userdata) {
    (void)userdata;
    projectile_t* p = (projectile_t*)server;
    return p->owner != NULL && strcmp(p->owner, l09.sid) == 0;
}

static double l09_spawn_time(colyseus_schema_t* server, void* userdata) {
    (void)userdata;
    return ((projectile_t*)server)->bornMs;
}

static void l09_local_step(void* local, double dt, void* userdata) {
    (void)userdata;
    step_projectile((entity_state_t*)local, dt);
}

static void l09_spawns_on_add(void* value, void* key, void* userdata) {
    (void)key; (void)userdata;
    colyseus_spawns_handle_add(l09.spawns, (colyseus_schema_t*)value);
    const colyseus_spawn_entry_t* e =
        colyseus_spawns_entry_for(l09.spawns, (colyseus_schema_t*)value);
    if (e) { l09_track(e->id); }
}

static void l09_spawns_on_remove(void* value, void* key, void* userdata) {
    (void)key; (void)userdata;
    colyseus_spawns_handle_remove(l09.spawns, (colyseus_schema_t*)value);
}

static void l09_on_player_add(void* value, void* key, void* userdata) {
    (void)userdata;
    const char* sid = (const char*)key;
    if (sid && strcmp(sid, l09.sid) == 0) { return; }
    colyseus_predict_field_options_t damped = { 0 };
    damped.mode = COLYSEUS_PREDICT_DAMPED;
    colyseus_predict_track(l09.predict, (colyseus_schema_t*)value, "x", &damped);
    colyseus_predict_track(l09.predict, (colyseus_schema_t*)value, "y", &damped);
}

static void l09_on_player_remove(void* value, void* key, void* userdata) {
    (void)key; (void)userdata;
    colyseus_predict_detach(l09.predict, (colyseus_schema_t*)value);
}

static void l09_step(const colyseus_step_ctx_t* ctx, colyseus_schema_t* state,
    const colyseus_schema_t* command, void* userdata) {
    (void)userdata;
    player_t* p = (player_t*)state;
    const range_input_t* inp = (const range_input_t*)command;
    entity_state_t e = { p->x, p->y, p->vx, p->vy };
    step_entity(&e, (double)inp->moveX, (double)inp->moveY, ctx->dt);
    p->x = e.x; p->y = e.y; p->vx = e.vx; p->vy = e.vy;
}

static bool l09_make_reconciler(void) {
    static const char* const FIELDS[] = { "x", "y", "vx", "vy" };
    colyseus_reconciler_options_t opts = { 0 };
    opts.smoothing = 15;
    opts.fields = FIELDS;
    opts.field_count = 4;
    l09.recon = colyseus_reconciler_create((colyseus_schema_t*)l09.me, &player_vtable,
        l09.input, colyseus_room_get_clock(l09.room), l09_step, &opts);
    if (!l09.recon) { return false; }
    l09.predicted = (player_t*)colyseus_reconciler_state(l09.recon);
    pacer_init(&l09.send_pacer, colyseus_reconciler_step_ms(l09.recon));
    return true;
}

static bool lab09_attach(app_t* app, colyseus_room_t* room) {
    projectile_state_t* state = (projectile_state_t*)colyseus_room_get_state(room);
    if (!state || !state->players || !state->projectiles) { return false; }
    const char* sid = colyseus_room_get_session_id(room);
    player_t* me = (player_t*)colyseus_map_schema_get(state->players, sid);
    if (!me) { return false; }

    memset(&l09, 0, sizeof(l09));
    l09.room = room;
    l09.state = state;
    l09.sid = sid;
    l09.me = me;
    l09.optimistic = true;
    l09.aim_x = 50;
    l09.aim_y = 20;
    l09.last_lead_ms = NAN;

    l09.callbacks = colyseus_callbacks_create(room->serializer->decoder);
    l09.predict = colyseus_predict_create(l09.callbacks, colyseus_room_get_clock(room));
    colyseus_callbacks_on_add(l09.callbacks, state, "players", l09_on_player_add, NULL, true);
    colyseus_callbacks_on_remove(l09.callbacks, state, "players", l09_on_player_remove, NULL);

    colyseus_spawns_options_t sp = { 0 };
    sp.owned = l09_owned;
    sp.spawn_time = l09_spawn_time;
    sp.has_spawn_time = true;
    sp.step = l09_local_step;
    sp.local_free = free;
    l09.spawns = colyseus_spawns_create(&sp, colyseus_room_get_clock(room));
    colyseus_callbacks_on_add(l09.callbacks, state, "projectiles", l09_spawns_on_add, NULL, true);
    colyseus_callbacks_on_remove(l09.callbacks, state, "projectiles", l09_spawns_on_remove, NULL);

    l09.input = colyseus_room_input(room, &range_input_vtable, NULL);
    if (!l09.input) { return false; }
    l09.cmd = (range_input_t*)colyseus_input_handle_data(l09.input);
    (void)app;
    return l09_make_reconciler();
}

static void l09_draw_remote(const char* sid, void* value, void* userdata) {
    app_t* app = (app_t*)userdata;
    if (strcmp(sid, l09.sid) == 0) { return; }
    player_t* p = (player_t*)value;
    draw_square(&app->view,
        colyseus_predict_value(l09.predict, (colyseus_schema_t*)p, "x"),
        colyseus_predict_value(l09.predict, (colyseus_schema_t*)p, "y"),
        PLAYER_HALF, hue_color(p->hue, 0.4));
}

static void lab09_frame(app_t* app, double now, double dt) {
    (void)dt;
    if (l09.rebind) {
        player_t* me = (player_t*)colyseus_map_schema_get(l09.state->players, l09.sid);
        if (me) {
            if (l09.recon) { colyseus_reconciler_free(l09.recon); l09.recon = NULL; }
            colyseus_spawns_clear(l09.spawns);
            l09.slot_count = 0;
            l09.me = me;
            l09.rebind = !l09_make_reconciler();
        }
        if (!l09.recon) { return; }
    }

    const world_view_t* v = &app->view;

    /* --- aim + fire --------------------------------------------------- */
    Vector2 mouse = GetMousePosition();
    bool over_stage = mouse.x < app->stage_x + app->stage_w;
    if (over_stage && !g_autopilot) {   /* the acceptance script aims for itself */
        l09.aim_x = vwx(v, mouse.x);
        l09.aim_y = vwy(v, mouse.y);
    }
    if (IsMouseButtonPressed(MOUSE_BUTTON_LEFT) && over_stage) { l09.pending_fire = true; }
    if (app_key(KEY_SPACE)) { l09.pending_fire = true; }
    if (app_key(KEY_O)) { l09.optimistic = !l09.optimistic; }

    colyseus_reconciler_tick(l09.recon, now);
    colyseus_predict_tick(l09.predict, now);
    colyseus_spawns_tick(l09.spawns, now);
    colyseus_spawns_prune(l09.spawns);

    int steps = pacer_steps(&l09.send_pacer, now);
    for (int i = 0; i < steps; i++) {
        l09.cmd->moveX = (int8_t)kb_move_x();
        l09.cmd->moveY = (int8_t)kb_move_y();
        l09.cmd->aimX = (float)l09.aim_x;
        l09.cmd->aimY = (float)l09.aim_y;
        l09.cmd->fire = l09.pending_fire;
        colyseus_input_handle_send(l09.input);
        if (l09.pending_fire) {
            l09.fired++;
            if (l09.optimistic) {
                /* Spawn the optimistic local at the PREDICTED pose — the same
                 * origin the server will use once this input arrives. */
                double px = l09.predicted->x, py = l09.predicted->y;
                double dx = l09.aim_x - px, dy = l09.aim_y - py;
                double len = sqrt(dx * dx + dy * dy);
                if (len < 1e-9) { len = 1; }
                entity_state_t* local = (entity_state_t*)malloc(sizeof(entity_state_t));
                local->x = px;
                local->y = py;
                local->vx = dx / len * PROJECTILE_SPEED;
                local->vy = dy / len * PROJECTILE_SPEED;
                l09_track(colyseus_spawns_spawn(l09.spawns, local));
            }
            l09.pending_fire = false;
        }
    }

    /* --- render ------------------------------------------------------ */
    draw_square(v, 50, 8, 2, with_alpha(COL_BAD, 0.3));
    draw_square_outline(v, 50, 8, 2, COL_BAD, 1.5f);
    draw_label_world(v, 50, 8, "turret (foreign shots)", COL_BAD, 10, -vs(v, 2) - 16);

    colyseus_map_schema_foreach(l09.state->players, l09_draw_remote, app);
    draw_square(v, colyseus_reconciler_value(l09.recon, "x"),
        colyseus_reconciler_value(l09.recon, "y"), PLAYER_HALF, hue_color(l09.me->hue, 1));
    draw_square_outline(v, colyseus_reconciler_value(l09.recon, "x"),
        colyseus_reconciler_value(l09.recon, "y"), PLAYER_HALF, COL_TEXT, 1.0f);
    draw_marker_world(v, l09.aim_x, l09.aim_y, 0.8, with_alpha(COL_TEXT, 0.6));

    /* One render path across the handoff, keyed on the stable entry id. */
    int n_pending = 0, n_confirmed = 0, n_foreign = 0;
    for (int i = l09.slot_count - 1; i >= 0; i--) {
        const colyseus_spawn_entry_t* e = colyseus_spawns_entry(l09.spawns, l09.slots[i].id);
        if (!e) {
            memmove(&l09.slots[i], &l09.slots[i + 1],
                sizeof(l09_slot_t) * (size_t)(l09.slot_count - i - 1));
            l09.slot_count--;
            continue;
        }
        double x, y;
        if (!e->confirmed) {
            entity_state_t* local = (entity_state_t*)e->local;
            if (!local) { continue; }
            x = local->x; y = local->y;
            n_pending++;
            l09.slots[i].was_pending = true;
            draw_circle_world(v, x, y, PROJECTILE_RADIUS, with_alpha(COL_WARN, 0.9));
            continue;
        }
        projectile_t* srv = (projectile_t*)e->server;
        if (!srv) { continue; }
        x = srv->x; y = srv->y;
        n_confirmed++;
        bool mine = srv->owner != NULL && strcmp(srv->owner, l09.sid) == 0;
        if (!mine) { n_foreign++; }
        if (l09.slots[i].was_pending) {
            l09.slots[i].was_pending = false;
            l09.slots[i].flash_t = now;
            if (e->lead_ms > 0) { l09.last_lead_ms = e->lead_ms; }
        }
        bool flashing = now - l09.slots[i].flash_t < 350;
        draw_circle_world(v, x, y, PROJECTILE_RADIUS * (flashing ? 1.8 : 1.0),
            mine ? with_alpha(COL_TEXT, 0.95) : with_alpha(COL_BAD, 0.9));
    }

    /* --- HUD --------------------------------------------------------- */
    hud_t* h = &app->hud;
    hud_section(h, "TELEMETRY");
    hud_row(h, "pending (mine, unconfirmed)", n_pending ? COL_WARN : COL_TEXT, "%d", n_pending);
    hud_row(h, "confirmed entities", COL_TEXT, "%d", n_confirmed);
    hud_row(h, "of those, foreign", COL_TEXT, "%d", n_foreign);
    if (isnan(l09.last_lead_ms)) { hud_row(h, "last measured input lead", COL_TEXT_FAINT, "--"); }
    else { hud_row(h, "last measured input lead", COL_GOOD, "%.0f ms", l09.last_lead_ms); }
    hud_row(h, "shots fired", COL_TEXT, "%d", l09.fired);

    hud_section(h, "CONTROLS");
    hud_key(h, "WASD", "drive");
    hud_key(h, "mouse", "aim");
    hud_key(h, "click / SPACE", "fire");
    hud_key(h, "O", l09.optimistic ? "optimistic spawn: on" : "optimistic spawn: OFF");
    hud_note(h, "Amber = predicted local (pending) - white = confirmed (correlated) - "
        "red = foreign (the turret's; nobody predicted them). Turn optimistic off with O "
        "and your own shot only appears when the server's entity arrives, ~RTT late.");
}

static void lab09_detach(app_t* app) {
    (void)app;
    if (l09.recon) { colyseus_reconciler_free(l09.recon); }
    if (l09.spawns) { colyseus_spawns_free(l09.spawns); }
    if (l09.predict) { colyseus_predict_free(l09.predict); }
    if (l09.callbacks) { colyseus_callbacks_free(l09.callbacks); }
    memset(&l09, 0, sizeof(l09));
}

static void lab09_on_reconnect(app_t* app) { (void)app; l09.rebind = true; }

static const lab_def_t LAB_09 = {
    .id = "09-predicted-spawns",
    .num = 9,
    .title = "Predicted Spawns",
    .blurb = "Optimistic projectile -> authoritative handoff.",
    .room_name = "lab-projectile",
    .state_vtable = &projectile_state_vtable,
    .attach = lab09_attach,
    .frame = lab09_frame,
    .detach = lab09_detach,
    .on_reconnect = lab09_on_reconnect,
};
