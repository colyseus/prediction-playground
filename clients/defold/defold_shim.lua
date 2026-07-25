--
-- Headless Defold-API shim for running the colyseus-defold SDK under plain
-- luajit: provides the `websocket`, `http`, `timer`, `sys`, `json` and
-- `socket` globals the SDK touches — websocket is a pure-Lua RFC 6455 client
-- over the FFI TCP layer (ffi_net.lua).
--
-- Call `shim.pump()` from the frame loop: it polls every live websocket and
-- fires due timers. `shim.sleep_ms(n)` idles between frames.
--
local net = require 'ffi_net'
local bit = require 'bit'

local shim = { _sockets = {}, _timers = {}, _next_timer = 1 }

-- ---------------------------------------------------------------- socket --

-- the SDK only uses socket.gettime (RoomClock.get_now)
socket = { gettime = net.gettime }

-- ------------------------------------------------------------------- sys --

-- in-memory stand-ins for the save-file APIs storage.lua touches
local save_data = {}
sys = {
  get_sys_info = function() return { system_name = "Headless" } end,
  get_save_file = function(app, file) return app .. "/" .. file end,
  load = function(_path) return save_data end,
  save = function(_path, data) save_data = data; return true end,
}

-- ------------------------------------------------------------------ json --

json = require 'colyseus.serializer.json'

-- ----------------------------------------------------------------- timer --

timer = {}

function timer.delay(seconds, repeating, callback)
  assert(not repeating, "shim: repeating timers not implemented")
  local handle = shim._next_timer
  shim._next_timer = handle + 1
  shim._timers[handle] = { at = net.gettime() + seconds, callback = callback }
  return handle
end

function timer.cancel(handle)
  shim._timers[handle] = nil
end

-- ------------------------------------------------------------------ http --

--- Defold-shaped http.request over a blocking HTTP/1.1 exchange
--- (Connection: close keeps the read loop trivial).
http = {}

local function parse_url(url)
  local scheme, host, port, path = url:match("^(https?)://([%d%.]+):(%d+)(.*)$")
  assert(scheme == "http", "shim http: plain http to a dotted-quad IP only (got " .. url .. ")")
  if path == "" then path = "/" end
  return host, tonumber(port), path
end

