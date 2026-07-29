--
-- Defold/Lua-SDK validation client for the Colyseus Prediction Playground.
--
-- Headless probe (plain luajit — defold_shim.lua supplies the Defold APIs
-- over an FFI TCP transport) against the live demo server, exercising the
-- predict layer end-to-end — the Lua twin of clients/native/predict_probe.c:
--
--   A  lab-move        join, TIMED clock sync, reconciler over the ported
--                      step_entity (bit-exact f64), impulse -> correction
--   B  lab-bots        passive smoothing (lerp) over the patrol bot
--   C  lab-goal        sim-born optimistic event (ctx:predict) -> confirm
--   D  lab-projectile  predicted spawn -> in-place authoritative handoff
--
-- State AND input schemas come from the JOIN_ROOM reflection handshake — no
-- generated fixtures needed on this SDK.
--
-- Run (from this directory):
--   luajit predict_probe.lua [port]
--
package.path = "./?.lua;../../../../colyseus-defold/?.lua;" .. package.path

local shim = require 'defold_shim'
local net = require 'ffi_net'
local Client = require 'colyseus.client'
local get_callbacks = require 'colyseus.serializer.schema.callbacks'
local Predict = require 'colyseus.predict.predict'

local PORT = arg[1] or "5173"
local HOST = "127.0.0.1"

-- ---------------------------------------------------------------- harness --

local checks_failed = 0

local function check(name, ok, detail)
  print(string.format("%s %s%s", ok and "OK  " or "FAIL", name,
    detail and (" — " .. detail) or ""))
  if not ok then checks_failed = checks_failed + 1 end
end

local function now_ms() return net.gettime() * 1000 end

--- Pump until pred() is truthy or timeout; returns pred()'s final value.
local function pump_until(pred, timeout_ms)
  local deadline = now_ms() + timeout_ms
  while now_ms() < deadline do
    shim.pump()
    local v = pred()
    if v then return v end
    net.sleep_ms(2)
  end
  return pred()
end

local function join_lab(client, name)
  local joined_room, join_err = nil, nil
  client:join_or_create(name, {}, function(err, room)
    join_err = err
    joined_room = room
  end)
  pump_until(function() return joined_room ~= nil or join_err ~= nil end, 5000)
  if join_err ~= nil then
    print("join error: " .. tostring(join_err.message or join_err))
    return nil
  end
  -- wait for the reflection handshake + first full state
  pump_until(function()
    return joined_room.serializer ~= nil and joined_room.serializer:get_state() ~= nil
  end, 5000)
  shim.sleep_ms(300)   -- one patch interval so the first TIMED sample lands
  return joined_room
end

local function leave_room(room)
  room:leave(true)
  shim.sleep_ms(300)
end

-- -------------------------------------------- shared sim (ported, f64) ----

local TICK_HZ = 20
local ARENA_W, ARENA_H, PLAYER_HALF = 100, 60, 1.6
local PLAYER_ACCEL, PLAYER_MAX_SPEED, PLAYER_FRICTION_K = 220, 34, 0.72
local SQRT1_2 = 0.70710678118654752440   -- Math.SQRT1_2, exact f64
local GOAL_ZONE_X, GOAL_ZONE_Y, GOAL_ZONE_H = ARENA_W - 8, ARENA_H / 2 - 9, 18
local SCORE_COOLDOWN_TICKS = 50
local PROJECTILE_SPEED = 34

--- shared/movement.ts stepEntity — same op order, same constants.
local function step_entity(e, move_x, move_y, dt)
  local ax, ay = move_x, move_y
  if ax ~= 0 and ay ~= 0 then ax = ax * SQRT1_2; ay = ay * SQRT1_2 end

  if ax ~= 0 or ay ~= 0 then
    e.vx = e.vx + ax * PLAYER_ACCEL * dt
    e.vy = e.vy + ay * PLAYER_ACCEL * dt
  else
    e.vx = e.vx * PLAYER_FRICTION_K
    e.vy = e.vy * PLAYER_FRICTION_K
    if e.vx > -0.05 and e.vx < 0.05 then e.vx = 0 end
    if e.vy > -0.05 and e.vy < 0.05 then e.vy = 0 end
  end

  local sq = e.vx * e.vx + e.vy * e.vy
  if sq > PLAYER_MAX_SPEED * PLAYER_MAX_SPEED then
    local s = PLAYER_MAX_SPEED / math.sqrt(sq)
    e.vx = e.vx * s
    e.vy = e.vy * s
  end

  e.x = e.x + e.vx * dt
  e.y = e.y + e.vy * dt

  local min_x, max_x = PLAYER_HALF, ARENA_W - PLAYER_HALF
  local min_y, max_y = PLAYER_HALF, ARENA_H - PLAYER_HALF
  if e.x < min_x then e.x = min_x; if e.vx < 0 then e.vx = 0 end
  elseif e.x > max_x then e.x = max_x; if e.vx > 0 then e.vx = 0 end end
  if e.y < min_y then e.y = min_y; if e.vy < 0 then e.vy = 0 end
  elseif e.y > max_y then e.y = max_y; if e.vy > 0 then e.vy = 0 end end
