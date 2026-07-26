/*
 * WorldView + the arena's drawing vocabulary, ported from
 * src/client/framework/draw.ts + trail.ts onto raylib.
 *
 * Same 100x60 world-unit arena letterboxed into the window, same palette as
 * index.html, same shape set (squares / circles / rays / dashed ghosts /
 * correction arrows / fading trails) so a lab reads the same on both clients.
 */
#ifndef PLAYGROUND_VIEW_H
#define PLAYGROUND_VIEW_H

#include <math.h>
#include <stdio.h>
#include <string.h>

#include "raylib.h"
#include "sim.h"

/* ------------------------------------------------------------ palette */

#define COL_BG        CLITERAL(Color){ 0x0a, 0x0f, 0x1a, 255 }
#define COL_PANEL     CLITERAL(Color){ 0x0e, 0x16, 0x26, 255 }
#define COL_INSET     CLITERAL(Color){ 0x12, 0x1c, 0x30, 255 }
#define COL_BORDER    CLITERAL(Color){ 0x24, 0x30, 0x4a, 255 }
#define COL_TEXT      CLITERAL(Color){ 0xd8, 0xe2, 0xf0, 255 }
#define COL_TEXT_DIM  CLITERAL(Color){ 0x8a, 0xa0, 0xc0, 255 }
#define COL_TEXT_FAINT CLITERAL(Color){ 0x5e, 0x71, 0x96, 255 }
#define COL_ACCENT    CLITERAL(Color){ 0xff, 0xd3, 0x6b, 255 }
#define COL_GOOD      CLITERAL(Color){ 0x7b, 0xe0, 0x8a, 255 }
#define COL_WARN      CLITERAL(Color){ 0xff, 0xb4, 0x54, 255 }
#define COL_BAD       CLITERAL(Color){ 0xff, 0x66, 0x88, 255 }
#define COL_BLUE      CLITERAL(Color){ 0x6d, 0xb3, 0xff, 255 }

static Color with_alpha(Color c, double a) {
    c.a = (unsigned char)(255.0 * (a < 0 ? 0 : a > 1 ? 1 : a));
    return c;
}

/* CSS hsl() -> RGB. The web uses hsl(h, 72%, L%); raylib only ships HSV. */
static Color hsl_color(double h_deg, double s, double l) {
    double c = (1 - fabs(2 * l - 1)) * s;
    double hp = fmod(h_deg, 360.0) / 60.0;
    double x = c * (1 - fabs(fmod(hp, 2.0) - 1));
    double r = 0, g = 0, b = 0;
    if (hp < 1) { r = c; g = x; }
    else if (hp < 2) { r = x; g = c; }
    else if (hp < 3) { g = c; b = x; }
    else if (hp < 4) { g = x; b = c; }
    else if (hp < 5) { r = x; b = c; }
    else { r = c; b = x; }
    double m = l - c / 2;
    Color out = {
        (unsigned char)((r + m) * 255.0 + 0.5),
        (unsigned char)((g + m) * 255.0 + 0.5),
        (unsigned char)((b + m) * 255.0 + 0.5),
        255,
    };
    return out;
}

/** Player color from the server-assigned hue byte — hsl(hue/256*360, 72%, 62%). */
static Color hue_color(int hue, double alpha) {
    return with_alpha(hsl_color((double)hue / 256.0 * 360.0, 0.72, 0.62), alpha);
}

/* --------------------------------------------------------- WorldView */

typedef struct {
    double scale, ox, oy;
    double width, height;   /* the viewport this view was fitted into */
} world_view_t;

static void view_fit(world_view_t* v, double x, double y, double w, double h, double margin) {
    v->width = w;
    v->height = h;
    double sx = (w - margin * 2) / ARENA_W;
    double sy = (h - margin * 2) / ARENA_H;
    v->scale = sx < sy ? sx : sy;
    v->ox = x + (w - ARENA_W * v->scale) / 2;
    v->oy = y + (h - ARENA_H * v->scale) / 2;
}

