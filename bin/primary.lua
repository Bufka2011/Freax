local shell = require("shell")

local args = shell.parse(...)
if #args == 0 then
  io.write("Usage: primary <type> [<address>]\n")
  io.write("Note that the address may be abbreviated.\n")
  return 1
end

if #args > 1 then
  if freax.setPrimary then
    freax.setPrimary(args[1], args[2])
  else
    io.stderr:write("primary: setting primaries not supported by this kernel\n")
    return 1
  end
end

local addr = freax.primary(args[1])
if addr then
  io.write(addr .. "\n")
else
  io.stderr:write("no primary " .. args[1] .. "\n")
  return 1
end