end

-- ------------------------------------------------- A. lab-move scenario ---

local function scenario_move(client)
  print("\n=== A. lab-move: join, clock, reconcile, impulse ===")
  local room = join_lab(client, "lab-move")
  check("join lab-move", room ~= nil)
  if room == nil then return end

  local state = room.state
  local me = state.players[room.session_id]
  check("own player spawned", me ~= nil, "session " .. tostring(room.session_id))
  if me == nil then leave_room(room); return end
  print(string.format("     spawn at %.1f %.1f hue %d", me.x, me.y, me.hue))

  check("clock synced (TIMED prefix flowing)", room.clock:last_server_time() > 0,
    string.format("lastServerTime=%.0f", room.clock:last_server_time()))

  local input = room:input()
  check("input handle created (from reflection)", input ~= nil)
  local cmd = input.data

  local predict = Predict.new(get_callbacks(room), room.clock)
  local recon = predict:reconciler(me, {
    input = input,
    fields = { "x", "y", "vx", "vy" },
    smoothing = 15,
    step = function(ctx, s, inp)
      step_entity(s, inp.moveX, inp.moveY, ctx.dt)
    end,
  })
  check("reconciler created (step 50ms adopted)", recon.step_ms == 50)
  local predicted = recon.state

  local start_x = predicted.x
  local early_x = start_x
  local max_corr_steady = 0
  local max_pending = 0

  -- drive left for 2s at the fixed step, ticking at ~60fps
  local send_acc, last = 0, now_ms()
  for frame = 0, 124 do
    shim.sleep_ms(16)
    local now = now_ms()
    send_acc = send_acc + (now - last)
    last = now
    while send_acc >= 50 do
      send_acc = send_acc - 50
      cmd.moveX = -1
      cmd.moveY = 0
      input:send()
    end
    predict:tick(now)
    if frame == 9 then early_x = predicted.x end
    if frame > 30 then
      max_corr_steady = math.max(max_corr_steady, recon.last_correction_mag)
      max_pending = math.max(max_pending, recon:pending_count())
    end
    if frame % 25 == 0 then
      print(string.format("     t=%4dms truth %6.2f,%6.2f v %6.2f,%6.2f | pred %6.2f,%6.2f | corr=%.3f",
        frame * 16, me.x, me.y, me.vx, me.vy, predicted.x, predicted.y, recon.last_correction_mag))
    end
  end

  check("predicted pose moves before RTT elapses", start_x - early_x > 0.3,
    string.format("dx=%.2f in ~150ms", start_x - early_x))
  check("steady-state corrections ~0 (shared step deterministic)",
    max_corr_steady < 1e-3, string.format("max |correction| = %.2e", max_corr_steady))
  local rtt = room.clock:smoothed_rtt()
  check("pending tracks RTT", max_pending <= math.floor(rtt * TICK_HZ / 1000 + 3),
    string.format("max pending=%d rtt=%.0fms", max_pending, rtt))
  local Drift = require 'colyseus.predict.drift'
  check("drift matched while driving", Drift.classify(recon.drift, 0) == "matched",
    string.format("ema=%.2e", recon.drift.ema))

  -- server-side shove the client can't see coming — MUST mispredict
  room:send("impulse", {})
  local impulse_corr = 0
  send_acc, last = 0, now_ms()
  for _ = 0, 219 do
    shim.sleep_ms(16)
    local now = now_ms()
    send_acc = send_acc + (now - last)
    last = now
    while send_acc >= 50 do
      send_acc = send_acc - 50
      cmd.moveX = 0
      cmd.moveY = 0
      input:send()   -- keep acks flowing
    end
    predict:tick(now)
    impulse_corr = math.max(impulse_corr, recon.last_correction_mag)
  end
  check("impulse produces a visible correction", impulse_corr > 0.05,
    string.format("max |correction| = %.3f", impulse_corr))
  check("drift recovers after impulse (not diverging)",
    Drift.classify(recon.drift, 0.01) ~= "diverging",
    string.format("ema=%.4f peak=%.4f", recon.drift.ema, recon.drift.peak))

  local read = recon:value("x")
  check("value(x) render read sane", read == read and math.abs(read - predicted.x) < 5,
    string.format("value=%.2f state=%.2f", read, predicted.x))

  leave_room(room)
