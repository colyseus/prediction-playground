--
-- Lab 04 — Remote Interpolation.
--
-- The SAME bot rendered through four Predict instances, one per mode:
--
--   raw          the decoded snapshot verbatim: stutters at patch rate.
--   lerp         render `delay` ms in the PAST, between two real samples.
--                Never wrong, always late.
--   damped       exponential chase of the newest sample: lags by construction
--                and rounds corners.
--   extrapolate  project the trend FORWARD. Present-time, but overshoots
--                whenever the bot turns.
--
-- Port of src/client/labs/04-interp-modes/.
--
local sim = require 'playground.sim'
local app = require 'playground.app'
local Predict = require 'colyseus.predict.predict'

local kb = app.kb
local PATTERNS = { "patrol", "circle", "wander" }

--- Coefficient of variation of rendered per-frame speed — the "limp" metric.
--- Constant speed scores 0; a mode that stutters between stalls and jumps
--- scores high.
local Smoothness = {}
Smoothness.__index = Smoothness

function Smoothness.new()
  return setmetatable({ speeds = {}, head = 0, count = 0, seeded = false }, Smoothness)
end

function Smoothness:clear()
  self.speeds, self.head, self.count, self.seeded = {}, 0, 0, false
end

function Smoothness:sample(x, y, dt_ms)
  if self.seeded and dt_ms > 0 then
    local dx, dy = x - self.last_x, y - self.last_y
    self.head = self.head % 120 + 1
    self.speeds[self.head] = math.sqrt(dx * dx + dy * dy) / dt_ms * 1000.0
    if self.count < 120 then self.count = self.count + 1 end
  end
  self.last_x, self.last_y, self.seeded = x, y, true
end

--- nil when there isn't enough motion for the ratio to mean anything.
function Smoothness:cv()
  if self.count < 20 then return nil end
  local mean = 0
  for i = 1, self.count do mean = mean + self.speeds[i] end
  mean = mean / self.count
  if mean < 0.5 then return nil end
  local var = 0
  for i = 1, self.count do
    local d = self.speeds[i] - mean
    var = var + d * d
  end
  return math.sqrt(var / self.count) / mean
end

local Lab = {
  id = "04-interp-modes",
  num = 4,
  title = "Remote Interpolation",
  blurb = "lerp / damped / extrapolate / raw, side by side.",
  room_name = "lab-bots",
}
Lab.__index = Lab

function Lab.new()
  return setmetatable({ pattern = 1, bot_travel = 0 }, Lab)
end

function Lab:ready(room)
  return room.state.bots ~= nil and room.state.bots["bot1"] ~= nil
end

function Lab:mount(context, room)
  self.room = room
  self.sid = room.session_id
  self.bot = room.state.bots["bot1"]
  if self.bot == nil then return false end

  self.input = room:input()
  self.cmd = self.input.data
  self.pacer = app.Pacer.new(1000.0 / sim.TICK_HZ)

  -- One Predict per mode — same entity, same fields, different smoothing.
  local function attach(name, color_key, opts)
    local predict = Predict.for_room(room)
    predict:track(self.bot, "x", opts)
    predict:track(self.bot, "y", opts)
    return { name = name, color_key = color_key, predict = predict,
             visible = true, smooth = Smoothness.new() }
  end

  self.modes = {
    { name = "raw", color_key = "text", visible = true, smooth = Smoothness.new() },
    attach("lerp", "blue", { mode = "lerp", delay = sim.REMOTE_INTERP_MS }),
    attach("damped", "good", { mode = "damped", damping = 12 }),
    attach("extrapolate", "warn", { mode = "extrapolate", max_extrapolate = 250 }),
  }
  return true
end

function Lab:value(mode, field)
  if mode.predict == nil then return self.bot[field] end   -- raw: the instance
  return mode.predict:value(self.bot, field)
end

function Lab:set_pattern(kind)
  for i, p in ipairs(PATTERNS) do
    if p == kind then
      self.pattern = i
      self.room:send("pattern", { kind = kind })
      return
    end
  end
end

--- Start a clean measurement window once a pattern change has landed.
function Lab:reset_meters()
  for _, m in ipairs(self.modes) do m.smooth:clear() end
  self.bot_travel = 0
end

function Lab:frame(context, now, dt_ms)
  if kb.key("b") then
    self:set_pattern(PATTERNS[self.pattern % #PATTERNS + 1])
  end
  for i = 1, 4 do
    if kb.key("f" .. i) then self.modes[i].visible = not self.modes[i].visible end
  end

  local steps = self.pacer:steps(now)
  for _ = 1, steps do
    self.cmd.moveX = kb.move_x()
    self.cmd.moveY = kb.move_y()
    self.input:send()
  end
  for _, m in ipairs(self.modes) do
    if m.predict then m.predict:tick(now) end
  end

  if self.last_raw_x ~= nil and (self.bot.x ~= self.last_raw_x or self.bot.y ~= self.last_raw_y) then
    local dx, dy = self.bot.x - self.last_raw_x, self.bot.y - self.last_raw_y
    self.bot_travel = self.bot_travel + math.sqrt(dx * dx + dy * dy)
  end
  self.last_raw_x, self.last_raw_y = self.bot.x, self.bot.y

  for _, m in ipairs(self.modes) do
    m.smooth:sample(self:value(m, "x"), self:value(m, "y"), dt_ms)
  end
end

function Lab:render(gfx)
  self.room.state.players:each(function(p, key)
    gfx.square(p.x, p.y, sim.PLAYER_HALF, gfx.hue(p.hue, key == self.sid and 0.9 or 0.4))
  end)

  for i, m in ipairs(self.modes) do
    if m.visible then
      local x, y = self:value(m, "x"), self:value(m, "y")
      gfx.circle_outline(x, y, sim.BOT_RADIUS, gfx.PALETTE[m.color_key], i == 1)
      -- Stagger the labels: the four modes sit within a bot radius of each
      -- other most of the time, so a shared baseline is unreadable.
      gfx.label(x, y, m.name, gfx.PALETTE[m.color_key], 10, -14 - (i - 1) * 11)
    end
  end

  gfx.hud_section("SMOOTHNESS (speed CV)")
  for _, m in ipairs(self.modes) do
    local cv = m.smooth:cv()
    if cv == nil then
      gfx.hud_row(m.name, "--", gfx.PALETTE.text_faint)
    else
      gfx.hud_row(m.name, string.format("%.0f %%", cv * 100),
        cv < 0.15 and gfx.PALETTE.good or cv < 0.5 and gfx.PALETTE.warn or gfx.PALETTE.bad)
    end
  end
  gfx.hud_row("bot travel", string.format("%.0f u", self.bot_travel), gfx.PALETTE.text)

  gfx.hud_section("CONTROLS")
  gfx.hud_key("WASD", "drive your own square")
  gfx.hud_key("B", "bot pattern: " .. PATTERNS[self.pattern])
  for i, m in ipairs(self.modes) do
    gfx.hud_key("F" .. i, (m.visible and "hide " or "show ") .. m.name)
  end
  gfx.hud_note("Lower CV = smoother render. raw stutters at the patch rate; " ..
    "lerp is smooth but late; damped rounds corners; extrapolate is present-time " ..
    "but overshoots every turn — press B and watch it on circle.")
end

function Lab:unmount()
  for _, m in ipairs(self.modes) do
    if m.predict then m.predict:dispose() end
  end
end

function Lab:on_reconnect()
  self.pacer:reset()
  self.bot = self.room.state.bots["bot1"]
end

return Lab
