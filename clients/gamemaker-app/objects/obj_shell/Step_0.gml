/// Per-frame contract: process (drains network on THIS thread) → attach when
/// ready → lab.step (tick + paced sends + reconciler pump inside).

colyseus_process();

var _now = colyseus_predict_now();
var _dt = min(delta_time / 1000, 100);

if (phase == "joining" && joined && net_room > 0) {
    // state + our player entry may trail the join by a few patches
    if (lab_me(self) != 0) {
        sid = colyseus_room_get_session_id(net_room);
        callbacks = colyseus_callbacks_create(net_room);
        colyseus_on_add(callbacks, "players", __on_player_add);
        colyseus_on_remove(callbacks, "players", __on_player_remove);
        lab = labs[lab_index];
        if (lab.attach(self)) {
            phase = "ready";
            apply_latency();
        } else {
            lab = undefined;
        }
    } else {
        sid = colyseus_room_get_session_id(net_room);
    }
    if (phase == "joining" && current_time > attach_deadline) phase = "idle";
}

if (phase == "ready" && lab != undefined) {
    lab.step(self, _now, _dt);
}

// global keys: digits select by lab.num; [ / ] cycle (reaches 10/11)
for (var _k = 0; _k < array_length(labs); _k++) {
    if (labs[_k].num <= 9 && keyboard_check_pressed(ord(string(labs[_k].num))) && _k != lab_index) {
        switch_lab(_k);
        break;
    }
}
if (keyboard_check_pressed(vk_pageup) || keyboard_check_pressed(221)) {   // ]
    switch_lab((lab_index + 1) mod array_length(labs));
}
if (keyboard_check_pressed(vk_pagedown) || keyboard_check_pressed(219)) { // [
    switch_lab((lab_index - 1 + array_length(labs)) mod array_length(labs));
}
if (keyboard_check_pressed(ord("L"))) {
    latency_index = (latency_index + 1) mod array_length(latency_presets);
    apply_latency();
}
if (keyboard_check_pressed(ord("K"))) {
    // K = the cross-lane drop key; guard: no room until the first join lands
    if (net_room > 0) colyseus_netdelay_drop(net_room);
}
