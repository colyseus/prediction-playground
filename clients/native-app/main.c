/*
 * Colyseus Prediction Playground — native app (C + raylib).
 *
 * The interactive twin of clients/native/predict_probe.c: the probe proves the
 * predict layer is CORRECT, this proves it's usable — real rendering, keyboard
 * input, a telemetry HUD and a latency injector, against the same server
 * (`pnpm dev --host 0.0.0.0`).
 *
 * Build: registered as `predict_playground` in native-sdk/build.zig (present
 * only when this repo sits next to native-sdk). Run:
 *   cd native-sdk && zig build && ./zig-out/bin/predict_playground [port]
 *
 * Single translation unit on purpose: schema-codegen emits `static` vtables per
 * header, so one TU is what keeps every lab pointing at the SAME vtable object.
 */
#include <math.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "raylib.h"

#include "colyseus/client.h"
#include "colyseus/schema.h"
#include "colyseus/room.h"
#include "colyseus/room_clock.h"
#include "colyseus/input_handle.h"
#include "colyseus/schema/callbacks.h"
#include "colyseus/schema/collections.h"
#include "colyseus/predict/predict.h"
#include "colyseus/predict/reconciler.h"

#include "colyseus/predict/events.h"
#include "colyseus/predict/spawns.h"

#include "schema/move_state.h"
#include "schema/move_input.h"
#include "schema/bots_state.h"
#include "schema/goal_state.h"
#include "schema/projectile_state.h"
#include "schema/range_state.h"
#include "schema/range_input.h"
#include "schema/bump_state.h"

#include "sim.h"
#include "view.h"
#include "hud.h"
#include "net_delay.h"
#include "app.h"

/* Labs are #included, not linked — see the single-TU note above. Order matters
 * only where one lab builds on another: 00 is 03's netcode behind a split. */
#include "labs/lab01_feel_the_lag.c"
#include "labs/lab02_clocks.c"
#include "labs/lab03_reconcile.c"
#include "labs/lab00_split.c"
#include "labs/lab04_interp_modes.c"
#include "labs/lab05_dead_reckoning.c"
#include "labs/lab06_lag_comp.c"
#include "labs/lab07_wysiwyg.c"
#include "labs/lab08_optimistic_events.c"
#include "labs/lab09_predicted_spawns.c"
#include "labs/lab11_deterministic_rng.c"

static const lab_def_t* const LABS[] = {
    &LAB_00, &LAB_01, &LAB_02, &LAB_03, &LAB_04, &LAB_05,
    &LAB_06, &LAB_07, &LAB_08, &LAB_09, &LAB_11,
};
#define LAB_COUNT ((int)(sizeof(LABS) / sizeof(LABS[0])))

/* ------------------------------------------------------ latency presets */

static const struct { double delay, jitter; const char* label; } PRESETS[] = {
    { 0,   0,  "off" },
    { 80,  10, "80 ms + 10 jitter" },
    { 200, 0,  "200 ms" },
    { 200, 80, "200 ms + 80 jitter" },
    { 400, 60, "400 ms + 60 jitter" },
};
#define PRESET_COUNT ((int)(sizeof(PRESETS) / sizeof(PRESETS[0])))

/* --------------------------------------------------------- shell state */

typedef enum { ST_IDLE, ST_JOINING, ST_ATTACHING, ST_READY, ST_FAILED } lab_status_t;

#define MAX_PENDING_FREE 8

static struct {
    app_t app;
    int lab_index;
    lab_status_t status;
    char error[192];

    join_req_t* join;         /* heap: callbacks land on the matchmaking thread */
    double join_started;

    int preset;

    /* Set by the SDK on its own thread; consumed on the main thread. */
    volatile bool reconnected;
    volatile bool dropped;
    double dropped_at;

    struct { colyseus_room_t* room; double free_at; } pending_free[MAX_PENDING_FREE];
    int pending_free_count;
} S;

static int reconnect_count = 0;

static double shell_now(void) {
    return S.app.room ? colyseus_room_clock_now(colyseus_room_get_clock(S.app.room)) : nd_now();
}

static void on_room_reconnect(void* userdata) {
    (void)userdata;
    S.reconnected = true;
    S.dropped = false;
    reconnect_count++;
}

static void on_room_drop(int code, const char* reason, void* userdata) {
    (void)code; (void)reason; (void)userdata;
    S.dropped = true;
}

/* Leave now, free later: the LEAVE frame still has to clear the injector's
 * outbound queue, which only drains from nd_pump(). */
static void retire_room(colyseus_room_t* room) {
    if (!room) { return; }
    colyseus_room_leave(room, true);
    if (S.pending_free_count < MAX_PENDING_FREE) {
        S.pending_free[S.pending_free_count].room = room;
        S.pending_free[S.pending_free_count].free_at =
            nd_now() + 400 + 2 * (nd_get_delay() + nd_get_jitter());
        S.pending_free_count++;
    }
}

