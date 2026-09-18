-- login: console login prompt, getty-style (M2).
-- Loops forever: prompt -> verify -> shell -> back to prompt on logout.
-- Killing login just respawns it (started by the kernel), like init/getty.
local auth = require("auth")
local fs = require("fs")
local shell = require("shell")
local term = require("term")

local function hostname()
  local data = fs.readFile("/etc/hostname")
  return (data and data:match("%S+")) or "freax"
end

term.clear() -- pristine screen: never show boot leftovers at the prompt

while true do
  if not fs.exists("/etc/passwd") then
    -- Live media without an installed system: present it as demo mode.
    -- Same root shell underneath.
    term.writeln("Demo mode. Run install to set up this computer.")
    os.setenv("USER", "root")
    os.setenv("LOGNAME", "root")
    os.setenv("HOME", "/")
    freax.setCwd("/")
    local pid = freax.spawn("root-sh", "/bin/sh.lua", {})
    if pid then
      freax.wait(pid)
    else
      term.writeln("Cannot start shell.")
      return
    end
  else
  term.write(hostname() .. " login: ")
  local user = term.readLine() or ""
  user = user:match("%S+") or ""
  local entry = (user ~= "") and auth.getPasswd(user) or nil
  -- Prompt unless this is a known account with no password (nullok):
  -- unknown users still get a prompt (then fail) so the flow leaks
  -- nothing about which accounts exist.
  local pw = ""
  local needPw = true
  if entry then
    local sh = auth.getShadow(user)
    needPw = sh and not (sh.salt == "" and sh.hash == "")
  end
  if needPw then
    term.write("Password: ")
    pw = term.read(nil, true, nil, "*") or ""
  end
  local ok = entry and auth.verify(user, pw)
  if not ok then
    term.writeln("Login incorrect")
  else
    local motd = fs.readFile("/etc/motd")
    if motd then term.writeln(motd:gsub("\n$", "")) end
    -- session env (throwaway: reset on next login iteration)
    os.setenv("USER", entry.name)
    os.setenv("LOGNAME", entry.name)
    os.setenv("HOME", (entry.home ~= "" and entry.home) or "/")
    local home = os.getenv("HOME")
    if not fs.isDirectory(home) then
      term.writeln("No home " .. home .. ", staying in /")
      home = "/"
      os.setenv("HOME", "/")
    end
    freax.setCwd(home)
    local shellPath = (entry.shell ~= "" and entry.shell) or "/bin/sh.lua"
    local pid = freax.spawn(entry.name .. "-sh", shellPath, {})
    if pid then
      freax.wait(pid) -- logout returns here
    else
      term.writeln("Cannot start shell " .. shellPath)
    end
    term.writeln("")
    term.clear() -- fresh screen for the next login, like agetty
  end
  end
end
