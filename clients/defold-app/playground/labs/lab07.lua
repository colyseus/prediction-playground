--
-- Lab 07 — WYSIWYG Collision.
--
-- The collision against the moving bot is predicted INSIDE the reconciler step.
-- Two ingredients make the client's verdict equal the server's:
--
--  1. predict:value_at(bot, "x", ctx.reckon_time) — read the bot at the instant
--     the server will REWIND this input to. Reading anything else (the stale
--     snapshot, or the smoothed render pose) tests against a position the server
--     never uses.
--
--  2. ctx:memo(...) — the verdict is NOT re-derivable on rollback replay (the
--     client keeps no bot history; a later replay would read the bot reckoned
--     from a NEWER snapshot and could flip the call). memo runs the test once on
--     the live step and replays the outcome verbatim.
--
-- The verdict is a VECTOR (the knockback vx/vy) memoized as one value, so both
-- components replay together. Encoding it as an angle would round through
-- atan2/cos and reintroduce the drift this lab exists to eliminate.
--
-- Port of src/client/labs/07-wysiwyg/.
--
local sim = require 'playground.sim'
local app = require 'playground.app'
local net_delay = require 'playground.net_delay'
local Predict = require 'colyseus.predict.predict'

local kb = app.kb

local Lab = {
  id = "07-wysiwyg",
  num = 7,
  title = "WYSIWYG Collision",
  blurb = "value_at(reckon_time) + ctx:memo.",
  room_name = "lab-bump",
}
Lab.__index = Lab

function Lab.new()
  return setmetatable({
    use_value_at = true,
    use_memo = true,
    bumps_predicted = 0,
    last_bump_at = -1e9,
    bump_flash_t = -1e9,
    mispredicts = 0,
    _last_reconcile_seq = 0,
  }, Lab)
end

function Lab:ready(room)
  return room.state.players ~= nil and room.state.players[room.session_id] ~= nil
     and room.state.bots ~= nil and room.state.bots["bot1"] ~= nil
end

function Lab:mount(context, room)
  self.room = room
  self.sid = room.session_id
  self.me = room.state.players[self.sid]
  self.bot = room.state.bots["bot1"]
  if self.me == nil or self.bot == nil then return false end

  self.predict = Predict.for_room(room)
  -- Bots are DEAD-RECKONED through the shared step — the timeline the collision
  -- test below reads at ctx.reckon_time.
  self.predict:attach_all_reckon("bots", {
    fields = { "x", "y" },
    smoothing = 25,
    step = function(b, dt, elapsed_ms)
      local s = {
        x = b.x, y = b.y, vx = b.vx, vy = b.vy, kind = b.kind,
        min_x = b.minX, max_x = b.maxX, base_y = b.baseY,
        phase_ms = b.phaseMs, speed = b.speed, last_teleport = b.lastTeleport,
      }
      sim.step_bot(s, dt, elapsed_ms)
      b.x, b.y, b.vx, b.vy = s.x, s.y, s.vx, s.vy
      b.lastTeleport = s.last_teleport
    end,
  })
  self.predict:attach_all("players", { "x", "y" }, { mode = "damped" })

  self.input = room:input()
  self.cmd = self.input.data
  self:build()
  net_delay.use_preset(3)     -- a knife-edge verdict needs a real RTT
  return true
end

--- Writes the knockback, or nil for "no bump this step".
function Lab:test_bots(px, py, gate, when)
  local hit_vx, hit_vy
  self.room.state.bots:each(function(bot)
    if hit_vx ~= nil then return end
    -- The server rewinds THIS input to reckon_time — test there. With the
    -- toggle off we read the raw snapshot instead: ~RTT/2 behind where the
    -- server tests, which is the whole point of the lab.
    local bx = self.use_value_at and self.predict:value_at(bot, "x", when) or bot.x
    local by = self.use_value_at and self.predict:value_at(bot, "y", when) or bot.y
    hit_vx, hit_vy = sim.collide_bot(px, py, gate, bx, by)
  end)
  if hit_vx == nil then return nil end
  return { hit_vx, hit_vy }
end

function Lab:build()
  self.recon = self.predict:make_reconciler(self.me, {
    input = self.input,
    fields = { "x", "y", "vx", "vy", "bumpTicks" },
    smoothing = 15,
    step = function(ctx, p, inp)
      p.bumpTicks = sim.step_bump_gate(p.bumpTicks)   -- reconciled tick gate
      sim.step_entity(p, inp.moveX, inp.moveY, ctx.dt)

      local px, py, gate, when = p.x, p.y, p.bumpTicks, ctx.reckon_time
      local knock
      if self.use_memo then
        knock = ctx:memo("bump", function() return self:test_bots(px, py, gate, when) end)
      else
        knock = self:test_bots(px, py, gate, when)
      end

      if knock ~= nil then
        p.vx, p.vy = knock[1], knock[2]
        p.bumpTicks = sim.BUMP_COOLDOWN_TICKS       -- immunity rides adopt+replay
        if not ctx.is_replay then                   -- FX/counters: live step only
          self.bumps_predicted = self.bumps_predicted + 1
          self.last_bump_at = app.now_ms()
          self.bump_flash_t = self.last_bump_at
        end
      end
    end,
  })
  self._last_reconcile_seq = 0