static void drain_pending_frees(bool force) {
    double now = nd_now();
    for (int i = S.pending_free_count - 1; i >= 0; i--) {
        if (!force && now < S.pending_free[i].free_at) { continue; }
        colyseus_room_free(S.pending_free[i].room);
        S.pending_free[i] = S.pending_free[--S.pending_free_count];
    }
}

static void start_join(void) {
    const lab_def_t* lab = LABS[S.lab_index];
    join_req_t* j = (join_req_t*)calloc(1, sizeof(join_req_t));
    j->state_vtable = lab->state_vtable;
    S.join = j;
    S.status = ST_JOINING;
    S.join_started = nd_now();
    S.error[0] = '\0';

    /* joinOrCreate puts every client in the SAME room — multiplayer is free.
     * `P` forces a solo room, mirroring the web build's ?private=1. */
    if (S.app.private_room) {
        colyseus_client_create_room(S.app.client, lab->room_name, NULL,
            join_on_success, join_on_error, j);
    } else {
        colyseus_client_join_or_create(S.app.client, lab->room_name, NULL,
            join_on_success, join_on_error, j);
    }
}

static void switch_lab(int index) {
    if (index < 0 || index >= LAB_COUNT) { return; }
    if (S.status == ST_READY) { LABS[S.lab_index]->detach(&S.app); }
    if (S.join && S.join->room) { retire_room(S.join->room); }
    free(S.join);
    S.join = NULL;
    S.app.room = NULL;
    S.lab_index = index;
    start_join();
}

/* ------------------------------------------------------------- chrome */

static void draw_top_bar(float w) {
    DrawRectangle(0, 0, (int)w, 44, COL_PANEL);
    DrawLineV((Vector2){ 0, 44 }, (Vector2){ w, 44 }, COL_BORDER);
    DrawText("PREDICTION PLAYGROUND", 16, 9, 12, COL_ACCENT);
    DrawText("native  (C + raylib)", 16, 24, 10, COL_TEXT_FAINT);

    /* Lab strip: one numbered chip per lab. */
    float x = 190;
    for (int i = 0; i < LAB_COUNT; i++) {
        bool on = i == S.lab_index;
        const char* n = TextFormat("%d", LABS[i]->num);
        Rectangle r = { x, 11, 22, 22 };
        DrawRectangleRounded(r, 0.3f, 4, on ? COL_ACCENT : COL_INSET);
        DrawRectangleRoundedLines(r, 0.3f, 4, COL_BORDER);
        DrawText(n, (int)(x + 11 - MeasureText(n, 11) / 2.0f), 16, 11,
            on ? COL_BG : COL_TEXT_DIM);
        x += 26;
    }

    const lab_def_t* lab = LABS[S.lab_index];
    DrawText(TextFormat("%02d  %s", lab->num, lab->title), (int)x + 14, 9, 13, COL_TEXT);
    DrawText(lab->blurb, (int)x + 14, 25, 10, COL_TEXT_DIM);
}

static void draw_bottom_bar(float w, float h) {
    float y = h - 46;
    DrawRectangle(0, (int)y, (int)w, 46, COL_PANEL);
    DrawLineV((Vector2){ 0, y }, (Vector2){ w, y }, COL_BORDER);

    float x = 16;
    #define STAT(label, val, col) do { \
        DrawText((label), (int)x, (int)y + 9, 9, COL_TEXT_FAINT); \
        DrawText((val), (int)x, (int)y + 22, 12, (col)); \
        x += (float)(MeasureText((val), 12) > MeasureText((label), 9) \
            ? MeasureText((val), 12) : MeasureText((label), 9)) + 22; \
    } while (0)

    colyseus_room_clock_t* clock = S.app.room ? colyseus_room_get_clock(S.app.room) : NULL;
    if (clock) {
        double last = colyseus_room_clock_last_server_time(clock);
        STAT("RTT", TextFormat("%.0f ms", colyseus_room_clock_smoothed_rtt(clock)), COL_TEXT);
        STAT("JITTER", TextFormat("%.0f ms", colyseus_room_clock_jitter(clock)), COL_TEXT);
        STAT("PATCH AGE", last > 0
            ? TextFormat("%.0f ms", fmax(0, colyseus_room_clock_server_now(clock) - last))
            : "--", COL_TEXT);
    } else {
        STAT("RTT", "--", COL_TEXT_FAINT);
        STAT("JITTER", "--", COL_TEXT_FAINT);
        STAT("PATCH AGE", "--", COL_TEXT_FAINT);
    }
    STAT("INJECTED LATENCY", PRESETS[S.preset].label,
        S.preset == 0 ? COL_TEXT_DIM : COL_WARN);
    STAT("IN FLIGHT", TextFormat("%d pkt", nd_inflight()), COL_TEXT_DIM);
    STAT("ROOM", S.app.private_room ? "private" : "shared", COL_TEXT_DIM);

    const char* state =
        S.status == ST_READY ? (S.dropped ? "reconnecting..." : "connected")
        : S.status == ST_FAILED ? "failed"
        : "connecting...";
    STAT("STATE", state,
        S.status == ST_FAILED ? COL_BAD : S.dropped ? COL_WARN
        : S.status == ST_READY ? COL_GOOD : COL_TEXT_DIM);
    #undef STAT

    const char* keys = "0-9 lab   [ ] prev/next   L latency   D drop   P private   ESC quit";
    DrawText(keys, (int)(w - MeasureText(keys, 10) - 16), (int)y + 18, 10, COL_TEXT_FAINT);
}

