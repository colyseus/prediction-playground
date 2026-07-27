--
-- Lab 08 — Optimistic Events.
--
-- The GOAL banner fires the instant your PREDICTED square crosses the line, then
-- settles against the server:
--
--   predicted  ctx:predict() inside the reconciler step. Fires on the LIVE step
--              only; rollback replays never re-fire it.
--   confirmed  the server's "goal" broadcast -> channel:confirm().
--   rejected   no confirmation by the time the server processed past the
--              predicting input -> grace-tick auto-reject -> on_reject.
--
-- The zone gate itself is SHARED deterministic sim over a reconciled tick field:
-- whether you *entered* is never a misprediction — only the server's deny roll
-- can reject the event.
--
-- Port of src/client/labs/08-optimistic-events/.
--
local sim = require 'playground.sim'
local app = require 'playground.app'
local Predict = require 'colyseus.predict.predict'

local kb = app.kb

local Lab = {
  id = "08-optimistic-events",
  num = 8,
  title = "Optimistic Events",
  blurb = "Instant feedback; confirm or reject.",
  room_name = "lab-goal",
}
Lab.__index = Lab

function Lab.new()
  return setmetatable({
    records = {},          -- { predicted_at, settled_at, outcome } | outcome: 0/1/-1
    banner = nil, banner_color_key = "good", banner_t = -1e9,
    deny_rate = 0,
  }, Lab)
end

function Lab:ready(room)
  return room.state.players ~= nil and room.state.players[room.session_id] ~= nil
end

function Lab:mount(context, room)
  self.room = room
  self.sid = room.session_id
  self.me = room.state.players[self.sid]
  if self.me == nil then return false end
  self.deny_rate = room.state.denyRate or 0

  self.predict = Predict.for_room(room)
  self.predict:attach_all("players", { x = "damped", y = "damped" })

  self.goals = self.predict:define_event({
    on_predict = function()
      self:push(app.now_ms())
      self:flash("GOAL!", "good")
    end,
    on_confirm = function() self:settle(1) end,
    on_reject = function() self:settle(-1); self:flash("DENIED", "bad") end,
  })

  room:on_message("goal", function(message)
    if message.sid == self.sid then self.goals:confirm() end
  end)

  self.input = room:input()
  self.cmd = self.input.data
  self:build()
  return true
end

--- step_entity + the shared score gate, with the sim-born optimistic event.
function Lab:build()
  local goals = self.goals
  self.recon = self.predict:reconciler(self.me, {
    input = self.input,
    fields = { "x", "y", "vx", "vy", "scoreTicks" },
    smoothing = 15,
    step = function(ctx, p, inp)
      sim.step_entity(p, inp.moveX, inp.moveY, ctx.dt)
      -- Live-only: ctx:predict is a no-op during rollback replay.
      local scored, ticks = sim.step_score_gate(p.x, p.y, p.scoreTicks)
      p.scoreTicks = ticks
      if scored then ctx:predict(goals, "goal") end
    end,
  })
end

function Lab:flash(text, color_key)
  self.banner, self.banner_color_key, self.banner_t = text, color_key, app.now_ms()
end

function Lab:push(now)
  table.insert(self.records, { predicted_at = now, settled_at = 0, outcome = 0 })
  if #self.records > 30 then table.remove(self.records, 1) end
end

--- Settle the oldest still-pending record.
function Lab:settle(outcome)
  for _, r in ipairs(self.records) do
    if r.outcome == 0 then
      r.outcome = outcome
      r.settled_at = app.now_ms()
      return
    end
  end
end

function Lab:set_deny_rate(rate)
  self.deny_rate = math.max(0, math.min(100, rate))
  self.room:send("denyRate", { rate = self.deny_rate })
end

function Lab:counts()
  local confirmed, rejected, pending, settle_sum = 0, 0, 0, 0
  for _, r in ipairs(self.records) do
    if r.outcome == 1 then
      confirmed = confirmed + 1
      settle_sum = settle_sum + (r.settled_at - r.predicted_at)
    elseif r.outcome == -1 then rejected = rejected + 1
    else pending = pending + 1 end
  end
  return confirmed, rejected, pending, settle_sum
