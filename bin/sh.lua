-- sh: Freax shell (M2).
-- Parsing and execution are delegated to lib/sh.lua (tokenize, aliases,
-- pipes, redirects, &&/||, glob, $expansion); this file provides the
-- interactive REPL, the builtin table, and registers it with lib/sh.

local term = require("term")
local shell = require("shell")
local fs = require("fs")
local sh = require("sh")

local builtins = {}

builtins.clear = function() term.clear() end

builtins.ps = function()
  io.write("PID  NAME\n")
  for _, p in ipairs(freax.ps()) do
    io.write(string.format("%-4d %s%s\n", p.pid, p.name, p.dead and " (dead)" or ""))
  end
end

builtins.pwd = function() io.write(freax.getCwd() .. "\n") end

builtins.cd = function(path)
  path = path or os.getenv("HOME") or "/"
  local ok, err = freax.setCwd(path)
  if not ok then io.write("cd: " .. tostring(err) .. "\n") return 1 end
end

builtins.export = function(...)
  for _, a in ipairs(table.pack(...)) do
    local k, v = tostring(a):match("^([^=]+)=(.*)$")
    if k then os.setenv(k, v) else io.write("export: use K=V\n") end
  end
end

builtins.unset = function(...)
  for _, a in ipairs(table.pack(...)) do os.setenv(tostring(a), nil) end
end

builtins.env = function()
  for k, v in pairs(os.getenv()) do io.write(k .. "=" .. tostring(v) .. "\n") end
end

builtins.alias = function(...)
  local args = table.pack(...)
  if args.n == 0 then return end
  for i = 1, args.n do
    local k, v = tostring(args[i]):match("^([^=]+)=(.*)$")
    if k then shell.setAlias(k, v) end
  end
end

builtins.unalias = function(...)
  for _, a in ipairs(table.pack(...)) do shell.setAlias(tostring(a), nil) end
end

-- Background job table (job spawning itself is not wired up yet).
local jobs = {}
local function jobAlive(pid)
  for _, p in ipairs(freax.ps()) do
    if p.pid == pid and not p.dead then return true end
  end
  return false
end

builtins.jobs = function()
  for _, j in ipairs(jobs) do
    local alive = {}
    for _, pid in ipairs(j.pids) do
      if jobAlive(pid) then alive[#alive + 1] = pid end
    end
    if #alive > 0 then
      io.write(string.format("[%d] running %s (pid %s)\n",
        j.id, j.line, table.concat(alive, ",")))
    end
  end
end

builtins.wait = function(pid)
  if pid then
    local ok, err = freax.wait(tonumber(pid) or -1)
    if not ok and err then io.stderr:write("wait: " .. tostring(err) .. "\n") return 1 end
  else
    for _, j in ipairs(jobs) do
      for _, p2 in ipairs(j.pids) do freax.wait(p2) end
    end
  end
end

builtins.kill = function(pid)
  if not pid then io.write("usage: kill PID\n") return 1 end
  local ok, err = freax.kill(tonumber(pid) or -1)
  if not ok then io.write("kill: " .. tostring(err) .. "\n") return 1 end
end

builtins.source = function(path)
  if not path then io.write("usage: source FILE\n") return 1 end
  local data, err = fs.readFile(shell.resolve(path))
  if not data then io.write("source: " .. tostring(err) .. "\n") return 1 end
  local code = 0
  for line in (data .. "\n"):gmatch("(.-)\n") do
    if line:match("%S") and not line:match("^%s*#") then
      code = runLine(line, (runDepth or 0) + 1)
    end
  end
  return code
end
builtins["."] = builtins.source

builtins.help = function()
  io.write("freax -- builtins: echo clear ps pwd cd export unset env alias unalias source jobs wait kill logout help exit\n")
  io.write("files: ls cat cp mv mkdir rmdir rm touch find tree du df mount umount list ln\n")
  io.write("doc: man\n")
  io.write("accounts: login passwd su whoami adduser\n")
  io.write("text: head grep wc sort less edit lua | sys: sleep uptime dmesg free\n")
  io.write("misc: which printenv hostname date time yes mktmp reboot shutdown install apt\n")
  io.write("hw: components lshw address primary redstone flash label resolution\n")
  io.write("net: wget pastebin\n")
  io.write("ops: a | b, > >> < 2> 2>&1 &>, ; && ||, quotes, source (M2)\n")
  io.write("note: background '&' jobs are not implemented yet\n")
end

builtins.exit = function() freax.exit() end
builtins.logout = function() freax.exit() end

-- Builtins run in-process inside lib/sh.lua's executor; register them here.
for name, fn in pairs(builtins) do
  sh.internal.builtins[name] = fn
end

runDepth = 0
function runLine(line, depth)
  depth = depth or 0
  if depth > 10 then
    io.write("sh: source nesting too deep\n")
    return 1
  end
  runDepth = depth
  local ok, reason = sh.execute(nil, line)
  if ok == nil then
    if reason then io.stderr:write("sh: " .. tostring(reason) .. "\n") end
    return 2
  end
  return ok and 0 or (sh.getLastExitCode() or 1)
end

-- Single-source version: /VERSION (apt-kept), fallback for old media.
local _ver = "0.6"
do
  local data = fs.readFile("/VERSION")
  if data and data:match("%S+") then _ver = data:match("%S+") end
end
-- Cached per process: /etc/passwd must not be re-read on every prompt.
-- Parsed inline instead of require("auth") so an interactive shell does not
-- pull lib/auth.lua + lib/sha256.lua into its process.
local _userCache, _userUid
local function currentUser()
  local uid = freax.geteuid()
  if uid == _userUid and _userCache then return _userCache end
  local name
  local data = fs.readFile("/etc/passwd")
  if data then
    for line in (data .. "\n"):gmatch("(.-)\n") do
      local name0, _, id = line:match("^([^:]*):[^:]*:(%d+):")
      if tonumber(id) == uid then name = name0 break end
    end
  end
  _userCache = name or os.getenv("USER") or tostring(uid)
  _userUid = uid
  return _userCache
end
term.writeln("FREAX " .. _ver .. " -- welcome, " .. currentUser())

local function hostname()
  if not _hostname then
    local data = fs.readFile("/etc/hostname")
    _hostname = (data and data:match("%S+")) or "freax"
  end
  return _hostname
end

freax.ttySetCompleter(sh.complete)

local profile = "/etc/profile.lua"
if freax.fsExists(profile) then
  local f = freax.fsOpen(profile, "r")
  if f then
    local content = ""
    while true do
      local chunk = freax.fsRead(f, 4096)
      if not chunk then break end
      content = content .. chunk
    end
    freax.fsClose(f)
    if #content > 0 then
      local fn, err = load(content, profile)
      if fn then pcall(fn) end
    end
  end
end

while true do
  local user = currentUser()
  local sym = (freax.geteuid() == 0) and "#" or "$"
  term.write(user .. "@" .. hostname() .. ":" .. freax.getCwd() .. sym .. " ")
  -- Ctrl+C cancels the line (ttyReadLine returns nil); an empty line is a
  -- no-op. pcall guards the REPL: a command error must never kill the
  -- shell (which would drop the user back to the login prompt).
  local ok, err = pcall(runLine, term.readLine() or "", 0)
  if not ok then io.stderr:write("sh: " .. tostring(err) .. "\n") end
end
