--
-- Lab 05 — Dead Reckoning.
--
-- Instead of drawing the PAST (lerp), forward-simulate the latest snapshot to
-- the PRESENT with the same step function the server runs. The reckon horizon is
-- exactly the snapshot age.
--
--   smooth_ms  glide applied to each snapshot REBASE (the small correction when
--              a patch lands mid-glide).
--   snap       rebases beyond this distance POP instead of gliding: a teleport
--              is a cut, and smoothing across it looks like flying.
--
-- Port of src/client/labs/05-dead-reckoning/.
--
local sim = require 'playground.sim'
local app = require 'playground.app'
local Predict = require 'colyseus.predict.predict'

local kb = app.kb
local PATTERNS = { "teleport", "patrol", "wander", "circle" }

--- The reckon scratch is a FULL copy of the entity, so descriptors this lab
--- never attached — `kind`, the patrol bounds — are readable straight off it.
--- The schema uses the server's camelCase names (everything decodes from
--- reflection here, so there is no codegen to rename them); step_bot takes the
--- snake_case shape the rest of this port uses.
local function to_sim(b)
  return {
    x = b.x, y = b.y, vx = b.vx, vy = b.vy, kind = b.kind,
    min_x = b.minX, max_x = b.maxX, base_y = b.baseY,
    phase_ms = b.phaseMs, speed = b.speed, last_teleport = b.lastTeleport,
  }
end

local Lab = {
  id = "05-dead-reckoning",
  num = 5,
  title = "Dead Reckoning",
  blurb = "Forward-simulate remotes to the present with the shared step.",
  room_name = "lab-bots",
}
Lab.__index = Lab

function Lab.new()
  return setmetatable({
    smooth_ms = 40, snap = 8, pattern = 1,
    dots = {}, warps = 0, warp_flash_t = -1e9, peak_gap = 0,
  }, Lab)
end

function Lab:ready(room)
  return room.state.bots ~= nil and room.state.bots["bot1"] ~= nil
end

function Lab:mount(context, room)
  self.room = room
  self.sid = room.session_id
  self.bot = room.state.bots["bot1"]
  if self.bot == nil then return false end

  -- The delayed baseline to compare against.
  self.lerp = Predict.get(room)
  local lerp_opts = { mode = "lerp", delay = sim.REMOTE_INTERP_MS }
  self.lerp:attach(self.bot, { x = lerp_opts, y = lerp_opts })

  self:attach_reckon()

  self.input = room:input()
  self.cmd = self.input.data
  self.pacer = app.Pacer.new(1000.0 / sim.TICK_HZ)

  self:set_pattern(PATTERNS[1])   -- the teleporter is the most legible default
  return true
end

--- The reckon step, called by the SDK with a scratch COPY of the bot.
--- `elapsed_ms` is absolute server-time at the end of the substep, which is what
--- makes the circle's closed form and the teleport schedule evaluable at any
--- instant — the same property the server relies on.
function Lab:attach_reckon()
  self.reckon = Predict.get(self.room)
  self.reckon:attach(self.bot, {
    mode = "reckon",
    fields = { "x", "y" },
    smooth_ms = self.smooth_ms,
    snap = self.snap,
    step = function(b, dt, elapsed_ms)
      local s = to_sim(b)
      sim.step_bot(s, dt, elapsed_ms)
      b.x, b.y, b.vx, b.vy = s.x, s.y, s.vx, s.vy
      -- Scratch mutation only persists within one forward pass — exactly right:
      -- periods chain, nothing leaks into the snapshot.
      b.lastTeleport = s.last_teleport
    end,
  })
end

function Lab:rebuild()
  self.reckon:dispose()
  self:attach_reckon()
end

function Lab:set_pattern(kind)
  for i, p in ipairs(PATTERNS) do
    if p == kind then
      self.pattern = i
      self.room:send("pattern", { kind = kind })
      self.warps, self.peak_gap = 0, 0
      return
    end
  end
end

