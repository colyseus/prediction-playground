--
-- Lab 09 — Predicted Spawns.
--
-- Click-to-fire feels instant because the client spawns an OPTIMISTIC local
-- projectile the same frame; when the server's authoritative entity arrives
-- (~RTT later) the store CORRELATES the two into one logical entry — same id,
-- same sprite, no visual seam.
--
--   owned       which server entities are mine to correlate (owner == me).
--               Foreign ones (the turret's) surface as server-only entries.
--   spawn_time  measures each shot's exact input lead (bornMs - predicted_at),
--               so MY projectile keeps flying the shooter's timeline through the
--               handoff instead of snapping back by lead x velocity.
--   step        the SAME shared flight function the server integrates.
--
-- Port of src/client/labs/09-predicted-spawns/.
--
local sim = require 'playground.sim'
local app = require 'playground.app'
local Predict = require 'colyseus.predict.predict'

local kb = app.kb

local Lab = {
  id = "09-predicted-spawns",
  num = 9,
  title = "Predicted Spawns",
  blurb = "Optimistic projectile -> authoritative handoff.",
  room_name = "lab-projectile",
}
Lab.__index = Lab

function Lab.new()
  return setmetatable({
    aim_x = 50, aim_y = 20,
    pending_fire = false,
    optimistic = true,
    fired = 0,
    last_lead_ms = nil,
    slots = {},                       -- entry id -> { was_pending, flash_t, x, y }
    pending = 0, confirmed = 0, foreign = 0,
    max_handoff_jump = 0,
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

  self.predict = Predict.get(room)
  self.predict:attach_all("players", { x = "damped", y = "damped" })

  self.spawns = self.predict:spawns("projectiles", {
    owned = function(p) return p.owner == self.sid end,
    spawn_time = function(p) return p.bornMs end,
    step = function(l, dt) sim.step_projectile(l, dt) end,
    fields = { "x", "y" },            -- also reckon the CONFIRMED entities
  })

  self.input = room:input()
  self.cmd = self.input.data
  self:build()
  return true
end

function Lab:build()
  self.recon = self.predict:reconciler(self.me, {
    input = self.input,
    fields = { "x", "y", "vx", "vy" },
    smooth_ms = 65,
    step = function(ctx, p, inp) sim.step_entity(p, inp.moveX, inp.moveY, ctx.dt) end,
  })
end

function Lab:aim_at(x, y) self.aim_x, self.aim_y = x, y end
function Lab:fire() self.pending_fire = true end

--- Spawn the optimistic local at the PREDICTED pose — the same origin the server
--- will use once this input arrives.
function Lab:fire_optimistic()
  local px, py = self.recon.state.x, self.recon.state.y
  local dx, dy = self.aim_x - px, self.aim_y - py
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1e-9 then len = 1 end
  self.spawns:spawn({
    x = px, y = py,
    vx = dx / len * sim.PROJECTILE_SPEED,
    vy = dy / len * sim.PROJECTILE_SPEED,
  })
end

--- Fold the store's entries into presentation state: which are pending, which
--- just crossed the handoff, and what lead the crossing measured. This lives in
--- frame(), not render() — a headless run has the same numbers.
function Lab:sweep(now)
  self.pending, self.confirmed, self.foreign = 0, 0, 0
  local live = {}
  for _, e in ipairs(self.spawns:entries()) do
    live[e.id] = true
    local slot = self.slots[e.id] or { was_pending = false, flash_t = -1e9 }
    local x, y = self.spawns:value(e, "x"), self.spawns:value(e, "y")
    if not e.confirmed then
      if e.local_state ~= nil then
        self.pending = self.pending + 1
        slot.was_pending = true
      end
    else
      self.confirmed = self.confirmed + 1
      if e.server ~= nil and e.server.owner ~= self.sid then
        self.foreign = self.foreign + 1
      end
      if slot.was_pending then
        slot.was_pending = false
        slot.flash_t = now
        if (e.lead_ms or 0) > 0 then self.last_lead_ms = e.lead_ms end
        -- How far the sprite TELEPORTED across the handoff. Un-reckoned, the
        -- confirmed entity renders at the last decoded snapshot — (age + lead)
        -- x speed behind the prediction, which is the visible snap-back.
        if slot.x ~= nil and x ~= nil then
          local d = math.sqrt((x - slot.x) ^ 2 + (y - slot.y) ^ 2)
          if d > self.max_handoff_jump then self.max_handoff_jump = d end
        end
      end
    end
    slot.x, slot.y = x, y
    self.slots[e.id] = slot
  end
  for id in pairs(self.slots) do
    if not live[id] then self.slots[id] = nil end
  end
end

function Lab:frame(context, now, dt_ms)
  if kb.key("space") then self.pending_fire = true end
  if kb.key("o") then self.optimistic = not self.optimistic end

  local steps = self.predict:tick(now)
  for _ = 1, steps do
    self.cmd.moveX = kb.move_x()
    self.cmd.moveY = kb.move_y()
    self.cmd.aimX = self.aim_x
    self.cmd.aimY = self.aim_y
    self.cmd.fire = self.pending_fire
    self.input:send()
    if self.pending_fire then
      self.fired = self.fired + 1
      if self.optimistic then self:fire_optimistic() end
      self.pending_fire = false
    end
  end

  self:sweep(now)
end

function Lab:render(gfx)
  local now = app.now_ms()

  gfx.square(50, 8, 2, gfx.a(gfx.PALETTE.bad, 0.3))
  gfx.square_outline(50, 8, 2, gfx.PALETTE.bad, 1.5)
  gfx.label(50, 8, "turret (foreign shots)", gfx.PALETTE.bad, 10, -16)

  self.room.state.players:each(function(p, key)
    if key ~= self.sid then
      gfx.square(self.predict:value(p, "x"), self.predict:value(p, "y"),
        sim.PLAYER_HALF, gfx.hue(p.hue, 0.4))
    end
  end)

  local mx, my = self.recon:value("x"), self.recon:value("y")
  gfx.square(mx, my, sim.PLAYER_HALF, gfx.hue(self.me.hue))
  gfx.square_outline(mx, my, sim.PLAYER_HALF, gfx.PALETTE.text, 1)
  gfx.circle_outline(self.aim_x, self.aim_y, 0.8, gfx.a(gfx.PALETTE.text, 0.6))

  -- One render path across the handoff, keyed on the stable entry id: :value()
  -- reads the stepped local while pending and the lead-aware reckon once
  -- confirmed, so the same two lines cover both sides of the seam.
  for _, e in ipairs(self.spawns:entries()) do
    local x, y = self.spawns:value(e, "x"), self.spawns:value(e, "y")
    -- Plain guard, no goto: the Defold editor validates against Lua 5.1
    -- grammar, where goto/labels don't exist (LuaJIT-only would pass the
    -- headless gate and still fail the editor build).
    if x ~= nil and y ~= nil then
      if not e.confirmed then
        gfx.circle(x, y, sim.PROJECTILE_RADIUS, gfx.a(gfx.PALETTE.warn, 0.9))
      else
        local slot = self.slots[e.id]
        local flashing = slot ~= nil and (now - slot.flash_t) < 350
        gfx.circle(x, y, sim.PROJECTILE_RADIUS * (flashing and 1.8 or 1.0),
          e.server.owner == self.sid and gfx.a(gfx.PALETTE.text, 0.95)
            or gfx.a(gfx.PALETTE.bad, 0.9))
      end
    end
  end

  gfx.hud_section("TELEMETRY")
  gfx.hud_row("pending (mine, unconfirmed)", tostring(self.pending),
    self.pending > 0 and gfx.PALETTE.warn or gfx.PALETTE.text)
  gfx.hud_row("confirmed entities", tostring(self.confirmed), gfx.PALETTE.text)
  gfx.hud_row("of those, foreign", tostring(self.foreign), gfx.PALETTE.text)
  gfx.hud_row("last measured input lead",
    self.last_lead_ms and string.format("%.0f ms", self.last_lead_ms) or "--",
    self.last_lead_ms and gfx.PALETTE.good or gfx.PALETTE.text_faint)
  gfx.hud_row("shots fired", tostring(self.fired), gfx.PALETTE.text)

  gfx.hud_section("CONTROLS")
  gfx.hud_key("WASD", "drive")
  gfx.hud_key("mouse", "aim")
  gfx.hud_key("click / SPACE", "fire")
  gfx.hud_key("O", self.optimistic and "optimistic spawn: on" or "optimistic spawn: OFF")
  gfx.hud_note("Amber = predicted local (pending) — white = confirmed " ..
    "(correlated) — red = foreign (the turret's; nobody predicted them). Turn " ..
    "optimistic off with O and your own shot only appears when the server's " ..
    "entity arrives, ~RTT late.")
end

function Lab:unmount() self.predict:dispose() end

function Lab:on_reconnect()
  self.me = self.room.state.players[self.sid]
  if self.me == nil then return end
  self.spawns:clear()
  self.slots = {}
  self:build()
end

return Lab
