-- term: terminal client (M2 compat).
-- Thin wrapper over the kernel shared tty: one screen, one cursor,
-- so io.write and term.write stay consistent for OpenOS programs.
-- Extra OpenOS names (read/isAvailable/getViewport/...) included.

local freax = freax

local term = {}
local blink = true

function term.write(s)
  freax.ttyWrite(s)
end

function term.writeln(s)
  freax.ttyWrite(tostring(s or "") .. "\n")
end

function term.clear()
  freax.ttyClear()
end

function term.clearLine()
  freax.ttyClearLine()
end

function term.setCursor(x, y) freax.ttySetCursor(x, y) end
function term.getCursor() return freax.ttyGetCursor() end
function term.getSize() return freax.ttySize() end

-- OpenOS compat ------------------------------------------------
function term.read(history, dobreak, hint, pwchar, filter)
  -- dobreak/hint: accepted; the kernel reader always returns one line
  -- and has no placeholder support. history seeds up-arrow recall.
  local f = filter
  if type(f) == "string" then
    local pat = f
    f = function(text) return text:match(pat) end
  end
  while true do
    local line = freax.ttyReadLine(pwchar, history)
    if type(f) ~= "function" or f(line) then return line end
    pcall(freax.beep, 2000, 0.1)
  end
end

function term.readLine() return freax.ttyReadLine() end

function term.isAvailable() return true end

function term.getViewport()
  local w, h = freax.ttySize()
  local x, y = freax.ttyGetCursor()
  return w, h, 0, 0, x, y
end

function term.getGlobalArea()
  local w, h = freax.ttySize()
  return 1, 1, w, h
end

local gpuBound = nil
function term.bind(gpu, window)
  gpuBound = gpu
  if window then term.window = window end
  return true
end

-- OpenOS term.internal.run_in_window: run func with the process window
-- switched. Freax has a single shared terminal, so the window is only
-- remembered; the call still runs.
term.internal = {}
function term.internal.run_in_window(window, func, ...)
  local prev = term.window
  term.window = window
  local ret = table.pack(func(...))
  term.window = prev
  return table.unpack(ret, 1, ret.n)
end

function term.setCursorBlink(e) blink = not not e freax.ttySetBlink(blink) end
function term.getCursorBlink() return blink end

function term.scroll() return 0 end

local pullPen = {}

function term.pull(...)
  local args = table.pack(...)
  local timeout
  if type(args[1]) == "number" then
    timeout = table.remove(args, 1)
  end
  local deadline = timeout and (freax.uptime() + timeout) or math.huge
  local function matches(sig)
    if #args == 0 then return true end
    if type(args[1]) == "string" and sig[1] ~= args[1] then return false end
    return true
  end
  while true do
    for i, sig in ipairs(pullPen) do
      if matches(sig) then
        table.remove(pullPen, i)
        return table.unpack(sig, 1, sig.n)
      end
    end
    local pk = table.pack(freax.peekEvent())
    if pk[1] ~= nil and matches(pk) then
      local sig = table.pack(freax.pollEvent()) -- takes the peeked head
      if sig[1] ~= nil then
        if matches(sig) then return table.unpack(sig, 1, sig.n) end
        pullPen[#pullPen + 1] = sig
      end
    else
      if freax.uptime() >= deadline then return nil end
      local sig = table.pack(freax.pullEvent()) -- blocks
      if matches(sig) then return table.unpack(sig, 1, sig.n) end
      if sig[1] ~= nil then pullPen[#pullPen + 1] = sig end
      if freax.uptime() >= deadline then return nil end
    end
  end
end

return term
