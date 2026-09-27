-- sh: Freax shell (M2).
-- Parsing and execution are delegated to lib/sh.lua (tokenize, aliases,
-- pipes, redirects, &&/||, glob, $expansion); this file provides the
-- interactive REPL, the builtin table, and registers it with lib/sh.

local term = require("term")
local shell = require("shell")
local fs = require("fs")
local sh = require("sh")
local argv = table.pack(...)

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

-- Job control table. Each entry is one pipeline: {id, pgid, pids, line}.
-- Bounded so a long session cannot grow the shell process without limit.
local MAX_JOBS = 32
local jobs = {}
local nextJobId = 1

-- One process-table snapshot per call site: freax.ps() builds a table per
-- process, so scanning it per job/pid would be needlessly expensive here.
local function psMap()
  local map = {}
  for _, p in ipairs(freax.ps()) do map[p.pid] = p end
  return map
end

local function jobState(job, map)
  map = map or psMap()
  local live, stopped = {}, false
  for _, pid in ipairs(job.pids) do
    local p = map[pid]
    if p and not p.dead then
      live[#live + 1] = pid
      if p.stopped or p.state == "stopped" then stopped = true end
    end
  end
  return (#live > 0) and (stopped and "stopped" or "running") or "done", live
end

-- Track a new background job. Finished jobs are announced by announceJobs, so
-- nothing is dropped silently; a table full of running jobs refuses new ones
-- instead of losing track of a live job.
local function addJob(pgid, pids, line)
  if #jobs >= MAX_JOBS then
    local map = psMap()
    for i = #jobs, 1, -1 do
      if select(1, jobState(jobs[i], map)) == "done" then
        table.remove(jobs, i)
      end
    end
    if #jobs >= MAX_JOBS then return nil, "too many jobs" end
  end
  local job = { id = nextJobId, pgid = pgid, pids = pids, line = line }
  nextJobId = nextJobId + 1
  jobs[#jobs + 1] = job
  return job
end

-- Printable label for a job: the command text, or "job" when a script started
-- it without a recorded line.
local function j_line(job)
  local text = tostring(job.line or ""):match("^%s*(.-)%s*$")
  if text == "" then return "job" end
  return text
end

-- Resolve %n, %+, %- and %prefix job references. %+ is the most recent live
-- job, %- the one before it.
local function resolveJob(spec)
  if not spec then return nil end
  spec = tostring(spec)
  local map
  if spec == "%" or spec == "%+" or spec == "%-" then
    map = psMap()
    local live = {}
    for _, j in ipairs(jobs) do
      if select(1, jobState(j, map)) ~= "done" then live[#live + 1] = j end
    end
    if #live == 0 then return nil end
    -- %+ is the newest live job, %- the one before it.
    if spec == "%-" then return live[#live - 1] end
    return live[#live]
  end
  if spec:sub(1, 1) == "%" then
    local rest = spec:sub(2)
    if rest:match("^%d+$") then
      local want = tonumber(rest)
      for _, j in ipairs(jobs) do if j.id == want then return j end end
      return nil
    end
    for _, j in ipairs(jobs) do
      if j_line(j):sub(1, #rest) == rest then return j end
    end
    return nil
  end
  return nil
end

-- Block until a job terminates. A stopped job returns 148 (128 + SIGTSTP)
-- instead of blocking forever, so the shell can never hang on `wait`.
local function waitJob(job)
  local status = 0
  while true do
    local state = jobState(job)
    if state == "done" then break end
    if state == "stopped" then return 148 end
    local pid, code = freax.waitGroup(job.pgid)
    if not pid then
      if jobState(job) == "done" then break end
      freax.sleep(0.05)
    else
      status = code or 0
    end
  end
  return status
end

builtins.jobs = function()
  local map, any = psMap(), false
  for _, j in ipairs(jobs) do
    local state, live = jobState(j, map)
    if state ~= "done" then
      any = true
      io.write(string.format("[%d] %-7s %s (%s)\n", j.id, state, j_line(j),
        table.concat(live, ",")))
    end
  end
  if not any then io.write("no jobs\n") end
end

builtins.fg = function(spec)
  local job = resolveJob(spec or "%+")
  if not job then io.stderr:write("fg: no such job\n") return 1 end
  if select(1, jobState(job)) == "done" then
    io.stderr:write("fg: job has exited\n") return 1
  end
  freax.kill(-job.pgid, "CONT")
  io.write(j_line(job) .. "\n")
  freax.setForeground(job.pgid)
  local status = waitJob(job)
  freax.setForeground(nil)
  return status
end

builtins.bg = function(spec)
  local job = resolveJob(spec or "%+")
  if not job then io.stderr:write("bg: no such job\n") return 1 end
  local ok, err = freax.kill(-job.pgid, "CONT")
  if not ok then io.stderr:write("bg: " .. tostring(err) .. "\n") return 1 end
  io.write("[" .. job.id .. "] " .. j_line(job) .. "\n")
end

builtins.wait = function(spec)
  if spec then
    local text = tostring(spec)
    -- A '%' reference is always a job: never silently reinterpret it as a pid.
    if text:sub(1, 1) == "%" then
      local job = resolveJob(text)
      if not job then io.stderr:write("wait: no such job\n") return 1 end
      return waitJob(job)
    end
    local pid = tonumber(text)
    if not pid then io.stderr:write("wait: bad job or pid\n") return 1 end
    local code, err = freax.wait(pid)
    if code == nil then
      io.stderr:write("wait: " .. tostring(err) .. "\n")
      return 1
    end
    return code
  end
  local status = 0
  for _, j in ipairs(jobs) do
    if select(1, jobState(j)) ~= "done" then status = waitJob(j) end
  end
  return status
end

builtins.kill = function(...)
  local argv, sig = table.pack(...), nil
  local targets = {}
  local i = 1
  while i <= argv.n do
    local a = tostring(argv[i])
    if a == "-s" or a == "--signal" then
      sig = argv[i + 1]
      i = i + 2
    elseif a:match("^%-[A-Za-z]") and not a:match("^%-%d+$") then
      sig = a:sub(2)
      i = i + 1
    elseif a == "--" then
      i = i + 1
      break
    else
      targets[#targets + 1] = a
      i = i + 1
    end
  end
  while i <= argv.n do targets[#targets + 1] = tostring(argv[i]) i = i + 1 end
  if #targets == 0 then
    io.write("usage: kill [-s SIGNAL | -SIGNAL] %JOB | PID...\n")
    return 1
  end
  local code = 0
  for _, t in ipairs(targets) do
    -- %n/%+/%- job references resolve to the whole process group; a bare
    -- number is a pid. Negative ids target a process group (kill(-pgid));
    -- the kernel enforces same-uid-or-root either way.
    local text = tostring(t)
    if text:sub(1, 1) == "%" then
      local job = resolveJob(text)
      if not job then
        io.stderr:write("kill: " .. text .. ": no such job\n")
        code = 1
      else
        local ok, err = freax.kill(-job.pgid, sig)
        if not ok then
          io.stderr:write("kill: " .. text .. ": " .. tostring(err) .. "\n")
          code = 1
        end
      end
    else
      local ok, err = freax.kill(tonumber(text) or 0, sig)
      if not ok then
        io.stderr:write("kill: " .. text .. ": " .. tostring(err) .. "\n")
        code = 1
      end
    end
  end
  return code
end

local function packedArgs(from, first)
  local out = {}
  for i = first, from.n do out[#out + 1] = tostring(from[i]) end
  return out
end

builtins.source = function(path, ...)
  if not path then io.write("usage: source FILE [ARG...]\n") return 1 end
  local parent = sh.internal.currentContext or sh.newContext("sh")
  if (parent.depth or 0) >= 10 then
    io.stderr:write("sh: source nesting too deep\n")
    return 1
  end
  local passed = table.pack(...)
  local args = passed.n > 0 and packedArgs(passed, 1) or parent.args
  local context = sh.newContext(parent.name, args, (parent.depth or 0) + 1)
  local code, err = sh.runFile(context, shell.resolve(path))
  if err then io.stderr:write("source: " .. tostring(err) .. "\n") end
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
  io.write("ops: a | b, > >> < 2> 2>&1 &>, ; && ||, if, for, source\n")
  io.write("jobs: cmd &, jobs, fg %n, bg %n, wait [%n], kill %n\n")
  io.write("keys: Ctrl+C interrupt job, Ctrl+Z suspend job\n")
  io.write("scripts: sh FILE [ARG...], sh -c COMMAND [NAME [ARG...]]\n")
end

builtins.exit = function(code) freax.exit(tonumber(code) or 0) end
builtins.logout = builtins.exit

-- Builtins run in-process inside lib/sh.lua's executor; register them here.
for name, fn in pairs(builtins) do
  sh.internal.builtins[name] = fn
end
-- fg/wait block; the REPL already runs commands under pcall, and pcall is
-- yieldable here, so no special dispatch is needed.

-- Text of the command currently running, shown in job listings.
local lastLine = ""

-- Report jobs that finished since the last prompt, then drop announced jobs.
local function announceJobs()
  for _, j in ipairs(jobs) do
    if not j.reported and select(1, jobState(j)) == "done" then
      j.reported = true
      io.write(string.format("[%d]  done                 %s\n", j.id, j_line(j)))
    end
  end
  for i = #jobs, 1, -1 do
    if jobs[i].reported then table.remove(jobs, i) end
  end
end

local function runScript(input, context)
  local code, reason = sh.runScript(context, input)
  if reason then io.stderr:write("sh: " .. tostring(reason) .. "\n") end
  return code
end

local context
local interactive = false

-- A background pipeline registers itself here in both modes; only an
-- interactive shell prints the "[n] pid" notice, so script output stays
-- predictable while `wait` still works.
sh.internal.onBackground = function(job)
  local entry, why = addJob(job.pgid, job.pids, lastLine)
  if not entry then
    io.stderr:write("sh: " .. tostring(why) .. "\n")
    return
  end
  if interactive then
    io.write(string.format("[%d] %d\n", entry.id, job.pgid))
  end
end

if argv[1] == "-c" then
  if not argv[2] then io.stderr:write("sh: -c requires command\n") return 2 end
  context = sh.newContext(argv[3] or "sh", packedArgs(argv, 4))
  return runScript(argv[2], context)
elseif argv[1] then
  local path = shell.resolve(tostring(argv[1]))
  context = sh.newContext(path, packedArgs(argv, 2))
  local code, reason = sh.runFile(context, path)
  if reason then io.stderr:write("sh: " .. tostring(reason) .. "\n") end
  return code
end

context = sh.newContext("sh")
interactive = true

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

local _hostname
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
  announceJobs()
  local user = currentUser()
  local sym = (freax.geteuid() == 0) and "#" or "$"
  term.write(user .. "@" .. hostname() .. ":" .. freax.getCwd() .. sym .. " ")
  -- Ctrl+D on an empty line reports EOF (false); Ctrl+C cancels the line
  -- (nil). EOF ends the shell, which returns the user to the login prompt.
  local first = term.readLine()
  if first == false then return 0 end
  first = first or ""
  lastLine = first
  local lines = {first}
  while true do
    local _, _, incomplete = sh.parseScript(lines)
    if not incomplete then break end
    term.write("> ")
    local continuation = term.readLine()
    if not continuation then lines = {} break end
    lines[#lines + 1] = continuation
  end
  -- pcall guards the REPL: a command error must never kill the shell, which
  -- would drop the user back to the login prompt.
  local ok, err = pcall(runScript, lines, context)
  if not ok then io.stderr:write("sh: " .. tostring(err) .. "\n") end
end
