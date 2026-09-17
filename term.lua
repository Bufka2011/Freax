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
  -- history/dobreak/hint/pwchar/filter handled by kernel reader
  -- only as plain line input in M1 (no masking/validation yet)
  return freax.ttyReadLine()
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

function term.bind() return true end

function term.setCursorBlink(e) blink = not not e end
function term.getCursorBlink() return blink end

function term.scroll() return 0 end

function term.pull(...)
  local args = table.pack(...)
  local timeout
  if type(args[1]) == "number" then
    timeout = table.remove(args, 1)
  end
  local deadline = timeout and (freax.uptime() + timeout) or math.huge
  while true do
    local sig = table.pack(freax.pollEvent())
    if sig[1] ~= nil then
      if #args == 0 then return table.unpack(sig, 1, sig.n) end
      local ok = true
      if type(args[1]) == "string" and sig[1] ~= args[1] then ok = false end
      if ok then return table.unpack(sig, 1, sig.n) end
    end
    if freax.uptime() >= deadline then return nil end
    sig = table.pack(freax.pullEvent())
    if #args == 0 then return table.unpack(sig, 1, sig.n) end
    if type(args[1]) == "string" and sig[1] ~= args[1] then
      -- not ours; drop (single-consumer M1 terminal)
    else
      return table.unpack(sig, 1, sig.n)
    end
  end
end

return term
