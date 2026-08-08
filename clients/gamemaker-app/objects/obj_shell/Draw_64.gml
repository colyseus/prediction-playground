/// Draw GUI: arena (letterboxed left of the HUD panel), HUD, active lab.

var _gw = display_get_gui_width();
var _gh = display_get_gui_height();

draw_set_color(COL_BG);
draw_rectangle(0, 0, _gw, _gh, false);

if (canary_fail != "") {
    draw_set_color(COL_BAD);
    draw_text(24, 24, "SIM CANARY FAILED: " + canary_fail);
    draw_set_color(COL_DIM);
    draw_text(24, 48, "The shared sim is not bit-exact - every lab below would lie. Fix scr_sim first.");
    exit;
}

view.fit(0, 34, _gw - HUD_W - 8, _gh - 40);
var _lab_owns_arena = phase == "ready" && lab != undefined
    && variable_struct_exists(lab, "own_arena") && lab.own_arena;
if (!_lab_owns_arena) view.draw_arena();

// top bar
draw_set_color(COL_TEXT);
var _title = (phase == "ready" && lab != undefined)
    ? "Lab " + string(lab.num) + " - " + lab.title
    : (phase == "joining" ? "joining " + labs[lab_index].room_name + "..." : "prediction playground");
draw_text(12, 8, _title);
if (phase == "ready" && lab != undefined) {
    draw_set_color(COL_FAINT);
    draw_text(12 + string_width(_title) + 16, 8, lab.blurb);
}

// HUD: shared rows first, then the lab appends its sections
hud.begin(_gw - HUD_W, 0, _gh);
hud.section("LINK");
if (net_room > 0) {
    hud.row("room", COL_TEXT, labs[lab_index].room_name);
    hud.row("connected", colyseus_room_is_connected(net_room) ? COL_GOOD : COL_BAD,
        colyseus_room_is_connected(net_room) ? "yes" : "no");
    hud.row("rtt", COL_ACCENT, string(round(__colyseus_gm_clock_stat(net_room, 2))) + " ms");
}
var _preset = latency_presets[latency_index];
hud.row("injected latency", _preset[0] > 0 ? COL_WARN : COL_DIM,
    string(_preset[0]) + (_preset[1] > 0 ? "+" + string(_preset[1]) + "j" : "") + " ms");
hud.key_hint("0-9", "switch lab");
hud.key_hint("L", "latency preset");
hud.key_hint("K", "drop connection");

if (phase == "ready" && lab != undefined) {
    lab.draw(self, view, hud);
}
