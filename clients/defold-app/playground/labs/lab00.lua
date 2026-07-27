--
-- Lab 00 — Lag vs Prediction (the hero).
--
-- Runs lab 03's netcode VERBATIM — same room, same reconciler, same entity, via
-- the shared MoveLane. The split screen is a RENDER-layer choice, not a
-- different protocol: the top lane draws the raw decoded server state (what lab
-- 01 draws), the bottom lane draws the reconciler's predicted pose (what lab 03
-- draws). Prediction is a client-side choice over the same authority.
--
-- Port of src/client/labs/00-split/.
--
local sim = require 'playground.sim'
local app = require 'playground.app'
local net_delay = require 'playground.net_delay'
local MoveLane = require 'playground.move_lane'

local kb = app.kb

--- Reversal-heavy autopilot legs — reversals are where the echo lane visibly
--- keeps going the wrong way for a full round trip.
local SCRIPT = {
  { 1, 0, 850 }, { -1, 0, 700 }, { 1, 0, 550 }, { 0, 1, 650 }, { 0, -1, 700 },
  { 1, 1, 600 }, { -1, -1, 750 }, { -1, 0, 550 }, { 1, 0, 800 }, { 0, -1, 500 },
}

local Lab = {
  id = "00-split",
  num = 0,
  title = "Lag vs Prediction",
  blurb = "Same input, same server — the top lane waits, the bottom predicts.",
  room_name = "lab-move",
  own_arena = true,     -- this lab paints two arenas of its own
}
Lab.__index = Lab

function Lab.new()
  return setmetatable({
    lane = MoveLane.new(),
    user_drove = false,
    leg_index = 0, leg_x = 1, leg_y = 0, leg_until = 0,
    top_trail = {}, bot_trail = {},
    peak_gap = 0,
  }, Lab)
end

function Lab:ready(room) return MoveLane.ready(room) end

function Lab:mount(context, room)
  self.room = room
  if not self.lane:attach(room) then return false end
  -- The point of this lab is invisible on a 1 ms localhost link.
  net_delay.use_preset(4)
  return true
end

--- Scripted strides, steered away from a wall when a leg would hug one.
function Lab:autopilot(now, x, y)
  if now < self.leg_until then return end
  self.leg_index = self.leg_index + 1
  local leg = SCRIPT[(self.leg_index - 1) % #SCRIPT + 1]
  self.leg_x, self.leg_y = leg[1], leg[2]
  if x > sim.ARENA_W * 0.72 and self.leg_x > 0 then self.leg_x = -1
  elseif x < sim.ARENA_W * 0.28 and self.leg_x < 0 then self.leg_x = 1 end
  if y > sim.ARENA_H * 0.72 and self.leg_y > 0 then self.leg_y = -1
  elseif y < sim.ARENA_H * 0.28 and self.leg_y < 0 then self.leg_y = 1 end
  self.leg_until = now + leg[3]
end

local function push_trail(trail, x, y)
  table.insert(trail, { x, y })
  if #trail > 120 then table.remove(trail, 1) end
end

function Lab:frame(context, now, dt_ms)
  local lane = self.lane
  if not self.user_drove and kb.any_move() then self.user_drove = true end
  if not self.user_drove then self:autopilot(now, lane:x(), lane:y()) end

  lane:drive(now,
    self.user_drove and kb.move_x() or self.leg_x,
    self.user_drove and kb.move_y() or self.leg_y)

  push_trail(self.top_trail, lane.me.x, lane.me.y)
  push_trail(self.bot_trail, lane:x(), lane:y())

  -- Peak, not instantaneous: the gap collapses at every direction change.
  local dx, dy = lane:x() - lane.me.x, lane:y() - lane.me.y
  local gap = math.sqrt(dx * dx + dy * dy)
  if gap > self.peak_gap then self.peak_gap = gap end
end

local function draw_trail(gfx, trail, color, max_alpha)
  for i = 2, #trail do
    local a, b = trail[i - 1], trail[i]
    gfx.line(a[1], a[2], b[1], b[2], gfx.a(color, max_alpha * i / #trail), 1.5)
  end
end

function Lab:render(gfx)
  local lane = self.lane
  local me = lane.me
  local px, py = lane:x(), lane:y()

  -- Two lanes stacked in the stage. The backend maps lane 1/2 onto its own
  -- half of the viewport; a lab never learns the pixel geometry.
  gfx.lane(1)
  gfx.arena()
  gfx.lane_title("SERVER ECHO", "every move waits the full round trip",
    gfx.a(gfx.PALETTE.text, 0.85))
  self.room.state.players:each(function(p, key)
    if key ~= lane.sid then gfx.square(p.x, p.y, sim.PLAYER_HALF, gfx.hue(p.hue, 0.4)) end
  end)
  draw_trail(gfx, self.top_trail, gfx.PALETTE.text, 0.35)
  gfx.square(me.x, me.y, sim.PLAYER_HALF, gfx.hue(me.hue, 0.8))
  gfx.square_outline(me.x, me.y, sim.PLAYER_HALF, gfx.a(gfx.PALETTE.text, 0.5), 1)
  gfx.label(me.x, me.y, "you (server)", gfx.a(gfx.PALETTE.text, 0.6), 11, -15)

  gfx.lane(2)
  gfx.arena()
  gfx.lane_title("PREDICTED", "instant — reconciled against the same server",
    gfx.PALETTE.good)
  self.room.state.players:each(function(p, key)
    if key ~= lane.sid then
      gfx.square(lane:remote_x(p), lane:remote_y(p), sim.PLAYER_HALF, gfx.hue(p.hue, 0.4))
    end
  end)
  draw_trail(gfx, self.bot_trail, gfx.hue(me.hue), 0.45)
  gfx.square(px, py, sim.PLAYER_HALF, gfx.hue(me.hue))
  gfx.square_outline(px, py, sim.PLAYER_HALF, gfx.PALETTE.text, 1)
  gfx.label(px, py, "you (predicted)", gfx.PALETTE.text, 11, -15)
  gfx.lane(nil)

  local rtt = self.room.clock:smoothed_rtt()
  gfx.caption(string.format("ROUND TRIP ~ %.0f ms", rtt), gfx.PALETTE.accent)
  gfx.caption(self.user_drove
    and "Same keys, same server — the top lane waits, the bottom predicts."
    or "> autopilot — press WASD / arrows to take over",
    gfx.a(gfx.PALETTE.text_dim, 0.85))

  gfx.hud_section("TELEMETRY")
  gfx.hud_row("round trip", string.format("%.0f ms", rtt),
    rtt > 300 and gfx.PALETTE.bad or rtt > 120 and gfx.PALETTE.warn or gfx.PALETTE.good)
  local dx, dy = px - me.x, py - me.y
  gfx.hud_row("echo trails you by",
    string.format("%.1f units", math.sqrt(dx * dx + dy * dy)), gfx.PALETTE.text)
  gfx.hud_chips("pending inputs (unacked)", lane.recon:pending_count())

  gfx.hud_section("CONTROLS")
  gfx.hud_key("WASD", self.user_drove and "drive (autopilot off)" or "take over from the autopilot")
  gfx.hud_key("L", "injected latency")
  gfx.hud_note("Render-only split: both lanes are the same entity in the same " ..
    "room, running lab 03's netcode verbatim.")
end

function Lab:unmount() self.lane:dispose() end

function Lab:on_reconnect()
  self.lane:rebind()
  self.top_trail, self.bot_trail = {}, {}
end

return Lab
