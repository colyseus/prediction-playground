/*
 * Lab 02 — Clocks & Timelines.
 *
 * There is no clock "API call" to make: the moment the server room declares
 * defineInput(), every input round-trip carries a TIMED prefix and the SDK
 * maintains room.clock for you. This lab just reads it:
 *
 *   colyseus_room_clock_now()          raw local clock
 *   colyseus_room_clock_server_now()   estimated CURRENT server time
 *   colyseus_room_clock_render_now()   serverNow with a slew limit (tau~250ms)
 *   rtt() / smoothed_rtt() / jitter() / last_server_time()
 *
 * Port of src/client/labs/02-clocks/.
 */

#define L02_STRIP_SPAN 3000.0
#define L02_MAX_ARRIVALS 128

static struct {
    colyseus_room_t* room;
    colyseus_room_clock_t* clock;
    colyseus_input_handle_t* input;
    move_input_t* cmd;
    bots_state_t* state;
    const char* sid;
    bot_t* bot;

    pacer_t pacer;

    double arrivals[L02_MAX_ARRIVALS];
    int arrival_count;
    double last_patch_stamp;

    spark_t rtt_spark, age_spark, slew_spark;
    double spark_gate;
} l02;

static bool lab02_attach(app_t* app, colyseus_room_t* room) {
    bots_state_t* state = (bots_state_t*)colyseus_room_get_state(room);
    if (!state || !state->players || !state->bots) { return false; }
    const char* sid = colyseus_room_get_session_id(room);
    bot_t* bot = (bot_t*)colyseus_map_schema_get(state->bots, "bot1");
    if (!bot || !colyseus_map_schema_get(state->players, sid)) { return false; }

    memset(&l02, 0, sizeof(l02));
    l02.room = room;
    l02.state = state;
    l02.sid = sid;
    l02.bot = bot;
    l02.clock = colyseus_room_get_clock(room);
    /* Inputs feed the clock: one send per fixed tick = one RTT/offset sample. */
    l02.input = colyseus_room_input(room, &move_input_vtable, NULL);
    if (!l02.input) { return false; }
    l02.cmd = (move_input_t*)colyseus_input_handle_data(l02.input);
    pacer_init(&l02.pacer, 1000.0 / TICK_HZ);
    spark_init(&l02.rtt_spark);
    spark_init(&l02.age_spark);
    spark_init(&l02.slew_spark);
    (void)app;
    return true;
}

static void l02_draw_player(const char* sid, void* value, void* userdata) {
    app_t* app = (app_t*)userdata;
    player_t* p = (player_t*)value;
    draw_square(&app->view, p->x, p->y, PLAYER_HALF,
        hue_color(p->hue, strcmp(sid, l02.sid) == 0 ? 0.9 : 0.4));
}

