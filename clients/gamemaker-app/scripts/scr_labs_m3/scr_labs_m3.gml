// =============================================================================
// Labs — M3: 06 Lag Compensation, 07 WYSIWYG, 10 Composite Sim, 11
// Deterministic RNG. Ports of clients/native-app/labs/lab06/07/10/11.
// (sim_ray_circle and the bump constants live in scr_sim — shared sim code
// never depends on a labs file.)
// =============================================================================

// ── Lab 06 — Lag Compensation: hit what you SAW ────────────────────────

function Lab06() constructor {
    num = 6;
    title = "Lag Compensation";
    blurb = "The server rewinds targets to what you actually saw.";
    room_name = "lab-range";

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
        // rewind stamping only on firing inputs — the allowRewind gate
        input.set_rewind_field("fire");
        predict = new ColyseusPredict(_shell.net_room);
        // remotes/bots rendered ~100ms in the past — exactly what lag comp rewinds to
        predict.attach_all("bots", { x: { mode: COLYSEUS_PREDICT_LERP, delay: 100 },
                                     y: { mode: COLYSEUS_PREDICT_LERP, delay: 100 } });
        rebind = false;
        pacer = new Pacer(1000 / SIM_TICK_HZ);
        lagcomp_on = true;
        rays = [];          // {ox,oy,tx,ty, bx,by, predicted, answered, hit, gx,gy, rx,ry, t}
        hits = 0; shots = 0;
        fire_pending = false;
        aim_x = SIM_ARENA_W / 2; aim_y = SIM_ARENA_H / 2;
        colyseus_send(_shell.net_room, "lagcomp", { on: true });
        var _lab_self = self;
        colyseus_on_message(_shell.net_room, method({ lab: _lab_self, shell: _shell },
            function(_r, _type, _payload) {
                if (_type != "shot" || !is_struct(_payload)) return;
                if (_payload[$ "sid"] != shell.sid) return;
                lab.shots += 1;
                if (_payload[$ "hit"]) lab.hits += 1;
                // answer the oldest unanswered ray with the server's reads
                for (var _i = 0; _i < array_length(lab.rays); _i++) {
                    var _ray = lab.rays[_i];
                    if (_ray.answered) continue;
                    _ray.answered = true;
                    _ray.hit = _payload[$ "hit"] ? true : false;
                    _ray.gx = _payload[$ "seenX"]; _ray.gy = _payload[$ "seenY"];
                    _ray.rx = _payload[$ "liveX"]; _ray.ry = _payload[$ "liveY"];
                    break;
                }
            }));
        // born from the Predict: binds the input's lag-comp render_delay to
        // the lerp delay — the server rewinds to the instant we actually DRAW.
        // Without this the rewind misses by the full lerp delay (the C-port
        // lesson: 3/6 hits vs 6/6).
        return __make_recon(_shell);
    };

    static step = function(_shell, _now, _dt) {
        if (rebind) {
            if (lab_me(_shell) == 0) return;
            recon.free_native();
            if (__make_recon(_shell)) rebind = false; else return;
        }
        if (keyboard_check_pressed(ord("C"))) {
            lagcomp_on = !lagcomp_on;
            hits = 0; shots = 0;
            colyseus_send(_shell.net_room, "lagcomp", { on: lagcomp_on });
        }
        // latch: clicks land between fixed steps — hold until one is due
        if (mouse_check_button_pressed(mb_left) || keyboard_check_pressed(vk_space)) fire_pending = true;
        var _steps = predict.tick(_now);
        recon.pump();
        repeat (_steps) {
            input.set("moveX", kb_move_x());
            input.set("moveY", kb_move_y());
            input.set("aimX", clamp(aim_x, 0, SIM_ARENA_W));
            input.set("aimY", clamp(aim_y, 0, SIM_ARENA_H));
            input.set("fire", fire_pending ? 1 : 0);
            input.set("spread", 0);
            input.send();
            recon.pump();
            if (fire_pending) {
                fire_pending = false;
                // record the shot AS THIS SCREEN SHOWED IT: origin at the
                // PREDICTED pose, blue marker = the (lerped) bot we aimed at
                var _state = __colyseus_room_get_state(_shell.net_room);
                var _bot = __colyseus_map_get(_state, "bots", "bot1");
                {
                    var _px = recon.value("x");
                    var _py = recon.value("y");
                    var _ax = clamp(aim_x, 0, SIM_ARENA_W);
                    var _ay = clamp(aim_y, 0, SIM_ARENA_H);
                    var _len = max(point_distance(_px, _py, _ax, _ay), 0.000000001);
                    var _dx = (_ax - _px) / _len, _dy = (_ay - _py) / _len;
                    var _bx = _bot != 0 ? predict.value(_bot, "x") : _ax;
                    var _by = _bot != 0 ? predict.value(_bot, "y") : _ay;
                    // the server's own hit test, run against the pose THIS
                    // screen was showing — available immediately, and it agrees
                    // with the server whenever the rewind lands where it should
                    var _pred = sim_ray_circle(_px, _py, _dx, _dy, _bx, _by,
                        SIM_BOT_RADIUS, SIM_SHOT_RANGE) >= 0;
                    array_push(rays, {
                        ox: _px, oy: _py, tx: _px + _dx * 120, ty: _py + _dy * 120,
                        bx: _bx, by: _by,
                        predicted: _pred,
                        answered: false, hit: false, gx: 0, gy: 0, rx: 0, ry: 0,
                        t: _now,
                    });
                    if (array_length(rays) > 8) array_delete(rays, 0, 1);
                }
            }
        }
    };

    static draw = function(_shell, _v, _hud) {
        aim_x = _v.wx(device_mouse_x_to_gui(0));
        aim_y = _v.wy(device_mouse_y_to_gui(0));
        var _now = colyseus_predict_now();
        var _state = __colyseus_room_get_state(_shell.net_room);

        // the strafing target, rendered where YOU see it (lerp = the past)
        var _bot = __colyseus_map_get(_state, "bots", "bot1");
        if (_bot != 0) {
            draw_circle_w(_v, predict.value(_bot, "x"), predict.value(_bot, "y"),
                SIM_BOT_RADIUS, COL_BLUE, false);
            // and the LIVE decoded pose as a faint outline — where it "really" is
            draw_circle_w(_v, __colyseus_schema_get_number(_bot, "x"),
                __colyseus_schema_get_number(_bot, "y"), SIM_BOT_RADIUS, COL_FAINT, true);
        }
        var _me = lab_me(_shell);
        if (_me == 0 || rebind) return;
        var _px2 = recon.value("x");
        var _py2 = recon.value("y");
        draw_square_w(_v, _px2, _py2, SIM_PLAYER_HALF,
            hue_color(__colyseus_schema_get_number(_me, "hue")));
        draw_square_outline_w(_v, _px2, _py2, SIM_PLAYER_HALF, COL_TEXT);
        draw_set_color(COL_TEXT);
        draw_circle(_v.sx(clamp(aim_x, 0, SIM_ARENA_W)), _v.sy(clamp(aim_y, 0, SIM_ARENA_H)), 6, true);

        // the live aim line, faint, from the predicted pose to the crosshair
        draw_set_color(COL_TEXT);
        draw_set_alpha(0.18);
        draw_line(_v.sx(_px2), _v.sy(_py2),
            _v.sx(clamp(aim_x, 0, SIM_ARENA_W)), _v.sy(clamp(aim_y, 0, SIM_ARENA_H)));
        draw_set_alpha(1);

        // shot rays: this screen's own verdict while in flight, faint; the
        // server's at full strength once answered — a ray that flips colour is
        // the rewind disagreeing with what you saw.
        // blue = the bot YOU saw, green = the server's rewound read,
        // red = the live pose at resolution time
        for (var _i = array_length(rays) - 1; _i >= 0; _i--) {
            var _ray = rays[_i];
            var _age = _now - _ray.t;
            if (_age > 2600) { array_delete(rays, _i, 1); continue; }
            var _a = 1 - _age / 2600;
            var _verdict = _ray.answered ? _ray.hit : _ray.predicted;
            draw_set_color(_verdict ? COL_GOOD : COL_BAD);
            draw_set_alpha(_a * (_ray.answered ? 0.7 : 0.3));
            draw_line(_v.sx(_ray.ox), _v.sy(_ray.oy), _v.sx(_ray.tx), _v.sy(_ray.ty));
            draw_set_alpha(_a);
            draw_circle_w(_v, _ray.bx, _ray.by, SIM_BOT_RADIUS * 0.7, COL_BLUE, true);
            if (_ray.answered) {
                draw_circle_w(_v, _ray.gx, _ray.gy, SIM_BOT_RADIUS * 0.85, COL_GOOD, true);
                draw_circle_w(_v, _ray.rx, _ray.ry, SIM_BOT_RADIUS, COL_BAD, true);
            }
            draw_set_alpha(1);
        }

        _hud.section("TELEMETRY");
        _hud.row("lag comp", lagcomp_on ? COL_GOOD : COL_BAD, lagcomp_on ? "ON" : "OFF");
        _hud.row("hits / shots", COL_TEXT, string(hits) + " / " + string(shots));
        _hud.section("CONTROLS");
        _hud.key_hint("click", "fire at the bot YOU see");
        _hud.key_hint("space", "fire, too");
        _hud.key_hint("C", "toggle server lag comp");
        _hud.note("You aim at a 100ms-old render. With lag comp ON the server rewinds the bot to that instant (green marker = its read). OFF, it tests the live pose (red) - and you miss. The ray carries your own verdict faintly at the click, then the server's at full strength.");
    };

    static detach = function(_shell) {
        recon.free_native();
        predict.free_native();
    };
    static on_reconnect = function(_shell) { rebind = true; };
}

