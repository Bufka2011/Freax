-- useradd: create a login account (OpenOS useradd port).
-- Freax has no player whitelist; accounts live in /etc/passwd and
-- /etc/shadow. New accounts start with no password: set one with
-- `passwd NAME`. Use adduser for an interactive password prompt.
local auth = require("auth")
local fs = require("fs")
local shell = require("shell")

local args = shell.parse(...)
if #args ~= 1 then
  io.write("Usage: useradd <name>\n")
  return 1
end

local name = args[1]
if not name:match("^[%w_][%w_.-]*$") then
  io.stderr:write("useradd: invalid name\n")
  return 1
end
if auth.getPasswd(name) then
  io.stderr:write("useradd: " .. name .. " already exists\n")
  return 1
end

local uid = 1000
do
  local data = fs.readFile("/etc/passwd") or ""
  for line in (data .. "\n"):gmatch("(.-)\n") do
    local id = tonumber(line:match("^[^:]*:[^:]*:(%d+):") or "")
    if id and id >= uid then uid = id + 1 end
  end
end

local home = "/home/" .. name
if not fs.isDirectory("/home") then fs.makeDirectory("/home") end
if not fs.isDirectory(home) then
  local ok, err = fs.makeDirectory(home)
  if not ok then
    io.stderr:write("useradd: " .. tostring(err) .. "\n")
    return 1
  end
end

local fd, err = fs.open("/etc/passwd", "a")
if not fd then
  io.stderr:write("useradd: " .. tostring(err) .. "\n")
  return 1
end
fs.write(fd, name .. ":x:" .. uid .. ":" .. uid .. "::" .. home .. ":/bin/sh.lua\n")
fs.close(fd)
