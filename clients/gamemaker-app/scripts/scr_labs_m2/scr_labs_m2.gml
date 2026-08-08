// =============================================================================
// Labs — M2: 00 Split Screen, 04 Interpolation Modes, 05 Dead Reckoning,
// 08 Optimistic Events, 09 Predicted Spawns.
// Ports of clients/native-app/labs/lab00/04/05/08/09 (lab05's bot step uses
// the bridge's built-in INTEGRATE+bounce projection — patrol bots reckon
// exactly; wander/teleport bots mispredict, which is the lab's own lesson).
// =============================================================================

// ── Lab 00 — Split Screen: echo vs prediction, same room ───────────────

function Lab00() constructor {
    num = 0;
    title = "Split Screen";
    blurb = "Left: echo (decoded state). Right: predicted. Same entity, same room.";
    room_name = "lab-move";
    own_arena = true;

    static __make_recon = function(_shell) {
        var _me = lab_me(_shell);
        if (_me == 0) return false;
        recon = predict.reconciler(_me, {
            fields: ["x", "y", "vx", "vy"],
            smoothing: 15,
            step: function(_ctx, _s, _cmd) {
                sim_step_mirror(_s, _cmd.get("moveX"), _cmd.get("moveY"), _ctx.dt);
            },
        });
        return recon.id > 0;
    };

    static attach = function(_shell) {
        if (lab_me(_shell) == 0) return false;
        input = new ColyseusInput(_shell.net_room);
        if (!input.ok) return false;
        predict = new ColyseusPredict(_shell.net_room);
        view_l = new WorldView();
        view_r = new WorldView();
        rebind = false;
        return __make_recon(_shell);
    };

    static step = function(_shell, _now, _dt) {
        if (rebind) {
            if (lab_me(_shell) == 0) return;
            recon.free_native();
            if (__make_recon(_shell)) rebind = false; else return;
        }
        var _steps = predict.tick(_now);
        recon.pump();
        repeat (_steps) {
            input.set("moveX", kb_move_x());
            input.set("moveY", kb_move_y());
            input.send();
            recon.pump();
        }
    };

    static draw = function(_shell, _v, _hud) {
        // two lanes inside the shell's arena rect
        var _gw = display_get_gui_width();
        var _gh = display_get_gui_height();
        var _half_w = (_gw - HUD_W - 24) / 2;
        view_l.fit(4, 34, _half_w, _gh - 40);
        view_r.fit(12 + _half_w, 34, _half_w, _gh - 40);
        view_l.draw_arena();
        view_r.draw_arena();

        var _me = lab_me(_shell);
        if (_me == 0 || rebind) return;
        var _hue = __colyseus_schema_get_number(_me, "hue");

        // left lane: the ECHO — decoded state verbatim, a round trip late
        draw_square_w(view_l, __colyseus_schema_get_number(_me, "x"),
            __colyseus_schema_get_number(_me, "y"), SIM_PLAYER_HALF, hue_color(_hue));
        draw_label_w(view_l, 50, 2, "ECHO - waits the round trip", COL_FAINT, 0);

        // right lane: the PREDICTION — moves the same frame the key lands
        draw_square_w(view_r, recon.value("x"), recon.value("y"), SIM_PLAYER_HALF, hue_color(_hue));
        draw_square_outline_w(view_r, recon.value("x"), recon.value("y"), SIM_PLAYER_HALF, COL_TEXT);
        draw_label_w(view_r, 50, 2, "PREDICTED - immediate", COL_ACCENT, 0);

        _hud.section("TELEMETRY");
        _hud.chips("pending inputs", recon.pending_count(), 48);
        _hud.row("drift ema", COL_ACCENT, string_format(recon.drift_ema(), 1, 4));
        _hud.section("CONTROLS");
        _hud.key_hint("WASD", "drive BOTH lanes");
        _hud.note("Same room, same inputs. Raise latency with L: the left square waits, the right one does not.");
    };

    static detach = function(_shell) {
        if (recon != undefined) recon.free_native();
        if (predict != undefined) predict.free_native();
    };
    static on_reconnect = function(_shell) { rebind = true; };
}