function Lab:frame(context, now, dt_ms)
  if kb.key("b") then self:set_pattern(PATTERNS[self.pattern % #PATTERNS + 1]) end
  local smooth_step = kb.key("equals") and 10 or kb.key("minus") and -10 or 0
  if smooth_step ~= 0 then
    self.smooth_ms = math.max(0, math.min(200, self.smooth_ms + smooth_step))
    self:rebuild()
  end
  local snap_step = kb.key("period") and 6 or kb.key("comma") and -6 or 0
  if snap_step ~= 0 then
    self.snap = math.max(1, math.min(60, self.snap + snap_step))
    self:rebuild()
  end

  local steps = self.pacer:steps(now)
  for _ = 1, steps do
    self.cmd.moveX = kb.move_x()
    self.cmd.moveY = kb.move_y()
    self.input:send()
  end
  self.lerp:tick(now)
  self.reckon:tick(now)

  if self.bot.x ~= self.last_raw_x or self.bot.y ~= self.last_raw_y then
    self.last_raw_x, self.last_raw_y = self.bot.x, self.bot.y
    table.insert(self.dots, { self.bot.x, self.bot.y, now })
    if #self.dots > 40 then table.remove(self.dots, 1) end
  end

  local rx, ry = self.reckon:value(self.bot, "x"), self.reckon:value(self.bot, "y")
  if self.last_reckon_x ~= nil and math.abs(rx - self.last_reckon_x) > 15 then
    self.warps = self.warps + 1
    self.warp_flash_t = now
  end
  self.last_reckon_x = rx

  local gx = rx - self.lerp:value(self.bot, "x")
  local gy = ry - self.lerp:value(self.bot, "y")
  local gap = math.sqrt(gx * gx + gy * gy)
  if gap > self.peak_gap then self.peak_gap = gap end
end

function Lab:render(gfx)
  local now = app.now_ms()
  local clock = self.room.clock
  local age = math.max(0, clock:server_now() - clock:last_server_time())

  self.room.state.players:each(function(p, key)
    gfx.square(p.x, p.y, sim.PLAYER_HALF, gfx.hue(p.hue, key == self.sid and 0.9 or 0.4))
  end)

  -- Raw snapshot dots, fading over 1.5 s — the samples reckon starts from.
  for _, d in ipairs(self.dots) do
    local a = 1 - (now - d[3]) / 1500.0
    if a > 0 then gfx.circle(d[1], d[2], 0.4, gfx.a(gfx.PALETTE.text, a * 0.5)) end
  end

  local lx, ly = self.lerp:value(self.bot, "x"), self.lerp:value(self.bot, "y")
  local rx, ry = self.reckon:value(self.bot, "x"), self.reckon:value(self.bot, "y")

  -- The reckon horizon: newest snapshot -> forward-simulated present.
  gfx.dashed(self.bot.x, self.bot.y, rx, ry, gfx.a(gfx.PALETTE.warn, 0.8), 1.2)
  gfx.circle(self.bot.x, self.bot.y, 0.7, gfx.a(gfx.PALETTE.text, 0.9))

  gfx.circle_outline(lx, ly, sim.BOT_RADIUS, gfx.PALETTE.blue)
  gfx.label(lx, ly, "lerp (past)", gfx.PALETTE.blue, 10, 14)
  gfx.circle(rx, ry, sim.BOT_RADIUS, gfx.a(gfx.PALETTE.warn, 0.25))
  gfx.circle_outline(rx, ry, sim.BOT_RADIUS, gfx.PALETTE.warn)
  gfx.label(rx, ry, "reckon (present)", gfx.PALETTE.warn, 10, -14)

  if now - self.warp_flash_t < 500 then
    gfx.label(rx, ry, "WARP", gfx.PALETTE.bad, 13, -30)
  end

  local dx, dy = rx - lx, ry - ly
  gfx.hud_section("TELEMETRY")
  gfx.hud_row("reckon horizon (snapshot age)", string.format("%.0f ms", age), gfx.PALETTE.text)
  gfx.hud_row("reckon vs lerp gap",
    string.format("%.1f u", math.sqrt(dx * dx + dy * dy)), gfx.PALETTE.text)
  gfx.hud_row("warps seen", tostring(self.warps), gfx.PALETTE.text)

  gfx.hud_section("CONTROLS")
  gfx.hud_key("WASD", "drive your own square")
  gfx.hud_key("B", "bot pattern: " .. PATTERNS[self.pattern])
  gfx.hud_key("- / =", string.format("rebase smoothing  %.0f ms", self.smooth_ms))
  gfx.hud_key(", / .", string.format("snap threshold  %.0f u", self.snap))
  gfx.hud_note("patrol = fully predictable — wander = server-secret turns, so " ..
    "reckon extrapolates straight through every one and gets corrected — " ..
    "teleport = a scheduled discontinuity. Raise the snap threshold above the " ..
    "warp distance and watch the teleport smear across the arena.")
end

function Lab:unmount()
  if self.reckon then self.reckon:dispose() end
  if self.lerp then self.lerp:dispose() end
end

function Lab:on_reconnect()
  self.pacer:reset()
  self.bot = self.room.state.bots["bot1"]
  self.dots = {}
end

return Lab
