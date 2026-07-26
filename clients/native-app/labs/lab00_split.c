/*
 * Lab 00 — Lag vs Prediction (the hero).
 *
 * Runs lab 03's netcode VERBATIM — same room, same reconciler, same entity.
 * The split screen is a RENDER-layer choice, not a different protocol: the top
 * lane draws the raw decoded server state (what lab 01 draws), the bottom lane
 * draws the reconciler's predicted pose (what lab 03 draws). Prediction is a
 * client-side choice over the same authority.
 *
 * Port of src/client/labs/00-split/.
 */

/* Reversal-heavy autopilot legs [dx, dy, ms] — reversals are where the echo
 * lane visibly keeps going the wrong way for a full round trip. */
static const struct { int dx, dy; double ms; } L00_SCRIPT[] = {
    { 1, 0, 850 }, { -1, 0, 700 }, { 1, 0, 550 }, { 0, 1, 650 }, { 0, -1, 700 },
    { 1, 1, 600 }, { -1, -1, 750 }, { -1, 0, 550 }, { 1, 0, 800 }, { 0, -1, 500 },
};
#define L00_SCRIPT_LEN ((int)(sizeof(L00_SCRIPT) / sizeof(L00_SCRIPT[0])))

static struct {
    bool user_drove;
    int leg_index, leg_x, leg_y;
    double leg_until;
    trail_t top_trail, bot_trail;
} l00;

static bool lab00_attach(app_t* app, colyseus_room_t* room) {
    if (!lab03_attach(app, room)) { return false; }
    memset(&l00, 0, sizeof(l00));
    l00.leg_x = 1;
    trail_init(&l00.top_trail, 120);
    trail_init(&l00.bot_trail, 120);
    /* The point of this lab is invisible on a 1 ms localhost link. */
    app_set_latency_preset(3);
    return true;
}

/* Scripted strides, steered away from a wall when a leg would hug one. */
static void l00_autopilot(double now, double x, double y) {
    if (now < l00.leg_until) { return; }
    int i = l00.leg_index++ % L00_SCRIPT_LEN;
    l00.leg_x = L00_SCRIPT[i].dx;
    l00.leg_y = L00_SCRIPT[i].dy;
    if (x > ARENA_W * 0.72 && l00.leg_x > 0) { l00.leg_x = -1; }
    else if (x < ARENA_W * 0.28 && l00.leg_x < 0) { l00.leg_x = 1; }
    if (y > ARENA_H * 0.72 && l00.leg_y > 0) { l00.leg_y = -1; }
    else if (y < ARENA_H * 0.28 && l00.leg_y < 0) { l00.leg_y = 1; }
    l00.leg_until = now + L00_SCRIPT[i].ms;
}

/* Titles sit INSIDE the arena — the lane above it is only 26 px of padding. */
static void l00_lane_title(const world_view_t* v, const char* main, const char* sub, Color c) {
    int x = (int)vsx(v, 0) + 10, y = (int)vsy(v, 0) + 8;
    DrawText(main, x, y, 12, c);
    DrawText(sub, x + MeasureText(main, 12) + 12, y + 1, 11, with_alpha(COL_TEXT_DIM, 0.75));
}

typedef struct { const world_view_t* view; bool predicted; } l00_remote_ctx_t;

static void l00_draw_remote(const char* sid, void* value, void* userdata) {
    l00_remote_ctx_t* c = (l00_remote_ctx_t*)userdata;
    if (strcmp(sid, l03.sid) == 0) { return; }
    player_t* p = (player_t*)value;
    double x = p->x, y = p->y;
    if (c->predicted) {
        x = colyseus_predict_value(l03.predict, (colyseus_schema_t*)p, "x");
        y = colyseus_predict_value(l03.predict, (colyseus_schema_t*)p, "y");
    }
    draw_square(c->view, x, y, PLAYER_HALF, hue_color(p->hue, 0.4));
}

