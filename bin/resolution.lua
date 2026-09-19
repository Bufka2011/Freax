-- resolution: show/set screen resolution (M2).
local shell = require("shell")

local args = shell.parse(...)

if #args == 0 then
  local w, h = freax.ttyGetSize()
  io.write(w .. " " .. h .. "\n")
  return
end

if #args ~= 2 then
  print("Usage: resolution [<width> <height>]")
  return
end

local w, h = tonumber(args[1]), tonumber(args[2])
if not w or not h then
  io.stderr:write("invalid width or height\n")
  return 1
end

local ok, err = freax.gpuSetResolution(w, h)
if not ok then
  io.stderr:write(tostring(err) .. "\n")
  return 1
end
freax.ttyClear()
