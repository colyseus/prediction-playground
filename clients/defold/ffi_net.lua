--
-- Minimal TCP client over LuaJIT FFI (BSD sockets) — no luasocket needed.
-- Supports exactly what the headless Defold-SDK probe requires: connect to an
-- IPv4 address, non-blocking reads, blocking-ish writes, wall-clock time.
--
local ffi = require 'ffi'

local M = {}

local is_macos = ffi.os == "OSX"

if is_macos then
  ffi.cdef[[
    struct in_addr { uint32_t s_addr; };
    struct sockaddr_in {
      uint8_t  sin_len;
      uint8_t  sin_family;
      uint16_t sin_port;
      struct in_addr sin_addr;
      char     sin_zero[8];
    };
    struct timeval { long tv_sec; int32_t tv_usec; };
  ]]
else
  ffi.cdef[[
    struct in_addr { uint32_t s_addr; };
    struct sockaddr_in {
      uint16_t sin_family;
      uint16_t sin_port;
      struct in_addr sin_addr;
      char     sin_zero[8];
    };
    struct timeval { long tv_sec; long tv_usec; };
  ]]
end

ffi.cdef[[
  typedef int socklen_t;
  int socket(int domain, int type, int protocol);
  int connect(int sockfd, const struct sockaddr_in *addr, socklen_t addrlen);
  long send(int sockfd, const void *buf, size_t len, int flags);
  long recv(int sockfd, void *buf, size_t len, int flags);
  int close(int fd);
  int fcntl(int fd, int cmd, int arg);
  int setsockopt(int sockfd, int level, int optname, const void *optval, socklen_t optlen);
  int usleep(unsigned int usec);
  int gettimeofday(struct timeval *tv, void *tz);
  uint16_t htons(uint16_t v);
  uint32_t inet_addr(const char *cp);
]]

local AF_INET = 2
local SOCK_STREAM = 1
local F_SETFL = 4
local O_NONBLOCK = is_macos and 0x0004 or 0x800
local EAGAIN = is_macos and 35 or 11
local SOL_SOCKET = is_macos and 0xffff or 1
local SO_NOSIGPIPE = 0x1022 -- macOS only

--- Wall clock in SECONDS (fractional) — the shim exposes it as socket.gettime.
function M.gettime()
  local tv = ffi.new("struct timeval")
  ffi.C.gettimeofday(tv, nil)
  return tonumber(tv.tv_sec) + tonumber(tv.tv_usec) / 1e6
end

function M.sleep_ms(ms)
  ffi.C.usleep(ms * 1000)
end

--- Connect to ip:port (dotted-quad only). Returns fd or nil, err.
--- The socket is left NON-BLOCKING; writes poll on EAGAIN.
function M.connect(ip, port)
  local fd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
  if fd < 0 then return nil, "socket() failed" end

  if is_macos then
    local one = ffi.new("int[1]", 1)
    ffi.C.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, one, 4)
  end

  local addr = ffi.new("struct sockaddr_in")
  if is_macos then addr.sin_len = ffi.sizeof(addr) end
  addr.sin_family = AF_INET
  addr.sin_port = ffi.C.htons(port)
  addr.sin_addr.s_addr = ffi.C.inet_addr(ip)

  if ffi.C.connect(fd, addr, ffi.sizeof(addr)) < 0 then
    ffi.C.close(fd)
    return nil, "connect() to " .. ip .. ":" .. port .. " failed"
  end
  ffi.C.fcntl(fd, F_SETFL, O_NONBLOCK)
  return fd
end

--- Send all of `data`, polling briefly on EAGAIN. Returns true, or nil on error.
function M.send_all(fd, data)
  local remaining = #data
  local offset = 0
  while remaining > 0 do
    local n = tonumber(ffi.C.send(fd, ffi.cast("const char*", data) + offset, remaining, 0))
    if n > 0 then
      offset = offset + n
      remaining = remaining - n
    elseif n < 0 and ffi.errno() == EAGAIN then
      ffi.C.usleep(500)
    else
      return nil, "send() failed"
    end
  end
  return true
end

local RECV_BUF = ffi.new("char[?]", 65536)

--- Non-blocking read. Returns: data (may be ""), or nil + "closed"/"error".
function M.recv(fd)
  local n = tonumber(ffi.C.recv(fd, RECV_BUF, 65536, 0))
  if n > 0 then
    return ffi.string(RECV_BUF, n)
  elseif n == 0 then
    return nil, "closed"
  elseif ffi.errno() == EAGAIN then
    return ""
  else
    return nil, "error"
  end
end

function M.close(fd)
  ffi.C.close(fd)
end

return M
