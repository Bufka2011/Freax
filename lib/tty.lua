-- tty: OpenOS-compatible tty over the Freax shared terminal.
-- term-backed base: viewport/cursor map to kernel tty syscalls.
-- ANSI/VT100 stream is parsed here: colors go to freax.ttySetForeground/
-- Background, cursor/erase to term, plus wrap/nowrap, horizontal scroll
-- and special chars. Multiple screens / gpu binding remain out of scope.

local term = require("term")

local tty = {}
tty.window = {
  fullscreen = true, blink = true, dx = 0, dy = 0,
  x = 1, y = 1, output_buffer = "", nowrap = false,
}

local function size()
  return term.getSize()
end

local function syncFromTerm()
  local x, y = term.getCursor()
  tty.window.x, tty.window.y = x, y
end

function tty.getViewport()
  local w, h = size()
  tty.window.width, tty.window.height = w, h
  syncFromTerm()
  return w, h, tty.window.dx, tty.window.dy, tty.window.x, tty.window.y
end

function tty.setViewport(w, h, dx, dy, x, y)
  tty.window.width, tty.window.height = w, h
  if dx then tty.window.dx = dx end
  if dy then tty.window.dy = dy end
  if x and y then term.setCursor(x, y) end
  syncFromTerm()
end

-- GPU shim: colors actuate the kernel tty; text goes through term.
function tty.gpu()
  local gpu = {}
  function gpu.setForeground(c, isPal)
    if freax.ttySetForeground then return freax.ttySetForeground(c, isPal) end
  end
  function gpu.getForeground()
    if freax.ttyGetForeground then return freax.ttyGetForeground() end
    return 0xFFFFFF, false
  end
  function gpu.setBackground(c, isPal)
    if freax.ttySetBackground then return freax.ttySetBackground(c, isPal) end
  end
  function gpu.getBackground()
    if freax.ttyGetBackground then return freax.ttyGetBackground() end
    return 0x000000, false
  end
  function gpu.set(x, y, s) term.setCursor(x, y); term.write(s) end
  function gpu.get(x, y) return nil end
  function gpu.getResolution() return size() end
  function gpu.setResolution(w, h) return freax.gpuSetResolution(w, h) end
  function gpu.getViewport() return size() end
  function gpu.copy(x, y, w, h, dx, dy) return freax.gpuCopy(x, y, w, h, dx, dy) end
  function gpu.fill(x, y, w, h, c)
    if type(c) == "string" and #c > 0 then
      local row = string.rep(c:sub(1, 1), w)
      for yy = y, y + h - 1 do
        term.setCursor(x, yy)
        term.write(row)
      end
    end
  end
  function gpu.maxResolution() return 160, 50 end
  return gpu
end

function tty.screen() return nil end
function tty.isAvailable() return true end
function tty.getCursor() return term.getCursor() end
function tty.setCursor(x, y) term.setCursor(x, y); syncFromTerm() end
function tty.bind() return true end
-- simplified: Freax exposes a single keyboard queue, no raw screen scan.
function tty.keyboard() return "keyboard0" end

function tty.clear()
  tty.window.output_buffer = ""
  term.clear()
  tty.window.x, tty.window.y = 1, 1
end

-------------------------------------------------------------------------------
-- ANSI / VT100 stream
-------------------------------------------------------------------------------

tty.stream = {}

local function writeText(s)
  local w = tty.window.width or select(1, size())
  if tty.window.nowrap then
    local g = tty.gpu()
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      local x, y = term.getCursor()
      if x > w then
        freax.gpuCopy(1, y, w, 1, -1, 0)
        g.fill(w, y, 1, 1, " ")
        term.setCursor(w, y)
      end
      term.write(ch)
    end
  else
    term.write(s)
  end
  syncFromTerm()
end