// ── Lab 04 — Interpolation Modes: one bot, four smoothing strategies ───

function Lab04() constructor {
    num = 4;
    title = "Interpolation Modes";
    blurb = "raw / lerp / damped / extrapolate over the same snapshot stream.";
    room_name = "lab-bots";

    static attach = function(_shell) {
        if (lab_me(_shell) == 0) return false;
        input = new ColyseusInput(_shell.net_room);
        if (!input.ok) return false;
        pacer = new Pacer(1000 / SIM_TICK_HZ);
        // four Predicts over ONE room — each attaches the bots with one mode
        modes = [
            { label: "raw",         col: COL_FAINT,  p: new ColyseusPredict(_shell.net_room),
              cfg: { x: COLYSEUS_PREDICT_RAW, y: COLYSEUS_PREDICT_RAW } },
            { label: "lerp 100ms",  col: COL_ACCENT, p: new ColyseusPredict(_shell.net_room),
              cfg: { x: { mode: COLYSEUS_PREDICT_LERP, delay: 100 }, y: { mode: COLYSEUS_PREDICT_LERP, delay: 100 } } },
            { label: "damped",      col: COL_GOOD,   p: new ColyseusPredict(_shell.net_room),
              cfg: { x: COLYSEUS_PREDICT_DAMPED, y: COLYSEUS_PREDICT_DAMPED } },
            { label: "extrapolate", col: COL_WARN,   p: new ColyseusPredict(_shell.net_room),
              cfg: { x: COLYSEUS_PREDICT_EXTRAPOLATE, y: COLYSEUS_PREDICT_EXTRAPOLATE } },
        ];
        for (var _i = 0; _i < 4; _i++) {
            modes[_i].p.attach_all("bots", modes[_i].cfg);
        }
        return true;
    };

    static step = function(_shell, _now, _dt) {
        var _steps = pacer.steps(_now);
        repeat (_steps) {
            input.set("moveX", kb_move_x());
            input.set("moveY", kb_move_y());
            input.send();
        }
        for (var _i = 0; _i < 4; _i++) modes[_i].p.tick(_now);
    };

    static draw = function(_shell, _v, _hud) {
        var _state = __colyseus_room_get_state(_shell.net_room);
        var _bot = __colyseus_map_get(_state, "bots", "bot1");
        _hud.section("MODES (one bot, four readers)");
        if (_bot != 0) {
            // draw the same bot once per mode, offset in Y so all four show
            for (var _i = 0; _i < 4; _i++) {
                var _bx = modes[_i].p.value(_bot, "x");
                var _by = modes[_i].p.value(_bot, "y") + (_i - 1.5) * 5;
                draw_circle_w(_v, _bx, _by, SIM_BOT_RADIUS, modes[_i].col, false);
                draw_label_w(_v, _bx, _by, modes[_i].label, modes[_i].col, -_v.vs(SIM_BOT_RADIUS) - 16);
                _hud.row(modes[_i].label, modes[_i].col, string_format(_bx, 1, 2));
            }
        }
        var _me = lab_me(_shell);
        if (_me != 0) {
            draw_square_w(_v, __colyseus_schema_get_number(_me, "x"),
                __colyseus_schema_get_number(_me, "y"), SIM_PLAYER_HALF,
                hue_color(__colyseus_schema_get_number(_me, "hue")));
        }
        _hud.section("CONTROLS");
        _hud.key_hint("L", "latency preset (watch raw stutter)");
        _hud.note("raw shows every snapshot as a jump. lerp renders 100ms in the past. damped chases. extrapolate guesses ahead and overshoots on turns.");
    };

    static detach = function(_shell) {
        for (var _i = 0; _i < array_length(modes); _i++) modes[_i].p.free_native();
    };
    static on_reconnect = function(_shell) { pacer.reset(); };
}

// ── Lab 05 — Dead Reckoning: forward-simulate the snapshot ─────────────

