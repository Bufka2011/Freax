-- login: terminal login, getty-style (M2).
-- Owns the screen from boot: banner, user/password prompt, then
-- spawns the shell and waits. Shell exit (logout) returns here,
-- exactly like getty respawning on Linux.
-- First boot with no root password runs setup instead.
-- Only "root" exists until the user system lands; unknown names are
-- still password-prompted (and always rejected) to avoid enumeration.

local term = require("term")
local fs = require("fs")
local shell = require("shell")
local shadow = require("shadow")

local function hostname()
  local data = fs.readFile("/etc/hostname")
  local name = data and data:match("%S+")
  return name or "freax"
end

local function readSecret()
  return term.readSecret()
end

local function setupPassword()
  term.writeln("No root password set -- creating one now.")
  while true do
    term.write("New root password: ")
    local a = readSecret()
    term.write("Retype root password: ")
    local b = readSecret()
    if a ~= b then
      term.writeln("Passwords do not match, try again.")
    else
      shadow.set("root", a)
      term.writeln("Root password set.")
      return
    end
  end
end

local function tryLogin()
  local host = hostname()
  term.write(host .. " login: ")
  local user = term.readLine()
  if not user or user == "" then return false end
  term.write("Password: ")
  local pw = readSecret()
  -- always hash even for unknown users: no user enumeration, no timing tell
  local ok = (user == "root") and shadow.verify("root", pw or "")
  if ok then
    return true
  end
  term.writeln("Login incorrect")
  return false
end

local function shellPath()
  -- K.spawn resolves FHS first, flat dev layout second
  return "/bin/sh.lua"
end

term.clear()
term.writeln("FREAX 0.5")
while true do
  if not shadow.hasPassword("root") then
    setupPassword()
  end
  if tryLogin() then
    local pid, err = freax.spawn("sh", shellPath(), {})
    if not pid then
      term.writeln("cannot start shell: " .. tostring(err))
    else
      freax.wait(pid)
      term.clear() -- fresh screen for the next login, like agetty
    end
  else
    freax.sleep(2) -- slow down guessing, like login(1)
  end
end
