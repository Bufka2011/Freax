-- mkdir: make directories (M1, inspired by OpenOS bin/mkdir).
local function out(s) io.write(tostring(s) .. "\n") end
local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if #args == 0 or opts.help then
  out("Usage: mkdir DIR...")
  return
end

local ec = 0
for _, a in ipairs(args) do
  local path = shell.resolve(a)
  local ok, err = fs.makeDirectory(path)
  if not ok then
    ec = 1
    out("mkdir: cannot create '" .. a .. "': " .. tostring(err))
  end
end
return ec
