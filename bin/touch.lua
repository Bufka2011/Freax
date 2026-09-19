local shell = require("shell")
local args, options = shell.parse(...)

if options.help then
  io.write("Usage: touch [OPTION]... FILE...\n")
  return
end
if #args == 0 then
  io.stderr:write("touch: missing operand\n")
  return 1
end

local no_create = options.c or options["no-create"]
local errors = 0

for _, arg in ipairs(args) do
  local path = shell.resolve(arg)
  if freax.fsExists(path) then
    local f, err = io.open(path, "a")
    if not f then
      io.stderr:write("touch: " .. arg .. ": " .. tostring(err) .. "\n")
      errors = 1
    else
      f:close()
    end
  elseif not no_create then
    local f, err = io.open(path, "w")
    if not f then
      io.stderr:write("touch: " .. arg .. ": " .. tostring(err) .. "\n")
      errors = 1
    else
      f:close()
    end
  end
end
return errors