// ── Lab 07 — WYSIWYG: predicted contact at the rewind instant ──────────

function Lab07() constructor {
    num = 7;
    title = "WYSIWYG Contact";
    blurb = "Predict the knockback against the bot AS RENDERED.";
    room_name = "lab-bump";

    static __make_recon = function(_shell) {
        var _me = lab_me(_shell);
        if (_me == 0) return false;
        var _lab_self = self;
        recon = predict.reconciler(_me, {
            fields: ["x", "y", "vx", "vy", "bumpTicks"],
            smoothing: 15,
            step: method({ lab: _lab_self, shell: _shell }, function(_ctx, _s, _cmd) {
                // gate BEFORE movement, exactly like the server
                var _ticks = _s.get("bumpTicks");
                if (_ticks > 0) _s.set("bumpTicks", _ticks - 1);
                var _e = { x: _s.get("x"), y: _s.get("y"), vx: _s.get("vx"), vy: _s.get("vy") };
                sim_step_entity(_e, _cmd.get("moveX"), _cmd.get("moveY"), _ctx.dt);
                // bot pose AT THE REWIND INSTANT — the server's own read; memo
                // freezes the verdict so replays can't re-roll it
                var _bx = _ctx.memo_peek("bx");
                var _by = _ctx.memo_peek("by");
                if (!_ctx.is_replay) {
                    var _state = __colyseus_room_get_state(shell.net_room);
                    var _bot = __colyseus_map_get(_state, "bots", "bot1");
                    if (_bot != 0) {
                        _bx = _ctx.memo_store("bx", lab.predict.value_at(_bot, "x", _ctx.reckon_time));
                        _by = _ctx.memo_store("by", lab.predict.value_at(_bot, "y", _ctx.reckon_time));
                    }
                }
                if (!is_nan(_bx) && _s.get("bumpTicks") <= 0) {
                    var _dx = _e.x - _bx, _dy = _e.y - _by;
                    var _r = SIM_PLAYER_HALF + SIM_BOT_RADIUS;
                    var _d2 = _dx * _dx + _dy * _dy;
                    if (_d2 < _r * _r) {
                        var _d = max(sqrt(_d2), 0.000001);
                        _e.vx = _dx / _d * SIM_BUMP_SPEED;
                        _e.vy = _dy / _d * SIM_BUMP_SPEED;
                        _s.set("bumpTicks", SIM_BUMP_COOLDOWN_TICKS);
                        if (!_ctx.is_replay) lab.bumps_predicted += 1;
                    }
                }
                _s.set("x", _e.x); _s.set("y", _e.y);
                _s.set("vx", _e.vx); _s.set("vy", _e.vy);
            }),
        });
        return recon.id > 0;
    };

    static attach = function(_shell) {
        if (lab_me(_shell) == 0) return false;
        input = new ColyseusInput(_shell.net_room);
        if (!input.ok) return false;
        // the input carries the render-time stamp every step (lag-comp basis)
        input.set_rewind_field("moveX");
        predict = new ColyseusPredict(_shell.net_room);
        // bots BOTH lerped (the render) and reckonable via value_at
        predict.attach_all("bots", { x: { mode: COLYSEUS_PREDICT_LERP, delay: 100 },
                                     y: { mode: COLYSEUS_PREDICT_LERP, delay: 100 } });
        bumps_predicted = 0;
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
        var _state = __colyseus_room_get_state(_shell.net_room);
        var _bot = __colyseus_map_get(_state, "bots", "bot1");
        if (_bot != 0) {
            draw_circle_w(_v, predict.value(_bot, "x"), predict.value(_bot, "y"),
                SIM_BOT_RADIUS, COL_BLUE, false);
        }
        var _me = lab_me(_shell);
        if (_me == 0 || rebind) return;
        draw_square_w(_v, recon.value("x"), recon.value("y"), SIM_PLAYER_HALF,
            hue_color(__colyseus_schema_get_number(_me, "hue")));

        var _server_bumps = __colyseus_schema_get_number(_me, "bumps");
        _hud.section("TELEMETRY");
        _hud.row("bumps predicted", COL_WARN, string(bumps_predicted));
        _hud.row("bumps (server)", COL_GOOD, string(_server_bumps));
        _hud.row("drift ema", COL_ACCENT, string_format(recon.drift_ema(), 1, 4));
        _hud.row("cooldown ticks", COL_TEXT, string(recon.state.get("bumpTicks")));
        _hud.section("CONTROLS");
        _hud.key_hint("WASD", "drive into the bot");
        _hud.note("The knockback fires against the bot AS RENDERED (value_at the input's rewind instant - the server's own read). The memo freezes each verdict so rollback replays can't re-roll it.");
    };

    static detach = function(_shell) {
        recon.free_native();
        predict.free_native();
    };
    static on_reconnect = function(_shell) { rebind = true; };
}