end

function Lab:mispredict_rate()
  if self.bumps_predicted == 0 then return 0 end
  return self.mispredicts / self.bumps_predicted * 100
end

function Lab:frame(context, now, dt_ms)
  -- Both toggles rebuild nothing — the step reads them live.
  if kb.key("v") then self.use_value_at = not self.use_value_at end
  if kb.key("m") then self.use_memo = not self.use_memo end

  -- The acceptance script can't hand-steer into a moving bot; when it drives,
  -- seek the bot's lane and let the patrol sweep do the rest.
  local move_x, move_y = kb.move_x(), kb.move_y()
  if kb.autopilot then
    local dy = self.predict:value(self.bot, "y") - self.recon.state.y
    move_x = 0
    move_y = dy > 1.0 and 1 or dy < -1.0 and -1 or 0
  end

  local steps = self.predict:tick(now)
  for _ = 1, steps do
    self.cmd.moveX = move_x
    self.cmd.moveY = move_y
    self.input:send()
  end

  -- Attribute LARGE corrections near a predicted bump to a flipped verdict.
  -- Small post-bump corrections (< ~3u) are knockback-direction epsilon; a
  -- genuinely flipped verdict diverges by many units — the 48 u/s shove either
  -- happened or it didn't.
  if self.recon.reconcile_seq ~= self._last_reconcile_seq then
    self._last_reconcile_seq = self.recon.reconcile_seq
    if self.recon.last_correction_mag > 3 and app.now_ms() - self.last_bump_at < 700 then
      self.mispredicts = self.mispredicts + 1
    end
  end
end

function Lab:render(gfx)
  self.room.state.players:each(function(p, key)
    if key ~= self.sid then
      gfx.square(self.predict:value(p, "x"), self.predict:value(p, "y"),
        sim.PLAYER_HALF, gfx.hue(p.hue, 0.4))
    end
  end)

  local bx, by = self.predict:value(self.bot, "x"), self.predict:value(self.bot, "y")
  gfx.circle(bx, by, sim.BOT_RADIUS, gfx.a(gfx.PALETTE.warn, 0.3))
  gfx.circle_outline(bx, by, sim.BOT_RADIUS, gfx.PALETTE.warn)
  gfx.label(bx, by, "bot (reckon = hit position)", gfx.PALETTE.warn, 10, -14)
  gfx.circle_outline(self.bot.x, self.bot.y, sim.BOT_RADIUS,
    gfx.a(gfx.PALETTE.text, 0.45), true)
  gfx.label(self.bot.x, self.bot.y, "stale snapshot", gfx.a(gfx.PALETTE.text, 0.45), 9, 14)

  gfx.ghost_square(self.me.x, self.me.y, sim.PLAYER_HALF, gfx.a(gfx.PALETTE.text, 0.5))
  local flash = app.now_ms() - self.bump_flash_t < 300
  local px, py = self.recon:value("x"), self.recon:value("y")
  gfx.square(px, py, sim.PLAYER_HALF, flash and gfx.PALETTE.bad or gfx.hue(self.me.hue))
  gfx.square_outline(px, py, sim.PLAYER_HALF, gfx.PALETTE.text, flash and 2.5 or 1)

  local rate = self:mispredict_rate()
  gfx.hud_section("TELEMETRY")
  gfx.hud_row("bumps predicted", tostring(self.bumps_predicted), gfx.PALETTE.text)
  gfx.hud_row("bumps (authoritative)", tostring(self.me.bumps), gfx.PALETTE.text)
  gfx.hud_row("mispredicts", tostring(self.mispredicts),
    self.mispredicts > 0 and gfx.PALETTE.warn or gfx.PALETTE.good)
  gfx.hud_row("mispredict rate",
    self.bumps_predicted > 0 and string.format("%.0f %%", rate) or "--",
    self.bumps_predicted == 0 and gfx.PALETTE.text_faint
      or (rate < 10 and gfx.PALETTE.good or rate < 40 and gfx.PALETTE.warn or gfx.PALETTE.bad))
  gfx.hud_row("bump immunity (ticks)", tostring(self.recon.state.bumpTicks), gfx.PALETTE.text)

  gfx.hud_section("CONTROLS")
  gfx.hud_key("WASD", "graze the bot's patrol path")
  gfx.hud_key("V", self.use_value_at and "read bot at ctx.reckon_time" or "read the STALE snapshot")
  gfx.hud_key("M", self.use_memo and "verdict frozen with memo" or "verdict RE-DERIVED on replay")
  gfx.hud_note("Raise the latency preset and graze the bot repeatedly. V off " ..
    "tests against a position ~RTT/2 behind where the server tests; M off lets " ..
    "replays re-derive the verdict against newer bot data and flip knife-edge " ..
    "calls. Both off is maximally wrong.")
end

function Lab:unmount() self.predict:dispose() end

function Lab:on_reconnect()
  self.me = self.room.state.players[self.sid]
  self.bot = self.room.state.bots["bot1"]
  if self.me == nil then return end
  self:build()
end

return Lab
