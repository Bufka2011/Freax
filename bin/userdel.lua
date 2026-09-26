-- userdel: remove a login account (OpenOS userdel port).
-- Drops the user from /etc/passwd and /etc/shadow; the home dir is
-- left in place, matching OpenOS userdel semantics.
local auth = require("auth")
local fs = require("fs")
local shell = require("shell")

local args = shell.parse(...)
if #args ~= 1 then
  io.write("Usage: userdel <name>\n")
  return 1
end
if freax.geteuid() ~= 0 then
  io.stderr:write("userdel: only root may delete users\n")
  return 1
end

local name = args[1]
if not auth.getPasswd(name) then
  io.stderr:write("userdel: no such user\n")
  return 1
end

local function drop(path)
  local out = {}
  for line in ((fs.readFile(path) or "") .. "\n"):gmatch("(.-)\n") do
    if line ~= "" and line:match("^([^:]*):") ~= name then
      out[#out + 1] = line
    end
  end
  local fd, err = fs.open(path, "w")
  if not fd then return nil, err end
  fs.write(fd, table.concat(out, "\n") .. "\n")
  fs.close(fd)
  return true
end

local ok, err = drop("/etc/passwd")
if ok then ok, err = drop("/etc/shadow") end
if not ok then
  io.stderr:write("userdel: " .. tostring(err) .. "\n")
  return 1
end
return 0