end

-- ------------------------------------------------- B. lab-bots scenario ---

local function scenario_bots(client)
  print("\n=== B. lab-bots: passive smoothing over a server-driven bot ===")
  local room = join_lab(client, "lab-bots")
  check("join lab-bots", room ~= nil)
  if room == nil then return end

  local bot = room.state.bots["bot1"]
  check("bot1 present", bot ~= nil)
  if bot == nil then leave_room(room); return end

  local predict = Predict.new(get_callbacks(room), room.clock)
  predict:attach(bot, { x = "lerp", y = "lerp" })
  check("track bot1.x/y (lerp)", true)

  local first, last_v, min_v, max_v = nil, nil, 1e9, -1e9
  local max_frame_jump, max_raw_jump, prev_raw = 0, 0, bot.x
  for _ = 1, 100 do
    shim.sleep_ms(16)
    predict:tick(now_ms())
    local v = predict:value(bot, "x")
    if first == nil then first = v end
    if last_v ~= nil then max_frame_jump = math.max(max_frame_jump, math.abs(v - last_v)) end
    max_raw_jump = math.max(max_raw_jump, math.abs(bot.x - prev_raw))
    prev_raw = bot.x
    last_v = v
    min_v = math.min(min_v, v)
    max_v = math.max(max_v, v)
  end
  check("lerped value follows the bot", math.abs(last_v - first) > 5,
    string.format("moved %.1f units over 1.6s", math.abs(last_v - first)))
  check("lerp output smoother than snapshots", max_frame_jump < max_raw_jump,
    string.format("max frame jump %.2f < max snapshot jump %.2f", max_frame_jump, max_raw_jump))
  check("lerped value stays in the patrol band", min_v > 20 and max_v < 80,
    string.format("range [%.1f, %.1f]", min_v, max_v))

  leave_room(room)
end

-- ------------------------------------------------- C. lab-goal scenario ---

local function scenario_goal(client)
  print("\n=== C. lab-goal: sim-born optimistic event -> server confirm ===")
  local room = join_lab(client, "lab-goal")
  check("join lab-goal", room ~= nil)
  if room == nil then return end

  local me = room.state.players[room.session_id]
  check("own player spawned", me ~= nil)
  if me == nil then leave_room(room); return end

  local predicted_count, confirmed_count, rejected_count = 0, 0, 0
  local predict = Predict.new(get_callbacks(room), room.clock)
  local goals = predict:define_event({
    on_predict = function() predicted_count = predicted_count + 1 end,
    on_confirm = function() confirmed_count = confirmed_count + 1 end,
    on_reject = function() rejected_count = rejected_count + 1 end,
  })

  room:on_message("goal", function(message)
    if message.sid == room.session_id then goals:confirm() end
  end)

  local input = room:input()
  local cmd = input.data

  local n = 0
  local recon = predict:reconciler(me, {
    input = input,
    fields = { "x", "y", "vx", "vy", "scoreTicks" },
    smoothing = 15,
    step = function(ctx, s, inp)
      step_entity(s, inp.moveX, inp.moveY, ctx.dt)
      -- shared/goal.ts stepScoreGate — reconciled tick state
      if s.scoreTicks > 0 then
        s.scoreTicks = s.scoreTicks - 1
      elseif s.x >= GOAL_ZONE_X and s.y >= GOAL_ZONE_Y and s.y <= GOAL_ZONE_Y + GOAL_ZONE_H then
        s.scoreTicks = SCORE_COOLDOWN_TICKS
        ctx:predict(goals, n)   -- live-only, replay-safe
        n = n + 1
      end
    end,
  })
  check("reconciler created (scoreTicks reconciled)", recon ~= nil)
  local predicted = recon.state

  local max_corr = 0
  local send_acc, last = 0, now_ms()
  local frames = 0
  while frames < 500 and confirmed_count == 0 do
    frames = frames + 1
    shim.sleep_ms(16)
    local now = now_ms()
    send_acc = send_acc + (now - last)
    last = now
    while send_acc >= 50 do
      send_acc = send_acc - 50
      cmd.moveX = 1
      cmd.moveY = (predicted.y < ARENA_H / 2 - 2) and 1
        or (predicted.y > ARENA_H / 2 + 2) and -1 or 0
      input:send()
    end
    predict:tick(now)
    if frames > 30 then max_corr = math.max(max_corr, recon.last_correction_mag) end
  end

  check("optimistic goal predicted (sim-born, live step)", predicted_count >= 1,
    string.format("predicted=%d after %d frames", predicted_count, frames))
  check("server confirmed the goal", confirmed_count >= 1,
    string.format("confirmed=%d", confirmed_count))
  check("no rejections (denyRate 0)", rejected_count == 0)
  check("gate deterministic through reconciles (corrections ~0)", max_corr < 1e-3,
    string.format("max |correction| = %.2e", max_corr))

  leave_room(room)
