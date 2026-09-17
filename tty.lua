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

function tty.gpu() return nil end
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
