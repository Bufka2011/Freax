-- tty: minimal OpenOS-compatible tty stub (M2 compat).
-- Freax has one dumb terminal; viewport/cursor calls map to term.
-- Anything needing gpu binding, screens or ANSI (vt100) is out of scope.

local term = require("term")

local tty = {}
tty.window = { fullscreen = true, blink = true, dx = 0, dy = 0, x = 1, y = 1 }

function tty.getViewport()
  local w, h = term.getSize()
  local x, y = term.getCursor()
  tty.window.width, tty.window.height = w, h
  return w, h, 0, 0, x, y
end

function tty.setViewport(w, h, dx, dy, x, y)
  tty.window.width, tty.window.height = w, h
  if x and y then term.setCursor(x, y) end
end

function tty.gpu()
  local gpu = {}
  function gpu.setForeground(c, isPal)
    if isPal then return end
    local r = bit32.band(bit32.rshift(c, 16), 0xFF)
    local g = bit32.band(bit32.rshift(c, 8), 0xFF)
    local b = bit32.band(c, 0xFF)
    local ansi = 16 + 36 * math.floor(r * 5 / 255) + 6 * math.floor(g * 5 / 255) + math.floor(b * 5 / 255)
    io.write("\27[38;5;" .. ansi .. "m")
  end
  function gpu.getForeground() return 0xFFFFFF, false end
  function gpu.setBackground(c, isPal)
    if isPal then return end
    local r = bit32.band(bit32.rshift(c, 16), 0xFF)
    local g = bit32.band(bit32.rshift(c, 8), 0xFF)
    local b = bit32.band(c, 0xFF)
    local ansi = 16 + 36 * math.floor(r * 5 / 255) + 6 * math.floor(g * 5 / 255) + math.floor(b * 5 / 255)
    io.write("\27[48;5;" .. ansi .. "m")
  end
  function gpu.getBackground() return 0x000000, false end
  function gpu.set(x, y, s)
    term.setCursor(x, y); io.write(s)
  end
  function gpu.getResolution() return term.getSize() end
  function gpu.setResolution(w, h) return freax.gpuSetResolution(w, h) end
  function gpu.getViewport() return term.getSize() end
  function gpu.copy(x, y, w, h, dx, dy) freax.gpuCopy(x, y, w, h, dx, dy) end
  function gpu.fill(x, y, w, h, c)
    if type(c) == "string" then
      for row = y, y + h - 1 do
        term.setCursor(x, row); io.write(string.rep(c:sub(1, 1), w))
      end
    end
  end
  function gpu.maxResolution() return 160, 50 end
  return gpu
end
function tty.screen() return nil end
function tty.clear() term.clear() end
function tty.isAvailable() return true end
function tty.getCursor() return term.getCursor() end
function tty.setCursor(x, y) term.setCursor(x, y) end
function tty.bind() return true end
function tty.keyboard() return "keyboard0" end

tty.stream = {}
function tty.stream.read() return term.readLine() end
function tty.stream:write(v) term.write(v) end
function tty.stream.scroll() return 0 end
function tty.stream.close() return nil, "tty: invalid operation" end
function tty.stream.seek() return nil, "tty: invalid operation" end
tty.stream.handle = "tty"

return tty