static float vsx(const world_view_t* v, double x) { return (float)(v->ox + x * v->scale); }
static float vsy(const world_view_t* v, double y) { return (float)(v->oy + y * v->scale); }
static float vs(const world_view_t* v, double len) { return (float)(len * v->scale); }
static double vwx(const world_view_t* v, double px) { return (px - v->ox) / v->scale; }
static double vwy(const world_view_t* v, double py) { return (py - v->oy) / v->scale; }

/* ------------------------------------------------------------ shapes */

static void draw_arena(const world_view_t* v) {
    Color grid = with_alpha(COL_TEXT_DIM, 0.10);
    for (int x = 10; x < (int)ARENA_W; x += 10) {
        DrawLineV((Vector2){ vsx(v, x), vsy(v, 0) }, (Vector2){ vsx(v, x), vsy(v, ARENA_H) }, grid);
    }
    for (int y = 10; y < (int)ARENA_H; y += 10) {
        DrawLineV((Vector2){ vsx(v, 0), vsy(v, y) }, (Vector2){ vsx(v, ARENA_W), vsy(v, y) }, grid);
    }
    DrawRectangleLinesEx(
        (Rectangle){ vsx(v, 0), vsy(v, 0), vs(v, ARENA_W), vs(v, ARENA_H) },
        1.5f, with_alpha(COL_TEXT_DIM, 0.38));
}

static void draw_square(const world_view_t* v, double x, double y, double half, Color fill) {
    float s = vs(v, half);
    DrawRectangleV((Vector2){ vsx(v, x) - s, vsy(v, y) - s }, (Vector2){ s * 2, s * 2 }, fill);
}

static void draw_square_outline(const world_view_t* v, double x, double y, double half,
    Color stroke, float width) {
    float s = vs(v, half);
    DrawRectangleLinesEx(
        (Rectangle){ vsx(v, x) - s, vsy(v, y) - s, s * 2, s * 2 }, width, stroke);
}

/** Straight dashed segment in screen space. */
static void draw_dashed_screen(Vector2 a, Vector2 b, Color c, float width, float dash, float gap) {
    float dx = b.x - a.x, dy = b.y - a.y;
    float len = sqrtf(dx * dx + dy * dy);
    if (len < 0.5f) { return; }
    float ux = dx / len, uy = dy / len;
    for (float t = 0; t < len; t += dash + gap) {
        float t2 = t + dash;
        if (t2 > len) { t2 = len; }
        DrawLineEx((Vector2){ a.x + ux * t, a.y + uy * t },
                   (Vector2){ a.x + ux * t2, a.y + uy * t2 }, width, c);
    }
}

static void draw_line_world(const world_view_t* v, double x0, double y0, double x1, double y1,
    Color c, float width) {
    DrawLineEx((Vector2){ vsx(v, x0), vsy(v, y0) }, (Vector2){ vsx(v, x1), vsy(v, y1) }, width, c);
}

static void draw_dashed_world(const world_view_t* v, double x0, double y0, double x1, double y1,
    Color c, float width) {
    draw_dashed_screen((Vector2){ vsx(v, x0), vsy(v, y0) },
                       (Vector2){ vsx(v, x1), vsy(v, y1) }, c, width, 4, 3);
}

/** Dashed outline "ghost" — the standard marker for a raw server position. */
static void draw_ghost_square(const world_view_t* v, double x, double y, double half, Color c) {
    float s = vs(v, half);
    float l = vsx(v, x) - s, t = vsy(v, y) - s, r = l + s * 2, b = t + s * 2;
    draw_dashed_screen((Vector2){ l, t }, (Vector2){ r, t }, c, 1.5f, 4, 3);
    draw_dashed_screen((Vector2){ r, t }, (Vector2){ r, b }, c, 1.5f, 4, 3);
    draw_dashed_screen((Vector2){ r, b }, (Vector2){ l, b }, c, 1.5f, 4, 3);
    draw_dashed_screen((Vector2){ l, b }, (Vector2){ l, t }, c, 1.5f, 4, 3);
}

static void draw_circle_world(const world_view_t* v, double x, double y, double r, Color fill) {
    DrawCircleV((Vector2){ vsx(v, x), vsy(v, y) }, vs(v, r), fill);
}

static void draw_circle_outline_world(const world_view_t* v, double x, double y, double r, Color c) {
    DrawCircleLinesV((Vector2){ vsx(v, x), vsy(v, y) }, vs(v, r), c);
}

