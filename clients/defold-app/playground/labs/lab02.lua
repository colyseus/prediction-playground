--
-- Lab 02 — Clocks & Timelines.
--
-- There is no clock "API call" to make: the moment the server declares
-- defineInput(), every input round-trip carries a TIMED prefix and the SDK
-- maintains room.clock. This lab just reads it — now / server_now / render_now /
-- rtt / smoothed_rtt / jitter / last_server_time.
--
-- Port of src/client/labs/02-clocks/.
--
local sim = require 'playground.sim'
local app = require 'playground.app'

local kb = app.kb
local STRIP_SPAN_MS = 3000

local Lab = {
  id = "02-clocks",
  num = 2,
  title = "Clocks & Timelines",
  blurb = "server_now / render_now / RTT / jitter.",
  room_name = "lab-bots",
}
Lab.__index = Lab

function Lab.new()
  return setmetatable({ arrivals = {}, last_patch_stamp = 0 }, Lab)
end

function Lab:ready(room)
  return room.state.bots ~= nil and room.state.bots["bot1"] ~= nil
end

function Lab:mount(context, room)
  self.room = room
  self.sid = room.session_id
  self.bot = room.state.bots["bot1"]
  if self.bot == nil then return false end
  -- Inputs feed the clock: one send per fixed tick = one RTT/offset sample.
  self.input = room:input()
  self.cmd = self.input.data
  self.pacer = app.Pacer.new(1000.0 / sim.TICK_HZ)
  return true
end

function Lab:frame(context, now, dt_ms)
  local steps = self.pacer:steps(now)
  for _ = 1, steps do
    self.cmd.moveX = kb.move_x()
    self.cmd.moveY = kb.move_y()
    self.input:send()
  end

  -- A patch arrival = the server stamp changing.
  local stamp = self.room.clock:last_server_time()
  if stamp ~= self.last_patch_stamp then
    self.last_patch_stamp = stamp
    table.insert(self.arrivals, now)
    if #self.arrivals > 128 then table.remove(self.arrivals, 1) end
  end
end

function Lab:render(gfx)
  local clock = self.room.clock

  self.room.state.players:each(function(p, key)
    gfx.square(p.x, p.y, sim.PLAYER_HALF, gfx.hue(p.hue, key == self.sid and 0.9 or 0.4))
  end)

  gfx.circle_outline(self.bot.x, self.bot.y, sim.BOT_RADIUS, gfx.PALETTE.text, true)
  gfx.label(self.bot.x, self.bot.y, "raw snapshots (patch rate)",
    gfx.a(gfx.PALETTE.text, 0.6), 10, -18)

  gfx.hud_section("TELEMETRY")
  gfx.hud_row("rtt", string.format("%.0f ms", clock:rtt()), gfx.PALETTE.blue)
  gfx.hud_row("smoothed rtt", string.format("%.0f ms", clock:smoothed_rtt()), gfx.PALETTE.text)
  gfx.hud_row("patch age (sawtooth)",
    string.format("%.0f ms", math.max(0, clock:server_now() - clock:last_server_time())),
    gfx.PALETTE.good)
  gfx.hud_row("|server_now - render_now| (slew)",
    string.format("%.1f ms", math.abs(clock:server_now() - clock:render_now())), gfx.PALETTE.warn)
  gfx.hud_row("server_now", string.format("%.0f ms", clock:server_now()), gfx.PALETTE.text)
  gfx.hud_row("render_now (slewed)", string.format("%.0f ms", clock:render_now()), gfx.PALETTE.text)
  gfx.hud_row("jitter (interarrival)", string.format("%.1f ms", clock:jitter()), gfx.PALETTE.text)
  gfx.hud_row("patch interval", string.format("%.0f ms", clock:patch_interval()), gfx.PALETTE.text)
  gfx.hud_row("patch arrivals buffered", tostring(#self.arrivals), gfx.PALETTE.text)

  gfx.hud_section("CONTROLS")
  gfx.hud_key("WASD", "drive")
  gfx.hud_note("Nothing to configure here — yank the latency preset with L and " ..
    "watch every readout respond. The offset re-converges; the slew spike decays " ..
    "over ~250 ms.")
end

function Lab:unmount() self.arrivals = {} end

function Lab:on_reconnect()
  self.pacer:reset()
  self.arrivals = {}
  self.last_patch_stamp = 0
  self.bot = self.room.state.bots["bot1"]
end

return Lab
