// =============================================================================
// Labs — M1: 01 Feel the Lag, 02 Clocks, 03 Predict & Reconcile.
// Ports of clients/native-app/labs/lab01..03. Contract per lab:
//   { num, title, blurb, room_name,
//     attach(shell) -> bool, step(shell, now, dt), draw(shell, v, hud),
//     detach(shell), on_reconnect(shell) }
// step() runs in the shell's Step event (logic + sends + pump); draw() in
// Draw GUI. Instance handles are re-resolved from a fresh state root every
// frame — raw handles dangle when the decoder replaces instances.
// =============================================================================

/// fresh root → players[sid] handle (0 when absent)
function lab_me(_shell) {
    var _state = __colyseus_room_get_state(_shell.net_room);
    if (_state == 0) return 0;
    return __colyseus_map_get(_state, "players", _shell.sid);
}

// ── Lab 01 — Feel the Lag ──────────────────────────────────────────────

function Lab01() constructor {
    num = 1;
    title = "Feel the Lag";
    blurb = "No prediction: every key press waits a full round trip.";
    room_name = "lab-move";

    static attach = function(_shell) {
        if (lab_me(_shell) == 0) return false;
        input = new ColyseusInput(_shell.net_room);
        if (!input.ok) return false;
        pacer = new Pacer(1000 / SIM_TICK_HZ);
        trail = new Trail(150);
        damped = {};          // sid → {x, y}
        raw_mode = true;
        damping = 12;
        phase = 0;            // 0 idle, 1 armed, 2 shown
        arm_t = 0; arm_x = 0; arm_y = 0; measured = 0;
        return true;
    };

    static step = function(_shell, _now, _dt) {
        if (keyboard_check_pressed(ord("R"))) { raw_mode = !raw_mode; trail.clear(); }
        if (keyboard_check_pressed(vk_subtract) && damping > 4) damping -= 2;
        if (keyboard_check_pressed(vk_add) && damping < 30) damping += 2;

        // one input per fixed server tick — no reconciler in this lab
        var _steps = pacer.steps(_now);
        repeat (_steps) {
            input.set("moveX", kb_move_x());
            input.set("moveY", kb_move_y());
            input.send();
        }

        // input → motion meter on the DECODED pose
        var _me = lab_me(_shell);
        if (_me != 0) {
            var _mx = __colyseus_schema_get_number(_me, "x");
            var _my = __colyseus_schema_get_number(_me, "y");
            var _speed = abs(__colyseus_schema_get_number(_me, "vx"))
                       + abs(__colyseus_schema_get_number(_me, "vy"));
            if (phase != 1 && kb_any_move() && _speed < 0.01) {
                phase = 1; arm_t = _now; arm_x = _mx; arm_y = _my;
            } else if (phase == 1) {
                if (abs(_mx - arm_x) > 0.03 || abs(_my - arm_y) > 0.03) {
                    measured = _now - arm_t;
                    phase = 2;
                } else if (!kb_any_move() && _now - arm_t > 2000) phase = 0;
            } else if (phase == 2 && !kb_any_move() && _speed < 0.01) phase = 0;
        }
    };

    static draw = function(_shell, _v, _hud) {
        var _dt_s = min(delta_time / 1000000, 0.1);
        var _sids = _shell.player_sids();
        for (var _i = 0; _i < array_length(_sids); _i++) {
            var _sid = _sids[_i];
            var _state = __colyseus_room_get_state(_shell.net_room);
            var _p = __colyseus_map_get(_state, "players", _sid);
            if (_p == 0) continue;
            var _px = __colyseus_schema_get_number(_p, "x");
            var _py = __colyseus_schema_get_number(_p, "y");
            var _hue = __colyseus_schema_get_number(_p, "hue");
            var _is_me = _sid == _shell.sid;

            // per-player damped shadow (render-side smoothing, still laggy)
            if (!variable_struct_exists(damped, _sid)) {
                variable_struct_set(damped, _sid, { x: _px, y: _py });
            }
            var _dm = variable_struct_get(damped, _sid);
            var _k = 1 - exp(-damping * _dt_s);
            _dm.x += (_px - _dm.x) * _k;
            _dm.y += (_py - _dm.y) * _k;
            var _rx = raw_mode ? _px : _dm.x;
            var _ry = raw_mode ? _py : _dm.y;

            if (_is_me) {
                trail.push(_rx, _ry);
                trail.draw(_v, hue_color(_hue), 0.45);
            }
            draw_square_w(_v, _rx, _ry, SIM_PLAYER_HALF, hue_color(_hue));
            if (_is_me) {
                draw_square_outline_w(_v, _rx, _ry, SIM_PLAYER_HALF, COL_TEXT);
                draw_label_w(_v, _rx, _ry, "you", COL_TEXT, -_v.vs(SIM_PLAYER_HALF) - 18);
            }
        }

        _hud.section("TELEMETRY");
        _hud.row("input -> motion", measured > 0 ? COL_BAD : COL_FAINT,
            measured > 0 ? string(round(measured)) + " ms" : "--");
        _hud.row("meter state", phase == 1 ? COL_WARN : (phase == 2 ? COL_GOOD : COL_DIM),
            phase == 1 ? "armed..." : (phase == 2 ? "measured" : "idle"));
        _hud.row("render strategy", COL_TEXT, raw_mode ? "raw" : "damped");
        _hud.row("damping", COL_TEXT, string(damping) + " /s");
        _hud.section("CONTROLS");
        _hud.key_hint("WASD", "drive");
        _hud.key_hint("R", "raw <-> damped");
        _hud.key_hint("- / +", "damping");
        _hud.note("raw = decoded server state verbatim. damped = smooth toward it (even laggier). predicted = Lab 3. Raise latency with L and feel it.");
    };

    static detach = function(_shell) {};
    static on_reconnect = function(_shell) { pacer.reset(); trail.clear(); phase = 0; };
}