function tty.stream.scroll(lines)
  local w, h = tty.window.width, tty.window.height
  if not w then w, h = size() end
  if not lines then
    local _, y = term.getCursor()
    if y < 1 then lines = y - 1
    elseif y > h then lines = y - h
    else return 0 end
  end
  if not lines or lines == 0 then return 0 end
  lines = math.max(-h, math.min(h, lines))
  local n = math.abs(lines)
  if n >= h then
    local g = tty.gpu()
    g.fill(1, 1, w, h, " ")
    return lines
  end
  if lines > 0 then
    freax.gpuCopy(1, 1 + n, w, h - n, 0, -n)
    local g = tty.gpu()
    g.fill(1, h - n + 1, w, n, " ")
  else
    freax.gpuCopy(1, 1, w, h - n, 0, n)
    local g = tty.gpu()
    g.fill(1, 1, w, n, " ")
  end
  return lines
end

local function saveCursor()
  local x, y = term.getCursor()
  tty.window.saved = { x, y }
end

local function restoreCursor()
  local s = tty.window.saved
  if s then term.setCursor(s[1], s[2]); syncFromTerm() end
end

local function eraseLine(mode)
  local g = tty.gpu()
  local w = select(1, size())
  local x, y = term.getCursor()
  if mode == 0 then g.fill(x, y, w - x + 1, 1, " ")
  elseif mode == 1 then g.fill(1, y, x, 1, " ")
  else g.fill(1, y, w, 1, " ") end
end

local function eraseDisplay(mode)
  local g = tty.gpu()
  local w, h = size()
  local x, y = term.getCursor()
  if mode == 0 then
    g.fill(x, y, w - x + 1, 1, " ")
    if y < h then g.fill(1, y + 1, w, h - y, " ") end
  elseif mode == 1 then
    if y > 1 then g.fill(1, 1, w, y - 1, " ") end
    g.fill(1, y, x, 1, " ")
  else
    g.fill(1, 1, w, h, " ")
    term.setCursor(1, 1)
  end
end

local function index()
  local _, h = size()
  local x, y = term.getCursor()
  if y >= h then tty.stream.scroll(1); term.setCursor(x, h)
  else term.setCursor(x, y + 1) end
  syncFromTerm()
end

local function reverseIndex()
  local _, h = size()
  local x, y = term.getCursor()
  if y <= 1 then tty.stream.scroll(-1); term.setCursor(x, 1)
  else term.setCursor(x, y - 1) end
  syncFromTerm()
end

local function applySGR(params)
  local g = tty.gpu()
  if #params == 0 then params = { 0 } end
  local i = 1
  while i <= #params do
    local n = params[i]
    if n == 0 then
      g.setForeground(0xFFFFFF)
      g.setBackground(0x000000)
    elseif n == 7 then
      local fg = g.getForeground()
      local bg = g.getBackground()
      g.setForeground(bg)
      g.setBackground(fg)
    elseif n == 39 then g.setForeground(0xFFFFFF)
    elseif n == 49 then g.setBackground(0x000000)
    elseif n >= 30 and n <= 37 then g.setForeground(n - 30, true)
    elseif n >= 90 and n <= 97 then g.setForeground(n - 90 + 8, true)
    elseif n >= 40 and n <= 47 then g.setBackground(n - 40, true)
    elseif n >= 100 and n <= 107 then g.setBackground(n - 100 + 8, true)
    elseif (n == 38 or n == 48) and params[i + 1] == 5 then
      local p = params[i + 2] or 0
      if n == 38 then g.setForeground(p < 16 and p or 0xFFFFFF, p < 16)
      else g.setBackground(p < 16 and p or 0x000000, p < 16) end
      i = i + 2
    elseif (n == 38 or n == 48) and params[i + 1] == 2 then
      local r, gg, b = params[i + 2] or 0, params[i + 3] or 0, params[i + 4] or 0
      local c = r * 0x10000 + gg * 0x100 + b
      if n == 38 then g.setForeground(c) else g.setBackground(c) end
      i = i + 4
    end
    i = i + 1
  end
end

