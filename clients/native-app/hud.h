/*
 * Immediate-mode side panel: telemetry rows, sparklines, pending-input chips,
 * and the keyboard "controls" list that stands in for the web build's sliders
 * and toggles (APPS_PLAN §6 native-app: controls are keybinds shown on-screen).
 *
 * Port of src/client/framework/hud.ts + controls.ts, minus the DOM: every
 * widget is drawn where the cursor currently is and advances it.
 */
#ifndef PLAYGROUND_HUD_H
#define PLAYGROUND_HUD_H

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "raylib.h"
#include "view.h"

#define HUD_FONT 12
#define HUD_SMALL 10

typedef struct {
    float x, y, w;
    float cursor;
} hud_t;

static void hud_begin(hud_t* h, float x, float y, float w) {
    h->x = x; h->y = y; h->w = w; h->cursor = y;
}

static void hud_gap(hud_t* h, float px) { h->cursor += px; }

static void hud_section(hud_t* h, const char* title) {
    h->cursor += 10;
    DrawText(title, (int)h->x, (int)h->cursor, HUD_SMALL, COL_TEXT_FAINT);
    h->cursor += HUD_SMALL + 4;
    DrawLineV((Vector2){ h->x, h->cursor }, (Vector2){ h->x + h->w, h->cursor }, COL_BORDER);
    h->cursor += 6;
}

/** Label on the left, value right-aligned — the web build's `.hudrow`. */
static void hud_row(hud_t* h, const char* label, Color value_color, const char* fmt, ...) {
    char buf[128];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);

    DrawText(label, (int)h->x, (int)h->cursor, HUD_FONT, COL_TEXT_DIM);
    int vw = MeasureText(buf, HUD_FONT);
    DrawText(buf, (int)(h->x + h->w - vw), (int)h->cursor, HUD_FONT, value_color);
    h->cursor += HUD_FONT + 6;
}

/** Keybinding hint: key chip on the left, what it does on the right. */
static void hud_key(hud_t* h, const char* key, const char* what) {
    int kw = MeasureText(key, HUD_SMALL);
    DrawRectangleRounded((Rectangle){ h->x, h->cursor - 2, (float)kw + 10, HUD_SMALL + 7 },
        0.35f, 4, COL_INSET);
    DrawRectangleRoundedLines((Rectangle){ h->x, h->cursor - 2, (float)kw + 10, HUD_SMALL + 7 },
        0.35f, 4, COL_BORDER);
    DrawText(key, (int)h->x + 5, (int)h->cursor + 1, HUD_SMALL, COL_TEXT);
    DrawText(what, (int)(h->x + kw + 18), (int)h->cursor + 1, HUD_SMALL, COL_TEXT_DIM);
    h->cursor += HUD_SMALL + 9;
}

/** Word-wrapped dim paragraph — the web build's control `note`. */
static void hud_note(hud_t* h, const char* text) {
    char line[256];
    size_t line_len = 0;
    const char* p = text;
    h->cursor += 2;
    while (*p) {
        const char* word = p;
        while (*p && *p != ' ') { p++; }
        size_t wlen = (size_t)(p - word);
        while (*p == ' ') { p++; }
        if (wlen == 0) { continue; }

        char probe[256];
        size_t plen = line_len ? line_len + 1 + wlen : wlen;
        if (plen >= sizeof(probe)) { plen = sizeof(probe) - 1; }
        memcpy(probe, line, line_len);
        if (line_len) { probe[line_len] = ' '; }
        memcpy(probe + (line_len ? line_len + 1 : 0), word, wlen);
        probe[plen] = '\0';

        if (line_len && MeasureText(probe, HUD_SMALL) > (int)h->w) {
            line[line_len] = '\0';
            DrawText(line, (int)h->x, (int)h->cursor, HUD_SMALL, COL_TEXT_FAINT);
            h->cursor += HUD_SMALL + 3;
            memcpy(line, word, wlen);
            line_len = wlen;
        } else {
            memcpy(line, probe, plen);
            line_len = plen;
        }
    }
    if (line_len) {
        line[line_len] = '\0';
        DrawText(line, (int)h->x, (int)h->cursor, HUD_SMALL, COL_TEXT_FAINT);
        h->cursor += HUD_SMALL + 3;
    }
    h->cursor += 4;
}

