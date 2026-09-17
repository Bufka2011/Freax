-- primary: show the kernel's chosen device (M2).
-- Freax owns hardware routing, so primaries are read-only here.
local shell = require("shell")

local args = shell.parse(...)
if #args == 0 then
  io.write("Usage: primary <type>\n")
  return 1
end

local addr = freax.primary(args[1])
if addr then
  io.write(addr .. "\n")
else
  io.stderr:write("no primary " .. args[1] .. " (kernel routes it)\n")
  return 1
end