// ── Lab 02 — Clocks & Timelines ────────────────────────────────────────

function Lab02() constructor {
    num = 2;
    title = "Clocks & Timelines";
    blurb = "now / serverNow / renderNow, RTT, jitter, patch cadence.";
    room_name = "lab-bots";

    static attach = function(_shell) {
        if (lab_me(_shell) == 0) return false;
        input = new ColyseusInput(_shell.net_room);
        if (!input.ok) return false;
        clock = new ColyseusClock(_shell.net_room);
        pacer = new Pacer(1000 / SIM_TICK_HZ);
        rtt_spark = new Spark();
        age_spark = new Spark();
        spark_gate = 0;
        last_patch_stamp = 0;
        return true;
    };

    static step = function(_shell, _now, _dt) {
        // inputs feed the clock: one send per tick = one RTT/offset sample
        var _steps = pacer.steps(_now);
        repeat (_steps) {
            input.set("moveX", kb_move_x());
            input.set("moveY", kb_move_y());
            input.send();
        }
        spark_gate += _dt;
        if (spark_gate >= 150) {
            spark_gate = 0;
            rtt_spark.push(clock.rtt());
            age_spark.push(clock.server_now() - clock.last_server_time());
        }
    };

    static draw = function(_shell, _v, _hud) {
        // me (raw) + the patrol bot at its decoded snapshot
        var _state = __colyseus_room_get_state(_shell.net_room);
        var _me = __colyseus_map_get(_state, "players", _shell.sid);
        if (_me != 0) {
            draw_square_w(_v, __colyseus_schema_get_number(_me, "x"),
                __colyseus_schema_get_number(_me, "y"), SIM_PLAYER_HALF,
                hue_color(__colyseus_schema_get_number(_me, "hue")));
        }
        var _bot = __colyseus_map_get(_state, "bots", "bot1");
        if (_bot != 0) {
            var _bx = __colyseus_schema_get_number(_bot, "x");
            var _by = __colyseus_schema_get_number(_bot, "y");
            draw_circle_w(_v, _bx, _by, SIM_BOT_RADIUS, COL_BLUE, false);
            draw_label_w(_v, _bx, _by, "bot (raw snapshots)", COL_FAINT, -_v.vs(SIM_BOT_RADIUS) - 18);
        }

        _hud.section("THE THREE TIMELINES");
        _hud.row("now (local)", COL_TEXT, string(round(clock.now())));
        _hud.row("serverNow (est)", COL_ACCENT, string(round(clock.server_now())));
        _hud.row("renderNow (slewed)", COL_GOOD, string(round(clock.render_now())));
        _hud.row("last patch stamp", COL_DIM, string(round(clock.last_server_time())));
        _hud.section("LINK QUALITY");
        _hud.spark(rtt_spark, "rtt", string(round(clock.rtt())) + " ms", COL_ACCENT);
        _hud.row("smoothed rtt", COL_TEXT, string(round(clock.smoothed_rtt())) + " ms");
        _hud.row("jitter", COL_TEXT, string(round(clock.jitter())) + " ms");
        _hud.spark(age_spark, "patch age", string(round(clock.server_now() - clock.last_server_time())) + " ms", COL_WARN);
        _hud.row("patch interval", COL_TEXT, string(round(clock.patch_interval())) + " ms");
        _hud.section("CONTROLS");
        _hud.key_hint("WASD", "drive (feeds the clock)");
        _hud.key_hint("L", "latency preset");
        _hud.note("No clock API call exists: defineInput() rooms stamp every input round-trip, and net_room.clock maintains itself.");
    };

    static detach = function(_shell) {};
    static on_reconnect = function(_shell) { pacer.reset(); };
}

