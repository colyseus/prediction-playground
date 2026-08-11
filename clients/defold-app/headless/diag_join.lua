--
-- Temporary: reproduce the editor's join path headlessly.
-- The acceptance harness always uses private=true (create); the editor shell
-- defaults to private=false (join_or_create), which no test covers.
--
--   luajit headless/diag_join.lua
--
package.path = table.concat({
  "./?.lua", "./?/init.lua", "../defold/?.lua",
  "../../../../colyseus-defold/?.lua", package.path,
}, ";")

local shim = require 'defold_shim'
local net = require 'ffi_net'
local Client = require 'colyseus.client'
local app = require 'playground.app'
app.now_ms = function() return net.gettime() * 1000 end

local client = Client("ws://127.0.0.1:5173")

for _, private in ipairs({ true, false }) do
  local label = private and "create (harness path)" or "join_or_create (EDITOR path)"
  local ctx = { client = client, private = private }
  local pending = app.join(ctx, "lab-move", function(room) return room.state ~= nil end)

  local deadline = app.now_ms() + 8000
  local room, err
  while app.now_ms() < deadline do
    shim.pump()
    local ok, r = pcall(app.poll_join, pending)
    if not ok then err = tostring(r); break end
    if r then room = r; break end
    net.sleep_ms(8)
  end

  print(string.format("%-32s -> %s", label,
    room and ("JOINED sid=" .. tostring(room.session_id)) or (err or "TIMEOUT")))
  if room then room:leave() end
  for _ = 1, 40 do shim.pump(); net.sleep_ms(8) end
end
