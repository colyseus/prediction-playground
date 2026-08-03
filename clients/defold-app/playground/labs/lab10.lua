--
-- Lab 10 — Composite Sim (SimReconciler).
--
-- The flat reconciler (lab 03) mirrors fields of ONE instance. Here the puck is
-- a separate entity — yet your shots must feel instant, so the puck is predicted
-- THROUGH your own inputs: every predicted paddle step also steps the puck and
-- resolves the contact, in the server's exact order. On each ack both bound
-- mirrors are re-seeded from authoritative state and the unacked inputs replay
-- on top, so a predicted shot is re-derived from truth every reconcile.
--
-- Remote HUMAN paddles enter the prediction as COLLIDERS at their latest
-- snapshot — their next input is unknowable until it arrives — so a contested
-- touch is the honest misprediction to watch for. The AI paddle is different
-- and is predicted in full: its steering is a pure function of synced state
-- (`sim.bot_input`), so the client runs the server's own decision.
--
-- Port of src/client/labs/10-composite-sim/.
--
local sim = require 'playground.sim'
local app = require 'playground.app'
local net_delay = require 'playground.net_delay'
local Predict = require 'colyseus.predict.predict'

local kb = app.kb

-- Fixed steps the autopilot spends heading home after a strike (20 Hz -> ~0.6s).
local RETREAT_TICKS = 12

local Lab = {
  id = "10-composite-sim",
  num = 10,
  title = "Composite Sim",
  blurb = "One rollback over a world of parts: paddle and puck together.",
  room_name = "lab-hockey",
}
Lab.__index = Lab

function Lab.new()
  return setmetatable({
    smoothing = 15,
    show_ghosts = true,
    touches = 0,
    touched_last_step = false,
    retreat_ticks = 0,
    -- PEAK, not instantaneous: the lead is largest right after a strike and
    -- collapses between them, so a spot reading says nothing.
    max_puck_lead = 0,
    trail = {},
  }, Lab)
end

function Lab:ready(room)
  return room.state.players ~= nil and room.state.players[room.session_id] ~= nil
     and room.state.puck ~= nil and room.state.players[sim.BOT_ID] ~= nil
end

function Lab:mount(context, room)
  self.room = room
  self.sid = room.session_id
  self.me = room.state.players[self.sid]
  -- The DECODED instances, kept as the read handles. The sim swaps mirrors into
  -- the world table, but these stay the source — which is what the bound
  -- overlay keys on, so `predict:value(self.puck, "x")` resolves to the
  -- controller's pose without anyone naming "puck.x".
  self.puck = room.state.puck
  self.bot = room.state.players[sim.BOT_ID]
  if self.me == nil or self.puck == nil or self.bot == nil then return false end

  self.predict = Predict.for_room(room)
  -- Remote paddles: damped toward the latest snapshot. They enter the sim as
  -- colliders, not as predicted parts.
  self.predict:attach_all("players", { x = "damped", y = "damped" })

  self.input = room:input()
  self.cmd = self.input.data
  self:build()
  net_delay.use_preset(3)     -- a predicted shot says nothing on a 1 ms link
  return true
end

function Lab:build()
  local lab = self
  -- Dispose BEFORE respawning, like the reference: the old controller would
  -- otherwise keep ticking, and its bound overlay would fight the new one for
  -- the same (instance, field) slots.
  if self.sim ~= nil then self.sim:dispose() end
  self.sim = self.predict:sim({
    input = self.input,
    smoothing = self.smoothing,
    -- All three entries are decoded instances, so all are auto-bound and
    -- replaced in place by mirrors. The pose keys they derive stay internal:
    -- reads go through predict:value(instance, field).
    world = { paddle = self.me, puck = self.puck, bot = self.bot },
    step = function(ctx, w, inp) lab:step(ctx, w, inp) end,
  })
end

--- Switch the server's AI paddle on/off. The acceptance run turns it OFF so the
--- determinism check measures OUR step alone, independent of the bot-prediction
--- path (the bot is predicted now — see `step` — but off, the check cannot be
--- flattered or flustered by it). The interactive build keeps its AI.
function Lab:set_bot(on)
  self.room:send("bot", { on = on })
end