// ── Lab 10 — Composite Sim: predict a world you partly control ─────────

function Lab10() constructor {
    num = 10;
    title = "Composite Sim";
    blurb = "Paddle + puck + contacts in one predicted world.";
    room_name = "lab-hockey";

    static __make_sim = function(_shell) {
        var _state = __colyseus_room_get_state(_shell.net_room);
        var _me = __colyseus_map_get(_state, "players", _shell.sid);
        var _puck = __colyseus_schema_get_number(_state, "puck");
        if (_me == 0 || _puck == 0) return false;
        sim = predict.sim({
            world: { me: _me, puck: _puck },
            smoothing: 0,
            step: function(_ctx, _world, _cmd) {
                predict_world_step(_ctx, _world, _cmd);
            },
        });
        return sim.id > 0;
    };

    static attach = function(_shell) {
        if (lab_me(_shell) == 0) return false;
        input = new ColyseusInput(_shell.net_room);
        if (!input.ok) return false;
        predict = new ColyseusPredict(_shell.net_room);
        bot_on = true;
        rebind = false;
        return __make_sim(_shell);
    };

    static step = function(_shell, _now, _dt) {
        if (rebind) {
            if (lab_me(_shell) == 0) return;
            sim.free_native();
            if (__make_sim(_shell)) rebind = false; else return;
        }
        if (keyboard_check_pressed(ord("B"))) {
            bot_on = !bot_on;
            colyseus_send(_shell.net_room, "bot", { on: bot_on });
        }
        if (keyboard_check_pressed(ord("P"))) colyseus_send(_shell.net_room, "resetPuck", {});
        var _steps = predict.tick(_now);
        sim.pump();
        repeat (_steps) {
            input.set("moveX", kb_move_x());
            input.set("moveY", kb_move_y());
            input.send();
            sim.pump();
        }
    };

    static draw = function(_shell, _v, _hud) {
        if (rebind) return;   // mid-resync: the native sim is gone until step rebuilds it
        var _state = __colyseus_room_get_state(_shell.net_room);

        // predicted world: my paddle + the puck
        draw_circle_w(_v, sim.value("me.x"), sim.value("me.y"), SIM_PADDLE_RADIUS, COL_ACCENT, false);
        draw_circle_w(_v, sim.value("puck.x"), sim.value("puck.y"), SIM_PUCK_RADIUS, COL_TEXT, false);

        // server ghost puck — the authoritative one trails by ~RTT
        var _puck = __colyseus_schema_get_number(_state, "puck");
        if (_puck != 0) {
            draw_ghost_square_w(_v, __colyseus_schema_get_number(_puck, "x"),
                __colyseus_schema_get_number(_puck, "y"), SIM_PUCK_RADIUS, COL_FAINT, 0.7);
        }
        // the server-driven bot paddle (not predicted — its policy is server state)
        var _bot = __colyseus_map_get(_state, "players", "bot");
        if (_bot != 0) {
            draw_circle_w(_v, __colyseus_schema_get_number(_bot, "x"),
                __colyseus_schema_get_number(_bot, "y"), SIM_PADDLE_RADIUS, COL_BAD, true);
        }

        _hud.section("TELEMETRY");
        _hud.row("median-ish corr", COL_ACCENT, string_format(sim.last_correction_mag(), 1, 3));
        _hud.row("reconciles", COL_TEXT, string(sim.reconcile_seq()));
        _hud.row("drift ema", COL_TEXT, string_format(sim.drift_ema(), 1, 3));
        _hud.section("CONTROLS");
        _hud.key_hint("WASD", "drive the paddle into the puck");
        _hud.key_hint("B", bot_on ? "bot: on (mispredicts!)" : "bot: off");
        _hud.key_hint("P", "reset puck");
        _hud.note("Your paddle AND the puck live in one predicted world - contacts feel instant. The dashed puck is the authority. Enable the bot: every bot-puck contact becomes a misprediction you can watch settle.");
    };

    static detach = function(_shell) {
        sim.free_native();
        predict.free_native();
    };
    static on_reconnect = function(_shell) { rebind = true; };
}

