--
-- The playground's shared simulation, ported to Lua.
--
-- Bit-exact double transliteration of the src/shared TypeScript: same op order,
-- same constants. Lua numbers ARE doubles, so this port can hold the server's
-- f64 all the way through — like the C one, unlike C#'s float32 schema fields.
--
-- The RNG is the exception: it is uint32 integer math, so it goes through the
-- `bit` library rather than arithmetic. That is the module that breaks silently
-- if a shift or a wrap is wrong, which is why the canary at the bottom pins it.
--
local bit = require 'bit'

local M = {}

M.TICK_HZ = 20
M.ARENA_W = 100.0
M.ARENA_H = 60.0
M.PLAYER_HALF = 1.6
M.PLAYER_ACCEL = 220.0
M.PLAYER_MAX_SPEED = 34.0
M.PLAYER_FRICTION_K = 0.72
M.BOT_RADIUS = 1.8
M.REMOTE_INTERP_MS = 100.0
M.TELEPORT_SNAP_DIST = 8.0
M.MAX_REWIND_MS = 500.0

-- Math.SQRT1_2 — the exact double the JS sim multiplies by.
M.SQRT1_2 = 0.70710678118654752440

local sqrt, abs, min, floor = math.sqrt, math.abs, math.min, math.floor
local cos, sin, fmod = math.cos, math.sin, math.fmod

-- ------------------------------------------------- shared/movement.ts

--- The single deterministic movement step, run identically by the server (once
--- per received input) and by the reconciler (predict + rollback replay).
--- sqrt/mul/add only — no exp, no trig.
--- @param e table with x, y, vx, vy (mutated in place)
function M.step_entity(e, move_x, move_y, dt)
  local ax, ay = move_x, move_y
  if ax ~= 0 and ay ~= 0 then
    ax = ax * M.SQRT1_2
    ay = ay * M.SQRT1_2
  end

  if ax ~= 0 or ay ~= 0 then
    e.vx = e.vx + ax * M.PLAYER_ACCEL * dt
    e.vy = e.vy + ay * M.PLAYER_ACCEL * dt
  else
    e.vx = e.vx * M.PLAYER_FRICTION_K
    e.vy = e.vy * M.PLAYER_FRICTION_K
    if e.vx > -0.05 and e.vx < 0.05 then e.vx = 0 end
    if e.vy > -0.05 and e.vy < 0.05 then e.vy = 0 end
  end

  local sq = e.vx * e.vx + e.vy * e.vy
  if sq > M.PLAYER_MAX_SPEED * M.PLAYER_MAX_SPEED then
    local s = M.PLAYER_MAX_SPEED / sqrt(sq)
    e.vx = e.vx * s
    e.vy = e.vy * s
  end

  e.x = e.x + e.vx * dt
  e.y = e.y + e.vy * dt

  local min_x, max_x = M.PLAYER_HALF, M.ARENA_W - M.PLAYER_HALF
  local min_y, max_y = M.PLAYER_HALF, M.ARENA_H - M.PLAYER_HALF
  if e.x < min_x then e.x = min_x; if e.vx < 0 then e.vx = 0 end
  elseif e.x > max_x then e.x = max_x; if e.vx > 0 then e.vx = 0 end end
  if e.y < min_y then e.y = min_y; if e.vy < 0 then e.vy = 0 end
  elseif e.y > max_y then e.y = max_y; if e.vy > 0 then e.vy = 0 end end
end

-- ----------------------------------------------------- shared/goal.ts

M.GOAL_ZONE_X = M.ARENA_W - 8.0
M.GOAL_ZONE_Y = M.ARENA_H / 2.0 - 9.0
M.GOAL_ZONE_W = 8.0
M.GOAL_ZONE_H = 18.0
M.SCORE_COOLDOWN_TICKS = 50

--- The scoring gate. A pure function of predicted state, so it is deterministic
--- under rollback replay: true on the entry EDGE, the step that crossed into the
--- zone with the gate open. Whether the goal is AWARDED stays server-only.
--- @return boolean scored, number next_ticks
function M.step_score_gate(x, y, score_ticks)
  if score_ticks > 0 then return false, score_ticks - 1 end
  if x >= M.GOAL_ZONE_X and y >= M.GOAL_ZONE_Y and y <= M.GOAL_ZONE_Y + M.GOAL_ZONE_H then
    return true, M.SCORE_COOLDOWN_TICKS
  end
  return false, score_ticks
end

-- ----------------------------------------------- shared/projectile.ts

M.PROJECTILE_SPEED = 34.0
M.PROJECTILE_RADIUS = 0.7
M.PROJECTILE_TTL_MS = 2600.0

