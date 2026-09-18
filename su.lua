-- su: switch user for one shell (M2). Usage: su [user] (default root)
-- Verifies the target password (root switching needs none), swaps
-- USER/LOGNAME/HOME + cwd, spawns a shell, restores afterwards.
local auth = require("auth")
local fs = require("fs")
local shell = require("shell")
local term = require("term")

local args = shell.parse(...)
local target = args[1] or "root"
local me = os.getenv("USER") or "root"

local entry = auth.getPasswd(target)
if not entry then
  io.stderr:write("su: unknown user " .. target .. "\n")
  return 1
end

if me ~= "root" then
  local sh = auth.getShadow(target)
  if sh and not (sh.salt == "" and sh.hash == "") then
    term.write("Password: ")
    local pw = term.read(nil, true, nil, "*") or ""
    if not auth.verify(target, pw) then
      io.stderr:write("su: incorrect password\n")
      return 1
    end
  end
end

local home = (entry.home ~= "" and entry.home) or "/"
if not fs.isDirectory(home) then home = "/" end

-- swap env/cwd around the child (children inherit copies, so this
-- only affects the new shell, and we restore right after)
local saveUser, saveLogname = os.getenv("USER"), os.getenv("LOGNAME")
local saveHome, saveCwd = os.getenv("HOME"), freax.getCwd()
os.setenv("USER", entry.name)
os.setenv("LOGNAME", entry.name)
os.setenv("HOME", home)
freax.setCwd(home)
local shellPath = (entry.shell ~= "" and entry.shell) or "/bin/sh.lua"
local pid = freax.spawn(entry.name .. "-sh", shellPath, {})
if pid then freax.wait(pid) end
os.setenv("USER", saveUser)
os.setenv("LOGNAME", saveLogname)
os.setenv("HOME", saveHome)
freax.setCwd(saveCwd)
return 0
