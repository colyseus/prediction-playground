// =============================================================================
// Playground framework — world view, palette, trails, sparklines, HUD,
// keyboard. Port of clients/native-app/{view,hud,app}.h shapes to GML.
// =============================================================================

// palette (index.html / view.h)
#macro COL_BG      $1a0f0a   // GM colours are BGR
#macro COL_PANEL   $26160e
#macro COL_INSET   $301c12
#macro COL_BORDER  $4a3024
#macro COL_TEXT    $f0e2d8
#macro COL_DIM     $c0a08a
#macro COL_FAINT   $96715e
#macro COL_ACCENT  $6bd3ff
#macro COL_GOOD    $8ae07b
#macro COL_WARN    $54b4ff
#macro COL_BAD     $8866ff
#macro COL_BLUE    $ffb36d

#macro HUD_W 330

/// hueColor(hue8) — the server's HSL(h,72%,62%) as GM HSV (hue 0-255).
function hue_color(_hue8) {
    return make_color_hsv(_hue8, 156, 228);
}

// ── world view: the 100x60 arena letterboxed into the stage ────────────

function WorldView() constructor {
    ox = 0; oy = 0; s = 1; w = 0; h = 0;

    /// Fit the arena into a screen rect.
    static fit = function(_x, _y, _w, _h) {
        var _sx = _w / SIM_ARENA_W;
        var _sy = _h / SIM_ARENA_H;
        s = min(_sx, _sy) * 0.94;
        w = SIM_ARENA_W * s;
        h = SIM_ARENA_H * s;
        ox = _x + (_w - w) / 2;
        oy = _y + (_h - h) / 2;
    };
    static sx = function(_wx) { return ox + _wx * s; };
    static sy = function(_wy) { return oy + _wy * s; };
    static vs = function(_units) { return _units * s; };
    static wx = function(_px) { return (_px - ox) / s; };
    static wy = function(_py) { return (_py - oy) / s; };

    static draw_arena = function() {
        draw_set_color(COL_INSET);
        draw_rectangle(ox, oy, ox + w, oy + h, false);
        draw_set_color(COL_BORDER);
        draw_rectangle(ox, oy, ox + w, oy + h, true);
        // grid every 10 units
        draw_set_alpha(0.12);
        for (var _gx = 10; _gx < SIM_ARENA_W; _gx += 10) {
            draw_line(sx(_gx), oy, sx(_gx), oy + h);
        }
        for (var _gy = 10; _gy < SIM_ARENA_H; _gy += 10) {
            draw_line(ox, sy(_gy), ox + w, sy(_gy));
        }
        draw_set_alpha(1);
    };
}

/// filled player square (world units, half-extent)
function draw_square_w(_v, _x, _y, _half, _col) {
    var _hs = _v.vs(_half);
    draw_set_color(_col);
    draw_rectangle(_v.sx(_x) - _hs, _v.sy(_y) - _hs, _v.sx(_x) + _hs, _v.sy(_y) + _hs, false);
}

function draw_square_outline_w(_v, _x, _y, _half, _col) {
    var _hs = _v.vs(_half);
    draw_set_color(_col);
    draw_rectangle(_v.sx(_x) - _hs, _v.sy(_y) - _hs, _v.sx(_x) + _hs, _v.sy(_y) + _hs, true);
}

/// dashed "ghost" square — manual segment stepping (GM has no line dash)
function draw_ghost_square_w(_v, _x, _y, _half, _col, _alpha) {
    var _hs = _v.vs(_half);
    var _x0 = _v.sx(_x) - _hs, _y0 = _v.sy(_y) - _hs;
    var _x1 = _v.sx(_x) + _hs, _y1 = _v.sy(_y) + _hs;
    draw_set_color(_col);
    draw_set_alpha(_alpha);
    var _dash = 5, _gap = 4, _step = _dash + _gap;
    for (var _px = _x0; _px < _x1; _px += _step) {
        draw_line(_px, _y0, min(_px + _dash, _x1), _y0);
        draw_line(_px, _y1, min(_px + _dash, _x1), _y1);
    }
    for (var _py = _y0; _py < _y1; _py += _step) {
        draw_line(_x0, _py, _x0, min(_py + _dash, _y1));
        draw_line(_x1, _py, _x1, min(_py + _dash, _y1));
    }
    draw_set_alpha(1);
}

function draw_circle_w(_v, _x, _y, _radius, _col, _outline) {
    draw_set_color(_col);
    draw_circle(_v.sx(_x), _v.sy(_y), _v.vs(_radius), _outline);
}

function draw_arrow_w(_v, _x0, _y0, _x1, _y1, _col, _alpha) {
    var _ax0 = _v.sx(_x0), _ay0 = _v.sy(_y0);
    var _ax1 = _v.sx(_x1), _ay1 = _v.sy(_y1);
    draw_set_color(_col);
    draw_set_alpha(_alpha);
    draw_line_width(_ax0, _ay0, _ax1, _ay1, 2);
    var _dir = point_direction(_ax0, _ay0, _ax1, _ay1);
    draw_line_width(_ax1, _ay1, _ax1 + lengthdir_x(7, _dir + 150), _ay1 + lengthdir_y(7, _dir + 150), 2);
    draw_line_width(_ax1, _ay1, _ax1 + lengthdir_x(7, _dir - 150), _ay1 + lengthdir_y(7, _dir - 150), 2);
    draw_set_alpha(1);
}

function draw_label_w(_v, _x, _y, _text, _col, _dy) {
    draw_set_color(_col);
    draw_set_halign(fa_center);
    draw_text(_v.sx(_x), _v.sy(_y) + _dy, _text);
    draw_set_halign(fa_left);
}