static void draw_stage_message(const char* msg, Color c) {
    int w = MeasureText(msg, 15);
    DrawText(msg, (int)(S.app.stage_x + (S.app.stage_w - w) / 2),
        (int)(S.app.stage_y + S.app.stage_h / 2), 15, c);
}

/* ------------------------------------------------- acceptance autopilot */

/*
 * `--demo` replays APPS_PLAN §7's M1 exit criteria with no hands on the
 * keyboard: it switches labs, cycles latency presets, drives the player, fires
 * the impulse, drops the transport, and writes a screenshot per checkpoint.
 * Each checkpoint prints OK/FAIL, and the process exits non-zero if any failed
 * — so the milestone is a command, not an opinion.
 */
typedef struct {
    double at;              /* ms since the demo started */
    int lab;                /* index into LABS; -1 = keep */
    int preset;             /* -1 = keep */
    int auto_x, auto_y;     /* autopilot axes */
    int synth_key;          /* 0 = none */
    int synth_repeat;       /* extra presses on following frames (0 = one) */
    const char* shot;       /* screenshot path, or NULL */
    const char* checkpoint; /* assertion name, or NULL */
} demo_step_t;

/* LABS index, by lab id — the script reads better than raw ordinals. */
enum { IX_00, IX_01, IX_02, IX_03, IX_04, IX_05, IX_06, IX_07, IX_08, IX_09, IX_11 };