function Lab05() constructor {
    num = 5;
    title = "Dead Reckoning";
    blurb = "Project remotes to NOW with their own motion model.";
    room_name = "lab-bots";

    static attach = function(_shell) {
        if (lab_me(_shell) == 0) return false;
        input = new ColyseusInput(_shell.net_room);
        if (!input.ok) return false;
        pacer = new Pacer(1000 / SIM_TICK_HZ);
        // reckon: project by velocity, bounce off arena edges (patrol bots
        // reckon exactly; wander/teleport bots WARP on reveal — the lesson)
        reckon = new ColyseusPredict(_shell.net_room);
        reckon.attach_all_reckon("bots", ["x", "y"], COLYSEUS_STEP_INTEGRATE,
            json_stringify({ bounds: [SIM_BOT_RADIUS, SIM_BOT_RADIUS,
                SIM_ARENA_W - SIM_BOT_RADIUS, SIM_ARENA_H - SIM_BOT_RADIUS], edge: "bounce" }),
            0, 10, 6);
        // the lerp ghost trails ~100ms behind — the thing reckoning removes
        lerp_ghost = new ColyseusPredict(_shell.net_room);
        lerp_ghost.attach_all("bots", { x: { mode: COLYSEUS_PREDICT_LERP, delay: 100 },
                                  y: { mode: COLYSEUS_PREDICT_LERP, delay: 100 } });
        return true;
    };

    static step = function(_shell, _now, _dt) {
        var _steps = pacer.steps(_now);
        repeat (_steps) {
            input.set("moveX", kb_move_x());
            input.set("moveY", kb_move_y());
            input.send();
        }
        reckon.tick(_now);
        lerp_ghost.tick(_now);
    };

    static draw = function(_shell, _v, _hud) {
        var _state = __colyseus_room_get_state(_shell.net_room);
        var _keys = ["bot1", "bot2", "bot3"];
        _hud.section("RECKONED BOTS");
        for (var _i = 0; _i < array_length(_keys); _i++) {
            var _bot = __colyseus_map_get(_state, "bots", _keys[_i]);
            if (_bot == 0) continue;
            // lerp ghost (dashed ~ the past) vs reckoned body (the present)
            draw_ghost_square_w(_v, lerp_ghost.value(_bot, "x"), lerp_ghost.value(_bot, "y"),
                SIM_BOT_RADIUS, COL_FAINT, 0.6);
            draw_circle_w(_v, reckon.value(_bot, "x"), reckon.value(_bot, "y"),
                SIM_BOT_RADIUS, COL_BLUE, false);
            var _kind = __colyseus_schema_get_string(_bot, "kind");
            draw_label_w(_v, reckon.value(_bot, "x"), reckon.value(_bot, "y"),
                _kind, COL_DIM, -_v.vs(SIM_BOT_RADIUS) - 16);
            _hud.row(_keys[_i] + " (" + _kind + ")", COL_TEXT,
                string_format(reckon.value(_bot, "x") - lerp_ghost.value(_bot, "x"), 1, 1) + "u lead");
        }
        var _me = lab_me(_shell);
        if (_me != 0) {
            draw_square_w(_v, __colyseus_schema_get_number(_me, "x"),
                __colyseus_schema_get_number(_me, "y"), SIM_PLAYER_HALF,
                hue_color(__colyseus_schema_get_number(_me, "hue")));
        }
        _hud.section("CONTROLS");
        _hud.key_hint("L", "latency preset (the lead grows)");
        _hud.note("Solid = snapshot projected to NOW by its motion model. Dashed = lerp, ~100ms in the past. Patrol bots reckon exactly; wander bots change heading server-side and WARP on reveal.");
    };

    static detach = function(_shell) {
        reckon.free_native();
        lerp_ghost.free_native();
    };
    static on_reconnect = function(_shell) { pacer.reset(); };
}

// ── Lab 08 — Optimistic Events: the goal gate ──────────────────────────