// ── Lab 03 — Predict & Reconcile ───────────────────────────────────────

function Lab03() constructor {
    num = 3;
    title = "Predict & Reconcile";
    blurb = "Rollback to the ack, replay pending inputs, smooth the error.";
    room_name = "lab-move";

    static __make_recon = function(_shell) {
        var _me = lab_me(_shell);
        if (_me == 0) return false;
        recon = predict.reconciler(_me, {
            fields: ["x", "y", "vx", "vy"],
            smoothing: smoothing,
            step: function(_ctx, _s, _cmd) {
                sim_step_mirror(_s, _cmd.get("moveX"), _cmd.get("moveY"), _ctx.dt);
            },
        });
        last_seq = 0;
        return recon.id > 0;
    };

    static attach = function(_shell) {
        if (lab_me(_shell) == 0) return false;
        input = new ColyseusInput(_shell.net_room);
        if (!input.ok) return false;
        predict = new ColyseusPredict(_shell.net_room);
        // remotes: damped toward the latest snapshot (their inputs aren't ours)
        predict.attach_all("players",
            { x: COLYSEUS_PREDICT_DAMPED, y: COLYSEUS_PREDICT_DAMPED }, _shell.sid);
        smoothing = 15;
        render_smoothed = true;
        show_ghost = true;
        auto_snap = true;
        corrections = 0;
        max_corr = 0;
        arrows = [];
        rebind = false;
        predicted_trail = new Trail(150);
        server_trail = new Trail(150);
        drift_spark = new Spark();
        spark_gate = 0;
        return __make_recon(_shell);
    };

    static step = function(_shell, _now, _dt) {
        if (rebind) {
            if (lab_me(_shell) == 0) return;
            recon.free_native();
            if (__make_recon(_shell)) {
                rebind = false;
                predicted_trail.clear();
                server_trail.clear();
                arrows = [];
            } else return;
        }

        if (keyboard_check_pressed(ord("I"))) colyseus_send(_shell.net_room, "impulse", {});
        if (keyboard_check_pressed(ord("T"))) colyseus_send(_shell.net_room, "teleport", {});
        if (keyboard_check_pressed(ord("V"))) render_smoothed = !render_smoothed;
        if (keyboard_check_pressed(ord("G"))) show_ghost = !show_ghost;
        if (keyboard_check_pressed(ord("N"))) auto_snap = !auto_snap;
        var _sm_step = keyboard_check_pressed(vk_add) ? 5 : (keyboard_check_pressed(vk_subtract) ? -5 : 0);
        if (_sm_step != 0) {
            smoothing = clamp(smoothing + _sm_step, 0, 40);
            // smoothing is a construction parameter — rebuild, like the web slider
            recon.free_native();
            __make_recon(_shell);
        }

        // drive: tick paces the sends; the pump runs replay bursts + live steps
        var _steps = predict.tick(_now);
        recon.pump();
        repeat (_steps) {
            input.set("moveX", kb_move_x());
            input.set("moveY", kb_move_y());
            input.send();
            recon.pump();
        }

        // reconcile telemetry
        var _seq = recon.reconcile_seq();
        if (_seq != last_seq) {
            last_seq = _seq;
            var _mag = recon.last_correction_mag();
            if (_mag > 0.02) {
                corrections += 1;
                max_corr = max(max_corr, _mag);
                var _cx = recon.last_correction("x");
                var _cy = recon.last_correction("y");
                var _px = recon.state.get("x");
                var _py = recon.state.get("y");
                array_push(arrows, { x0: _px - _cx, y0: _py - _cy, x1: _px, y1: _py, t: _now });
                if (array_length(arrows) > 8) array_delete(arrows, 0, 1);
            }
            if (auto_snap && _mag > SIM_TELEPORT_SNAP_DIST) {
                recon.reset();
                predicted_trail.clear();
                server_trail.clear();
            }
        }
        spark_gate += _dt;
        if (spark_gate >= 100) { spark_gate = 0; drift_spark.push(recon.drift_ema()); }
    };

    static draw = function(_shell, _v, _hud) {
        var _now = colyseus_predict_now();
        var _state = __colyseus_room_get_state(_shell.net_room);

        // remotes through predict.value (damped)
        var _sids = _shell.player_sids();
        for (var _i = 0; _i < array_length(_sids); _i++) {
            if (_sids[_i] == _shell.sid) continue;
            var _p = __colyseus_map_get(_state, "players", _sids[_i]);
            if (_p == 0) continue;
            draw_square_w(_v, predict.value(_p, "x"), predict.value(_p, "y"),
                SIM_PLAYER_HALF, merge_color(hue_color(__colyseus_schema_get_number(_p, "hue")), COL_BG, 0.4));
        }

        var _me = __colyseus_map_get(_state, "players", _shell.sid);
        if (_me == 0 || rebind) return;
        var _hue = __colyseus_schema_get_number(_me, "hue");

        // server ghost: the raw authoritative pose — trails by ~RTT
        if (show_ghost) {
            var _gx = __colyseus_schema_get_number(_me, "x");
            var _gy = __colyseus_schema_get_number(_me, "y");
            server_trail.push(_gx, _gy);
            server_trail.draw(_v, COL_TEXT, 0.3);
            draw_ghost_square_w(_v, _gx, _gy, SIM_PLAYER_HALF, COL_TEXT, 0.75);
            draw_label_w(_v, _gx, _gy, "server", COL_FAINT, _v.vs(SIM_PLAYER_HALF) + 6);
        }

        var _px = render_smoothed ? recon.value("x") : recon.state.get("x");
        var _py = render_smoothed ? recon.value("y") : recon.state.get("y");
        predicted_trail.push(_px, _py);
        predicted_trail.draw(_v, hue_color(_hue), 0.45);
        draw_square_w(_v, _px, _py, SIM_PLAYER_HALF, hue_color(_hue));
        draw_square_outline_w(_v, _px, _py, SIM_PLAYER_HALF, COL_TEXT);
        draw_label_w(_v, _px, _py, "you (predicted)", COL_TEXT, -_v.vs(SIM_PLAYER_HALF) - 18);

        // correction arrows fade over 900ms
        for (var _i = array_length(arrows) - 1; _i >= 0; _i--) {
            var _age = _now - arrows[_i].t;
            if (_age > 900) { array_delete(arrows, _i, 1); continue; }
            draw_arrow_w(_v, arrows[_i].x0, arrows[_i].y0, arrows[_i].x1, arrows[_i].y1,
                COL_BAD, 1 - _age / 900);
        }

        var _drift = recon.drift_ema();
        _hud.section("TELEMETRY");
        _hud.chips("pending inputs (unacked)", recon.pending_count(), 48);
        _hud.row("drift status", _drift < 0.05 ? COL_GOOD : (_drift < 0.5 ? COL_WARN : COL_BAD),
            _drift < 0.05 ? "matched" : (_drift < 0.5 ? "jitter" : "diverging"));
        _hud.spark(drift_spark, "drift ema", string_format(_drift, 1, 4), COL_ACCENT);
        _hud.row("last correction", COL_TEXT, string_format(recon.last_correction_mag(), 1, 3));
        _hud.row("corrections seen", COL_TEXT, string(corrections));
        _hud.row("reconciles", COL_TEXT, string(recon.reconcile_seq()));
        _hud.section("CONTROLS");
        _hud.key_hint("WASD", "drive");
        _hud.key_hint("I", "force mispredict (impulse)");
        _hud.key_hint("T", "teleport");
        _hud.key_hint("- / +", "smoothing  " + string(smoothing) + " /s");
        _hud.key_hint("V", render_smoothed ? "render: value() smoothed" : "render: state (exact)");
        _hud.key_hint("G", show_ghost ? "server ghost: on" : "server ghost: off");
        _hud.key_hint("N", auto_snap ? "snap on teleport: on" : "snap on teleport: off");
        _hud.note("Corrections beyond 8u call reset() - a cut, not a cross-arena glide. Toggle N and teleport to see why.");
    };

    static detach = function(_shell) {
        if (recon != undefined) recon.free_native();
        if (predict != undefined) predict.free_native();
    };
    static on_reconnect = function(_shell) { rebind = true; };
}

/// The lab registry — select with the digit matching lab.num.
function lab_registry() {
    return [new Lab00(), new Lab01(), new Lab02(), new Lab03(),
            new Lab04(), new Lab05(), new Lab06(), new Lab07(),
            new Lab08(), new Lab09(), new Lab10(), new Lab11()];
}
