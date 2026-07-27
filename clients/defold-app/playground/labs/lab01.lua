--
-- Lab 01 — Feel the Lag.
--
-- No prediction at all: send one input per fixed server tick, render the player
-- straight from decoded state. Every key press waits a full round trip, so the
-- `L` latency presets are what make this lab say anything.
--
-- Port of src/client/labs/01-feel-the-lag/.
--
local sim = require 'playground.sim'
local app = require 'playground.app'

local kb = app.kb

local Lab = {
  id = "01-feel-the-lag",
  num = 1,
  title = "Feel the Lag",
  blurb = "No prediction: every key press waits a full round trip.",
  room_name = "lab-move",
}
Lab.__index = Lab

function Lab.new()
  return setmetatable({
    damped = false,
    damping = 12,
    smooth = {},
    phase = "idle",        -- idle | armed | shown
    arm_t = 0, arm_x = 0, arm_y = 0,
    measured = 0,
  }, Lab)
end

function Lab:ready(room)
  return room.state.players ~= nil and room.state.players[room.session_id] ~= nil
end

function Lab:mount(context, room)
  self.room = room
  self.sid = room.session_id
  self.input = room:input()
  self.cmd = self.input.data
  self.pacer = app.Pacer.new(1000.0 / sim.TICK_HZ)
  return true
end

function Lab:frame(context, now, dt_ms)
  if kb.key("r") then self.damped = not self.damped end
  if kb.key("minus") and self.damping > 4 then self.damping = self.damping - 2 end
  if kb.key("equals") and self.damping < 30 then self.damping = self.damping + 2 end

  -- One input per fixed server tick — no reconciler here, so a local
  -- accumulator paces the sends.
  local steps = self.pacer:steps(now)
  for _ = 1, steps do
    self.cmd.moveX = kb.move_x()
    self.cmd.moveY = kb.move_y()
    self.input:send()
  end

  local dt = math.min(0.1, dt_ms / 1000.0)
  local k = 1 - math.exp(-self.damping * dt)
  self.room.state.players:each(function(p, key)
    local s = self.smooth[key]
    if not s then s = { x = p.x, y = p.y }; self.smooth[key] = s end
    s.x = s.x + (p.x - s.x) * k
    s.y = s.y + (p.y - s.y) * k
  end)

  -- input->photon meter: arm on a key press while at rest, measure when the
  -- RENDERED position first moves.
  local me = self.room.state.players[self.sid]
  if me then
    local speed = math.abs(me.vx) + math.abs(me.vy)
    if self.phase ~= "armed" and kb.any_move() and speed < 0.01 then
      self.phase, self.arm_t, self.arm_x, self.arm_y = "armed", now, me.x, me.y
    elseif self.phase == "armed" then
      if math.abs(me.x - self.arm_x) > 0.03 or math.abs(me.y - self.arm_y) > 0.03 then
        self.measured = now - self.arm_t
        self.phase = "shown"
      elseif not kb.any_move() and now - self.arm_t > 2000 then
        self.phase = "idle"
      end
    elseif self.phase == "shown" and not kb.any_move() and speed < 0.01 then
      self.phase = "idle"
    end
  end
end

function Lab:render(gfx)
  self.room.state.players:each(function(p, key)
    local is_me = key == self.sid
    local x, y = p.x, p.y
    if self.damped and self.smooth[key] then
      x, y = self.smooth[key].x, self.smooth[key].y
    end
    gfx.square(x, y, sim.PLAYER_HALF, gfx.hue(p.hue, is_me and 1 or 0.45))
    if is_me then
      gfx.square_outline(x, y, sim.PLAYER_HALF, gfx.PALETTE.text, 1)
      gfx.label(x, y, "you", gfx.PALETTE.text, 11, -18)
    end
  end)

  gfx.hud_section("TELEMETRY")
  gfx.hud_row("input -> motion",
    self.measured > 0 and string.format("%.0f ms", self.measured) or "--",
    self.measured > 0 and gfx.PALETTE.bad or gfx.PALETTE.text_faint)
  gfx.hud_row("meter state", self.phase,
    self.phase == "armed" and gfx.PALETTE.warn
      or self.phase == "shown" and gfx.PALETTE.good
      or gfx.PALETTE.text_dim)
  gfx.hud_row("render strategy", self.damped and "damped" or "raw", gfx.PALETTE.text)
  gfx.hud_row("damping", string.format("%.0f /s", self.damping), gfx.PALETTE.text)

  gfx.hud_section("CONTROLS")
  gfx.hud_key("WASD", "drive")
  gfx.hud_key("R", "raw <-> damped")
  gfx.hud_key("- / =", "damping")
  gfx.hud_note("raw = decoded server state verbatim. damped = smooth toward it " ..
    "(even laggier). predicted = Lab 03. Raise the latency preset with L and " ..
    "feel the difference.")
end

function Lab:unmount() self.smooth = {} end

function Lab:on_reconnect()
  self.pacer:reset()
  self.phase = "idle"
end

return Lab
