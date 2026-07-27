--
-- The Defold implementation of the `gfx` contract (see gfx_null.lua).
--
-- Everything goes through the built-in render script's `draw_line` and
-- `draw_debug_text` messages, so this project needs no atlas, no material and no
-- game objects — which suits a vector playground and keeps the whole client
-- readable as Lua.
--
-- Two coordinate facts live here and nowhere else:
--   * the arena is 100x60 world units, letterboxed into the window;
--   * the arena's y points DOWN (it is a canvas port) while Defold's screen y
--     points UP, so this backend flips it.
-- A lab never learns either.
--
local sim = require 'playground.sim'

local M = {}

-- Palette and colour helpers are shared with the headless backend: they are
-- pure data, and a lab that picks colours differently per backend is a bug.
local null = require 'playground.gfx_null'
M.PALETTE, M.hue, M.a = null.PALETTE, null.hue, null.a

local view = { scale = 1, ox = 0, oy = 0, stage = {} }
local lane_rect = nil          -- set by M.lane(); nil = the full stage
local hud = { x = 0, y = 0, w = 300 }

local function v4(c) return vmath.vector4(c[1], c[2], c[3], c[4] or 1) end

--- Fit the arena into a rect. `flip` maps arena-y-down onto Defold's y-up.
local function fit(x, y, w, h, margin)
  margin = margin or 28
  local sx = (w - margin * 2) / sim.ARENA_W
  local sy = (h - margin * 2) / sim.ARENA_H
  view.scale = math.min(sx, sy)
  view.ox = x + (w - sim.ARENA_W * view.scale) / 2
  view.oy = y + (h + sim.ARENA_H * view.scale) / 2   -- top edge, in y-up space
end

--- Call once per frame before drawing; `stage` is the arena's screen rect.
function M.begin_frame(stage_x, stage_y, stage_w, stage_h, hud_x, hud_y, hud_w)
  view.stage = { x = stage_x, y = stage_y, w = stage_w, h = stage_h }
  lane_rect = nil
  fit(stage_x, stage_y, stage_w, stage_h)
  hud.x, hud.y, hud.w = hud_x, hud_y, hud_w
  hud.cursor = hud_y
end

local function sx(x) return view.ox + x * view.scale end
local function sy(y) return view.oy - y * view.scale end     -- the flip
local function s(len) return len * view.scale end

local function line(x0, y0, x1, y1, color)
  msg.post("@render:", "draw_line", {
    start_point = vmath.vector3(x0, y0, 0),
    end_point = vmath.vector3(x1, y1, 0),
    color = v4(color),
  })
end

local function text(x, y, str, color)
  msg.post("@render:", "draw_debug_text", {
    text = str,
    position = vmath.vector3(x, y, 0),
    color = v4(color),
  })
end

-- --------------------------------------------------------------- shapes --

--- Filled shapes are horizontal spans: draw_line is all the render script
--- offers, and at these sizes a dozen spans reads as solid.
local function fill_rect(x0, y0, x1, y1, color)
  local step = 2
  local top, bottom = math.max(y0, y1), math.min(y0, y1)
  local yy = bottom
  while yy <= top do
    line(x0, yy, x1, yy, color)
    yy = yy + step
  end
end

function M.square(x, y, half, color)
  local h = s(half)
  fill_rect(sx(x) - h, sy(y) - h, sx(x) + h, sy(y) + h, color)
end

function M.square_outline(x, y, half, color, width)
  local h = s(half)
  local l, r, b, t = sx(x) - h, sx(x) + h, sy(y) - h, sy(y) + h
  line(l, b, r, b, color); line(r, b, r, t, color)
  line(r, t, l, t, color); line(l, t, l, b, color)
end

function M.ghost_square(x, y, half, color)
  local h = s(half)
  local l, r, b, t = sx(x) - h, sx(x) + h, sy(y) - h, sy(y) + h
  local function dash(x0, y0, x1, y1)
    local n = 6
    for i = 0, n - 1, 2 do
      local a0, a1 = i / n, (i + 1) / n
      line(x0 + (x1 - x0) * a0, y0 + (y1 - y0) * a0,
           x0 + (x1 - x0) * a1, y0 + (y1 - y0) * a1, color)
    end
  end
  dash(l, b, r, b); dash(r, b, r, t); dash(r, t, l, t); dash(l, t, l, b)
end

function M.circle(x, y, r, color)
  local pr = s(r)
  local cx, cy = sx(x), sy(y)
  local seg = 14
  for i = 0, seg do
    local t = (i / seg) * 2 - 1
    local half = pr * math.sqrt(math.max(0, 1 - t * t))
    if half > 0 then line(cx - half, cy + t * pr, cx + half, cy + t * pr, color) end
  end
end

