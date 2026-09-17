-- shadow: /etc/shadow handling (M2).
-- Format per line: user:$salt$hex  (hex = sha256(salt .. password))
-- Single-user for now; the table shape already supports more users
-- for the future user system. Like OpenOS-era practice this is
-- obfuscation, not real security: disk readers bypass it entirely.
local sha256 = require("sha256")
local fs = require("fs")

local shadow = {}
shadow.path = "/etc/shadow"

local function loadAll()
  local users = {}
  local data = fs.readFile(shadow.path)
  if data then
    for line in (data .. "\n"):gmatch("(.-)\n") do
      local user, hash = line:match("^([^:]+):(%S*)$")
      if user then users[user] = hash end
    end
  end
  return users
end

local function saveAll(users)
  local names = {}
  for name in pairs(users) do names[#names + 1] = name end
  table.sort(names)
  local out = {}
  for _, name in ipairs(names) do
    out[#out + 1] = name .. ":" .. (users[name] or "")
  end
  return fs.writeFile(shadow.path, table.concat(out, "\n") .. "\n")
end

function shadow.exists(user)
  local users = loadAll()
  return users[user] ~= nil
end

function shadow.hasPassword(user)
  local users = loadAll()
  return users[user] ~= nil and users[user] ~= ""
end

local function salt()
  local parts = {}
  for _ = 1, 8 do
    parts[#parts + 1] = string.format("%02x", math.random(0, 255))
  end
  return table.concat(parts)
end

function shadow.set(user, password)
  local users = loadAll()
  local s = salt()
  users[user] = "$" .. s .. "$" .. sha256.digest(s .. tostring(password))
  return saveAll(users)
end

function shadow.verify(user, password)
  local users = loadAll()
  local stored = users[user]
  if not stored or stored == "" then return false end
  local s = stored:match("^%$(.-)%$")
  if not s then return false end
  return stored == "$" .. s .. "$" .. sha256.digest(s .. tostring(password))
end

return shadow