// ── fading trail ───────────────────────────────────────────────────────

function Trail(_cap) constructor {
    cap = _cap;
    xs = array_create(_cap, 0);
    ys = array_create(_cap, 0);
    head = 0; count = 0;

    static push = function(_x, _y) {
        xs[head] = _x; ys[head] = _y;
        head = (head + 1) mod cap;
        if (count < cap) count += 1;
    };
    static clear = function() { count = 0; head = 0; };
    static draw = function(_v, _col, _max_alpha) {
        if (count < 2) return;
        var _prev_i = (head - count + cap) mod cap;
        for (var _k = 1; _k < count; _k++) {
            var _i = (_prev_i + 1) mod cap;
            draw_set_color(_col);
            draw_set_alpha(_max_alpha * _k / count);
            draw_line(_v.sx(xs[_prev_i]), _v.sy(ys[_prev_i]), _v.sx(xs[_i]), _v.sy(ys[_i]));
            _prev_i = _i;
        }
        draw_set_alpha(1);
    };
}

// ── sparkline (fixed 60-sample ring) ───────────────────────────────────

function Spark() constructor {
    cap = 60;
    vals = array_create(cap, 0);
    head = 0; count = 0;
    static push = function(_val) {
        vals[head] = _val;
        head = (head + 1) mod cap;
        if (count < cap) count += 1;
    };
    static draw = function(_x, _y, _w, _h, _col) {
        draw_set_color(COL_INSET);
        draw_rectangle(_x, _y, _x + _w, _y + _h, false);
        if (count < 2) return;
        var _peak = 0.0001;
        for (var _i = 0; _i < count; _i++) _peak = max(_peak, vals[_i]);
        draw_set_color(_col);
        var _i0 = (head - count + cap) mod cap;
        for (var _k = 1; _k < count; _k++) {
            var _a = (_i0 + _k - 1) mod cap;
            var _b = (_i0 + _k) mod cap;
            var _xa = _x + _w * (_k - 1) / (count - 1);
            var _xb = _x + _w * _k / (count - 1);
            draw_line(_xa, _y + _h - _h * vals[_a] / _peak, _xb, _y + _h - _h * vals[_b] / _peak);
        }
    };
}

// ── HUD: right panel of sections / rows / keys / sparks ────────────────

function Hud() constructor {
    x = 0; y = 0; cursor_y = 0;

    static begin = function(_x, _y, _h) {
        x = _x; y = _y; cursor_y = _y + 12;
        draw_set_color(COL_PANEL);
        draw_rectangle(_x, _y, _x + HUD_W, _y + _h, false);
        draw_set_color(COL_BORDER);
        draw_rectangle(_x, _y, _x + HUD_W, _y + _h, true);
        draw_set_font(-1);
    };
    static section = function(_title) {
        cursor_y += 8;
        draw_set_color(COL_FAINT);
        draw_text(x + 14, cursor_y, _title);
        cursor_y += 20;
    };
    static row = function(_label, _col, _value) {
        draw_set_color(COL_DIM);
        draw_text(x + 14, cursor_y, _label);
        draw_set_color(_col);
        draw_set_halign(fa_right);
        draw_text(x + HUD_W - 14, cursor_y, _value);
        draw_set_halign(fa_left);
        cursor_y += 18;
    };
    static key_hint = function(_key, _what) {
        draw_set_color(COL_ACCENT);
        draw_text(x + 14, cursor_y, _key);
        draw_set_color(COL_DIM);
        draw_text(x + 84, cursor_y, _what);
        cursor_y += 18;
    };
    static spark = function(_spark, _label, _value, _col) {
        row(_label, COL_TEXT, _value);
        _spark.draw(x + 14, cursor_y, HUD_W - 28, 26, _col);
        cursor_y += 32;
    };
    static chips = function(_label, _n, _cap) {
        row(_label, COL_TEXT, string(_n));
        var _cx = x + 14;
        for (var _i = 0; _i < min(_n, _cap); _i++) {
            draw_set_color(COL_ACCENT);
            draw_rectangle(_cx, cursor_y, _cx + 4, cursor_y + 8, false);
            _cx += 6;
        }
        cursor_y += 14;
    };
    static note = function(_text) {
        draw_set_color(COL_FAINT);
        var _wrap = HUD_W - 28;
        draw_text_ext(x + 14, cursor_y, _text, 14, _wrap);
        cursor_y += string_height_ext(_text, 14, _wrap) + 6;
    };
}

// ── keyboard ───────────────────────────────────────────────────────────

function kb_move_x() {
    return (keyboard_check(ord("D")) || keyboard_check(vk_right))
         - (keyboard_check(ord("A")) || keyboard_check(vk_left));
}
function kb_move_y() {
    return (keyboard_check(ord("S")) || keyboard_check(vk_down))
         - (keyboard_check(ord("W")) || keyboard_check(vk_up));
}
function kb_any_move() {
    return kb_move_x() != 0 || kb_move_y() != 0;
}

// ── fixed-step pacer (pre-reconciler labs; cap 5 like the predict tick) ─

function Pacer(_step_ms) constructor {
    step_ms = _step_ms;
    acc = 0; last = -1;
    static steps = function(_now) {
        if (last < 0) { last = _now; return 0; }
        acc += _now - last;
        last = _now;
        var _n = floor(acc / step_ms);
        if (_n > 5) { _n = 5; acc = 0; } else { acc -= _n * step_ms; }
        return _n;
    };
    static reset = function() { acc = 0; last = -1; };
}