--- Constant-velocity flight with wall bounces.
function M.step_projectile(p, dt)
  p.x = p.x + p.vx * dt
  p.y = p.y + p.vy * dt
  if p.x < 0 then p.x = 0; p.vx = abs(p.vx)
  elseif p.x > M.ARENA_W then p.x = M.ARENA_W; p.vx = -abs(p.vx) end
  if p.y < 0 then p.y = 0; p.vy = abs(p.vy)
  elseif p.y > M.ARENA_H then p.y = M.ARENA_H; p.vy = -abs(p.vy) end
end

-- --------------------------------------------------- shared/movers.ts

M.TELEPORT_PERIOD_MS = 3000.0
M.WANDER_TURN_MS = 900.0

--- Horizontal ping-pong between min_x and max_x at |vx| = speed.
local function patrol(b, dt)
  b.x = b.x + b.vx * dt
  b.y = b.base_y
  if b.x < b.min_x then b.x = b.min_x; b.vx = abs(b.vx)
  elseif b.x > b.max_x then b.x = b.max_x; b.vx = -abs(b.vx) end
end

--- Run by the server each fixed tick AND by the client's reckon mode to
--- forward-simulate from the latest snapshot to the present. `elapsed_ms` is the
--- shared server-clock timeline, which is what makes time-sampled motion (the
--- circle's closed form, the teleport schedule) evaluable at ANY instant.
---
--- "wander" is deliberately only PARTLY predictable: it integrates velocity, but
--- the heading changes are a server-side secret, so reckon extrapolates straight
--- through every turn and gets corrected. That error is the lesson, not a bug.
function M.step_bot(b, dt, elapsed_ms)
  if b.kind == "circle" then
    local cx = (b.min_x + b.max_x) / 2
    local rx = (b.max_x - b.min_x) / 2
    local ry = min(12.0, M.ARENA_H / 2 - M.BOT_RADIUS - 2)
    local w = b.speed / rx                      -- rad/s
    local t = (elapsed_ms + b.phase_ms) / 1000.0
    b.x = cx + rx * cos(w * t)
    b.y = b.base_y + ry * sin(w * t)
    b.vx = -rx * w * sin(w * t)
    b.vy = ry * w * cos(w * t)
    return
  end

  if b.kind == "teleport" then
    patrol(b, dt)
    -- Predict the warp from the synced schedule: jump half the patrol span
    -- (wrapping) every period — a constant, always-visible cut.
    while b.last_teleport > 0 and elapsed_ms - b.last_teleport >= M.TELEPORT_PERIOD_MS do
      local span = b.max_x - b.min_x
      b.x = b.min_x + fmod((b.x - b.min_x) + span / 2, span)
      b.last_teleport = b.last_teleport + M.TELEPORT_PERIOD_MS
    end
    return
  end

  if b.kind == "wander" then
    b.x = b.x + b.vx * dt
    b.y = b.y + b.vy * dt
    local lo, hi_x, hi_y = M.BOT_RADIUS, M.ARENA_W - M.BOT_RADIUS, M.ARENA_H - M.BOT_RADIUS
    if b.x < lo then b.x = lo; b.vx = abs(b.vx)
    elseif b.x > hi_x then b.x = hi_x; b.vx = -abs(b.vx) end
    if b.y < lo then b.y = lo; b.vy = abs(b.vy)
    elseif b.y > hi_y then b.y = hi_y; b.vy = -abs(b.vy) end
    return
  end

  patrol(b, dt)
end

-- -------------------------------------------------- shared/hitscan.ts

--- 2D hitscan: ray vs circle. Returns the ray parameter t (distance along the
--- unit direction) of the nearest intersection, or -1 on a miss. Pure math,
--- shared so the client's shot preview and the server's resolution cannot drift.
function M.ray_circle(ox, oy, dx, dy, cx, cy, r, max_dist)
  local mx, my = ox - cx, oy - cy
  local b = mx * dx + my * dy
  local c = mx * mx + my * my - r * r
  if c > 0 and b > 0 then return -1 end          -- outside, pointing away
  local disc = b * b - c
  if disc < 0 then return -1 end
  local t = -b - sqrt(disc)
  local hit = t < 0 and 0 or t                   -- inside the circle = t 0
  return hit <= max_dist and hit or -1
end

-- ----------------------------------------------------- shared/bump.ts

M.BUMP_COOLDOWN_TICKS = 12
M.BUMP_SPEED = 48.0

--- Cooldown countdown — run BEFORE the movement step on both sides.
function M.step_bump_gate(bump_ticks)
  if bump_ticks > 0 then return bump_ticks - 1 end
  return bump_ticks
end

--- Player-vs-bot bump test at an agreed bot position. Returns the knockback
--- velocity, or nil. The CALLER applies it and re-arms bump_ticks — on the
--- client that happens inside the reconciler step, so the whole outcome
--- (velocity + immunity window) rides adopt+replay.
function M.collide_bot(px, py, bump_ticks, bot_x, bot_y)
  if bump_ticks > 0 then return nil end
  local dx, dy = px - bot_x, py - bot_y
  local r = M.PLAYER_HALF + M.BOT_RADIUS
  local d2 = dx * dx + dy * dy
  if d2 >= r * r then return nil end
  local d = sqrt(d2)
  if d == 0 then d = 1e-6 end
  return dx / d * M.BUMP_SPEED, dy / d * M.BUMP_SPEED
end

-- --------------------------------------------------- shared/random.ts

local band, bxor, brshift, blshift = bit.band, bit.bxor, bit.rshift, bit.lshift
local bor, tobit = bit.bor, bit.tobit

-- bit.rshift is a LOGICAL shift on the 32-bit pattern, which is exactly JS's
-- `>>> `; `bit.tobit` is `| 0`. Results come back SIGNED, so anything that
-- escapes to arithmetic goes through u32() first.
local function u32(v) return v % 4294967296 end

-- Math.imul, which LuaJIT has no equivalent of. `tobit(a * b)` is NOT it: both
-- operands reach 2^32, so the product reaches 2^64 and the double has already
-- lost the low bits by the time it is truncated. Splitting `a` into 16-bit
-- halves keeps every partial product under 2^48, where a double is still exact.
local function imul(a, b)
  local al = band(a, 0xffff)
  local ah = brshift(a, 16)
  return tobit(blshift(tobit(ah * b), 16) + tobit(al * b))
end

--- splitmix32 — one-shot avalanche of a 32-bit seed into a well-mixed word.
function M.splitmix32(a)
  a = tobit(a + 0x9e3779b9)
  local t = bxor(a, brshift(a, 16))
  t = imul(t, 0x21f0aaad)
  t = bxor(t, brshift(t, 15))
  t = imul(t, 0x735a2d97)
  return u32(bxor(t, brshift(t, 15)))
end

--- mulberry32 — the tiny seeded PRNG both sides roll. Returns a stateful
--- closure so a stream is a value you can hold and advance.
function M.mulberry32(seed)
  local a = tobit(seed)
  return function()
    a = tobit(a + 0x6d2b79f5)
    local t = imul(bxor(a, brshift(a, 15)), bor(1, a))
    t = bxor(tobit(t + imul(bxor(t, brshift(t, 7)), bor(61, t))), t)
    return u32(bxor(t, brshift(t, 14))) / 4294967296.0
  end
end

--- Per-shot seed from the input sequence + a synced per-round salt.
function M.shot_seed(seq, salt)
  return M.splitmix32(bxor(tobit(seq), imul(tobit(salt), 0x85ebca6b)))
end

-- --------------------------------------------------- shared/spread.ts

M.PELLETS = 6
M.SPREAD_RAD = 0.38

--- The shotgun fan — the SAME derivation on both sides, with nothing random on
--- the wire: the seed is (input seq, synced per-room salt), so client and server
--- roll identical pellets for the same shot.
function M.spread_angles(base_angle, seq, salt, out)
  out = out or {}
  local rng = M.mulberry32(M.shot_seed(seq, salt))
  for i = 1, M.PELLETS do
    out[i] = base_angle + (rng() - 0.5) * M.SPREAD_RAD
  end
  return out
end

-- --------------------------------------------------- shared/hockey.ts

M.PADDLE_RADIUS = 2.2
M.PUCK_RADIUS = 1.4
M.PUCK_FRICTION_K = 0.985
M.PUCK_RESTITUTION = 0.92
M.PUCK_PUSH_MIN = 14.0

--- Puck free flight: bleed speed, integrate, bounce off the walls.
function M.step_puck(p, dt)
  p.vx = p.vx * M.PUCK_FRICTION_K
  p.vy = p.vy * M.PUCK_FRICTION_K
  p.x = p.x + p.vx * dt
  p.y = p.y + p.vy * dt
  local lo, hi_x, hi_y = M.PUCK_RADIUS, M.ARENA_W - M.PUCK_RADIUS, M.ARENA_H - M.PUCK_RADIUS
  if p.x < lo then p.x = lo; p.vx = abs(p.vx) * M.PUCK_RESTITUTION
  elseif p.x > hi_x then p.x = hi_x; p.vx = -abs(p.vx) * M.PUCK_RESTITUTION end
  if p.y < lo then p.y = lo; p.vy = abs(p.vy) * M.PUCK_RESTITUTION
  elseif p.y > hi_y then p.y = hi_y; p.vy = -abs(p.vy) * M.PUCK_RESTITUTION end
end

--- Paddle-puck contact: push the puck out of penetration along the contact
--- normal and give it the paddle's velocity plus a minimum separation speed.
--- Deterministic (sqrt/mul/add only) and ORDER-DEPENDENT — both sides must
--- resolve paddles in the same order, which is the players-map iteration order.
function M.collide_paddle_puck(paddle_x, paddle_y, paddle_vx, paddle_vy, puck)
  local dx, dy = puck.x - paddle_x, puck.y - paddle_y
  local r = M.PADDLE_RADIUS + M.PUCK_RADIUS
  local d2 = dx * dx + dy * dy
  if d2 >= r * r then return false end
  local d = sqrt(d2)
  if d == 0 then d = 1e-6 end
  local nx, ny = dx / d, dy / d
  puck.x = paddle_x + nx * r
  puck.y = paddle_y + ny * r
  local along = paddle_vx * nx + paddle_vy * ny
  local speed = along > M.PUCK_PUSH_MIN and along or M.PUCK_PUSH_MIN
  puck.vx = nx * speed + paddle_vx * 0.35
  puck.vy = ny * speed + paddle_vy * 0.35
  return true
end

--- Session id of the server-driven AI paddle in lab-hockey.
M.BOT_ID = "bot"

--- The AI paddle's steering, quantized to the same -1/0/1 move input a human
--- sends. A server-owned DECISION but a pure function of synced state — the
--- puck it chases and `botEnabled` — so a predicting client derives it exactly:
--- the bot is remote but NOT unpredictable. Port of shared/hockey.ts
--- `botInput`. Returns moveX, moveY.
function M.bot_input(bot_x, bot_y, puck_x, puck_y, enabled)
  local chase = enabled and puck_y < M.ARENA_H / 2
  local tx = chase and puck_x or M.ARENA_W / 2
  local ty = chase and puck_y or M.ARENA_H * 0.2
  local mx = tx - bot_x > 1 and 1 or tx - bot_x < -1 and -1 or 0
  local my = ty - bot_y > 1 and 1 or ty - bot_y < -1 and -1 or 0
  return mx, my
end

-- ------------------------------------------------------ startup canary

--- Cheap check that the port still reproduces the reference numbers (pinned from
--- running the TypeScript original). Returns the number of FAILED checks.
function M.selfcheck(log)
  local failed = 0
  local dt = 1.0 / M.TICK_HZ
  local function check(ok, line)
    if log then log(line) end
    if not ok then failed = failed + 1 end
  end

  local e = { x = 50, y = 30, vx = 0, vy = 0 }
  for _ = 1, 5 do M.step_entity(e, 1, 0, dt) end
  check(abs(e.x - 56.7) < 1e-12 and e.vx == M.PLAYER_MAX_SPEED,
    string.format("  sim: 5x right  -> x=%.15f vx=%.15f (want 56.7 / 34)", e.x, e.vx))

  local d = { x = 50, y = 30, vx = 0, vy = 0 }
  M.step_entity(d, 1, 1, dt)
  check(d.vx == d.vy and abs(d.vx - 7.77817459305202341113) < 1e-15,
    string.format("  sim: diagonal  -> vx=%.15f vy=%.15f", d.vx, d.vy))

  local w = { x = M.PLAYER_HALF + 0.1, y = 30, vx = -30, vy = 0 }
  M.step_entity(w, 0, 0, dt)
  check(abs(w.x - M.PLAYER_HALF) < 1e-12 and w.vx == 0,
    string.format("  sim: wall      -> x=%.15f vx=%.15f", w.x, w.vx))

  local f = { x = 50, y = 30, vx = 0.06, vy = 0 }
  M.step_entity(f, 0, 0, dt)
  check(f.vx == 0, string.format("  sim: friction  -> vx=%.15f (want exactly 0)", f.vx))

  local c = { x = 50, y = 18, vx = 18, vy = 0, kind = "circle",
              min_x = 22, max_x = 78, base_y = 18, phase_ms = 0, speed = 18, last_teleport = 0 }
  M.step_bot(c, dt, 1234)
  check(abs(c.x - 69.6422100736938887167) < 1e-12 and abs(c.y - 26.5519448209259039118) < 1e-12,
    string.format("  sim: circle    -> x=%.15f y=%.15f", c.x, c.y))

  local tp = { x = 70, y = 18, vx = 18, vy = 0, kind = "teleport",
               min_x = 22, max_x = 78, base_y = 18, phase_ms = 0, speed = 18, last_teleport = 1000 }
  M.step_bot(tp, dt, 7100)
  check(abs(tp.x - 70.9) < 1e-12 and tp.last_teleport == 7000,
    string.format("  sim: teleport  -> x=%.15f lastTeleport=%.0f", tp.x, tp.last_teleport))

  local pj = { x = 99, y = 30, vx = 34, vy = 0 }
  M.step_projectile(pj, dt)
  check(pj.x == M.ARENA_W and pj.vx == -34.0,
    string.format("  sim: bounce    -> x=%.15f vx=%.15f", pj.x, pj.vx))

  local rng = M.mulberry32(0xB07B07)
  local r0, r1, r2 = rng(), rng(), rng()
  check(abs(r0 - 0.00975770130753517150879) < 1e-18
    and abs(r1 - 0.220020313980057835579) < 1e-15
    and abs(r2 - 0.457878412213176488876) < 1e-15
    and M.splitmix32(1) == 1580013426
    and M.shot_seed(7, 12345) == 1994071465,
    string.format("  sim: mulberry  -> %.17f %.17f %.17f / splitmix32(1)=%d shotSeed=%d",
      r0, r1, r2, M.splitmix32(1), M.shot_seed(7, 12345)))

  local fan = M.spread_angles(0.5, 7, 12345)
  check(abs(fan[1] - 0.599485442587174510720) < 1e-15
    and abs(fan[2] - 0.672593814930878552971) < 1e-15,
    string.format("  sim: spread    -> %.17f %.17f", fan[1], fan[2]))

  -- A seed that EXCEEDS 2^31. Both vectors above stay under it, so between them
  -- they only exercise the half of the input space where a 32-bit seed still
  -- fits a signed int — the Haxe port shipped a collapse in the other half and
  -- this canary passed anyway. shot_seed(50, 3004265928) is 2712337003, and the
  -- room salts the server rolls are uniform over the full u32 range, so half of
  -- all real shots land here.
  local wide = M.spread_angles(0.5, 50, 3004265928)
  check(M.shot_seed(50, 3004265928) == 2712337003
    and abs(wide[1] - 0.558667531493119873254) < 1e-15
    and abs(wide[6] - 0.613833207678981085387) < 1e-15,
    string.format("  sim: wide seed -> shotSeed=%d %.17f %.17f",
      M.shot_seed(50, 3004265928), wide[1], wide[6]))

  local t_hit = M.ray_circle(0, 0, 1, 0, 10, 0, 2, 100)
  local t_miss = M.ray_circle(0, 0, 1, 0, 10, 5, 2, 100)
  check(t_hit == 8.0 and t_miss == -1,
    string.format("  sim: hitscan   -> hit t=%.15f miss t=%.0f", t_hit, t_miss))

  local pk = { x = 50, y = 30, vx = 20, vy = 0 }
  M.step_puck(pk, dt)
  check(abs(pk.x - 50.985) < 1e-12 and abs(pk.vx - 19.7) < 1e-12,
    string.format("  sim: puck      -> x=%.15f vx=%.15f", pk.x, pk.vx))

  local contact = { x = 52, y = 30, vx = 0, vy = 0 }
  local touched = M.collide_paddle_puck(50, 30, 10, 0, contact)
  check(touched and abs(contact.x - 53.6) < 1e-12 and contact.vx == 17.5,
    string.format("  sim: contact   -> hit=%s x=%.15f vx=%.15f",
      tostring(touched), contact.x, contact.vx))

  local first, ticks = M.step_score_gate(M.GOAL_ZONE_X + 1, M.ARENA_H / 2, 0)
  local second, ticks2 = M.step_score_gate(M.GOAL_ZONE_X + 1, M.ARENA_H / 2, ticks)
  check(first and not second and ticks2 == M.SCORE_COOLDOWN_TICKS - 1,
    string.format("  sim: goal gate -> edge=%s repeat=%s ticks=%d",
      tostring(first), tostring(second), ticks2))

  local bvx, bvy = M.collide_bot(50, 30, 0, 51, 30)
  local immune = M.collide_bot(50, 30, 1, 51, 30)
  check(bvx == -M.BUMP_SPEED and bvy == 0 and immune == nil,
    string.format("  sim: bump      -> vx=%s vy=%s immune=%s",
      tostring(bvx), tostring(bvy), tostring(immune)))

  return failed
end

return M
