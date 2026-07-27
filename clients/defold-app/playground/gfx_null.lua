--
-- The `gfx` contract, and the headless implementation of it.
--
-- Labs draw ONLY through this table. That is the whole reason the acceptance
-- harness can run the real lab modules under plain luajit: swap this in for the
-- Defold backend and every draw call becomes a no-op, while the netcode — which
-- is what the harness is actually testing — runs untouched.
--
-- World coordinates are the shared 100x60 arena; the backend letterboxes.
-- Colours are {r, g, b, a} in 0..1.
--
local M = {}

M.PALETTE = {
  bg        = { 0.039, 0.059, 0.102, 1 },
  panel     = { 0.055, 0.086, 0.149, 1 },
  text      = { 0.847, 0.886, 0.941, 1 },
  text_dim  = { 0.541, 0.627, 0.753, 1 },
  text_faint= { 0.369, 0.443, 0.588, 1 },
  accent    = { 1.000, 0.827, 0.420, 1 },
  good      = { 0.482, 0.878, 0.541, 1 },
  warn      = { 1.000, 0.706, 0.329, 1 },
  bad       = { 1.000, 0.400, 0.533, 1 },
  blue      = { 0.427, 0.702, 1.000, 1 },
}

--- Player colour from the server hue byte — hsl(hue/256*360, 72%, 62%).
function M.hue(hue, alpha)
  local h, s, l = (hue / 256 * 360) % 360, 0.72, 0.62
  local c = (1 - math.abs(2 * l - 1)) * s
  local hp = h / 60
  local x = c * (1 - math.abs(hp % 2 - 1))
  local r, g, b = 0, 0, 0
  if hp < 1 then r, g = c, x
  elseif hp < 2 then r, g = x, c
  elseif hp < 3 then g, b = c, x
  elseif hp < 4 then g, b = x, c
  elseif hp < 5 then r, b = x, c
  else r, b = c, x end
  local m = l - c / 2
  return { r + m, g + m, b + m, alpha or 1 }
end

--- Same colour, different alpha.
function M.a(color, alpha)
  return { color[1], color[2], color[3], alpha }
end

-- --------------------------------------------------------- the contract --
--
-- Every one of these is a no-op here and drawn for real by gfx_defold.lua.

--- Filled square, centred on (x, y), `half` world units to a side.
function M.square(_x, _y, _half, _color) end

--- Outlined square; `width` in pixels.
function M.square_outline(_x, _y, _half, _color, _width) end

--- Dashed-outline square — the standard raw-server-pose ghost.
function M.ghost_square(_x, _y, _half, _color) end

function M.circle(_x, _y, _r, _color) end
function M.circle_outline(_x, _y, _r, _color, _dashed) end

--- Segment between two WORLD points.
function M.line(_x0, _y0, _x1, _y1, _color, _width) end
function M.dashed(_x0, _y0, _x1, _y1, _color, _width) end

--- Text anchored at a world point, offset `dy` pixels.
function M.label(_x, _y, _text, _color, _size, _dy) end

--- The arena grid and border. The shell draws this unless the lab owns it.
function M.arena() end

--- Split-screen: subsequent world draws land in lane 1 (top) or 2 (bottom);
--- nil restores the full stage. Only the hero lab uses this, and it exists so
--- that lab never has to learn the backend's pixel geometry.
function M.lane(_index) end

--- A title inside the current lane's arena.
function M.lane_title(_main, _sub, _color) end

--- A centred line under the stage — the divider readout and the hero's caption.
function M.caption(_text, _color, _size) end

--- A filled+outlined world rectangle: the goal zone, and anything like it.
function M.zone(_x, _y, _w, _h, _fill, _stroke) end

-- ------------------------------------------------------------------ hud --

function M.hud_begin() end
function M.hud_section(_title) end
function M.hud_row(_label, _value, _color) end
function M.hud_key(_key, _what) end
function M.hud_note(_text) end
function M.hud_chips(_label, _n, _max) end

return M
