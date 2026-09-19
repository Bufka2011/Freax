local shell = require("shell")
local fs = require("fs")

local args, opts = shell.parse(...)
if #args == 0 then args = {"-"} end

for _, a in ipairs(args) do
  if a == "-" then
    repeat
      local chunk = io.stdin:read(4096)
      if chunk then io.write(chunk) end
    until not chunk
  else
    local path = shell.resolve(a)
    if fs.isDirectory(path) then
      io.stderr:write("cat: " .. a .. ": Is a directory\n")
      os.exit(1)
    end
    local f, err = io.open(path, "r")
    if not f then
      io.stderr:write("cat: " .. a .. ": " .. tostring(err) .. "\n")
      os.exit(1)
    else
      repeat
        local chunk = f:read(4096)
        if chunk then io.write(chunk) end
      until not chunk
      f:close()
    end
  end
end