-- touch: create empty files (M2).
local function out(s) io.write(tostring(s) .. "\n") end
local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if #args == 0 or opts.help then
  out("Usage: touch FILE...")
  return
end

for _, a in ipairs(args) do
  local path = shell.resolve(a)
  if not fs.exists(path) then
    local fd, err = fs.open(path, "w")
    if not fd then
      out("touch: " .. a .. ": " .. tostring(err))
    else
      fs.close(fd)
    end
  end
end