/** Dashed circle — the "raw snapshot" marker, matching drawCircle's dash set. */
static void draw_circle_dashed_world(const world_view_t* v, double x, double y, double r, Color c) {
    const int segments = 28;
    float cx = vsx(v, x), cy = vsy(v, y), pr = vs(v, r);
    for (int i = 0; i < segments; i += 2) {
        float a0 = (float)(i * 2 * PI / segments);
        float a1 = (float)((i + 1) * 2 * PI / segments);
        DrawLineEx((Vector2){ cx + cosf(a0) * pr, cy + sinf(a0) * pr },
                   (Vector2){ cx + cosf(a1) * pr, cy + sinf(a1) * pr }, 1.5f, c);
    }
}

static void draw_arrow_world(const world_view_t* v, double x0, double y0, double x1, double y1,
    Color c, float width) {
    Vector2 a = { vsx(v, x0), vsy(v, y0) }, b = { vsx(v, x1), vsy(v, y1) };
    float dx = b.x - a.x, dy = b.y - a.y;
    float len = sqrtf(dx * dx + dy * dy);
    if (len < 2) { return; }
    DrawLineEx(a, b, width, c);
    float hs = len * 0.4f < 8 ? len * 0.4f : 8;
    float ux = dx / len, uy = dy / len;
    DrawTriangle(
        b,
        (Vector2){ b.x - ux * hs + uy * hs * 0.5f, b.y - uy * hs - ux * hs * 0.5f },
        (Vector2){ b.x - ux * hs - uy * hs * 0.5f, b.y - uy * hs + ux * hs * 0.5f },
        c);
}

/** Crosshair marker (shot-impact style). */
static void draw_marker_world(const world_view_t* v, double x, double y, double r, Color c) {
    float px = vsx(v, x), py = vsy(v, y), pr = vs(v, r);
    DrawCircleLinesV((Vector2){ px, py }, pr, c);
    DrawLineEx((Vector2){ px - pr * 1.5f, py }, (Vector2){ px + pr * 1.5f, py }, 1.5f, c);
    DrawLineEx((Vector2){ px, py - pr * 1.5f }, (Vector2){ px, py + pr * 1.5f }, 1.5f, c);
}

/** Centered label anchored to a world position, offset by `dy` screen pixels. */
static void draw_label_world(const world_view_t* v, double x, double y, const char* text,
    Color c, int size, float dy) {
    int w = MeasureText(text, size);
    DrawText(text, (int)(vsx(v, x) - w / 2.0f), (int)(vsy(v, y) + dy), size, c);
}

/* ------------------------------------------------------------- trail */

#define TRAIL_MAX 180

typedef struct {
    double xs[TRAIL_MAX], ys[TRAIL_MAX];
    int head, count, cap;
} trail_t;

static void trail_init(trail_t* t, int cap) {
    memset(t, 0, sizeof(*t));
    t->cap = cap > TRAIL_MAX ? TRAIL_MAX : cap;
}

static void trail_clear(trail_t* t) { t->head = 0; t->count = 0; }

static void trail_push(trail_t* t, double x, double y) {
    t->xs[t->head] = x;
    t->ys[t->head] = y;
    t->head = (t->head + 1) % t->cap;
    if (t->count < t->cap) { t->count++; }
}

/** Fading polyline — oldest sample transparent, newest at `max_alpha`. */
static void trail_draw(const trail_t* t, const world_view_t* v, Color c, float width, double max_alpha) {
    if (t->count < 2) { return; }
    int start = (t->head - t->count + t->cap * 2) % t->cap;
    for (int i = 1; i < t->count; i++) {
        int a = (start + i - 1) % t->cap, b = (start + i) % t->cap;
        double alpha = max_alpha * ((double)i / (double)t->count);
        DrawLineEx((Vector2){ vsx(v, t->xs[a]), vsy(v, t->ys[a]) },
                   (Vector2){ vsx(v, t->xs[b]), vsy(v, t->ys[b]) },
                   width, with_alpha(c, alpha));
    }
}

#endif /* PLAYGROUND_VIEW_H */
