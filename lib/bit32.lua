-- bit32: pure-Lua fallback (Lua 5.2 bit32 subset).
-- The kernel exposes host bit32 to processes, but the live require path
-- (lib/package.lua) snapshots globals at init and carries no bit32 hook,
-- so require("bit32") failed whenever package init ran without it in env
-- (broke require("uuid")). File-based: resolves via package.path under any
-- require implementation, any load order, any kernel vintage. No host
-- globals used. All ops on unsigned 32-bit values.
local bit32 = {}

local MOD = 2 ^ 32

local function norm(n)
  n = tonumber(n) or 0
  return n % MOD
end

local function fold2(op, ...)
  local n = select("#", ...)
  if n == 0 then return op() end
  local acc = norm(select(1, ...))
  for i = 2, n do acc = op(acc, norm(select(i, ...))) end
  return acc
end

local function band2(a, b)
  local r, m = 0, 1
  for _ = 1, 32 do
    local x, y = a % 2, b % 2
    if x == 1 and y == 1 then r = r + m end
    a, b = (a - x) / 2, (b - y) / 2
    m = m * 2
  end
  return r
end

local function bor2(a, b)
  local r, m = 0, 1
  for _ = 1, 32 do
    local x, y = a % 2, b % 2
    if x == 1 or y == 1 then r = r + m end
    a, b = (a - x) / 2, (b - y) / 2
    m = m * 2
  end
  return r
end

local function bxor2(a, b)
  local r, m = 0, 1
  for _ = 1, 32 do
    local x, y = a % 2, b % 2
    if x ~= y then r = r + m end
    a, b = (a - x) / 2, (b - y) / 2
    m = m * 2
  end
  return r
end

function bit32.band(...) return fold2(band2, ...) end
function bit32.bor(...) return fold2(bor2, ...) end
function bit32.bxor(...) return fold2(bxor2, ...) end

function bit32.bnot(a)
  return (MOD - 1) - norm(a)
end

function bit32.lshift(a, d)
  return norm(norm(a) * (2 ^ (norm(d) % 32)))
end

function bit32.rshift(a, d)
  return math.floor(norm(a) / (2 ^ (norm(d) % 32)))
end

function bit32.arshift(a, d)
  a = norm(a)
  d = norm(d) % 32
  if d <= 0 then return a end
  if a < 2 ^ 31 then return math.floor(a / (2 ^ d)) end
  -- sign-extend: fill top d bits with 1s
  return norm(math.floor(a / (2 ^ d)) + (MOD - math.floor(MOD / (2 ^ d))))
end

function bit32.extract(n, field, width)
  width = width or 1
  return math.floor(norm(n) / (2 ^ field)) % (2 ^ width)
end

function bit32.replace(n, v, field, width)
  width = width or 1
  local mask = (2 ^ width - 1) * (2 ^ field)
  return norm(norm(n) - band2(norm(n), mask) + band2(norm(v) * (2 ^ field), mask))
end

function bit32.btest(...)
  return fold2(band2, ...) ~= 0
end

return bit32
