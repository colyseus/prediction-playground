--
-- Lab 06 — Lag Compensation.
--
-- The client's job is only to be HONEST about its display timeline:
--  - bots are DRAWN with lerp, REMOTE_INTERP_MS in the past;
--  - the server records bot history and, on a fire input, rewinds every target
--    to this client's render time — the instant the shooter aimed at;
--  - allow_rewind stamps the render time ONLY on fire frames (movement inputs
--    don't need the extra wire bytes).
--
-- Markers: blue = what you saw, green = the server's rewound read, red = the
-- server's live position. With lag comp on they coincide; with it off, the
-- red/blue gap is exactly how far you must lead.
--
-- Port of src/client/labs/06-lag-comp/.
--
local sim = require 'playground.sim'
local app = require 'playground.app'
local net_delay = require 'playground.net_delay'
local Predict = require 'colyseus.predict.predict'

local kb = app.kb
local SHOT_FADE_MS = 2600

local Lab = {
  id = "06-lag-comp",
  num = 6,
  title = "Lag Compensation",
  blurb = "The server rewinds targets to what you saw.",
  room_name = "lab-range",
}
Lab.__index = Lab

function Lab.new()
  return setmetatable({
    aim_x = 50, aim_y = 20,
    pending_fire = false,
    shots = {},
    hits_on = 0, shots_on = 0, hits_off = 0, shots_off = 0,
    -- Shots this screen called a hit at the click, before any report.
    predicted_hits = 0,
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

  self.predict = Predict.get(room)
  -- Bots ride the lerp timeline — the one the server rewinds to.
  self.predict:attach_all("bots", {
    x = { mode = "lerp", delay = sim.REMOTE_INTERP_MS },
    y = { mode = "lerp", delay = sim.REMOTE_INTERP_MS },
  })
  self.predict:attach_all("players", { x = "damped", y = "damped" })

  room:on_message("shot", function(m) self:on_shot(m) end)

  -- render_delay is bound for us: :reconciler() pushes this Predict's lerp
  -- delay onto the handle, so the server rewinds to exactly the instant we drew.
  -- Passing it here would only override that.
  self.input = room:input({ allow_rewind = function(data) return data.fire end })
  self.cmd = self.input.data
  self:build()
  net_delay.use_preset(3)     -- lag comp says nothing on a 1 ms link
  return true
end

function Lab:build()
  self.recon = self.predict:reconciler(self.me, {
    input = self.input,
    fields = { "x", "y", "vx", "vy" },
    smooth_ms = 65,
    step = function(ctx, p, inp) sim.step_entity(p, inp.moveX, inp.moveY, ctx.dt) end,
  })
end

--- The server's shot report completes the oldest unanswered record.
function Lab:on_shot(m)
  if m.sid ~= self.sid then return end
  for _, s in ipairs(self.shots) do
    if not s.answered then
      s.answered = true
      s.hit = m.hit and true or false
      s.green_x, s.green_y = m.seenX, m.seenY
      s.red_x, s.red_y = m.liveX, m.liveY
      break
    end
  end
  if m.lagComp then
    self.shots_on = self.shots_on + 1
    if m.hit then self.hits_on = self.hits_on + 1 end
  else
    self.shots_off = self.shots_off + 1
    if m.hit then self.hits_off = self.hits_off + 1 end
  end
end

function Lab:fire() self.pending_fire = true end
function Lab:set_lag_comp(on) self.room:send("lagcomp", { on = on }) end

--- Record what THIS screen showed at the moment of the shot.
function Lab:record_shot(now)
  local px, py = self.recon.state.x, self.recon.state.y
  local dx, dy = self.aim_x - px, self.aim_y - py
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1e-9 then len = 1 end
  dx, dy = dx / len, dy / len
  local bx = self.predict:value(self.bot, "x")
  local by = self.predict:value(self.bot, "y")
  -- The server's own hit test, run against the pose THIS screen was showing.
  -- Available immediately, and it agrees with the server whenever the rewind
  -- lands where it should.
  local predicted = sim.ray_circle(px, py, dx, dy, bx, by, sim.BOT_RADIUS, sim.SHOT_RANGE) >= 0
  if predicted then self.predicted_hits = self.predicted_hits + 1 end
  table.insert(self.shots, {
    ox = px, oy = py, tx = px + dx * 120, ty = py + dy * 120,
    blue_x = bx, blue_y = by,
    predicted_hit = predicted,
    answered = false, hit = false, t = now,
  })
  if #self.shots > 6 then table.remove(self.shots, 1) end
end

--- Newest answered shot's red/blue distance — how far the view lags. -1 if none.
function Lab:view_lag()
  for i = #self.shots, 1, -1 do
    local s = self.shots[i]
    if s.answered then
      local dx, dy = s.red_x - s.blue_x, s.red_y - s.blue_y
      return math.sqrt(dx * dx + dy * dy)
    end
  end
  return -1
end

--- How far the server's rewound read landed from what we drew. This is the
--- number that exposes an unbound render_delay: it grows to exactly the lerp
--- delay's worth of bot travel and nothing else in the lab says so.
function Lab:rewind_error()
  for i = #self.shots, 1, -1 do
    local s = self.shots[i]
    if s.answered then
      local dx, dy = s.green_x - s.blue_x, s.green_y - s.blue_y
      return math.sqrt(dx * dx + dy * dy)
    end
  end
  return -1
end

function Lab:frame(context, now, dt_ms)
  if kb.autopilot then
    -- The acceptance script has no cursor — track the target it fires at.
    self.aim_x = self.predict:value(self.bot, "x")
    self.aim_y = self.predict:value(self.bot, "y")
  end
  if kb.key("space") then self.pending_fire = true end
  if kb.key("c") then self:set_lag_comp(not self.room.state.lagComp) end

  local steps = self.predict:tick(now)
  for _ = 1, steps do
    self.cmd.moveX = kb.move_x()
    self.cmd.moveY = kb.move_y()
    self.cmd.aimX = self.aim_x
    self.cmd.aimY = self.aim_y
    self.cmd.fire = self.pending_fire
    self.input:send()
    if self.pending_fire then
      self:record_shot(now)
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
  gfx.label(bx, by, "target (lerp view)", gfx.PALETTE.blue, 10, -14)

  gfx.dashed(px, py, self.aim_x, self.aim_y, gfx.a(gfx.PALETTE.text, 0.18), 1)
  gfx.circle_outline(self.aim_x, self.aim_y, 0.9, gfx.a(gfx.PALETTE.text, 0.7))

  for i = #self.shots, 1, -1 do
    local s = self.shots[i]
    local age = now - s.t
    if age > SHOT_FADE_MS then
      table.remove(self.shots, i)
    else
      local a = 1 - age / SHOT_FADE_MS
      -- Until the report lands the ray wears this screen's own verdict, faint;
      -- the server's answer replaces it at full strength. A ray that flips
      -- colour is the rewind disagreeing with what you saw. (Spelled out, not
      -- `and/or`: the verdict is a boolean and false would fall through.)
      local verdict, weight
      if s.answered then verdict, weight = s.hit, 0.7
      else verdict, weight = s.predicted_hit, 0.3 end
      local ray = gfx.a(verdict and gfx.PALETTE.good or gfx.PALETTE.bad, a * weight)
      gfx.line(s.ox, s.oy, s.tx, s.ty, ray, 1.2)
      gfx.circle_outline(s.blue_x, s.blue_y, sim.BOT_RADIUS * 0.7, gfx.a(gfx.PALETTE.blue, a))
      if s.answered then
        gfx.circle_outline(s.green_x, s.green_y, sim.BOT_RADIUS * 0.85, gfx.a(gfx.PALETTE.good, a))
        gfx.circle_outline(s.red_x, s.red_y, sim.BOT_RADIUS, gfx.a(gfx.PALETTE.bad, a))
      end
    end
  end

  local gap = self:view_lag()
  gfx.hud_section("TELEMETRY")
  gfx.hud_row("hits (lag comp ON)", string.format("%d / %d", self.hits_on, self.shots_on),
    (self.shots_on > 0 and self.hits_on * 10 > self.shots_on * 7)
      and gfx.PALETTE.good or gfx.PALETTE.text)
  gfx.hud_row("hits (lag comp OFF)", string.format("%d / %d", self.hits_off, self.shots_off),
    (self.shots_off > 0 and self.hits_off * 2 < self.shots_off)
      and gfx.PALETTE.bad or gfx.PALETTE.text)
  gfx.hud_row("view lag (red<->blue gap)",
    gap >= 0 and string.format("%.1f u", gap) or "--",
    gap >= 0 and gfx.PALETTE.text or gfx.PALETTE.text_faint)

  gfx.hud_section("CONTROLS")
  gfx.hud_key("WASD", "drive (predicted)")
  gfx.hud_key("mouse", "aim")
  gfx.hud_key("click / SPACE", "fire")
  gfx.hud_key("C", self.room.state.lagComp and "lag comp: ON (room-wide)"
    or "lag comp: OFF (room-wide)")
  gfx.hud_note("blue = what you saw — green = the server's rewound read — red = " ..
    "the server live. The ray shows your own verdict faintly at the click, then " ..
    "the server's at full strength. Turn lag comp off at 200 ms and you have to " ..
    "lead the target by exactly the red-to-blue gap.")
end

function Lab:unmount() self.predict:dispose() end

function Lab:on_reconnect()
  self.me = self.room.state.players[self.sid]
  self.bot = self.room.state.bots["bot1"]
  if self.me == nil then return end
  self:build()
end

return Lab