function Lab08() constructor {
    num = 8;
    title = "Optimistic Events";
    blurb = "Predict the GOAL! banner; confirm or retract on the verdict.";
    room_name = "lab-goal";

    static __make_recon = function(_shell) {
        var _me = lab_me(_shell);
        if (_me == 0) return false;
        var _lab_self = self;
        recon = predict.reconciler(_me, {
            fields: ["x", "y", "vx", "vy", "scoreTicks"],
            smoothing: 15,
            step: method({ lab: _lab_self }, function(_ctx, _s, _cmd) {
                sim_step_mirror(_s, _cmd.get("moveX"), _cmd.get("moveY"), _ctx.dt);
                // the scoring gate (src/shared/goal.ts) — deterministic replay
                var _ticks = _s.get("scoreTicks");
                if (_ticks > 0) _s.set("scoreTicks", _ticks - 1);
                else {
                    var _x = _s.get("x"), _y = _s.get("y");
                    if (_x >= SIM_ARENA_W - 8 && _y >= SIM_ARENA_H / 2 - 9
                     && _y <= SIM_ARENA_H / 2 + 9) {
                        _s.set("scoreTicks", SIM_SCORE_COOLDOWN_TICKS);
                        if (!_ctx.is_replay) _ctx.predict(lab.goals, "goal-" + string(_ctx.tick));
                    }
                }
            }),
        });
        return recon.id > 0;
    };

    static attach = function(_shell) {
        if (lab_me(_shell) == 0) return false;
        input = new ColyseusInput(_shell.net_room);
        if (!input.ok) return false;
        predict = new ColyseusPredict(_shell.net_room);
        deny_rate = 0;
        banner = "";           // "" | "pending" | "confirmed" | "denied"
        banner_t = 0;
        tally = { predicted: 0, confirmed: 0, rejected: 0 };
        var _lab8 = self;   // `self` inside a struct literal binds to the literal
        goals = predict.define_event({
            grace_ticks: 10,
            on_predict: method(_lab8, function(_k) { tally.predicted += 1; banner = "pending"; banner_t = colyseus_predict_now(); }),
            on_confirm: method(_lab8, function(_k) { tally.confirmed += 1; banner = "confirmed"; banner_t = colyseus_predict_now(); }),
            on_reject:  method(_lab8, function(_k) { tally.rejected += 1; banner = "denied"; banner_t = colyseus_predict_now(); }),
        });
        var _lab_self = self;
        colyseus_on_message(_shell.net_room, method({ lab: _lab_self, shell: _shell }, function(_r, _type, _payload) {
            if (_type == "goal" && is_struct(_payload) && _payload[$ "sid"] == shell.sid) {
                lab.goals.confirm();
            }
        }));
        rebind = false;
        colyseus_send(_shell.net_room, "denyRate", { rate: deny_rate });
        return __make_recon(_shell);
    };

    static step = function(_shell, _now, _dt) {
        if (rebind) {
            if (lab_me(_shell) == 0) return;
            recon.free_native();
            if (__make_recon(_shell)) rebind = false; else return;
        }
        var _delta = keyboard_check_pressed(vk_add) ? 25 : (keyboard_check_pressed(vk_subtract) ? -25 : 0);
        if (_delta != 0) {
            deny_rate = clamp(deny_rate + _delta, 0, 100);
            colyseus_send(_shell.net_room, "denyRate", { rate: deny_rate });
        }
        var _steps = predict.tick(_now);
        recon.pump();
        repeat (_steps) {
            input.set("moveX", kb_move_x());
            input.set("moveY", kb_move_y());
            input.send();
            recon.pump();
        }
    };

    static draw = function(_shell, _v, _hud) {
        var _now = colyseus_predict_now();
        // the goal zone strip
        draw_set_color(COL_GOOD);
        draw_set_alpha(0.15);
        draw_rectangle(_v.sx(SIM_ARENA_W - 8), _v.sy(SIM_ARENA_H / 2 - 9),
                       _v.sx(SIM_ARENA_W), _v.sy(SIM_ARENA_H / 2 + 9), false);
        draw_set_alpha(1);
        draw_label_w(_v, SIM_ARENA_W - 4, SIM_ARENA_H / 2, "GOAL", COL_GOOD, 0);

        var _me = lab_me(_shell);
        if (_me == 0 || rebind) return;
        draw_square_w(_v, recon.value("x"), recon.value("y"), SIM_PLAYER_HALF,
            hue_color(__colyseus_schema_get_number(_me, "hue")));

        // the optimistic banner: shows the same frame the gate fires
        if (banner != "" && _now - banner_t < 1600) {
            var _col = banner == "confirmed" ? COL_GOOD : (banner == "denied" ? COL_BAD : COL_WARN);
            draw_set_color(_col);
            draw_set_halign(fa_center);
            draw_text(_v.sx(SIM_ARENA_W / 2), _v.sy(8),
                banner == "denied" ? "DENIED" : "GOAL!" + (banner == "pending" ? " (pending)" : ""));
            draw_set_halign(fa_left);
        }

        _hud.section("TELEMETRY");
        _hud.row("predicted", COL_WARN, string(tally.predicted));
        _hud.row("confirmed", COL_GOOD, string(tally.confirmed));
        _hud.row("rejected", COL_BAD, string(tally.rejected));
        _hud.row("pending", COL_TEXT, string(goals.pending_count()));
        _hud.section("CONTROLS");
        _hud.key_hint("WASD", "run into the zone");
        _hud.key_hint("- / +", "server deny rate  " + string(deny_rate) + "%");
        _hud.note("The banner fires optimistically on the gate edge. The server broadcast confirms it; at 100% deny the grace ticks retract it instead.");
    };

    static detach = function(_shell) {
        goals.free_native();
        recon.free_native();
        predict.free_native();
    };
    static on_reconnect = function(_shell) { rebind = true; };
}