static void lab00_frame(app_t* app, double now, double dt) {
    (void)dt;
    recon_lane_t* l = &l03;
    if (l->rebind) { lab03_frame(app, now, dt); return; }   /* shared rebind path */

    if (!l00.user_drove && kb_any_move()) { l00.user_drove = true; }
    if (!l00.user_drove) { l00_autopilot(now, l->predicted->x, l->predicted->y); }

    l03_drive(l, now,
        l00.user_drove ? kb_move_x() : l00.leg_x,
        l00.user_drove ? kb_move_y() : l00.leg_y);

    /* Two lanes stacked in the stage rect. */
    float lane_h = app->stage_h / 2;
    const float lane_pad = 22;
    world_view_t top, bot;
    view_fit(&top, app->stage_x, app->stage_y + lane_pad, app->stage_w, lane_h - lane_pad, 26);
    view_fit(&bot, app->stage_x, app->stage_y + lane_h, app->stage_w, lane_h - lane_pad, 26);

    double px = colyseus_reconciler_value(l->recon, "x");
    double py = colyseus_reconciler_value(l->recon, "y");

    /* ---- Top lane: raw server echo ---- */
    draw_arena(&top);
    l00_lane_title(&top, "SERVER ECHO", "every move waits the full round trip",
        with_alpha(COL_TEXT, 0.85));
    l00_remote_ctx_t rtop = { &top, false };
    colyseus_map_schema_foreach(l->state->players, l00_draw_remote, &rtop);
    trail_push(&l00.top_trail, l->me->x, l->me->y);
    trail_draw(&l00.top_trail, &top, with_alpha(COL_TEXT, 0.8), 1.5f, 0.35);
    draw_square(&top, l->me->x, l->me->y, PLAYER_HALF, hue_color(l->me->hue, 0.8));
    draw_square_outline(&top, l->me->x, l->me->y, PLAYER_HALF, with_alpha(COL_TEXT, 0.5), 1.0f);
    draw_label_world(&top, l->me->x, l->me->y, "you (server)", with_alpha(COL_TEXT, 0.6), 11,
        -vs(&top, PLAYER_HALF) - 15);

    /* ---- Bottom lane: predicted ---- */
    draw_arena(&bot);
    l00_lane_title(&bot, "PREDICTED", "instant - reconciled against the same server", COL_GOOD);
    l00_remote_ctx_t rbot = { &bot, true };
    colyseus_map_schema_foreach(l->state->players, l00_draw_remote, &rbot);
    trail_push(&l00.bot_trail, px, py);
    trail_draw(&l00.bot_trail, &bot, hue_color(l->me->hue, 1), 1.5f, 0.45);
    draw_square(&bot, px, py, PLAYER_HALF, hue_color(l->me->hue, 1));
    draw_square_outline(&bot, px, py, PLAYER_HALF, COL_TEXT, 1.0f);
    draw_label_world(&bot, px, py, "you (predicted)", COL_TEXT, 11, -vs(&bot, PLAYER_HALF) - 15);

    /* ---- Divider readout ---- */
    double rtt = colyseus_room_clock_smoothed_rtt(colyseus_room_get_clock(l->room));
    const char* readout = TextFormat("ROUND TRIP ~ %.0f ms", rtt);
    float divider_y = app->stage_y + lane_h;
    float cx = app->stage_x + app->stage_w / 2;
    float tw = (float)MeasureText(readout, 13);
    DrawLineV((Vector2){ app->stage_x + 24, divider_y }, (Vector2){ cx - tw / 2 - 18, divider_y },
        with_alpha(COL_TEXT_DIM, 0.25));
    DrawLineV((Vector2){ cx + tw / 2 + 18, divider_y },
        (Vector2){ app->stage_x + app->stage_w - 24, divider_y }, with_alpha(COL_TEXT_DIM, 0.25));
    DrawText(readout, (int)(cx - tw / 2), (int)divider_y - 7, 13, COL_ACCENT);

    /* ---- Caption ---- */
    const char* caption = l00.user_drove
        ? "Same keys, same server - the top lane waits, the bottom predicts."
        : "> autopilot - press WASD / arrows to take over";
    DrawText(caption, (int)(cx - MeasureText(caption, 12) / 2),
        (int)(app->stage_y + app->stage_h - 18), 12, with_alpha(COL_TEXT_DIM, 0.85));

    /* ---- HUD ---- */
    hud_t* h = &app->hud;
    hud_section(h, "TELEMETRY");
    hud_row(h, "round trip", rtt > 300 ? COL_BAD : rtt > 120 ? COL_WARN : COL_GOOD, "%.0f ms", rtt);
    double gap = sqrt((px - l->me->x) * (px - l->me->x) + (py - l->me->y) * (py - l->me->y));
    hud_row(h, "echo trails you by", COL_TEXT, "%.1f units", gap);
    hud_chips(h, "pending inputs (unacked)", colyseus_reconciler_pending_count(l->recon), 48);

    hud_section(h, "CONTROLS");
    hud_key(h, "WASD", l00.user_drove ? "drive (autopilot off)" : "take over from the autopilot");
    hud_key(h, "L", "injected latency");
    hud_note(h, "Render-only split: both lanes are the same entity in the same room, "
        "running lab 03's netcode verbatim.");
}

static void lab00_detach(app_t* app) { lab03_detach(app); }

static void lab00_on_reconnect(app_t* app) {
    lab03_on_reconnect(app);
    trail_clear(&l00.top_trail);
    trail_clear(&l00.bot_trail);
}

static const lab_def_t LAB_00 = {
    .id = "00-split",
    .num = 0,
    .title = "Lag vs Prediction",
    .blurb = "Same input, same server - the top lane waits, the bottom predicts.",
    .room_name = "lab-move",
    .state_vtable = &move_state_vtable,
    .own_arena = true,
    .attach = lab00_attach,
    .frame = lab00_frame,
    .detach = lab00_detach,
    .on_reconnect = lab00_on_reconnect,
};
