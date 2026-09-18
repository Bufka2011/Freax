-- less: page through a file (M2). Space/pgdn = page, enter = line, q = quit.
local fs = require("fs")
local shell = require("shell")
local keyboard = require("keyboard")

local args = table.pack(...)
if args.n == 0 then
  io.write("Usage: less FILE\n")
  return
end

local path = shell.resolve(args[1])
local data, err = fs.readFile(path)
if not data then
  io.write("less: " .. tostring(err) .. "\n")
  return
end

local lines = {}
for line in (data .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end

local w, h = freax.ttySize()
local page = h - 1
local top = 1

local function draw()
  freax.ttyClear()
  for i = 0, page - 1 do
    freax.ttyWrite((lines[top + i] or "") .. "\n")
  end
  freax.ttyWrite("-- " .. args[1] .. " " .. top .. "-" ..
    math.min(top + page - 1, #lines) .. "/" .. #lines .. " (space/enter/q)")
end

draw()
while true do
  local name, _, char, code = freax.pullEvent()
  if name == "key_down" then
    if code == keyboard.keys.space or code == keyboard.keys.pageDown then
      top = math.min(top + page, math.max(#lines - page + 1, 1))
      draw()
    elseif code == 28 then -- enter
      top = math.min(top + 1, math.max(#lines - page + 1, 1))
      draw()
    elseif (char and char == 113) or code == keyboard.keys.q then -- q
      return
    end
  end
end
