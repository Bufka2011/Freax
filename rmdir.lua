-- rmdir: remove empty directories (M2).
local fs = require("fs")
local shell = require("shell")

local args = table.pack(...)
if args.n == 0 then
  io.write("Usage: rmdir DIR...\n")
  return
end

for i = 1, args.n do
  local path = shell.resolve(args[i])
  if not fs.isDirectory(path) then
    io.stderr:write("rmdir: " .. args[i] .. ": not a directory\n")
  elseif #(fs.list(path) or {}) > 0 then
    io.stderr:write("rmdir: " .. args[i] .. ": not empty\n")
  else
    local ok, err = fs.remove(path)
    if not ok then io.stderr:write("rmdir: " .. args[i] .. ": " .. tostring(err) .. "\n") end
  end
end