end

function Lab:frame(context, now, dt_ms)
  -- The deny rate is room-wide, like the web slider.
  local step = kb.key("equals") and 25 or kb.key("minus") and -25 or 0
  if step ~= 0 then self:set_deny_rate(self.deny_rate + step) end

  local steps = self.predict:tick(now)
  for _ = 1, steps do
    self.cmd.moveX = kb.move_x()
    self.cmd.moveY = kb.move_y()
    self.input:send()
  end
end

function Lab:render(gfx)
  gfx.zone(sim.GOAL_ZONE_X, sim.GOAL_ZONE_Y, sim.GOAL_ZONE_W, sim.GOAL_ZONE_H,
    gfx.a(gfx.PALETTE.good, 0.12), gfx.a(gfx.PALETTE.good, 0.5))
  gfx.label(sim.GOAL_ZONE_X + sim.GOAL_ZONE_W / 2, sim.GOAL_ZONE_Y, "GOAL",
    gfx.a(gfx.PALETTE.good, 0.7), 10, -14)

  self.room.state.players:each(function(p, key)
    if key ~= self.sid then
      gfx.square(self.predict:value(p, "x"), self.predict:value(p, "y"),
        sim.PLAYER_HALF, gfx.hue(p.hue, 0.4))
    end
  end)

  gfx.ghost_square(self.me.x, self.me.y, sim.PLAYER_HALF, gfx.a(gfx.PALETTE.text, 0.4))
  local px, py = self.recon:value("x"), self.recon:value("y")
  gfx.square(px, py, sim.PLAYER_HALF, gfx.hue(self.me.hue))
  gfx.square_outline(px, py, sim.PLAYER_HALF, gfx.PALETTE.text, 1)

  local age = app.now_ms() - self.banner_t
  if self.banner and age < 1400 then
    gfx.caption(self.banner, gfx.a(gfx.PALETTE[self.banner_color_key],
      math.min(1, 3 * (1 - age / 1400))), 42)
  end

  local confirmed, rejected, pending, settle_sum = self:counts()
  gfx.hud_section("TELEMETRY")
  gfx.hud_row("score (authoritative)", tostring(self.me.score), gfx.PALETTE.text)
  gfx.hud_row("events predicted", tostring(#self.records), gfx.PALETTE.text)
  gfx.hud_row("confirmed (avg settle)",
    confirmed > 0 and string.format("%d (%.0f ms)", confirmed, settle_sum / confirmed) or "0",
    confirmed > 0 and gfx.PALETTE.good or gfx.PALETTE.text_faint)
  gfx.hud_row("rejected", tostring(rejected),
    rejected > 0 and gfx.PALETTE.bad or gfx.PALETTE.text)
  gfx.hud_row("pending", tostring(pending),
    pending > 0 and gfx.PALETTE.warn or gfx.PALETTE.text)

  gfx.hud_section("RECENT EVENTS")
  for i = 1, 5 do
    local r = self.records[#self.records - i + 1]
    if r == nil then
      gfx.hud_row("event " .. i, "--", gfx.PALETTE.text_faint)
    elseif r.outcome == 0 then
      gfx.hud_row("event " .. i, "pending...", gfx.PALETTE.warn)
    else
      gfx.hud_row("event " .. i,
        string.format("%s +%.0f ms", r.outcome == 1 and "confirmed" or "rejected",
          r.settled_at - r.predicted_at),
        r.outcome == 1 and gfx.PALETTE.good or gfx.PALETTE.bad)
    end
  end

  gfx.hud_section("CONTROLS")
  gfx.hud_key("WASD", "run into the goal zone on the right")
  gfx.hud_key("- / =", string.format("server deny rate  %d %%", self.deny_rate))
  gfx.hud_note("The banner is optimistic — score is authoritative. Raise the " ..
    "deny rate and the banner goes up instantly, then retracts when the server " ..
    "stays silent.")
end

function Lab:unmount() self.predict:dispose() end

function Lab:on_reconnect()
  self.me = self.room.state.players[self.sid]
  if self.me == nil then return end
  self.goals:clear()
  self:build()
end

return Lab