static const demo_step_t DEMO[] = {
    /* ---- M1 ------------------------------------------------------------ */
    /* Lab 01 — the input->motion meter needs the player AT REST to arm, so
     * every measurement is preceded by a beat of no input. */
    { 500,   IX_01, 0,  0, 0, 0, 0, NULL, NULL },
    { 2000,  -1, -1,  1, 0, 0, 0, NULL, NULL },
    { 3400,  -1, -1,  1, 0, 0, 0, "media/native-app/01-latency-off.png", "lab01-latency-off" },
    { 3600,  -1, -1,  0, 0, 0, 0, NULL, NULL },
    { 4800,  -1,  2,  0, 0, 0, 0, NULL, NULL },
    { 5800,  -1, -1, -1, 0, 0, 0, NULL, NULL },
    { 7400,  -1, -1, -1, 0, 0, 0, "media/native-app/01-latency-200.png", "lab01-latency-200" },
    /* Lab 02 — clock readouts under the same 200 ms injection. */
    { 7800,  IX_02, -1,  1, 0, 0, 0, NULL, NULL },
    { 11800, -1, -1,  1, 0, 0, 0, "media/native-app/02-clocks.png", "lab02-clock" },
    /* Lab 03 — predicted, then mispredicted, then dropped. */
    { 12300, IX_03, -1, -1, 0, 0, 0, NULL, NULL },
    { 16800, -1, -1, -1, 0, 0, 0, "media/native-app/03-reconcile.png", "lab03-predicted" },
    { 17000, -1, -1,  0, 0, KEY_I, 0, NULL, NULL },
    { 18200, -1, -1,  0, 0, 0, 0, "media/native-app/03-impulse.png", "lab03-impulse" },
    /* The drift EMA folds in at 0.1/reconcile: a 4-unit spike needs ~60 patches
     * (~3 s) to bleed back under the noise floor. Give it 6. */
    { 23600, -1, -1,  1, 0, 0, 0, NULL, "lab03-recovered" },
    { 24100, -1, -1,  0, 0, KEY_D, 0, NULL, NULL },  /* the shell's "drop transport" key */
    { 31600, -1, -1,  1, 0, 0, 0, "media/native-app/03-reconnected.png", "lab03-reconnected" },

    /* ---- M2 ------------------------------------------------------------ */
    /* Lab 00 — the split. It sets its own latency preset and drives itself. */
    { 32600, IX_00, -1, 0, 0, 0, 0, NULL, NULL },
    { 39000, -1, -1, 0, 0, 0, 0, "media/native-app/00-split.png", "lab00-split" },
    /* Lab 04 — four interpolation modes over one bot. */
    { 39500, IX_04, -1, 1, 0, 0, 0, NULL, NULL },
    { 40000, -1, -1, 1, 0, KEY_B, 0, NULL, NULL },   /* patrol -> circle: constant turning */
    { 47000, -1, -1, 1, 0, 0, 0, "media/native-app/04-interp.png", "lab04-modes" },
    /* Lab 05 — reckon vs lerp: exact on patrol, honestly wrong on wander. */
    { 47500, IX_05, -1, 0, 0, 0, 0, NULL, NULL },
    { 48200, -1, -1, 0, 0, KEY_B, 0, NULL, NULL },   /* teleport -> patrol */
    { 54000, -1, -1, 0, 0, 0, 0, "media/native-app/05-reckon.png", "lab05-patrol" },
    { 54300, -1, -1, 0, 0, KEY_B, 0, NULL, NULL },   /* patrol -> wander */
    { 61000, -1, -1, 0, 0, 0, 0, NULL, "lab05-wander" },
    /* Lab 08 — optimistic goals, then a room-wide 100 % deny rate. */
    { 61500, IX_08, -1, 1, 0, 0, 0, NULL, NULL },
    { 69000, -1, -1, 1, 0, 0, 0, "media/native-app/08-goal.png", "lab08-confirmed" },
    { 69200, -1, -1, 1, 0, KEY_EQUAL, 3, NULL, NULL },  /* deny 0 -> 100 (4 presses) */
    { 78000, -1, -1, 1, 0, 0, 0, "media/native-app/08-denied.png", "lab08-denied" },
    /* Lab 09 — predicted spawn, authoritative handoff. */
    { 78500, IX_09, -1, 0, 0, 0, 0, NULL, NULL },
    { 80000, -1, -1, 0, 0, KEY_SPACE, 0, NULL, NULL },
    { 83000, -1, -1, 0, 0, 0, 0, "media/native-app/09-spawns.png", "lab09-spawn" },

    /* ---- M3 (labs 06 / 07 / 11; lab 10 needs the SimReconciler port) ---- */
    /*
     * Every lab switch costs a join round trip (~1 s at these presets), so an
     * input scheduled right after one lands before attach() and is lost. The
     * M3 legs allow 2 s of settle. Shot records also fade after 2.6 s — fire
     * close enough to the checkpoint that the record still exists.
     */
    /* Lab 06 — the autopilot aims at the bot's lerp pose and fires a volley;
     * a single grazing shot is noise, a hit RATE is the claim (same shape as
     * scripts/probe-rewind.mjs). */
    { 83500, IX_06, 2, 0, 0, 0, 0, NULL, NULL },   /* 200 ms, no jitter */
    { 86000, -1, -1, 0, 0, KEY_SPACE, 0, NULL, NULL },
    { 86500, -1, -1, 0, 0, KEY_SPACE, 0, NULL, NULL },
    { 87000, -1, -1, 0, 0, KEY_SPACE, 0, NULL, NULL },
    { 87500, -1, -1, 0, 0, KEY_SPACE, 0, NULL, NULL },
    { 88000, -1, -1, 0, 0, KEY_SPACE, 0, NULL, NULL },
    { 88500, -1, -1, 0, 0, KEY_SPACE, 0, NULL, NULL },
    { 90200, -1, -1, 0, 0, 0, 0, "media/native-app/06-lagcomp.png", "lab06-shot" },
    /* Lab 07 — park in the bot's patrol lane (y 30) and get swept. Spawn is
     * y 45 and the predicted pose moves instantly, so ~0.6 s of "up" lands on
     * the lane; any longer and it parks against the top wall. */
    { 91700, IX_07, -1, 0, 0, 0, 0, NULL, NULL },
    { 93700, -1, -1, 0, -1, 0, 0, NULL, NULL },
    { 94300, -1, -1, 0, 0, 0, 0, NULL, NULL },
    { 103000, -1, -1, 0, 0, 0, 0, "media/native-app/07-wysiwyg.png", "lab07-bumps" },
    /* Lab 11 — one fan, compared against the server's. */
    { 103500, IX_11, -1, 0, 0, 0, 0, NULL, NULL },
    { 107500, -1, -1, 0, 0, KEY_SPACE, 0, NULL, NULL },
    { 110000, -1, -1, 0, 0, 0, 0, "media/native-app/11-rng.png", "lab11-fan" },
    { 111000, -1, -1, 0, 0, 0, 0, NULL, NULL },
};
#define DEMO_COUNT ((int)(sizeof(DEMO) / sizeof(DEMO[0])))

static bool demo_mode = false;
static int demo_cursor = 0;
static double demo_started = 0;
static int demo_failed = 0;

static void demo_check(const char* name, bool ok, const char* fmt, ...) {
    printf("%s %-22s ", ok ? "OK  " : "FAIL", name);
    va_list args;
    va_start(args, fmt);
    vprintf(fmt, args);
    va_end(args);
    printf("\n");
    if (!ok) { demo_failed++; }
}