end

-- ------------------------------------------- D. lab-projectile scenario ---

local function scenario_projectile(client)
  print("\n=== D. lab-projectile: predicted spawn -> authoritative handoff ===")
  local room = join_lab(client, "lab-projectile")
  check("join lab-projectile", room ~= nil)
  if room == nil then return end

  local me = room.state.players[room.session_id]
  check("own player spawned", me ~= nil)
  if me == nil then leave_room(room); return end

  local rejected = 0
  local foreign_seen = false
  local predict = Predict.new(get_callbacks(room), room.clock)
  local store = predict:spawns("projectiles", {
    owned = function(p) return p.owner == room.session_id end,
    spawn_time = function(p) return p.bornMs end,
    step = function(l, dt)
      -- shared/projectile.ts stepProjectile over the pending local
      l.x = l.x + l.vx * dt
      l.y = l.y + l.vy * dt
      if l.x < 0 then l.x = 0; l.vx = math.abs(l.vx)
      elseif l.x > ARENA_W then l.x = ARENA_W; l.vx = -math.abs(l.vx) end
      if l.y < 0 then l.y = 0; l.vy = math.abs(l.vy)
      elseif l.y > ARENA_H then l.y = ARENA_H; l.vy = -math.abs(l.vy) end
    end,
    on_reject = function() rejected = rejected + 1 end,
  })

  local input = room:input()
  local cmd = input.data

  -- fire one shot at the turret (50, 8) and spawn the optimistic local
  local aim_x, aim_y = 50, 8
  local dx, dy = aim_x - me.x, aim_y - me.y
  local len = math.sqrt(dx * dx + dy * dy)
  dx, dy = dx / len, dy / len
  local local_projectile = {
    x = me.x, y = me.y,
    vx = dx * PROJECTILE_SPEED, vy = dy * PROJECTILE_SPEED,
  }

  cmd.aimX = aim_x
  cmd.aimY = aim_y
  cmd.fire = true
  input:send()
  cmd.fire = false
  local handle = store:spawn(local_projectile)

  check("optimistic local pending immediately",
    not handle.confirmed and handle.local_state == local_projectile,
    "id=" .. handle.id)

  local send_acc, last = 0, now_ms()
  local lead_ms = 0
  local confirmed = false
  for _ = 1, 250 do
    if confirmed and foreign_seen then break end
    shim.sleep_ms(16)
    local now = now_ms()
    send_acc = send_acc + (now - last)
    last = now
    while send_acc >= 50 do
      send_acc = send_acc - 50
      input:send()   -- keep the input stream alive
    end
    predict:tick(now)
    if not confirmed and handle.confirmed then
      confirmed = true
      lead_ms = handle.lead_ms
    end
    -- the turret's projectiles must surface as foreign (server-only) entries
    for _, entry in ipairs(store:entries()) do
      if entry.confirmed and entry.local_state == nil
        and entry.server ~= nil and entry.server.owner == "turret" then
        foreign_seen = true
      end
    end
  end

  check("authoritative projectile correlated IN PLACE (stable id)", confirmed,
    "id=" .. handle.id)
  check("input lead measured", confirmed and lead_ms > 0 and lead_ms < 1000,
    string.format("leadMs=%.0f", lead_ms))
  check("turret projectiles surface as foreign entries", foreign_seen)
  check("own prediction not TTL-rejected", rejected == 0, "rejected=" .. rejected)

  leave_room(room)
end

-- ------------------------------------------------------------------ main --

print(string.format("predict_probe (Defold/Lua) -> ws://%s:%s", HOST, PORT))
local client = Client(string.format("ws://%s:%s", HOST, PORT))

scenario_move(client)
scenario_bots(client)
scenario_goal(client)
scenario_projectile(client)

print("\n" .. (checks_failed == 0 and "PROBE OK" or "PROBE FAILED"))
os.exit(checks_failed == 0 and 0 or 1)
