local shell = require("shell")
local args, options = shell.parse(...)

local help = options.help
local lines = tonumber(options.lines) or 10
options.help = nil; options.lines = nil

if help or next(options) or #args == 0 then
  io.write("Usage: head [--lines=n] file...\n")
  return
end

for i = 1, #args do
  local f, err
  if args[i] == "-" then
    f = io.stdin
  else
    f, err = io.open(args[i], "r")
  end
  if not f then
    io.stderr:write("head: " .. args[i] .. ": " .. tostring(err) .. "\n")
  else
    if #args > 1 then
      io.write("==> " .. args[i] .. " <==\n")
    end
    local count = 0
    repeat
      local line = f:read("*l")
      if not line then break end
      io.write(line .. "\n")
      count = count + 1
    until count >= lines
    if args[i] ~= "-" then f:close() end
  end
end