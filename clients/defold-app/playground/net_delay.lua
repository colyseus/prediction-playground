--
-- Latency injector (APPS_PLAN §3). The web playground gets delay/jitter from the
-- JS SDK's debug panel; on localhost every other SDK needs its own, or labs
-- 00/01/03 demonstrate nothing.
--
-- Lua has the cleanest seam of the four. `Connection` is an EventEmitter, so
-- replacing its `emit` puts us in front of EVERY listener at once — including
-- ones registered later. Subscribing instead would only run us alongside the
-- room's handler, which cannot delay anything. Outbound goes through `send`.
--
-- Two properties are load-bearing:
--
--  - No reordering: each packet's deliver-at is clamped to >= the previous
--    one's, because the wire is a stream and TCP never reorders (the JS debug
--    panel does the same).
--  - "open" is delayed with the rest. `Connection:_connect` flips `state` to
--    OPEN synchronously, so sends still reach our queue — but the room must not
--    learn it joined before the frames that arrived with it.
--
local M = {
  delay_ms = 0,
  jitter_ms = 0,
  _live = {},
  _seed = 0x5EED,
}

--- Named delay/jitter pairs — what the `L` key cycles through.
M.PRESETS = {
  { delay = 0,   jitter = 0,  label = "off" },
  { delay = 80,  jitter = 10, label = "80 ms + 10 jitter" },
  { delay = 200, jitter = 0,  label = "200 ms" },
  { delay = 200, jitter = 80, label = "200 ms + 80 jitter" },
  { delay = 400, jitter = 60, label = "400 ms + 60 jitter" },
}
M.preset_index = 1

function M.set_latency(delay_ms, jitter_ms)
  M.delay_ms = math.max(0, delay_ms or 0)
  M.jitter_ms = math.max(0, jitter_ms or 0)
end

function M.use_preset(index)
  M.preset_index = ((index - 1) % #M.PRESETS) + 1
  local p = M.PRESETS[M.preset_index]
  M.set_latency(p.delay, p.jitter)
end

function M.next_preset() M.use_preset(M.preset_index + 1) end
function M.preset_label() return M.PRESETS[M.preset_index].label end

--- Forget every socket and zero the latency — between acceptance cases.
function M.reset()
  M._live = {}
  M.delay_ms, M.jitter_ms = 0, 0
  M.preset_index = 1
end

-- A tiny LCG rather than math.random: the injector must not perturb (or be
-- perturbed by) whatever else in the process is drawing random numbers.
local function one_way()
  M._seed = (M._seed * 1103515245 + 12345) % 2147483648
  return M.delay_ms + (M._seed / 2147483648) * M.jitter_ms
end

local function enqueue(q, now, kind, payload)
  local at = now + one_way()
  if at < q.last then at = q.last end     -- the wire never reorders
  q.last = at
  q[#q + 1] = { at = at, kind = kind, payload = payload }
end

--- Wrap a room's connection. Call right after the room has joined, once its own
--- handlers are installed.
function M.wrap(room, now_ms)
  local conn = room.connection
  if not conn or conn._nd then return end

  -- reconnect built this room a NEW connection: wraps still pointing at the
  -- old one would replay their queues into the room's handlers — retire them
  for i = #M._live, 1, -1 do
    local stale = M._live[i]
    if stale.room == room and stale.conn ~= conn then table.remove(M._live, i) end
  end

  local w = {
    room = room,
    conn = conn,
    inbound = { last = 0 },
    outbound = { last = 0 },
    real_send = conn.send,
    real_emit = conn.emit,
  }
  conn._nd = w

  conn.send = function(_self, bytes)
    enqueue(w.outbound, now_ms(), "send", bytes)
  end

  local DELAYED = { message = true, close = true, error = true, open = true }
  conn.emit = function(self, event, ...)
    if not DELAYED[event] then return w.real_emit(self, event, ...) end
    enqueue(w.inbound, now_ms(), event, { n = select('#', ...), ... })
  end

  M._live[#M._live + 1] = w
  return w
end

local function drain(w, q, now)
  while #q > 0 and q[1].at <= now do
    local p = table.remove(q, 1)
    if p.kind == "send" then
      w.real_send(w.conn, p.payload)
    else
      w.real_emit(w.conn, p.kind, unpack(p.payload, 1, p.payload.n))
    end
  end
end

--- Drain everything due. Call once per frame, on the main loop.
function M.pump(now_ms)
  for i = 1, #M._live do
    local w = M._live[i]
    drain(w, w.outbound, now_ms)
    drain(w, w.inbound, now_ms)
  end
end

--- Kill every live socket uncleanly (close 4010, MAY_TRY_RECONNECT) — the
--- SDK sees a drop, not a leave, and its auto-reconnect takes over. The K key.
function M.drop()
  for i = 1, #M._live do
    local w = M._live[i]
    if w.conn.state ~= "CLOSED" then w.conn:close(4010) end
  end
end

function M.in_flight()
  local n = 0
  for i = 1, #M._live do
    n = n + #M._live[i].inbound + #M._live[i].outbound
  end
  return n
end

return M
