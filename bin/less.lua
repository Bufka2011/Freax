local keys = require("keyboard").keys
local shell = require("shell")
local event = require("event")

local args, opts = shell.parse(...)
if #args == 0 then
  io.write("Usage: less <filename>\n"); return 1
end

local lines = {}
for _, fname in ipairs(args) do
  local f, err = io.open(fname, "r")
  if not f then io.stderr:write("less: " .. fname .. ": " .. tostring(err) .. "\n"); return 1 end
  while true do
    local line = f:read("*l"); if not line then break end
    lines[#lines + 1] = line
  end
  f:close()
end
if #lines == 0 then return end

local w, h = term.getSize()
local top, bot = 1, math.min(h - 1, #lines)
local eof = #lines <= h - 1

local function draw()
  local used = 0
  for i = top, bot do
    local line = lines[i]
    if #line > w then line = line:sub(1, w) end
    io.write(line .. "\n")
    used = used + 1
  end
  for i = used + 1, h - 1 do io.write("\n") end
end

draw()

while true do
  term.setCursor(1, h); io.write(":")
  local e, _, _, code = event.pull()
  if e == "interrupted" or (e == "key_down" and code == keys.q) then break end
  if e == "key_down" then
    if code == keys.down and bot < #lines then
      top = top + 1; bot = bot + 1; eof = false
    elseif code == keys.up and top > 1 then
      top = top - 1; bot = bot - 1; eof = false
    elseif (code == keys.space or code == keys.pageDown) and not eof then
      top = top + h - 1
      if top > #lines - h + 2 then top = #lines - h + 2 end
      bot = math.min(top + h - 2, #lines); eof = bot == #lines
    elseif code == keys.pageUp then
      top = math.max(1, top - h + 1)
      bot = math.min(top + h - 2, #lines); eof = bot == #lines
    elseif code == keys.home then
      top = 1; bot = math.min(h - 1, #lines); eof = bot == #lines
    elseif code == keys["end"] then
      top = math.max(1, #lines - h + 2); bot = #lines; eof = true
    end
    draw()
  end
end
term.clear()