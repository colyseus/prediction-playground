--
-- Lab 11 — Deterministic Randomness.
--
-- The shotgun fan is "random", yet the client predicts every pellet EXACTLY —
-- because the randomness is a pure function of data both sides already share:
--
--   seed = splitmix32(input seq ^ room salt)  ->  mulberry32 pellet stream
--
-- The seq is the engine's own input counter (input:send() returns it; the server
-- reads channel.consumedCount). The salt is synced room state. NOTHING about the
-- pellets rides the wire — the server's broadcast here carries its angles only
-- so this lab can overlay and compare.
--
-- Port of src/client/labs/11-deterministic-rng/.
--
local sim = require 'playground.sim'
local app = require 'playground.app'
local Predict = require 'colyseus.predict.predict'

local kb = app.kb
local FAN_LEN = 40.0
local FAN_FADE_MS = 2400

local Lab = {
  id = "11-deterministic-rng",
  num = 11,
  title = "Deterministic Randomness",
  blurb = "Same seed both sides, nothing on the wire.",
  room_name = "lab-range",
}
Lab.__index = Lab

function Lab.new()
  return setmetatable({
    aim_x = 50, aim_y = 20,
    pending_fire = false,
    cheat = false,
    cheat_rng = sim.mulberry32(0x1234567),
    fans = {},
    max_divergence = nil,
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
  -- Bots ride the lerp timeline — the one the server rewinds to.
  self.predict:attach_all("bots", { "x", "y" },
    { mode = "lerp", delay = sim.REMOTE_INTERP_MS })
  self.predict:attach_all("players", { "x", "y" }, { mode = "damped" })

  room:on_message("spread", function(m) self:on_spread(m) end)

  self.input = room:input({ allow_rewind = function(data) return data.fire end })
  self.cmd = self.input.data
  self:build()
  return true
end

function Lab:build()
  self.recon = self.predict:reconciler(self.me, {
    input = self.input,
    fields = { "x", "y", "vx", "vy" },
    smoothing = 15,
    step = function(ctx, p, inp) sim.step_entity(p, inp.moveX, inp.moveY, ctx.dt) end,
  })
end

--- The client's half of the derivation — identical to the server's.
function Lab:client_fan(base_angle, seq, salt)
  if not self.cheat then return sim.spread_angles(base_angle, seq, salt) end
  -- The broken version: a local RNG the server cannot reproduce.
  local out = {}
  for i = 1, sim.PELLETS do
    out[i] = base_angle + (self.cheat_rng() - 0.5) * sim.SPREAD_RAD
  end
  return out
end

--- The server's fan for the same (seq, salt) — for overlay only.
function Lab:on_spread(m)
  if m.sid ~= self.sid or m.seq == nil then return end
  for _, f in ipairs(self.fans) do
    if f.seq == m.seq then
      local worst = 0
      for i = 1, math.min(#m.angles, sim.PELLETS) do
        f.server[i] = m.angles[i]
        local d = math.abs(f.client[i] - f.server[i])
        if d > worst then worst = d end
      end
      f.hits = m.hits or 0
      f.answered = true
      self.max_divergence = worst
      return
    end
  end
end

function Lab:fire() self.pending_fire = true end

function Lab:answered_fans()
  local n = 0
  for _, f in ipairs(self.fans) do if f.answered then n = n + 1 end end
  return n
end

function Lab:frame(context, now, dt_ms)
  if kb.autopilot then
    self.aim_x = self.predict:value(self.bot, "x")
    self.aim_y = self.predict:value(self.bot, "y")
  end
  if kb.key("space") then self.pending_fire = true end
  if kb.key("x") then self.cheat = not self.cheat end

  local steps = self.predict:tick(now)
  for _ = 1, steps do
    self.cmd.moveX = kb.move_x()
    self.cmd.moveY = kb.move_y()
    self.cmd.aimX = self.aim_x
    self.cmd.aimY = self.aim_y
    self.cmd.fire = self.pending_fire
    self.cmd.spread = true
    local seq = self.input:send()
    if self.pending_fire and seq and seq > 0 then
      local px, py = self.recon.state.x, self.recon.state.y
      local base = math.atan2(self.aim_y - py, self.aim_x - px)
      table.insert(self.fans, {
        seq = seq, ox = px, oy = py, t = now, answered = false, hits = 0,
        client = self:client_fan(base, seq, self.room.state.salt),
        server = {},
      })
      if #self.fans > 4 then table.remove(self.fans, 1) end
      self.pending_fire = false
    end
  end
end

function Lab:render(gfx)
  local now = app.now_ms()

  self.room.state.players:each(function(p, key)
    if key ~= self.sid then
      gfx.square(self.predict:value(p, "x"), self.predict:value(p, "y"),
        sim.PLAYER_HALF, gfx.hue(p.hue, 0.4))
    end
  end)

  local px, py = self.recon:value("x"), self.recon:value("y")
  gfx.square(px, py, sim.PLAYER_HALF, gfx.hue(self.me.hue))
  gfx.square_outline(px, py, sim.PLAYER_HALF, gfx.PALETTE.text, 1)

  local bx, by = self.predict:value(self.bot, "x"), self.predict:value(self.bot, "y")
  gfx.circle(bx, by, sim.BOT_RADIUS, gfx.a(gfx.PALETTE.blue, 0.25))
  gfx.circle_outline(bx, by, sim.BOT_RADIUS, gfx.PALETTE.blue)
  gfx.circle_outline(self.aim_x, self.aim_y, 0.9, gfx.a(gfx.PALETTE.text, 0.7))

  for i = #self.fans, 1, -1 do
    local f = self.fans[i]
    local age = now - f.t
    if age > FAN_FADE_MS then
      table.remove(self.fans, i)
    else
      local a = 1 - age / FAN_FADE_MS
      for p = 1, sim.PELLETS do
        local ang = f.client[p]
        gfx.line(f.ox, f.oy, f.ox + math.cos(ang) * FAN_LEN, f.oy + math.sin(ang) * FAN_LEN,
          gfx.a(gfx.PALETTE.warn, a * 0.75), 1.2)
      end
      if f.answered then
        for p = 1, sim.PELLETS do
          local ang = f.server[p]
          if ang then
            gfx.dashed(f.ox, f.oy, f.ox + math.cos(ang) * FAN_LEN,
              f.oy + math.sin(ang) * FAN_LEN, gfx.a(gfx.PALETTE.text, a * 0.9), 0.8)
          end
        end
      end
    end
  end
  if #self.fans > 0 then
    local last = self.fans[#self.fans]
    gfx.label(last.ox, last.oy, "amber = client — white = server",
      gfx.a(gfx.PALETTE.text, 0.5), 9, 14)
  end

  local last_hits
  for i = #self.fans, 1, -1 do
    if self.fans[i].answered then last_hits = self.fans[i].hits; break end
  end

  gfx.hud_section("TELEMETRY")
  gfx.hud_row("fan divergence (last shot)",
    self.max_divergence and string.format("%.5f rad", self.max_divergence) or "--",
    self.max_divergence == nil and gfx.PALETTE.text_faint
      or (self.max_divergence < 1e-6 and gfx.PALETTE.good or gfx.PALETTE.bad))
  gfx.hud_row("pellets hit (last shot)",
    last_hits and string.format("%d / %d", last_hits, sim.PELLETS) or "--",
    last_hits and gfx.PALETTE.text or gfx.PALETTE.text_faint)
  gfx.hud_row("room salt", tostring(self.room.state.salt), gfx.PALETTE.text)
  gfx.hud_row("shots (authoritative)", tostring(self.me.shots), gfx.PALETTE.text)

  gfx.hud_section("CONTROLS")
  gfx.hud_key("WASD", "drive")
  gfx.hud_key("mouse", "aim")
  gfx.hud_key("click / SPACE", "fire a 6-pellet fan")
  gfx.hud_key("X", self.cheat and "CHEATING with a local RNG" or "seeded from (seq, salt)")
  gfx.hud_note("Amber = the fan your client derived at the click. White dashes = " ..
    "the fan the server derived from the same (seq, salt). They should be " ..
    "identical to the pixel. Press X to swap in an unshared RNG and watch them " ..
    "disagree.")
end

function Lab:unmount() self.predict:dispose() end

function Lab:on_reconnect()
  self.me = self.room.state.players[self.sid]
  self.bot = self.room.state.bots["bot1"]
  if self.me == nil then return end
  self:build()
end

return Lab