/// lab 10's world step — my paddle through the shared movement, puck flight,
/// contact in the server's order (bot first if present is server-side only;
/// the predicted world contains what WE control + the puck).
function predict_world_step(_ctx, _world, _cmd) {
    sim_step_mirror(_world.me, _cmd.get("moveX"), _cmd.get("moveY"), _ctx.dt);
    predict_test_free_puck_step(_world.puck, _ctx.dt);
    predict_collide(_world.me, _world.puck);
}

/// stepPuck against a mirror view (hockey.ts)
function predict_test_free_puck_step(_p, _dt) {
    var _vx = _p.get("vx") * SIM_PUCK_FRICTION_K;
    var _vy = _p.get("vy") * SIM_PUCK_FRICTION_K;
    var _x = _p.get("x") + _vx * _dt;
    var _y = _p.get("y") + _vy * _dt;
    var _min = SIM_PUCK_RADIUS;
    var _max_x = SIM_ARENA_W - SIM_PUCK_RADIUS;
    var _max_y = SIM_ARENA_H - SIM_PUCK_RADIUS;
    if (_x < _min) { _x = _min; _vx = abs(_vx) * SIM_PUCK_RESTITUTION; }
    else if (_x > _max_x) { _x = _max_x; _vx = -abs(_vx) * SIM_PUCK_RESTITUTION; }
    if (_y < _min) { _y = _min; _vy = abs(_vy) * SIM_PUCK_RESTITUTION; }
    else if (_y > _max_y) { _y = _max_y; _vy = -abs(_vy) * SIM_PUCK_RESTITUTION; }
    _p.set("x", _x); _p.set("y", _y); _p.set("vx", _vx); _p.set("vy", _vy);
}

