local keys = require("keyboard").keys
local shell = require("shell")
local event = require("event")

local args, opts = shell.parse(...)
local stdinMode = #args == 0
if stdinMode then args = {"-"} end

local lines = {}
local scrollback = not opts.noback and {}
local bottom = 0
local eof = false
local w, h = term.getSize()

local function split(full)
  local parts = {}
  local i = 1
  while i <= #full do
    local sub = full:sub(i, i + w * 3)
    if #sub <= w then parts[#parts + 1] = sub; break end
    parts[#parts + 1] = sub:sub(1, w)
    i = i + #parts[#parts]
  end
  return parts
end

local function scan(num)
  local count = 0
  for i = 1, num do
    local full
    if scrollback and bottom + i <= #scrollback then
      full = scrollback[bottom + i]
    else
      full = io.stdin:read("*l")
      if not full then eof = true break end
      if scrollback then scrollback[#scrollback + 1] = full end
    end
    if full then
      for _, part in ipairs(split(full)) do
        io.write(part .. "\n")
        count = count + 1
      end
    end
  end
  bottom = bottom + count
  return count
end

scan(h - 1)

while true do
  term.setCursor(1, h)
  if eof then io.write("(END)") end
  io.write(":")
  local e, _, _, code = event.pull()
  if e == "interrupted" or (e == "key_down" and code == keys.q) then break end
  if e == "key_down" then
    if code == keys.up and scrollback then
      local top = math.max(1, bottom - h + 1)
      if top > 1 then
        term.clear(); bottom = bottom - 1
        local t = math.max(1, bottom - h + 2)
        for i = t, bottom do io.write((scrollback[i] or "") .. "\n") end
      end
    elseif code == keys.down and bottom < #scrollback then
      term.clear()
      for i = bottom - h + 3, bottom + 1 do io.write((scrollback[i] or "") .. "\n") end
      bottom = bottom + 1; eof = false
    elseif (code == keys.space or code == keys.pageDown) and not eof then
      if scan(h - 1) == 0 then eof = true end
    elseif code == keys.pageUp and scrollback then
      local t = math.max(1, bottom - (h - 1) * 2 + 1)
      term.clear()
      for i = t, math.min(t + h - 2, #scrollback) do io.write((scrollback[i] or "") .. "\n") end
      bottom = t + h - 2
    elseif code == keys.home then
      term.clear(); bottom = 0
      scan(h - 1)
    elseif code == keys["end"] then
      if scrollback then
        term.clear()
        for i = math.max(1, #scrollback - h + 2), #scrollback do io.write((scrollback[i] or "") .. "\n") end
        bottom = #scrollback; eof = true
      end
    end
  end
end
term.clear()