/* --------------------------------------------------------- sparkline */

#define SPARK_SAMPLES 140

typedef struct {
    double data[SPARK_SAMPLES];
    int head, count;
} spark_t;

static void spark_init(spark_t* s) { memset(s, 0, sizeof(*s)); }

static void spark_push(spark_t* s, double v) {
    s->data[s->head] = v;
    s->head = (s->head + 1) % SPARK_SAMPLES;
    if (s->count < SPARK_SAMPLES) { s->count++; }
}

static double spark_last(const spark_t* s) {
    return s->count ? s->data[(s->head - 1 + SPARK_SAMPLES) % SPARK_SAMPLES] : 0;
}

/**
 * Rolling graph. `fixed_max <= 0` auto-scales to the window maximum; the
 * current value is printed next to the label.
 */
static void hud_spark(hud_t* h, spark_t* s, const char* label, const char* value,
    Color color, double fixed_max) {
    DrawText(label, (int)h->x, (int)h->cursor, HUD_SMALL, COL_TEXT_DIM);
    int vw = MeasureText(value, HUD_SMALL);
    DrawText(value, (int)(h->x + h->w - vw), (int)h->cursor, HUD_SMALL, color);
    h->cursor += HUD_SMALL + 3;

    const float gh = 30;
    DrawRectangle((int)h->x, (int)h->cursor, (int)h->w, (int)gh, COL_INSET);
    if (s->count >= 2) {
        double max = fixed_max;
        if (max <= 0) {
            for (int i = 0; i < s->count; i++) { if (s->data[i] > max) { max = s->data[i]; } }
            if (max <= 0) { max = 1e-6; }
        }
        int start = (s->head - s->count + SPARK_SAMPLES * 2) % SPARK_SAMPLES;
        for (int i = 1; i < s->count; i++) {
            double v0 = s->data[(start + i - 1) % SPARK_SAMPLES];
            double v1 = s->data[(start + i) % SPARK_SAMPLES];
            float x0 = h->x + (float)((i - 1) / (double)(SPARK_SAMPLES - 1)) * h->w;
            float x1 = h->x + (float)(i / (double)(SPARK_SAMPLES - 1)) * h->w;
            double n0 = v0 / max, n1 = v1 / max;
            if (n0 > 1) { n0 = 1; }
            if (n1 > 1) { n1 = 1; }
            DrawLineV((Vector2){ x0, h->cursor + gh - 2 - (float)n0 * (gh - 4) },
                      (Vector2){ x1, h->cursor + gh - 2 - (float)n1 * (gh - 4) }, color);
        }
    }
    h->cursor += gh + 8;
}

/** One chip per pending (unacked) input — the row drains as acks land. */
static void hud_chips(hud_t* h, const char* label, int n, int max) {
    char buf[16];
    snprintf(buf, sizeof(buf), "%d", n);
    DrawText(label, (int)h->x, (int)h->cursor, HUD_SMALL, COL_TEXT_DIM);
    int vw = MeasureText(buf, HUD_SMALL);
    DrawText(buf, (int)(h->x + h->w - vw), (int)h->cursor, HUD_SMALL, COL_ACCENT);
    h->cursor += HUD_SMALL + 4;

    const float cw = 5, ch = 10, gapx = 2;
    int shown = n > max ? max : n;
    float cx = h->x, cy = h->cursor;
    for (int i = 0; i < shown; i++) {
        DrawRectangleV((Vector2){ cx, cy }, (Vector2){ cw, ch }, with_alpha(COL_ACCENT, 0.75));
        cx += cw + gapx;
        if (cx + cw > h->x + h->w) { cx = h->x; cy += ch + 2; }
    }
    h->cursor = cy + ch + 8;
}

#endif /* PLAYGROUND_HUD_H */
