/// The playground shell: joins lab rooms, drives the active lab, owns the
/// arena view + HUD. Labs live in scr_labs; per-frame contract in Step.

// determinism gate — a wrong RNG width or step constant poisons every lab
canary_fail = sim_selfcheck();
if (canary_fail != "") show_debug_message("SIM CANARY FAILED: " + canary_fail);

#macro PLAYGROUND_ENDPOINT "http://127.0.0.1:5173"

client = colyseus_client_create(PLAYGROUND_ENDPOINT);
labs = lab_registry();
lab = undefined;          // active lab struct
lab_index = -1;
net_room = -1;
sid = "";
phase = "idle";           // idle | joining | ready
joined = false;
attach_deadline = 0;

view = new WorldView();
hud = new Hud();

// latency presets (L): delay ms / jitter ms
latency_presets = [[0, 0], [80, 0], [200, 0], [400, 80]];
latency_index = 0;

// remote roster via schema callbacks
callbacks = -1;
sids = [];

/// labs read the current roster
player_sids = function() { return sids; };

__on_player_add = function(_p, _key) {
    for (var _i = 0; _i < array_length(sids); _i++) if (sids[_i] == _key) return;
    array_push(sids, _key);
};
__on_player_remove = function(_p, _key) {
    for (var _i = 0; _i < array_length(sids); _i++) {
        if (sids[_i] == _key) { array_delete(sids, _i, 1); return; }
    }
};

switch_lab = function(_idx) {
    if (_idx < 0 || _idx >= array_length(labs)) return;
    if (lab != undefined) {
        lab.detach(self);
        lab = undefined;
    }
    if (net_room > 0) {
        colyseus_room_leave(net_room);
        var _t0 = current_time;
        while (current_time - _t0 < 400) { colyseus_process(); }
        colyseus_room_free(net_room);
        net_room = -1;
    }
    sids = [];
    joined = false;
    lab_index = _idx;
    net_room = colyseus_client_join_or_create(client, labs[_idx].room_name, "{}");
    if (net_room <= 0) { phase = "idle"; return; }
    colyseus_on_join(net_room, method(self, function(_r) { joined = true; }));
    colyseus_on_reconnect(net_room, method(self, function() {
        if (lab != undefined) lab.on_reconnect(self);
    }));
    phase = "joining";
    attach_deadline = current_time + 10000;
};

apply_latency = function() {
    var _p = latency_presets[latency_index];
    if (net_room > 0) colyseus_netdelay_set(net_room, _p[0], _p[1]);
};

// acceptance mode: headless self-check (COLYSEUS_ACCEPTANCE=1 env)
acceptance = environment_get_variable("COLYSEUS_ACCEPTANCE") == "1";
if (acceptance) {
    run_acceptance();   // busy-runs, prints ACCEPT lines, calls game_end()
} else {
    switch_lab(3);      // start on Lab 03 — the headline
}
