// =============================================================================
// Acceptance autopilot (`-acceptance` launch parameter): canaries, join,
// reconciler drift at wire precision, impulse correction. Busy-runs inside
// one Step (the GMTL pattern), prints ACCEPT lines, exits non-zero-visible
// via the final line. run-acceptance.sh greps "ACCEPTANCE FINISHED".
// =============================================================================

function __accept(_name, _ok, _detail) {
    show_debug_message((_ok ? "ACCEPT PASS " : "ACCEPT FAIL ") + _name
        + (_detail != "" ? " (" + _detail + ")" : ""));
    return _ok ? 1 : 0;
}

function run_acceptance() {
    var _pass = 0, _total = 0;

    // 1. determinism canaries
    _total += 1;
    _pass += __accept("canaries", canary_fail == "", canary_fail);

    // 2. join lab-move
    var _ctx = { done: false };
    var _room = colyseus_client_join_or_create(client, "lab-move", "{}");
    _total += 1;
    if (_room <= 0) {
        __accept("join", false, "join_or_create returned 0");
        show_debug_message("ACCEPTANCE FINISHED " + string(_pass) + "/" + string(_total));
        game_end();
        return;
    }
    colyseus_on_join(_room, method(_ctx, function(_r) { done = true; }));
    var _t0 = current_time;
    var _me = 0;
    var _sid = "";
    while (current_time - _t0 < 8000) {
        colyseus_process();
        if (!_ctx.done) continue;
        _sid = colyseus_room_get_session_id(_room);
        var _state = __colyseus_room_get_state(_room);
        if (_state != 0) _me = __colyseus_map_get(_state, "players", _sid);
        if (_me != 0) break;
    }
    _pass += __accept("join", _me != 0, "me=" + string(_me));

    if (_me != 0) {
        // 3. reconciler: drive right 3s, drift must hold wire precision
        var _input = new ColyseusInput(_room);
        var _predict = new ColyseusPredict(_room);
        var _recon = _predict.reconciler(_me, {
            fields: ["x", "y", "vx", "vy"],
            smooth_ms: 65, snap: 8,
            step: function(_ctx2, _s, _cmd) {
                sim_step_mirror(_s, _cmd.get("moveX"), _cmd.get("moveY"), _ctx2.dt);
            },
        });
        var _x0 = _recon.value("x");
        _t0 = current_time;
        while (current_time - _t0 < 3000) {
            colyseus_process();
            var _steps = _predict.tick(colyseus_predict_now());
            _recon.pump();
            repeat (_steps) {
                _input.set("moveX", 1);
                _input.set("moveY", 0);
                _input.send();
                _recon.pump();
            }
        }
        _total += 1;
        _pass += __accept("reconciler_drift",
            _recon.reconcile_seq() > 10 && _recon.drift_ema() < 0.01
            && (_recon.value("x") - _x0) > 5,
            "seq=" + string(_recon.reconcile_seq())
            + " drift=" + string_format(_recon.drift_ema(), 1, 4)
            + " dx=" + string_format(_recon.value("x") - _x0, 1, 1));

        // 4. impulse forces a visible correction
        colyseus_send(_room, "impulse", {});
        var _peak = 0;
        _t0 = current_time;
        while (current_time - _t0 < 2000) {
            colyseus_process();
            var _steps = _predict.tick(colyseus_predict_now());
            _recon.pump();
            repeat (_steps) {
                _input.set("moveX", 0);
                _input.set("moveY", 0);
                _input.send();
                _recon.pump();
            }
            _peak = max(_peak, _recon.last_correction_mag());
        }
        _total += 1;
        _pass += __accept("impulse_correction", _peak > 0.05,
            "peak=" + string_format(_peak, 1, 3));

        _recon.free_native();
        _predict.free_native();
    }

    colyseus_room_leave(_room);
    _t0 = current_time;
    while (current_time - _t0 < 400) { colyseus_process(); }
    colyseus_room_free(_room);

    show_debug_message("ACCEPTANCE FINISHED " + string(_pass) + "/" + string(_total));
    game_end();
}
