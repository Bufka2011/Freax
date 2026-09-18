-- sh: Freax shell (M2).
-- Quotes-aware tokenizer; pipelines | ; redirects > >> < 2> 2>&1;
-- chaining ; && || ; aliases; source. Builtins use io (redirectable).

local term = require("term")
local shell = require("shell")
local fs = require("fs")

local builtins = {}

builtins.echo = function(...)
  local out = {}
  for i = 1, select("#", ...) do out[#out + 1] = tostring(select(i, ...)) end
  io.write(table.concat(out, " ") .. "\n")
end

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

-- Background jobs (single-user: any pid may be waited/killed).
local jobs, nextJob = {}, 1
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
    freax.wait(tonumber(pid) or -1)
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
  io.write("ops: a | b, > >> < 2> 2>&1 &> & jobs, ; && ||, quotes, source (M2)\n")
end

builtins.exit = function() freax.exit() end
builtins.logout = function() freax.exit() end

-- Tokenizer: quotes, backslash escapes, operators incl. 2> 2>> 0< && || ;.
local function tokenize(line)
  local toks, cur, q = {}, "", nil
  local function flushOp(op)
    if cur ~= "" and cur:match("^%d+$") then
      toks[#toks + 1] = cur .. op
      cur = ""
    else
      if cur ~= "" then toks[#toks + 1] = cur cur = "" end
      toks[#toks + 1] = op
    end
  end
  local i = 1
  while i <= #line do
    local c = line:sub(i, i)
    local two = line:sub(i, i + 1)
    if q then
      if c == q then q = nil
      elseif c == "\\" and i < #line then i = i + 1 cur = cur .. line:sub(i, i)
      else cur = cur .. c end
    elseif c == '"' or c == "'" then q = c
    elseif c:match("%s") then
      if cur ~= "" then toks[#toks + 1] = cur cur = "" end
    elseif two == "&&" or two == "||" or two == ">>" or two == "2>" or two == "&>" then
      if two == "2>" and line:sub(i + 2, i + 2) == ">" then
        flushOp("2>>")
        i = i + 1
      elseif two == ">>" then
        flushOp(">>")
        i = i + 1
      else
        -- && || or fd-less 2> : flush pending word, emit operator
        if cur ~= "" then toks[#toks + 1] = cur cur = "" end
        toks[#toks + 1] = two
        i = i + 1
      end
    elseif c == "|" or c == "<" or c == ">" or c == ";" then
      flushOp(c)
    elseif c == "&" then
      -- lone &: background operator (&& handled above); quoted & stays data
      if cur ~= "" then toks[#toks + 1] = cur cur = "" end
      toks[#toks + 1] = c
    else cur = cur .. c end
    i = i + 1
  end
  if cur ~= "" then toks[#toks + 1] = cur end
  return toks
end

-- Split token list into commands chained by ; && ||.
local function splitCommands(toks)
  local cmds = { { stages = { { args = {} } }, op = nil } }
  local cur = cmds[1].stages[1]
  local i = 1
  while i <= #toks do
    local t = toks[i]
    if t == ";" or t == "&&" or t == "||" or t == "&" then
      cmds[#cmds].after = (t == "&") and ";" or t
      if t == "&" then cmds[#cmds].bg = true end
      cmds[#cmds + 1] = { stages = { { args = {} } } }
      cur = cmds[#cmds].stages[1]
    elseif t == "|" then
      cur = { args = {} }
      cmds[#cmds].stages[#cmds[#cmds].stages + 1] = cur
    elseif t == "<" or t == "0<" then
      i = i + 1
      if not toks[i] then return nil, "missing file after " .. t end
      cur.stdin = toks[i]
    elseif t == ">" or t == "1>" or t == ">>" or t == "1>>" or t == "&>" then
      i = i + 1
      if not toks[i] then return nil, "missing file after " .. t end
      cur.stdout = toks[i]
      cur.append = (t == ">>" or t == "1>>")
      if t == "&>" then cur.errMerge = "1" end -- &>file = >file 2>&1
    elseif t == "2>" or t == "2>>" then
      i = i + 1
      if not toks[i] then return nil, "missing file after " .. t end
      local target = toks[i]
      if target == "&" and toks[i + 1] then
        i = i + 1
        target = "&" .. toks[i] -- split form of 2>&N
      end
      if target:sub(1, 1) == "&" then -- 2>&N form (tokenizer splits it)
        cur.errMerge = target:sub(2)
      else
        cur.stderr = target
        cur.errAppend = (t == "2>>")
      end
    elseif t:match("^2>&%d$") then
      cur.errMerge = t:sub(4)
    else
      cur.args[#cur.args + 1] = t
    end
    i = i + 1
  end
  return cmds
end

local function runBuiltin(b, args, st)
  local oldIn, oldOut, oldErr = io.input(), io.output(), io.error()
  local opened = {}
  local function fail(msg)
    io.input(oldIn) io.output(oldOut) io.error(oldErr)
    for _, h in ipairs(opened) do h:close() end
    io.write(msg .. "\n")
    return 1
  end
  if st.stdin then
    local f, err = io.open(shell.resolve(st.stdin), "r")
    if not f then return fail("cannot read " .. st.stdin .. ": " .. tostring(err)) end
    opened[#opened + 1] = f
    io.input(f)
  end
  if st.stdout then
    local f, err = io.open(shell.resolve(st.stdout), st.append and "a" or "w")
    if not f then return fail("cannot write " .. st.stdout .. ": " .. tostring(err)) end
    opened[#opened + 1] = f
    io.output(f)
  end
  if st.stderr then
    local f, err = io.open(shell.resolve(st.stderr), st.errAppend and "a" or "w")
    if not f then return fail("cannot write " .. st.stderr .. ": " .. tostring(err)) end
    opened[#opened + 1] = f
    io.error(f)
  elseif st.errMerge == "1" then
    io.error(io.output())
  end
  local r = b(table.unpack(args))
  io.input(oldIn) io.output(oldOut) io.error(oldErr)
  for _, h in ipairs(opened) do h:close() end
  return r or 0
end

local function runExternal(stages, bg, line)
  local pids = {}
  local prevR = nil
  local owned = {}
  local function cleanup()
    for _, h in ipairs(owned) do
      if type(h) == "number" then freax.fsClose(h)
      else h:close() end
    end
    owned = {}
  end
  local function reap()
    local code = 0
    for i, p2 in ipairs(pids) do
      local c = freax.wait(p2)
      if i == #pids then code = c or 0 end
    end
    return code
  end
  for idx, st in ipairs(stages) do
    local cmd = st.args[1]
    if not cmd then
      cleanup()
      for _, p2 in ipairs(pids) do freax.wait(p2) end
      return 0
    end
    if builtins[cmd] then
      io.write(cmd .. ": builtin in pipeline unsupported\n")
      cleanup()
      for _, p2 in ipairs(pids) do freax.wait(p2) end
      return 1
    end
    local inFd, outFd, errFd = nil, nil, nil
    if st.stdin then
      local h, err = io.open(shell.resolve(st.stdin), "r")
      if not h then io.write("cannot read " .. st.stdin .. "\n") cleanup() return 1 end
      owned[#owned + 1] = h
      inFd = h._fd
    elseif prevR then
      inFd = prevR
    end
    local nextR = nil
    if idx < #stages then
      local rfd, wfd = freax.pipe()
      owned[#owned + 1] = rfd
      owned[#owned + 1] = wfd
      outFd = wfd
      nextR = rfd
    elseif st.stdout then
      local h, err = io.open(shell.resolve(st.stdout), st.append and "a" or "w")
      if not h then io.write("cannot write " .. st.stdout .. "\n") cleanup() return 1 end
      owned[#owned + 1] = h
      outFd = h._fd
    end
    if st.stderr then
      local h, err = io.open(shell.resolve(st.stderr), st.errAppend and "a" or "w")
      if not h then io.write("cannot write " .. st.stderr .. "\n") cleanup() return 1 end
      owned[#owned + 1] = h
      errFd = h._fd
    elseif st.errMerge == "1" then
      errFd = outFd -- 2>&1: same destination (or tty default when nil)
    end
    local prog = shell.resolveCmd(cmd)
    local args = {}
    for i = 2, #st.args do args[#args + 1] = st.args[i] end
    local pid, err = freax.spawnIO(cmd, prog, args, inFd, outFd, errFd)
    if not pid then
      io.write(tostring(err) .. "\n")
      cleanup()
      for _, p2 in ipairs(pids) do freax.wait(p2) end
      return 127
    end
    pids[#pids + 1] = pid
    prevR = nextR
  end
  cleanup() -- children hold dups; closing ours signals EOF downstream
  if bg then
    local job = { id = nextJob, pids = pids, line = line or "" }
    nextJob = nextJob + 1
    jobs[#jobs + 1] = job
    io.write(string.format("[%d] %s\n", job.id,
      table.concat(pids, ",")))
    return 0
  end
  return reap()
end

runDepth = 0
function runLine(line, depth)
  depth = depth or 0
  if depth > 10 then io.write("sh: source nesting too deep\n") return 1 end
  runDepth = depth
  local toks = tokenize(line)
  if toks[1] and shell.getAlias(toks[1]) then
    toks = tokenize(shell.getAlias(toks[1]) .. " " .. line:sub(#toks[1] + 1))
  end
  if #toks == 0 then return 0 end
  local cmds, err = splitCommands(toks)
  if not cmds then
    io.write("sh: " .. tostring(err) .. "\n")
    return 2
  end
  local code = 0
  local prevAfter = nil
  for _, cmd in ipairs(cmds) do
    local run = true
    if prevAfter == "&&" and code ~= 0 then run = false end
    if prevAfter == "||" and code == 0 then run = false end
    if run then
      local stages = cmd.stages
      if #stages == 1 and builtins[stages[1].args[1] or ""] then
        local st = stages[1]
        local args = {}
        for i = 2, #st.args do args[#args + 1] = st.args[i] end
        code = runBuiltin(builtins[st.args[1]], args, st) or 0
      else
        code = runExternal(stages, cmd.bg, line)
      end
    end
    prevAfter = cmd.after
  end
  return code
end

-- Single-source version: /VERSION (apt-kept), fallback for old media.
local _ver = "0.6"
do
  local data = fs.readFile("/VERSION")
  if data and data:match("%S+") then _ver = data:match("%S+") end
end
term.writeln("FREAX " .. _ver .. " -- welcome, " .. (os.getenv("USER") or "root"))

local function hostname()
  if not _hostname then
    local data = fs.readFile("/etc/hostname")
    _hostname = (data and data:match("%S+")) or "freax"
  end
  return _hostname
end

while true do
  local user = os.getenv("USER") or "root"
  local sym = (user == "root") and "#" or "$"
  term.write(user .. "@" .. hostname() .. ":" .. freax.getCwd() .. sym .. " ")
  runLine(term.readLine(), 0)
end
