-- hostname: print or set the machine name (M2, stored in /etc/hostname).
local function out(s) io.write(tostring(s) .. "\n") end
local fs = require("fs")

local name = ...
if name and name ~= "" then
  local fd, err = fs.open("/etc/hostname", "w")
  if not fd then
    io.stderr:write("hostname: " .. tostring(err) .. "\n")
  else
    fs.write(fd, name .. "\n")
    fs.close(fd)
  end
else
  local data = fs.readFile("/etc/hostname")
  out(data and data:match("%S+") or "freax")
end
