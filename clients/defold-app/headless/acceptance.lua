--
-- The Defold app's acceptance harness — the Lua twin of the native app's
-- `--demo` and the Unity client's PlayMode suite.
--
-- It runs the REAL lab modules: same mount, same frame(), same `kb` accessors a
-- human drives, with the null gfx backend swapped in so nothing needs a window.
-- That is the point of labs drawing only through `gfx` — the netcode under test
-- is byte-for-byte what the engine build runs.
--
-- Needs `pnpm dev --host 0.0.0.0` on :5173.
--
--   luajit headless/acceptance.lua [port]
--
package.path = table.concat({
  "./?.lua",
  "./?/init.lua",
  "../defold/?.lua",                              -- defold_shim, ffi_net
  "../../../../colyseus-defold/?.lua",            -- the SDK
  package.path,
}, ";")

local shim = require 'defold_shim'
local net = require 'ffi_net'
local Client = require 'colyseus.client'

local sim = require 'playground.sim'
local app = require 'playground.app'
local net_delay = require 'playground.net_delay'
local gfx = require 'playground.gfx_null'

local PORT = arg[1] or "5173"
local kb = app.kb

app.now_ms = function() return net.gettime() * 1000 end

-- ---------------------------------------------------------------- harness --

local failed = 0

local function check(name, ok, detail)
  print(string.format("%s %s%s", ok and "OK  " or "FAIL", name,
    detail and (" — " .. detail) or ""))
  if not ok then failed = failed + 1 end
end

--- Pump the injector + a lab for `ms`, exactly like the engine's update() does.
local function drive(lab, context, ms, auto_x, auto_y)
  kb.autopilot = true
  kb.auto_x, kb.auto_y = auto_x or 0, auto_y or 0
  local start = app.now_ms()
  local last = start
  while app.now_ms() - start < ms do
    shim.pump()
    net_delay.pump(app.now_ms())
    local now = app.now_ms()
    lab:frame(context, now, now - last)
    last = now
    net.sleep_ms(8)
  end
end

--- Join and wait for the lab's own readiness predicate. Fails loudly.
local function mount(lab, context, timeout_ms)
  local pending = app.join(context, lab.room_name, function(room) return lab:ready(room) end)
  local deadline = app.now_ms() + (timeout_ms or 15000)
  while app.now_ms() < deadline do
    shim.pump()
    net_delay.pump(app.now_ms())
    local room = app.poll_join(pending)
    if room then
      assert(lab:mount(context, room), lab.id .. ": mount refused the room")
      return room
    end
    net.sleep_ms(8)
  end
  error(lab.id .. ": never became ready (" .. net_delay.in_flight() .. " pkt in the injector)")
end

local function leave(lab, room)
  lab:unmount()
  room:leave()
  local deadline = app.now_ms() + 2000
  while app.now_ms() < deadline do
    shim.pump()
    net_delay.pump(app.now_ms())
    net.sleep_ms(8)
  end
end

-- ------------------------------------------------------------------ cases --

print("prediction playground — defold-app acceptance\n")

check("shared sim reproduces the reference numbers", sim.selfcheck() == 0)

local client = Client(string.format("ws://127.0.0.1:%s", PORT))
local context = { client = client, private = true }

do -- lab 01: with no prediction, input->motion IS the round trip
  local Lab01 = require 'playground.labs.lab01'
  local lab = Lab01.new()
  net_delay.reset()
  local room = mount(lab, context)

  drive(lab, context, 800)
  drive(lab, context, 1600, 1)
  local at_zero = lab.measured
  check("lab01 meter arms at 0 injected latency", at_zero > 0)
  check("lab01 input->motion is ~one patch interval at 0 injected",
    at_zero > 0 and at_zero < 250, string.format("%.0f ms", at_zero))

  drive(lab, context, 900)
  net_delay.set_latency(200, 0)
  drive(lab, context, 1200)
  drive(lab, context, 2000, -1)
  local at_200 = lab.measured
  check("lab01 input->motion tracks the round trip at 200 ms each way",
    at_200 > 300, string.format("%.0f ms (was %.0f ms)", at_200, at_zero))

  leave(lab, room)
end

print()
if failed == 0 then
  print("all checks passed")
else
  print(failed .. " check(s) FAILED")
end
os.exit(failed == 0 and 0 or 1)