--- The server's step order, reproduced: paddles (mine AND the bot's) -> puck -> contacts.
function Lab:step(ctx, w, inp)
  local pad = { x = w.paddle.x, y = w.paddle.y, vx = w.paddle.vx, vy = w.paddle.vy }
  sim.step_entity(pad, inp.moveX, inp.moveY, ctx.dt)
  w.paddle.x, w.paddle.y, w.paddle.vx, w.paddle.vy = pad.x, pad.y, pad.vx, pad.vy

  -- The bot steps from the PRE-step puck, exactly as the server does — its
  -- paddle loop runs before step_puck.
  local bt = { x = w.bot.x, y = w.bot.y, vx = w.bot.vx, vy = w.bot.vy }
  local bmx, bmy = sim.bot_input(bt.x, bt.y, w.puck.x, w.puck.y, self.room.state.botEnabled)
  sim.step_entity(bt, bmx, bmy, ctx.dt)
  w.bot.x, w.bot.y, w.bot.vx, w.bot.vy = bt.x, bt.y, bt.vx, bt.vy

  local pk = { x = w.puck.x, y = w.puck.y, vx = w.puck.vx, vy = w.puck.vy }
  sim.step_puck(pk, ctx.dt)

  -- Contacts resolve in players-map iteration order — the server's order. Mine
  -- and the bot's come from the PREDICTED mirrors; remote HUMANS are zero-delta
  -- colliders at their last-known snapshot.
  local touched = false
  self.room.state.players:each(function(p, key)
    if key == self.sid then
      if sim.collide_paddle_puck(pad.x, pad.y, pad.vx, pad.vy, pk) then touched = true end
    elseif key == sim.BOT_ID then
      if sim.collide_paddle_puck(bt.x, bt.y, bt.vx, bt.vy, pk) then touched = true end
    else
      if sim.collide_paddle_puck(p.x, p.y, p.vx, p.vy, pk) then touched = true end
    end
  end)

  w.puck.x, w.puck.y, w.puck.vx, w.puck.vy = pk.x, pk.y, pk.vx, pk.vy
  if touched and not ctx.is_replay then self.touched_last_step = true end
end

--- Where the predicted puck is relative to the predicted paddle. A lab-10
--- autopilot that just sweeps never reaches the puck, and a puck nobody touches
--- makes the whole lab look broken while proving nothing.
---
--- Backs off to its own half for a beat after each strike. Chasing without
--- release pins the puck against a wall and holds it there: the contact
--- re-fires every tick (the wall-aware push-out keeps it inside the arena, but
--- nothing moves), so the whole world freezes with both sides in perfect
--- agreement.
function Lab:seek_puck()
  local tx = self.predict:value(self.puck, "x")
  local ty = self.predict:value(self.puck, "y")
  -- Counted down on the fixed-step loop, not here: seek_puck runs once per
  -- frame, which is several times faster than the tick and would burn the
  -- retreat off almost immediately.
  if self.retreat_ticks > 0 then
    tx, ty = sim.ARENA_W / 2, sim.ARENA_H * 0.75
  end
  local dx = tx - self.predict:value(self.me, "x")
  local dy = ty - self.predict:value(self.me, "y")
  local mx = dx > 0.4 and 1 or dx < -0.4 and -1 or 0
  local my = dy > 0.4 and 1 or dy < -0.4 and -1 or 0
  return mx, my
end

function Lab:frame(context, now, dt_ms)
  if kb.key("g") then self.show_ghosts = not self.show_ghosts end
  local step = kb.key("equals") and 5 or kb.key("minus") and -5 or 0
  if step ~= 0 then
    self.smoothing = math.max(0, math.min(40, self.smoothing + step))
    self:build()
  end

  local mx, my = kb.move_x(), kb.move_y()
  if kb.autopilot then mx, my = self:seek_puck() end

  local steps = self.predict:tick(now)
  for _ = 1, steps do
    self.cmd.moveX = mx
    self.cmd.moveY = my
    self.input:send()
    if self.retreat_ticks > 0 then self.retreat_ticks = self.retreat_ticks - 1 end
    if self.touched_last_step then
      self.touches = self.touches + 1
      self.touched_last_step = false
      self.retreat_ticks = RETREAT_TICKS
    end
  end

  local dx = self.predict:value(self.puck, "x") - self.room.state.puck.x
  local dy = self.predict:value(self.puck, "y") - self.room.state.puck.y
  local lead = math.sqrt(dx * dx + dy * dy)
  if lead > self.max_puck_lead then self.max_puck_lead = lead end

  table.insert(self.trail, { self.predict:value(self.puck, "x"), self.predict:value(self.puck, "y") })
  if #self.trail > 120 then table.remove(self.trail, 1) end
