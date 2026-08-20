--
-- Lab 03 — Predict & Reconcile.
--
-- The reconciler OBSERVES the input handle: every send() is predicted locally
-- the same instant and buffered. When the server's next patch acks input N, it
-- rewinds to the authoritative state and REPLAYS inputs N+1.. through the same
-- shared step_entity — so the predicted pose stays consistent with everything
-- the server hasn't seen.
--
-- Port of src/client/labs/03-reconcile/.
--
local sim = require 'playground.sim'
local app = require 'playground.app'
local MoveLane = require 'playground.move_lane'
local drift = require 'colyseus.predict.drift'

local kb = app.kb

local Lab = {
  id = "03-reconcile",
  num = 3,
  title = "Predict & Reconcile",
  blurb = "Rollback to the ack, replay pending inputs, smooth the error.",
  room_name = "lab-move",
}
Lab.__index = Lab

function Lab.new()
  return setmetatable({
    lane = MoveLane.new(),
    render_smoothed = true,
    show_ghost = true,
  }, Lab)
end

function Lab:ready(room) return MoveLane.ready(room) end

function Lab:mount(context, room)
  self.room = room
  return self.lane:attach(room)
end

function Lab:frame(context, now, dt_ms)
  local lane = self.lane
  if kb.key("i") then self.room:send("impulse") end
  if kb.key("t") then self.room:send("teleport") end
  if kb.key("v") then self.render_smoothed = not self.render_smoothed end
  if kb.key("g") then self.show_ghost = not self.show_ghost end
  if kb.key("n") then lane.auto_snap = not lane.auto_snap end
  local step = kb.key("equals") and 10 or kb.key("minus") and -10 or 0
  if step ~= 0 then
    lane:build(math.max(0, math.min(200, lane.smooth_ms + step)))
  end

  lane:drive(now, kb.move_x(), kb.move_y())
end

function Lab:render(gfx)
  local lane = self.lane
  local me = lane.me

  self.room.state.players:each(function(p, key)
    if key == lane.sid then return end
    gfx.square(lane:remote_x(p), lane:remote_y(p), sim.PLAYER_HALF, gfx.hue(p.hue, 0.45))
  end)

  -- Server ghost: the raw authoritative pose — it trails by ~RTT.
  if self.show_ghost then
    gfx.ghost_square(me.x, me.y, sim.PLAYER_HALF, gfx.a(gfx.PALETTE.text, 0.75))
    gfx.label(me.x, me.y, "server", gfx.a(gfx.PALETTE.text, 0.55), 11, 14)
  end

  local px = self.render_smoothed and lane:x() or lane.recon.state.x
  local py = self.render_smoothed and lane:y() or lane.recon.state.y
  gfx.square(px, py, sim.PLAYER_HALF, gfx.hue(me.hue))
  gfx.square_outline(px, py, sim.PLAYER_HALF, gfx.PALETTE.text, 1)
  gfx.label(px, py, "you (predicted)", gfx.PALETTE.text, 11, -18)

  local recon = lane.recon
  local status = drift.classify(recon.drift, 0)
  gfx.hud_section("TELEMETRY")
  gfx.hud_chips("pending inputs (unacked)", recon:pending_count())
  gfx.hud_row("drift status", status,
    status == "matched" and gfx.PALETTE.good
      or status == "jitter" and gfx.PALETTE.warn
      or gfx.PALETTE.bad)
  gfx.hud_row("drift ema", string.format("%.4f", recon.drift.ema), gfx.PALETTE.accent)
  gfx.hud_row("last correction", string.format("%.3f", recon.last_correction_mag), gfx.PALETTE.text)
  gfx.hud_row("corrections seen", tostring(lane.corrections), gfx.PALETTE.text)
  gfx.hud_row("reconciles", tostring(recon.reconcile_seq), gfx.PALETTE.text)

  gfx.hud_section("CONTROLS")
  gfx.hud_key("WASD", "drive")
  gfx.hud_key("I", "force mispredict (impulse)")
  gfx.hud_key("T", "teleport")
  gfx.hud_key("- / =", string.format("smoothing %.0f ms", lane.smooth_ms))
  gfx.hud_key("V", self.render_smoothed and "render: value() smoothed" or "render: state (exact)")
  gfx.hud_key("G", self.show_ghost and "server ghost: on" or "server ghost: off")
  gfx.hud_key("N", lane.auto_snap and "snap on teleport: on" or "snap on teleport: off")
  gfx.hud_note("Corrections beyond 8u call reset() — a cut, not a cross-arena " ..
    "glide. Turn it off with N and teleport to see why.")
end

function Lab:unmount() self.lane:dispose() end
function Lab:on_reconnect() self.lane:rebind() end

return Lab
