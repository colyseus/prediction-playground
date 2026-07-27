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
--- `on_frame(elapsed_ms)`, when given, runs after each frame — for checks that
--- need the shape of a run rather than one end-of-run reading.
local function drive(lab, context, ms, auto_x, auto_y, on_frame)
  kb.autopilot = true
  kb.auto_x, kb.auto_y = auto_x or 0, auto_y or 0
  local start = app.now_ms()
  local last = start
  while app.now_ms() - start < ms do
    shim.pump()
    net_delay.pump(app.now_ms())
    local now = app.now_ms()
    lab:frame(context, now, now - last)
    lab:render(gfx)          -- no-op visually, but it exercises the draw path
    last = now
    if on_frame ~= nil then on_frame(now - start) end
    net.sleep_ms(8)
  end
end

--- Median of a numeric list (sorts in place).
local function median(values)
  if #values == 0 then return -1 end
  table.sort(values)
  return values[math.ceil(#values / 2)]
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

do -- lab 02: every clock readout responds to the injected link
  local Lab02 = require 'playground.labs.lab02'
  local lab = Lab02.new()
  net_delay.reset()
  net_delay.set_latency(200, 0)
  local room = mount(lab, context)

  drive(lab, context, 4000, 1)
  local clock = room.clock
  check("lab02 smoothed rtt sees the injected latency", clock:smoothed_rtt() > 350,
    string.format("%.0f ms", clock:smoothed_rtt()))
  check("lab02 clock synced from the TIMED prefix", clock:last_server_time() > 0)
  check("lab02 patch cadence advertised", clock:patch_interval() > 0,
    string.format("%.0f ms", clock:patch_interval()))
  check("lab02 saw patch arrivals", #lab.arrivals > 10, #lab.arrivals .. " buffered")

  leave(lab, room)
end

do -- lab 00: the predicted lane leads the server echo by ~RTT
  local Lab00 = require 'playground.labs.lab00'
  local lab = Lab00.new()
  net_delay.reset()
  local room = mount(lab, context)   -- mount picks its own latency preset

  drive(lab, context, 6000)          -- its autopilot drives itself
  check("lab00 lanes separate under latency", lab.peak_gap > 2.0,
    string.format("peak %.2f u", lab.peak_gap))
  check("lab00 autopilot ran without a hand on the keyboard", not lab.user_drove)

  leave(lab, room)
end

do -- lab 05: reckon renders the present, and honours the bot's actual pattern
  local Lab05 = require 'playground.labs.lab05'
  local lab = Lab05.new()
  net_delay.reset()
  net_delay.set_latency(200, 0)
  local room = mount(lab, context)

  lab:set_pattern("patrol")
  drive(lab, context, 5000)
  check("lab05 reckon leads the lerp view", lab.peak_gap > 1.0,
    string.format("peak %.2f u", lab.peak_gap))

  -- The circle is the check that matters: it is the one pattern whose y moves.
  -- If the reckon step cannot see `kind` it falls through to patrol, which pins
  -- y to base_y — so a flat y here means the scratch lost the pattern.
  lab:set_pattern("circle")
  drive(lab, context, 2000)
  local min_y, max_y = 1e9, -1e9
  for _ = 1, 40 do
    drive(lab, context, 100)
    local ry = lab.reckon:value(lab.bot, "y")
    min_y, max_y = math.min(min_y, ry), math.max(max_y, ry)
  end
  check("lab05 reckon follows the circle pattern, not a patrol fallback",
    max_y - min_y > 4, string.format("y swept %.2f u", max_y - min_y))

  leave(lab, room)
end

do -- lab 03: predicted instantly, and a mispredict decays back to steady state
  local Lab03 = require 'playground.labs.lab03'
  local drift = require 'colyseus.predict.drift'
  local lab = Lab03.new()
  net_delay.reset()
  net_delay.set_latency(200, 0)
  local room = mount(lab, context)
  local recon = lab.lane.recon

  drive(lab, context, 4000, -1)
  -- Predicted while ~RTT worth of inputs are still unacked, and the shared step
  -- reproduces the server's math to wire precision (Lua numbers are f64, so
  -- unlike C# there is no schema rounding on the way down either).
  check("lab03 predicts with inputs still in flight", recon:pending_count() > 0,
    recon:pending_count() .. " unacked")
  check("lab03 client step agrees with the server's",
    drift.classify(recon.drift, 0.01) ~= "diverging",
    string.format("drift ema %.3e", recon.drift.ema))

  -- A server-side shove the client cannot see coming MUST mispredict...
  room:send("impulse")
  drive(lab, context, 1500)
  check("lab03 impulse produces a visible correction",
    lab.lane.max_correction_mag > 0.05,
    string.format("peak %.3f", lab.lane.max_correction_mag))

  -- ...and then decay back to steady state.
  drive(lab, context, 5000, 1)
  check("lab03 corrections converge again", recon.last_correction_mag < 0.05,
    string.format("settled to %.4f", recon.last_correction_mag))

  leave(lab, room)
end

do -- lab 08: the optimistic banner fires instantly, then settles
  local Lab08 = require 'playground.labs.lab08'
  local lab = Lab08.new()
  net_delay.reset()
  net_delay.set_latency(200, 0)
  local room = mount(lab, context)

  -- Deny nothing: every optimistic banner must be confirmed.
  lab:set_deny_rate(0)
  drive(lab, context, 600)
  drive(lab, context, 6000, 1)
  local confirmed, rejected = lab:counts()
  check("lab08 entered the goal zone and predicted", #lab.records > 0,
    #lab.records .. " predicted")
  check("lab08 optimistic goals get confirmed at a 0 % deny rate",
    confirmed > 0 and rejected == 0,
    confirmed .. " confirmed, " .. rejected .. " rejected")
  local clean_run = #lab.records

  -- Deny everything: the banner still fires instantly, then retracts.
  lab:set_deny_rate(100)
  drive(lab, context, 600)
  drive(lab, context, 9000, 1)
  local _, rejected2 = lab:counts()
  check("lab08 keeps predicting once the server starts denying",
    #lab.records > clean_run, #lab.records .. " total")
  check("lab08 grace-tick auto-reject retracts the unconfirmed banners",
    rejected2 > 0, rejected2 .. " rejected")

  leave(lab, room)
end

do -- lab 09: an optimistic spawn hands off to the authoritative entity
  local Lab09 = require 'playground.labs.lab09'
  local lab = Lab09.new()
  net_delay.reset()
  net_delay.set_latency(200, 0)
  local room = mount(lab, context)
  drive(lab, context, 800)

  lab:aim_at(50, 55)
  lab:fire()
  -- Immediately after firing there must be a local to look at — that IS the
  -- feature; a full RTT later it would be far too late.
  drive(lab, context, 150)
  check("lab09 spawns a local the same frame it fires", lab.pending > 0,
    lab.pending .. " pending")

  -- ...and by ~2 RTT the server's entity has arrived and correlated.
  drive(lab, context, 1600)
  check("lab09 the server's projectile correlates", lab.confirmed > 0,
    lab.confirmed .. " confirmed")
  check("lab09 measures the input lead (else the handoff would jump)",
    lab.last_lead_ms ~= nil and lab.last_lead_ms > 0,
    lab.last_lead_ms and string.format("%.0f ms", lab.last_lead_ms) or "never measured")

  leave(lab, room)
end

do -- lab 06: lag comp lands the shot where the shooter aimed
  local Lab06 = require 'playground.labs.lab06'
  local lab = Lab06.new()
  net_delay.reset()
  local room = mount(lab, context)     -- mount picks its own latency preset
  drive(lab, context, 1500)

  lab:set_lag_comp(true)
  drive(lab, context, 800)
  for _ = 1, 6 do
    lab:fire()
    drive(lab, context, 700)
  end
  check("lab06 the server reported the shots", lab.shots_on > 0,
    lab.shots_on .. " with comp on")
  check("lab06 lag comp hits what the shooter saw",
    lab.hits_on * 10 > lab.shots_on * 6,
    string.format("%d/%d hits", lab.hits_on, lab.shots_on))
  -- The assertion that catches an unbound render_delay: the rewound read has to
  -- coincide with our view, while the view itself lags well behind live.
  check("lab06 the rewound read coincides with our view",
    lab:rewind_error() >= 0 and lab:rewind_error() < 3.0,
    string.format("rewind error %.2f u, view lag %.1f u", lab:rewind_error(), lab:view_lag()))

  leave(lab, room)
end

do -- lab 07: a frozen verdict agrees with the server's
  local Lab07 = require 'playground.labs.lab07'
  local lab = Lab07.new()
  net_delay.reset()
  local room = mount(lab, context)     -- mount picks its own latency preset

  -- The autopilot seeks the bot's lane and lets the patrol sweep hit it.
  drive(lab, context, 14000, 1)
  check("lab07 bumped the bot at all", lab.bumps_predicted > 0,
    lab.bumps_predicted .. " predicted")
  -- The server's own counter is the only verdict that settles it: with
  -- value_at + memo the client's count must TRACK it, not merely be close.
  check("lab07 the client's verdict matches the server's",
    math.abs(lab.bumps_predicted - lab.me.bumps) <= 1,
    string.format("predicted %d, authoritative %d, mispredict rate %.0f %%",
      lab.bumps_predicted, lab.me.bumps, lab:mispredict_rate()))

  leave(lab, room)
end

do -- lab 11: client and server roll identical pellets from (seq, salt)
  local Lab11 = require 'playground.labs.lab11'
  local lab = Lab11.new()
  net_delay.reset()
  net_delay.set_latency(200, 0)
  local room = mount(lab, context)
  drive(lab, context, 1200)

  for _ = 1, 3 do
    lab:fire()
    drive(lab, context, 700)
  end
  check("lab11 the server reported a fan", lab:answered_fans() > 0,
    lab:answered_fans() .. " answered")
  check("lab11 seeded from (seq, salt), both sides derive the same fan",
    lab.max_divergence ~= nil and lab.max_divergence < 1e-6,
    string.format("divergence %.3e rad", lab.max_divergence or -1))

  -- Swap in an unshared RNG and the SAME comparison must fail — otherwise the
  -- check above proves nothing.
  lab.cheat = true
  for _ = 1, 3 do
    lab:fire()
    drive(lab, context, 700)
  end
  check("lab11 an unshared RNG visibly disagrees",
    lab.max_divergence ~= nil and lab.max_divergence > 1e-6,
    string.format("divergence %.3e rad", lab.max_divergence or -1))

  leave(lab, room)
end

do -- lab 10: the puck is predicted THROUGH our own inputs
  local Lab10 = require 'playground.labs.lab10'
  local lab = Lab10.new()
  net_delay.reset()
  local room = mount(lab, context)   -- mount picks its own latency preset

  -- The lab steers itself toward the puck under autopilot; a plain sweep never
  -- reaches it, and a puck nobody touches proves nothing.
  --
  -- Sample every reconcile as it happens, and how far the puck travels late in
  -- the run. Reading drift.ema once at the end measures the wrong thing twice
  -- over: it decays toward zero when the world stops moving, so a puck pinned
  -- against a wall scores BETTER than honest play.
  local mags, seq = {}, lab.sim.reconcile_seq
  local late_path, px, py = 0, nil, nil
  drive(lab, context, 12000, nil, nil, function(elapsed)
    if lab.sim.reconcile_seq ~= seq then
      seq = lab.sim.reconcile_seq
      table.insert(mags, lab.sim.last_correction_mag or 0)
    end
    local puck = lab.room.state.puck
    if elapsed > 9000 then
      if px ~= nil then
        late_path = late_path + math.sqrt((puck.x - px) ^ 2 + (puck.y - py) ^ 2)
      end
      px, py = puck.x, puck.y
    end
  end)

  check("lab10 predicts with inputs still in flight", lab.sim:pending_count() > 0,
    lab.sim:pending_count() .. " unacked")
  check("lab10 the predicted puck leads the authoritative one",
    lab.max_puck_lead > 0.5,
    string.format("peak %.2f u over %d touches", lab.max_puck_lead, lab.touches))

  -- The MEDIAN reconcile, not the worst or the last. Remote paddles enter the
  -- prediction at their last snapshot, so a contested touch mispredicts by
  -- design — lab 10 exists to show that. What must hold is that the shared step
  -- agrees the rest of the time: a typical reconcile costs nothing, and the
  -- spikes are a tail rather than a trend.
  --
  -- 0.5 is measured, not guessed: honest play lands at 0.0000-0.1527 across
  -- runs, and a client stepping the puck with the wrong friction constant
  -- (0.900 vs 0.985) lands at 1.7751. This catches GROSS divergence only — a
  -- 0.1 % constant slip reads 0.0593 and sails through. Bit-exactness is the
  -- startup canary's job (it fails that same slip on a pinned vector, with no
  -- dependence on how one 12-second rally happened to go).
  local mid = median(mags)
  check("lab10 the composite step agrees with the server's",
    mid >= 0 and mid < 0.5,
    string.format("median correction %.4f over %d reconciles", mid, #mags))

  -- Guards the check above: a frozen world agrees with itself perfectly.
  check("lab10 the puck is still live at the end",
    late_path > 5,
    string.format("%.1f u travelled in the last 3s", late_path))

  leave(lab, room)
end

print()
if failed == 0 then
  print("all checks passed")
else
  print(failed .. " check(s) FAILED")
end
os.exit(failed == 0 and 0 or 1)