function http.request(url, method, callback, headers, post_data, _options)
  local host, port, path = parse_url(url)
  local fd, err = net.connect(host, port)
  if fd == nil then
    callback(nil, "shim", { status = 0, response = err, headers = {} })
    return
  end

  local lines = {
    string.format("%s %s HTTP/1.1", method, path),
    "Host: " .. host .. ":" .. port,
    "Connection: close",
  }
  for k, v in pairs(headers or {}) do
    table.insert(lines, k .. ": " .. v)
  end
  local body = post_data or ""
  if #body > 0 then
    table.insert(lines, "Content-Length: " .. #body)
  end
  local request = table.concat(lines, "\r\n") .. "\r\n\r\n" .. body
  if not net.send_all(fd, request) then
    net.close(fd)
    callback(nil, "shim", { status = 0, response = "send failed", headers = {} })
    return
  end

  -- Connection: close → read until remote close
  local chunks = {}
  local deadline = net.gettime() + 10
  while net.gettime() < deadline do
    local data, rerr = net.recv(fd)
    if data == nil then
      if rerr == "closed" then break end
      net.close(fd)
      callback(nil, "shim", { status = 0, response = rerr, headers = {} })
      return
    elseif #data > 0 then
      table.insert(chunks, data)
    else
      net.sleep_ms(1)
    end
  end
  net.close(fd)

  local response = table.concat(chunks)
  local header_blob, resp_body = response:match("^(.-)\r\n\r\n(.*)$")
  local status = tonumber(header_blob:match("^HTTP/%d%.%d (%d+)")) or 0
  local resp_headers = {}
  for k, v in header_blob:gmatch("\r\n([^:\r\n]+):%s*([^\r\n]*)") do
    resp_headers[k:lower()] = v
  end
  -- chunked transfer: stitch the chunks back together
  if (resp_headers["transfer-encoding"] or ""):find("chunked") then
    local out, pos = {}, 1
    while true do
      local line_end = resp_body:find("\r\n", pos, true)
      if line_end == nil then break end
      local size = tonumber(resp_body:sub(pos, line_end - 1):match("^%x+"), 16)
      if size == nil or size == 0 then break end
      table.insert(out, resp_body:sub(line_end + 2, line_end + 1 + size))
      pos = line_end + 2 + size + 2
    end
    resp_body = table.concat(out)
  end
  callback(nil, "shim", { status = status, response = resp_body, headers = resp_headers })
end

-- ------------------------------------------------------------- websocket --

websocket = {
  EVENT_CONNECTED = 1,
  EVENT_DISCONNECTED = 2,
  EVENT_MESSAGE = 3,
  EVENT_ERROR = 4,
}

local band, bor, bxor = bit.band, bit.bor, bit.bxor
local char, byte = string.char, string.byte

local function ws_key()
  local raw = {}
  for i = 1, 16 do raw[i] = char(math.random(0, 255)) end
  -- minimal base64
  local b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local data = table.concat(raw)
  local out = {}
  for i = 1, #data, 3 do
    local a, b, c = byte(data, i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local s = ""
    for j = 3, 0, -1 do
      s = s .. b64:sub(math.floor(n / 64 ^ j) % 64 + 1, math.floor(n / 64 ^ j) % 64 + 1)
    end
    if c == nil then s = s:sub(1, b == nil and 2 or 3) .. string.rep("=", b == nil and 2 or 1) end
    out[#out + 1] = s
  end
  return table.concat(out)
end

--- Frame a client payload. RFC 6455 requires the MASK bit on client frames;
--- an all-zero mask key is a legal key and keeps the payload readable.
local function ws_frame(opcode, payload)
  local len = #payload
  local head
  if len < 126 then
    head = char(bor(0x80, opcode), bor(0x80, len))
  elseif len < 65536 then
    head = char(bor(0x80, opcode), bor(0x80, 126),
      math.floor(len / 256), len % 256)
  else
    error("shim ws: frame too large")
  end
  return head .. "\0\0\0\0" .. payload
end

function websocket.connect(url, _params, callback)
  local host, port, path = url:match("^ws://([%d%.]+):(%d+)(.*)$")
  assert(host, "shim ws: expected ws://<ip>:<port>/... (got " .. tostring(url) .. ")")
  if path == "" then path = "/" end

  local conn = {
    callback = callback,
    buffer = "",
    fragments = nil,
    open = false,
    handshake_done = false,
  }

  local fd, err = net.connect(host, tonumber(port))
  if fd == nil then
    callback(nil, conn, { event = websocket.EVENT_ERROR, message = err })
    return conn
  end
  conn.fd = fd

  net.send_all(fd, table.concat({
    "GET " .. path .. " HTTP/1.1",
    "Host: " .. host .. ":" .. port,
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: " .. ws_key(),
    "Sec-WebSocket-Version: 13",
  }, "\r\n") .. "\r\n\r\n")

  table.insert(shim._sockets, conn)
  return conn
end

function websocket.send(conn, data, _options)
  if conn.fd == nil then return end
  net.send_all(conn.fd, ws_frame(0x2, data))
end

function websocket.disconnect(conn)
  if conn.fd == nil then return end
  net.send_all(conn.fd, ws_frame(0x8, char(0x03, 0xe8))) -- 1000 normal closure
  net.close(conn.fd)
  conn.fd = nil
  conn.open = false
  conn.callback(nil, conn, { event = websocket.EVENT_DISCONNECTED, code = 1000 })
end

local function ws_dispatch(conn)
  -- handshake: wait for the full 101 response header
  if not conn.handshake_done then
    local head_end = conn.buffer:find("\r\n\r\n", 1, true)
    if head_end == nil then return true end
    local head = conn.buffer:sub(1, head_end - 1)
    conn.buffer = conn.buffer:sub(head_end + 4)
    if head:match("^HTTP/%d%.%d 101") == nil then
      conn.callback(nil, conn, { event = websocket.EVENT_ERROR, message = "handshake rejected: " .. head })
      return false
    end
    conn.handshake_done = true
    conn.open = true
    conn.callback(nil, conn, { event = websocket.EVENT_CONNECTED })
  end

  -- frames (server->client frames are unmasked)
  while true do
    local buf = conn.buffer
    if #buf < 2 then return true end
    local b1, b2 = byte(buf, 1, 2)
    local fin = band(b1, 0x80) ~= 0
    local opcode = band(b1, 0x0f)
    local len = band(b2, 0x7f)
    local offset = 2
    if len == 126 then
      if #buf < 4 then return true end
      len = byte(buf, 3) * 256 + byte(buf, 4)
      offset = 4
    elseif len == 127 then
      if #buf < 10 then return true end
      len = 0
      for i = 3, 10 do len = len * 256 + byte(buf, i) end
      offset = 10
    end
    if band(b2, 0x80) ~= 0 then offset = offset + 4 end -- masked (unexpected from server)
    if #buf < offset + len then return true end
    local payload = buf:sub(offset + 1, offset + len)
    conn.buffer = buf:sub(offset + len + 1)

    if opcode == 0x9 then
      net.send_all(conn.fd, ws_frame(0xA, payload))       -- ping -> pong
    elseif opcode == 0x8 then
      local code = #payload >= 2 and (byte(payload, 1) * 256 + byte(payload, 2)) or 1005
      net.close(conn.fd)
      conn.fd = nil
      conn.open = false
      conn.callback(nil, conn, { event = websocket.EVENT_DISCONNECTED, code = code })
      return false
    elseif opcode == 0x1 or opcode == 0x2 or opcode == 0x0 then
      if not fin or opcode == 0x0 then
        conn.fragments = (conn.fragments or "") .. payload
        if fin then
          local message = conn.fragments
          conn.fragments = nil
          conn.callback(nil, conn, { event = websocket.EVENT_MESSAGE, message = message })
        end
      else
        conn.callback(nil, conn, { event = websocket.EVENT_MESSAGE, message = payload })
      end
    end
  end
end

-- ------------------------------------------------------------------ pump --

--- Poll sockets + timers once. Call every frame.
function shim.pump()
  for i = #shim._sockets, 1, -1 do
    local conn = shim._sockets[i]
    if conn.fd == nil then
      table.remove(shim._sockets, i)
    else
      while true do
        local data, err = net.recv(conn.fd)
        if data == nil then
          net.close(conn.fd)
          conn.fd = nil
          conn.open = false
          conn.callback(nil, conn, { event = websocket.EVENT_DISCONNECTED, code = 1006, message = err })
          break
        elseif #data == 0 then
          break
        else
          conn.buffer = conn.buffer .. data
          if not ws_dispatch(conn) then break end
        end
      end
    end
  end

  local now = net.gettime()
  for handle, t in pairs(shim._timers) do
    if now >= t.at then
      shim._timers[handle] = nil
      t.callback()
    end
  end
end

--- Idle between frames, pumping once per millisecond-ish slice.
function shim.sleep_ms(ms)
  local deadline = net.gettime() + ms / 1000
  while net.gettime() < deadline do
    shim.pump()
    net.sleep_ms(1)
  end
end

return shim