function M.circle_outline(x, y, r, color, dashed)
  local seg = 28
  local cx, cy, pr = sx(x), sy(y), s(r)
  local step = dashed and 2 or 1
  for i = 0, seg - 1, step do
    local a0 = i * 2 * math.pi / seg
    local a1 = (i + 1) * 2 * math.pi / seg
    line(cx + math.cos(a0) * pr, cy + math.sin(a0) * pr,
         cx + math.cos(a1) * pr, cy + math.sin(a1) * pr, color)
  end
end

function M.line(x0, y0, x1, y1, color, _width)
  line(sx(x0), sy(y0), sx(x1), sy(y1), color)
end

function M.dashed(x0, y0, x1, y1, color, _width)
  local px0, py0, px1, py1 = sx(x0), sy(y0), sx(x1), sy(y1)
  local n = 16
  for i = 0, n - 1, 2 do
    local a0, a1 = i / n, (i + 1) / n
    line(px0 + (px1 - px0) * a0, py0 + (py1 - py0) * a0,
         px0 + (px1 - px0) * a1, py0 + (py1 - py0) * a1, color)
  end
end

function M.label(x, y, str, color, _size, dy)
  -- dy is in canvas pixels (y-down), so it subtracts in Defold's y-up space.
  text(sx(x) - #str * 3, sy(y) - (dy or 0), str, color)
end

function M.zone(x, y, w, h, fill, stroke)
  fill_rect(sx(x), sy(y), sx(x + w), sy(y + h), fill)
  local l, r, t, b = sx(x), sx(x + w), sy(y), sy(y + h)
  line(l, t, r, t, stroke); line(r, t, r, b, stroke)
  line(r, b, l, b, stroke); line(l, b, l, t, stroke)
end

function M.arena()
  local grid = M.a(M.PALETTE.text_dim, 0.10)
  for x = 10, sim.ARENA_W - 1, 10 do
    line(sx(x), sy(0), sx(x), sy(sim.ARENA_H), grid)
  end
  for y = 10, sim.ARENA_H - 1, 10 do
    line(sx(0), sy(y), sx(sim.ARENA_W), sy(y), grid)
  end
  local border = M.a(M.PALETTE.text_dim, 0.38)
  line(sx(0), sy(0), sx(sim.ARENA_W), sy(0), border)
  line(sx(0), sy(sim.ARENA_H), sx(sim.ARENA_W), sy(sim.ARENA_H), border)
  line(sx(0), sy(0), sx(0), sy(sim.ARENA_H), border)
  line(sx(sim.ARENA_W), sy(0), sx(sim.ARENA_W), sy(sim.ARENA_H), border)
end

-- ----------------------------------------------------------- split view --

function M.lane(index)
  local st = view.stage
  if index == nil then
    fit(st.x, st.y, st.w, st.h)
    lane_rect = nil
    return
  end
  local lane_h = st.h / 2
  -- Lane 1 is the TOP one on screen, which is the HIGHER y in Defold's y-up.
  local y = index == 1 and (st.y + lane_h) or st.y
  lane_rect = { x = st.x, y = y, w = st.w, h = lane_h }
  fit(st.x, y, st.w, lane_h, 24)
end

function M.lane_title(main, sub, color)
  local r = lane_rect or view.stage
  text(r.x + 16, r.y + r.h - 14, main, color)
  text(r.x + 16 + #main * 7 + 14, r.y + r.h - 14, sub, M.a(M.PALETTE.text_dim, 0.75))
end

function M.caption(str, color, _size)
  local st = view.stage
  text(st.x + st.w / 2 - #str * 3, st.y + 16, str, color)
end

-- ------------------------------------------------------------------ hud --

local function hud_line(str, color)
  text(hud.x, hud.cursor, str, color)
  hud.cursor = hud.cursor - 14
end

function M.hud_begin() hud.cursor = hud.y end

function M.hud_section(title)
  hud.cursor = hud.cursor - 6
  hud_line(title, M.PALETTE.accent)
end

function M.hud_row(label, value, color)
  hud_line(string.format("%-28s %s", label, value), color or M.PALETTE.text)
end

function M.hud_key(key, what)
  hud_line(string.format("[%s] %s", key, what), M.PALETTE.text_dim)
end

function M.hud_note(str)
  -- Wrap by hand: draw_debug_text has no layout of its own.
  local width, line_text = 46, ""
  for word in str:gmatch("%S+") do
    if #line_text + #word + 1 > width then
      hud_line(line_text, M.PALETTE.text_faint)
      line_text = word
    else
      line_text = (#line_text == 0) and word or (line_text .. " " .. word)
    end
  end
  if #line_text > 0 then hud_line(line_text, M.PALETTE.text_faint) end
end

function M.hud_chips(label, n, max)
  local capped = math.min(n, max or 48)
  hud_line(string.format("%-28s %s %d", label, string.rep("|", capped), n), M.PALETTE.text)
end

return M
