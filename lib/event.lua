-- event: OpenOS-compatible event lib (M2 compat).
-- Implemented on deadline-aware computer.pullSignal plus Freax event queues.

local freax = freax
local computer = require("computer")

local event = {}
local keyboard = require("keyboard")
local uptime = computer.uptime
local lastInterrupt = 0
local handlers = {}
event.handlers = handlers
event._taps = {} -- keyboard state feeds here

local nextId = 0

function event.register(key, callback, interval, times, opt)
  interval = tonumber(interval) or math.huge
  if interval <= 0 then interval = 0.05 end
  local h = {
    key = key, times = times or 1, callback = callback,
    interval = interval,
  }
  h.timeout = freax.uptime() + h.interval
  opt = opt or handlers
  nextId = nextId + 1
  while opt[nextId] do nextId = nextId + 1 end
  opt[nextId] = h
  return nextId
end

function event.listen(name, callback)
  for _, h in pairs(handlers) do
    if h.key == name and h.callback == callback then return false end
  end
  return event.register(name, callback, math.huge, math.huge)
end

function event.ignore(name, callback)
  for id, h in pairs(handlers) do
    if h.key == name and h.callback == callback then
      handlers[id] = nil
      return true
    end
  end
  return false
end

function event.cancel(id)
  if handlers[id] then handlers[id] = nil return true end
  return false
end

function event.timer(interval, callback, times)
  return event.register(false, callback, interval, times or math.huge)
end

function event.onError(msg)
  freax.ttyWrite("event error: " .. tostring(msg) .. "\n")
end

local function dispatch(sig, timeoutOnly)
  local n = sig.n
  local name = sig[1]
  if not timeoutOnly then
    for _, tap in ipairs(event._taps) do
      pcall(tap, table.unpack(sig, 1, n))
    end
  end
  local now = freax.uptime()
  -- Ctrl+C interrupt handling
  if now - lastInterrupt > 1 and keyboard.isControlDown() and keyboard.isKeyDown(keyboard.keys.c) then
    lastInterrupt = now
    if keyboard.isAltDown() then
      event.push("interrupted", 0)
    else
      event.push("interrupted", lastInterrupt)
    end
  end
  local copy = {}
  for id, h in pairs(handlers) do copy[id] = h end
  for id, h in pairs(copy) do
    -- nil keys match anything; timers (key == false) fire on timeout only
    if (not timeoutOnly and (h.key == nil or h.key == name)) or now >= h.timeout then
        h.times = h.times - 1
        h.timeout = now + h.interval
        if h.times <= 0 and handlers[id] == h then handlers[id] = nil end
        local ok, msg
        if timeoutOnly or h.key == false then ok, msg = pcall(h.callback)
        else ok, msg = pcall(h.callback, table.unpack(sig, 1, n)) end
        if not ok then
          pcall(event.onError, msg)
        elseif msg == false and handlers[id] == h then
          handlers[id] = nil
        end
    end
  end
end

function event._nextTimeout()
  local nextTimeout = math.huge
  for _, h in pairs(handlers) do
    if h.timeout < nextTimeout then nextTimeout = h.timeout end
  end
  return nextTimeout
end

function event._dispatchTimeouts()
  dispatch(table.pack(), true)
end

event._dispatch = dispatch

local function pullOnce()
  local sig = table.pack(freax.pollEvent())
  if sig[1] ~= nil then
    dispatch(sig)
    return sig
  end
  return nil
end

function event.pullFiltered(...)
  local args = table.pack(...)
  local seconds, filter = math.huge, nil
  if type(args[1]) == "function" then
    filter = args[1]
  else
    seconds = args[1] or math.huge
    filter = args[2]
  end
  local deadline = freax.uptime() + (seconds or math.huge)
  -- pen: taken-but-unmatched signals. Non-matching takes must not
  -- eat other consumers' keys from the shared queue, so they wait
  -- here for a later matching pull.
  event._pen = event._pen or {}
  local pen = event._pen
  local function matches(sig)
    return filter == nil or filter(table.unpack(sig, 1, sig.n))
  end
  while true do
    for i, sig in ipairs(pen) do
      if matches(sig) then
        table.remove(pen, i)
        return table.unpack(sig, 1, sig.n)
      end
    end
    local pk = table.pack(freax.peekEvent())
    if pk[1] ~= nil and matches(pk) then
      local sig = pullOnce() -- takes the head we just peeked
      if sig then
        if matches(sig) then return table.unpack(sig, 1, sig.n) end
        pen[#pen + 1] = sig -- raced: head changed under us, keep it
      end
      -- else: raced away entirely (same-process thread took it): re-loop
    else
      local now = freax.uptime()
      if now >= deadline then return nil end
      local wake = math.min(deadline, event._nextTimeout())
      local s = table.pack(computer.pullSignal(math.max(0, wake - now)))
      if s[1] ~= nil then
        dispatch(s)
        if matches(s) then return table.unpack(s, 1, s.n) end
        pen[#pen + 1] = s
      else
        event._dispatchTimeouts()
      end
    end
  end
end

local function plainFilter(name, ...)
  local f = table.pack(...)
  if name == nil and f.n == 0 then return nil end
  return function(...)
    local s = table.pack(...)
    if name and not (type(s[1]) == "string" and s[1]:match(name)) then
      return false
    end
    for i = 1, f.n do
      if f[i] ~= nil and f[i] ~= s[i + 1] then return false end
    end
    return true
  end
end

function event.pull(...)
  local args = table.pack(...)
  if type(args[1]) == "string" then
    return event.pullFiltered(plainFilter(...))
  else
    return event.pullFiltered(args[1], plainFilter(select(2, ...)))
  end
end

-- Pull the next signal whose name matches any of the given Lua patterns.
-- OpenOS compat (lib/core/full_event.lua): optional leading timeout.
function event.pullMultiple(...)
  local args = table.pack(...)
  local seconds
  if type(args[1]) == "number" then
    seconds = args[1]
    args = table.pack(table.unpack(args, 2, args.n))
  end
  local filter
  if args.n > 0 then
    filter = function(...)
      local s = table.pack(...)
      if type(s[1]) ~= "string" then return false end
      for i = 1, args.n do
        if args[i] ~= nil and s[1]:match(args[i]) then return true end
      end
      return false
    end
  end
  return event.pullFiltered(seconds, filter)
end

-- Signal injection is denied under Freax isolation.
function event.push()
  return nil, "signal injection denied under Freax"
end

return event
