--
-- The reconciled `lab-move` lane: join, predict, reconcile, send.
--
-- Labs 00 and 03 are the SAME netcode behind different renderers — the split
-- screen is a render-layer choice over one entity in one room, not a second
-- protocol — so the lane lives here and neither lab owns it.
--
local sim = require 'playground.sim'
local app = require 'playground.app'
local Predict = require 'colyseus.predict.predict'

local kb = app.kb

local MoveLane = {}
MoveLane.__index = MoveLane

function MoveLane.new()
  return setmetatable({
    corrections = 0,
    max_correction_mag = 0,
    auto_snap = true,          -- Reset() on a teleport-class correction: a cut
    smooth_ms = 65,
    _last_reconcile_seq = 0,
  }, MoveLane)
end

--- What must be decoded before the lane can wire up.
function MoveLane.ready(room)
  return room.state.players ~= nil and room.state.players[room.session_id] ~= nil
end

function MoveLane:attach(room)
  self.room = room
  self.sid = room.session_id
  self.me = room.state.players[self.sid]     -- the raw authoritative pose
  if self.me == nil then return false end

  self.input = room:input()
  self.cmd = self.input.data
  self.predict = Predict.get(room)
  -- Remote squares: damped toward the latest snapshot. Their inputs are not
  -- ours to predict — lab 04 explores the modes.
  self.predict:attach_all("players", { x = "damped", y = "damped" })
  self:build(self.smooth_ms)
  return true
end

--- Rebuild the reconciler — smoothing is taken at construction.
function MoveLane:build(smooth_ms)
  self.smooth_ms = smooth_ms
  self.recon = self.predict:reconciler(self.me, {
    input = self.input,
    fields = { "x", "y", "vx", "vy" },
    smooth_ms = smooth_ms,
    -- The SAME function the server runs — determinism is the contract.
    step = function(ctx, s, inp)
      sim.step_entity(s, inp.moveX, inp.moveY, ctx.dt)
    end,
  })
  self._last_reconcile_seq = 0
end

--- One frame of netcode: advance the stack, send the inputs it says are due,
--- and fold in whatever the latest reconcile reported.
function MoveLane:drive(now, move_x, move_y)
  local steps = self.predict:tick(now)
  for _ = 1, steps do
    self.cmd.moveX = move_x
    self.cmd.moveY = move_y
    self.input:send()
  end

  if self.recon.reconcile_seq == self._last_reconcile_seq then return end
  self._last_reconcile_seq = self.recon.reconcile_seq
  local mag = self.recon.last_correction_mag
  if mag > 0.02 then
    self.corrections = self.corrections + 1
    if mag > self.max_correction_mag then self.max_correction_mag = mag end
  end
  if self.auto_snap and mag > sim.TELEPORT_SNAP_DIST then self.recon:reset() end
end

--- The predicted pose: what the local player should be looking at.
function MoveLane:x() return self.recon:value("x") end
function MoveLane:y() return self.recon:value("y") end

--- The predicted pose of a remote square (damped, not reconciled).
function MoveLane:remote_x(p) return self.predict:value(p, "x") end
function MoveLane:remote_y(p) return self.predict:value(p, "y") end

--- After a reconnect. The reconnected room counts inputs from ZERO, so a
--- reconciler carrying the pre-drop backlog would replay it on every reconcile
--- — rebind to the fresh entity and start the buffer over.
function MoveLane:rebind()
  local me = self.room.state.players[self.sid]
  if me ~= nil then self.me = me end
  self:build(self.smooth_ms)
end

function MoveLane:dispose()
  if self.predict ~= nil then self.predict:dispose() end
end

return MoveLane
