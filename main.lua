-- ============================================================
-- FREAX kernel (M0)
-- Owns: hardware, process table, scheduler, syscall table.
--
-- A process is a coroutine + a private environment (_ENV).
-- Processes never see component/computer; they touch hardware
-- only through the freax.* syscalls implemented here.
--
-- Preemption honesty: the OC runtime itself kills any script that
-- runs too long without yielding. That error unwinds through the
-- offending coroutine only, so the hog dies and the kernel lives.
-- ============================================================

local computer  = computer
local component = component
-- Host-provided pure libs (no authority): passed into processes as-is.
local hostUnicode = unicode
local hostLoad, hostLoadfile, hostDofile = load, loadfile, dofile

local K = {}

local procs    = {}
local nextPid  = 1
local bootfs, readFile   -- injected by init()
local bootaddr = nil

-- Kernel log ring for dmesg (M2 compat).
local klogRing, klogMax = {}, 64
local function klogPush(msg)
  klogRing[#klogRing + 1] = string.format("[%.1f] %s", computer.uptime(), tostring(msg))
  if #klogRing > klogMax then table.remove(klogRing, 1) end
end

-- Shared terminal cursor (M2 compat). Single terminal, foreground-
-- serialized input, so one global cursor is correct: a child continues
-- where the shell left off instead of restarting at 1,1.
local termSt = { cx = 1, cy = 1, hist = {}, histPos = 0,
  blink = true, curOn = false, savedX = 0, savedY = 0, savedCh = " ", phase = -1 }

---------------------------------------------------------------
-- VFS (M1, inspired by OpenOS lib/filesystem.lua, simplified)
-- No symlinks / bind mounts yet. Flat mount table: path -> proxy.
-- Longest-prefix match. Paths canonicalized (., .., //).
---------------------------------------------------------------

local mounts = {}   -- array of {path=..., proxy=..., addr=...}
local fds = {}
local nextFd = 1

local function vfsSegments(path)
  local parts = {}
  for part in tostring(path):gmatch("[^/\\]+") do
    if part == "." or part == "" then
      -- skip
    elseif part == ".." then
      if #parts > 0 then table.remove(parts) end
    else
      parts[#parts + 1] = part
    end
  end
  return parts
end

local function vfsCanonical(path)
  path = tostring(path or "")
  local abs = path:sub(1, 1) == "/"
  local parts = vfsSegments(path)
  local res = table.concat(parts, "/")
  if abs then return "/" .. res end
  return res
end

local function vfsConcat(...)
  local n = select("#", ...)
  local pieces = {}
  for i = 1, n do pieces[#pieces + 1] = tostring(select(i, ...)) end
  return vfsCanonical(table.concat(pieces, "/"))
end

local function vfsName(path)
  local parts = vfsSegments(path)
  return parts[#parts]
end

local function vfsDir(path)
  local canon = vfsCanonical(path)
  if canon == "/" then return "/" end
  local parts = vfsSegments(canon)
  table.remove(parts)
  if path:sub(1,1) == "/" or canon:sub(1,1) == "/" then
    return "/" .. table.concat(parts, "/")
  end
  return table.concat(parts, "/")
end

local function vfsAbs(path, cwd)
  path = tostring(path or "")
  if path:sub(1, 1) == "/" then return vfsCanonical(path) end
  return vfsCanonical(vfsConcat(cwd or "/", path))
end

-- longest-prefix mount match; returns proxy, rest, mountPath, addr
local function vfsResolve(absPath)
  absPath = vfsCanonical(absPath)
  local best, bestRest, bestPath, bestAddr
  local bestLen = -1
  for _, m in ipairs(mounts) do
    local mp = m.path
    local match, rest
    if mp == "/" then
      match = true
      rest = absPath:sub(2) -- strip leading /
    elseif absPath == mp or absPath:sub(1, #mp + 1) == mp .. "/" then
      match = true
      rest = absPath:sub(#mp + 2)
    end
    if match and #mp > bestLen then
      best, bestRest, bestPath, bestAddr = m.proxy, rest or "", mp, m.addr
      bestLen = #mp
    end
  end
  return best, bestRest, bestPath, bestAddr
end

local function vfsMount(proxy, path, addr)
  path = vfsCanonical(path)
  if path == "" then path = "/" end
  for _, m in ipairs(mounts) do
    if m.path == path then m.proxy, m.addr = proxy, addr return true end
  end
  mounts[#mounts + 1] = { path = path, proxy = proxy, addr = addr }
  return true
end

local function vfsMounts()
  local out = {}
  for _, m in ipairs(mounts) do
    out[#out + 1] = { path = m.path, addr = m.addr }
  end
  return out
end

-- forward: symlink expansion (defined below) used by vfsReadFile
local expandLinks
-- read whole file via VFS (kernel-private, no fd leak; follows links)
local function vfsReadFile(absPath)
  local exp = expandLinks(absPath, true) or absPath
  local proxy, rest = vfsResolve(exp)
  if not proxy then return nil end
  local ok, h = pcall(proxy.open, rest, "r")
  if not ok or not h then return nil end
  local data = ""
  while true do
    local rok, chunk = pcall(proxy.read, h, 4096)
    if not rok or not chunk then break end
    data = data .. chunk
  end
  pcall(proxy.close, h)
  return data
end

---------------------------------------------------------------
-- Virtual symlinks (M2). OC filesystems have no link concept,
-- so like OpenOS the kernel overlays a RAM table on the namespace:
-- links[canonicalAbsPath] = rawTarget (absolute or linkdir-relative).
-- Lost on reboot, exactly like OpenOS virtual links.
---------------------------------------------------------------

local links = {}

-- Expand links in an absolute canonical path. followFinal=false
-- leaves a final-component link in place (lstat behavior).
expandLinks = function(absPath, followFinal)
  local cur = absPath
  local seen = {}
  for _ = 1, 40 do
    if seen[cur] then return nil, "link cycle detected" end
    seen[cur] = true
    local best
    for lp in pairs(links) do
      local isFull = (cur == lp)
      local isPrefix = (cur:sub(1, #lp + 1) == lp .. "/")
      if (isPrefix or (isFull and followFinal))
        and (not best or #lp > #best) then
        best = lp
      end
    end
    if not best then return cur end
    local rest = cur:sub(#best + 1) -- "" or "/..."
    local tgt = links[best]
    local base
    if tgt:sub(1, 1) == "/" then base = tgt
    else base = vfsConcat(vfsDir(best), tgt) end
    cur = vfsCanonical(base .. rest)
  end
  return nil, "too many levels of symbolic links"
end

---------------------------------------------------------------
-- Pipes + fd ownership (M2). fds entries carry .owner (pid).
-- Pipes are kernel-buffered (8K cap, blocking both ends).
-- fds are process-scoped by ownership: the reaper closes leftovers,
-- and cross-process sharing always dups (pipes) or reopens (files).
---------------------------------------------------------------

local PIPE_MAX = 8192

local function pipeRead(st, n, p)
  n = n or 4096
  while true do
    if #st.buf > 0 then
      local r = st.buf:sub(1, n)
      st.buf = st.buf:sub(#r + 1)
      return r
    end
    if st.wopen == 0 then return nil end -- EOF
    p.pipeWait = st
    coroutine.yield()
    p.pipeWait = nil
  end
end

local function pipeWrite(st, data, p)
  if st.ropen == 0 then return nil, "broken pipe" end
  local i = 1
  while i <= #data do
    while #st.buf >= PIPE_MAX do
      if st.ropen == 0 then return nil, "broken pipe" end
      p.pipeWait = st
      coroutine.yield()
      p.pipeWait = nil
    end
    if st.ropen == 0 then return nil, "broken pipe" end
    local room = PIPE_MAX - #st.buf
    st.buf = st.buf .. data:sub(i, i + room - 1)
    i = i + room
  end
  return true
end

local function closeFdEntry(e)
  if e.proxy then
    pcall(e.proxy.close, e.h)
  elseif e.pipe then
    if e.pend == "w" then e.pipe.wopen = e.pipe.wopen - 1
    else e.pipe.ropen = e.pipe.ropen - 1 end
  elseif e.net then
    pcall(e.net.close)
  elseif e.sock then
    pcall(e.sock.close)
  end
end

local function closeOwnedFds(pid)
  for fd, e in pairs(fds) do
    if e.owner == pid then
      closeFdEntry(e)
      fds[fd] = nil
    end
  end
end

-- Duplicate a pipe end into another process (refcount via open counters).
local function dupPipeFd(fd, newPid)
  local e = fds[fd]
  if not e or not e.pipe then return nil end
  local nfd = nextFd
  nextFd = nextFd + 1
  fds[nfd] = { pipe = e.pipe, pend = e.pend, owner = newPid }
  if e.pend == "w" then e.pipe.wopen = e.pipe.wopen + 1
  else e.pipe.ropen = e.pipe.ropen + 1 end
  return nfd
end

-- File/pipe handle shared by io.open, spawn stdio and wrapFd.
local function kernelNewHandle(fd, p)
  local h = { _fd = fd, _buf = "", _eof = false, _closed = false, _isfile = true }
  local function fillFile()
    if h._eof then return end
    local e = fds[fd]
    if not e then h._eof = true return end
    if e.sock then
      local ok, chunk = pcall(e.sock.read, 4096)
      if not ok or not chunk then h._eof = true return end
      h._buf = h._buf .. chunk
      return
    end
    if not e.proxy then h._eof = true return end
    local ok, chunk = pcall(e.proxy.read, e.h, 4096)
    if not ok or not chunk then h._eof = true return end
    h._buf = h._buf .. chunk
  end
  local function fillPipe()
    if h._eof then return end
    local e = fds[fd]
    if not e or not e.pipe then h._eof = true return end
    local chunk = pipeRead(e.pipe, 4096, p)
    if not chunk then h._eof = true return end
    h._buf = h._buf .. chunk
  end
  function h:read(fmt)
    if self._closed then return nil, "closed" end
    local e = fds[fd]
    if not e then self._closed = true return nil, "closed" end
    fmt = fmt or "*l"
    local fill = e.pipe and fillPipe or fillFile
    if type(fmt) == "number" then
      while #self._buf < fmt and not self._eof do fill() end
      if #self._buf == 0 then return nil end
      local r = self._buf:sub(1, fmt)
      self._buf = self._buf:sub(#r + 1)
      return r
    elseif fmt == "*a" then
      while not self._eof do fill() end
      if #self._buf == 0 then return nil end
      local r = self._buf
      self._buf = ""
      return r
    elseif fmt == "*l" or fmt == "*L" then
      while not self._eof do
        if self._buf:find("\n", 1, true) then break end
        fill()
      end
      if #self._buf == 0 then return nil end
      local i = self._buf:find("\n", 1, true)
      local r
      if i then
        r = self._buf:sub(1, i - 1)
        self._buf = self._buf:sub(i + 1)
      else
        r = self._buf
        self._buf = ""
      end
      if fmt == "*L" and i then r = r .. "\n" end
      return r
    end
    return nil, "not supported"
  end
  function h:lines(...)
    local fmts = table.pack(...)
    if fmts.n == 0 then fmts = { "*l" } end
    return function()
      return self:read(table.unpack(fmts, 1, fmts.n))
    end
  end
  function h:write(...)
    if self._closed then return nil, "closed" end
    local e = fds[fd]
    if not e then self._closed = true return nil, "closed" end
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local data = table.concat(parts)
    if e.pipe then
      local ok, err = pipeWrite(e.pipe, data, p)
      if not ok then return nil, tostring(err) end
      return self
    end
    if e.sock then
      local rest = data
      while #rest > 0 do
        local ok, n = pcall(e.sock.write, rest)
        if not ok or not n then return nil, tostring(n) end
        rest = rest:sub((n or 0) + 1)
        if (n or 0) <= 0 then break end
      end
      return self
    end
    local i = 1
    while i <= #data do
      local ok, r = pcall(e.proxy.write, e.h, data:sub(i, i + 8191))
      if not ok or not r then return nil, "write failed" end
      i = i + 8192
    end
    return self
  end
  function h:close()
    if self._closed then return true end
    self._closed = true
    local e = fds[fd]
    if e then closeFdEntry(e) fds[fd] = nil end
    return true
  end
  function h:flush() return true end
  function h:seek() return nil, "not supported" end
  return h
end

---------------------------------------------------------------
-- Hardware (kernel-private)
---------------------------------------------------------------

-- forward: block-cursor primitives (defined in the tty section below)
local ttyHideCursor, ttyShowCursor, ttyCursorTick
-- forward: merged input take (defined with the input model below)
local takeMerged

local gpu, gpuAddr
local function gpu0()
  if not gpu then
    local addr = component.list("gpu")()
    if addr then gpu, gpuAddr = component.proxy(addr), addr end
  end
  return gpu
end

-- Kernel console: one dedicated line (row 1) for kernel messages.
function K.klog(msg)
  klogPush(msg)
  local g = gpu0()
  if g then
    ttyHideCursor()
    g.setForeground(0xFFAA00)
    g.set(1, 1, "[freax] " .. tostring(msg))
    g.setForeground(0xFFFFFF)
    ttyShowCursor()
  end
end

function K.panic(msg)
  local g = gpu0()
  if g then
    ttyHideCursor()
    g.setForeground(0xFF0000)
    g.set(1, 1, "KERNEL PANIC: " .. tostring(msg))
    g.setForeground(0xFFFFFF)
  end
  error("freax panic: " .. tostring(msg))
end

---------------------------------------------------------------
-- Shared terminal (M2 compat). One screen, foreground jobs, so
-- one global cursor: children continue where the shell left off.
-- Same crude scroll as the old term lib (clear on overflow).
---------------------------------------------------------------

local function ttySize()
  local g = gpu0()
  if g then return g.getResolution() end
  return 80, 25
end

local function ttyNewline()
  local g = gpu0()
  local w, h = ttySize()
  ttyHideCursor()
  termSt.cx = 1
  if termSt.cy < h then
    termSt.cy = termSt.cy + 1
  else
    if g then g.fill(1, 1, w, h, " ") end
    termSt.cx, termSt.cy = 1, 1
  end
  ttyShowCursor()
end

local function ttyWrite(s)
  local g = gpu0()
  if not g then return end
  ttyHideCursor()
  local w = ttySize()
  s = tostring(s)
  -- Segment writes: one g.set per wrap-limited run, no per-char
  -- string buildup (run..ch is O(n^2) garbage and OOMs low-RAM
  -- machines on long lines). Layout matches per-char writes.
  local i, n = 1, #s
  while i <= n do
    local nl = s:find("\n", i, true)
    local segEnd = nl and (nl - 1) or n
    while i <= segEnd do
      if termSt.cx > w then ttyNewline() end
      local room = w - termSt.cx + 1
      local j = math.min(segEnd, i + room - 1)
      g.set(termSt.cx, termSt.cy, s:sub(i, j))
      termSt.cx = termSt.cx + (j - i + 1)
      i = j + 1
      if termSt.cx > w and i <= segEnd then ttyNewline() end
    end
    if nl then
      ttyNewline()
      i = nl + 1
    end
  end
  ttyShowCursor()
end

local function ttyClear()
  local g = gpu0()
  ttyHideCursor()
  if g then local w, h = ttySize() g.fill(1, 1, w, h, " ") end
  termSt.cx, termSt.cy = 1, 1
  ttyShowCursor()
end

local function ttyClearLine()
  local g = gpu0()
  ttyHideCursor()
  if g then local w = ttySize() g.fill(1, termSt.cy, w, 1, " ") end
  termSt.cx = 1
  ttyShowCursor()
end

-- Block cursor with blink. The underlying cell is saved via gpu.get
-- and restored on hide/move, so output never leaves cursor artifacts.
function ttyHideCursor()
  if not termSt.curOn then return end
  termSt.curOn = false
  local g = gpu0()
  if g then
    pcall(g.setForeground, 0xFFFFFF)
    pcall(g.setBackground, 0x000000)
    pcall(g.set, termSt.savedX, termSt.savedY, termSt.savedCh)
  end
end

function ttyShowCursor()
  local g = gpu0()
  if not g or not termSt.blink then return end
  local w, h = ttySize()
  local cx = math.max(1, math.min(termSt.cx, w))
  local cy = math.max(1, math.min(termSt.cy, h))
  if termSt.curOn and termSt.savedX == cx and termSt.savedY == cy then
    return -- already shown here: no flicker
  end
  ttyHideCursor()
  local ok, ch = pcall(g.get, cx, cy)
  termSt.savedX, termSt.savedY = cx, cy
  termSt.savedCh = (ok and type(ch) == "string") and ch or " "
  pcall(g.setForeground, 0x000000)
  pcall(g.setBackground, 0xFFFFFF)
  pcall(g.set, cx, cy, termSt.savedCh)
  pcall(g.setForeground, 0xFFFFFF)
  pcall(g.setBackground, 0x000000)
  termSt.curOn = true
end

-- Called every scheduler tick + after each output op. Cheap: one
-- uptime() and a compare; touches the GPU only on phase change.
function ttyCursorTick()
  if not termSt.blink then
    ttyHideCursor()
    return
  end
  local phase = math.floor(computer.uptime() * 2) % 2
  if phase ~= termSt.phase then
    termSt.phase = phase
    if phase == 0 then ttyShowCursor() else ttyHideCursor() end
  end
end

-- Blocking line reader for process p (history shared, one terminal).
-- mask (string, or true for "*"): echo mask instead of input, skip
-- history and recall, for password fields.
local function ttyReadLine(p, mask)
  local g = gpu0()
  local buf = ""
  local sx, sy = termSt.cx, termSt.cy
  local w = ttySize()
  local echo = (mask == true and "*")
    or (type(mask) == "string" and mask ~= "" and mask) or nil
  ttyHideCursor()
  local function shown()
    return echo and echo:rep(#buf) or buf
  end
  local function redraw()
    if not g then termSt.cx = sx + #buf return end
    ttyHideCursor()
    g.fill(sx, sy, w - sx + 1, 1, " ")
    g.set(sx, sy, shown())
    termSt.cx = sx + #buf
    ttyShowCursor()
  end
  while true do
    local sig = takeMerged(p)
    while not sig do
      coroutine.yield()
      sig = takeMerged(p)
    end
    local name, _, char, code = table.unpack(sig, 1, sig.n)
    if name == "key_down" then
      if code == 28 then                       -- enter
        termSt.cx = sx + #buf
        ttyNewline()
        if not echo then
          termSt.hist[#termSt.hist + 1] = buf
          termSt.histPos = #termSt.hist + 1
        end
        return buf
      elseif code == 14 then                   -- backspace
        if #buf > 0 then
          buf = buf:sub(1, -2)
          redraw()
        end
      elseif code == 200 and not echo then     -- up: older (off in pw fields)
        if termSt.histPos > 1 then
          termSt.histPos = termSt.histPos - 1
          buf = termSt.hist[termSt.histPos] or ""
          redraw()
        end
      elseif code == 208 and not echo then     -- down: newer (off in pw fields)
        if termSt.histPos <= #termSt.hist then
          termSt.histPos = termSt.histPos + 1
          buf = termSt.hist[termSt.histPos] or ""
          redraw()
        end
      elseif char and char > 0 then            -- printable
        buf = buf .. string.char(char)
        ttyHideCursor()
        if g then g.set(termSt.cx, termSt.cy, echo or string.char(char)) end
        termSt.cx = termSt.cx + 1
        ttyShowCursor()
      end
    end
  end
end

-- Input model: ONE shared keyboard queue (key_down/key_up/clipboard),
-- like a Unix tty buffer -- whoever pulls first consumes each keystroke
-- exactly once, so typeahead survives foreground waits but interactive
-- children can't leave stale duplicates behind for the next reader.
-- All other signals keep per-process broadcast queues. Global arrival
-- order across both queues is preserved via sequence numbers.
local keyQueue = {}
local sigSeq = 0

local function isKeySig(s)
  return s[1] == "key_down" or s[1] == "key_up" or s[1] == "clipboard"
end

-- Non-blocking take honoring global arrival order. Returns packed sig or nil.
takeMerged = function(p)
  local ksig, qsig = keyQueue[1], p.queue[1]
  if ksig and (not qsig or (ksig.seq or 0) <= (qsig.seq or 0)) then
    table.remove(keyQueue, 1)
    return ksig
  elseif qsig then
    table.remove(p.queue, 1)
    return qsig
  end
  return nil
end

-- Blocking pull shared by pullEvent.
local function procPull(p)
  while true do
    local sig = takeMerged(p)
    if sig then return table.unpack(sig, 1, sig.n) end
    coroutine.yield()
  end
end

---------------------------------------------------------------
-- Environments and syscalls
---------------------------------------------------------------

-- Build the private environment (_ENV) for process p.
-- Deliberately absent: component, debug, loadstring, dofile fallback,
-- _G, and global require. Present in safe forms: computer (info-only
-- subset), os (per-process env + clock + VFS-backed remove/rename),
-- io (fd/tty-backed), unicode (pure), load/loadfile (process env).
local function makeEnv(p)
  local env = {}

  -- standard library subset
  env.string       = string
  env.table        = table
  env.math         = math
  env.bit32        = bit32
  env.coroutine    = coroutine
  env.assert       = assert
  env.error        = error
  env.ipairs       = ipairs
  env.next         = next
  env.pairs        = pairs
  env.pcall        = pcall
  env.xpcall       = xpcall
  env.select       = select
  env.tostring     = tostring
  env.tonumber     = tonumber
  env.type         = type
  env.unpack       = table.unpack
  env.setmetatable = setmetatable
  env.getmetatable = getmetatable
  env.rawget       = rawget
  env.rawset       = rawset
  env.rawequal     = rawequal
  env.rawlen       = rawlen

  local freax = {}

  -- snapshot of my env/cwd for a child (copy: child edits never leak up)
  local function myInh()
    local c = {}
    for k, v in pairs(p.vars or {}) do c[k] = v end
    return { vars = c, cwd = p.cwd or "/" }
  end

  ---- process control ----
  function freax.getpid() return p.pid end

  function freax.exit()
    p.dead = true
    coroutine.yield()          -- never returns; scheduler reaps us
  end

  function freax.spawn(name, path, args)
    return K.spawn(name, path, args, nil, myInh())
  end

  function freax.ps()
    local out = {}
    for _, q in ipairs(procs) do
      out[#out + 1] = { pid = q.pid, name = q.name, dead = q.dead or false }
    end
    return out
  end

  -- Foreground wait: shell uses this so interactive children (install)
  -- own the keyboard. No input is consumed here, so no echo fights.
  -- Returns the child's exit code (0 ok, 1 error) for && and ||.
  function freax.wait(pid)
    p.waitingFor = pid
    local code = 0
    while true do
      local found
      for _, q in ipairs(procs) do
        if q.pid == pid then found = q break end
      end
      if not found or found.dead then
        if found and found.exitCode then code = found.exitCode end
        p.waitingFor = nil
        return code
      end
      coroutine.yield() -- scheduler resumes waiters every tick, no signal needed
    end
  end

  ---- events ----
  -- M0 contract: the ONLY yield points in a process are here,
  -- freax.wait, ttyReadLine and freax.exit. Scheduler relies on this.
  function freax.pullEvent()
    return procPull(p)
  end

  -- Non-blocking drain for timeout loops (computer.pullSignal etc.).
  -- Returns nil when empty, else unpacked signal like pullEvent.
  function freax.pollEvent()
    local sig = takeMerged(p)
    if not sig then return nil end
    return table.unpack(sig, 1, sig.n)
  end

  -- Non-destructive merged peek: lets timeout loops (sleep, timed
  -- pulls) wait without eating keystrokes meant for someone else.
  function freax.peekEvent()
    local ksig, qsig = keyQueue[1], p.queue[1]
    local sig = nil
    if ksig and (not qsig or (ksig.seq or 0) <= (qsig.seq or 0)) then
      sig = ksig
    else
      sig = qsig
    end
    if not sig then return nil end
    return table.unpack(sig, 1, sig.n)
  end

  function freax.sleep(sec)
    local deadline = computer.uptime() + (sec or 0)
    while computer.uptime() < deadline do
      if freax.peekEvent() then coroutine.yield() else procPull(p) end
    end
  end

  function freax.uptime() return computer.uptime() end

  ---- video (kernel-mediated) ----
  function freax.gpuSet(x, y, s)
    local g = gpu0(); if g then return g.set(x, y, s) end
  end
  function freax.gpuFill(x, y, wc, hc, c)
    local g = gpu0(); if g then return g.fill(x, y, wc, hc, c) end
  end
  function freax.gpuSize()
    local g = gpu0(); if g then return g.getResolution() end
    return 80, 25
  end

  ---- filesystem (M1 VFS, inspired by OpenOS) ----
  function freax.getCwd() return p.cwd or "/" end
  function freax.setCwd(path)
    local abs = vfsAbs(path, p.cwd or "/")
    local proxy, rest = vfsResolve(abs)
    if not proxy then return nil, "no such directory" end
    local ok, isDir
    if rest == "" then isDir = true
    else ok, isDir = pcall(proxy.isDirectory, rest) end
    if ok ~= false and isDir then p.cwd = abs return true end
    return nil, "not a directory"
  end
  function freax.fsCanonical(path) return vfsCanonical(path) end
  function freax.fsConcat(...) return vfsConcat(...) end
  function freax.fsName(path) return vfsName(path) end
  function freax.fsDir(path) return vfsDir(path) end
  function freax.fsResolve(path)
    local abs = vfsAbs(path, p.cwd or "/")
    local _, rest, mp, addr = vfsResolve(abs)
    return abs, rest, mp, addr
  end
  local function withProxy(path, followFinal)
    local abs = vfsAbs(path, p.cwd or "/")
    if followFinal == nil then followFinal = true end
    local exp, err = expandLinks(abs, followFinal)
    if not exp then return nil, nil, abs, err end
    local proxy, rest = vfsResolve(exp)
    return proxy, rest, exp
  end
  function freax.fsExists(path)
    -- lstat-style: a (possibly dangling) link itself exists.
    local proxy, rest, abs, err = withProxy(path, false)
    if not proxy then return false end
    if rest == "" then return true end -- mount point
    if links[abs] then return true end
    local ok, r = pcall(proxy.exists, rest)
    return ok and r or false
  end
  function freax.fsIsDir(path)
    local proxy, rest, _, err = withProxy(path)
    if not proxy then return nil, err or "no such file" end
    if rest == "" then return true end
    local ok, r = pcall(proxy.isDirectory, rest)
    if not ok then return nil, tostring(r) end
    if r then return true end
    -- false means file OR missing: tell them apart (OpenOS semantics).
    local ok2, ex = pcall(proxy.exists, rest)
    if ok2 and ex then return false end
    return nil, "no such file"
  end
  function freax.fsSize(path)
    local proxy, rest = withProxy(path)
    if not proxy or rest == "" then return 0 end
    local ok, r = pcall(proxy.size, rest)
    return (ok and r) or 0
  end
  function freax.fsList(path)
    local proxy, rest, abs, err = withProxy(path)
    if not proxy then return nil, err or "no such directory" end
    local ok, list = pcall(proxy.list, rest or "")
    local out = {}
    if ok and list then
      if type(list) == "table" then
        for _, n in ipairs(list) do out[#out + 1] = n end
      elseif type(list) == "function" then
        for n in list do out[#out + 1] = n end
      end
    end
    -- add virtual mount-point children (e.g. /mnt/xxx under /)
    for _, m in ipairs(mounts) do
      if m.path ~= abs then
        local dir = vfsDir(m.path)
        if dir == abs then
          local nm = vfsName(m.path) .. "/"
          local dup = false
          for _, e in ipairs(out) do if e == nm or e == nm:sub(1,-2) then dup = true break end end
          if not dup then out[#out + 1] = nm end
        end
      end
    end
    -- add virtual symlink children living directly under abs
    for lp in pairs(links) do
      if vfsDir(lp) == abs then
        local nm = vfsName(lp)
        local dup = false
        for _, e in ipairs(out) do
          if e == nm or e == nm .. "/" then dup = true break end
        end
        if not dup then out[#out + 1] = nm end
      end
    end
    -- add virtual symlink children living directly under abs
    for lp in pairs(links) do
      if vfsDir(lp) == abs then
        local nm = vfsName(lp)
        local dup = false
        for _, e in ipairs(out) do
          if e == nm or e == nm .. "/" then dup = true break end
        end
        if not dup then out[#out + 1] = nm end
      end
    end
    table.sort(out)
    return out
  end
  function freax.fsMakeDir(path)
    local proxy, rest, _, err = withProxy(path, false)
    if not proxy then return nil, err or "no such filesystem" end
    if rest == "" then return nil, "already exists" end
    local ok, r, err = pcall(proxy.makeDirectory, rest)
    if ok and r then return true end
    return nil, tostring(err or r)
  end
  function freax.fsRemove(path)
    -- never follows the final link: removing a link removes the link.
    local proxy, rest, abs, err = withProxy(path, false)
    if not proxy then return nil, err or "no such file" end
    if rest == "" then return nil, "cannot remove mount point" end
    if links[abs] then
      links[abs] = nil
      return true
    end
    local ok, r, err = pcall(proxy.remove, rest)
    if ok and r then return true end
    return nil, tostring(err or r or "failed")
  end
  function freax.fsOpen(path, mode)
    mode = tostring(mode or "r")
    local proxy, rest, _, err = withProxy(path)
    if not proxy then return nil, err or "no such filesystem" end
    if rest == "" then return nil, "is a directory" end
    local ok, h, err = pcall(proxy.open, rest, mode)
    if not ok or not h then return nil, tostring(err or h) end
    local fd = nextFd; nextFd = nextFd + 1
    fds[fd] = { proxy = proxy, h = h, owner = p.pid,
      path = vfsAbs(path, p.cwd or "/"), mode = mode }
    return fd
  end
  function freax.fsRead(fd, n)
    local e = fds[fd]
    if not e then return nil, "bad fd" end
    if e.pipe then return pipeRead(e.pipe, n or 4096, p) end
    if e.net then
      local ok, chunk = pcall(e.net.read)
      if not ok then return nil, tostring(chunk) end
      return chunk
    end
    if e.sock then
      local ok, chunk = pcall(e.sock.read, n or 4096)
      if not ok then return nil, tostring(chunk) end
      return chunk
    end
    local ok, chunk = pcall(e.proxy.read, e.h, n or 4096)
    if not ok then return nil, tostring(chunk) end
    return chunk
  end
  function freax.fsWrite(fd, data)
    local e = fds[fd]
    if not e then return nil, "bad fd" end
    if e.pipe then
      local ok, err = pipeWrite(e.pipe, tostring(data), p)
      if not ok then return nil, tostring(err) end
      return true
    end
    if e.net then return nil, "response stream is read-only" end
    if e.sock then
      local rest = tostring(data)
      while #rest > 0 do
        local ok, n = pcall(e.sock.write, rest)
        if not ok or not n then return nil, tostring(n) end
        rest = rest:sub((n or 0) + 1)
        if (n or 0) <= 0 then break end
      end
      return true
    end
    local ok, r, err = pcall(e.proxy.write, e.h, data)
    if ok and r then return true end
    return nil, tostring(err or r)
  end
  function freax.fsClose(fd)
    local e = fds[fd]
    if not e then return nil end
    closeFdEntry(e)
    fds[fd] = nil
    return true
  end
  function freax.fsMounts()
    local out = {}
    for _, m in ipairs(mounts) do out[#out + 1] = { path = m.path, addr = m.addr } end
    return out
  end
  function freax.fsDevices()
    local out = {}
    -- OpenOS excludes tmpfs from install candidates; flag it here.
    local tmpAddr = nil
    pcall(function()
      if computer.tmpAddress then tmpAddr = computer.tmpAddress() end
    end)
    for addr in component.list("filesystem") do
      local ok, proxy = pcall(component.proxy, addr)
      local label, total, used, ro = "", 0, 0, false
      if ok and proxy then
        pcall(function() label = proxy.getLabel() or "" end)
        pcall(function() total = proxy.spaceTotal() or 0 end)
        pcall(function() used = proxy.spaceUsed() or 0 end)
        pcall(function() ro = proxy.isReadOnly() end)
      end
      local mnt = nil
      for _, m in ipairs(mounts) do if m.addr == addr then mnt = m.path break end end
      out[#out + 1] = { addr = addr, label = label, total = total,
        used = used, readonly = not not ro, mount = mnt,
        boot = (addr == bootaddr), tmp = (tmpAddr ~= nil and addr == tmpAddr) }
    end
    return out
  end
  function freax.fsMount(addr, path)
    local ok, proxy = pcall(component.proxy, addr)
    if not ok or not proxy then return nil, "no such device" end
    vfsMount(proxy, vfsAbs(path, "/"), addr)
    return true
  end
  function freax.fsUmount(pathOrAddr)
    local key = tostring(pathOrAddr)
    local abs = vfsAbs(key, "/")
    for i, m in ipairs(mounts) do
      if m.path ~= "/" and (m.path == abs or m.addr == key
        or m.addr:sub(1, #key) == key) then
        table.remove(mounts, i)
        return true
      end
    end
    return nil, "not mounted"
  end

  ---- hardware inventory + mediated access (M2). Info calls are read-only;
  ---- actuating calls (redstone/eeprom/net/labels) are first-card syscalls.
  function freax.devices(filter)
    local out = {}
    local ok, it = pcall(component.list, filter)
    if ok and type(it) == "function" then
      for addr, typ in it do
        out[#out + 1] = { address = addr, type = typ }
      end
    end
    return out
  end
  function freax.deviceInfo()
    local ok, r = pcall(computer.getDeviceInfo)
    return (ok and type(r) == "table" and r) or {}
  end
  function freax.machineAddr()
    local ok, r = pcall(computer.address)
    return (ok and r) or ""
  end
  function freax.compDoc(addr, method)
    local ok, r = pcall(component.doc, addr, method)
    return (ok and r) or nil
  end
  function freax.primary(typ)
    if typ == "gpu" then return gpuAddr end
    if typ == "filesystem" then return bootaddr end
    return nil
  end
  -- redstone card 0: generic method call (input/output/bundled/wireless).
  local rsProxy
  function freax.rsAvail()
    if rsProxy then return true end
    local ok, it = pcall(component.list, "redstone")
    if ok and type(it) == "function" then
      for addr in it do
        local ok2, px = pcall(component.proxy, addr)
        if ok2 and px then rsProxy = px return true end
      end
    end
    return false
  end
  function freax.rs(method, ...)
    if not freax.rsAvail() then return nil, "no redstone card" end
    local fn = rsProxy[method]
    if type(fn) ~= "function" then return nil, "no such method" end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then return nil, tostring(a) end
    return a, b, c
  end
  -- eeprom (first found): flash/read/labels.
  local eeProxy, eeAddr
  local function ee()
    if eeProxy then return eeProxy, eeAddr end
    local ok, it = pcall(component.list, "eeprom")
    if ok and type(it) == "function" then
      for addr in it do
        local ok2, px = pcall(component.proxy, addr)
        if ok2 and px then eeProxy, eeAddr = px, addr return px, addr end
      end
    end
    return nil
  end
  function freax.eepromAddr() local _, a = ee() return a end
  function freax.eepromGet()
    local px = ee()
    if not px then return nil, "no eeprom" end
    local ok, r = pcall(px.get)
    return ok and r or nil, ok and nil or tostring(r)
  end
  function freax.eepromSet(data)
    local px = ee()
    if not px then return nil, "no eeprom" end
    local ok, r, err = pcall(px.set, data)
    if ok and not err then return true end
    return nil, tostring(err or r)
  end
  function freax.eepromLabel()
    local px = ee()
    if not px then return nil, "no eeprom" end
    local ok, r = pcall(px.getLabel)
    return ok and r or nil
  end
  function freax.eepromSetLabel(label)
    local px = ee()
    if not px then return nil, "no eeprom" end
    local ok, r, err = pcall(px.setLabel, label)
    if ok and not err then return true end
    return nil, tostring(err or r)
  end
  function freax.eepromSize()
    local px = ee()
    if not px then return 0 end
    local ok, r = pcall(px.getSize)
    return (ok and r) or 0
  end
  -- gpu resolution control (read via ttySize).
  function freax.gpuSetResolution(w, h)
    local g = gpu0()
    if not g then return nil, "no gpu" end
    local ok, r, err = pcall(g.setResolution, w, h)
    if ok and r ~= false then termSt.cx, termSt.cy = 1, 1 return true end
    return nil, tostring(err or r or "rejected")
  end
  -- filesystem labels by address prefix.
  local function fsProxyByAddr(addr)
    for _, m in ipairs(mounts) do
      if m.addr == addr or m.addr:sub(1, #addr) == addr then return m.proxy end
    end
    local ok, px = pcall(component.proxy, addr)
    return ok and px or nil
  end
  function freax.fsLabel(addr)
    local px = fsProxyByAddr(tostring(addr))
    if not px or not px.getLabel then return nil, "no such device" end
    local ok, r = pcall(px.getLabel)
    return ok and r or nil
  end
  function freax.fsSetLabel(addr, label)
    local px = fsProxyByAddr(tostring(addr))
    if not px or not px.setLabel then return nil, "no such device" end
    local ok, r, err = pcall(px.setLabel, label)
    if ok and not err then return true end
    return nil, tostring(err or r)
  end
  -- internet card 0: GET/POST via fds (read until nil, then close).
  local netProxy
  function freax.netAvail()
    if netProxy then return true end
    local ok, it = pcall(component.list, "internet")
    if ok and type(it) == "function" then
      for addr in it do
        local ok2, px = pcall(component.proxy, addr)
        if ok2 and px then netProxy = px return true end
      end
    end
    return false
  end
  function freax.netRequest(url, post, headers, method)
    if not freax.netAvail() then return nil, "no internet card" end
    local ok, h, err = pcall(netProxy.request, url, post, headers, method)
    if not ok or not h then return nil, tostring(err or h) end
    local fd = nextFd
    nextFd = nextFd + 1
    fds[fd] = { net = h, owner = p.pid }
    return fd
  end
  function freax.netResponse(fd)
    local e = fds[fd]
    if not e or not e.net or not e.net.response then
      return nil, "bad net fd"
    end
    local ok, a, b, c = pcall(e.net.response)
    if not ok then return nil, tostring(a) end
    return a, b, c
  end
  function freax.netFinish(fd)
    local e = fds[fd]
    if not e or not e.net then return nil, "bad net fd" end
    if not e.net.finishConnect then return true end
    local ok, r = pcall(e.net.finishConnect)
    return ok and true or nil, ok and nil or tostring(r)
  end
  -- Raw TCP (internet.socket): streams support read AND write.
  function freax.netConnect(address)
    if not freax.netAvail() then return nil, "no internet card" end
    local ok, h, err = pcall(netProxy.connect, address)
    if not ok or not h then return nil, tostring(err or h) end
    local fd = nextFd
    nextFd = nextFd + 1
    fds[fd] = { sock = h, owner = p.pid }
    return fd
  end
  -- Pipes (M2): kernel-buffered, blocking both ends, 8K cap.
  function freax.pipe()
    local st = { buf = "", wopen = 1, ropen = 1 }
    local rfd, wfd = nextFd, nextFd + 1
    nextFd = nextFd + 2
    fds[rfd] = { pipe = st, pend = "r", owner = p.pid }
    fds[wfd] = { pipe = st, pend = "w", owner = p.pid }
    return rfd, wfd
  end
  -- Wrap one of my own fds as an io handle (for popen/pipeline parents).
  function freax.wrapFd(fd)
    local e = fds[fd]
    if not e or e.owner ~= p.pid then return nil, "bad fd" end
    return kernelNewHandle(fd, p)
  end
  -- Spawn with redirected stdio: fds (pipes) or {path, mode} specs.
  -- (myInh is defined once near the top of makeEnv.)
  function freax.spawnIO(name, path, args, inFd, outFd, errFd)
    return K.spawn(name, path, args, { in_ = inFd, out = outFd, err = errFd }, myInh())
  end
  function freax.myInfo()
    return { pid = p.pid, name = p.name, vars = p.vars }
  end
  -- Single-user root: any process may reap any other (jobs, kill).
  function freax.kill(pid)
    for _, q in ipairs(procs) do
      if q.pid == pid then
        q.dead = true
        return true
      end
    end
    return nil, "no such process"
  end
  -- Speaker passthrough (harmless output, like the screen).
  function freax.beep(freq, dur)
    local ok, r = pcall(computer.beep, freq or 440, dur or 0.2)
    return ok and true or nil, ok and nil or tostring(r)
  end
  function freax.getBootAddr() return bootaddr end
  function freax.setBootAddr(addr)
    -- computer.setBootAddress returns nothing on success in OC,
    -- so "no throw" counts as success; only false/exception is failure.
    local ok, r = pcall(computer.setBootAddress, addr)
    if not ok then return nil, tostring(r) end
    if r == false then return nil, "rejected" end
    return true
  end
  function freax.reboot() pcall(computer.shutdown, true) end
  function freax.shutdown() pcall(computer.shutdown, false) end

  ---- machine info (safe, read-only; for computer shim + free/uptime) ----
  function freax.freeMem()
    local ok, r = pcall(computer.freeMemory)
    return (ok and r) or 0
  end
  function freax.totalMem()
    local ok, r = pcall(computer.totalMemory)
    return (ok and r) or 0
  end
  function freax.tmpAddr()
    local ok, r = pcall(function() return computer.tmpAddress() end)
    return (ok and r) or nil
  end
  function freax.dmesg()
    local out = {}
    for i, l in ipairs(klogRing) do out[i] = l end
    return out
  end

  ---- rename (same-fs proxy rename, else copy + remove) ----
  function freax.fsRename(oldPath, newPath)
    local function absOf(pp) return vfsAbs(pp, p.cwd or "/") end
    -- renaming a link renames the link itself (OpenOS semantics)
    local oNoFollow, oErr = expandLinks(absOf(oldPath), false)
    if not oNoFollow then return nil, oErr end
    local nNoFollow, nErr = expandLinks(absOf(newPath), false)
    if not nNoFollow then return nil, nErr end
    if links[oNoFollow] then
      links[nNoFollow] = links[oNoFollow]
      links[oNoFollow] = nil
      return true
    end
    -- overwriting a link removes the link first (no stale shadows)
    if links[nNoFollow] then links[nNoFollow] = nil end
    local oAbs, nAbs = oNoFollow, expandLinks(absOf(newPath), true)
    if not nAbs then return nil, nErr end
    local oProxy, oRest = vfsResolve(oAbs)
    local nProxy, nRest = vfsResolve(nAbs)
    if not oProxy or not nProxy then return nil, "no such filesystem" end
    if oRest == "" or nRest == "" then return nil, "cannot rename mount point" end
    local _, _, _, oAddr = vfsResolve(oAbs)
    local _, _, _, nAddr = vfsResolve(nAbs)
    if oAddr == nAddr then
      local ok, r, err = pcall(oProxy.rename, oRest, nRest)
      if ok and r then return true end
      return nil, tostring(err or r or "rename failed")
    end
    -- cross-device: stream copy then remove source
    local ok, ih = pcall(oProxy.open, oRest, "r")
    if not ok or not ih then return nil, "cannot read source" end
    local ok2, oh = pcall(nProxy.open, nRest, "w")
    if not ok2 or not oh then pcall(oProxy.close, ih) return nil, "cannot write target" end
    while true do
      local rok, chunk = pcall(oProxy.read, ih, 4096)
      if not rok or not chunk then break end
      local wok = pcall(nProxy.write, oh, chunk)
      if not wok then break end
    end
    pcall(oProxy.close, ih)
    pcall(nProxy.close, oh)
    pcall(oProxy.remove, oRest)
    return true
  end

  function freax.fsLink(target, linkpath)
    if type(target) ~= "string" or target == "" then
      return nil, "bad target"
    end
    local abs = vfsAbs(tostring(linkpath), p.cwd or "/")
    local exp, err = expandLinks(abs, false)
    if not exp then return nil, err end
    -- the link itself must not exist (physical or virtual)
    if links[exp] then return nil, "file already exists" end
    local proxy, rest = vfsResolve(exp)
    if not proxy then return nil, "no such filesystem" end
    if rest == "" then return nil, "cannot link a mount point" end
    local ok, already = pcall(proxy.exists, rest)
    if ok and already then return nil, "file already exists" end
    -- parent must be a real directory
    local parent = vfsDir(exp)
    local pExp, pErr = expandLinks(parent, true)
    if not pExp then return nil, pErr end
    local pProxy, pRest = vfsResolve(pExp)
    local isDir = false
    if pProxy then
      if pRest == "" then isDir = true
      else
        local ok2, r2 = pcall(pProxy.isDirectory, pRest)
        isDir = ok2 and r2
      end
    end
    if not isDir then return nil, "no such directory" end
    links[exp] = target -- stored raw; relative targets resolve at follow time
    return true
  end

  function freax.fsIsLink(path)
    local abs = vfsAbs(tostring(path), p.cwd or "/")
    local exp, err = expandLinks(abs, false)
    if not exp then return nil, err end
    if links[exp] then return true, links[exp] end
    return false
  end

  ---- shared terminal syscalls (one screen, see termSt) ----
  function freax.ttyWrite(s) ttyWrite(s) return true end
  function freax.ttyClear() ttyClear() return true end
  function freax.ttyClearLine() ttyClearLine() return true end
  function freax.ttySetCursor(x, y)
    ttyHideCursor()
    termSt.cx, termSt.cy = x, y
    ttyShowCursor()
    return true
  end
  function freax.ttySetBlink(on)
    termSt.blink = not not on
    if not termSt.blink then ttyHideCursor() end
    return true
  end
  function freax.ttyGetCursor() return termSt.cx, termSt.cy end
  function freax.ttySize() return ttySize() end
  function freax.ttyReadLine(mask) return ttyReadLine(p, mask) end

  env.freax = freax

  ---- safe globals for OpenOS compat (M2). Pure or kernel-mediated. ----
  env.unicode = hostUnicode

  function env.checkArg(n, val, ...)
    local exp = table.pack(...)
    for i = 1, exp.n do
      if type(val) == exp[i] then return end
    end
    error(string.format("bad argument #%d (%s expected, got %s)",
      n, table.concat(exp, " or "), type(val)), 3)
  end

  env.load = function(chunk, name, mode, e)
    return hostLoad(chunk, name, mode, e or env)
  end
  env.loadfile = function(path, mode, e)
    local abs = vfsAbs(tostring(path), p.cwd or "/")
    local data = vfsReadFile(abs)
    if not data and readFile then
      data = readFile(path)
      if not data then
        local base = tostring(path):match("([^/]+)$")
        if base then data = readFile("/" .. base) or readFile(base) end
      end
    end
    if not data then return nil, tostring(path) .. ": not found" end
    return hostLoad(data, "=" .. tostring(path), mode or "t", e or env)
  end
  env.dofile = function(path)
    local fn, err = env.loadfile(path)
    if not fn then error(err) end
    return fn()
  end

  -- computer: info subset + harmless outputs (shutdown/beep).
  -- No pushSignal (cross-process injection) by design.
  env.computer = {
    uptime = function() return computer.uptime() end,
    freeMemory = function() return freax.freeMem() end,
    totalMemory = function() return freax.totalMem() end,
    tmpAddress = function() return freax.tmpAddr() end,
    getDeviceInfo = function() return freax.deviceInfo() end,
    address = function() return freax.machineAddr() end,
    shutdown = function(reboot) pcall(computer.shutdown, reboot and true or false) end,
    pullSignal = function(sec)
      sec = sec or math.huge
      local deadline = computer.uptime() + sec
      local first = table.pack(freax.pollEvent())
      if first[1] ~= nil then return table.unpack(first, 1, first.n) end
      if computer.uptime() >= deadline then return nil end
      -- wait without eating: peek, yield, re-check (shared keys stay
      -- queued for whoever actually reads them)
      while computer.uptime() < deadline do
        if freax.peekEvent() then coroutine.yield()
        else return procPull(p) end
      end
      return nil
    end,
    pushSignal = function() return nil, "signal injection denied under Freax" end,
    beep = function(freq, dur) return freax.beep(freq, dur) end,
  }

  -- os: per-process env vars + clock + VFS-backed remove/rename.
  p.vars = p.vars or {
    PATH = "/bin:/usr/bin:.", TMPDIR = "/tmp", TMP = "/tmp",
    HOME = "/home", SHELL = "/bin/sh",
    MANPATH = "/usr/man", PAGER = "less",
  }
  local osT = {}
  function osT.getenv(k)
    if k == nil then
      local c = {}
      for kk, vv in pairs(p.vars) do c[kk] = vv end
      return c
    end
    if k == "#" then
      local n = 0
      for _ in pairs(p.vars) do n = n + 1 end
      return n
    end
    if k == "PWD" and p.vars.PWD == nil then return p.cwd or "/" end
    return p.vars[k]
  end
  function osT.setenv(k, v)
    if v ~= nil then v = tostring(v) end
    p.vars[k] = v
    return v
  end
  osT.clock = os.clock
  osT.date = os.date
  osT.time = os.time
  osT.difftime = os.difftime
  function osT.sleep(t)
    local deadline = computer.uptime() + (t or 0)
    while computer.uptime() < deadline do
      if freax.peekEvent() then coroutine.yield() else procPull(p) end
    end
  end
  osT.remove = function(path) return freax.fsRemove(path) end
  osT.rename = function(a, b) return freax.fsRename(a, b) end
  osT.exit = function(code)
    p.exitCode = (type(code) == "number" and code)
      or (code == false and 1) or 0
    p.dead = true
    coroutine.yield()
  end
  osT.tmpname = function()
    for _ = 1, 10 do
      local n = "/tmp/" .. tostring(math.random(1, 0x7FFFFFFF))
      if not freax.fsExists(n) then return n end
    end
  end
  -- Resolve a command name via PATH (shared by os.execute and io.popen).
  local function resolveProg(prog)
    if prog:find("/") then return prog end
    for dir in string.gmatch(p.vars.PATH or "/bin", "[^:]+") do
      for _, cand in ipairs({ dir .. "/" .. prog .. ".lua", dir .. "/" .. prog }) do
        if vfsReadFile(vfsAbs(cand, "/")) then return cand end
      end
    end
    return nil
  end
  local function waitPid(cpid)
    p.waitingFor = cpid
    while true do
      local found
      for _, q in ipairs(procs) do
        if q.pid == cpid then found = q break end
      end
      if not found or found.dead then p.waitingFor = nil break end
      coroutine.yield()
    end
  end
  osT.execute = function(cmd)
    if not cmd then return false end
    local args = {}
    for tok in tostring(cmd):gmatch("%S+") do args[#args + 1] = tok end
    local prog = table.remove(args, 1)
    if not prog then return false end
    local path = resolveProg(prog)
    if not path then return nil, "command not found" end
    -- inherit my stdio (so `man ls > file` captures the pager too);
    -- tty handles have no _fd and fall back to the tty, as before.
    local function fdOf(h)
      return (type(h) == "table" and h._fd) or nil
    end
    local cpid = K.spawn(prog, path, args,
      { in_ = fdOf(p.ioT[1]), out = fdOf(p.ioT[2]), err = fdOf(p.ioT[3]) },
      myInh())
    if not cpid then return nil, "cannot execute" end
    waitPid(cpid)
    return true
  end
  env.os = osT

  -- io: fd-backed files + shared-tty stdio (mirrors OpenOS io surface).
  local function ioFill(h)
    if h._eof then return end
    local e = fds[h._fd]
    if not e then h._eof = true return end
    local ok, chunk = pcall(e.proxy.read, e.h, 4096)
    if not ok or not chunk then h._eof = true return end
    h._buf = h._buf .. chunk
  end
  local function newHandle(fd)
    local h = { _fd = fd, _buf = "", _eof = false, _closed = false, _isfile = true }
    function h:read(fmt)
      if self._closed then return nil, "closed" end
      fmt = fmt or "*l"
      if type(fmt) == "number" then
        while #self._buf < fmt and not self._eof do ioFill(self) end
        if #self._buf == 0 then return nil end
        local r = self._buf:sub(1, fmt)
        self._buf = self._buf:sub(#r + 1)
        return r
      elseif fmt == "*a" then
        while not self._eof do ioFill(self) end
        if #self._buf == 0 then return nil end
        local r = self._buf
        self._buf = ""
        return r
      elseif fmt == "*l" or fmt == "*L" then
        while not self._eof do
          local i = self._buf:find("\n", 1, true)
          if i then break end
          ioFill(self)
        end
        if #self._buf == 0 then return nil end
        local i = self._buf:find("\n", 1, true)
        local r
        if i then
          r = self._buf:sub(1, i - 1)
          self._buf = self._buf:sub(i + 1)
        else
          r = self._buf
          self._buf = ""
        end
        if fmt == "*L" and i then r = r .. "\n" end
        return r
      end
      return nil, "not supported"
    end
    function h:lines(...)
      local fmts = table.pack(...)
      if fmts.n == 0 then fmts = { "*l" } end
      return function()
        local r = self:read(table.unpack(fmts, 1, fmts.n))
        return r
      end
    end
    function h:write(...)
      if self._closed then return nil, "closed" end
      local e = fds[self._fd]
      if not e then return nil, "closed" end
      local parts = {}
      for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
      local data = table.concat(parts)
      local i = 1
      while i <= #data do
        local ok, r = pcall(e.proxy.write, e.h, data:sub(i, i + 8191))
        if not ok or not r then return nil, "write failed" end
        i = i + 8192
      end
      return self
    end
    function h:close()
      if self._closed then return true end
      self._closed = true
      local e = fds[self._fd]
      if e then pcall(e.proxy.close, e.h) fds[self._fd] = nil end
      return true
    end
    function h:flush() return true end
    function h:seek() return nil, "not supported" end
    return h
  end
  local stdinH = { _isfile = true, _stdio = true }
  function stdinH:read(fmt)
    fmt = fmt or "*l"
    if fmt == "*l" or fmt == "*L" or fmt == nil then return ttyReadLine(p) end
    return nil, "not supported on tty"
  end
  function stdinH:lines() return function() return ttyReadLine(p) end end
  function stdinH:close() return nil, "cannot close stdin" end
  local function newTtyOut()
    local o = { _isfile = true, _stdio = true }
    function o:write(...)
      local parts = {}
      for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
      ttyWrite(table.concat(parts))
      return self
    end
    function o:close() return true end
    function o:flush() return true end
    function o:seek() return nil, "not supported" end
    return o
  end
  p.ioT = p.ioT or {}
  if not p.ioT[1] then p.ioT[1] = stdinH end
  if not p.ioT[2] then p.ioT[2] = newTtyOut() end
  if not p.ioT[3] then p.ioT[3] = newTtyOut() end
  local ioT = {}
  function ioT.open(path, mode)
    mode = tostring(mode or "r"):gsub("b", "")
    if mode ~= "r" and mode ~= "w" and mode ~= "a" then
      return nil, "bad mode"
    end
    local abs = vfsAbs(tostring(path), p.cwd or "/")
    local exp, expErr = expandLinks(abs, true)
    if not exp then return nil, expErr end
    local proxy, rest = vfsResolve(exp)
    if not proxy then return nil, "no such filesystem" end
    if rest == "" then return nil, "is a directory" end
    local ok, hnd = pcall(proxy.open, rest, mode)
    if not ok or not hnd then return nil, "cannot open" end
    local fd = nextFd
    nextFd = nextFd + 1
    fds[fd] = { proxy = proxy, h = hnd, owner = p.pid, path = abs, mode = mode }
    return newHandle(fd)
  end
  function ioT.input(f)
    if f ~= nil then
      if type(f) == "string" then f = ioT.open(f, "r") end
      p.ioT[1] = f
    end
    return p.ioT[1]
  end
  function ioT.output(f)
    if f ~= nil then
      if type(f) == "string" then f = ioT.open(f, "w") end
      p.ioT[2] = f
    end
    return p.ioT[2]
  end
  function ioT.error(f)
    if f ~= nil then p.ioT[3] = f end
    return p.ioT[3]
  end
  ioT.stdin, ioT.stdout, ioT.stderr = p.ioT[1], p.ioT[2], p.ioT[3]
  function ioT.close(f) return (f or p.ioT[2]):close() end
  function ioT.flush() return true end
  function ioT.read(...) return p.ioT[1]:read(...) end
  function ioT.write(...) return p.ioT[2]:write(...) end
  function ioT.lines(path, ...)
    if path then
      local f, err = ioT.open(path, "r")
      if not f then error(err, 2) end
      return f:lines(...)
    end
    return p.ioT[1]:lines(...)
  end
  function ioT.tmpfile()
    local n = osT.tmpname()
    return n and ioT.open(n, "w") or nil
  end
  function ioT.popen(prog, mode)
    mode = tostring(mode or "r"):sub(1, 1)
    if mode ~= "r" and mode ~= "w" then return nil, "bad mode" end
    local args = {}
    for tok in tostring(prog):gmatch("%S+") do args[#args + 1] = tok end
    local name = table.remove(args, 1)
    if not name then return nil, "bad prog" end
    local path = resolveProg(name)
    if not path then return nil, "command not found" end
    local rfd, wfd = freax.pipe()
    local cpid
    if mode == "r" then
      cpid = K.spawn(name, path, args, { out = wfd }, myInh())
      freax.fsClose(wfd)
      if not cpid then freax.fsClose(rfd) return nil, "cannot execute" end
      return kernelNewHandle(rfd, p)
    else
      cpid = K.spawn(name, path, args, { in_ = rfd }, myInh())
      freax.fsClose(rfd)
      if not cpid then freax.fsClose(wfd) return nil, "cannot execute" end
      return kernelNewHandle(wfd, p)
    end
  end
  function ioT.type(o)
    if type(o) == "table" and o._isfile then
      return o._closed and "closed file" or "file"
    end
    return nil
  end
  env.io = ioT

  -- per-process module loader: /lib only, compiled in THIS env
  -- tries VFS FHS path first, then flat M0 dev layout (term.lua in /)
  local function tryRead(path)
    local src = vfsReadFile(vfsAbs(path, "/"))
    if src then return src end
    src = readFile and readFile(path)
    if src then return src end
    local base = path:match("([^/]+)$")
    if base and base ~= path then
      src = vfsReadFile("/" .. base)
      if src then return src end
      if readFile then
        src = readFile("/" .. base)
        if src then return src end
        src = readFile(base)
        if src then return src end
      end
    end
    return nil
  end
  local libs = {}
  function env.require(name)
    -- mod-provided or safe-subset globals first (OpenOS require falls
    -- back to globals the same way for computer/unicode).
    if name == "computer" then return env.computer end
    if name == "unicode" then return env.unicode end
    if name == "bit32" then return env.bit32 end
    if libs[name] then return libs[name] end
    local stem = name:gsub("%.", "/")
    local src = tryRead("/lib/" .. stem .. ".lua")
      or tryRead("/" .. stem .. ".lua")
      or tryRead(stem .. ".lua")
    if not src then error("module not found: " .. name) end
    local fn, err = load(src, "=" .. name, "t", env)
    if not fn then error("load error in " .. name .. ": " .. tostring(err)) end
    local ok, res = pcall(fn)
    if not ok then error("init error in " .. name .. ": " .. tostring(res)) end
    libs[name] = res
    return res
  end

  env.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
      parts[#parts + 1] = tostring(select(i, ...))
    end
    local term = env.require("term")
    term.writeln(table.concat(parts, "\t"))
  end

  return env
end

---------------------------------------------------------------
-- Process management
---------------------------------------------------------------

function K.spawn(name, path, args, stdio, inh)
  -- M1: resolve via VFS first (FHS), then legacy flat fallback.
  local src = vfsReadFile(vfsAbs(path, "/"))
  if not src then src = readFile and readFile(path) end
  if not src then
    -- flat fallback: /bin/sh.lua -> sh.lua (M0 dev layout, all files in /)
    local base = path:match("([^/]+)$")
    if base then
      local v = vfsReadFile("/" .. base)
      if v then src = v
      elseif readFile then src = readFile("/" .. base) or readFile(base) end
    end
  end
  if not src then return nil, path .. ": not found" end
  local p = {
    pid = nextPid, name = name,
    queue = {}, started = false, dead = false,
    -- children inherit cwd + env vars (like a real fork/exec)
    cwd = (inh and inh.cwd) or "/",
    vars = inh and inh.vars,
  }
  -- Optional redirected stdio for pipelines (M2): pipe fds are duped
  -- into the child; {path, mode} specs are opened independently.
  if stdio then
    p.ioT = {}
    local okAll = true
    local function take(spec, dfltMode)
      if spec == nil then return nil end
      if type(spec) == "number" then
        local e = fds[spec]
        if not e then okAll = false return nil end
        if e.pipe then
          local d = dupPipeFd(spec, p.pid)
          return d and kernelNewHandle(d, p) or nil
        end
        -- file fd: reopen the same path for the child (independent
        -- offset/close; avoids shared-handle refcounting)
        if e.proxy and e.path then
          local exp = expandLinks(e.path, true) or e.path
          local proxy, rest = vfsResolve(exp)
          if proxy and rest ~= "" then
            local ok, hnd = pcall(proxy.open, rest, e.mode or "r")
            if ok and hnd then
              local fd = nextFd
              nextFd = nextFd + 1
              fds[fd] = { proxy = proxy, h = hnd, owner = p.pid,
                path = e.path, mode = e.mode }
              return kernelNewHandle(fd, p)
            end
          end
        end
        okAll = false
        return nil
      elseif type(spec) == "table" then
        local abs = vfsAbs(tostring(spec[1]), "/")
        abs = expandLinks(abs, true) or abs
        local proxy, rest = vfsResolve(abs)
        if proxy and rest ~= "" then
          local ok, hnd = pcall(proxy.open, rest, spec[2] or dfltMode)
          if ok and hnd then
            local fd = nextFd
            nextFd = nextFd + 1
            fds[fd] = { proxy = proxy, h = hnd, owner = p.pid,
              path = abs, mode = spec[2] or dfltMode }
            return kernelNewHandle(fd, p)
          end
        end
      end
      okAll = false
      return nil
    end
    p.ioT[1] = take(stdio[1] or stdio.in_, "r")
    p.ioT[2] = take(stdio[2] or stdio.out, "w")
    p.ioT[3] = take(stdio[3] or stdio.err, "w")
    if not okAll then closeOwnedFds(p.pid) return nil, "bad stdio" end
  end
  local fn, err = load(src, "=" .. path, "t", makeEnv(p))
  if not fn then closeOwnedFds(p.pid) return nil, tostring(err) end
  if not fn then return nil, tostring(err) end
  p.co = coroutine.create(function()
    -- program return value IS the exit code (numbers; false = 1)
    local r = fn(table.unpack(args or {}))
    p.exitCode = (r == false and 1) or (type(r) == "number" and r) or 0
    p.dead = true
  end)
  procs[#procs + 1] = p
  nextPid = nextPid + 1
  return p.pid
end

---------------------------------------------------------------
-- Scheduler
---------------------------------------------------------------

function K.loop()
  while true do
    local sig = table.pack(computer.pullSignal(0.05))
    local hasSig = sig.n > 0 and sig[1] ~= nil
    if hasSig then
      -- sequence + route: keystrokes go ONLY to the shared queue
      -- (single consumption); everything else keeps broadcast copies.
      sigSeq = sigSeq + 1
      sig.seq = sigSeq
      if isKeySig(sig) then
        keyQueue[#keyQueue + 1] = sig
      end
    end
    ttyCursorTick() -- block-cursor blink (GPU touched only on change)
    for i = #procs, 1, -1 do
      local p = procs[i]
      if p.dead then
        closeOwnedFds(p.pid)
        table.remove(procs, i)
      else
        local ok, err
        if not p.started then
          p.started = true
          -- don't drop input arriving on the exact start tick
          -- (non-key only; keys wait in the shared queue)
          if hasSig and not isKeySig(sig) and not p.waitingFor then
            p.queue[#p.queue + 1] = sig
          end
          ok, err = coroutine.resume(p.co)
        elseif p.waitingFor or p.pipeWait then
          -- foreground wait / pipe block: poll every tick.
          -- waiters still queue non-key input (typeahead); pipe blocks
          -- and all keystrokes bypass per-process queues entirely.
          if hasSig and not isKeySig(sig) and not p.pipeWait then
            p.queue[#p.queue + 1] = sig
          end
          ok, err = coroutine.resume(p.co)
        elseif hasSig then
          -- active process: keys come from the shared queue on pull,
          -- everything else broadcasts as before
          if not isKeySig(sig) then
            p.queue[#p.queue + 1] = sig
          end
          ok, err = coroutine.resume(p.co)
        end
        if ok == false then
          K.klog(p.name .. " (pid " .. p.pid .. "): " .. tostring(err))
          p.exitCode = 1
          p.dead = true
        end
      end
    end
  end
end

---------------------------------------------------------------
-- Boot
---------------------------------------------------------------

function K.init(a, b)
  if type(a) == "table" and (a.bootfs or a.readFile or a.loadModule) then
    bootfs = a.bootfs
    readFile = a.readFile
    bootaddr = a.bootaddr
  else
    bootfs, readFile = a, b
  end
  -- M1 VFS: mount boot at /, others at /mnt/xxx (like OpenOS 90_filesystem)
  mounts = {}
  links = {} -- virtual symlinks never survive a reboot (as in OpenOS)
  if bootfs then
    vfsMount(bootfs, "/", bootaddr)
  end
  if component and component.list and bootaddr then
    for addr in component.list("filesystem") do
      if addr ~= bootaddr then
        local ok, proxy = pcall(component.proxy, addr)
        if ok and proxy then
          local short = addr:sub(1, 3)
          -- avoid collisions
          local name = short
          local n = 3
          local taken = true
          while taken do
            taken = false
            for _, m in ipairs(mounts) do
              if m.path == "/mnt/" .. name then taken = true break end
            end
            if taken then n = n + 1 name = addr:sub(1, n) end
          end
          vfsMount(proxy, "/mnt/" .. name, addr)
        end
      end
    end
  end
  K.klog("freax 0.5 kernel up")
end

function K.start()
  -- login first (full installs); bare shell fallback (minimal/rescue).
  local loginPaths = {
    "/bin/login.lua",
    "login.lua",
  }
  local pid, err
  for _, p in ipairs(loginPaths) do
    pid, err = K.spawn("login", p, {})
    if pid then break end
  end
  if pid then return K.loop() end
  local shellPaths = {
    "/bin/sh.lua", "/bin/shell.lua",
    "/sh.lua", "sh.lua",
    "/bin/sh", "sh",
  }
  for _, p in ipairs(shellPaths) do
    pid, err = K.spawn("sh", p, {})
    if pid then break end
  end
  if not pid then
    K.klog("no shell found: " .. tostring(err))
  end
  return K.loop()
end

return K
