-- adduser: create a login account (M2, minimal).
-- Root-only. Writes /etc/passwd + /etc/shadow (same formats auth.lua
-- uses) and makes the home dir. UIDs for people start at 1000;
-- permissions/ownership enforcement belongs to the future user system.
local auth = require("auth")
local fs = require("fs")
local shell = require("shell")
local term = require("term")

local args, opts = shell.parse(...)
if #args ~= 1 or (opts and opts.help) then
  io.write("Usage: adduser <name>\n")
  return 1
end

local me = os.getenv("USER") or "root"
if me ~= "root" then
  io.stderr:write("adduser: only root may add users\n")
  return 1
end

local name = args[1]
if not name:match("^[%w_][%w_.-]*$") then
  io.stderr:write("adduser: invalid name\n")
  return 1
end
if auth.getPasswd(name) then
  io.stderr:write("adduser: " .. name .. " already exists\n")
  return 1
end

-- next free uid >= 1000 (third field of passwd lines)
local uid = 1000
do
  local data = fs.readFile("/etc/passwd") or ""
  for line in (data .. "\n"):gmatch("(.-)\n") do
    local id = tonumber(line:match("^[^:]*:[^:]*:(%d+):") or "")
    if id and id >= uid then uid = id + 1 end
  end
end

local home = "/home/" .. name
term.write("New password: ")
local a = term.read(nil, true, nil, "*") or ""
term.write("Retype: ")
local b = term.read(nil, true, nil, "*") or ""
if a ~= b then
  io.stderr:write("adduser: mismatch\n")
  return 1
end
if a == "" then
  io.stderr:write("adduser: empty password not allowed\n")
  return 1
end

if not fs.isDirectory("/home") then
  fs.makeDirectory("/home")
end
if not fs.isDirectory(home) then
  local ok, err = fs.makeDirectory(home)
  if not ok then
    io.stderr:write("adduser: " .. tostring(err) .. "\n")
    return 1
  end
end

do
  local fd, err = fs.open("/etc/passwd", "a")
  if not fd then
    io.stderr:write("adduser: " .. tostring(err) .. "\n")
    return 1
  end
  fs.write(fd, name .. ":x:" .. uid .. ":" .. uid .. "::" .. home .. ":/bin/sh.lua\n")
  fs.close(fd)
end

local salt = auth.genSalt()
local ok, err = auth.setShadow(name, salt, auth.hash(a, salt))
if not ok then
  io.stderr:write("adduser: " .. tostring(err) .. "\n")
  return 1
end
term.writeln("Added " .. name .. " (uid " .. uid .. ").")
return 0