/// collidePaddlePuck against mirror views (hockey.ts)
function predict_collide(_paddle, _puck) {
    var _dx = _puck.get("x") - _paddle.get("x");
    var _dy = _puck.get("y") - _paddle.get("y");
    var _r = SIM_PADDLE_RADIUS + SIM_PUCK_RADIUS;
    var _d2 = _dx * _dx + _dy * _dy;
    if (_d2 >= _r * _r) return false;
    var _d = max(sqrt(_d2), 0.000001);
    var _nx = _dx / _d, _ny = _dy / _d;
    var _px = _paddle.get("x") + _nx * _r;
    var _py = _paddle.get("y") + _ny * _r;
    var _pvx = _paddle.get("vx"), _pvy = _paddle.get("vy");
    var _along = _pvx * _nx + _pvy * _ny;
    var _speed = _along > SIM_PUCK_PUSH_MIN ? _along : SIM_PUCK_PUSH_MIN;
    var _vx = _nx * _speed + _pvx * 0.35;
    var _vy = _ny * _speed + _pvy * 0.35;
    var _min = SIM_PUCK_RADIUS;
    var _max_x = SIM_ARENA_W - SIM_PUCK_RADIUS;
    var _max_y = SIM_ARENA_H - SIM_PUCK_RADIUS;
    if (_px < _min) { _px = _min; _vx = abs(_vx) * SIM_PUCK_RESTITUTION; }
    else if (_px > _max_x) { _px = _max_x; _vx = -abs(_vx) * SIM_PUCK_RESTITUTION; }
    if (_py < _min) { _py = _min; _vy = abs(_vy) * SIM_PUCK_RESTITUTION; }
    else if (_py > _max_y) { _py = _max_y; _vy = -abs(_vy) * SIM_PUCK_RESTITUTION; }
    _puck.set("x", _px); _puck.set("y", _py);
    _puck.set("vx", _vx); _puck.set("vy", _vy);
    return true;
}