static void demo_checkpoint(const char* name) {
    colyseus_room_clock_t* clock = S.app.room ? colyseus_room_get_clock(S.app.room) : NULL;
    double rtt = clock ? colyseus_room_clock_smoothed_rtt(clock) : 0;

    if (S.status != ST_READY) {
        demo_check(name, false, "lab not ready (status %d: %s)", (int)S.status, S.error);
        return;
    }

    if (strcmp(name, "lab01-latency-off") == 0) {
        demo_check(name, l01.measured > 0 && l01.measured < 250,
            "input->motion %.0f ms at 0 injected (rtt %.0f) — one patch interval",
            l01.measured, rtt);
    } else if (strcmp(name, "lab01-latency-200") == 0) {
        demo_check(name, l01.measured > 300 && l01.measured < 1200,
            "input->motion %.0f ms at 200 ms injected (rtt %.0f) — no prediction, so it "
            "tracks the round trip", l01.measured, rtt);
    } else if (strcmp(name, "lab02-clock") == 0) {
        demo_check(name, rtt > 350 && colyseus_room_clock_last_server_time(clock) > 0,
            "smoothed rtt %.0f ms, patch stamp flowing, jitter %.1f",
            rtt, colyseus_room_clock_jitter(clock));
    } else if (strcmp(name, "lab03-predicted") == 0) {
        const colyseus_drift_t* d = colyseus_reconciler_drift(l03.recon);
        int pending = colyseus_reconciler_pending_count(l03.recon);
        bool matched = colyseus_drift_classify(d, 0) == COLYSEUS_DRIFT_MATCHED;
        demo_check(name, matched && pending > 0 && l03.corrections == 0,
            "drift %s (ema %.2e), %d pending inputs at rtt %.0f ms, %d corrections",
            matched ? "matched" : "NOT matched", d->ema, pending, rtt, l03.corrections);
    } else if (strcmp(name, "lab03-impulse") == 0) {
        demo_check(name, l03.max_corr_mag > 0.05,
            "max |correction| %.3f after the server-side shove", l03.max_corr_mag);
    } else if (strcmp(name, "lab03-recovered") == 0) {
        const colyseus_drift_t* d = colyseus_reconciler_drift(l03.recon);
        double live = colyseus_reconciler_last_correction_mag(l03.recon);
        demo_check(name, live < 0.02 && d->ema < l03.max_corr_mag * 0.05,
            "live |correction| %.4f (peak was %.3f), drift ema %.4f peak %.4f — decayed",
            live, l03.max_corr_mag, d->ema, d->peak);
    } else if (strcmp(name, "lab03-reconnected") == 0) {
        const colyseus_drift_t* d = colyseus_reconciler_drift(l03.recon);
        bool matched = colyseus_drift_classify(d, 0.01) != COLYSEUS_DRIFT_DIVERGING;
        demo_check(name, reconnect_count > 0 && !l03.rebind && matched,
            "%d reconnect(s), reconciler rebound, drift ema %.4f, %d reconciles",
            reconnect_count, d->ema, colyseus_reconciler_reconcile_seq(l03.recon));

    /* ---- M2 ---- */
    } else if (strcmp(name, "lab00-split") == 0) {
        /* The lanes must be separated by roughly RTT x speed; at 200 ms + jitter
         * with a mover that reverses constantly, several world units. */
        double gap = sqrt(
            (l03.predicted->x - l03.me->x) * (l03.predicted->x - l03.me->x)
            + (l03.predicted->y - l03.me->y) * (l03.predicted->y - l03.me->y));
        demo_check(name, gap > 2.0 && colyseus_reconciler_pending_count(l03.recon) > 0,
            "echo lane trails the predicted lane by %.1f u at rtt %.0f ms (%d in flight)",
            gap, rtt, colyseus_reconciler_pending_count(l03.recon));
    } else if (strcmp(name, "lab04-modes") == 0) {
        double raw_cv = l04_smooth_cv(&l04.modes[0].smooth);
        double lerp_cv = l04_smooth_cv(&l04.modes[1].smooth);
        double damped_cv = l04_smooth_cv(&l04.modes[2].smooth);
        double ext_cv = l04_smooth_cv(&l04.modes[3].smooth);
        demo_check(name, !isnan(raw_cv) && !isnan(lerp_cv) && lerp_cv < raw_cv,
            "speed CV raw %.0f%% > lerp %.0f%% (damped %.0f%%, extrapolate %.0f%%) — "
            "the raw square steps at the patch rate, lerp glides",
            raw_cv * 100, lerp_cv * 100, damped_cv * 100, ext_cv * 100);
    } else if (strcmp(name, "lab05-patrol") == 0) {
        double rx = colyseus_predict_value(l05.reckon, (colyseus_schema_t*)l05.bot, "x");
        double lx = colyseus_predict_value(l05.lerp, (colyseus_schema_t*)l05.bot, "x");
        /* Reckon runs at the present, lerp 100 ms in the past: on a straight
         * patrol leg the gap is real motion, not error. */
        demo_check(name, strcmp(l05.bot->kind, "patrol") == 0 && fabs(rx - lx) > 0.5,
            "kind=%s reckon x %.2f vs lerp x %.2f (gap %.2f u over a %.0f ms horizon)",
            l05.bot->kind, rx, lx, fabs(rx - lx),
            fmax(0, colyseus_room_clock_server_now(l05.clock)
                - colyseus_room_clock_last_server_time(l05.clock)));
    } else if (strcmp(name, "lab05-wander") == 0) {
        double rx = colyseus_predict_value(l05.reckon, (colyseus_schema_t*)l05.bot, "x");
        /* Reckon must actually be projecting past the snapshot — that is the
         * mechanism whose error the wander pattern then exposes. */
        demo_check(name, strcmp(l05.bot->kind, "wander") == 0 && fabs(rx - l05.bot->x) > 0.1,
            "kind=%s, reckon x %.2f is %.2f u past the newest snapshot — headings are a "
            "server secret, so it extrapolates straight through every turn and gets rebased",
            l05.bot->kind, rx, fabs(rx - l05.bot->x));
    } else if (strcmp(name, "lab08-confirmed") == 0) {
        int confirmed = 0;
        for (int i = 0; i < l08.record_count; i++) { if (l08.records[i].outcome == 1) { confirmed++; } }
        demo_check(name, l08.record_count > 0 && confirmed > 0,
            "%d predicted, %d confirmed at deny rate %d %% (score %d)",
            l08.record_count, confirmed, l08.deny_rate, l08.me->score);
    } else if (strcmp(name, "lab08-denied") == 0) {
        int rejected = 0;
        for (int i = 0; i < l08.record_count; i++) { if (l08.records[i].outcome == -1) { rejected++; } }
        demo_check(name, l08.deny_rate == 100 && rejected > 0,
            "%d rejected at deny rate %d %% — the banner went up, then retracted",
            rejected, l08.deny_rate);
    } else if (strcmp(name, "lab09-spawn") == 0) {
        demo_check(name, l09.fired > 0 && !isnan(l09.last_lead_ms) && l09.last_lead_ms > 0,
            "%d fired, authoritative entity correlated in place, measured input lead "
            "%.0f ms", l09.fired, l09.last_lead_ms);

    /* ---- M3 ---- */
    } else if (strcmp(name, "lab06-shot") == 0) {
        const l06_shot_t* s = NULL;
        for (int i = l06.shot_count - 1; i >= 0; i--) {
            if (l06.shots[i].answered) { s = &l06.shots[i]; break; }
        }
        double lead = s ? sqrt((s->red_x - s->blue_x) * (s->red_x - s->blue_x)
            + (s->red_y - s->blue_y) * (s->red_y - s->blue_y)) : -1;
        /* The rewound read must land on what the shooter saw, not on live. */
        double rewind_err = s ? sqrt((s->green_x - s->blue_x) * (s->green_x - s->blue_x)
            + (s->green_y - s->blue_y) * (s->green_y - s->blue_y)) : -1;
        double rate = l06.shots_on ? (double)l06.hits_on / l06.shots_on : 0;
        demo_check(name, s != NULL && l06.state->lagComp && l06.shots_on >= 5
            && rate >= 0.6 && rewind_err < lead,
            "%d/%d hits (%.0f %%) aiming dead-on at the lerp view, rtt %.0f ms; the "
            "server rewound to within %.2f u of what I saw while live had moved %.2f u "
            "away [stamp render=%d reckon=%d, %.0f ms of bot travel]",
            l06.hits_on, l06.shots_on, rate * 100, rtt, rewind_err, lead,
            l06.room->input_stamp_render, l06.room->input_stamp_reckon,
            rewind_err / 22.0 * 1000.0);
    } else if (strcmp(name, "lab07-bumps") == 0) {
        double bx = colyseus_predict_value(l07.predict, (colyseus_schema_t*)l07.bot, "x");
        double by = colyseus_predict_value(l07.predict, (colyseus_schema_t*)l07.bot, "y");
        (void)bx; (void)by;
        /*
         * The claim is that the client's verdict EQUALS the server's, so the
         * check is the two counters, not a correction-magnitude heuristic:
         * one bump may still be in flight when the checkpoint reads them.
         */
        int diff = l07.bumps_predicted - (int)l07.me->bumps;
        if (diff < 0) { diff = -diff; }
        demo_check(name, l07.bumps_predicted >= 3 && diff <= 1,
            "%d bumps predicted through valueAt(reckonTime)+memo vs %d authoritative "
            "(delta %d), %d large post-bump corrections",
            l07.bumps_predicted, l07.me->bumps, diff, l07.mispredicts);
    } else if (strcmp(name, "lab11-fan") == 0) {
        demo_check(name, l11.has_divergence && l11.max_divergence < 1e-6,
            "client and server fans agree to %.2e rad over %d pellets — the uint32 RNG "
            "port reproduces the stream exactly, and nothing about it rode the wire",
            l11.max_divergence, PELLETS);
    } else {
        demo_check(name, false, "unknown checkpoint");
    }
}

