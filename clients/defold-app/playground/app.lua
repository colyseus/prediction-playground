--
-- Shell contract + the services every lab shares.
--
-- Port of src/client/framework/lab.ts + input.ts + pacer.ts. The shell owns the
-- room and hands it to the lab; labs never join and never leave.
--
-- A lab touches NO Defold API. It draws through the `gfx` table the shell hands
-- it, which is what lets the same lab module run under the engine and under
-- plain luajit in the acceptance harness — the Lua answer to the Unity client's
-- Draw/Hud split.
--
local net_delay = require 'playground.net_delay'

local M = {}

-- ------------------------------------------------------------- keyboard --

--- WASD / arrows -> tri-state axes, exactly like framework/input.ts.
--- The acceptance harness feeds the SAME accessors, so a lab never learns
--- whether a human or a script is playing.
local kb = {
  autopilot = false,
  auto_x = 0,
  auto_y = 0,
  _down = {},        -- held keys, filled by the shell each frame
  _pressed = {},     -- key edges this frame, filled by the shell
  _synth = nil,      -- one-shot key edge from the harness
}
M.kb = kb

--- One-shot key edge, real or synthesized. Labs use this, never a raw poll.
function kb.key(name)
  if kb._synth == name then kb._synth = nil; return true end
  return kb._pressed and kb._pressed[name] or false
end

function kb.move_x()
  if kb.autopilot then return kb.auto_x end
  local l = kb._down.a or kb._down.left
  local r = kb._down.d or kb._down.right
  if r == l then return 0 end
  return r and 1 or -1
end

function kb.move_y()
  if kb.autopilot then return kb.auto_y end
  local u = kb._down.w or kb._down.up
  local d = kb._down.s or kb._down.down
  if d == u then return 0 end
  return d and 1 or -1
end

function kb.any_move() return kb.move_x() ~= 0 or kb.move_y() ~= 0 end

-- ---------------------------------------------------------------- pacer --

--- Fixed-step accumulator for labs WITHOUT a reconciler: predict:tick() only
--- paces once a reconciler adopts the fixed step, but a prediction-free client
--- still has to send one input per server tick.
local Pacer = {}
Pacer.__index = Pacer
M.Pacer = Pacer

function Pacer.new(step_ms)
  return setmetatable({ acc = 0, last = 0, step_ms = step_ms, started = false }, Pacer)
end

function Pacer:reset() self.acc = 0; self.started = false end

function Pacer:steps(now)
  if not self.started then
    self.started = true
    self.last = now
    return 0
  end
  self.acc = self.acc + (now - self.last)
  self.last = now
  local n = math.floor(self.acc / self.step_ms)
  if n > 5 then                       -- hitch: drop the backlog
    n, self.acc = 5, 0
  else
    self.acc = self.acc - n * self.step_ms
  end
  return n
end

-- ----------------------------------------------------------------- join --

--- Multiple clients land in the SAME room by default (multiplayer is free);
--- `private` forces a solo room, mirroring the web build's ?private=1.
---
--- `ready(room)` is what the caller needs decoded before it can wire up — the
--- web build's `waitFor`. Waiting on `room.state` alone is not enough on every
--- SDK, and asking each lab to name what it needs keeps the failure legible.
---
--- Returns a "pending" table the shell polls: { room, err, done }.
function M.join(app, name, ready)
  local pending = { done = false }
  local method = app.private and "create" or "join_or_create"

  app.client[method](app.client, name, {}, function(err, room)
    if err then
      pending.err = (err.message or tostring(err))
      pending.done = true
      return
    end
    pending.room = room
    pending.ready = ready
    -- In front of the room's own listeners, but only now that it has joined:
    -- the handshake rides an undelayed link, gameplay does not.
    net_delay.wrap(room, M.now_ms)
    -- reconnection builds a NEW connection: re-wrap it so the injected
    -- latency survives a drop (the preset globals persist across wraps)
    room:on("reconnect", function()
      net_delay.wrap(room, M.now_ms)
    end)
  end)

  return pending
end

--- Poll a pending join. Returns room once its state has decoded, nil while
--- waiting, and raises the recorded error if the join failed.
function M.poll_join(pending)
  if pending.err then error("join failed: " .. pending.err) end
  local room = pending.room
  if not room or not room.state then return nil end
  if pending.ready and not pending.ready(room) then return nil end
  pending.done = true
  return room
end

-- ------------------------------------------------------------ time base --

--- Set by the shell (engine: socket.gettime; harness: the FFI clock) so the
--- injector and the pacers share one monotonic millisecond timeline.
M.now_ms = function() return socket.gettime() * 1000 end

return M