// ── Lab 11 — Deterministic RNG: the fan is derived, not transmitted ────

function Lab11() constructor {
    num = 11;
    title = "Deterministic RNG";
    blurb = "Client and server roll identical pellets from (seq, salt).";
    room_name = "lab-range";

    static attach = function(_shell) {
        if (lab_me(_shell) == 0) return false;
        input = new ColyseusInput(_shell.net_room);
        if (!input.ok) return false;
        input.set_rewind_field("fire");
        // no reconciler here — stamp the lag-comp render delay by hand so the
        // server's rewound hit test matches what this screen shows (raw ≈ 0)
        input.set_render_delay(0);
        pacer = new Pacer(1000 / SIM_TICK_HZ);
        cheat = false;
        fire_pending = false;
        fans = [];      // {angles[], ox, oy, col, t}
        matches = 0; rolls = 0;
        aim_x = SIM_ARENA_W / 2; aim_y = SIM_ARENA_H / 2;
        var _lab_self = self;
        colyseus_on_message(_shell.net_room, method({ lab: _lab_self, shell: _shell },
            function(_r, _type, _payload) {
                if (_type != "spread" || !is_struct(_payload)) return;
                if (_payload[$ "sid"] != shell.sid) return;
                // the server's own fan — overlay in white over our amber one
                array_push(lab.fans, { angles: _payload[$ "angles"],
                    ox: _payload[$ "ox"], oy: _payload[$ "oy"],
                    col: COL_TEXT, t: colyseus_predict_now() });
            }));
        return true;
    };

    static step = function(_shell, _now, _dt) {
        if (keyboard_check_pressed(ord("X"))) cheat = !cheat;   // X: K is the global drop key
        if (mouse_check_button_pressed(mb_left) || keyboard_check_pressed(vk_space)) fire_pending = true;
        var _steps = pacer.steps(_now);
        repeat (_steps) {
            input.set("moveX", kb_move_x());
            input.set("moveY", kb_move_y());
            input.set("aimX", clamp(aim_x, 0, SIM_ARENA_W));
            input.set("aimY", clamp(aim_y, 0, SIM_ARENA_H));
            input.set("fire", 0);
            input.set("spread", fire_pending ? 1 : 0);
            var _seq = input.send();
            if (fire_pending && _seq > 0) {
                fire_pending = false;
                rolls += 1;
                // derive the fan CLIENT-SIDE from (seq, salt) — nothing on the wire
                var _state = __colyseus_room_get_state(_shell.net_room);
                var _salt = __colyseus_schema_get_number(_state, "salt");
                var _me = __colyseus_map_get(_state, "players", _shell.sid);
                var _ox = _me != 0 ? __colyseus_schema_get_number(_me, "x") : SIM_ARENA_W / 2;
                var _oy = _me != 0 ? __colyseus_schema_get_number(_me, "y") : SIM_ARENA_H / 2;
                var _base = arctan2(clamp(aim_y, 0, SIM_ARENA_H) - _oy,
                                    clamp(aim_x, 0, SIM_ARENA_W) - _ox);
                var _angles;
                if (cheat) {
                    // the "just use random()" mistake — diverges from the server
                    _angles = array_create(SIM_PELLETS);
                    for (var _i = 0; _i < SIM_PELLETS; _i++) {
                        _angles[_i] = _base + (random(1) - 0.5) * SIM_SPREAD_RAD;
                    }
                } else {
                    _angles = sim_spread_angles(_base, _seq, _salt);
                }
                array_push(fans, { angles: _angles, ox: _ox, oy: _oy,
                    col: COL_ACCENT, t: _now });
            }
        }
    };

    static draw = function(_shell, _v, _hud) {
        aim_x = _v.wx(device_mouse_x_to_gui(0));
        aim_y = _v.wy(device_mouse_y_to_gui(0));
        var _now = colyseus_predict_now();
        var _state = __colyseus_room_get_state(_shell.net_room);

        var _me = lab_me(_shell);
        if (_me != 0) {
            draw_square_w(_v, __colyseus_schema_get_number(_me, "x"),
                __colyseus_schema_get_number(_me, "y"), SIM_PLAYER_HALF,
                hue_color(__colyseus_schema_get_number(_me, "hue")));
        }
        var _bot = __colyseus_map_get(_state, "bots", "bot1");
        if (_bot != 0) {
            draw_circle_w(_v, __colyseus_schema_get_number(_bot, "x"),
                __colyseus_schema_get_number(_bot, "y"), SIM_BOT_RADIUS, COL_BLUE, false);
        }
        draw_set_color(COL_TEXT);
        draw_circle(_v.sx(clamp(aim_x, 0, SIM_ARENA_W)), _v.sy(clamp(aim_y, 0, SIM_ARENA_H)), 6, true);

        // pellet fans: amber = client-derived, white = the server's broadcast
        for (var _i = array_length(fans) - 1; _i >= 0; _i--) {
            var _f = fans[_i];
            var _age = _now - _f.t;
            if (_age > 2000) { array_delete(fans, _i, 1); continue; }
            draw_set_alpha((1 - _age / 2000) * 0.8);
            for (var _k = 0; _k < array_length(_f.angles); _k++) {
                var _a = _f.angles[_k];
                draw_set_color(_f.col);
                draw_line(_v.sx(_f.ox), _v.sy(_f.oy),
                    _v.sx(_f.ox + cos(_a) * 40), _v.sy(_f.oy + sin(_a) * 40));
            }
            draw_set_alpha(1);
        }

        _hud.section("TELEMETRY");
        _hud.row("fans rolled", COL_TEXT, string(rolls));
        _hud.row("derivation", cheat ? COL_BAD : COL_GOOD,
            cheat ? "random() - WRONG" : "(seq, salt) - shared");
        _hud.section("CONTROLS");
        _hud.key_hint("click", "shotgun fan at the crosshair");
        _hud.key_hint("space", "fire, too");
        _hud.key_hint("X", "toggle the random() cheat");
        _hud.note("Amber = your fan, derived from (input seq, room salt) before the server answers. White = the server's own roll - identical, because the derivation is shared. Press X to see what random() does instead.");
    };

    static detach = function(_shell) {};
    static on_reconnect = function(_shell) { pacer.reset(); };
}