static void lab02_frame(app_t* app, double now, double dt) {
    (void)dt;
    int steps = pacer_steps(&l02.pacer, now);
    for (int i = 0; i < steps; i++) {
        l02.cmd->moveX = (int8_t)kb_move_x();
        l02.cmd->moveY = (int8_t)kb_move_y();
        colyseus_input_handle_send(l02.input);
    }

    /* A patch arrival = the server stamp changing. */
    double stamp = colyseus_room_clock_last_server_time(l02.clock);
    if (stamp != l02.last_patch_stamp) {
        l02.last_patch_stamp = stamp;
        if (l02.arrival_count == L02_MAX_ARRIVALS) {
            memmove(l02.arrivals, l02.arrivals + 1, sizeof(double) * (L02_MAX_ARRIVALS - 1));
            l02.arrival_count--;
        }
        l02.arrivals[l02.arrival_count++] = now;
    }

    double s_now = colyseus_room_clock_server_now(l02.clock);
    double r_now = colyseus_room_clock_render_now(l02.clock);

    const world_view_t* v = &app->view;
    colyseus_map_schema_foreach(l02.state->players, l02_draw_player, app);
    draw_circle_dashed_world(v, l02.bot->x, l02.bot->y, BOT_RADIUS, COL_TEXT);
    draw_label_world(v, l02.bot->x, l02.bot->y, "raw snapshots (patch rate)",
        with_alpha(COL_TEXT, 0.6), 10, -vs(v, BOT_RADIUS) - 14);

    /* Patch-arrival strip along the bottom of the stage. */
    float x0 = app->stage_x + 24, x1 = app->stage_x + app->stage_w - 20;
    float y = app->stage_y + app->stage_h - 34;
    if (x1 - x0 > 200) {
        DrawLineV((Vector2){ x0, y }, (Vector2){ x1, y }, with_alpha(COL_TEXT_DIM, 0.3));
        for (int i = 0; i < l02.arrival_count; i++) {
            double age = now - l02.arrivals[i];
            if (age > L02_STRIP_SPAN) { continue; }
            float px = x1 - (float)(age / L02_STRIP_SPAN) * (x1 - x0);
            DrawCircleV((Vector2){ px, y }, 2.5f, COL_GOOD);
        }
        DrawText("patch arrivals (local clock, last 3 s) ->", (int)x0, (int)y - 14, 10,
            with_alpha(COL_TEXT, 0.55));
    }

    /* Throttle the trend sparks to ~5 Hz so they read as trends, not noise. */
    l02.spark_gate += dt;
    if (l02.spark_gate >= 200) {
        l02.spark_gate = 0;
        spark_push(&l02.rtt_spark, colyseus_room_clock_rtt(l02.clock));
        spark_push(&l02.slew_spark, fabs(s_now - r_now));
    }
    spark_push(&l02.age_spark, fmax(0, s_now - stamp));

    hud_t* h = &app->hud;
    char buf[64];
    hud_section(h, "TELEMETRY");
    snprintf(buf, sizeof(buf), "%.0f ms", spark_last(&l02.rtt_spark));
    hud_spark(h, &l02.rtt_spark, "rtt", buf, COL_BLUE, 0);
    snprintf(buf, sizeof(buf), "%.0f ms", spark_last(&l02.age_spark));
    hud_spark(h, &l02.age_spark, "patch age (sawtooth)", buf, COL_GOOD, 0);
    snprintf(buf, sizeof(buf), "%.1f ms", spark_last(&l02.slew_spark));
    hud_spark(h, &l02.slew_spark, "|serverNow - renderNow| (slew)", buf, COL_WARN, 0);
    /* The web prints serverNow - performance.now(); the C clock's local base is
     * monotonic-since-BOOT, so that subtraction is meaningless here. Show the
     * two server-axis timelines themselves — the pair the lab is actually about. */
    hud_row(h, "serverNow", COL_TEXT, "%.0f ms", s_now);
    hud_row(h, "renderNow (slewed)", COL_TEXT, "%.0f ms", r_now);
    hud_row(h, "jitter (interarrival)", COL_TEXT, "%.1f ms",
        colyseus_room_clock_jitter(l02.clock));
    hud_row(h, "smoothed rtt", COL_TEXT, "%.0f ms",
        colyseus_room_clock_smoothed_rtt(l02.clock));
    hud_row(h, "patch interval", COL_TEXT, "%.0f ms",
        colyseus_room_clock_patch_interval(l02.clock));

    hud_section(h, "CONTROLS");
    hud_key(h, "WASD", "drive");
    hud_note(h, "Nothing to configure here - yank the latency preset with L and watch "
        "every readout respond. The offset re-converges; the slew spike decays over "
        "~250 ms. The dot row marks each PATCH ARRIVAL on the local clock: add jitter "
        "and watch the spacing get ragged.");
}

static void lab02_detach(app_t* app) { (void)app; memset(&l02, 0, sizeof(l02)); }

static void lab02_on_reconnect(app_t* app) {
    (void)app;
    pacer_reset(&l02.pacer);
    l02.arrival_count = 0;
    l02.last_patch_stamp = 0;
    /* The bot instance survives a reconnect only if the decoder reused the ref;
     * re-resolve so a fresh full-sync can't leave us pointing at freed state. */
    l02.bot = (bot_t*)colyseus_map_schema_get(l02.state->bots, "bot1");
}

static const lab_def_t LAB_02 = {
    .id = "02-clocks",
    .num = 2,
    .title = "Clocks & Timelines",
    .blurb = "serverNow / renderNow / RTT / jitter.",
    .room_name = "lab-bots",
    .state_vtable = &bots_state_vtable,
    .attach = lab02_attach,
    .frame = lab02_frame,
    .detach = lab02_detach,
    .on_reconnect = lab02_on_reconnect,
};
