-- sha256: pure-Lua SHA-256 (M2, no dependencies).
-- Deliberately dependency-free (works under OC Lua, LuaJIT, PUC):
-- 32-bit ops are done with plain arithmetic, no bit32/bit needed.
-- Used for the root password hash. Note: this is obfuscation-grade
-- security at best -- anyone with the disk can read /etc/shadow.

local sha256 = {}

local MOD = 4294967296 -- 2^32

local function band2(a, b)
  local r, bit = 0, 1
  for _ = 1, 32 do
    if a % 2 == 1 and b % 2 == 1 then r = r + bit end
    a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
  end
  return r
end

local function bxor2(a, b)
  local r, bit = 0, 1
  for _ = 1, 32 do
    if (a % 2) ~= (b % 2) then r = r + bit end
    a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
  end
  return r
end

local function bnot(a) return (MOD - 1) - (a % MOD) end
local function rshift(a, n) return math.floor((a % MOD) / (2 ^ n)) end
local function lshift(a, n) return (a * (2 ^ n)) % MOD end
local function rotr(a, n) return (rshift(a, n) + lshift(a, 32 - n)) % MOD end
local function add(...)
  local s = 0
  for i = 1, select("#", ...) do s = s + select(i, ...) end
  return s % MOD
end

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function processBlock(h, block)
  local w = {}
  for i = 0, 15 do
    local o = i * 4
    w[i] = (block:byte(o + 1) * 16777216) + (block:byte(o + 2) * 65536)
      + (block:byte(o + 3) * 256) + (block:byte(o + 4))
  end
  for i = 16, 63 do
    local s0 = bxor2(bxor2(rotr(w[i - 15], 7), rotr(w[i - 15], 18)), rshift(w[i - 15], 3))
    local s1 = bxor2(bxor2(rotr(w[i - 2], 17), rotr(w[i - 2], 19)), rshift(w[i - 2], 10))
    w[i] = add(w[i - 16], s0, w[i - 7], s1)
  end
  local a, bb, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
  for i = 0, 63 do
    local S1 = bxor2(bxor2(rotr(e, 6), rotr(e, 11)), rotr(e, 25))
    local ch = bxor2(band2(e, f), band2(bnot(e), g))
    local t1 = add(hh, S1, ch, K[i + 1], w[i])
    local S0 = bxor2(bxor2(rotr(a, 2), rotr(a, 13)), rotr(a, 22))
    local maj = bxor2(bxor2(band2(a, bb), band2(a, c)), band2(bb, c))
    local t2 = add(S0, maj)
    hh, g, f, e, d, c, bb, a = g, f, e, add(d, t1), c, bb, a, add(t1, t2)
  end
  h[1] = add(h[1], a)
  h[2] = add(h[2], bb)
  h[3] = add(h[3], c)
  h[4] = add(h[4], d)
  h[5] = add(h[5], e)
  h[6] = add(h[6], f)
  h[7] = add(h[7], g)
  h[8] = add(h[8], hh)
end

-- Incremental hasher: feed chunks as they stream in, never hold the
-- whole message. Used by apt/dpkg to verify downloads without OOM.
function sha256.new()
  local h = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  }
  local buf = ""
  local len = 0
  local obj = {}
  function obj:update(chunk)
    chunk = tostring(chunk or "")
    len = len + #chunk
    local data = chunk
    if #buf > 0 then
      data = buf .. data
      buf = ""
    end
    local i = 1
    while #data - i + 1 >= 64 do
      processBlock(h, data:sub(i, i + 63))
      i = i + 64
    end
    if i <= #data then buf = data:sub(i) end
    return obj
  end
  function obj:hex()
    local tail = buf
    local bitlen = len * 8
    tail = tail .. string.char(0x80)
    while (#tail % 64) ~= 56 do tail = tail .. "\0" end
    local hi = math.floor(bitlen / MOD)
    local lo = bitlen % MOD
    for _, v in ipairs({ hi, lo }) do
      -- 32-bit big-endian length words
      for i = 3, 0, -1 do
        tail = tail .. string.char(math.floor(v / (256 ^ i)) % 256)
      end
    end
    for i = 1, #tail, 64 do processBlock(h, tail:sub(i, i + 63)) end
    return string.format("%08x%08x%08x%08x%08x%08x%08x%08x",
      h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8])
  end
  return obj
end

function sha256.digest(msg)
  local h = sha256.new()
  h:update(tostring(msg))
  return h:hex()
end

return sha256
