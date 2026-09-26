-- auth: password hashing + account file helpers (M2).
-- Shadow format per line: "user:$salt$hex" (hex = sha256(salt..password)),
-- empty entry ("user:") means no password. Passwd format (Linux-like):
--   "name:x:uid:gid:gecos:home:shell"  (uid/gid reserved for the
--   future user system; only name/home/shell are honoured today).
--
-- SECURITY NOTE: sha256 is real hashing, but /etc/shadow stays
-- world-readable until Freax grows file permissions with the user
-- system. Anyone with the disk can read (then brute-force) it.

local fs = require("fs")
local sha256 = require("sha256")

local auth = {}

function auth.genSalt()
  local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  local out = {}
  for _ = 1, 8 do
    local i = math.random(1, #chars)
    out[#out + 1] = chars:sub(i, i)
  end
  return table.concat(out)
end

function auth.hash(password, salt)
  salt = salt or ""
  return sha256.digest(salt .. tostring(password))
end

local function readLines(path)
  local data = fs.readFile(path)
  if not data then return {} end
  local out = {}
  for line in (data .. "\n"):gmatch("(.-)\n") do
    if line ~= "" and line:sub(1, 1) ~= "#" then
      out[#out + 1] = line
    end
  end
  return out
end

local function split(line)
  local parts = {}
  for part in (line .. ":"):gmatch("(.-):") do
    parts[#parts + 1] = part
  end
  return parts
end

function auth.getPasswd(user)
  for _, line in ipairs(readLines("/etc/passwd")) do
    local p = split(line)
    if p[1] == user then
      return { name = p[1], uid = tonumber(p[3]), gid = tonumber(p[4]),
        gecos = p[5], home = p[6], shell = p[7] }
    end
  end
  return nil
end

function auth.getShadow(user)
  for _, line in ipairs(readLines("/etc/shadow")) do
    local name, rest = line:match("^([^:]*):(%S*)$")
    if name == user then
      if rest == "" then
        return { salt = "", hash = "" }
      end
      local salt, hash = rest:match("^%$(.-)%$(.+)$")
      if salt and salt ~= "" and hash:match("^%x+$") and #hash == 64 then
        return { salt = salt, hash = hash }
      end
      return nil, "malformed shadow entry"
    end
  end
  return nil
end

-- Only an explicit empty shadow entry means no password.
function auth.verify(user, password)
  if not auth.getPasswd(user) then
    return nil, "unknown user"
  end
  local sh, err = auth.getShadow(user)
  if not sh then return nil, err or "missing shadow entry" end
  if sh.salt == "" and sh.hash == "" then
    return true
  end
  if auth.hash(password or "", sh.salt) == sh.hash then
    return true
  end
  return nil, "incorrect password"
end

-- Rewrite one shadow entry (others preserved, order kept).
-- Stored as user:$salt$hex to match the historical format.
function auth.setShadow(user, salt, hash)
  local entry = user .. ":$" .. salt .. "$" .. hash
  local found, out = false, {}
  for _, line in ipairs(readLines("/etc/shadow")) do
    local name = line:match("^([^:]*):")
    if name == user then
      found = true
      out[#out + 1] = entry
    else
      out[#out + 1] = line
    end
  end
  if not found then
    out[#out + 1] = entry
  end
  local fd, err = fs.open("/etc/shadow", "w")
  if not fd then return nil, err end
  local ok, err = fs.write(fd, table.concat(out, "\n") .. "\n")
  local cok, cerr = fs.close(fd)
  if not ok then return nil, err end
  if cok == nil then return nil, cerr end
  return true
end

return auth
