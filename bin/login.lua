-- login: console login prompt, getty-style (M2).
-- Loops forever: prompt -> verify -> shell -> back to prompt on logout.
-- Killing login just respawns it (started by the kernel), like init/getty.
-- auth (and its sha256 dep) is loaded lazily: demo media has no account
-- DB, so requiring it at startup costs RAM for nothing.
local auth
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
    -- Demo media: no account database yet. Drop to a root setup shell.
    term.writeln("Demo mode. Run install to set up this computer.")
    term.writeln("Changes are not saved until you install to a hard drive.")
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
  if not auth then auth = require("auth") end
  term.write(hostname() .. " login: ")
  local user = term.readLine() or ""
  user = user:match("%S+") or ""
  local entry = (user ~= "") and auth.getPasswd(user) or nil
  -- Prompt unless the account is explicitly passwordless (nullok): a missing
  -- or malformed shadow entry must still prompt, and unknown users get a
  -- prompt too, so the flow leaks nothing about which accounts exist.
  local pw = ""
  local needPw = true
  if entry then
    local sh = auth.getShadow(user)
    needPw = not (sh and sh.salt == "" and sh.hash == "")
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
    if motd then
      local w = freax.ttySize()
      local _, cy = freax.ttyGetCursor()
      for line in motd:gmatch("[^\n]+") do
        freax.gpuFill(1, cy, w, 1, " ")
        freax.gpuSet(1, cy, line)
        cy = cy + 1
      end
      freax.ttySetCursor(1, cy)
    end
    local uid, gid = tonumber(entry.uid), tonumber(entry.gid)
    if not uid or not gid then
      term.writeln("Account " .. entry.name .. " has no usable uid/gid.")
    else
    -- session env (throwaway: reset on next login iteration)
    os.setenv("USER", entry.name)
    os.setenv("LOGNAME", entry.name)
    local privateTmp = "/tmp/u" .. tostring(uid)
    if not fs.isDirectory(privateTmp) then fs.makeDirectory(privateTmp) end
    os.setenv("TMPDIR", privateTmp)
    os.setenv("TMP", privateTmp)
    local home = entry.home or ""
    if home == "" or not fs.isDirectory(home) then
      if home ~= "" then term.writeln("No home " .. home .. ", using " .. privateTmp) end
      home = privateTmp
      if not fs.isDirectory(home) then
        term.writeln("No writable home or temporary directory.")
        home = "/"
      end
    end
    os.setenv("HOME", home)
    freax.setCwd(home)
    local shellPath = (entry.shell ~= "" and entry.shell) or "/bin/sh.lua"
    local pid = freax.spawnAs(entry.name .. "-sh", shellPath, {}, uid, gid, home)
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
end
