-- su: switch user for one shell (M2). Usage: su [user] (default root)
-- Setuid-root entry point: verifies target password for non-root callers,
-- then spawns a shell with target kernel credentials.
local auth = require("auth")
local fs = require("fs")
local shell = require("shell")
local term = require("term")

local args = shell.parse(...)
local target = args[1] or "root"
local realUid = freax.getuid()

local entry = auth.getPasswd(target)
if not entry then
  io.stderr:write("su: unknown user " .. target .. "\n")
  return 1
end

if realUid ~= 0 then
  -- prompt unless the target is explicitly passwordless; a missing or
  -- malformed shadow entry must never authenticate
  local sh = auth.getShadow(target)
  if not (sh and sh.salt == "" and sh.hash == "") then
    term.write("Password: ")
    local pw = term.read(nil, true, nil, "*") or ""
    if not auth.verify(target, pw) then
      io.stderr:write("su: incorrect password\n")
      return 1
    end
  elseif tonumber(entry.uid) == 0 then
    -- root left passwordless by install: an unprivileged session must not
    -- reach a root shell with no credential at all
    io.stderr:write("su: root has no password set; su refused\n")
    return 1
  end
end

local uid, gid = tonumber(entry.uid), tonumber(entry.gid)
if not uid or not gid then
  io.stderr:write("su: account " .. target .. " has no usable uid/gid\n")
  return 1
end

local home = entry.home or ""
local privateTmp = "/tmp/u" .. tostring(uid)
if not fs.isDirectory(privateTmp) then fs.makeDirectory(privateTmp) end
if home == "" or not fs.isDirectory(home) then home = privateTmp end

-- swap env/cwd around the child (children inherit copies, so this
-- only affects the new shell, and we restore right after)
local saveUser, saveLogname = os.getenv("USER"), os.getenv("LOGNAME")
local saveHome, saveCwd = os.getenv("HOME"), freax.getCwd()
os.setenv("USER", entry.name)
os.setenv("LOGNAME", entry.name)
os.setenv("HOME", home)
local saveTmpdir, saveTmp = os.getenv("TMPDIR"), os.getenv("TMP")
os.setenv("TMPDIR", privateTmp)
os.setenv("TMP", privateTmp)
freax.setCwd(home)
local shellPath = (entry.shell ~= "" and entry.shell) or "/bin/sh.lua"
local pid = freax.spawnAs(entry.name .. "-sh", shellPath, {}, uid, gid, home)
if pid then freax.wait(pid) end
os.setenv("USER", saveUser)
os.setenv("LOGNAME", saveLogname)
os.setenv("HOME", saveHome)
os.setenv("TMPDIR", saveTmpdir)
os.setenv("TMP", saveTmp)
freax.setCwd(saveCwd)
return 0