// ── Lab 09 — Predicted Spawns: fire before the server knows ────────────

function Lab09() constructor {
    num = 9;
    title = "Predicted Spawns";
    blurb = "Optimistic projectiles that hand off to the authoritative entity.";
    room_name = "lab-projectile";

    static __make_recon = function(_shell) {
        var _me = lab_me(_shell);
        if (_me == 0) return false;
        recon = predict.reconciler(_me, {
            fields: ["x", "y", "vx", "vy"],
            smoothing: 15,
            step: function(_ctx, _s, _cmd) {
                sim_step_mirror(_s, _cmd.get("moveX"), _cmd.get("moveY"), _ctx.dt);
            },
        });
        return recon.id > 0;
    };

    static attach = function(_shell) {
        if (lab_me(_shell) == 0) return false;
        input = new ColyseusInput(_shell.net_room);
        if (!input.ok) return false;
        predict = new ColyseusPredict(_shell.net_room);
        shots = predict.spawns("projectiles", {
            fields: ["x", "y", "vx", "vy"],
            owned_field: "owner",
            owned_value: _shell.sid,
            spawn_time_field: "bornMs",
            step_id: COLYSEUS_STEP_INTEGRATE,
            step_params: json_stringify({ bounds: [0, 0, SIM_ARENA_W, SIM_ARENA_H], edge: "bounce" }),
        });
        if (shots.id <= 0) return false;
        last_lead = 0;
        fired = 0;
        fire_pending = false;
        rebind = false;
        aim_x = SIM_ARENA_W / 2;
        aim_y = SIM_ARENA_H / 2;
        return __make_recon(_shell);
    };

    static step = function(_shell, _now, _dt) {
        if (rebind) {
            if (lab_me(_shell) == 0) return;
            recon.free_native();
            if (__make_recon(_shell)) rebind = false; else return;
        }
        // latch: clicks land between fixed steps — hold until one is due
        if (mouse_check_button_pressed(mb_left) || keyboard_check_pressed(vk_space)) fire_pending = true;
        var _steps = predict.tick(_now);
        recon.pump();
        repeat (_steps) {
            input.set("moveX", kb_move_x());
            input.set("moveY", kb_move_y());
            var _wx = clamp(aim_x, 0, SIM_ARENA_W);
            var _wy = clamp(aim_y, 0, SIM_ARENA_H);
            input.set("aimX", _wx);
            input.set("aimY", _wy);
            input.set("fire", fire_pending ? 1 : 0);
            input.send();
            recon.pump();
            if (fire_pending) {
                fire_pending = false;
                fired += 1;
                // spawn at the PREDICTED pose (the mirror, post-step) — the
                // same origin the server uses when this input arrives. The
                // decoded pose trails a moving shooter, and the handoff would
                // visibly jump forward in the movement direction.
                var _px = recon.state.get("x");
                var _py = recon.state.get("y");
                var _d = point_distance(_px, _py, _wx, _wy);
                if (_d < 0.001) _d = 1;
                shots.spawn({ x: _px, y: _py,
                    vx: (_wx - _px) / _d * SIM_PROJECTILE_SPEED,
                    vy: (_wy - _py) / _d * SIM_PROJECTILE_SPEED });
            }
        }
        // surface the newest confirmed lead for the HUD
        var _entries = shots.entries();
        for (var _i = 0; _i < array_length(_entries); _i++) {
            if (_entries[_i].confirmed && _entries[_i].lead_ms > 0) last_lead = _entries[_i].lead_ms;
        }
    };

    static draw = function(_shell, _v, _hud) {
        // aim from the GUI mouse in world coords
        aim_x = _v.wx(device_mouse_x_to_gui(0));
        aim_y = _v.wy(device_mouse_y_to_gui(0));

        var _me = lab_me(_shell);
        if (_me != 0 && !rebind) {
            draw_square_w(_v, recon.value("x"), recon.value("y"), SIM_PLAYER_HALF,
                hue_color(__colyseus_schema_get_number(_me, "hue")));
            // crosshair
            draw_set_color(COL_TEXT);
            draw_circle(_v.sx(clamp(aim_x, 0, SIM_ARENA_W)), _v.sy(clamp(aim_y, 0, SIM_ARENA_H)), 6, true);
        }

        // every live entry: amber = pending local, text = confirmed own,
        // red = foreign (the turret's — never consumes a prediction)
        var _entries = shots.entries();
        var _pending = 0;
        for (var _i = 0; _i < array_length(_entries); _i++) {
            var _e = _entries[_i];
            var _ex = shots.value(_e.id, "x");
            var _ey = shots.value(_e.id, "y");
            if (is_nan(_ex)) continue;
            var _col = COL_ACCENT;
            if (_e.confirmed) {
                var _owner = _e.server != 0 ? __colyseus_schema_get_string(_e.server, "owner") : "";
                _col = _owner == _shell.sid ? COL_TEXT : COL_BAD;
            } else {
                _pending += 1;
            }
            draw_circle_w(_v, _ex, _ey, SIM_PROJECTILE_RADIUS + 0.3, _col, false);
        }

        _hud.section("TELEMETRY");
        _hud.row("fired", COL_TEXT, string(fired));
        _hud.row("pending locals", COL_ACCENT, string(_pending));
        _hud.row("live entries", COL_TEXT, string(shots.size()));
        _hud.row("last handoff lead", last_lead > 0 ? COL_GOOD : COL_FAINT,
            last_lead > 0 ? string(round(last_lead)) + " ms" : "--");
        _hud.section("CONTROLS");
        _hud.key_hint("click", "fire at the crosshair");
        _hud.key_hint("space", "fire, too");
        _hud.key_hint("WASD", "drive");
        _hud.note("Amber = your optimistic shot flying before the server knows. It hands off to the authoritative entity (same id) with the measured lead. Red = the turret's foreign shots - never yours to predict.");
    };

    static detach = function(_shell) {
        recon.free_native();
        shots.free_native();
        predict.free_native();
    };
    static on_reconnect = function(_shell) { rebind = true; };
}