local function applyCSI(final, params, private)
  local w, h = size()
  local x, y = term.getCursor()
  local p = params[1] or 0
  if private then
    if final == "h" or final == "l" then
      for _, m in ipairs(params) do
        if m == 7 then tty.window.nowrap = (final == "l") end
      end
    end
  elseif final == "m" then
    applySGR(params)
  elseif final == "A" then term.setCursor(x, math.max(1, y - (p == 0 and 1 or p)))
  elseif final == "B" then term.setCursor(x, math.min(h, y + (p == 0 and 1 or p)))
  elseif final == "C" then term.setCursor(math.min(w, x + (p == 0 and 1 or p)), y)
  elseif final == "D" then term.setCursor(math.max(1, x - (p == 0 and 1 or p)), y)
  elseif final == "E" then term.setCursor(1, math.min(h, y + (p == 0 and 1 or p)))
  elseif final == "F" then term.setCursor(1, math.max(1, y - (p == 0 and 1 or p)))
  elseif final == "G" then term.setCursor(math.max(1, math.min(w, p == 0 and 1 or p)), y)
  elseif final == "H" or final == "f" then
    term.setCursor(math.max(1, math.min(w, params[2] or 1)),
      math.max(1, math.min(h, params[1] or 1)))
  elseif final == "J" then eraseDisplay(p)
  elseif final == "K" then eraseLine(p)
  elseif final == "s" then saveCursor()
  elseif final == "u" then restoreCursor()
  end
  syncFromTerm()
end

-- returns bytes consumed, or 0 when the sequence is incomplete.
local function parseEscape(buf, i)
  local c2 = buf:sub(i + 1, i + 1)
  if c2 == "" then return 0 end
  if c2 == "[" then
    local j, num, private = i + 2, "", false
    local params = {}
    while j <= #buf do
      local ch = buf:sub(j, j)
      if ch == "?" then private = true
      elseif ch:match("%d") then num = num .. ch
      elseif ch == ";" then params[#params + 1] = tonumber(num) or 0; num = ""
      else
        if num ~= "" then params[#params + 1] = tonumber(num) or 0 end
        applyCSI(ch, params, private)
        return (j - i) + 1
      end
      j = j + 1
    end
    return 0
  elseif c2 == "7" then saveCursor(); return 2
  elseif c2 == "8" then restoreCursor(); return 2
  elseif c2 == "D" then index(); return 2
  elseif c2 == "E" then index(); term.setCursor(1, select(2, term.getCursor())); syncFromTerm(); return 2
  elseif c2 == "M" then reverseIndex(); return 2
  else return 1 end
end

-- Auto-flush: consume the buffer on every write, retaining only a
-- trailing incomplete escape sequence for the next call.
function tty.stream:write(value)
  if type(value) ~= "string" then value = tostring(value) end
  local window = tty.window
  local buf = (window.output_buffer or "") .. value
  local i, n = 1, #buf
  while i <= n do
    local c = buf:sub(i, i)
    if c == "\27" then
      local consumed = parseEscape(buf, i)
      if consumed == 0 then
        window.output_buffer = buf:sub(i)
        return true
      end
      i = i + consumed
    elseif c == "\n" then
      term.write("\n"); syncFromTerm(); i = i + 1
    elseif c == "\r" then
      term.setCursor(1, select(2, term.getCursor())); syncFromTerm(); i = i + 1
    elseif c == "\t" then
      local x, y = term.getCursor()
      local nx = ((x - 1) - ((x - 1) % 8)) + 9
      local w = size()
      term.setCursor(math.min(nx, w), y); syncFromTerm(); i = i + 1
    elseif c == "\b" then
      local x, y = term.getCursor()
      if x > 1 then term.setCursor(x - 1, y) end
      syncFromTerm(); i = i + 1
    elseif c == "\a" then
      pcall(freax.beep); i = i + 1
    elseif c == "\v" or c == "\f" then
      local x, y = term.getCursor()
      term.setCursor(1, y + 1); syncFromTerm(); i = i + 1
    elseif c:byte() < 32 then
      i = i + 1
    else
      local j = buf:find("[\27\n\r\t\b\a\v\f\1-\31]", i)
      writeText(j and buf:sub(i, j - 1) or buf:sub(i))
      i = j or (n + 1)
    end
  end
  window.output_buffer = ""
  return true
end

function tty.stream.read() return term.readLine() end
function tty.stream.close() return nil, "tty: invalid operation" end
function tty.stream.seek() return nil, "tty: invalid operation" end
tty.stream.handle = "tty"

return tty