end

function Lab:render(gfx)
  local state = self.room.state

  state.players:each(function(p, key)
    if key == self.sid then return end
    local x, y = self.predict:value(p, "x"), self.predict:value(p, "y")
    gfx.circle(x, y, sim.PADDLE_RADIUS, gfx.hue(p.hue, 0.35))
    gfx.circle_outline(x, y, sim.PADDLE_RADIUS, gfx.hue(p.hue, 0.8))
  end)

  if self.show_ghosts then
    gfx.circle_outline(self.me.x, self.me.y, sim.PADDLE_RADIUS,
      gfx.a(gfx.PALETTE.text, 0.35), true)
    gfx.circle_outline(state.puck.x, state.puck.y, sim.PUCK_RADIUS,
      gfx.a(gfx.PALETTE.text, 0.45), true)
    gfx.label(state.puck.x, state.puck.y, "server puck",
      gfx.a(gfx.PALETTE.text, 0.45), 9, 14)
  end

  for i = 2, #self.trail do
    local a, b = self.trail[i - 1], self.trail[i]
    gfx.line(a[1], a[2], b[1], b[2],
      gfx.a(gfx.PALETTE.accent, 0.4 * i / #self.trail), 1.5)
  end

  local px, py = self.predict:value(self.me, "x"), self.predict:value(self.me, "y")
  gfx.circle(px, py, sim.PADDLE_RADIUS, gfx.hue(self.me.hue, 0.5))
  gfx.circle_outline(px, py, sim.PADDLE_RADIUS, gfx.PALETTE.text)
  gfx.label(px, py, "you (predicted)", gfx.PALETTE.text, 11, -16)

  local kx, ky = self.predict:value(self.puck, "x"), self.predict:value(self.puck, "y")
  gfx.circle(kx, ky, sim.PUCK_RADIUS, gfx.a(gfx.PALETTE.accent, 0.9))
  gfx.circle_outline(kx, ky, sim.PUCK_RADIUS, gfx.PALETTE.accent)
  gfx.label(kx, ky, "puck (predicted)", gfx.PALETTE.accent, 10, -14)

  gfx.hud_section("TELEMETRY")
  gfx.hud_chips("pending inputs (unacked)", self.sim:pending_count())
  gfx.hud_row("drift ema", string.format("%.6f", self.sim.drift.ema), gfx.PALETTE.accent)
  gfx.hud_row("puck lead (peak)", string.format("%.2f u", self.max_puck_lead), gfx.PALETTE.text)
  gfx.hud_row("last correction", string.format("%.3f", self.sim.last_correction_mag),
    gfx.PALETTE.text)
  gfx.hud_row("touches predicted", tostring(self.touches), gfx.PALETTE.text)

  gfx.hud_section("CONTROLS")
  gfx.hud_key("WASD", "drive your paddle into the puck")
  gfx.hud_key("- / =", string.format("smoothing %.0f /s", self.smoothing))
  gfx.hud_key("G", self.show_ghosts and "server ghosts: on" or "server ghosts: off")
  gfx.hud_note("One rollback over THREE parts. Your paddle, the puck AND the " ..
    "AI paddle are predicted together, in the server's order, so a strike is " ..
    "instant — and re-derived from truth on every ack. The AI is predictable " ..
    "because its steering is a pure function of synced state; remote HUMANS " ..
    "stay colliders at their last snapshot, so a contested human touch is the " ..
    "honest misprediction.")
end

function Lab:unmount() self.predict:dispose() end

function Lab:on_reconnect()
  self.me = self.room.state.players[self.sid]
  self.bot = self.room.state.players[sim.BOT_ID]
  if self.me == nil or self.bot == nil then return end
  self:build()
  self.trail = {}
end

return Lab
