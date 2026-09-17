-- thread: cooperative in-process threads (M2).
-- Freax-native engine, OpenOS-shaped API: create/join/kill/suspend/
-- resume/status/current/sleep/waitForAny/waitForAll.
-- Threads advance whenever THIS process pulls events (the pump runs
-- inside wrapped event.pullFiltered) or joins/sleeps. A process that
-- never pulls starves its threads -- same rule as the kernel level.

local event = require("event")
local freax = freax

local thread = {}

local threads = {}       -- live worker objects (main excluded)
local mainThread = { co = "main", queue = {}, status = "running", waiting = nil }
local current = mainThread

local function now() return freax.uptime() end

-- Take first queued signal matching filter (nil filter = anything).
local function takeMatch(t, filter)
  for i, sig in ipairs(t.queue) do
    if filter == nil or filter(table.unpack(sig, 1, sig.n)) then
      table.remove(t.queue, i)
      return sig
    end
  end
  return nil
end

local function prune()
  for i = #threads, 1, -1 do
    if threads[i].status == "dead" then
      table.remove(threads, i)
    end
  end
end

local function runScheduler()
  while true do
    local tnow = now()
    -- 1. wake sleepers whose time came
    for _, t in ipairs(threads) do
      if t.status == "running" and t.wake and t.wake <= tnow then
        t.wake, t.blocked, t.waiting = nil, false, nil
      end
    end
    -- 2. serve blocked workers: timeout or matching signal
    for _, t in ipairs(threads) do
      if t.status == "running" and t.blocked and t.waiting then
        local w = t.waiting
        local function step(...)
          current = t
          local ok, err = coroutine.resume(t.co, ...)
          current = mainThread
          if not ok then
            t.status = "dead"
            pcall(event.onError, "[thread] " .. tostring(err))
          end
        end
        if w.deadline and tnow >= w.deadline then
          t.blocked, t.waiting = false, nil
          step()
        else
          local sig = takeMatch(t, w.filter)
          if sig then
            t.blocked, t.waiting = false, nil
            step(table.unpack(sig, 1, sig.n))
          end
        end
      elseif t.status == "running" and not t.blocked then
        -- fresh thread: run until it blocks or finishes
        current = t
        local ok, err = coroutine.resume(t.co)
        current = mainThread
        if not ok then
          t.status = "dead"
          pcall(event.onError, "[thread] " .. tostring(err))
        end
      end
    end
    prune()
    -- 3. main's match?
    local mw = mainThread.waiting
    if mw then
      local sig = takeMatch(mainThread, mw.filter)
      if sig then
        mainThread.waiting = nil
        return table.unpack(sig, 1, sig.n)
      end
      if mw.deadline and now() >= mw.deadline then
        mainThread.waiting = nil
        return nil
      end
    end
    -- 4. fresh work arrived without blocking? (new thread this round)
    local runnable = false
    for _, t in ipairs(threads) do
      if t.status == "running" and not t.blocked then
        runnable = true
        break
      end
    end
    if not runnable then
      -- 5. kernel block, then broadcast to every thread queue
      local sig = table.pack(freax.pullEvent())
      for _, t in ipairs(threads) do
        t.queue[#t.queue + 1] = sig
      end
      mainThread.queue[#mainThread.queue + 1] = sig
    end
  end
end

-- Blocking pull for the CURRENT execution (thread or main).
local function scheduledPull(filter, deadline)
  local me = current
  me.waiting = { filter = filter, deadline = deadline }
  if me == mainThread then
    return runScheduler()
  end
  me.blocked = true
  coroutine.yield("blocked") -- scheduler resumes us with the signal
  -- timeout path clears waiting before resume; matched path too
end

-- Install the pump once: wrap event.pullFiltered for this process.
if not event._threadWrapped then
  event._threadWrapped = true
  local origPullFiltered = event.pullFiltered
  event.pullFiltered = function(...)
    if #threads == 0 then
      return origPullFiltered(...)
    end
    local args = table.pack(...)
    local seconds, filter = math.huge, nil
    if type(args[1]) == "function" then
      filter = args[1]
    else
      seconds = args[1] or math.huge
      filter = args[2]
    end
    return scheduledPull(filter, now() + (seconds or math.huge))
  end
end

-- Main-side wait until cond() or timeout (pumps threads meanwhile).
local function mainWaitUntil(cond, timeout)
  local deadline = now() + (timeout or math.huge)
  while true do
    if cond() then return true end
    if now() >= deadline then return nil, "thread join timed out" end
    scheduledPull(nil, deadline)
  end
end

function thread.create(fn, ...)
  local args = table.pack(...)
  local t = {
    queue = {}, status = "suspended", blocked = false,
    waiting = nil, wake = nil,
  }
  t.co = coroutine.create(function()
    local ok, err = pcall(fn, table.unpack(args, 1, args.n))
    t.status = "dead"
    if not ok then
      pcall(event.onError, "[thread] " .. tostring(err))
    end
  end)
  threads[#threads + 1] = t
  t.status = "running" -- threads start out running
  return t
end

function thread.current()
  return current
end

function thread.status(t)
  t = t or current
  return t.status
end

function thread.suspend(t)
  t = t or current
  if t == mainThread then return nil, "cannot suspend main" end
  if t.status ~= "running" then return nil, "cannot suspend " .. t.status end
  t.status = "suspended"
  if t == current then
    coroutine.yield("blocked") -- scheduler drops us until resumed
  end
  return true
end

function thread.resume(t)
  if t.status ~= "suspended" then
    return nil, "cannot resume " .. t.status
  end
  t.status = "running"
  t.blocked = false
  return true
end

function thread.kill(t)
  t = t or current
  if t ~= mainThread then
    t.status = "dead"
  end
  if t == current and t ~= mainThread then
    coroutine.yield("blocked") -- never resumed: scheduler skips dead
  end
  return true
end

function thread.join(t, timeout)
  return mainWaitUntil(function() return t.status == "dead" end, timeout)
end

function thread.detach()
  return current
end

function thread.attach()
  return current -- single process: always attached here
end

function thread.sleep(sec)
  local wake = now() + (sec or 0)
  if current == mainThread then
    mainWaitUntil(function() return now() >= wake end, (sec or 0) + 1)
  else
    current.wake = wake
    current.blocked = true
    coroutine.yield("blocked")
    current.wake = nil
  end
end

function thread.waitForAny(list, timeout)
  return mainWaitUntil(function()
    for _, t in ipairs(list) do
      if t.status == "dead" then return true end
    end
    return false
  end, timeout)
end

function thread.waitForAll(list, timeout)
  return mainWaitUntil(function()
    for _, t in ipairs(list) do
      if t.status ~= "dead" then return false end
    end
    return true
  end, timeout)
end

return thread