/* --------------------------------------------------------------- main */

static void register_vtables(void) {
    colyseus_schema_register_vtable(&player_vtable);
    colyseus_schema_register_vtable(&move_state_vtable);
    colyseus_schema_register_vtable(&move_input_vtable);
    colyseus_schema_register_vtable(&bot_vtable);
    colyseus_schema_register_vtable(&bots_state_vtable);
    colyseus_schema_register_vtable(&goal_player_vtable);
    colyseus_schema_register_vtable(&goal_state_vtable);
    colyseus_schema_register_vtable(&projectile_vtable);
    colyseus_schema_register_vtable(&projectile_state_vtable);
    colyseus_schema_register_vtable(&range_input_vtable);
    colyseus_schema_register_vtable(&range_player_vtable);
    colyseus_schema_register_vtable(&range_state_vtable);
    colyseus_schema_register_vtable(&bump_player_vtable);
    colyseus_schema_register_vtable(&bump_state_vtable);
}

/* Declared in app.h — labs 00 and friends set the stage before they mount. */
static void app_set_latency_preset(int index) {
    if (index < 0 || index >= PRESET_COUNT) { return; }
    S.preset = index;
    nd_set_latency(PRESETS[index].delay, PRESETS[index].jitter);
}

int main(int argc, char** argv) {
    /* macOS raises SIGPIPE on socket writes after peer close and the SDK's
     * transport does not set SO_NOSIGPIPE — a desktop client must ignore it. */
    signal(SIGPIPE, SIG_IGN);
    setvbuf(stdout, NULL, _IONBF, 0);

    const char* port = "5173";
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--selfcheck") == 0) {
            printf("predict_playground selfcheck\n");
            int failed = sim_selfcheck(1);
            printf("%s\n", failed == 0 ? "SELFCHECK OK" : "SELFCHECK FAILED");
            return failed == 0 ? 0 : 1;
        }
        if (strcmp(argv[i], "--demo") == 0) { demo_mode = true; continue; }
        port = argv[i];
    }

    if (sim_selfcheck(0) != 0) {
        fprintf(stderr, "shared-sim port mismatch — run --selfcheck\n");
        return 1;
    }

    register_vtables();

    S.app.settings = colyseus_settings_create();
    colyseus_settings_set_address(S.app.settings, "127.0.0.1");
    colyseus_settings_set_port(S.app.settings, port);
    colyseus_settings_set_secure(S.app.settings, false);
    /* Every room is built on the injector's wrapper transport (APPS_PLAN §3). */
    S.app.client = colyseus_client_create_with_transport(S.app.settings, nd_transport_create);
    printf("predict_playground -> ws://localhost:%s\n", port);

    SetConfigFlags(FLAG_WINDOW_RESIZABLE | FLAG_MSAA_4X_HINT);
    InitWindow(1440, 860, "Colyseus Prediction Playground — native");
    /* No window (headless shell, no display) means glfw is uninitialised and
     * every later GLFW call spins in raylib's error logger. Fail loudly. */
    if (!IsWindowReady()) {
        fprintf(stderr, "could not open a window — this app needs a display "
            "(use --selfcheck for the headless canary)\n");
        return 2;
    }
    SetTargetFPS(60);

    if (demo_mode) {
        g_autopilot = true;
        demo_started = nd_now();
        if (!DirectoryExists("media/native-app")) { MakeDirectory("media/native-app"); }
        printf("\n=== acceptance run: M1 + M2 (APPS_PLAN §7) ===\n");
    }

    start_join();

    const char* pending_shot = NULL;
    int repeat_key = 0, repeat_left = 0;
    double last = nd_now();
    while (!WindowShouldClose()) {
        /* 1. Deliver due packets — every schema decode happens right here, on
         *    the main thread, so labs read state without a lock. */
        nd_pump();
        drain_pending_frees(false);

        double now = shell_now();
        double wall = nd_now();
        S.app.dt = wall - last;
        last = wall;
        S.app.now = now;

        /* 2. Demo autopilot (drives the same keys a human would). */
        if (demo_mode) {
            while (demo_cursor < DEMO_COUNT && wall - demo_started >= DEMO[demo_cursor].at) {
                const demo_step_t* st = &DEMO[demo_cursor++];
                g_auto_x = st->auto_x;
                g_auto_y = st->auto_y;
                if (st->preset >= 0) {
                    S.preset = st->preset;
                    nd_set_latency(PRESETS[S.preset].delay, PRESETS[S.preset].jitter);
                }
                if (st->lab >= 0 && st->lab != S.lab_index) { switch_lab(st->lab); }
                if (st->synth_key) {
                    g_synth_key = st->synth_key;
                    repeat_key = st->synth_key;
                    repeat_left = st->synth_repeat;
                }
                if (st->checkpoint) { demo_checkpoint(st->checkpoint); }
                pending_shot = st->shot;
            }
            /* A key that steps a value needs one press per frame, not per step. */
            if (repeat_left > 0 && g_synth_key == 0) { g_synth_key = repeat_key; repeat_left--; }
            if (demo_cursor >= DEMO_COUNT) { break; }
        }

        /* 3. Shell keys — digits address a lab by its NUMBER, not its slot. */
        for (int i = 0; i < LAB_COUNT; i++) {
            int num = LABS[i]->num;
            if (num >= 0 && num <= 9 && app_key(num == 0 ? KEY_ZERO : KEY_ONE + num - 1)) {
                switch_lab(i);
            }
        }
        if (app_key(KEY_LEFT_BRACKET)) { switch_lab((S.lab_index + LAB_COUNT - 1) % LAB_COUNT); }
        if (app_key(KEY_RIGHT_BRACKET)) { switch_lab((S.lab_index + 1) % LAB_COUNT); }
        if (app_key(KEY_L)) {
            S.preset = (S.preset + 1) % PRESET_COUNT;
            nd_set_latency(PRESETS[S.preset].delay, PRESETS[S.preset].jitter);
        }
        if (app_key(KEY_D)) { nd_drop(); S.dropped_at = wall; }
        if (app_key(KEY_P)) { S.app.private_room = !S.app.private_room; switch_lab(S.lab_index); }
        if (app_key(KEY_F12)) { TakeScreenshot("media/native-app/manual.png"); }

        /* 4. Room lifecycle. */
        if (S.status == ST_JOINING && S.join) {
            if (S.join->errored) {
                snprintf(S.error, sizeof(S.error), "%s", S.join->error);
                S.status = ST_FAILED;
            } else if (S.join->joined && colyseus_room_get_state(S.join->room)) {
                S.app.room = S.join->room;
                colyseus_room_on_reconnect(S.app.room, on_room_reconnect, NULL);
                colyseus_room_on_drop(S.app.room, on_room_drop, NULL);
                S.status = ST_ATTACHING;
            } else if (wall - S.join_started > 8000) {
                snprintf(S.error, sizeof(S.error), "timed out joining %s",
                    LABS[S.lab_index]->room_name);
                S.status = ST_FAILED;
            }
        }
        if (S.status == ST_ATTACHING) {
            if (LABS[S.lab_index]->attach(&S.app, S.app.room)) {
                S.status = ST_READY;
            } else if (wall - S.join_started > 8000) {
                snprintf(S.error, sizeof(S.error), "state never arrived for %s",
                    LABS[S.lab_index]->id);
                S.status = ST_FAILED;
            }
        }
        if (S.status == ST_READY && S.reconnected) {
            S.reconnected = false;
            if (LABS[S.lab_index]->on_reconnect) { LABS[S.lab_index]->on_reconnect(&S.app); }
        }

        /* 5. Draw. */
        float w = (float)GetScreenWidth(), h = (float)GetScreenHeight();
        const float panel_w = 300, panel_pad = 18;
        S.app.stage_x = 0;
        S.app.stage_y = 44;
        S.app.stage_w = w - panel_w - panel_pad * 2;
        S.app.stage_h = h - 44 - 46;
        view_fit(&S.app.view, S.app.stage_x, S.app.stage_y, S.app.stage_w, S.app.stage_h, 28);
        hud_begin(&S.app.hud, w - panel_w - panel_pad, 60, panel_w);

        BeginDrawing();
        ClearBackground(COL_BG);

        /* Panel background first — the lab's frame() draws the arena overlay
         * AND its HUD widgets, so nothing may be painted over it afterwards. */
        DrawRectangle((int)(w - panel_w - panel_pad * 2), 44, (int)(panel_w + panel_pad * 2),
            (int)(h - 44 - 46), COL_PANEL);
        DrawLineV((Vector2){ w - panel_w - panel_pad * 2, 44 },
                  (Vector2){ w - panel_w - panel_pad * 2, h - 46 }, COL_BORDER);
        if (!LABS[S.lab_index]->own_arena) { draw_arena(&S.app.view); }

        if (S.status == ST_READY) {
            LABS[S.lab_index]->frame(&S.app, now, S.app.dt);
        } else if (S.status == ST_FAILED) {
            draw_stage_message(S.error, COL_BAD);
        } else {
            draw_stage_message(TextFormat("connecting to %s ...", LABS[S.lab_index]->room_name),
                COL_TEXT_DIM);
        }

        draw_top_bar(w);
        draw_bottom_bar(w, h);
        EndDrawing();

        if (pending_shot) { TakeScreenshot(pending_shot); pending_shot = NULL; }
    }

    if (demo_mode) {
        /* A window closed early (or a crash) must never read as a pass. */
        if (demo_cursor < DEMO_COUNT) {
            printf("FAIL script aborted at step %d/%d\n", demo_cursor, DEMO_COUNT);
            demo_failed++;
        }
        printf("\n%s\n", demo_failed == 0 ? "ACCEPTANCE OK" : "ACCEPTANCE FAILED");
    }
    if (S.status == ST_READY) { LABS[S.lab_index]->detach(&S.app); }
    if (S.app.room) { retire_room(S.app.room); }
    /* Let the LEAVE frame clear the injector's outbound queue before the room
     * (and with it the transport) goes away. usleep, not raylib's WaitTime:
     * this runs past the window's useful life. */
    for (int i = 0; i < 40; i++) { nd_pump(); usleep(10000); }
    drain_pending_frees(true);
    nd_pump();

    CloseWindow();
    colyseus_client_free(S.app.client);
    colyseus_settings_free(S.app.settings);
    free(S.join);
    return demo_failed == 0 ? 0 : 1;
}
