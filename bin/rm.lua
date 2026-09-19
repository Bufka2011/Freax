local fs = require("fs")
local shell = require("shell")

local args, options = shell.parse(...)
if #args == 0 or options.help then
  io.write("Usage: rm [options] <file>...\n")
  io.write("  -r  remove directories recursively\n")
  io.write("  -f  ignore nonexistent files, never prompt\n")
  io.write("  -v  explain what is being done\n")
  return
end

local bRec = options.r or options.R
local bForce = options.f or options.force
local bVerbose = options.v or options.verbose
local ec = 0

local function removeRec(path)
  local isDir = fs.isDirectory(path)
  if isDir then
    local list = fs.list(path) or {}
    if #list > 0 and not bRec then
      return nil, "is a directory (use -r)"
    end
    for _, n in ipairs(list) do
      local full = fs.concat(path, n:gsub("/$", ""))
      local ok, err = removeRec(full)
      if not ok then return nil, err end
    end
  end
  return fs.remove(path)
end

for _, a in ipairs(args) do
  local path = shell.resolve(a)
  if not fs.exists(path) then
    if not bForce then
      io.stderr:write("rm: " .. a .. ": no such file\n")
      ec = 1
    end
  else
    local ok, err = removeRec(path)
    if not ok then
      io.stderr:write("rm: " .. a .. ": " .. tostring(err) .. "\n")
      ec = 1
    elseif bVerbose then
      io.write("removed '" .. a .. "'\n")
    end
  end
end
return ec