local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if #args == 0 or opts.help then
  io.write("Usage: mkdir [-p] DIR...\n")
  io.write("  -p  create parent directories as needed\n")
  return 1
end

local bParents = opts.p or opts.parents
local ec = 0

local function mkdirP(path)
  local ok, err = fs.makeDirectory(path)
  if ok then return true end
  if bParents then
    local parent = path:match("^(.+)/[^/]+$")
    if parent then mkdirP(parent) end
    return fs.makeDirectory(path)
  end
  return nil, err
end

for _, a in ipairs(args) do
  local path = shell.resolve(a)
  if fs.exists(path) then
    io.stderr:write("mkdir: cannot create '" .. a .. "': file exists\n")
    ec = 1
  else
    local ok, err = mkdirP(path)
    if not ok then
      io.stderr:write("mkdir: cannot create '" .. a .. "': " .. tostring(err) .. "\n")
      ec = 1
    end
  end
end
return ec